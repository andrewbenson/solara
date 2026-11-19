import AppKit

public struct SidebarChromeDot: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var slot: Double?
  public var icon: String?
  public var shortcut: String?
  public var color: String?

  public init(id: String, name: String, slot: Double?, icon: String? = nil, shortcut: String? = nil, color: String? = nil) {
    self.id = id
    self.name = name
    self.slot = slot
    self.icon = icon
    self.shortcut = shortcut
    self.color = color
  }
}

public struct SidebarChromeState: Decodable, Equatable, Sendable {
  public var controls: StripControlsState
  public var downloads: Bool
  public var addressBar: Bool
  public var dark: Bool
  public var theme: [String: String]
  public var dots: [SidebarChromeDot]
  public var savedWidth: Double
  public var currentProfileId: String?
  public var iconsOnly: Bool?
  public var dropOver: Bool
  public var sidebarPosition: String?
  public var windowFullscreen: Bool?
  public var update: SidebarUpdatePillState?

  public var rail: Bool { iconsOnly == true }

  public init(
    controls: StripControlsState, downloads: Bool, addressBar: Bool, dark: Bool, theme: [String: String], dots: [SidebarChromeDot], savedWidth: Double,
    iconsOnly: Bool = false, dropOver: Bool = false, update: SidebarUpdatePillState? = nil, currentProfileId: String? = nil, sidebarPosition: String? = nil,
    windowFullscreen: Bool? = nil
  ) {
    self.controls = controls
    self.downloads = downloads
    self.addressBar = addressBar
    self.dark = dark
    self.theme = theme
    self.dots = dots
    self.savedWidth = savedWidth
    self.currentProfileId = currentProfileId
    self.iconsOnly = iconsOnly
    self.dropOver = dropOver
    self.update = update
    self.sidebarPosition = sidebarPosition
    self.windowFullscreen = windowFullscreen
  }

  public static func decode(_ json: String) -> SidebarChromeState? {
    try? JSONDecoder().decode(SidebarChromeState.self, from: Data(json.utf8))
  }
}

public enum SidebarChromeAction: Equatable, Sendable {
  case profileMenu
  case manageProfiles
  case toggleDownloads
  case switchProfile(String)
  case changeProfileIcon(String, String?)
  case profileIntent(String?)
  case liveWidth(Double?)
  case commitWidth(Double)
  case resetWidth
  case installUpdate
  case iconsOnly(Bool)
}

public enum SidebarChromeMetrics {
  public static let header: CGFloat = 46
  public static let railButton: CGFloat = 28
  public static let railIcon: CGFloat = 20
  public static let railPadding: CGFloat = 4
  public static let railHeader: CGFloat = railPadding + railButton + railPadding
  public static let fieldRow: CGFloat = 34
  public static let footer: CGFloat = 40
  public static let indicatorX = ShellMetrics.railLightsTrailing + 8 - StripControlsLayout.pad
  public static let headerRight: CGFloat = 7
  public static let controlTop: CGFloat = 10
  public static let downloadsBox: CGFloat = 34
  public static let footerDownloadsBottom: CGFloat = (40 - 34) / 2
  public static let inset: CGFloat = 6
  public static let resizeStrip: CGFloat = 4
  public static let dotCell: CGFloat = 28
  public static let minDotGap: CGFloat = 1
  public static let dotBand: CGFloat = 24
  public static let dot: CGFloat = 5
  public static let profileButton: CGFloat = 24
  public static let profileGlyph: CGFloat = 13
  public static let profileOpticalBox: CGFloat = 16
  public static let profileInset: CGFloat = 8
  public static let minWidth: Double = 160
  public static let maxWidth: Double = 400
  public static let defaultWidth: Double = 190

  public static func profileRow(count: Int, available: CGFloat) -> (pitch: CGFloat, visible: CGFloat) {
    let gap = dotCell - profileButton
    guard count > 1, dotCell * CGFloat(count) - gap > available else { return (dotCell, max(0, available)) }
    let fitted = ((available - profileButton) / CGFloat(count - 1) * 2).rounded(.down) / 2
    if fitted >= profileButton + minDotGap { return (fitted, available) }
    let shown = max(1, Int(((available + gap) / dotCell).rounded(.down)))
    return (dotCell, CGFloat(shown) * dotCell - gap)
  }

  public static func headerHeight(addressBar: Bool) -> CGFloat { addressBar ? header + fieldRow : header }

  public static func railHeaderShown(_ state: SidebarChromeState) -> Bool { state.controls.incognito }

  public static func footerRowHeight(_ state: SidebarChromeState) -> CGFloat {
    if state.rail { return (state.dots.isEmpty ? 0 : footer) + (state.downloads ? footer : 0) }
    return !state.dots.isEmpty || (footerDownloads(state) && state.downloads) ? footer : 0
  }

  public static func footerHeight(_ state: SidebarChromeState) -> CGFloat {
    let updateBand = state.rail ? SidebarUpdatePillMetrics.railBand : SidebarUpdatePillMetrics.band
    return footerRowHeight(state) + (state.update == nil ? 0 : updateBand)
  }

  public static func footerDownloads(_ state: SidebarChromeState) -> Bool { state.addressBar || state.rail }

  public static func indicatorLeading(windowFullscreen: Bool) -> CGFloat {
    windowFullscreen ? inset : indicatorX
  }

  public static func indicatorRoom(width: CGFloat, downloads: Bool, windowFullscreen: Bool = false) -> CGFloat {
    width - indicatorLeading(windowFullscreen: windowFullscreen) - headerRight - (downloads ? downloadsBox + 2 : 0)
  }

  public static func dotOpacity(slot: Double?, position: Double, hovered: Bool) -> CGFloat {
    let rest = hovered ? 0.85 : 0.65
    guard let slot else { return rest }
    let distance = min(1, abs(position - slot))
    return CGFloat(1 + (rest - 1) * distance)
  }
}

public enum SidebarResizeMath {
  static let band = 36.0
  static let bandScale = 90.0

  public static func rubberBand(_ width: Double, min: Double = SidebarChromeMetrics.minWidth, max: Double = SidebarChromeMetrics.maxWidth) -> Double {
    if width > max { return max + band * (1 - Foundation.exp(-(width - max) / bandScale)) }
    if width < min { return min - band * (1 - Foundation.exp(-(min - width) / bandScale)) }
    return width
  }

