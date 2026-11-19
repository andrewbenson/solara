import AppKit

@MainActor
enum SidebarProfileStyle {
  static func neutral(dark: Bool) -> NSColor {
    SidebarPalette.parse(dark ? "#F5F2F7" : "#302938")!
  }

  static func fill(dark: Bool, selected: Bool, hovered: Bool, pressed: Bool) -> NSColor {
    let alpha: CGFloat
    if selected {
      alpha = dark ? (pressed ? 0.24 : hovered ? 0.20 : 0.16) : (pressed ? 0.75 : hovered ? 0.65 : 0.55)
    } else {
      alpha = dark ? (pressed ? 0.20 : hovered ? 0.09 : 0) : (pressed ? 0.65 : hovered ? 0.30 : 0)
    }
    return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
  }

  static func composite(_ ink: NSColor, over background: NSColor, opacity: CGFloat) -> NSColor {
    guard let ink = ink.usingColorSpace(.sRGB), let background = background.usingColorSpace(.sRGB) else { return ink }
    return NSColor(srgbRed: background.redComponent + (ink.redComponent - background.redComponent) * opacity,
      green: background.greenComponent + (ink.greenComponent - background.greenComponent) * opacity,
      blue: background.blueComponent + (ink.blueComponent - background.blueComponent) * opacity, alpha: 1)
  }

  static func luminance(_ color: NSColor) -> CGFloat {
    guard let color = color.usingColorSpace(.sRGB) else { return 0 }
    func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
  }

  static func contrast(_ ink: NSColor, background: NSColor) -> CGFloat {
    let a = luminance(composite(ink, over: background, opacity: 0.65)), b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  static func accessibleInk(_ ink: NSColor, background: NSColor, dark: Bool) -> NSColor {
    let ink = ink.withAlphaComponent(1)
    if contrast(ink, background: background) >= 3 { return ink }
    var target = neutral(dark: dark)
    if contrast(target, background: background) < 3 {
      let alternative = neutral(dark: !dark)
      if contrast(alternative, background: background) > contrast(target, background: background) { target = alternative }
    }
    for step in 1...100 {
      let mixed = composite(target, over: ink, opacity: CGFloat(step) / 100)
      if contrast(mixed, background: background) >= 3 { return mixed }
    }
    return target
  }
}

enum SidebarProfileScrollStep {
  static func next(from: CGFloat, travel: CGFloat?, delta: CGFloat, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, snap: CGFloat, limit: CGFloat) -> (x: CGFloat, travel: CGFloat?) {
    func clamp(_ value: CGFloat) -> CGFloat { min(limit, max(0, value)) }
    func slot(_ value: CGFloat) -> CGFloat { clamp((value / snap).rounded() * snap) }
    guard snap > 0 else { return (clamp(from - delta * (precise ? 1 : 10)), nil) }
    guard precise else {
      var snapped = slot(from - delta * 10)
      if delta != 0, abs(snapped - from) < 0.5 { snapped = clamp(from - (delta > 0 ? snap : -snap)) }
      return (snapped, nil)
    }
    let restart = phase.contains(.began) || phase.contains(.cancelled) || momentum.contains(.began) || momentum.contains(.cancelled)
    var base = restart ? nil : travel
    if let stale = base, abs(slot(stale) - from) >= 0.5 { base = nil }
    let raw = clamp((base ?? from) - delta)
    let finished = phase.contains(.ended) || phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) || (phase.isEmpty && momentum.isEmpty)
    return (slot(raw), finished ? nil : raw)
  }
}

@MainActor
final class SidebarProfileScrollView: NSScrollView {
  var onScroll: (() -> Void)?
  var snap: CGFloat = 0 { didSet { if snap != oldValue { travel = nil } } }
  private var travel: CGFloat?
  @objc var solaraOwnsHorizontalScrolling: Bool { (documentView?.bounds.width ?? 0) > contentView.bounds.width + 0.5 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
    automaticallyAdjustsContentInsets = false
    contentView.drawsBackground = false
    contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: contentView)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    if !solaraOwnsHorizontalScrolling, hit === self || hit === contentView || hit === documentView { return nil }
    return hit
  }

  override func scrollWheel(with event: NSEvent) {
    guard let documentView else { return }
    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
    let limit = max(0, documentView.bounds.width - contentView.bounds.width)
    let step = SidebarProfileScrollStep.next(from: contentView.bounds.minX, travel: travel, delta: delta, precise: event.hasPreciseScrollingDeltas,
      phase: event.phase, momentum: event.momentumPhase, snap: snap, limit: limit)
    travel = step.travel
    let x = step.x
    contentView.scroll(to: NSPoint(x: x, y: 0))
    reflectScrolledClipView(contentView)
  }

  @objc private func didScroll() { onScroll?() }
}

@MainActor
final class SidebarProfileEmoji: NSView {
  var stringValue = "" { didSet { needsDisplay = true } }
  var color: NSColor = .labelColor { didSet { needsDisplay = true } }
  let font = NSFont.systemFont(ofSize: SidebarChromeMetrics.profileGlyph)

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    let text = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    let height = ceil(font.ascender - font.descender + font.leading)
    text.draw(with: NSRect(x: 0, y: (bounds.height - height) / 2 - 0.5, width: bounds.width, height: height), options: [.usesLineFragmentOrigin])
  }
}

