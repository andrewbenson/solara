import AppKit
import SolaraModel
import SolaraStore

public enum SplitLayout {
  public static func panes(split: SplitView?, activeId: String?, fullscreenTab: String?, bounds: CGRect) -> (panes: [String: CGRect], dividers: [SplitDivider]) {
    guard bounds.width > 0, bounds.height > 0 else { return ([:], []) }
    guard let split else {
      guard let id = fullscreenTab ?? activeId else { return ([:], []) }
      return ([id: bounds], [])
    }
    let geometry = ShellGeometry.split(split, width: bounds.width, height: bounds.height)
    let positioned = geometry.panes.mapValues { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) }
    let dividers = geometry.dividers.map { divider in
      var next = divider
      next.rect = next.rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
      return next
    }
    guard let fullscreenTab else { return (positioned, dividers) }
    var panes = positioned
    if split.tabIds.contains(fullscreenTab) { panes[fullscreenTab] = bounds } else { panes = [fullscreenTab: bounds] }
    return (panes, [])
  }

  @MainActor
  static func bounds(in view: NSView, fullscreenTab: String?) -> CGRect {
    guard fullscreenTab == nil, let shell = view.windowShell, shell.railFraction > 0 else { return view.bounds }
    let page = view.convert(shell.pageArea, from: shell.card)
    let fraction = shell.railFraction
    let full = view.bounds
    return CGRect(
      x: page.minX,
      y: full.minY + (page.minY - full.minY) * fraction,
      width: page.width,
      height: max(0, full.height + (page.height - full.height) * fraction))
  }
}

