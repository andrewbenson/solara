import AppKit

@MainActor
final class SidebarActivePill: NSView {
  static let size = NSSize(width: 51, height: 28)
  static let gapAboveDock: CGFloat = 6

  var onPress: () -> Void = {}
  private let ring = CALayer()
  private let plate = CALayer()
  private let icon = TabIconView()
  private let arrow = SymbolView()
  private var pressed = false { didSet { if pressed != oldValue { alphaValue = pressed ? 0.8 : 1 } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for surface in [ring, plate] {
      surface.actions = SurfaceLayer.noActions
      surface.cornerCurve = .continuous
      layer?.addSublayer(surface)
    }
    ring.borderWidth = 0.5
    plate.borderWidth = 1
    addSubview(icon)
    addSubview(arrow)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func clearBinding() {
    icon.clearBinding()
    pressed = false
    alphaValue = 0
    toolTip = nil
    setAccessibilityLabel(nil)
  }

  func set(_ spec: TabIconSpec, title: String, up: Bool, palette: SidebarPalette, favicons: SidebarFavicons) {
    let dark = palette.dark
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.borderColor = NSColor.black.withAlphaComponent(dark ? 0.8 : 0.12).cgColor
    plate.backgroundColor = (dark ? NSColor(white: 0.04, alpha: 0.68) : NSColor(white: 1, alpha: 0.9)).cgColor
    plate.borderColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).cgColor
    CATransaction.commit()
    icon.favicons = favicons
    icon.set(spec, palette: palette)
    arrow.set(up ? "arrow.up" : "arrow.down", size: 9, color: dark ? NSColor.white.withAlphaComponent(0.67) : NSColor.black.withAlphaComponent(0.55))
    setAccessibilityLabel(up ? "Scroll up to \(title)" : "Scroll down to \(title)")
    toolTip = title
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds
    ring.cornerRadius = bounds.height / 2
    plate.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    plate.cornerRadius = plate.frame.height / 2
    CATransaction.commit()
    let h = bounds.height
    icon.frame = NSRect(x: 11, y: (h - 16) / 2, width: 16, height: 16)
    arrow.frame = NSRect(x: 37 - 7, y: (h - 14) / 2, width: 14, height: 14)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }
    return bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pressed = true }
  override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress()
    return true
  }
}
