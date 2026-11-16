import AppKit

@MainActor
public final class WindowShellView: NSView {
  public enum Slot: String, CaseIterable, Sendable {
    case backdrop
    case tint
    case react
    case card
    case sidePanel
    case splitChrome
    case peek
    case sidebar
    case topStrip
    case navigation
    case overlay

    static let reactOnTop: [Slot] = [.backdrop, .tint, .card, .sidePanel, .splitChrome, .peek, .sidebar, .topStrip, .react, .navigation, .overlay]
  }

  public static let hoverCoverChanged = Notification.Name("SolaraHoverCoverChanged")

  public let windowId: String
  public let reactOnTop: Bool
  public private(set) var input: DockedLayoutInput
  public private(set) var frames: DockedLayoutFrames
  public var onFrames: ((DockedLayoutFrames) -> Void)?
  public var onLightsLayout: (() -> Void)?
  public var onCaptionLayout: (() -> Void)?
  public var onDetach: (() -> Void)?
  public var onWindow: ((NSWindow?) -> Void)?
  public var onSidePanelChange: ((CGFloat) -> Void)?
  public var onSidePanelSettle: ((CGFloat) -> Void)?
  public let card = FlippedContainerView()
  public let sidePanelClip = FlippedContainerView()
  public let overlay = ShellOverlayView()
  public let hiddenPages = FlippedContainerView()
  public let cardPage = FlippedContainerView()
  public var ownsPaneSlots = false
  public let cardClip = FlippedContainerView()
  public let cardShadow = CardEdgeView(part: .shadow)
  public let cardRim = CardEdgeView(part: .rim)
  public var cardEdgeTint: NSColor? {
    didSet {
      guard cardEdgeTint != oldValue else { return }
      cardShadow.tint = cardEdgeTint
      cardRim.tint = cardEdgeTint
      mounted[.splitChrome]?.needsLayout = true
    }
  }
  public var cardStyle = CardStyle.resting { didSet { if cardStyle != oldValue { applyCardStyle() } } }
  public var cardPageFrame: CGRect? { didSet { if cardPageFrame != oldValue { placeCardPage() } } }
  public var widthDragActive = false
  private var mounted: [Slot: NSView] = [:]
  private var layoutStopped = false
  private let widthMotion = DockAnimator(value: 0)
  private let sidePanelMotion = DockAnimator(value: 0)
  private var sidePanelOpen = false
  private var sidePanelRoom: CGFloat = 0
  private var widthRun: (from: CGFloat, to: CGFloat, railFrom: CGFloat, railTo: CGFloat)?
  private var toolbars: [RailToolbarHome] = []
  private weak var railToolbar: ToolbarView?
  private let railToolbarClip = FlippedContainerView()
  public var fullScreenProfileNameShown = false
  public private(set) var fullScreenStripOffset: CGFloat = 0
  private var fullScreenRevealEnabled = false
  private var fullScreenRevealProgress: CGFloat = 0
  private var fullScreenMenuBottom: CGFloat = 0
  private weak var fullScreenChrome: SidebarChromeView?
  private var fullScreenPaneToolbars: [RailToolbarHome] = []

  public var railFraction: CGFloat { input.railFraction }
  public var fullScreenIconSidebar: Bool { input.windowFullscreen && !input.topTabs && SidebarRail.contains(width: Double(input.sidebarWidth)) }

  public var fullScreenHeaderCanSlide: Bool {
    !input.fullscreen
  }

  public var fullScreenTopInsetFrame: CGRect {
    CGRect(x: frames.card.minX, y: frames.card.minY - ShellMetrics.cardTop + fullScreenStripOffset,
      width: frames.card.width, height: ShellMetrics.cardTop)
  }

  public var fullScreenHeaderRect: CGRect {
    if input.topTabs { return frames.topStrip ?? CGRect(x: 0, y: 0, width: bounds.width, height: ShellMetrics.topStripHeight) }
    let side = frames.sidebar.map { $0.offsetBy(dx: frames.sidebarShift, dy: 0) }
    let center = ShellMetrics.lightsCenter.y
    return CGRect(x: 0, y: center - (ShellMetrics.toolbarHeight + 1) / 2, width: side?.width ?? input.sidebarWidth, height: ShellMetrics.toolbarHeight + 1)
  }

  public func applyFullScreenReveal(fullscreen: Bool, page: Bool, reveal: CGFloat, menuBottom: CGFloat) {
    let enabled = fullscreen && !page
    let progress = enabled ? min(1, max(0, reveal)) : 0
    let changed = enabled != fullScreenRevealEnabled || progress != fullScreenRevealProgress || max(0, menuBottom) != fullScreenMenuBottom
    fullScreenRevealEnabled = enabled
    fullScreenRevealProgress = progress
    fullScreenMenuBottom = max(0, menuBottom)
    if input.windowFullscreen != fullscreen {
      input.windowFullscreen = fullscreen
      relayout()
    } else {
      applyFullScreenStripLayers()
    }
    if changed {
      refreshFullScreenPointer(window?.mouseLocationOutsideOfEventStream)
      coverChanged()
    }
  }

  public func fullScreenPresentationOffset(for view: NSView) -> CGFloat {
    if let chrome = fullScreenChrome, view === chrome.fullScreenHeader || view.isDescendant(of: chrome.fullScreenHeader) { return chrome.fullScreenHeaderOffset }
    for slot: Slot in [.topStrip, .navigation] {
      if let strip = mounted[slot], view === strip || view.isDescendant(of: strip) { return fullScreenStripOffset }
    }
    if view === railToolbarClip || view.isDescendant(of: railToolbarClip) { return fullScreenStripOffset }
    if fullScreenPaneToolbars.contains(where: { home in home.toolbar.map { view === $0 || view.isDescendant(of: $0) } == true }) { return fullScreenStripOffset }
    return 0
  }