  public static func unstretch(_ width: Double, min: Double = SidebarChromeMetrics.minWidth, max: Double = SidebarChromeMetrics.maxWidth) -> Double {
    let unband = { (stretch: Double) in -bandScale * Foundation.log(1 - Swift.min(stretch, band - 0.01) / band) }
    if width > max { return max + unband(width - max) }
    if width < min { return min - unband(min - width) }
    return width
  }

  public static func clamp(_ width: Double, min: Double = SidebarChromeMetrics.minWidth, max: Double = SidebarChromeMetrics.maxWidth) -> Double {
    Swift.min(max, Swift.max(min, width))
  }

  public static func backOut(_ t: Double, overshoot: Double = 1.2) -> Double {
    let u = 1 - t
    return 1 - u * u * ((overshoot + 1) * u - overshoot)
  }

  public static func live(_ width: Double) -> Double { (width * 2).rounded() / 2 }

  public static let snapIn = SidebarRail.width + 36
  public static let snapOut = SidebarRail.width + 26

  public struct Snap: Equatable, Sendable {
    public var width: Double
    public var rail: Bool
  }

  public static func snap(pointer: Double, fromRail: Bool, saved: Double) -> Snap {
    let rail = Snap(width: SidebarRail.width, rail: true)
    if fromRail {
      guard pointer > snapOut else { return rail }
      return Snap(width: rubberBand(Swift.max(clamp(saved), pointer)), rail: false)
    }
    return pointer < snapIn ? rail : Snap(width: rubberBand(pointer), rail: false)
  }
}

@MainActor
public final class SidebarChromeView: NSView {
  public var onAction: (SidebarChromeAction) -> Void = { _ in }
  public var onBlankMouseDown: (NSEvent) -> Void = { event in event.window?.performDrag(with: event) }
  public let fullScreenHeader = FlippedContainerView()
  public private(set) var fullScreenHeaderOffset: CGFloat = 0
  public var onFullScreenPresentationChange: (() -> Void)?
  private var fullScreenCaptionReserved = false
  public let addressSlot = FlippedContainerView()
  public private(set) var state: SidebarChromeState?

  let indicator = StripProfileIndicator()
  let headerProfile = StripIconButton()
  let headerDownloads = StripIconButton()
  let footerDownloads = StripIconButton()
  let resize = SidebarResizeHandle()
  let updatePill = SidebarUpdatePill()
  private var dots: [SidebarProfileDot] = []
  let profileScroll = SidebarProfileScrollView()
  let profileRow = FlippedContainerView()
  let profileSwitcher = SidebarRailProfileButton()
  let profilePopover = NSPopover()
  private(set) var iconPopover: ProfileIconPopover?
  private var iconProfileId: String?
  private var menuProfileId: String?
  private var railHover: String?
  private let tooltip = SidebarDotTooltip()
  private let dropGlow = CALayer()
  private var pagerPosition: Double?
  private var tracking: NSTrackingArea?
  private weak var fullscreenWindow: NSWindow?
  private var observedWindowFullscreen: Bool?

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    dropGlow.cornerRadius = 10
    dropGlow.cornerCurve = .circular
    dropGlow.borderWidth = 1.5
    dropGlow.opacity = 0
    dropGlow.actions = SurfaceLayer.noActions
    layer?.addSublayer(dropGlow)
    DevPointer.observe(self, #selector(devPointer(_:)))
    fullScreenHeader.wantsLayer = true
    addSubview(fullScreenHeader)
    addressSlot.autoresizingMask = []
    fullScreenHeader.addSubview(addressSlot)
    for button in [headerDownloads, footerDownloads] {
      button.radius = 10
      button.name = "Downloads"
      button.onPress = { [weak self] in self?.onAction(.toggleDownloads) }
      if button === headerDownloads { fullScreenHeader.addSubview(button) } else { addSubview(button) }
    }
    headerProfile.radius = 8
    headerProfile.isHidden = true
    headerProfile.onPress = { [weak self] in
      guard self?.state?.controls.incognito != true else { return }
      self?.onAction(.profileMenu)
    }
    fullScreenHeader.addSubview(headerProfile)
    indicator.onPress = { [weak self] in self?.onAction(.profileMenu) }
    fullScreenHeader.addSubview(indicator)
    profileScroll.documentView = profileRow
    profileScroll.onScroll = { [weak self] in
      guard let self else { return }
      self.tooltip.hide()
      for dot in self.dots { dot.setHovered(false) }
    }
    addSubview(profileScroll)
    profileSwitcher.isHidden = true
    profileSwitcher.onPress = { [weak self] in self?.showProfiles() }
    profileSwitcher.onMenu = { [weak self] in
      guard let self, let profile = self.currentProfile else { return }
      self.showProfileMenu(profile.id, on: self.profileSwitcher)
    }
    profileSwitcher.onHover = { [weak self] inside in
      guard let self, let profile = self.currentProfile else { return }
      if inside { self.tooltip.show(profile.name, shortcut: profile.shortcut, above: self.profileSwitcher) } else { self.tooltip.hide(self.profileSwitcher) }
      self.onAction(.profileIntent(inside ? profile.id : nil))
    }
    addSubview(profileSwitcher)
    profilePopover.behavior = .transient
    profilePopover.animates = false
    updatePill.isHidden = true
    updatePill.onPress = { [weak self] in self?.onAction(.installUpdate) }
    addSubview(updatePill)
    resize.onWidth = { [weak self] action in self?.onAction(action) }
    resize.savedWidth = { [weak self] in self?.state?.savedWidth ?? SidebarChromeMetrics.defaultWidth }
    resize.railShown = { [weak self] in self?.state?.rail ?? false }
    addSubview(resize)
    tooltip.isHidden = true
    addSubview(tooltip)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      tooltip.hide()
      tooltip.removeFromSuperview()
      iconPopover?.close()
      profilePopover.close()
    }
    let center = NotificationCenter.default
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      center.removeObserver(self, name: name, object: fullscreenWindow)
      if let window { center.addObserver(self, selector: #selector(windowFullscreenChanged(_:)), name: name, object: window) }
    }
    fullscreenWindow = window
    observedWindowFullscreen = window?.styleMask.contains(.fullScreen)
    needsLayout = true
  }

  @objc private func windowFullscreenChanged(_ note: Notification) {
    guard let changed = note.object as? NSWindow else { return }
    setWindowFullscreen(note.name == NSWindow.didEnterFullScreenNotification, in: changed)
  }

