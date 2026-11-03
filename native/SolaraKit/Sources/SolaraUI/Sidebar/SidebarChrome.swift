import AppKit

public struct SidebarChromeDot: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var slot: Double?

  public init(id: String, name: String, slot: Double?) {
    self.id = id
    self.name = name
    self.slot = slot
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
  public var dropOver: Bool
  public var update: SidebarUpdatePillState?

  public init(
    controls: StripControlsState, downloads: Bool, addressBar: Bool, dark: Bool, theme: [String: String], dots: [SidebarChromeDot], savedWidth: Double,
    dropOver: Bool = false, update: SidebarUpdatePillState? = nil
  ) {
    self.controls = controls
    self.downloads = downloads
    self.addressBar = addressBar
    self.dark = dark
    self.theme = theme
    self.dots = dots
    self.savedWidth = savedWidth
    self.dropOver = dropOver
    self.update = update
  }

  public static func decode(_ json: String) -> SidebarChromeState? {
    try? JSONDecoder().decode(SidebarChromeState.self, from: Data(json.utf8))
  }
}

public enum SidebarChromeAction: Equatable, Sendable {
  case profileMenu
  case toggleDownloads
  case switchProfile(String)
  case liveWidth(Double?)
  case commitWidth(Double)
  case resetWidth
  case installUpdate
}

public enum SidebarChromeMetrics {
  public static let header: CGFloat = 46
  public static let fieldRow: CGFloat = 34
  public static let footer: CGFloat = 41
  public static let indicatorX: CGFloat = 84
  public static let headerRight: CGFloat = 7
  public static let controlTop: CGFloat = 10
  public static let downloadsBox: CGFloat = 34
  public static let footerDownloadsBottom: CGFloat = 3 + (41 - 3 - 34) / 2
  public static let inset: CGFloat = 6
  public static let resizeStrip: CGFloat = 4
  public static let dotCell: CGFloat = 12
  public static let dotBand: CGFloat = 28
  public static let dot: CGFloat = 6
  public static let minWidth: Double = 160
  public static let maxWidth: Double = 400
  public static let defaultWidth: Double = 190

  public static func headerHeight(addressBar: Bool) -> CGFloat { addressBar ? header + fieldRow : header }

  public static func footerRowHeight(_ state: SidebarChromeState) -> CGFloat {
    !state.dots.isEmpty || (state.addressBar && state.downloads) ? footer : 0
  }

  public static func footerHeight(_ state: SidebarChromeState) -> CGFloat {
    footerRowHeight(state) + (state.update == nil ? 0 : SidebarUpdatePillMetrics.band)
  }

  public static func indicatorRoom(width: CGFloat, downloads: Bool) -> CGFloat {
    width - indicatorX - headerRight - (downloads ? downloadsBox + 2 : 0)
  }

  public static func dotOpacity(slot: Double?, position: Double, hovered: Bool) -> CGFloat {
    let rest = hovered ? 0.4 : 0.2
    guard let slot else { return rest }
    let distance = min(1, abs(position - slot))
    return CGFloat(0.85 + (rest - 0.85) * distance)
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
}

@MainActor
public final class SidebarChromeView: NSView {
  public var onAction: (SidebarChromeAction) -> Void = { _ in }
  public var onBlankMouseDown: (NSEvent) -> Void = { event in event.window?.performDrag(with: event) }
  public let addressSlot = FlippedContainerView()
  public private(set) var state: SidebarChromeState?