@MainActor
public final class SplitPanesView: NSView {
  public let windowId: String
  public var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  public var cardColor: NSColor = .windowBackgroundColor {
    didSet {
      guard cardColor != oldValue else { return }
      panes.values.forEach { $0.fill = cardColor }
      publishCardStyle()
    }
  }
  public var onCardStyle: (CardStyle) -> Void = { _ in } {
    didSet {
      publishedCardStyle = nil
      publishCardStyle()
    }
  }
  public var pagesPooled = false { didSet { if pagesPooled != oldValue { publishCardStyle() } } }
  public var cardStyle: CardStyle {
    CardStyle(
      fill: pagesPooled && split == nil && fullscreenTab == nil ? cardColor : nil, radius: fullscreenTab == nil ? ShellMetrics.cardRadius : 0,
      edge: split == nil && fullscreenTab == nil)
  }
  private var publishedCardStyle: CardStyle?
  public var small = false { didSet { if small != oldValue { refreshEmpty() } } }
  public var theme = SplitChromeTheme.fallback { didSet { if theme != oldValue { panes.values.forEach { $0.empty?.theme = theme } } } }
  public var favicons: SidebarFavicons?
  public var onToolbarClick: (String, ToolbarClick) -> Void = { _, _ in }
  public var onToolbarAnchors: (String, [String: CGRect]) -> Void = { _, _ in }
  public var onNavigate: (String, String) -> Void = { _, _ in }
  public var onReplace: (String, String) -> Void = { _, _ in }
  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
  private var state: BrowserState?
  private var toolbars: [String: String] = [:]
  private var panes: [String: SplitLeafView] = [:]
  private var liveTops: [String: CGFloat] = [:]
  public var bandHeights: [String: CGFloat] = [:] {
    didSet {
      guard bandHeights != oldValue else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    if !isHidden, let fullscreenTab, let pane = panes[fullscreenTab] { return pane.hitTest(convert(point, from: superview)) }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(state next: BrowserState) {
    guard let window = next.windows[windowId] else { return }
    state = next
    let active = window.activeTabIds[window.profileId]
    let nextSplit = Splits.splitOf(next, active)
    if nextSplit != split || active != activeId {
      split = nextSplit
      activeId = active
      needsLayout = true
    }
    refreshEmpty()
    publishCardStyle()
  }

  public func setFullscreenTab(_ tabId: String?) {
    guard tabId != fullscreenTab else { return }
    fullscreenTab = tabId
    needsLayout = true
    publishCardStyle()
  }

  private func publishCardStyle() {
    let next = cardStyle
    guard next != publishedCardStyle else { return }
    publishedCardStyle = next
    onCardStyle(next)
  }

  public func setToolbars(_ next: [String: String]) {
    toolbars = next
    for (tabId, pane) in panes { pane.setToolbar(next[tabId]) }
  }

  public func setLiveTop(_ top: CGFloat?, tabId: String) {
    guard liveTops[tabId] != top else { return }
    liveTops[tabId] = top
    panes[tabId]?.liveTop = top
  }

  public func container(_ tabId: String) -> NSView? { panes[tabId]?.page }

  public func toolbar(_ tabId: String) -> ToolbarView? { panes[tabId]?.toolbar }

  public func empty(_ tabId: String) -> SplitEmptyStateView? { panes[tabId]?.empty }

  public func sample() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
    let height = window?.contentView?.bounds.height ?? 0
    return panes.mapValues { pane -> [String: Any] in
      let page = pane.page.convert(pane.page.bounds, to: nil)
      return [
        "frame": rect(pane.frame), "page": rect(pane.page.frame), "window": rect(CGRect(x: page.minX, y: height - page.maxY, width: page.width, height: page.height)),
        "toolbar": !pane.toolbar.isHidden, "empty": pane.empty != nil, "hidden": pane.isHidden, "covered": fullscreenTab != nil && pane.layer?.zPosition == 0, "radius": Double(pane.radius),
      ]
    }
  }

  public override func layout() {
    super.layout()
    let area = SplitLayout.bounds(in: self, fullscreenTab: fullscreenTab)
    let rail = fullscreenTab == nil ? windowShell?.railFraction ?? 0 : 0
    if rail > 0 { wantsLayer = true }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.masksToBounds = rail > 0
    layer?.cornerRadius = rail > 0 ? (windowShell?.cardStyle.radius ?? ShellMetrics.cardRadius) * (1 - rail) : 0
    layer?.cornerCurve = .continuous
    CATransaction.commit()
    let rects = split == nil ? [:] : SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: area).panes
    var made = false
    for (tabId, rect) in rects {
      let pane = panes[tabId] ?? { made = true; return make(tabId) }()
      pane.frame = rect
      pane.fullscreen = tabId == fullscreenTab
      pane.layer?.zPosition = pane.fullscreen ? 1 : 0
      pane.railFraction = rail
      pane.toolbarHeight = tabId == fullscreenTab ? 0 : toolbarHeight * (1 - rail)
      pane.liveTop = liveTops[tabId].map { $0 * (1 - rail) }
      pane.band = tabId == fullscreenTab ? 0 : bandHeights[tabId] ?? 0
      if rail > 0, tabId == activeId {
        if pane.toolbar.superview !== self {
          addSubview(pane.toolbar)
        }
        pane.toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight + ShellMetrics.railToolbarTop * rail)
        pane.toolbar.isHidden = !pane.hasToolbar
        pane.toolbar.alphaValue = 1
      } else {
        if pane.toolbar.superview !== pane {
          pane.addSubview(pane.toolbar)
        }
        pane.toolbar.alphaValue = 1 - rail
      }
      let edge: CGFloat = fullscreenTab == nil && window?.styleMask.contains(.fullScreen) != true ? 1 : 0
      pane.edgeShadow.tint = windowShell?.cardEdgeTint
      pane.edgeRim.tint = windowShell?.cardEdgeTint
      pane.edgeShadow.place(rect, radius: pane.radius, strength: edge)
      pane.edgeRim.place(rect, radius: pane.radius, strength: edge)
      pane.needsLayout = true
    }
    for (tabId, pane) in panes where rects[tabId] == nil { drop(tabId, pane) }
    if rail > 0, let activeId, let toolbar = panes[activeId]?.toolbar, toolbar.superview === self, subviews.last !== toolbar {
      addSubview(toolbar, positioned: .above, relativeTo: nil)
    }
    if made { refreshEmpty() }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil else { return }
    for (tabId, pane) in panes { drop(tabId, pane) }
  }

  private func refreshEmpty() {
    guard let state else { return }
    for (tabId, pane) in panes {
      let tab = state.tabs[tabId]
      guard let tab, tab.url.isEmpty, !small else {
        pane.setEmpty(nil)
        continue
      }
      let view = pane.empty ?? {
        let made = SplitEmptyStateView(focused: tabId == activeId)
        made.favicons = favicons
        made.theme = theme
        made.onNavigate = { [weak self] text in self?.onNavigate(tabId, text) }
        made.onReplace = { [weak self] other in self?.onReplace(tabId, other) }
        return made
      }()
      pane.setEmpty(view)
      view.update(SplitEmptyState.suggestions(state, tabId: tabId))
    }
  }

  private func make(_ tabId: String) -> SplitLeafView {
    let pane = SplitLeafView()
    pane.fill = cardColor
    pane.toolbar.onClick = { [weak self] click in self?.onToolbarClick(tabId, click) }
    pane.toolbar.onAnchors = { [weak self] anchors in self?.onToolbarAnchors(tabId, anchors) }
    pane.setToolbar(toolbars[tabId])
    panes[tabId] = pane
    addSubview(pane.edgeShadow)
    addSubview(pane)
    addSubview(pane.edgeRim)
    TabSlots.shared.set(.pane(windowId, tabId), container: pane.page)
    return pane
  }

  private func drop(_ tabId: String, _ pane: SplitLeafView) {
    TabSlots.shared.remove(.pane(windowId, tabId), container: pane.page)
    panes[tabId] = nil
    pane.toolbar.removeFromSuperview()
    pane.edgeShadow.removeFromSuperview()
    pane.edgeRim.removeFromSuperview()
    pane.removeFromSuperview()
  }
}