  func setWindowFullscreen(_ fullscreen: Bool, in changed: NSWindow) {
    guard state?.windowFullscreen == nil, changed === window else { return }
    observedWindowFullscreen = fullscreen
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public var reservesFullScreenCaption: Bool {
    guard let state, !state.addressBar, !state.controls.incognito, state.controls.profiles <= 1 else { return false }
    return windowShell?.input.windowFullscreen ?? state.windowFullscreen ?? observedWindowFullscreen ?? false
  }

  public var toolbarBandBottom: CGFloat {
    let fullscreen = windowShell?.input.windowFullscreen ?? state?.windowFullscreen ?? observedWindowFullscreen ?? false
    return fullscreen ? ShellMetrics.cardTop + ShellMetrics.toolbarHeight : ShellMetrics.railToolbarTop + ShellMetrics.railToolbarHeight
  }

  public func sidebarListTopInset(_ top: CGFloat) -> CGFloat {
    let resting = state?.rail == true ? toolbarBandBottom + headerHeight : top
    guard reservesFullScreenCaption else { return resting }
    return max(resting, SidebarChromeMetrics.header) + fullScreenHeaderOffset
  }

  public func setFullScreenHeaderOffset(_ offset: CGFloat) {
    let reserved = reservesFullScreenCaption
    let changed = offset != fullScreenHeaderOffset || reserved != fullScreenCaptionReserved
    fullScreenHeaderOffset = offset
    fullScreenCaptionReserved = reserved
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fullScreenHeader.layer?.transform = CATransform3DMakeTranslation(0, offset, 0)
    CATransaction.commit()
    for bar in addressSlot.subviews.compactMap({ $0 as? SidebarAddressBarView }) { bar.refreshFullScreenAnchors() }
    if changed { onFullScreenPresentationChange?() }
  }

  public var headerHeight: CGFloat {
    guard let state, state.rail else { return SidebarChromeMetrics.headerHeight(addressBar: state?.addressBar ?? false) }
    return SidebarChromeMetrics.railHeaderShown(state) ? SidebarChromeMetrics.railHeader : 0
  }
  public var footerHeight: CGFloat { state.map(SidebarChromeMetrics.footerHeight) ?? 0 }

  public func update(_ next: SidebarChromeState) {
    guard next != state else { return }
    if next.dropOver != state?.dropOver { fadeDropGlow(to: next.dropOver ? 1 : 0) }
    if next.rail != state?.rail || next.dots != state?.dots || next.currentProfileId != state?.currentProfileId { profilePopover.performClose(nil) }
    if next.rail != state?.rail || next.currentProfileId != state?.currentProfileId || iconProfileId.map({ id in !next.dots.contains { $0.id == id } }) == true {
      iconPopover?.close()
      iconProfileId = nil
      tooltip.hide()
    }
    state = next
    syncDots(next.dots)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public func setPagerPosition(_ next: Double) {
    pagerPosition = next
    paintDots()
  }

  private var position: Double {
    pagerPosition ?? state?.dots.first { $0.id == state?.currentProfileId }?.slot ?? 0
  }

  public var downloadsRect: NSRect? {
    let button = [headerDownloads, footerDownloads].first { !$0.isHidden }
    guard let button, window != nil else { return nil }
    return button.fullScreenRect(button.bounds, to: nil)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    let headerPoint = CGPoint(x: local.x, y: local.y - fullScreenHeaderOffset)
    if fullScreenHeader.frame.contains(headerPoint), let hit = fullScreenHeader.hitTest(headerPoint), hit !== fullScreenHeader { return hit }
    let hit = super.hitTest(point)
    if hit !== self, hit !== fullScreenHeader, hit?.isDescendant(of: fullScreenHeader) != true { return hit }
    return fullScreenHeader.frame.contains(headerPoint) || local.y >= bounds.height - footerHeight ? self : nil
  }

  public override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard fullScreenHeader.frame.contains(CGPoint(x: point.x, y: point.y - fullScreenHeaderOffset)) else { return }
    onBlankMouseDown(event)
  }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func layout() {
    super.layout()
    guard let state else { return }
    func color(_ key: String) -> NSColor { SidebarPalette.parse(state.theme[key]) ?? .clear }
    let width = bounds.width
    let header = headerHeight
    fullScreenHeader.frame = CGRect(x: 0, y: 0, width: width, height: header)
    setFullScreenHeaderOffset(fullScreenHeaderOffset)
    let footer = SidebarChromeMetrics.footerRowHeight(state)
    addressSlot.isHidden = !state.addressBar || state.rail
    addressSlot.frame = NSRect(x: 0, y: 0, width: width, height: header)

    let controls = state.controls
    headerProfile.isHidden = !state.rail || !SidebarChromeMetrics.railHeaderShown(state)
    headerProfile.name = controls.title
    headerProfile.set(
      "person.fill", size: SidebarChromeMetrics.railIcon, weight: .regular,
      color: SidebarPalette.parse(controls.nameColor) ?? color("textPrimary"),
      hover: controls.incognito ? .clear : color("toolbarHover"), pressed: controls.incognito ? .clear : color("toolbarPressed"),
      tooltip: controls.incognito ? nil : "Switch between profiles")
    headerProfile.frame = NSRect(
      x: ((width - SidebarChromeMetrics.railButton) / 2).rounded(), y: SidebarChromeMetrics.railPadding,
      width: SidebarChromeMetrics.railButton, height: SidebarChromeMetrics.railButton)
    let inHeader = !state.addressBar && !state.rail
    let windowFullscreen = state.windowFullscreen ?? observedWindowFullscreen ?? window?.styleMask.contains(.fullScreen) ?? false
    let leadingAtEdge = windowFullscreen || state.sidebarPosition == "right"
    let room = SidebarChromeMetrics.indicatorRoom(width: width, downloads: state.downloads, windowFullscreen: leadingAtEdge)
    let layout = StripControlsLayout.indicator(
      textWidth: StripControlsLayout.nameWidth(controls.title), room: room, incognito: controls.incognito, profiles: controls.profiles)
    let leadingTrim: CGFloat = leadingAtEdge ? 0 : 5
    indicator.leadingPadding = StripControlsLayout.pad - leadingTrim
    indicator.isHidden = !inHeader || !layout.shown
    indicator.set(
      title: controls.title, showName: layout.showName, color: SidebarPalette.parse(controls.nameColor) ?? color("textPrimary"),
      hover: controls.incognito ? .clear : color("tabHover"), pressed: controls.incognito ? .clear : color("tabPressed"), enabled: !controls.incognito,
      tooltip: controls.incognito ? nil : "Switch between profiles")
    indicator.frame = NSRect(
      x: SidebarChromeMetrics.indicatorLeading(windowFullscreen: leadingAtEdge) + leadingTrim, y: SidebarChromeMetrics.controlTop,
      width: layout.shown ? max(0, layout.width - leadingTrim) : 0, height: StripControlsLayout.height)

    let box = SidebarChromeMetrics.downloadsBox
    for button in [headerDownloads, footerDownloads] {
      button.active = controls.downloadsOpen
      button.set(
        "arrow.down.circle", size: 16, weight: .regular, color: color("icon"), hover: color("toolbarHover"), pressed: color("toolbarPressed"),
        tooltip: controls.downloadsOpen ? nil : controls.downloadsTooltip)
    }
    headerDownloads.isHidden = !inHeader || !state.downloads
    headerDownloads.frame = NSRect(x: width - SidebarChromeMetrics.headerRight - box, y: SidebarChromeMetrics.controlTop, width: box, height: box)
    footerDownloads.isHidden = !(SidebarChromeMetrics.footerDownloads(state) && state.downloads)
    footerDownloads.frame = NSRect(
      x: state.rail ? ((width - box) / 2).rounded() : SidebarChromeMetrics.inset,
      y: bounds.height - SidebarChromeMetrics.footerDownloadsBottom - box - (state.rail && !state.dots.isEmpty ? SidebarChromeMetrics.footer : 0), width: box, height: box)

    let leadingRoom = footerDownloads.isHidden ? SidebarChromeMetrics.profileInset : footerDownloads.frame.maxX + SidebarChromeMetrics.profileInset
    let row = SidebarChromeMetrics.profileRow(count: dots.count, available: width - leadingRoom - SidebarChromeMetrics.profileInset)
    let cell = row.pitch
    let rowWidth = max(0, cell * CGFloat(dots.count) - (cell - SidebarChromeMetrics.profileButton))
    let rowTop = bounds.height - (state.rail ? SidebarChromeMetrics.footer : footer) + (SidebarChromeMetrics.footer - SidebarChromeMetrics.dotBand) / 2
    profileScroll.isHidden = state.rail || dots.isEmpty
    profileScroll.frame = NSRect(x: leadingRoom, y: rowTop, width: row.visible, height: SidebarChromeMetrics.dotBand)
    profileScroll.snap = rowWidth > row.visible + 0.5 ? cell : 0
    profileRow.frame = NSRect(x: 0, y: 0, width: max(rowWidth, profileScroll.contentSize.width), height: SidebarChromeMetrics.dotBand)
    let rowLeft = (max(0, min((width - rowWidth) / 2 - leadingRoom, profileRow.bounds.width - rowWidth)) * 2).rounded() / 2
    let background = SidebarPalette.parse(state.theme["windowTint"]) ?? NSColor(white: state.dark ? 0.16 : 0.85, alpha: 1)
    for (index, dot) in dots.enumerated() {
      dot.frame = NSRect(x: rowLeft + cell * CGFloat(index), y: 0, width: SidebarChromeMetrics.profileButton, height: SidebarChromeMetrics.dotBand)
      dot.dark = state.dark
      let neutral = SidebarProfileStyle.neutral(dark: state.dark)
      let isStar = ["star", "star.fill"].contains(ProfileIcons.symbol(dot.icon) ?? "")
      let ink = isStar ? neutral : SidebarPalette.parse(state.dots[index].color) ?? neutral
      dot.ink = SidebarProfileStyle.accessibleInk(ink, background: background, dark: state.dark)
      dot.isHidden = state.rail
      if state.rail { dot.setHovered(false) }
    }
    profileSwitcher.isHidden = !state.rail || dots.isEmpty
    if state.rail, let profile = currentProfile {
      let side = SidebarChromeMetrics.profileButton
      profileSwitcher.frame = NSRect(x: ((width - side) / 2).rounded(), y: rowTop, width: side, height: side)
      let neutral = SidebarProfileStyle.neutral(dark: state.dark)
      let isStar = ["star", "star.fill"].contains(ProfileIcons.symbol(profile.icon) ?? "")
      let ink = SidebarProfileStyle.accessibleInk(isStar ? neutral : SidebarPalette.parse(profile.color) ?? neutral, background: background, dark: state.dark)
      profileSwitcher.set(profile, dark: state.dark, ink: ink)
    } else {
      profilePopover.performClose(nil)
    }
    paintDots()
    revealCurrentProfile()

    updatePill.isHidden = state.update == nil
    if let update = state.update {
      updatePill.set(update, color: color("textPrimary"), dark: state.dark, rail: state.rail)
      let pill = SidebarUpdatePillMetrics.self
      let height = state.rail ? pill.railHeight : pill.height
      let pillWidth = state.rail ? height : max(0, width - pill.sideInset * 2)
      updatePill.frame = NSRect(
        x: state.rail ? ((width - pillWidth) / 2).rounded() : pill.sideInset,
        y: bounds.height - footer - pill.gap - height, width: pillWidth, height: height)
    }

    let resizeTop = state.rail ? header : SidebarChromeMetrics.header
    resize.frame = NSRect(
      x: state.sidebarPosition == "right" ? 0 : width - SidebarChromeMetrics.resizeStrip, y: resizeTop, width: SidebarChromeMetrics.resizeStrip,
      height: max(0, bounds.height - resizeTop))
    tooltip.look(dark: state.dark, panel: color("panel"), border: color("panelBorder"))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let glowTop = state.rail ? header : 44
    dropGlow.frame = NSRect(x: 5, y: glowTop, width: max(0, width - 10), height: max(0, bounds.height - glowTop - 6))
    dropGlow.borderColor = color("accent").cgColor
    dropGlow.backgroundColor = NSColor(white: state.dark ? 1 : 0, alpha: state.dark ? 0.06 : 0.04).cgColor
    CATransaction.commit()
  }

  private func fadeDropGlow(to target: Float) {
    let from = dropGlow.presentation()?.opacity ?? dropGlow.opacity
    dropGlow.removeAnimation(forKey: "fade")
    dropGlow.opacity = target
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = target
    fade.duration = 0.14
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    dropGlow.add(fade, forKey: "fade")
  }

  private func syncDots(_ given: [SidebarChromeDot]) {
    while dots.count > given.count { dots.removeLast().removeFromSuperview() }
    while dots.count < given.count {
      let dot = SidebarProfileDot()
      dot.onPress = { [weak self, weak dot] in
        guard let self, let dot else { return }
        self.tooltip.hide()
        self.onAction(.switchProfile(dot.profileId))
      }
      dot.onHover = { [weak self, weak dot] inside in
        guard let self, let dot else { return }
        if inside { self.tooltip.show(dot.name, shortcut: dot.shortcut, above: dot) } else { self.tooltip.hide(dot) }
        self.paintDots()
        self.onAction(.profileIntent(self.dots.first { $0.hovered && !$0.isHidden }?.profileId))
      }
      dot.onMenu = { [weak self, weak dot] in
        guard let self, let dot else { return }
        self.showProfileMenu(dot.profileId, on: dot)
      }
      profileRow.addSubview(dot)
      dots.append(dot)
    }
    for (dot, info) in zip(dots, given) {
      dot.profileId = info.id
      dot.name = info.name
      dot.slot = info.slot
      dot.icon = info.icon
      dot.shortcut = info.shortcut
    }
  }

  private var currentProfile: SidebarChromeDot? {
    guard let state else { return nil }
    return state.dots.first { $0.id == state.currentProfileId }
      ?? state.dots.min { abs(($0.slot ?? .infinity) - position) < abs(($1.slot ?? .infinity) - position) }
  }

  private func showProfiles() {
    guard let state, !profileSwitcher.isHidden else { return }
    if profilePopover.isShown { return profilePopover.performClose(nil) }
    let width = CGFloat(min(320, max(200, state.savedWidth)))
    tooltip.hide()
    iconPopover?.close()
    let rowsHeight = CGFloat(state.dots.count) * (FolderPanelMetrics.rowHeight + FolderPanelMetrics.rowGap)
    let height = rowsHeight + FolderPanelMetrics.padding * 2 + 66
    let body = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let colors = FolderPanelColors(dark: state.dark, tokens: state.theme)
    body.wantsLayer = true
    body.layer?.backgroundColor = colors.panel.ns.cgColor
    for (index, profile) in state.dots.enumerated() {
      let row = SidebarRailProfileRow(profile: profile, current: profile.id == currentProfile?.id, color: colors.textPrimary.ns)
      row.onChoose = { [weak self] in
        self?.profilePopover.performClose(nil)
        self?.onAction(.switchProfile(profile.id))
      }
      row.onHover = { [weak self] inside in
        guard let self else { return }
        if inside { self.railHover = profile.id } else if self.railHover == profile.id { self.railHover = nil } else { return }
        self.onAction(.profileIntent(self.railHover))
      }
      row.frame = NSRect(
        x: FolderPanelMetrics.padding, y: FolderPanelMetrics.padding + CGFloat(index) * (FolderPanelMetrics.rowHeight + FolderPanelMetrics.rowGap),
        width: width - FolderPanelMetrics.padding * 2, height: FolderPanelMetrics.rowHeight)
      body.addSubview(row)
    }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(400, height)))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = height > 400
    scroll.documentView = body
    for (index, title) in ["Change Icon…", "Manage Profiles…"].enumerated() {
      let button = NSButton(title: title, target: self, action: index == 0 ? #selector(changeCurrentIcon) : #selector(manageProfiles))
      button.isBordered = false
      button.alignment = .left
      button.font = .systemFont(ofSize: 13)
      button.frame = NSRect(x: 12, y: rowsHeight + 12 + CGFloat(index) * 30, width: width - 24, height: 30)
      body.addSubview(button)
    }
    let controller = NSViewController()
    controller.view = scroll
    profilePopover.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
    profilePopover.contentViewController = controller
    profilePopover.contentSize = scroll.frame.size
    if profileSwitcher.window != nil { profilePopover.show(relativeTo: profileSwitcher.bounds, of: profileSwitcher, preferredEdge: state.sidebarPosition == "right" ? .minX : .maxX) }
  }

