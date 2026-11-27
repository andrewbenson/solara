import AppKit
import SolaraModel
import SolaraStore

public struct ProfilePagerSelection: Equatable, Sendable {
  public let profileId: String
  public let order: [String]
  public let index: Int?
  public let engineProfile: String
  public let neighbours: [String]

  public init?(state: BrowserState, windowId: String) {
    guard let window = state.windows[windowId] else { return nil }
    profileId = window.profileId
    let order = window.incognito ? [] : state.profileOrder
    self.order = order
    index = order.firstIndex(of: window.profileId)
    engineProfile = state.engineProfile(window.profileId)
    neighbours = index.map { index in
      [index - 1, index + 1].compactMap { order.indices.contains($0) ? state.engineProfile(order[$0]) : nil }
    } ?? []
  }

  static func pageOrder(profileId: String, profiles: [String], looks: [SidebarPageLook]?) -> [String] {
    guard let looks else { return [profileId] }
    let available = Set(looks.map(\.profileId))
    let order = profiles.filter(available.contains)
    return order.contains(profileId) ? order : [profileId]
  }

  static func retainedPosition(_ position: Double?, previous: [String], next: [String], selectionChanged: Bool) -> Double? {
    guard previous == next, let position else { return nil }
    if selectionChanged && abs(position - position.rounded()) < 0.001 { return nil }
    return position
  }
}

@MainActor
public final class SidebarPagerView: NSView {
  public let virtualizesRows: Bool
  public let windowId: String
  public let favicons = SidebarFavicons()
  public var bottomBarHeight: CGFloat = 0 {
    didSet {
      guard bottomBarHeight != oldValue else { return }
      for page in pages.values { page.bottomBarHeight = bottomBarHeight }
    }
  }
  public var onLayoutAnchorsChange: (() -> Void)?
  public var onAction: (SidebarAction) -> Void = { _ in }

  private var stopped = false
  private var pages: [String: SidebarView] = [:]
  private lazy var sharedPlayer = SidebarSharedPlayer(container: self)
  private var stale: Set<String> = []
  private var state: BrowserState?
  private var host: SidebarHostState?
  private var order: [String] = []
  private var pagerPosition: Double?
  private var warm: DispatchWorkItem?
  public var pendingScrollOffsets: [String: CGFloat] = [:]

  static let warmDelay: TimeInterval = 0.3

  public override var isFlipped: Bool { true }

  public init(windowId: String, virtualizesRows: Bool = false) {
    self.virtualizesRows = virtualizesRows
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    warm?.cancel()
    warm = nil
    state = nil
    host = nil
    order = []
    onAction = { _ in }
    onLayoutAnchorsChange = nil
    for page in pages.values {
      page.stop()
      page.removeFromSuperview()
    }
    pages.removeAll()
    stale.removeAll()
    pendingScrollOffsets.removeAll()
  }

  public var current: SidebarView? { host.flatMap { pages[$0.profileId] } }

  public static func profileIDs(state: BrowserState, windowId: String) -> [String] {
    guard let window = state.windows[windowId], !window.incognito else { return [] }
    return state.profileOrder
  }

  public var pageIds: [String] { order }

  public var scrollOffsets: [String: CGFloat] {
    pendingScrollOffsets.merging(pages.mapValues { $0.scroll.contentView.bounds.minY }) { _, live in live }
  }

  public func describePages() -> [[String: Any]] {
    order.compactMap { id in
      guard let page = pages[id] else { return ["id": id, "made": false] }
      return ["id": id, "made": true, "x": page.frame.minX, "hidden": page.isHidden, "docked": page.pageLayout.docked, "current": id == host?.profileId]
    } + [["position": position], ["player": playerDescription], ["views": Self.count(self), "windowViews": window?.contentView.map { Self.count($0) } ?? 0,
          "layers": layer.map { Self.layers($0) } ?? 0, "windowLayers": window?.contentView?.layer.map { Self.layers($0) } ?? 0, "classes": Self.classes(self)]]
  }

  #if SOLARA_PROBES
  public func probeRealization() -> [String: Any] {
    ["enabled": virtualizesRows, "position": position, "pages": order.map { id in
      ["profileId": id, "realization": pages[id]?.probeRealization() ?? ["enabled": virtualizesRows, "logical": [], "bound": [], "reuse": [], "effectiveClip": [0, 0, 0, 0]]] as [String: Any]
    }]
  }
  #endif

  static func classes(_ view: NSView) -> [String: Int] {
    var out = [String(describing: type(of: view)): 1]
    for sub in view.subviews { out.merge(classes(sub), uniquingKeysWith: +) }
    return out
  }

