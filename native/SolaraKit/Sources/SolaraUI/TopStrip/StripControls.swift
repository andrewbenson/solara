import AppKit
import SolaraModel
import SolaraStore

public struct StripControlsState: Decodable, Equatable, Sendable {
  public var title: String
  public var incognito: Bool
  public var profiles: Int
  public var nameColor: String
  public var downloadsOpen: Bool
  public var downloadsTooltip: String?

  public init(title: String, incognito: Bool, profiles: Int, nameColor: String, downloadsOpen: Bool, downloadsTooltip: String?) {
    self.title = title
    self.incognito = incognito
    self.profiles = profiles
    self.nameColor = nameColor
    self.downloadsOpen = downloadsOpen
    self.downloadsTooltip = downloadsTooltip
  }

  public init(state: BrowserState, window: BrowserWindow, nameColor: String, downloadsHint: String?) {
    self.init(title: window.incognito ? "Incognito" : state.profiles[window.profileId]?.name ?? BrowserState.defaultProfile.name,
      incognito: window.incognito, profiles: state.profileOrder.count, nameColor: nameColor,
      downloadsOpen: state.windowUi[window.id]?.downloadsOpen ?? false,
      downloadsTooltip: downloadsHint.map { "Downloads (\($0))" } ?? "Downloads")
  }
}

public enum StripControlAction: Equatable, Sendable {
  case profileMenu
  case toggleDownloads
}

public struct StripIndicatorLayout: Equatable, Sendable {
  public var shown: Bool
  public var showName: Bool
  public var width: CGFloat
}

public enum StripControlsLayout {
  public static let pad: CGFloat = 9
  public static let height: CGFloat = 34
  public static let minCutName: CGFloat = 52
  public static let iconWidth: CGFloat = 32
  public static let profileRoom: CGFloat = 140
  public static let downloadsBox: CGFloat = 34
  public static let gap: CGFloat = 2
  public static let profileGap: CGFloat = 8
  public static let minimumProfileSlot: CGFloat = 84
  public static let trailingReservation: CGFloat = 84
  public static let rowTop: CGFloat = StripMetrics.mid - 17

  public static func pixelAligned(_ value: CGFloat, backingScale: CGFloat) -> CGFloat {
    let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
    let scaled = value * scale
    let base = floor(scaled)
    let fraction = scaled - base
    if fraction < 0.0001 { return base / scale }
    if abs(fraction - 1) < 0.0001 { return (base + 1) / scale }
    return (base + (fraction > 0.5 || abs(fraction - 0.5) < 0.0001 ? 1 : 0)) / scale
  }

  public static func indicator(textWidth: CGFloat, room: CGFloat = profileRoom, incognito: Bool, profiles: Int) -> StripIndicatorLayout {
    let shown = (incognito || profiles >= 2) && room >= iconWidth
    let nameRoom = room - 2 * pad
    let showName = textWidth > 0 && (textWidth <= nameRoom || nameRoom >= minCutName)
    let width = !shown ? 0 : showName ? min(room, textWidth + 2 * pad) : iconWidth
    return StripIndicatorLayout(shown: shown, showName: showName, width: width)
  }

  public static func profileRoom(width: CGFloat, leading: CGFloat) -> CGFloat {
    max(minimumProfileSlot - profileGap, min(profileRoom, width - leading - trailingReservation - StripMetrics.minChip - profileGap))
  }

  public static func profileSlot(indicator: CGFloat, coveredByIsland: Bool) -> CGFloat {
    indicator > 0 ? max(coveredByIsland ? minimumProfileSlot : 0, indicator + profileGap) : 0
  }

  public static func width(indicator: CGFloat) -> CGFloat { (indicator > 0 ? indicator + gap : 0) + downloadsBox }