  func showProfileMenu(_ id: String, on anchor: NSView) {
    tooltip.hide()
    profilePopover.performClose(nil)
    menuProfileId = id
    let menu = NSMenu()
    menu.addItem(withTitle: "Change Icon…", action: #selector(changeMenuIcon), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Manage Profiles…", action: #selector(manageProfiles), keyEquivalent: "").target = self
    if anchor.window != nil { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor) }
  }

  @objc private func changeMenuIcon() {
    guard let menuProfileId else { return }
    showIconPicker(menuProfileId)
  }

  @objc private func changeCurrentIcon() {
    guard let profile = currentProfile else { return }
    showIconPicker(profile.id)
  }

  @objc private func manageProfiles() {
    profilePopover.performClose(nil)
    onAction(.manageProfiles)
  }

  func showIconPicker(_ id: String) {
    guard let state, let profile = state.dots.first(where: { $0.id == id }) else { return }
    profilePopover.performClose(nil)
    tooltip.hide()
    let anchor: NSView
    if profileSwitcher.isHidden, let dot = dots.first(where: { $0.profileId == id }) { anchor = dot } else { anchor = profileSwitcher }
    iconProfileId = id
    let popover = iconPopover ?? ProfileIconPopover()
    iconPopover = popover
    popover.show(profileId: id, current: profile.icon, dark: state.dark,
      tint: SidebarPalette.parse(profile.color) ?? SidebarPalette.parse(state.theme["accent"]) ?? .controlAccentColor,
      relativeTo: anchor.bounds, of: anchor) { [weak self] icon in
        self?.onAction(.changeProfileIcon(id, icon))
      }
  }