  let indicator = StripProfileIndicator()
  let headerDownloads = StripIconButton()
  let footerDownloads = StripIconButton()
  let resize = SidebarResizeHandle()
  let updatePill = SidebarUpdatePill()
  private var dots: [SidebarProfileDot] = []
  private let tooltip = SidebarDotTooltip()
  private let dropGlow = CALayer()
  private var position: Double = 0
  private var tracking: NSTrackingArea?

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
    addressSlot.autoresizingMask = []
    addSubview(addressSlot)
    for button in [headerDownloads, footerDownloads] {
      button.radius = 10
      button.name = "Downloads"
      button.onPress = { [weak self] in self?.onAction(.toggleDownloads) }
      addSubview(button)
    }
    indicator.onPress = { [weak self] in self?.onAction(.profileMenu) }
    addSubview(indicator)
    updatePill.isHidden = true
    updatePill.onPress = { [weak self] in self?.onAction(.installUpdate) }
    addSubview(updatePill)
    resize.onWidth = { [weak self] action in self?.onAction(action) }
    resize.savedWidth = { [weak self] in self?.state?.savedWidth ?? SidebarChromeMetrics.defaultWidth }
    addSubview(resize)
    tooltip.isHidden = true
    addSubview(tooltip)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var headerHeight: CGFloat { SidebarChromeMetrics.headerHeight(addressBar: state?.addressBar ?? false) }
  public var footerHeight: CGFloat { state.map(SidebarChromeMetrics.footerHeight) ?? 0 }

  public func update(_ next: SidebarChromeState) {
    guard next != state else { return }
    if next.dropOver != state?.dropOver { fadeDropGlow(to: next.dropOver ? 1 : 0) }
    state = next
    syncDots(next.dots)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public func setPagerPosition(_ next: Double) {
    position = next
    paintDots()
  }

  public var downloadsRect: NSRect? {
    let button = [headerDownloads, footerDownloads].first { !$0.isHidden }
    guard let button, window != nil else { return nil }
    return button.convert(button.bounds, to: nil)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    let hit = super.hitTest(point)
    if hit !== self { return hit }
    return local.y < headerHeight || local.y >= bounds.height - footerHeight ? self : nil
  }

  public override func mouseDown(with event: NSEvent) {
    guard convert(event.locationInWindow, from: nil).y < headerHeight else { return }
    onBlankMouseDown(event)
  }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func layout() {
    super.layout()
    guard let state else { return }
    func color(_ key: String) -> NSColor { SidebarPalette.parse(state.theme[key]) ?? .clear }
    let width = bounds.width
    let header = headerHeight
    let footer = SidebarChromeMetrics.footerRowHeight(state)
    addressSlot.isHidden = !state.addressBar
    addressSlot.frame = NSRect(x: 0, y: 0, width: width, height: header)

    let controls = state.controls
    let inHeader = !state.addressBar
    let room = SidebarChromeMetrics.indicatorRoom(width: width, downloads: state.downloads)
    let layout = StripControlsLayout.indicator(
      textWidth: StripControlsLayout.nameWidth(controls.title), room: room, incognito: controls.incognito, profiles: controls.profiles)
    indicator.isHidden = !inHeader || !layout.shown
    indicator.set(
      title: controls.title, showName: layout.showName, color: SidebarPalette.parse(controls.nameColor) ?? color("textPrimary"),
      hover: controls.incognito ? .clear : color("tabHover"), pressed: controls.incognito ? .clear : color("tabPressed"), enabled: !controls.incognito,
      tooltip: controls.incognito ? nil : "Switch between profiles")
    indicator.frame = NSRect(
      x: SidebarChromeMetrics.indicatorX, y: SidebarChromeMetrics.controlTop + 0.5, width: layout.shown ? layout.width : 0, height: StripControlsLayout.height)

    let box = SidebarChromeMetrics.downloadsBox
    for button in [headerDownloads, footerDownloads] {
      button.active = controls.downloadsOpen
      button.set(
        "arrow.down.circle", size: 16, weight: .regular, color: color("icon"), hover: color("toolbarHover"), pressed: color("toolbarPressed"),
        tooltip: controls.downloadsOpen ? nil : controls.downloadsTooltip)
    }
    headerDownloads.isHidden = !inHeader || !state.downloads
    headerDownloads.frame = NSRect(x: width - SidebarChromeMetrics.headerRight - box, y: SidebarChromeMetrics.controlTop, width: box, height: box)
    footerDownloads.isHidden = !(state.addressBar && state.downloads)
    footerDownloads.frame = NSRect(
      x: SidebarChromeMetrics.inset, y: bounds.height - SidebarChromeMetrics.footerDownloadsBottom - box, width: box, height: box)

    let cell = SidebarChromeMetrics.dotCell
    let rowLeft = ((width - cell * CGFloat(dots.count)) / 2 * 2).rounded() / 2
    let rowTop = bounds.height - footer + (SidebarChromeMetrics.footer - 3 - SidebarChromeMetrics.dotBand) / 2
    for (index, dot) in dots.enumerated() {
      dot.frame = NSRect(x: rowLeft + cell * CGFloat(index), y: rowTop, width: cell, height: SidebarChromeMetrics.dotBand)
      dot.ink = state.dark ? .white : .black
    }
    paintDots()

    updatePill.isHidden = state.update == nil
    if let update = state.update {
      updatePill.set(update, color: color("textPrimary"), dark: state.dark)
      let pill = SidebarUpdatePillMetrics.self
      updatePill.frame = NSRect(
        x: pill.sideInset, y: bounds.height - footer - pill.gap - pill.height, width: max(0, width - pill.sideInset * 2), height: pill.height)
    }

    resize.frame = NSRect(
      x: width - SidebarChromeMetrics.resizeStrip, y: SidebarChromeMetrics.header, width: SidebarChromeMetrics.resizeStrip,
      height: max(0, bounds.height - SidebarChromeMetrics.header))
    tooltip.look(dark: state.dark, panel: color("panel"), border: color("panelBorder"))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dropGlow.frame = NSRect(x: 5, y: 44, width: max(0, width - 10), height: max(0, bounds.height - 50))
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
        if inside { self.tooltip.show(dot.name, above: dot) } else { self.tooltip.hide(dot) }
        self.paintDots()
      }
      addSubview(dot, positioned: .below, relativeTo: tooltip)
      dots.append(dot)
    }
    for (dot, info) in zip(dots, given) {
      dot.profileId = info.id
      dot.name = info.name
      dot.slot = info.slot
    }
  }

