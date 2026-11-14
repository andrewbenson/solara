import AppKit

public final class CheckInControl: NSControl {
  public var onPress: (() -> Void)?
  public var acceptsFirstClick = false
  public var interactionEnabled = true
  public var containsPointer: ((NSPoint) -> Bool)?
  var onHover: (Bool) -> Void = { _ in }
  var onPressed: (Bool) -> Void = { _ in }
  var onFocus: () -> Void = {}
  private var tracking: NSTrackingArea?
  private var downAction: (() -> Void)?
  private var down = false
  public private(set) var focused = false
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { isEnabled && (interactionEnabled || window?.firstResponder === self) && onPress != nil && !isHiddenOrHasHiddenAncestor }
  public override var canBecomeKeyView: Bool { acceptsFirstResponder }
  public override func isAccessibilityEnabled() -> Bool { isEnabled && interactionEnabled }
  public override var focusRingMaskBounds: NSRect { bounds }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick && isEnabled && interactionEnabled }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    focusRingType = .exterior
  }

  public required init?(coder: NSCoder) { nil }

  public override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  public override func drawFocusRingMask() {
    NSColor.black.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: min(10, bounds.height / 2), yRadius: min(10, bounds.height / 2)).fill()
  }
  public override func becomeFirstResponder() -> Bool {
    guard acceptsFirstResponder else { return false }
    focused = true
    needsDisplay = true
    noteFocusRingMaskChanged()
    onFocus()
    return true
  }
  public override func resignFirstResponder() -> Bool {
    focused = false
    cancelPress()
    needsDisplay = true
    noteFocusRingMaskChanged()
    onFocus()
    return true
  }
  public override func viewWillMove(toSuperview newSuperview: NSView?) { cancelPress(); super.viewWillMove(toSuperview: newSuperview) }
  public func cancelPress() { down = false; downAction = nil; onPressed(false) }
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    tracking = area
    addTrackingArea(area)
  }
  public override func mouseEntered(with event: NSEvent) { onHover(true) }
  public override func mouseExited(with event: NSEvent) { onHover(false); onPressed(false) }
  public override func mouseDown(with event: NSEvent) {
    guard isEnabled, interactionEnabled, !isHiddenOrHasHiddenAncestor else { return }
    down = true
    downAction = onPress
    onPressed(true)
  }
  public override func mouseUp(with event: NSEvent) {
    let action = downAction
    let contains = containsPointer?(event.locationInWindow) ?? bounds.contains(convert(event.locationInWindow, from: nil))
    let activate = down && isEnabled && interactionEnabled && !isHiddenOrHasHiddenAncestor && contains
    cancelPress()
    if activate { action?() }
  }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    guard isEnabled, interactionEnabled, acceptsFirstResponder, [36, 49, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
    onPressed(true)
    if !event.isARepeat { onPress?() }
  }
  public override func keyUp(with event: NSEvent) {
    guard [36, 49, 76].contains(event.keyCode) else { return super.keyUp(with: event) }
    onPressed(false)
  }
  public override func accessibilityPerformPress() -> Bool {
    guard isEnabled, interactionEnabled, acceptsFirstResponder, let onPress else { return false }
    onPress()
    return true
  }
}