  private func paintDots() {
    let selectedId = currentProfile?.id
    for dot in dots {
      dot.selected = pagerPosition.map { progress in
        dot.slot.map { abs(progress - $0) * 13 < 5 } ?? false
      } ?? (dot.profileId == selectedId)
      dot.opacity = SidebarChromeMetrics.dotOpacity(slot: dot.slot, position: position, hovered: dot.hovered)
    }
  }

  private func revealCurrentProfile() {
    guard !profileScroll.isHidden, let dot = dots.first(where: { $0.selected }) else { return }
    let clip = profileScroll.contentView
    let left = min(clip.bounds.minX, dot.frame.minX)
    var origin = max(left, dot.frame.maxX - clip.bounds.width)
    if profileScroll.snap > 0 { origin = (origin / profileScroll.snap).rounded() * profileScroll.snap }
    clip.scroll(to: NSPoint(x: max(0, min(origin, profileRow.bounds.width - clip.bounds.width)), y: 0))
    profileScroll.reflectScrolledClipView(clip)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseMoved(with event: NSEvent) { hover(at: isHitBy(event) ? fullScreenPoint(event.locationInWindow, from: nil) : nil) }
  public override func mouseEntered(with event: NSEvent) { hover(at: isHitBy(event) ? fullScreenPoint(event.locationInWindow, from: nil) : nil) }
  public override func mouseExited(with event: NSEvent) { hover(at: nil) }

  @objc private func devPointer(_ note: Notification) {
    guard DevPointer.inside(self, note), let window, let screen = (note.object as? NSValue)?.pointValue else { return hover(at: nil) }
    hover(at: fullScreenPoint(window.convertPoint(fromScreen: screen), from: nil))
  }

  public func dragCarryProfile(at windowPoint: NSPoint) -> String? {
    let point = fullScreenPoint(windowPoint)
    guard !isHiddenOrHasHiddenAncestor, bounds.contains(point), !profileScroll.isHidden,
      profileScroll.frame.contains(point), let dot = dots.first(where: {
        !$0.isHidden && $0.bounds.contains($0.convert(point, from: self))
      }), dot.profileId != state?.currentProfileId else { return nil }
    return dot.profileId
  }

  private func hover(at point: NSPoint?) {
    let headerPoint = point.map { CGPoint(x: $0.x, y: $0.y - fullScreenHeaderOffset) }
    headerProfile.hovered = headerPoint.map { !headerProfile.isHidden && headerProfile.frame.contains($0) } ?? false
    indicator.hovered = headerPoint.map { !indicator.isHidden && indicator.frame.contains($0) } ?? false
    headerDownloads.hovered = headerPoint.map { !headerDownloads.isHidden && headerDownloads.frame.contains($0) } ?? false
    footerDownloads.hovered = point.map { !footerDownloads.isHidden && footerDownloads.frame.contains($0) } ?? false
    updatePill.hovered = point.map { !updatePill.isHidden && updatePill.frame.contains($0) } ?? false
    profileSwitcher.hovered = point.map { !profileSwitcher.isHidden && profileSwitcher.frame.contains($0) } ?? false
    for dot in dots {
      dot.setHovered(point.map {
        !profileScroll.isHidden && profileScroll.frame.contains($0) && dot.bounds.contains(dot.convert($0, from: self))
      } ?? false)
    }
  }

  public func describe() -> [String: Any] {
    func rect(_ view: NSView) -> [Double] {
      let r = view.convert(view.bounds, to: self)
      return [r.minX, r.minY, r.width, r.height]
    }
    func fill(_ dot: SidebarProfileDot) -> [Double] {
      guard let fill = dot.layer?.backgroundColor, let color = NSColor(cgColor: fill)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
      return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)]
    }
    return [
      "header": headerHeight, "footer": footerHeight,
      "indicator": indicator.isHidden ? NSNull() : rect(indicator),
      "headerProfile": headerProfile.isHidden ? NSNull() : rect(headerProfile),
      "headerProfileHovered": headerProfile.hovered,
      "indicatorHovered": indicator.hovered,
      "headerDownloads": headerDownloads.isHidden ? NSNull() : rect(headerDownloads),
      "footerDownloads": footerDownloads.isHidden ? NSNull() : rect(footerDownloads),
      "resize": rect(resize),
      "update": updatePill.isHidden ? NSNull() : ["text": updatePill.text, "rect": rect(updatePill)],
      "dropGlow": Double(dropGlow.opacity),
      "dots": dots.map { ["id": $0.profileId, "rect": rect($0), "opacity": Double($0.opacity), "glyphOpacity": Double($0.glyph.alphaValue), "fill": fill($0), "icon": ($0.icon as Any?) ?? NSNull(), "selected": $0.selected, "hidden": $0.isHidden] },
      "profileSwitcher": profileSwitcher.isHidden ? NSNull() : ["id": currentProfile?.id ?? "", "rect": rect(profileSwitcher), "icon": (currentProfile?.icon as Any?) ?? NSNull(), "label": currentProfile?.name ?? ""],
      "tooltip": tooltip.isHidden ? NSNull() : ["text": tooltip.text, "shortcut": (tooltip.shortcut as Any?) ?? NSNull(), "rect": rect(tooltip), "alpha": Double(tooltip.alphaValue)],
    ]
  }
}