  private func applyFullScreenStripLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fullScreenStripOffset = fullScreenRevealEnabled && fullScreenHeaderCanSlide ? fullScreenRevealProgress * fullScreenMenuBottom : 0
    let shift = CATransform3DMakeTranslation(0, fullScreenStripOffset, 0)
    for slot: Slot in [.topStrip, .navigation] {
      mounted[slot]?.wantsLayer = true
      mounted[slot]?.layer?.transform = shift
    }
    railToolbarClip.layer?.transform = shift
    refreshFullScreenPaneToolbars()
    for home in fullScreenPaneToolbars { home.toolbar?.layer?.transform = shift }
    if let sidebar = mounted[.sidebar] {
      if fullScreenChrome?.isDescendant(of: sidebar) != true { fullScreenChrome = findFullScreenChrome(sidebar) }
      fullScreenChrome?.setFullScreenHeaderOffset(fullScreenStripOffset)
    }
    if let navigation = mounted[.navigation] as? SidebarAddressBarView {
      navigation.navigationLeadingInset = input.trafficLightsLeadingInset(at: 0, reveal: fullScreenRevealProgress)
      navigation.needsLayout = true
      navigation.layoutSubtreeIfNeeded()
    }
    if !DockedLayoutInput.reserveFullScreenCaptionSpace, input.reservesCaption {
      for home in toolbars + fullScreenPaneToolbars {
        home.toolbar?.needsLayout = true
        home.toolbar?.layoutSubtreeIfNeeded()
      }
    }
    placeCardSurface()
    CATransaction.commit()
    for home in toolbars + fullScreenPaneToolbars { home.toolbar?.refreshFullScreenAnchors() }
  }

  private func refreshFullScreenPaneToolbars() {
    var found: [RailToolbarHome] = []
    func visit(_ view: NSView) {
      if view is SplitPageContainer { return }
      if let toolbar = view as? ToolbarView {
        if abs(toolbar.convert(toolbar.bounds, to: self).minY - frames.card.minY) < 0.5, let owner = toolbar.superview {
          found.append(RailToolbarHome(toolbar: toolbar, owner: owner))
        }
        return
      }
      for child in view.subviews { visit(child) }
    }
    if input.windowFullscreen { visit(card) }
    for home in fullScreenPaneToolbars where !found.contains(where: { $0.toolbar === home.toolbar }) { home.toolbar?.layer?.transform = CATransform3DIdentity }
    fullScreenPaneToolbars = found
  }

  private func fullScreenPaneToolbarHit(over hit: NSView?, in view: NSView, at point: CGPoint) -> NSView? {
    for home in fullScreenPaneToolbars.reversed() {
      guard let toolbar = home.toolbar, let owner = toolbar.superview, toolbar.isDescendant(of: view), !toolbar.isHiddenOrHasHiddenAncestor,
        let candidate = toolbar.hitTest(owner.convert(point, from: self)) else { continue }
      guard let hit else { return candidate }
      if hit === toolbar || hit.isDescendant(of: toolbar) { return candidate }
      var branch: NSView = toolbar
      while let parent = branch.superview {
        if hit === parent { return candidate }
        if let hitBranch = parent.subviews.first(where: { hit === $0 || hit.isDescendant(of: $0) }) {
          if let toolbarIndex = parent.subviews.firstIndex(of: branch), let hitIndex = parent.subviews.firstIndex(of: hitBranch), toolbarIndex >= hitIndex { return candidate }
          break
        }
        branch = parent
      }
    }
    return nil
  }

  private func findFullScreenChrome(_ view: NSView) -> SidebarChromeView? {
    if let chrome = view as? SidebarChromeView { return chrome }
    for child in view.subviews.reversed() {
      if let chrome = findFullScreenChrome(child) { return chrome }
    }
    return nil
  }

  private func fullScreenStripHit(at point: CGPoint) -> NSView? {
    for view in subviews.reversed() where !view.isHidden {
      let shifted = view === mounted[.topStrip] || view === mounted[.navigation] || view === railToolbarClip
      let source = shifted ? CGPoint(x: point.x, y: point.y - fullScreenStripOffset) : point
      let underlying = view.hitTest(source)
      if !shifted, railToolbarClip.isDescendant(of: view),
        let toolbar = toolbarHit(over: underlying ?? view, at: CGPoint(x: point.x, y: point.y - fullScreenStripOffset)) { return toolbar }
      if !shifted, let toolbar = fullScreenPaneToolbarHit(over: underlying, in: view, at: CGPoint(x: point.x, y: point.y - fullScreenStripOffset)) { return toolbar }
      guard let hit = underlying else { continue }
      let inToolbar = hit.isDescendant(of: railToolbarClip) || fullScreenPaneToolbars.contains { $0.toolbar.map { hit === $0 || hit.isDescendant(of: $0) } == true }
      if !shifted, fullScreenPresentationOffset(for: hit) > 0, inToolbar || mounted[.topStrip].map({ hit === $0 || hit.isDescendant(of: $0) }) == true { continue }
      return hit
    }
    return nil
  }

  public var sidebarPeekCoverage: CGRect? { input.peeking ? frames.sidebarCoverage(in: bounds) : nil }
  public var toolbarRowFrame: CGRect {
    let progress = input.chromeToolbarRow ? railFraction : 0
    return CGRect(x: frames.card.minX * (1 - progress), y: frames.card.minY,
      width: frames.card.width + (bounds.width - frames.card.width) * progress, height: input.toolbarHeight)
  }

  public var trafficLightsLeadingInset: CGFloat {
    trafficLightsLeadingInset(at: toolbarRowFrame.minX)
  }

  public func trafficLightsLeadingInset(at x: CGFloat) -> CGFloat {
    input.trafficLightsLeadingInset(at: x, reveal: fullScreenRevealProgress)
  }

  public func trafficLightsLeadingInset(for view: NSView) -> CGFloat {
    let at = view.convert(CGPoint.zero, to: self)
    return at.x <= frames.card.minX + 0.5 && at.y <= frames.card.minY + 0.5 ? trafficLightsLeadingInset : 0
  }

  public func captionTop(in view: NSView, rect: CGRect? = nil) -> CGFloat { 0 }

  public var pageArea: CGRect { frames.page.offsetBy(dx: -frames.card.minX, dy: -frames.card.minY) }
  public var contentArea: CGRect { CGRect(x: pageArea.minX, y: 0, width: pageArea.width, height: frames.card.height) }
  public var widthMoving: Bool { widthMotion.moving }
  public var sidePanelMoving: Bool { sidePanelMotion.moving }
  private var pointerLayer: ObjectIdentifier?
  private var pendingPointer: NSPoint??
  private var lastPointer: NSPoint?
  private var pointerLink: CADisplayLink?
  #if DEBUG
  public var devSidePanelLinkRunning: Bool { sidePanelMotion.devLinkActive }
  public var devPointerResolved: ((_ changed: Bool) -> Void)?
  public private(set) var devPointerLookups = 0
  public private(set) var devPointerLookupNanos: UInt64 = 0
  #endif
  private var modalOwners: Set<String> = []
  private weak var titlebarWindow: NSWindow?
  private var titlebarAccessibility: [(button: NSButton, cell: NSCell, accessible: Bool, children: [Any]?)] = []

  public override var isFlipped: Bool { true }

  public init(windowId: String, reactOnTop: Bool = false) {
    self.windowId = windowId
    self.reactOnTop = reactOnTop
    input = DockedLayoutInput(size: .zero, dock: 1)
    frames = DockedLayoutFrames.of(input)
    super.init(frame: .zero)
    wantsLayer = true
    widthMotion.onChange = { [weak self] progress in self?.widthMoved(CGFloat(progress)) }
    widthMotion.onSettle = { [weak self] _ in
      guard let self, let run = self.widthRun else { return }
      self.widthRun = nil
      self.input.sidebarWidth = run.to
      self.input.railProgress = nil
      self.relayout()
    }
    sidePanelMotion.onChange = { [weak self] room in
      guard let self else { return }
      self.input.sidePanel = CGFloat(room)
      self.relayout()
      self.onSidePanelChange?(CGFloat(room))
    }
    sidePanelMotion.onSettle = { [weak self] room in self?.onSidePanelSettle?(CGFloat(room)) }
    hiddenPages.isHidden = true
    hiddenPages.autoresizingMask = []
    addSubview(hiddenPages)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
    cardPage.autoresizingMask = []
    cardClip.autoresizingMask = []
    cardClip.wantsLayer = true
    cardClip.layer?.masksToBounds = true
    cardClip.layer?.cornerCurve = .continuous
    applyCardStyle()
    cardClip.addSubview(cardPage)
    card.addSubview(cardShadow)
    card.addSubview(cardClip)
    card.addSubview(cardRim)
    mount(.card, card)
    sidePanelClip.wantsLayer = true
    sidePanelClip.layer?.masksToBounds = true
    mount(.sidePanel, sidePanelClip)
    mount(.overlay, overlay)
    overlay.onChildrenChanged = { [weak self] in self?.coverChanged() }
    railToolbarClip.wantsLayer = true
    railToolbarClip.layer?.masksToBounds = true
    railToolbarClip.layer?.cornerCurve = .continuous
    railToolbarClip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    railToolbarClip.layer?.cornerRadius = cardStyle.radius
    railToolbarClip.isHidden = true
    overlay.addSubview(railToolbarClip)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func view(in slot: Slot) -> NSView? { mounted[slot] }

  @objc public var backgroundColor: NSColor?
  @objc public var drawsWholeWindow: Bool { true }
  @objc public var solara_gatesHover: Bool { true }

  public func mount(_ slot: Slot, _ view: NSView?) {
    if let view, let container = ownedContainer(slot), view !== container {
      assertionFailure("\(slot) is shell-owned: add views inside shell.\(slot), don't mount them")
      NSLog("WindowShellView: a view was mounted in the shell-owned \(slot.rawValue) slot; it goes inside the container instead")
      view.removeFromSuperview()
      container.addSubview(view)
      return
    }
    if view == nil, ownedContainer(slot) != nil { return }
    if let current = mounted[slot], current === view { return }
    if let current = mounted[slot], current !== view {
      if slot == .topStrip || slot == .navigation { current.layer?.transform = CATransform3DIdentity }
      if slot == .sidebar {
        findFullScreenChrome(current)?.setFullScreenHeaderOffset(0)
        fullScreenChrome = nil
      }
      if current.superview === self || current.superview === cardClip { current.removeFromSuperview() }
    }
    if let view, let other = mounted.first(where: { $0.key != slot && $0.value === view })?.key { mounted[other] = nil }
    #if SOLARA_PROBES
    NativeWorkCounters.slotPublishes += 1
    #endif
    mounted[slot] = view
    defer { coverChanged() }
    guard let view else { return }
    view.autoresizingMask = []
    if slot == .react, view.responds(to: Selector(("setBackgroundColor:"))) { view.setValue(nil, forKey: "backgroundColor") }
    let above = stack.drop { $0 != slot }.dropFirst().lazy.compactMap { self.mounted[$0] }.first { $0.superview === self }
    let foreign = subviews.first { subview in subview !== view && subview !== hiddenPages && !mounted.values.contains { $0 === subview } }
    if let above = above ?? foreign { addSubview(view, positioned: .below, relativeTo: above) } else { addSubview(view) }
    place(slot, view)
    applyFullScreenStripLayers()
  }

  private var stack: [Slot] { reactOnTop ? Slot.reactOnTop : Slot.allCases }

  private func ownedContainer(_ slot: Slot) -> NSView? {
    switch slot {
    case .card: card
    case .sidePanel: sidePanelClip
    case .overlay: overlay
    default: nil
    }
  }

  public func slot(of view: NSView) -> Slot? { mounted.first { $0.value === view }?.key }

  public func slot(containing view: NSView) -> Slot? {
    var current: NSView? = view
    while let at = current, at !== self {
      if let slot = slot(of: at) { return slot }
      current = at.superview
    }
    return nil
  }

  public func update(_ change: (inout DockedLayoutInput) -> Void) {
    var next = input
    change(&next)
    guard next != input else { return }
    let width = next.sidebarWidth
    let changedWidth = width != input.sidebarWidth
    let target = widthRun?.to ?? input.sidebarWidth
    let crossing = SidebarRail.contains(width: Double(target)) != SidebarRail.contains(width: Double(width))
    if changedWidth, widthRun != nil || (crossing && window != nil && !next.topTabs && !next.fullscreen && !next.windowFullscreen) {
      next.sidebarWidth = input.sidebarWidth
      next.railProgress = input.railProgress
      input = next
      if width != target { setSidebarWidth(width, animated: true) } else { relayout() }
      return
    }
    input = next
    relayout()
  }

  public func stopLayoutMotion() {
    guard !layoutStopped else { return }
    layoutStopped = true
    widthMotion.stop()
    widthRun = nil
    sidePanelMotion.stop()
    stopPointerLink()
    widthDragActive = false
    applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
  }

  public func setSidebarWidth(_ width: CGFloat, animated: Bool) {
    guard !layoutStopped else { return }
    let targetRail: CGFloat = SidebarRail.contains(width: Double(width)) ? 1 : 0
    guard animated, !input.topTabs, !input.fullscreen, !input.windowFullscreen, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      widthMotion.stop()
      widthRun = nil
      input.sidebarWidth = width
      input.railProgress = nil
      return relayout()
    }
    if widthRun?.to == width { return }
    let from = input.sidebarWidth
    let railFrom = railFraction
    widthMotion.stop()
    widthRun = (from, width, railFrom, targetRail)
    widthMotion.jump(to: 0)
    widthMotion.animate(to: 1, curve: .timed(duration: 0.18, ease: .outCubic), in: self)
  }

  public func setSidePanelRoom(_ room: CGFloat, open: Bool, animated: Bool) {
    guard !layoutStopped else { return }
    let room = max(0, room)
    let wasOpen = sidePanelOpen
    let changedRoom = room != sidePanelRoom
    guard open != wasOpen || changedRoom || (!animated && sidePanelMotion.moving) else { return }
    sidePanelOpen = open
    sidePanelRoom = room
    let target = open ? room : 0
    guard animated, !(open && wasOpen && changedRoom), target != input.sidePanel,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      sidePanelMotion.jump(to: Double(target))
      onSidePanelSettle?(target)
      return
    }
    sidePanelMotion.animate(to: Double(target), curve: .timed(duration: SidePanelMetrics.appearDuration, ease: .outCubic), in: self)
  }

  #if DEBUG
  public func devStepSidePanel(by seconds: Double) { sidePanelMotion.step(by: seconds) }
  #endif

  public func stepWidth(by seconds: Double) { widthMotion.step(by: seconds) }

  private func widthMoved(_ progress: CGFloat) {
    guard let run = widthRun else { return }
    input.sidebarWidth = run.from + (run.to - run.from) * progress
    input.railProgress = run.railFrom + (run.railTo - run.railFrom) * progress
    relayout()
  }

  public func registerToolbar(_ toolbar: ToolbarView, owner: NSView) {
    toolbars.removeAll { $0.toolbar == nil || $0.owner == nil }
    if !toolbars.contains(where: { $0.toolbar === toolbar }) { toolbars.append(RailToolbarHome(toolbar: toolbar, owner: owner)) }
    placeRailToolbar()
  }

  public func toolbarSitsOnFrame(_ toolbar: ToolbarView) -> Bool {
    railToolbar === toolbar && railFraction > 0
  }

  public func unregisterToolbar(_ toolbar: ToolbarView) {
    if railToolbar === toolbar {
      railToolbar = nil
      restoreToolbar(toolbar, owner: toolbars.first { $0.toolbar === toolbar }?.owner)
    }
    toolbars.removeAll { $0.toolbar === toolbar }
    placeRailToolbar()
  }

  private func restoreToolbar(_ toolbar: ToolbarView, owner: NSView?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    toolbar.underColor = nil
    if let owner {
      toolbar.autoresizingMask = [.width, .height]
      owner.addSubview(toolbar)
      toolbar.frame = owner.bounds
      toolbar.needsLayout = true
      toolbar.layoutSubtreeIfNeeded()
    } else {
      toolbar.removeFromSuperview()
    }
    toolbar.onGeometryChange()
  }

  private func placeRailToolbar() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let home = toolbars.last {
      $0.toolbar?.state?.focused == true
        && (railFraction > 0 || $0.toolbar?.state?.windowToolbar == true || ($0.toolbar?.state?.bare == true && $0.toolbar?.state?.inSplit != true))
        && $0.toolbar?.isHidden == false && $0.owner?.windowShell === self && $0.owner?.isHiddenOrHasHiddenAncestor == false
    }
    if railToolbar !== home?.toolbar {
      if let current = railToolbar {
        railToolbar = nil
        restoreToolbar(current, owner: toolbars.first { $0.toolbar === current }?.owner)
      }
      railToolbar = home?.toolbar
      if let toolbar = railToolbar {
        toolbar.autoresizingMask = []
        railToolbarClip.addSubview(toolbar)
      }
    }
    if railToolbar != nil, railFraction == 0, reactOnTop, let owner = home?.owner {
      if railToolbarClip.superview !== owner { owner.addSubview(railToolbarClip) }
    } else if railToolbar != nil, railFraction == 0 {
      if let above = [Slot.peek, .sidebar, .topStrip, .overlay].compactMap({ mounted[$0] }).first(where: { $0.superview === self }) {
        let index = subviews.firstIndex(of: above)
        let below = index.flatMap { $0 > 0 ? subviews[$0 - 1] : nil }
        if below !== railToolbarClip { addSubview(railToolbarClip, positioned: .below, relativeTo: above) }
      }
    } else if railToolbarClip.superview !== overlay {
      overlay.addSubview(railToolbarClip)
    }
    railToolbarClip.isHidden = railToolbar == nil || modalShown
    let row = toolbarRowFrame
    railToolbarClip.frame = railToolbarClip.superview?.convert(row, from: self) ?? row
    if let toolbar = railToolbar {
      let height = min(frames.card.height, input.toolbarHeight)
      toolbar.frame = CGRect(x: 0, y: 0, width: row.width, height: height)
      toolbar.needsLayout = true
      toolbar.layoutSubtreeIfNeeded()
      toolbar.onGeometryChange()
    }
    applyCardStyle()
    applyFullScreenStripLayers()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    relayout()
  }

  public override func layout() {
    super.layout()
    relayout()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { TabSlots.shared.remove(.card(windowId), container: cardPage) } else if !ownsPaneSlots { TabSlots.shared.set(.card(windowId), container: cardPage) }
    if window == nil {
      stopPointerLink()
      widthMotion.stop()
      if sidePanelMotion.moving {
        let target = CGFloat(sidePanelMotion.target)
        sidePanelMotion.jump(to: Double(target))
        onSidePanelSettle?(target)
      }
      if let run = widthRun {
        widthRun = nil
        input.sidebarWidth = run.to
        input.railProgress = nil
        relayout()
      }
    }
    syncTitlebarAccessibility()
    onWindow?(window)
    onCaptionLayout?()
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onCaptionLayout?()
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if superview == nil { onDetach?() }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    if fullScreenRevealEnabled, fullScreenStripOffset > 0 { return fullScreenStripHit(at: convert(point, from: superview)) }
    let hit = super.hitTest(point)
    if let hit, let toolbar = toolbarHit(over: hit, at: convert(point, from: superview)) { return toolbar }
    return hit === self ? nil : hit
  }

  private func toolbarHit(over hit: NSView, at point: NSPoint) -> NSView? {
    guard reactOnTop, railFraction == 0,
      let root = mounted[.react],
      let toolbar = railToolbar, let owner = toolbars.first(where: { $0.toolbar === toolbar })?.owner,
      railToolbarClip.superview === owner,
      let candidate = railToolbarClip.hitTest(owner.convert(point, from: self)) else { return nil }
    if hit === self { return candidate }
    if hit !== root, !hit.isDescendant(of: root) {
      var branch = hit
      while let parent = branch.superview, parent !== self { branch = parent }
      guard let hitIndex = subviews.firstIndex(of: branch), let rootIndex = subviews.firstIndex(of: root), hitIndex < rootIndex else { return nil }
      return candidate
    }
    var branch = owner
    while let parent = branch.superview {
      if hit === parent { return candidate }
      if let hitBranch = parent.subviews.first(where: { hit === $0 || hit.isDescendant(of: $0) }) {
        guard let ownerIndex = parent.subviews.firstIndex(of: branch), let hitIndex = parent.subviews.firstIndex(of: hitBranch) else { return nil }
        return ownerIndex >= hitIndex ? candidate : nil
      }
      branch = parent
    }
    return nil
  }

  public var modalShown: Bool { !modalOwners.isEmpty }

  public func setModal(_ owner: String, shown: Bool) {
    let before = modalShown
    if shown { modalOwners.insert(owner) } else { modalOwners.remove(owner) }
    guard modalShown != before else { return }
    placeRailToolbar()
    syncTitlebarAccessibility()
    NSAccessibility.post(element: self, notification: .layoutChanged)
  }

  private func syncTitlebarAccessibility() {
    for entry in titlebarAccessibility {
      entry.cell.setAccessibilityElement(entry.accessible)
      entry.button.setAccessibilityChildren(entry.children)
    }
    if let titlebarWindow { NSAccessibility.post(element: titlebarWindow, notification: .layoutChanged) }
    titlebarAccessibility.removeAll()
    titlebarWindow = nil
    guard modalShown, let window else { return }
    titlebarWindow = window
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = window.standardWindowButton(kind), let cell = button.cell else { continue }
      titlebarAccessibility.append((button, cell, cell.isAccessibilityElement(), button.accessibilityChildren()))
      cell.setAccessibilityElement(false)
      button.setAccessibilityChildren([])
    }
    NSAccessibility.post(element: window, notification: .layoutChanged)
  }

  private var modalLayers: [NSView]? {
    guard modalShown, let root = mounted[.react], root.superview === self else { return nil }
    return overlay.superview === self && !overlay.isHidden ? [root, overlay] : [root]
  }

  public override func accessibilityChildren() -> [Any]? {
    guard let modalLayers else { return super.accessibilityChildren() }
    return NSAccessibility.unignoredChildren(from: modalLayers)
  }

  public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    guard let modalLayers, let root = modalLayers.first else { return super.accessibilityHitTest(point) }
    if modalLayers.contains(where: { $0 === overlay }), let window, overlay.hitTest(convert(window.convertPoint(fromScreen: point), from: nil)) != nil {
      return overlay.accessibilityHitTest(point)
    }
    return root.accessibilityHitTest(point)
  }

  public override func mouseMoved(with event: NSEvent) { notePointer(event.locationInWindow) }
  public override func mouseEntered(with event: NSEvent) { notePointer(event.locationInWindow) }
  public override func mouseExited(with event: NSEvent) { notePointer(nil) }

  public func coverChanged() {
    if reactOnTop, let pointerLink {
      pendingPointer = .some(lastPointer)
      pointerLink.isPaused = false
      return postCoverChanged()
    }
    if !resolvePointer(lastPointer) { postCoverChanged() }
  }

  private func postCoverChanged() {
    NotificationCenter.default.post(name: Self.hoverCoverChanged, object: self)
  }

  public var pointerSlot: Slot? {
    pointerLayer.flatMap { layer in mounted.first { ObjectIdentifier($0.value) == layer }?.key }
  }

  public func slotUnderPointer(at pointInWindow: NSPoint) -> Slot? {
    layerUnderPointer(at: pointInWindow).flatMap(slot(of:))
  }

  private func layerUnderPointer(at pointInWindow: NSPoint) -> NSView? {
    let point = convert(pointInWindow, from: nil)
    if fullScreenRevealEnabled, fullScreenStripOffset > 0 {
      guard let hit = fullScreenStripHit(at: point) else { return nil }
      return slot(containing: hit).flatMap { mounted[$0] } ?? railToolbarClip
    }
    for layer in subviews.reversed() where !layer.isHidden {
      if layer === mounted[.react], !reactOnTop { return layer.frame.contains(point) ? layer : nil }
      if let hit = layer.hitTest(point) {
        if toolbarHit(over: hit, at: point) != nil { return railToolbarClip }
        if layer === card, let sidebar = mounted[.sidebar], sidebar.superview === cardClip,
          sidebar.hitTest(convert(point, to: cardClip)) != nil { return sidebar }
        return layer
      }
    }
    return nil
  }

  @objc private func devPointer(_ note: Notification) {
    guard let window else { return }
    notePointer((note.object as? NSValue).map { window.convertPoint(fromScreen: $0.pointValue) } ?? window.mouseLocationOutsideOfEventStream)
  }

  private func refreshFullScreenPointer(_ pointInWindow: NSPoint?) {
    guard let window else { return }
    let screen = pointInWindow.map { NSValue(point: window.convertPoint(toScreen: $0)) }
    NotificationCenter.default.post(name: Notification.Name("SolaraFullScreenPointerChanged"), object: screen, userInfo: ["window": window])
  }

  private func notePointer(_ pointInWindow: NSPoint?) {
    guard !layoutStopped else { return }
    if fullScreenRevealEnabled { refreshFullScreenPointer(pointInWindow) }
    lastPointer = pointInWindow
    guard reactOnTop, window != nil else {
      resolvePointer(pointInWindow)
      return
    }
    if let pointerLink, !pointerLink.isPaused {
      pendingPointer = .some(pointInWindow)
      return
    }
    resolvePointer(pointInWindow)
    if let pointerLink { pointerLink.isPaused = false; return }
    let made = displayLink(target: self, selector: #selector(pointerFrame(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(made)
    #endif
    made.add(to: .main, forMode: .common)
    pointerLink = made
  }

  @objc private func pointerFrame(_ link: CADisplayLink) {
    guard let pending = pendingPointer else { link.isPaused = true; return }
    pendingPointer = nil
    resolvePointer(pending)
  }

  private func stopPointerLink() {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(pointerLink)
    #endif
    pointerLink?.invalidate()
    pointerLink = nil
    pendingPointer = nil
  }

  @discardableResult
  private func resolvePointer(_ pointInWindow: NSPoint?) -> Bool {
    #if DEBUG
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    #endif
    let layer = pointInWindow.flatMap(layerUnderPointer(at:)).map(ObjectIdentifier.init)
    let changed = layer != pointerLayer
    #if DEBUG
    devPointerLookups += 1
    devPointerLookupNanos += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
    #endif
    if changed {
      pointerLayer = layer
      postCoverChanged()
    }
    #if DEBUG
    devPointerResolved?(changed)
    #endif
    return changed
  }

  #if DEBUG
  public func devNotePointer(_ pointInWindow: NSPoint?) { notePointer(pointInWindow) }

  public func devPointerFrame() {
    if let pointerLink { pointerFrame(pointerLink) }
  }

  public func devResetPointerStats() {
    devPointerLookups = 0
    devPointerLookupNanos = 0
  }
  #endif

  private func relayout() {
    #if SOLARA_PROBES
    NativeWorkCounters.layoutApplications += 1
    #endif
    input.size = bounds.size
    let next = DockedLayoutFrames.of(input)
    let changed = next != frames
    frames = next
    for (slot, view) in mounted { place(slot, view) }
    if hiddenPages.frame != frames.card { hiddenPages.frame = frames.card }
    placeCardPage()
    placeRailToolbar()
    applyFullScreenStripLayers()
    for view in card.subviews where view is SplitPanesView || view is PaneOverlaysView {
      if view.frame != card.bounds { view.frame = card.bounds }
      view.needsLayout = true
    }
    mounted[.splitChrome]?.needsLayout = true
    onLightsLayout?()
    onCaptionLayout?()
    if changed {
      #if SOLARA_PROBES
      NativeWorkCounters.slotPublishes += 1
      #endif
      coverChanged()
      onFrames?(next)
    }
  }

  private func applyCardStyle() {
    let radius = cardStyle.radius
    let fill = cardStyle.fill?.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    railToolbar?.underColor = nil
    if cardClip.layer?.cornerRadius != radius { cardClip.layer?.cornerRadius = radius }
    if railToolbarClip.layer?.cornerRadius != radius { railToolbarClip.layer?.cornerRadius = radius }
    if cardClip.layer?.backgroundColor != fill { cardClip.layer?.backgroundColor = fill }
    CATransaction.commit()
    placeCardSurface()
  }

  private var cardSurfaceRect: CGRect {
    let baseTop = input.chromeToolbarRow ? min(input.toolbarHeight * railFraction, frames.card.height) : 0
    let top = min(frames.card.height, baseTop + fullScreenStripOffset)
    return CGRect(x: 0, y: top, width: frames.card.width, height: max(0, frames.card.height - top))
  }

  private func placeCardSurface() {
    let rect = cardSurfaceRect
    if cardClip.frame != rect { cardClip.frame = rect }
    if cardClip.bounds != rect { cardClip.bounds = rect }
    placeCardEdge()
  }

  private func placeCardEdge() {
    let rect = cardSurfaceRect
    let strength: CGFloat = cardStyle.edge && !input.fullscreen && cardStyle.radius > 0 ? 1 : 0
    let radius = cardStyle.radius
    cardShadow.place(rect, radius: radius, strength: strength)
    cardRim.place(rect, radius: radius, strength: strength, topEdge: !input.topTabs)
  }

  private func placeCardPage() {
    let page = pageArea
    let top = min(max(cardPageFrame?.minY ?? page.minY, page.minY), page.maxY)
    let vertical = cardPageFrame ?? page
    let caption = captionTop(in: card)
    let requestedTop = railFraction > 0 ? top : vertical.minY
    let actualTop = caption > 0 ? max(caption, requestedTop) : requestedTop
    let bottom = railFraction > 0 ? page.maxY : vertical.maxY
    let frame = input.alignFrame(CGRect(
      x: page.minX, y: actualTop, width: page.width,
      height: max(0, bottom - actualTop)))
    if cardPage.frame != frame { cardPage.frame = frame }
    placeCardSurface()
    if railFraction > 0 { cardPage.wantsLayer = true }
    guard let layer = cardPage.layer else { return }
    let radius: CGFloat = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if layer.cornerRadius != radius { layer.cornerRadius = radius }
    layer.cornerCurve = .continuous
    layer.masksToBounds = radius > 0
    CATransaction.commit()
  }

  private func place(_ slot: Slot, _ view: NSView) {
    let frame: CGRect
    switch slot {
    case .backdrop, .tint, .react, .overlay: frame = bounds
    case .card, .splitChrome: frame = frames.card
    case .sidePanel: frame = frames.sidePanel ?? .zero
    case .peek: frame = railFraction > 0 ? frames.page : frames.card
    case .sidebar: frame = (frames.sidebar ?? .zero).offsetBy(dx: frames.sidebarShift, dy: 0)
    case .topStrip: frame = frames.topStrip ?? .zero
    case .navigation:
      frame = CGRect(x: 0, y: ShellMetrics.cardTop, width: bounds.width, height: ShellMetrics.toolbarHeight)
    }
    let local: CGRect
    if slot == .sidebar {
      let parent: NSView = self
      if view.superview !== parent {
        if parent === self {
          let above = stack.drop { $0 != slot }.dropFirst().compactMap { mounted[$0] }.first { $0.superview === self }
          addSubview(view, positioned: .below, relativeTo: above)
        } else {
          parent.addSubview(view)
        }
      }
      local = parent === self ? frame : frame.offsetBy(dx: -frames.card.minX, dy: -frames.card.minY)
    } else {
      local = frame
    }
    if view.frame != local { view.frame = local }
    view.isHidden = (slot == .sidePanel && frames.sidePanel == nil) || (slot == .sidebar && frames.sidebar == nil) || (slot == .topStrip && frames.topStrip == nil) || (slot == .navigation && !input.chromeNavigationRow)
  }
}

