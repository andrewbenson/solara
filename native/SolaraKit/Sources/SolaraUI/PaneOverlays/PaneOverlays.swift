import AppKit
import SolaraModel
import SolaraStore

public enum PaneOverlayLayer: Sendable {
  case rn
  case native
}

@MainActor
public final class PaneOverlays {
  public static let shared = PaneOverlays()
  public static let changed = Notification.Name("SolaraPaneOverlaysChanged")

  private var containers: [String: [String: PaneOverlaySlot]] = [:]
  private var windows: [String: WeakOverlays] = [:]

  private var batchDepth = 0
  private var pendingWindows: Set<String> = []

  public init() {}

  public func performBatch(_ install: () -> Void) {
    batchDepth += 1
    install()
    batchDepth -= 1
    guard batchDepth == 0 else { return }
    let windows = pendingWindows.sorted()
    pendingWindows = []
    for windowId in windows { post(windowId, "") }
  }

  public func container(windowId: String, tabId: String, layer: PaneOverlayLayer) -> NSView? {
    containers[windowId]?[tabId].map { layer == .rn ? $0.rn : $0.native }
  }

  public func layer(windowId: String) -> NSView? { windows[windowId]?.view }

  func slot(_ windowId: String, _ tabId: String) -> PaneOverlaySlot? { containers[windowId]?[tabId] }

  public func setLiveTop(_ top: CGFloat?, windowId: String, tabId: String) {
    windows[windowId]?.view?.setLiveTop(top, tabId: tabId)
  }

  func setWindow(_ windowId: String, _ view: PaneOverlaysView?) {
    guard windows[windowId]?.view !== view else { return }
    windows[windowId] = view.map(WeakOverlays.init)
    post(windowId, "")
  }

  public func tabIds(in windowId: String) -> Set<String> { Set(containers[windowId].map { Array($0.keys) } ?? []) }

  func set(_ windowId: String, _ tabId: String, _ container: PaneOverlaySlot?) {
    guard containers[windowId]?[tabId] !== container else { return }
    containers[windowId, default: [:]][tabId] = container
    if containers[windowId]?.isEmpty == true { containers[windowId] = nil }
    post(windowId, tabId)
  }

  func post(_ windowId: String, _ tabId: String) {
    if batchDepth > 0 { pendingWindows.insert(windowId); return }
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": windowId, "tabId": tabId])
  }
}

@MainActor
final class WeakOverlays {
  weak var view: PaneOverlaysView?
  init(_ view: PaneOverlaysView) { self.view = view }
}

@MainActor
final class PaneOverlaySlot: PaneOverlayLayerView {
  let rn = PaneRootLayerView()
  let native = PaneOverlayLayerView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    for layer in [rn, native] {
      layer.autoresizingMask = [.width, .height]
      addSubview(layer)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    rn.frame = bounds
    native.frame = bounds
  }
}

@MainActor
class PaneOverlayLayerView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class PaneRootLayerView: PaneOverlayLayerView {
  var onEmptied: () -> Void = {}

  override func willRemoveSubview(_ subview: NSView) {
    super.willRemoveSubview(subview)
    if superview != nil, subviews.count == 1 { DispatchQueue.main.async { [weak self] in self?.onEmptied() } }
  }
}