@MainActor
final class SidebarProfileDot: NSView {
  var profileId = ""
  var name = ""
  var slot: Double?
  var shortcut: String?
  var icon: String? { didSet { repaint() } }
  var onPress: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  var onMenu: (() -> Void)?
  private(set) var hovered = false
  private var pressed = false
  let glyph = SidebarProfileGlyph()
  var dark = false { didSet { repaint() } }
  var ink: NSColor = .black { didSet { repaint() } }
  var opacity: CGFloat = 0.65 { didSet { glyph.alphaValue = pressed || selected ? 1 : opacity } }
  var selected = false { didSet { if selected != oldValue { repaint() } } }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 6
    addSubview(glyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    glyph.frame = bounds
  }

  private func repaint() {
    layer?.backgroundColor = SidebarProfileStyle.fill(dark: dark, selected: selected, hovered: hovered, pressed: pressed).cgColor
    layer?.borderWidth = selected ? 0.5 : 0
    layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08).cgColor
    glyph.set(icon, color: ink, opacity: pressed || selected ? 1 : opacity)
    setAccessibilityValue(NSNumber(value: selected))
  }

  func setHovered(_ inside: Bool) {
    guard inside != hovered else { return }
    hovered = inside
    if !inside { pressed = false }
    repaint()
    onHover?(inside && !pressed)
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
    pressed = true
    onHover?(false)
    repaint()
  }

  override func mouseUp(with event: NSEvent) {
    let choose = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    repaint()
    if choose { onPress?() }
  }

  override func rightMouseDown(with event: NSEvent) { onMenu?() }
  override func isAccessibilityElement() -> Bool { !isHidden }
  override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
  override func accessibilityLabel() -> String? { name }
  override func accessibilityHelp() -> String? { shortcut }
  override func accessibilityPerformPress() -> Bool { onPress?(); return true }
  override func accessibilityPerformShowMenu() -> Bool { onMenu?(); return true }
}