  private func paintDots() {
    for dot in dots { dot.opacity = SidebarChromeMetrics.dotOpacity(slot: dot.slot, position: position, hovered: dot.hovered) }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseExited(with event: NSEvent) { hover(at: nil) }

  @objc private func devPointer(_ note: Notification) {
    guard DevPointer.inside(self, note), let window, let screen = (note.object as? NSValue)?.pointValue else { return hover(at: nil) }
    hover(at: convert(window.convertPoint(fromScreen: screen), from: nil))
  }

  private func hover(at point: NSPoint?) {
    indicator.hovered = point.map { !indicator.isHidden && indicator.frame.contains($0) } ?? false
    for button in [headerDownloads, footerDownloads] { button.hovered = point.map { !button.isHidden && button.frame.contains($0) } ?? false }
    updatePill.hovered = point.map { !updatePill.isHidden && updatePill.frame.contains($0) } ?? false
    for dot in dots { dot.setHovered(point.map { dot.frame.contains($0) } ?? false) }
  }

  public func describe() -> [String: Any] {
    func rect(_ view: NSView) -> [Double] {
      let r = view.convert(view.bounds, to: self)
      return [r.minX, r.minY, r.width, r.height]
    }
    return [
      "header": headerHeight, "footer": footerHeight,
      "indicator": indicator.isHidden ? NSNull() : rect(indicator),
      "headerDownloads": headerDownloads.isHidden ? NSNull() : rect(headerDownloads),
      "footerDownloads": footerDownloads.isHidden ? NSNull() : rect(footerDownloads),
      "resize": rect(resize),
      "update": updatePill.isHidden ? NSNull() : ["text": updatePill.text, "rect": rect(updatePill)],
      "dropGlow": Double(dropGlow.opacity),
      "dots": dots.map { ["id": $0.profileId, "rect": rect($0), "opacity": Double($0.opacity)] },
      "tooltip": tooltip.isHidden ? NSNull() : ["text": tooltip.text, "rect": rect(tooltip), "alpha": Double(tooltip.alphaValue)],
    ]
  }
}

@MainActor
final class SidebarProfileDot: NSView {
  var profileId = ""
  var name = ""
  var slot: Double?
  var onPress: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  private(set) var hovered = false
  private var pressed = false
  private let disc = CALayer()