@MainActor
public final class PaneOverlaysView: NSView {
  public let windowId: String
  public private(set) var paneFrames: [String: CGRect] = [:]
  public var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  public var pageTops: [String: CGFloat] = [:] { didSet { if pageTops != oldValue { needsLayout = true } } }
  public var bandHeights: [String: CGFloat] = [:] {
    didSet {
      guard bandHeights != oldValue else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }
  private var bandViews: [String: NSView] = [:]
  public var onCoverChanged: () -> Void = {}
  private var liveTops: [String: CGFloat] = [:]
  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
  private var liveTabs: Set<String> = []
  private var overlays: [String: PaneOverlaySlot] = [:]
  private var installed: WindowLayoutSnapshot?
  private var stopped = false

  public func install(_ snapshot: WindowLayoutSnapshot, state: BrowserState) {
    guard !stopped, snapshot.input.windowId == windowId else { return }
    installed = snapshot
    update(state: state)
    setFullscreenTab(snapshot.fullscreenTabId)
    frame = CGRect(origin: .zero, size: snapshot.frames.card.size)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    for (tabId, overlay) in overlays { drop(tabId, overlay) }
    if PaneOverlays.shared.layer(windowId: windowId) === self { PaneOverlays.shared.setWindow(windowId, nil) }
    installed = nil
    bandViews.values.forEach { $0.removeFromSuperview() }
    bandViews = [:]
    removeFromSuperview()
  }

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(state: BrowserState) {
    guard let window = state.windows[windowId] else { return }
    let active = window.activeTabIds[window.profileId]
    let next = Splits.splitOf(state, active)
    let tabs = Set(window.tabIds)
    if tabs != liveTabs {
      liveTabs = tabs
      needsLayout = true
    }
    guard next != split || active != activeId else { return }
    split = next
    activeId = active
    needsLayout = true
  }

  func setLiveTop(_ top: CGFloat?, tabId: String) {
    guard liveTops[tabId] != top else { return }
    liveTops[tabId] = top
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public func setFullscreenTab(_ tabId: String?) {
    guard tabId != fullscreenTab else { return }
    fullscreenTab = tabId
    needsLayout = true
  }

  public func container(_ tabId: String, layer: PaneOverlayLayer) -> NSView? { overlays[tabId].map { layer == .rn ? $0.rn : $0.native } }

  public func setBand(_ view: NSView?, tabId: String) {
    if let old = bandViews[tabId], old !== view { old.removeFromSuperview() }
    bandViews[tabId] = view
    if let view, view.superview !== self { addSubview(view) }
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    let before = overlays.mapValues { $0.isHidden ? CGRect.null : $0.frame }
    let hiddenBefore = overlays.mapValues(\.isHidden)
    defer {
      if overlays.mapValues({ $0.isHidden ? CGRect.null : $0.frame }) != before { onCoverChanged() }
      for (tabId, overlay) in overlays where hiddenBefore[tabId].map({ $0 != overlay.isHidden }) == true { PaneOverlays.shared.post(windowId, tabId) }
    }
    let area = SplitLayout.bounds(in: self, fullscreenTab: fullscreenTab)
    let rail = fullscreenTab == nil ? windowShell?.railFraction ?? 0 : 0
    let origin = installed?.frames.card.origin ?? .zero
    let rects = installed?.panes.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
      ?? SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: area).panes
    paneFrames = rects
    for (tabId, rect) in rects {
      let overlay = overlays[tabId] ?? make(tabId)
      let caption = tabId == fullscreenTab ? 0 : windowShell?.captionTop(in: self, rect: rect) ?? 0
      let base = min(max(caption, (liveTops[tabId] ?? pageTops[tabId] ?? (tabId == fullscreenTab ? 0 : toolbarHeight)) * (1 - rail)), rect.height)
      let band = tabId == fullscreenTab ? 0 : min(max(0, bandHeights[tabId] ?? 0), rect.height - base)
      let top = base + band
      overlay.frame = installed?.pages[tabId].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        ?? CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: rect.height - top)
      overlay.layoutSubtreeIfNeeded()
      overlay.isHidden = fullscreenTab != nil && tabId != fullscreenTab
      if let view = bandViews[tabId] {
        let nativeBand = installed?.input.pageFacts[tabId]?.band
        let height = min(max(0, nativeBand ?? band), max(0, overlay.frame.minY - rect.minY))
        view.frame = CGRect(x: rect.minX, y: overlay.frame.minY - height, width: rect.width, height: height)
        view.isHidden = height <= 0 || overlay.isHidden
      }
    }
    for (tabId, view) in bandViews where rects[tabId] == nil { view.isHidden = true }
    for (tabId, overlay) in overlays where rects[tabId] == nil {
      if liveTabs.contains(tabId), !overlay.rn.subviews.isEmpty {
        overlay.isHidden = true
      } else {
        drop(tabId, overlay)
      }
    }
  }

  public override func viewDidHide() {
    super.viewDidHide()
    for tabId in overlays.keys { PaneOverlays.shared.post(windowId, tabId) }
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    for tabId in overlays.keys { PaneOverlays.shared.post(windowId, tabId) }
  }

  public func sample() -> [String: Any] {
    let height = window?.contentView?.bounds.height ?? 0
    var rows = overlays.mapValues { overlay -> [String: Any] in
      let r = overlay.convert(overlay.bounds, to: nil)
      return ["window": [r.minX, height - r.maxY, r.width, r.height].map(Double.init), "hidden": overlay.isHiddenOrHasHiddenAncestor, "rn": overlay.rn.subviews.count, "native": overlay.native.subviews.count]
    }
    for tabId in rows.keys { rows[tabId]?["band"] = Double(bandHeights[tabId] ?? 0) }
    return rows
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if superview == nil {
      guard installed == nil else { return }
      for (tabId, overlay) in overlays { drop(tabId, overlay) }
      if PaneOverlays.shared.layer(windowId: windowId) === self { PaneOverlays.shared.setWindow(windowId, nil) }
    } else {
      PaneOverlays.shared.setWindow(windowId, self)
    }
  }

  private func make(_ tabId: String) -> PaneOverlaySlot {
    let overlay = PaneOverlaySlot()
    overlay.rn.onEmptied = { [weak self] in self?.needsLayout = true }
    overlays[tabId] = overlay
    let firstForeign = subviews.first { view in !overlays.values.contains { $0 === view } }
    if let firstForeign { addSubview(overlay, positioned: .below, relativeTo: firstForeign) } else { addSubview(overlay) }
    PaneOverlays.shared.set(windowId, tabId, overlay)
    return overlay
  }

  private func drop(_ tabId: String, _ overlay: PaneOverlaySlot) {
    overlays[tabId] = nil
    overlay.removeFromSuperview()
    if PaneOverlays.shared.slot(windowId, tabId) === overlay { PaneOverlays.shared.set(windowId, tabId, nil) }
  }
}