@MainActor
final class SidebarProfileGlyph: NSView {
  private let symbol = SymbolView()
  private let label = SidebarProfileEmoji()
  private let disc = CALayer()
  private(set) var value: String?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    disc.actions = SurfaceLayer.noActions
    disc.cornerRadius = SidebarChromeMetrics.dot / 2
    layer?.addSublayer(disc)
    label.wantsLayer = true
    addSubview(label)
    addSubview(symbol)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ icon: String?, color: NSColor, opacity: CGFloat = 1) {
    value = icon.flatMap { $0.isEmpty ? nil : $0 }
    let name = ProfileIcons.symbol(value)
    symbol.isHidden = name == nil
    label.isHidden = value == nil || name != nil
    disc.isHidden = value != nil
    if let name { symbol.set(name, size: SidebarChromeMetrics.profileGlyph, weight: .regular, color: color) }
    label.stringValue = value ?? ""
    label.color = color
    label.alphaValue = 1
    label.layer?.filters = nil
    disc.backgroundColor = color.cgColor
    alphaValue = opacity
    needsLayout = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    let box = SidebarChromeMetrics.profileOpticalBox
    let optical = NSRect(x: bounds.midX - box / 2, y: bounds.midY - box / 2, width: box, height: box)
    symbol.frame = optical
    label.frame = optical
    let size = SidebarChromeMetrics.dot
    disc.frame = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
  }
}

@MainActor
final class SidebarRailProfileButton: StripHoverView {
  let glyph = SidebarProfileGlyph()
  private var name = ""
  private var fills: (rest: NSColor, hover: NSColor, pressed: NSColor) = (.clear, .clear, .clear)
  var onPress: (() -> Void)?
  var onMenu: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  private var wasHovered = false

  override var accessibleName: String? { name }
  override var accessibleSelected: Bool? { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    layer?.cornerRadius = 6
    addSubview(glyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ profile: SidebarChromeDot, dark: Bool, ink: NSColor) {
    name = profile.name
    glyph.set(profile.icon, color: ink)
    fills = (
      SidebarProfileStyle.fill(dark: dark, selected: true, hovered: false, pressed: false),
      SidebarProfileStyle.fill(dark: dark, selected: true, hovered: true, pressed: false),
      SidebarProfileStyle.fill(dark: dark, selected: true, hovered: true, pressed: true))
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08).cgColor
    toolTip = nil
    needsLayout = true
    repaint()
  }

  override func layout() {
    super.layout()
    glyph.frame = bounds
  }

  override func repaint() {
    layer?.backgroundColor = (pressed ? fills.pressed : hovered ? fills.hover : fills.rest).cgColor
    if hovered != wasHovered {
      wasHovered = hovered
      onHover?(hovered)
    }
  }

  override func press(_ mods: SidebarClickMods) { onPress?() }
  override func contextMenu() { onMenu?() }
}

@MainActor
final class SidebarRailProfileRow: NSButton {
  var onChoose: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  private let check = SymbolView()
  private let glyph = SidebarProfileGlyph()
  private let shortcut = StripLabel()
  private let nameLabel = StripLabel()

  init(profile: SidebarChromeDot, current: Bool, color: NSColor) {
    super.init(frame: .zero)
    title = profile.name
    isBordered = false
    alignment = .left
    font = .systemFont(ofSize: FolderPanelMetrics.labelSize)
    attributedTitle = NSAttributedString(string: profile.name, attributes: [.foregroundColor: NSColor.clear])
    nameLabel.stringValue = profile.name
    nameLabel.font = .systemFont(ofSize: FolderPanelMetrics.labelSize)
    nameLabel.textColor = color
    wantsLayer = true
    layer?.cornerRadius = 6
    setButtonType(.momentaryChange)
    imagePosition = .imageLeading
    imageHugsTitle = true
    contentTintColor = color
    image = NSImage(size: NSSize(width: 46, height: 20))
    glyph.set(profile.icon, color: SidebarPalette.parse(profile.color) ?? color)
    state = current ? .on : .off
    check.set("checkmark", size: 12, weight: .semibold, color: .controlAccentColor)
    check.isHidden = !current
    shortcut.font = .systemFont(ofSize: 12, weight: .medium)
    shortcut.textColor = color.withAlphaComponent(0.65)
    shortcut.stringValue = profile.shortcut ?? ""
    for view in [check, glyph, shortcut, nameLabel] as [NSView] { addSubview(view) }
    target = self
    action = #selector(choose)
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(profile.name)
    setAccessibilityHelp(profile.shortcut)
    setAccessibilityValue(NSNumber(value: current))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    check.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    glyph.frame = NSRect(x: 22, y: (bounds.height - 20) / 2, width: 20, height: 20)
    let width = (shortcut.stringValue as NSString).size(withAttributes: [.font: shortcut.font]).width
    shortcut.frame = NSRect(x: bounds.width - width - 8, y: 0, width: width, height: bounds.height)
    nameLabel.frame = NSRect(x: 50, y: 0, width: max(0, bounds.width - 66 - width), height: bounds.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) {
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    onHover?(true)
  }
  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
    onHover?(false)
  }

  @objc private func choose() { onChoose?() }
}