@MainActor
final class SidebarKeycap: NSView {
  var stringValue = "" { didSet { if stringValue != oldValue { needsDisplay = true } } }
  var textColor: NSColor = .labelColor { didSet { if textColor != oldValue { needsDisplay = true } } }
  var font: NSFont = .systemFont(ofSize: 12, weight: .semibold) { didSet { needsDisplay = true } }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var glyphRect: NSRect {
    let text = NSAttributedString(string: stringValue, attributes: [.font: font])
    let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
    let scale = window?.backingScaleFactor ?? 2
    let origin = convert(NSPoint(x: bounds.midX - ink.width / 2, y: bounds.midY - ink.height / 2), to: nil)
    let snapped = convert(NSPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale), from: nil)
    return NSRect(origin: snapped, size: ink.size)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let text = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: textColor])
    let line = CTLineCreateWithAttributedString(text)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let target = glyphRect
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: target.minX - ink.minX, y: target.maxY + ink.minY)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }
}

public enum SidebarDotTooltipMetrics {
  public static let height: CGFloat = 23
  public static let labelFont: CGFloat = 12
  public static let keycapHeight: CGFloat = 16
  public static let keycapFont: CGFloat = 10
  public static let keycapMinWidth: CGFloat = 16
  public static let keycapPadding: CGFloat = 8
  public static let keycapGap: CGFloat = 3
  public static let keycapRadius: CGFloat = 4.5
  public static let leading: CGFloat = 9
  public static let trailing: CGFloat = 9
  public static let keysInset: CGFloat = 3.5
  public static let labelToKeys: CGFloat = 6
  public static let gap: CGFloat = 12

  public static func keycapWidth(_ key: String) -> CGFloat {
    max(keycapMinWidth, (key as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: keycapFont, weight: .semibold)]).width + keycapPadding)
  }
}

@MainActor
final class SidebarDotTooltip: NSView {
  static let delay: TimeInterval = 0.5
  static let fade: TimeInterval = 0.1
  private let ring = CALayer()
  private let plate = CALayer()
  private let glass = NewTabGlassSurface(frame: .zero)
  private var glassApplied: (size: CGSize, dark: Bool)?
  private let label = StripLabel()
  private var keycaps: [SidebarKeycap] = []
  private var shownKeycaps = 0
  private var dark = false
  private(set) var usesGlass = false
  private(set) var shortcut: String?
  private var pending: DispatchWorkItem?
  private weak var anchor: NSView?
  private(set) var text = ""
  #if DEBUG
  var forcedReduceTransparency: Bool?
  #endif

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    let m = SidebarDotTooltipMetrics.self
    ring.actions = SurfaceLayer.noActions
    plate.actions = SurfaceLayer.noActions
    ring.cornerRadius = m.height / 2
    ring.borderWidth = 0.5
    ring.shadowColor = NSColor.black.cgColor
    ring.shadowRadius = 4
    ring.shadowOffset = CGSize(width: 0, height: -1)
    plate.cornerRadius = m.height / 2 - 0.5
    plate.borderWidth = 1
    layer?.addSublayer(ring)
    layer?.addSublayer(plate)
    addSubview(glass)
    label.font = .systemFont(ofSize: m.labelFont, weight: .medium)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var reduceTransparency: Bool {
    #if DEBUG
    if let forcedReduceTransparency { return forcedReduceTransparency }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  var keycapViews: [SidebarKeycap] { Array(keycaps.prefix(shownKeycaps)) }

  func look(dark: Bool, panel: NSColor, border: NSColor) {
    self.dark = dark
    ring.borderColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.12).cgColor
    ring.shadowOpacity = dark ? 0.15 : 0.08
    plate.backgroundColor = (dark ? NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1) : panel).cgColor
    plate.borderColor = border.cgColor
    paint()
  }

  private func paint() {
    usesGlass = !reduceTransparency
    let ink = NSColor(white: dark ? 1 : 0, alpha: 1)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.isHidden = usesGlass
    plate.isHidden = usesGlass
    for keycap in keycaps {
      keycap.textColor = usesGlass ? ink.withAlphaComponent(dark ? 0.9 : 0.75) : (dark ? .white : NSColor(white: 0.2, alpha: 1))
      keycap.layer?.backgroundColor = (usesGlass ? ink.withAlphaComponent(dark ? 0.12 : 0.05) : NSColor(white: dark ? 1 : 0, alpha: dark ? 0.1 : 0.04)).cgColor
      keycap.layer?.borderColor = (usesGlass ? ink.withAlphaComponent(dark ? 0.2 : 0.14) : NSColor(white: dark ? 1 : 0, alpha: 0.16)).cgColor
    }
    CATransaction.commit()
    glass.isHidden = !usesGlass
    label.textColor = ink.withAlphaComponent(usesGlass ? (dark ? 0.92 : 0.85) : 0.85)
    applyGlass()
  }

  private func applyGlass() {
    guard usesGlass, glassApplied?.size != bounds.size || glassApplied?.dark != dark else { return }
    glass.frame = bounds
    glass.apply(frame: bounds, radius: bounds.height / 2, tint: NewTabTheme(dark: dark, tokens: [:]).ntpBarSolid.ns, dark: dark)
    glassApplied = (bounds.size, dark)
  }

  func show(_ text: String, shortcut: String? = nil, above view: NSView) {
    self.shortcut = shortcut
    pending?.cancel()
    anchor = view
    var sidebar = view.superview
    while sidebar != nil, !(sidebar is SidebarChromeView) { sidebar = sidebar?.superview }
    if let parent = view.window?.contentView ?? sidebar ?? view.superview, superview !== parent {
      removeFromSuperview()
      parent.addSubview(self)
    }
    guard !text.isEmpty else { return hide() }
    let work = DispatchWorkItem { [weak self] in self?.appear(text) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
  }

  static func keys(_ shortcut: String?) -> [String] {
    guard let shortcut, !shortcut.isEmpty else { return [] }
    var keys: [String] = []
    var key = ""
    for character in shortcut {
      if "⌃⌥⇧⌘".contains(character) {
        if !key.isEmpty { keys.append(key); key = "" }
        keys.append(String(character))
      } else {
        key.append(character)
      }
    }
    if !key.isEmpty { keys.append(key) }
    return keys
  }

  func hide(_ from: NSView? = nil) {
    if let from, from !== anchor { return }
    pending?.cancel()
    pending = nil
    anchor = nil
    isHidden = true
    alphaValue = 0
  }

  func appear(_ text: String) {
    guard let anchor, let superview else { return }
    var parent = anchor.superview
    while parent != nil, !(parent is SidebarChromeView) { parent = parent?.superview }
    guard let sidebar = parent ?? anchor.superview else { return }
    let m = SidebarDotTooltipMetrics.self
    self.text = text
    label.stringValue = text
    let textWidth = StripControlsLayout.measuredLikeYoga((text as NSString).size(withAttributes: [.font: label.font]).width)
    let keys = Self.keys(shortcut)
    while keycaps.count < keys.count {
      let keycap = SidebarKeycap()
      keycap.font = .systemFont(ofSize: m.keycapFont, weight: .semibold)
      keycap.wantsLayer = true
      keycap.layer?.cornerRadius = m.keycapRadius
      keycap.layer?.borderWidth = 0.5
      addSubview(keycap)
      keycaps.append(keycap)
    }
    for (index, keycap) in keycaps.enumerated() {
      keycap.isHidden = index >= keys.count
      if index < keys.count { keycap.stringValue = keys[index] }
    }
    shownKeycaps = keys.count
    let widths = keys.map(m.keycapWidth)
    let shortcutWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * m.keycapGap
    let windowBounds = sidebar.convert(superview.bounds, from: superview).insetBy(dx: 4, dy: 4)
    var room = windowBounds
    if (sidebar as? SidebarChromeView)?.state?.rail != true {
      room = room.intersection(sidebar.bounds.insetBy(dx: 4, dy: 0))
    }
    let tail = keys.isEmpty ? m.trailing : m.labelToKeys + shortcutWidth + m.keysInset
    let size = NSSize(width: min(room.width, textWidth + m.leading + tail), height: m.height)
    let item = anchor.convert(anchor.bounds, to: sidebar)
    let y = sidebar.isFlipped ? item.minY - m.gap - size.height : item.maxY + m.gap
    let target = NSRect(x: max(room.minX, min((item.midX - size.width / 2).rounded(), room.maxX - size.width)), y: y, width: size.width, height: size.height)
    guard size.width >= shortcutWidth + m.leading + m.keysInset + m.labelToKeys, room.contains(target) else { return hide() }
    let scale = window?.backingScaleFactor ?? 2
    func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    let placed = sidebar.convert(target, to: superview)
    frame = NSRect(x: pixel(placed.minX), y: pixel(placed.minY), width: placed.width, height: placed.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds
    plate.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    CATransaction.commit()
    paint()
    let labelWidth = max(0, size.width - m.leading - tail)
    label.frame = NSRect(x: m.leading, y: 0, width: labelWidth, height: size.height)
    var keyX = size.width - m.keysInset - shortcutWidth
    for (keycap, width) in zip(keycaps, widths) {
      keycap.frame = NSRect(x: pixel(keyX), y: pixel((size.height - m.keycapHeight) / 2), width: pixel(keyX + width) - pixel(keyX), height: m.keycapHeight)
      keyX += width + m.keycapGap
    }
    isHidden = false
    alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fade
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
      animator().alphaValue = 1
    }
  }
}

