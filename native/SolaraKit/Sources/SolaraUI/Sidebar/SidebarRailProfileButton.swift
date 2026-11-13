import AppKit

@MainActor
final class SidebarRailProfileButton: StripHoverView {
  private let label = StripLabel()
  private var name = ""
  private var fills: (rest: NSColor, hover: NSColor, pressed: NSColor) = (.clear, .clear, .clear)
  var onPress: (() -> Void)?

  override var accessibleName: String? { name }

  override init(frame: NSRect) {
    super.init(frame: frame)
    layer?.cornerRadius = SidebarChromeMetrics.profileButton / 2
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  static func icon(_ profile: SidebarChromeDot) -> String {
    if let icon = profile.icon, !icon.isEmpty, ProfileIcons.symbol(icon) == nil { return icon }
    return String(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
  }

  func set(_ profile: SidebarChromeDot, dark: Bool, hover: NSColor, pressed: NSColor) {
    name = profile.name
    label.stringValue = Self.icon(profile)
    label.textColor = dark ? .white : .black
    fills = (NSColor(white: dark ? 1 : 0, alpha: 0.06), hover, pressed)
    toolTip = profile.name
    needsLayout = true
    repaint()
  }

  override func layout() {
    super.layout()
    let width = (label.stringValue as NSString).size(withAttributes: [.font: label.font]).width
    label.frame = NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
  }

  override func repaint() {
    layer?.backgroundColor = (pressed ? fills.pressed : hovered ? fills.hover : fills.rest).cgColor
  }

  override func press(_ mods: SidebarClickMods) { onPress?() }
}

@MainActor
final class SidebarRailProfileRow: NSButton {
  var onChoose: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  private let check = SymbolView()

  init(profile: SidebarChromeDot, current: Bool, color: NSColor) {
    super.init(frame: .zero)
    title = profile.name
    isBordered = false
    alignment = .left
    font = .systemFont(ofSize: FolderPanelMetrics.labelSize)
    setButtonType(.momentaryChange)
    imagePosition = .imageLeading
    imageHugsTitle = true
    contentTintColor = color
    let icon = SidebarRailProfileButton.icon(profile)
    image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { rect in
      (icon as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color])
      return true
    }
    state = current ? .on : .off
    check.set("checkmark", size: 12, weight: .semibold, color: color)
    check.isHidden = !current
    addSubview(check)
    target = self
    action = #selector(choose)
    setAccessibilityRole(.radioButton)
    setAccessibilityValue(NSNumber(value: current))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    check.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 16) / 2, width: 16, height: 16)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }

  @objc private func choose() { onChoose?() }
}
