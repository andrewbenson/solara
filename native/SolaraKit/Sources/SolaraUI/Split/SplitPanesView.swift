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
public final class SplitPanesView: FrameLayoutView {
  public let windowId: String
  private weak var chromeToolbar: ToolbarView?
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
  public var onToolbarGeometryChange: (String) -> Void = { _ in }
  public var onNavigate: (String, String) -> Void = { _, _ in }
  public var onReplace: (String, String) -> Void = { _, _ in }
  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
  private var state: BrowserState?
  private var toolbars: [String: String] = [:]
  private var panes: [String: SplitLeafView] = [:]
  private var liveTops: [String: CGFloat] = [:]
  private var installed: WindowLayoutSnapshot?
  private var stopped = false
  private var singlePage: NSView?
  #if DEBUG || SOLARA_PROBES
  private(set) var placementLayoutPasses = 0
  #endif

  public func install(_ snapshot: WindowLayoutSnapshot, state: BrowserState) {
    guard !stopped, snapshot.input.windowId == windowId else { return }
    TabSlots.shared.performBatch {
      let placementChanged = installed.map { !$0.input.hasSameLayout(as: snapshot.input) } ?? true
      reuseSinglePane(snapshot)
      installed = snapshot
      update(state: state)
      setFullscreenTab(snapshot.fullscreenTabId)
      let nextFrame = CGRect(origin: .zero, size: snapshot.frames.card.size)
      if frame != nextFrame { frame = nextFrame }
      if placementChanged { needsLayout = true }
      if needsLayout {
        layoutFrameIfNeeded()
      } else {
        for pane in panes.values { pane.layoutNativeContentIfNeeded() }
      }
      for pane in panes.values {
        pane.edgeShadow.tint = windowShell?.cardEdgeTint
        pane.edgeRim.tint = windowShell?.cardEdgeTint
      }
      if snapshot.input.split == nil, let id = snapshot.input.selectedTabId, let container = panes[id]?.page {
        if let singlePage, singlePage !== container { TabSlots.shared.remove(.card(windowId), container: singlePage) }
        singlePage = container
        TabSlots.shared.set(.card(windowId), container: container)
      } else if let singlePage {
        TabSlots.shared.remove(.card(windowId), container: singlePage)
        self.singlePage = nil
      }
    }
  }