public struct CardStyle: Equatable {
  public var fill: NSColor?
  public var radius: CGFloat
  public var edge: Bool

  public init(fill: NSColor?, radius: CGFloat, edge: Bool = true) {
    self.fill = fill
    self.radius = radius
    self.edge = edge
  }

  public static var resting: CardStyle { CardStyle(fill: nil, radius: ShellMetrics.cardRadius) }
}

public struct CardShadowLayer: Equatable, Sendable {
  public var lightOpacity: Double
  public var darkOpacity: Double
  public var radius: CGFloat
  public var drop: CGFloat
}

public enum CardEdgeMetrics {
  public static let rimWidth: CGFloat = 0.5
  public static let lightRim = 0.05
  public static let darkRim = 0.07
  public static let contact = CardShadowLayer(lightOpacity: 0.06, darkOpacity: 0.45, radius: 1.5, drop: 0.5)
  public static let ambient = CardShadowLayer(lightOpacity: 0.07, darkOpacity: 0.32, radius: 18, drop: 6)
  public static let shadows = [contact, ambient]
  public static let lightRimTinted = 0.10

  public static func shadowColor(under tint: NSColor?) -> NSColor {
    guard let base = tint?.usingColorSpace(.sRGB) else { return .black }
    let tinted = min(1, base.saturationComponent / 0.15)
    return NSColor(hue: base.hueComponent, saturation: 0.55 * tinted, brightness: 0.42, alpha: 1)
  }