@MainActor
public final class SidebarResizeHandle: NSView {
  var onWidth: (SidebarChromeAction) -> Void = { _ in }
  var savedWidth: () -> Double = { SidebarChromeMetrics.defaultWidth }
  var railShown: () -> Bool = { false }
  public private(set) var dragging = false
  private var live: Double?
  private var start: Double = 0
  private var fromRail = false
  private var downX: CGFloat = 0
  private var spring: (from: Double, to: Double, began: CFTimeInterval, link: CADisplayLink)?

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { false }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

  private func show(_ width: Double) {
    live = width
    onWidth(.liveWidth(SidebarResizeMath.live(width)))
  }

  private func commit(_ width: Double) {
    live = nil
    dragging = false
    onWidth(.commitWidth(width))
    onWidth(.liveWidth(nil))
  }

  private func commitRail() {
    live = nil
    dragging = false
    onWidth(.iconsOnly(true))
    onWidth(.liveWidth(nil))
  }

  private func snapped(_ event: NSEvent) -> SidebarResizeMath.Snap {
    SidebarResizeMath.snap(pointer: start + Double((windowShell?.input.sidebarSide ?? .left).widthDelta(event.locationInWindow.x - downX)), fromRail: fromRail, saved: savedWidth())
  }

  public override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      stopSpring()
      live = nil
      dragging = false
      return onWidth(railShown() ? .iconsOnly(false) : .resetWidth)
    }
    stopSpring()
    dragging = true
    downX = event.locationInWindow.x
    fromRail = live == nil && railShown()
    start = fromRail ? SidebarRail.width : SidebarResizeMath.unstretch(live ?? savedWidth())
    show(fromRail ? SidebarRail.width : SidebarResizeMath.rubberBand(start))
  }

  public override func mouseDragged(with event: NSEvent) {
    guard dragging else { return }
    show(snapped(event).width)
  }

  public override func mouseUp(with event: NSEvent) {
    guard dragging else { return }
    let snap = snapped(event)
    if snap.rail { return commitRail() }
    let raw = snap.width
    let target = SidebarResizeMath.clamp(raw)
    if raw == target { return commit(target) }
    let link = displayLink(target: self, selector: #selector(step(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(link)
    #endif
    link.add(to: .main, forMode: .common)
    spring = (raw, target, CACurrentMediaTime(), link)
  }

  @objc private func step(_ link: CADisplayLink) {
    guard let spring else { return }
    let t = min(1, (CACurrentMediaTime() - spring.began) / 0.26)
    show(spring.from + (spring.to - spring.from) * SidebarResizeMath.backOut(t))
    if t >= 1 {
      stopSpring()
      commit(spring.to)
    }
  }

  private func stopSpring() {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(spring?.link)
    #endif
    spring?.link.invalidate()
    spring = nil
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil, dragging || spring != nil {
      if spring == nil, let live, SidebarRail.contains(width: live) {
        stopSpring()
        return commitRail()
      }
      let target = spring?.to ?? SidebarResizeMath.clamp(live ?? savedWidth())
      stopSpring()
      commit(target)
    }
  }
}