  var ink: NSColor = .black { didSet { disc.backgroundColor = ink.cgColor } }
  var opacity: CGFloat = 0.2 {
    didSet {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      disc.opacity = Float(opacity)
      CATransaction.commit()
    }
  }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    disc.actions = SurfaceLayer.noActions
    disc.cornerRadius = SidebarChromeMetrics.dot / 2
    layer?.addSublayer(disc)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let size = SidebarChromeMetrics.dot
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    disc.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    CATransaction.commit()
  }

  func setHovered(_ inside: Bool) {
    guard inside != hovered else { return }
    hovered = inside
    if !inside { pressed = false }
    onHover?(inside && !pressed)
  }

  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onPress?()
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { name }
  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}

@MainActor
final class SidebarDotTooltip: NSView {
  static let delay: TimeInterval = 0.5
  static let fade: TimeInterval = 0.1
  static let centerToTooltip: CGFloat = 18.25
  private let ring = CALayer()
  private let plate = CALayer()
  private let label = StripLabel()
  private var pending: DispatchWorkItem?
  private weak var anchor: NSView?
  private(set) var text = ""

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    ring.actions = SurfaceLayer.noActions
    plate.actions = SurfaceLayer.noActions
    ring.cornerRadius = 4.5
    ring.borderWidth = 0.5
    ring.shadowColor = NSColor.black.cgColor
    ring.shadowRadius = 4
    ring.shadowOffset = CGSize(width: 0, height: -1)
    plate.cornerRadius = 4
    plate.borderWidth = 1
    layer?.addSublayer(ring)
    layer?.addSublayer(plate)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func look(dark: Bool, panel: NSColor, border: NSColor) {
    ring.borderColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.12).cgColor
    ring.shadowOpacity = dark ? 0.15 : 0.08
    plate.backgroundColor = (dark ? NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1) : panel).cgColor
    plate.borderColor = border.cgColor
    label.textColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.85)
  }

  func show(_ text: String, above view: NSView) {
    pending?.cancel()
    anchor = view
    guard !text.isEmpty else { return hide() }
    let work = DispatchWorkItem { [weak self] in self?.appear(text) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
  }

  func hide(_ from: NSView? = nil) {
    if let from, from !== anchor { return }
    pending?.cancel()
    pending = nil
    anchor = nil
    isHidden = true
    alphaValue = 0
  }

  private func appear(_ text: String) {
    guard let anchor, let superview else { return }
    self.text = text
    label.stringValue = text
    let textWidth = StripControlsLayout.measuredLikeYoga((text as NSString).size(withAttributes: [.font: label.font]).width)
    let size = NSSize(width: textWidth + 13 + 1, height: label.lineHeight + 10 + 1)
    let center = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: superview)
    frame = NSRect(x: (center.x - size.width / 2).rounded(), y: center.y - Self.centerToTooltip - size.height + 0.5, width: size.width, height: size.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds
    plate.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    CATransaction.commit()
    label.frame = NSRect(x: 7, y: 5.5, width: textWidth, height: label.lineHeight)
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
  public private(set) var dragging = false
  private var live: Double?
  private var start: Double = 0
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

  public override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      stopSpring()
      live = nil
      dragging = false
      return onWidth(.resetWidth)
    }
    stopSpring()
    dragging = true
    downX = event.locationInWindow.x
    start = SidebarResizeMath.unstretch(live ?? savedWidth())
    show(SidebarResizeMath.rubberBand(start))
  }

  public override func mouseDragged(with event: NSEvent) {
    guard dragging else { return }
    show(SidebarResizeMath.rubberBand(start + Double(event.locationInWindow.x - downX)))
  }

  public override func mouseUp(with event: NSEvent) {
    guard dragging else { return }
    let raw = SidebarResizeMath.rubberBand(start + Double(event.locationInWindow.x - downX))
    let target = SidebarResizeMath.clamp(raw)
    if raw == target { return commit(target) }
    let link = displayLink(target: self, selector: #selector(step(_:)))
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
    spring?.link.invalidate()
    spring = nil
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil, dragging || spring != nil {
      let target = spring?.to ?? SidebarResizeMath.clamp(live ?? savedWidth())
      stopSpring()
      commit(target)
    }
  }
}
