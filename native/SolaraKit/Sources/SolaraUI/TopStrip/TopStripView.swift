import AppKit
import SolaraModel

@MainActor
public final class TopStripView: NSView {
  public let windowId: String
  public let favicons = SidebarFavicons()
  public var onAction: (StripAction) -> Void = { _ in }
  public weak var dragBridge: StripDragBridge? {
    didSet { for page in pages.values { page.dragBridge = dragBridge } }
  }

  private var pages: [String: StripPageView] = [:]
  private var state: BrowserState?
  private var host: StripHostState?
  private var pagerPosition: Double?
  private lazy var dropZone = StripDropZone(strip: self)
  public var takesDrops = true

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    NotificationCenter.default.addObserver(self, selector: #selector(heavyChanged), name: HeavyTabs.changed, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func heavyChanged() {
    guard let state, let host else { return }
    update(state: state, host: host)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil || !takesDrops {
      TabDragSession.unregister(dropZone)
    } else {
      TabDragSession.register(dropZone, windowId: windowId, priority: .insert)
    }
  }

  public var current: StripPageView? { host.flatMap { pages[$0.profileId] } }

  public static let shown = Notification.Name("SolaraTopStripShown")
  private var shownKey: String?

  public func update(state: BrowserState, host: StripHostState) {
    self.state = state
    if self.host?.profileId != host.profileId, let pagerPosition, abs(pagerPosition - pagerPosition.rounded()) < 0.001 { self.pagerPosition = nil }
    self.host = host
    for id in pages.keys where !order.contains(id) {
      pages[id]?.removeFromSuperview()
      pages[id] = nil
    }
    place(refresh: true)
    let key = current?.shownKey
    defer { shownKey = key }
    if shownKey != nil, key != shownKey, !isHiddenOrHasHiddenAncestor { NotificationCenter.default.post(name: Self.shown, object: self) }
  }

  public func setPagerPosition(_ position: Double) {
    pagerPosition = position
    place(refresh: false)
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { place(refresh: true) }
  }

  private var order: [String] {
    guard let host else { return [] }
    guard let looks = host.pages, let state else { return [host.profileId] }
    let paged = Set(looks.map(\.profileId))
    let ids = state.profileOrder.filter { paged.contains($0) }
    return ids.contains(host.profileId) ? ids : [host.profileId]
  }

  private var position: Double {
    let ids = order
    let home = Double(ids.firstIndex(of: host?.profileId ?? "") ?? 0)
    guard ids.count > 1, let pagerPosition else { return home }
    return pagerPosition
  }

  private var flare: CGFloat { host?.floating == true ? 0 : StripMetrics.flare }

  private func place(refresh: Bool) {
    guard let host, let state, bounds.width > 0 else { return }
    let ids = order
    let at = position
    let pageWidth = host.pageWidth > 0 ? CGFloat(host.pageWidth) : max(0, bounds.width - flare * 2)
    let width = pageWidth + flare * 2
    for (slot, id) in ids.enumerated() {
      let offset = Double(slot) - at
      let shown = abs(offset) < 1 || ids.count == 1
      if !shown {
        pages[id]?.isHidden = true
        continue
      }
      let page = page(id)
      let frame = NSRect(x: (offset * width).rounded(), y: 0, width: width, height: bounds.height)
      let resized = page.frame.size != frame.size || page.pageWidth != pageWidth
      if page.frame != frame { page.frame = frame }
      page.pageWidth = pageWidth
      page.isHidden = false
      if refresh || resized {
        let look = id == host.profileId ? host : host.pages?.first { $0.profileId == id }.map(host.page) ?? host
        page.update(state: state, host: look, current: id == host.profileId)
      }
    }
  }

  private func page(_ id: String) -> StripPageView {
    if let page = pages[id] { return page }
    let page = StripPageView(windowId: windowId, profileId: id, favicons: favicons)
    page.onAction = { [weak self] action in self?.onAction(action) }
    page.dragBridge = dragBridge
    page.isHidden = true
    pages[id] = page
    addSubview(page)
    return page
  }
}