  public static func nameWidth(_ title: String) -> CGFloat {
    measuredLikeYoga((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
  }

  public static func measuredLikeYoga(_ width: CGFloat) -> CGFloat {
    let pixel: CGFloat = 0.5
    let text = ceil(width / pixel) * pixel
    return ceil(text + pixel)
  }
}

public struct TopStripLeadingLayout: Equatable {
  public let controls: CGRect
  public let profile: CGRect
  public let downloads: CGRect
  public let strip: CGRect
  public let leading: CGFloat
  public let pageWidth: CGFloat

  public init(width: CGFloat, profileWidth: CGFloat, windowFullscreen: Bool, backingScale: CGFloat = 2) {
    let profileX: CGFloat = windowFullscreen ? 8 : ShellMetrics.topStripLeadingReservation
    let top = StripControlsLayout.pixelAligned(ShellMetrics.topStripLightsCenter.y - StripControlsLayout.height / 2, backingScale: backingScale)
    controls = CGRect(x: 0, y: top, width: max(0, width - 8), height: StripControlsLayout.height + 0.5)
    profile = CGRect(x: profileX, y: top,
      width: profileWidth, height: StripControlsLayout.height)
    downloads = CGRect(x: max(0, width - 8 - StripControlsLayout.downloadsBox),
      y: top,
      width: StripControlsLayout.downloadsBox, height: StripControlsLayout.downloadsBox)
    leading = profileX + StripControlsLayout.profileSlot(indicator: profileWidth, coveredByIsland: windowFullscreen)
    pageWidth = max(0, width - leading - StripControlsLayout.trailingReservation)
    strip = CGRect(x: leading - StripMetrics.flare, y: 0,
      width: max(0, width - leading + StripMetrics.flare - max(StripControlsLayout.trailingReservation - StripMetrics.flare, StripControlsLayout.downloadsBox + 8)), height: StripMetrics.height)
  }
}

@MainActor
public final class StripControlsView: NSView {
  public var onAction: (StripControlAction) -> Void = { _ in }
  public private(set) var width: CGFloat = StripControlsLayout.downloadsBox
  public private(set) var profileSlotWidth: CGFloat = 0
  public var leadingInset: CGFloat = 0 { didSet { place() } }
  public var captionAligned = false { didSet { place() } }
  private var state: StripControlsState?
  private var theme: [String: String] = [:]
  public var docked = false { didSet { place() } }
  public var windowFullscreen = false { didSet { place() } }
  public var profileCoveredByIsland = false { didSet { place() } }
  public private(set) var profileWidth: CGFloat = 0
  public var dockedLayout: TopStripLeadingLayout {
    TopStripLeadingLayout(width: bounds.width, profileWidth: profileWidth, windowFullscreen: windowFullscreen,
      backingScale: window?.backingScaleFactor ?? 2)
  }
  let indicator = StripProfileIndicator()
  let downloads = StripIconButton()

  public override var isFlipped: Bool { true }

  private var tracking: NSTrackingArea?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointer(_:)))
    addSubview(indicator)
    addSubview(downloads)
    downloads.radius = 10
    downloads.name = "Downloads"
    indicator.onPress = { [weak self] in self?.onAction(.profileMenu) }
    downloads.onPress = { [weak self] in self?.onAction(.toggleDownloads) }
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(_ state: StripControlsState, theme: [String: String]) {
    self.state = state
    self.theme = theme
    place()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    place()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    place()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    place()
  }

  private func place() {
    guard let state else { return }
    func color(_ key: String) -> NSColor { SidebarPalette.parse(theme[key]) ?? .clear }
    let leading: CGFloat = docked ? (windowFullscreen ? 8 : ShellMetrics.topStripLeadingReservation) : leadingInset
    let room = bounds.width > 0 ? StripControlsLayout.profileRoom(width: bounds.width + (docked ? 0 : 8), leading: leading) : StripControlsLayout.profileRoom
    let layout = StripControlsLayout.indicator(textWidth: StripControlsLayout.nameWidth(state.title), room: room, incognito: state.incognito, profiles: state.profiles)
    indicator.isHidden = !layout.shown
    indicator.set(
      title: state.title, showName: layout.showName, color: SidebarPalette.parse(state.nameColor) ?? color("textPrimary"),
      hover: state.incognito ? .clear : color("tabHover"), pressed: state.incognito ? .clear : color("tabPressed"), enabled: !state.incognito,
      tooltip: state.incognito ? nil : "Switch between profiles")
    downloads.active = state.downloadsOpen
    downloads.set(
      "arrow.down.circle", size: 16, weight: .regular, color: color("icon"), hover: color("toolbarHover"), pressed: color("toolbarPressed"),
      tooltip: state.downloadsOpen ? nil : state.downloadsTooltip)
    let indicatorWidth = layout.shown ? layout.width : 0
    profileWidth = indicatorWidth
    width = StripControlsLayout.width(indicator: indicatorWidth)
    profileSlotWidth = StripControlsLayout.profileSlot(indicator: indicatorWidth, coveredByIsland: windowFullscreen || profileCoveredByIsland)
    indicator.frame = NSRect(x: leadingInset, y: captionAligned ? 0 : 0.5, width: indicatorWidth, height: StripControlsLayout.height)
    downloads.frame = NSRect(x: max(0, bounds.width - StripControlsLayout.downloadsBox), y: !captionAligned && indicatorWidth > 0 ? 0.5 : 0, width: StripControlsLayout.downloadsBox, height: StripControlsLayout.downloadsBox)
    if docked { placeDocked() }
  }

