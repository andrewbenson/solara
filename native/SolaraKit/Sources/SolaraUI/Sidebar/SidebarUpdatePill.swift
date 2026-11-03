import AppKit

public struct SidebarUpdatePillState: Decodable, Equatable, Sendable {
  public var text: String
  public var tooltip: String?

  public init(text: String, tooltip: String? = nil) {
    self.text = text
    self.tooltip = tooltip
  }
}

public enum SidebarUpdatePillMetrics {
  public static let height: CGFloat = 30
  public static let gap: CGFloat = 8
  public static let band: CGFloat = height + gap
  public static let sideInset: CGFloat = 8
  public static let fontSize: CGFloat = 12

  public static func fill(dark: Bool, hovered: Bool, pressed: Bool) -> NSColor {
    let alpha: CGFloat = pressed ? (dark ? 0.2 : 0.13) : hovered ? (dark ? 0.15 : 0.1) : (dark ? 0.1 : 0.06)
    return NSColor(white: dark ? 1 : 0, alpha: alpha)
  }

  public static func edge(dark: Bool) -> NSColor { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.05) }
}

@MainActor
final class SidebarUpdatePill: NSView {
  var onPress: (() -> Void)?
  private let plate = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var tracking: NSTrackingArea?
  private(set) var text = ""
  private var dark = true
  var hovered = false { didSet { if hovered != oldValue { paint() } } }
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    plate.borderWidth = 0.5
    layer?.addSublayer(plate)
    label.font = .systemFont(ofSize: SidebarUpdatePillMetrics.fontSize, weight: .medium)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ state: SidebarUpdatePillState, color: NSColor, dark: Bool) {
    text = state.text
    label.stringValue = state.text
    label.textColor = color
    toolTip = state.tooltip
    self.dark = dark
    paint()
    needsLayout = true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }

  func recheckHover() {
    guard let window else { return hovered = false }
    hovered = !isHidden && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    plate.cornerRadius = bounds.height / 2
    CATransaction.commit()
    let size = label.fittingSize
    let width = min(size.width, max(0, bounds.width - 16))
    label.frame = NSRect(x: ((bounds.width - width) / 2 * 2).rounded() / 2, y: ((bounds.height - size.height) / 2 * 2).rounded() / 2, width: width, height: size.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { text }
  override func accessibilityHelp() -> String? { toolTip }
  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return onPress != nil
  }

  private func paint() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = SidebarUpdatePillMetrics.fill(dark: dark, hovered: hovered, pressed: pressed).cgColor
    plate.borderColor = SidebarUpdatePillMetrics.edge(dark: dark).cgColor
    CATransaction.commit()
  }
}
