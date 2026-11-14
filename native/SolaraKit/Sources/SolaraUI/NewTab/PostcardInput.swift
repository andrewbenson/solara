import AppKit

public final class PostcardControl: NSControl {
  public var onPress: (() -> Void)?
  public var acceptsFirstClick = false
  public var interactionEnabled = true
  public var containsPointInWindow: ((NSPoint) -> Bool)?
  var onHover: (Bool) -> Void = { _ in }
  var onPressed: (Bool) -> Void = { _ in }
  var onFocus: () -> Void = {}
  var onBlur: () -> Void = {}
  var accessible = true
  var glyph: String? { didSet { refreshGlyph() } }
  var glyphSize: CGFloat = 11 { didSet { refreshGlyph() } }
  var glyphWeight: NSFont.Weight = .medium { didSet { refreshGlyph() } }
  var glyphColor = NSColor.white { didSet { glyphView.contentTintColor = glyphColor } }
  var radius: CGFloat = 0
  var fill: NSColor?
  var border: NSColor?
  var borderWidth: CGFloat = 0
  public private(set) var hovered = false
  public private(set) var pressed = false
  private let glyphView = PostcardGlyph()
  private var tracking: NSTrackingArea?
  private var downAction: (() -> Void)?
  private var down = false
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { accessible && isEnabled && (interactionEnabled || window?.firstResponder === self) && onPress != nil && !isHiddenOrHasHiddenAncestor }
  public override var canBecomeKeyView: Bool { acceptsFirstResponder }
  public override func isAccessibilityEnabled() -> Bool { isEnabled && interactionEnabled }
  public override var focusRingMaskBounds: NSRect { bounds }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick && isEnabled && interactionEnabled }
  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    glyphView.imageScaling = .scaleNone
    glyphView.autoresizingMask = [.width, .height]
    glyphView.setAccessibilityElement(false)
    addSubview(glyphView)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    focusRingType = .exterior
  }
  public required init?(coder: NSCoder) { nil }
  public override func isAccessibilityElement() -> Bool { accessible }
  public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: min(radius, 12), yRadius: min(radius, 12)).fill() }
  public override func becomeFirstResponder() -> Bool {
    guard acceptsFirstResponder else { return false }
    onFocus()
    needsDisplay = true
    noteFocusRingMaskChanged()
    return true
  }
  public override func resignFirstResponder() -> Bool {
    down = false
    downAction = nil
    setPressed(false)
    needsDisplay = true
    noteFocusRingMaskChanged()
    onBlur()
    return true
  }
  public override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); path.fill() }
    if let border, borderWidth > 0 { border.setStroke(); path.lineWidth = borderWidth; path.stroke() }
  }
  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    glyphView.frame = bounds
  }
  private func refreshGlyph() {
    glyphView.image = glyph.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: glyphSize, weight: glyphWeight)) }
    glyphView.contentTintColor = glyphColor
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    tracking = area
    addTrackingArea(area)
  }
  public override func mouseEntered(with event: NSEvent) { hovered = true; onHover(true) }
  public override func mouseExited(with event: NSEvent) { hovered = false; onHover(false); setPressed(false) }
  private func setPressed(_ value: Bool) { pressed = value; onPressed(value) }
  public override func mouseDown(with event: NSEvent) {
    guard isEnabled, interactionEnabled, !isHiddenOrHasHiddenAncestor, window != nil else { return }
    down = true; downAction = onPress; setPressed(true)
  }
  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { down = false; downAction = nil; setPressed(false) }
    super.viewWillMove(toWindow: newWindow)
  }
  public override func mouseUp(with event: NSEvent) {
    let inside = containsPointInWindow?(event.locationInWindow) ?? bounds.contains(convert(event.locationInWindow, from: nil))
    let fire = down && isEnabled && interactionEnabled && !isHiddenOrHasHiddenAncestor && window != nil && inside
    let action = downAction
    down = false
    downAction = nil
    setPressed(false)
    if fire { action?() }
  }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    if event.keyCode == 53 { nextResponder?.keyDown(with: event); return }
    guard isEnabled, interactionEnabled, acceptsFirstResponder, [36, 49, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
    setPressed(true)
    if !event.isARepeat { onPress?() }
  }
  public override func keyUp(with event: NSEvent) {
    guard [36, 49, 76].contains(event.keyCode) else { return super.keyUp(with: event) }
    setPressed(false)
  }
  public override func accessibilityPerformPress() -> Bool {
    guard isEnabled, interactionEnabled, acceptsFirstResponder, let onPress else { return false }
    onPress()
    return true
  }
}

private final class PostcardGlyph: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