  static func count(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + count($1) } }
  static func layers(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) } }

  public func update(state: BrowserState, host: SidebarHostState) {
    guard !stopped else { return }
    let previous = order
    let selectionChanged = self.host?.profileId != host.profileId
    self.state = state
    self.host = host
    order = ProfilePagerSelection.pageOrder(profileId: host.profileId, profiles: Self.profileIDs(state: state, windowId: windowId), looks: host.pages)
    pagerPosition = ProfilePagerSelection.retainedPosition(pagerPosition, previous: previous, next: order, selectionChanged: selectionChanged)
    stale = Set(pages.keys)
    pendingScrollOffsets = pendingScrollOffsets.filter { order.contains($0.key) }
    for id in pages.keys where !order.contains(id) {
      pages[id]?.stop()
      pages[id]?.removeFromSuperview()
      pages[id] = nil
      stale.remove(id)
    }
    place()
    if !virtualizesRows { scheduleWarm() }
  }

  public func setPagerPosition(_ position: Double) {
    guard !stopped else { return }
    pagerPosition = position
    place()
  }

  public override func layout() {
    super.layout()
    place()
  }

  var position: Double {
    let ids = order
    let home = Double(ids.firstIndex(of: host?.profileId ?? "") ?? 0)
    guard ids.count > 1, let pagerPosition else { return home }
    return pagerPosition
  }

  var playerDescription: [String: Any] {
    guard let stack = sharedPlayer.stack else { return ["made": false] }
    return ["made": true, "x": stack.frame.minX, "y": stack.frame.minY, "width": stack.frame.width, "height": stack.frame.height,
            "hidden": stack.isHidden, "alpha": stack.alphaValue, "driver": pages.first { $0.value === sharedPlayer.driver }?.key ?? NSNull()]
  }

  private func place() {
    guard let host, state != nil, bounds.width > 0 else { return }
    let ids = order
    let at = position
    if ids.contains(host.profileId) { sharedPlayer.driver = page(host.profileId) }
    for (slot, id) in ids.enumerated() {
      let offset = Double(slot) - at
      let shown = abs(offset) < 1 || id == host.profileId && ids.count == 1
      if !shown {
        pages[id]?.isHidden = true
        continue
      }
      let page = page(id)
      let frame = NSRect(x: (offset * bounds.width).rounded(), y: 0, width: bounds.width, height: bounds.height)
      if page.frame != frame { page.frame = frame }
      page.isHidden = false
      if stale.contains(id) { refresh(id) }
      if virtualizesRows { page.reconcileViewport() }
    }
  }

  private func page(_ id: String) -> SidebarView {
    if let page = pages[id] { return page }
    let page = SidebarView(windowId: windowId, favicons: favicons, virtualizesRows: virtualizesRows)
    page.bottomBarHeight = bottomBarHeight
    page.onAction = { [weak self] action in self?.onAction(action) }
    page.onLayoutAnchorsChange = { [weak self] in self?.onLayoutAnchorsChange?() }
    page.isHidden = true
    page.sharedPlayer = sharedPlayer
    pages[id] = page
    stale.insert(id)
    if let stack = sharedPlayer.stack { addSubview(page, positioned: .below, relativeTo: stack) } else { addSubview(page) }
    return page
  }

  private func refresh(_ id: String) {
    guard let state, let host, let page = pages[id] else { return }
    stale.remove(id)
    let pageHost = id == host.profileId ? host : host.pages?.first { $0.profileId == id }.map(host.page) ?? host
    if page.frame.size != bounds.size { page.frame.size = bounds.size }
    page.update(state: state, host: pageHost)
    if let offset = pendingScrollOffsets.removeValue(forKey: id) {
      let clip = page.scroll.contentView
      let bounds = clip.bounds.offsetBy(dx: 0, dy: offset - clip.bounds.minY)
      clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
      page.scroll.reflectScrolledClipView(clip)
    }
  }

  private func scheduleWarm() {
    warm?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped, let host else { return }
      let ids = order
      guard let home = ids.firstIndex(of: host.profileId) else { return }
      for slot in [home - 1, home + 1] where slot >= 0 && slot < ids.count {
        let id = ids[slot]
        _ = page(id)
        if stale.contains(id) { refresh(id) }
      }
    }
    warm = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmDelay, execute: work)
  }
}

@MainActor final class SidebarSharedPlayer {
  unowned let container: NSView
  weak var driver: SidebarView?
  var stack: SidebarPlayerStack?

  init(container: NSView) { self.container = container }
}