@MainActor
final class SplitLeafView: NSView {
  let page = SplitPageContainer()
  let edgeShadow = CardEdgeView(part: .shadow)
  let edgeRim = CardEdgeView(part: .rim)
  let toolbar = ToolbarView(frame: .zero)
  private(set) var empty: SplitEmptyStateView?
  private var toolbarJson: String?
  var fullscreen = false {
    didSet {
      guard fullscreen != oldValue else { return }
      layer?.cornerRadius = radius
      layer?.backgroundColor = fullscreen ? nil : fill.cgColor
    }
  }
  var railFraction: CGFloat = 0 {
    didSet { if railFraction != oldValue { layer?.cornerRadius = radius } }
  }
  var radius: CGFloat { fullscreen ? 0 : ShellMetrics.cardRadius }
  var hasToolbar: Bool { toolbarJson != nil }
  var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  var band: CGFloat = 0 {
    didSet {
      guard band != oldValue else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }
  var liveTop: CGFloat? {
    didSet {
      guard liveTop != oldValue else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }
  var fill: NSColor = .windowBackgroundColor { didSet { if !fullscreen { layer?.backgroundColor = fill.cgColor } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = fill.cgColor
    addSubview(page)
    toolbar.isHidden = true
    addSubview(toolbar)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setToolbar(_ json: String?) {
    guard json != toolbarJson else { return }
    toolbarJson = json
    guard let json, let state = ToolbarState.decode(json) else {
      toolbar.isHidden = true
      return
    }
    toolbar.update(state)
    toolbar.isHidden = toolbar.superview === self && toolbarHeight == 0
  }

  func setEmpty(_ view: SplitEmptyStateView?) {
    guard view !== empty else { return }
    empty?.removeFromSuperview()
    empty = view
    if let view { addSubview(view, positioned: .above, relativeTo: page) }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    if toolbar.superview === self {
      toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)
      toolbar.isHidden = toolbarHeight == 0 || toolbarJson == nil
    }
    let pageTop = min((liveTop.map { min(max(0, $0), bounds.height) } ?? toolbarHeight) + max(0, band), bounds.height)
    page.frame = CGRect(x: 0, y: pageTop, width: bounds.width, height: max(0, bounds.height - pageTop))
    empty?.frame = page.frame
  }
}

@MainActor
final class SplitPageContainer: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
