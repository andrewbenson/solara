import AppKit
import CoreImage

@MainActor
final class SidebarProfileGlyph: NSView {
  private let symbol = SymbolView()
  private let label = StripLabel()
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
    label.font = .systemFont(ofSize: 12)
    addSubview(label)
    addSubview(symbol)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ icon: String?, color: NSColor, opacity: CGFloat = 1, active: Bool = true) {
    value = icon.flatMap { $0.isEmpty ? nil : $0 }
    let name = ProfileIcons.symbol(value)
    symbol.isHidden = name == nil
    label.isHidden = value == nil || name != nil
    disc.isHidden = value != nil
    if let name { symbol.set(name, size: 12, weight: .regular, color: color.withAlphaComponent(opacity)) }
    label.stringValue = value ?? ""
    label.alphaValue = active ? 1 : 0.55
    if !active, name == nil, let filter = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.25]) {
      label.layer?.filters = [filter]
    } else {
      label.layer?.filters = nil
    }
    disc.backgroundColor = color.withAlphaComponent(opacity).cgColor
    needsLayout = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    symbol.frame = bounds
    let width = (label.stringValue as NSString).size(withAttributes: [.font: label.font]).width
    label.frame = NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
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

  func set(_ profile: SidebarChromeDot, dark: Bool, ink: NSColor, hover: NSColor, pressed: NSColor) {
    name = profile.name
    glyph.set(profile.icon, color: ink.withAlphaComponent(0.72))
    fills = (NSColor(white: dark ? 0 : 1, alpha: 0.22), hover, pressed)
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