  private func placeDocked() {
    let geometry = dockedLayout
    indicator.frame = geometry.profile
    downloads.frame = geometry.downloads
  }

  public override func layout() {
    super.layout()
    if docked { placeDocked() }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseMoved(with event: NSEvent) { hover(at: isHitBy(event) ? fullScreenPoint(event.locationInWindow) : nil) }
  public override func mouseEntered(with event: NSEvent) { hover(at: isHitBy(event) ? fullScreenPoint(event.locationInWindow) : nil) }
  public override func mouseExited(with event: NSEvent) { hover(at: isHitBy(event) ? fullScreenPoint(event.locationInWindow) : nil) }

  @objc private func devPointer(_ note: Notification) {
    guard DevPointer.inside(self, note), let window, let screen = (note.object as? NSValue)?.pointValue else { return hover(at: nil) }
    hover(at: fullScreenPoint(window.convertPoint(fromScreen: screen)))
  }

  private func hover(at point: NSPoint?) {
    indicator.hovered = point.map { !indicator.isHidden && indicator.frame.contains($0) } ?? false
    downloads.hovered = point.map { downloads.frame.contains($0) } ?? false
  }

  public var downloadsRect: NSRect? { downloads.isHidden || window == nil ? nil : downloads.fullScreenRect(downloads.bounds, to: nil) }
}

@MainActor
final class StripProfileIndicator: StripHoverView {
  private let plate = CALayer()
  private let label = StripLabel()
  private let symbol = SymbolView()
  private var fills: (hover: NSColor, pressed: NSColor) = (.clear, .clear)
  private var showName = true
  private var enabled = true
  var leadingPadding: CGFloat = StripControlsLayout.pad { didSet { placeContents() } }
  var onPress: (() -> Void)?

  override var accessibleName: String? { label.stringValue }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    plate.cornerRadius = 10
    layer?.addSublayer(plate)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    addSubview(label)
    addSubview(symbol)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(title: String, showName: Bool, color: NSColor, hover: NSColor, pressed: NSColor, enabled: Bool, tooltip: String?) {
    self.showName = showName
    self.enabled = enabled
    label.stringValue = title
    label.textColor = color
    label.isHidden = !showName
    symbol.isHidden = showName
    symbol.set("person.fill", size: 14, weight: .semibold, color: color)
    fills = (hover, pressed)
    if toolTip != tooltip { toolTip = tooltip }
    needsLayout = true
    repaint()
  }

  override func layout() {
    super.layout()
    placeContents()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    placeContents()
  }

  private func placeContents() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    label.frame = NSRect(x: leadingPadding, y: 0, width: max(0, bounds.width - leadingPadding - StripControlsLayout.pad), height: bounds.height)
    symbol.frame = NSRect(x: (bounds.width - 16 + leadingPadding - StripControlsLayout.pad) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
  }

  override func repaint() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed ? fills.pressed : hovered ? fills.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    super.mouseDown(with: event)
  }

  override func press(_ mods: SidebarClickMods) { onPress?() }
  override func contextMenu() {}
}

@MainActor
public final class StripPeekRow: NSView {
  public let strip: TopStripView
  public let controls = StripControlsView()
  public var onPageWidth: (CGFloat) -> Void = { _ in }
  public private(set) var pageWidth: CGFloat = 0

  public override var isFlipped: Bool { true }

  public init(strip: TopStripView) {
    self.strip = strip
    super.init(frame: .zero)
    addSubview(strip)
    addSubview(controls)
    controls.leadingInset = 8
    controls.profileCoveredByIsland = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public static func frames(width: CGFloat, profileSlot: CGFloat) -> (strip: CGRect, controls: CGRect) {
    let left = 8 + profileSlot
    let strip = CGRect(x: left, y: 0, width: max(0, width - left - StripControlsLayout.trailingReservation), height: StripMetrics.height)
    let row = CGRect(x: 0, y: StripControlsLayout.rowTop, width: max(0, width - 8), height: StripControlsLayout.height + 0.5)
    return (strip, row)
  }

  public override func layout() {
    super.layout()
    controls.frame = Self.frames(width: bounds.width, profileSlot: 0).controls
    let frames = Self.frames(width: bounds.width, profileSlot: controls.profileSlotWidth)
    strip.frame = frames.strip
    let next = frames.strip.width
    if next != pageWidth {
      pageWidth = next
      onPageWidth(next)
    }
  }
}