  public static func rimColor(over tint: NSColor?) -> NSColor {
    guard let base = tint?.usingColorSpace(.sRGB) else { return NSColor.black.withAlphaComponent(lightRim) }
    let tinted = min(1, base.saturationComponent / 0.15)
    return NSColor(hue: base.hueComponent, saturation: 0.35 * tinted, brightness: 0.45, alpha: lightRim + (lightRimTinted - lightRim) * tinted)
  }
}

@MainActor
public final class CardEdgeView: NSView {
  public enum Part { case shadow, rim }
  public let part: Part
  public private(set) var edgeRect = CGRect.zero
  public private(set) var radius: CGFloat = 0
  public private(set) var strength: CGFloat = 0
  public private(set) var topEdge = true
  public var tint: NSColor? { didSet { if tint != oldValue { redraw() } } }
  private let shades = CardEdgeMetrics.shadows.map { _ in CALayer() }
  private let shadowMask = CAShapeLayer()
  private let shadeGroup = CALayer()
  private let rimMask = CAShapeLayer()

  public override var isFlipped: Bool { true }

  public init(part: Part) {
    self.part = part
    super.init(frame: .zero)
    autoresizingMask = []
    wantsLayer = true
    layer?.masksToBounds = false
    shadowMask.fillRule = .evenOdd
    shadeGroup.mask = shadowMask
    rimMask.fillRule = .evenOdd
    let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull(), "shadowOpacity": NSNull(), "path": NSNull(), "frame": NSNull()]
    for each in shades + [shadowMask, shadeGroup, rimMask] { each.actions = still }
    shades.forEach { shadeGroup.addSublayer($0) }
    if part == .shadow { layer?.addSublayer(shadeGroup) }
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    redraw()
  }

  public func place(_ rect: CGRect, radius: CGFloat, strength: CGFloat, topEdge: Bool = true) {
    guard rect != edgeRect || radius != self.radius || strength != self.strength || topEdge != self.topEdge else { return }
    edgeRect = rect
    self.radius = radius
    self.strength = strength
    self.topEdge = topEdge
    redraw()
  }

  private func redraw() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = strength <= 0 || edgeRect.isEmpty
    if frame != edgeRect { frame = edgeRect }
    let bounds = CGRect(origin: .zero, size: edgeRect.size)
    let corner = max(0, min(radius, bounds.width / 2, bounds.height / 2))
    switch part {
    case .shadow:
      let shape = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
      shadeGroup.frame = bounds
      for (shade, look) in zip(shades, CardEdgeMetrics.shadows) {
        shade.frame = bounds
        shade.shadowPath = shape
        shade.shadowColor = (dark ? NSColor.black : CardEdgeMetrics.shadowColor(under: tint)).cgColor
        shade.shadowOpacity = Float((dark ? look.darkOpacity : look.lightOpacity) * strength)
        shade.shadowRadius = look.radius
        shade.shadowOffset = CGSize(width: 0, height: look.drop)
      }
      let outset = (CardEdgeMetrics.shadows.map { $0.radius * 3 + abs($0.drop) }.max() ?? 0) + 4
      let mask = CGMutablePath()
      mask.addRect(bounds.insetBy(dx: -outset, dy: -outset))
      mask.addPath(shape)
      shadowMask.frame = bounds
      shadowMask.path = mask
    case .rim:
      guard let layer else { break }
      layer.cornerRadius = corner
      layer.cornerCurve = .continuous
      layer.borderWidth = CardEdgeMetrics.rimWidth
      let light = CardEdgeMetrics.rimColor(over: tint)
      layer.borderColor = (dark ? NSColor.white.withAlphaComponent(CardEdgeMetrics.darkRim * strength) : light.withAlphaComponent(light.alphaComponent * strength)).cgColor
      if topEdge {
        layer.mask = nil
      } else {
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addRect(CGRect(x: corner, y: 0, width: max(0, bounds.width - corner * 2), height: CardEdgeMetrics.rimWidth.rounded(.up)))
        rimMask.frame = bounds
        rimMask.path = mask
        layer.mask = rimMask
      }
    }
    CATransaction.commit()
  }
}