  private func reuseSinglePane(_ snapshot: WindowLayoutSnapshot) {
    guard let previous = installed, previous.input.split == nil, snapshot.input.split == nil,
      previous.fullscreenTabId == nil, snapshot.fullscreenTabId == nil,
      let oldId = previous.input.selectedTabId, let nextId = snapshot.input.selectedTabId, oldId != nextId,
      panes.count == 1, let pane = panes[oldId], snapshot.panes[nextId] != nil else { return }
    pane.rebindForNextTab()
    TabSlots.shared.remove(.pane(windowId, oldId), container: pane.page)
    panes[oldId] = nil
    panes[nextId] = pane
    bind(pane, tabId: nextId)
    TabSlots.shared.set(.pane(windowId, nextId), container: pane.page)
  }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    if let singlePage { TabSlots.shared.remove(.card(windowId), container: singlePage) }
    singlePage = nil
    for (tabId, pane) in panes { drop(tabId, pane) }
    installed = nil
    removeFromSuperview()
  }
  public var bandHeights: [String: CGFloat] = [:] {
    didSet {
      guard bandHeights != oldValue else { return }
      needsLayout = true
      layoutFrameIfNeeded()
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
      let viewport = pane.page.frame
      let left = max(pane.bounds.minX, viewport.minX)
      let top = max(pane.bounds.minY, viewport.minY)
      let visible = installed == nil ? viewport : CGRect(x: left, y: top,
        width: max(0, min(pane.bounds.maxX, viewport.maxX) - left), height: max(0, min(pane.bounds.maxY, viewport.maxY) - top))
      let page = pane.convert(visible, to: nil)
      let renderer = pane.page.convert(pane.page.bounds, to: nil)
      return [
        "frame": rect(pane.frame), "page": rect(visible), "window": rect(CGRect(x: page.minX, y: height - page.maxY, width: page.width, height: page.height)),
        "viewport": rect(viewport), "viewportWindow": rect(CGRect(x: renderer.minX, y: height - renderer.maxY, width: renderer.width, height: renderer.height)),
        "toolbar": !pane.toolbar.isHidden, "empty": pane.empty != nil, "hidden": pane.isHidden, "covered": fullscreenTab != nil && pane.layer?.zPosition == 0, "radius": Double(pane.radius),
      ]
    }
  }

  public override func layout() {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("splitPanesLayout", windowId)
    defer { LayoutTrace.end(trace) }
    #endif
    #if DEBUG || SOLARA_PROBES
    placementLayoutPasses += 1
    #endif
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
    let toolbarOnChrome = windowShell?.input.chromeToolbarRow == true
    if let current = chromeToolbar, !toolbarOnChrome || current !== activeId.flatMap({ panes[$0]?.toolbar }) {
      windowShell?.unregisterToolbar(current)
      chromeToolbar = nil
    }
    let origin = installed?.frames.card.origin ?? .zero
    let rects = installed?.panes.filter { $0.key != installed?.input.peekTabId }.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
      ?? (split == nil ? [:] : SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: area).panes)
    var made = false
    for (tabId, rect) in rects {
      let pane = panes[tabId] ?? { made = true; return make(tabId) }()
      let fullscreen = tabId == fullscreenTab
      let barHeight = installed?.toolbars[tabId]?.height ?? (fullscreen ? 0 : toolbarHeight * (1 - rail))
      let top = liveTops[tabId].map { $0 * (1 - rail) }
      let band = fullscreen ? 0 : bandHeights[tabId] ?? 0
      let page = installed?.pageViewports[tabId]?.offsetBy(dx: -origin.x - rect.minX, dy: -origin.y - rect.minY)
      let bar = installed?.toolbars[tabId]?.offsetBy(dx: -origin.x - rect.minX, dy: -origin.y - rect.minY)
      let liftedToolbar = rail > 0 && tabId == activeId
      let toolbarParentChanged: Bool
      if liftedToolbar, toolbarOnChrome, let shell = windowShell {
        toolbarParentChanged = !shell.toolbarSitsOnFrame(pane.toolbar)
      } else {
        toolbarParentChanged = pane.toolbar.superview !== (liftedToolbar ? self : pane)
      }
      let placementChanged = installed == nil || pane.frame != rect || pane.fullscreen != fullscreen || pane.railFraction != rail
        || pane.toolbarHeight != barHeight || pane.liveTop != top || pane.band != band
        || pane.installedPage != page || pane.installedToolbar != bar || toolbarParentChanged
      if placementChanged {
        pane.performPlacement(deferred: installed != nil) {
          if pane.frame != rect { pane.frame = rect }
          pane.fullscreen = fullscreen
          pane.layer?.zPosition = fullscreen ? 1 : 0
          pane.railFraction = rail
          pane.toolbarHeight = barHeight
          pane.liveTop = top
          pane.band = band
          pane.installedPage = page
          pane.installedToolbar = bar
          if liftedToolbar {
            pane.toolbar.isHidden = !pane.hasToolbar
            pane.toolbar.alphaValue = 1
            if toolbarOnChrome, let shell = windowShell {
              chromeToolbar = pane.toolbar
              shell.registerToolbar(pane.toolbar, owner: self)
            } else {
              if pane.toolbar.superview !== self { addSubview(pane.toolbar) }
              pane.toolbar.frame = installed?.toolbars[tabId]?.offsetBy(dx: -origin.x, dy: -origin.y)
                ?? CGRect(x: 0, y: 0, width: bounds.width, height: windowShell?.input.toolbarHeight ?? toolbarHeight)
            }
          } else {
            if pane.toolbar.superview !== pane { pane.addSubview(pane.toolbar) }
            pane.toolbar.alphaValue = 1 - rail
          }
          pane.needsLayout = true
        }
      }
      let edge: CGFloat = fullscreenTab == nil && installed?.input.windowFullscreen != true && installed?.input.windowFullscreenTransition != true && window?.styleMask.contains(.fullScreen) != true ? 1 : 0
      pane.edgeShadow.tint = windowShell?.cardEdgeTint
      pane.edgeRim.tint = windowShell?.cardEdgeTint
      pane.edgeShadow.place(rect, radius: pane.radius, strength: edge)
      let topTabs = installed?.input.layout.topTabs ?? windowShell?.input.topTabs ?? false
      pane.edgeRim.place(rect, radius: pane.radius, strength: edge, topEdge: split != nil || !topTabs)
      pane.layoutNativeContentIfNeeded()
    }
    for (tabId, pane) in panes where rects[tabId] == nil { drop(tabId, pane) }
    if rail > 0, let activeId, let toolbar = panes[activeId]?.toolbar, toolbar.superview === self, subviews.last !== toolbar {
      addSubview(toolbar, positioned: .above, relativeTo: nil)
    }
    if made {
      refreshEmpty()
      for pane in panes.values { pane.layoutNativeContentIfNeeded() }
    }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil, installed == nil else { return }
    for (tabId, pane) in panes { drop(tabId, pane) }
  }

  private func refreshEmpty() {
    guard let state else { return }
    for (tabId, pane) in panes {
      let tab = state.tabs[tabId]
      guard let tab, tab.url.isEmpty, !small, installed == nil || split != nil else {
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
    bind(pane, tabId: tabId)
    panes[tabId] = pane
    addSubview(pane.edgeShadow)
    addSubview(pane)
    addSubview(pane.edgeRim)
    TabSlots.shared.set(.pane(windowId, tabId), container: pane.page)
    return pane
  }

  private func bind(_ pane: SplitLeafView, tabId: String) {
    pane.toolbar.onClick = { [weak self] click in self?.onToolbarClick(tabId, click) }
    pane.toolbar.onAnchors = { [weak self] anchors in self?.onToolbarAnchors(tabId, anchors) }
    pane.toolbar.onLayoutAnchorsChange = { [weak self] in self?.onToolbarGeometryChange(tabId) }
    pane.setToolbar(toolbars[tabId])
  }

  private func drop(_ tabId: String, _ pane: SplitLeafView) {
    if pane.toolbar === chromeToolbar {
      windowShell?.unregisterToolbar(pane.toolbar)
      chromeToolbar = nil
    }
    TabSlots.shared.remove(.pane(windowId, tabId), container: pane.page)
    panes[tabId] = nil
    pane.toolbar.removeFromSuperview()
    pane.edgeShadow.removeFromSuperview()
    pane.edgeRim.removeFromSuperview()
    pane.removeFromSuperview()
  }
}

@MainActor
final class SplitLeafView: FrameLayoutView {
  let page = SplitPageContainer()
  let edgeShadow = CardEdgeView(part: .shadow)
  let edgeRim = CardEdgeView(part: .rim)
  private(set) var toolbar = ToolbarView(frame: .zero)
  private(set) var empty: SplitEmptyStateView?
  private var toolbarJson: String?
  #if DEBUG || SOLARA_PROBES
  private(set) var placementLayoutPasses = 0
  #endif
  private var installingPlacement = false
  var installedPage: CGRect?
  var installedToolbar: CGRect?
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
      if !installingPlacement { layoutNativeContentIfNeeded() }
    }
  }
  var liveTop: CGFloat? {
    didSet {
      guard liveTop != oldValue else { return }
      needsLayout = true
      if !installingPlacement { layoutNativeContentIfNeeded() }
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

  func layoutNativeContentIfNeeded() {
    layoutFrameIfNeeded()
    toolbar.layoutSubtreeIfNeeded()
    empty?.layoutSubtreeIfNeeded()
  }

  func performPlacement(deferred: Bool, _ install: () -> Void) {
    installingPlacement = deferred
    install()
    installingPlacement = false
  }

  func rebindForNextTab() {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("paneToolbarRebuild")
    defer { LayoutTrace.end(trace) }
    #endif
    toolbar.onHiddenOrDetached()
    toolbar.onHiddenOrDetached = {}
    toolbar.removeFromSuperview()
    toolbar = ToolbarView(frame: .zero)
    toolbar.isHidden = true
    toolbarJson = nil
    addSubview(toolbar)
    setEmpty(nil)
    needsLayout = true
  }

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
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("splitLeafLayout")
    defer { LayoutTrace.end(trace) }
    #endif
    #if DEBUG || SOLARA_PROBES
    placementLayoutPasses += 1
    #endif
    super.layout()
    if toolbar.superview === self {
      toolbar.frame = installedToolbar ?? CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)
      toolbar.isHidden = toolbarHeight == 0 || toolbarJson == nil
    }
    let caption = fullscreen ? 0 : windowShell?.captionTop(in: self) ?? 0
    let pageTop = min(max(caption, liveTop.map { min(max(0, $0), bounds.height) } ?? toolbarHeight) + max(0, band), bounds.height)
    page.frame = installedPage ?? CGRect(x: 0, y: pageTop, width: bounds.width, height: max(0, bounds.height - pageTop))
    empty?.frame = page.frame
  }
}

@MainActor
final class SplitPageContainer: FrameLayoutView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
