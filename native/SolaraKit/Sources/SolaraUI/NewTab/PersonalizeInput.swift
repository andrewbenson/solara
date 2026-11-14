import AppKit
import SwiftUI

struct PersonalizePressable<Label: View>: View {
  let title: String
  let selected: Bool
  let action: () -> Void
  @ViewBuilder let label: (Bool, Bool) -> Label
  @State private var hovered = false
  @State private var pressed = false

  var body: some View {
    label(hovered, pressed)
      .accessibilityHidden(true)
      .overlay {
        PersonalizeInput(title: title, selected: selected, hovered: $hovered, pressed: $pressed, action: action)
      }
  }
}

private struct PersonalizeInput: NSViewRepresentable {
  let title: String
  let selected: Bool
  @Binding var hovered: Bool
  @Binding var pressed: Bool
  let action: () -> Void

  func makeNSView(context: Context) -> PersonalizeControl {
    let view = PersonalizeControl()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: PersonalizeControl, context: Context) {
    view.setAccessibilityLabel(title)
    view.setAccessibilityRole(.radioButton)
    view.setAccessibilityValue(selected ? 1 : 0)
    view.onPress = action
    view.onHover = { hovered = $0 }
    view.onPressed = { pressed = $0 }
  }
}

public final class PersonalizeControl: NSControl {
  public var onPress: (() -> Void)?
  var onHover: (Bool) -> Void = { _ in }
  var onPressed: (Bool) -> Void = { _ in }
  private var tracking: NSTrackingArea?
  private var down = false
  private var downAction: (() -> Void)?
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { onPress != nil && !isHiddenOrHasHiddenAncestor }
  public override var canBecomeKeyView: Bool { acceptsFirstResponder }
  public override var focusRingMaskBounds: NSRect { bounds }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    focusRingType = .exterior
  }

  public required init?(coder: NSCoder) { nil }
  public override func drawFocusRingMask() {
    NSColor.black.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: min(12, bounds.height / 2), yRadius: min(12, bounds.height / 2)).fill()
  }
  public override func becomeFirstResponder() -> Bool {
    guard acceptsFirstResponder else { return false }
    needsDisplay = true
    noteFocusRingMaskChanged()
    return true
  }
  public override func resignFirstResponder() -> Bool {
    down = false
    downAction = nil
    onPressed(false)
    needsDisplay = true
    noteFocusRingMaskChanged()
    return true
  }
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    tracking = area
    addTrackingArea(area)
  }
  public override func mouseEntered(with event: NSEvent) { onHover(true) }
  public override func mouseExited(with event: NSEvent) { onHover(false); onPressed(false) }
  public override func mouseDown(with event: NSEvent) { down = true; downAction = onPress; onPressed(true) }
  public override func mouseUp(with event: NSEvent) {
    let press = down && bounds.contains(convert(event.locationInWindow, from: nil))
    let action = downAction
    down = false
    downAction = nil
    onPressed(false)
    if press { action?() }
  }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    guard acceptsFirstResponder, [36, 49, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
    onPressed(true)
    if !event.isARepeat { onPress?() }
  }
  public override func keyUp(with event: NSEvent) {
    guard [36, 49, 76].contains(event.keyCode) else { return super.keyUp(with: event) }
    onPressed(false)
  }
  public override func accessibilityPerformPress() -> Bool {
    guard acceptsFirstResponder, let onPress else { return false }
    onPress()
    return true
  }
}