@MainActor
public final class FlippedContainerView: NSView {
  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
public final class ShellOverlayView: NSView {
  public var onChildrenChanged: (() -> Void)?
  private let turn = OverlayTurn()
  private var watches: [ObjectIdentifier: (hidden: NSKeyValueObservation, frame: NSObjectProtocol)] = [:]

  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    watch(subview)
    changed()
  }

  public override func willRemoveSubview(_ subview: NSView) {
    super.willRemoveSubview(subview)
    unwatch(subview)
    guard superview != nil else { return }
    changed()
  }

  private func changed() {
    guard let onChildrenChanged else { return }
    turn.post(onChildrenChanged)
  }

  private func watch(_ child: NSView) {
    unwatch(child)
    child.postsFrameChangedNotifications = true
    let turn = turn
    let post = { [weak self] in
      MainActor.assumeIsolated {
        guard let changed = self?.onChildrenChanged else { return }
        turn.post(changed)
      }
    }
    let hidden = child.observe(\.isHidden, options: [.new]) { _, _ in post() }
    let frame = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: child, queue: nil) { _ in post() }
    watches[ObjectIdentifier(child)] = (hidden, frame)
  }

  private func unwatch(_ child: NSView) {
    guard let watch = watches.removeValue(forKey: ObjectIdentifier(child)) else { return }
    watch.hidden.invalidate()
    NotificationCenter.default.removeObserver(watch.frame)
  }
}

@MainActor
private final class OverlayTurn {
  private var pending = false

  func post(_ changed: @escaping () -> Void) {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.pending = false
        changed()
      }
    }
  }
}

@MainActor
private final class RailToolbarHome {
  weak var toolbar: ToolbarView?
  weak var owner: NSView?

  init(toolbar: ToolbarView, owner: NSView) {
    self.toolbar = toolbar
    self.owner = owner
  }
}

extension NSView {
  public var windowShell: WindowShellView? {
    var view: NSView? = self
    while let current = view {
      if let shell = current as? WindowShellView { return shell }
      view = current.superview
    }
    return nil
  }
}
