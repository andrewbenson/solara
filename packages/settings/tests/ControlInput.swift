import AppKit

@MainActor
private final class PageFocusView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class FirstMouseControl: NSView {
  var permitsFirstMouse = false
  var queries = 0
  var clicks = 0
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    queries += 1
    return permitsFirstMouse
  }
  override func mouseDown(with event: NSEvent) { clicks += 1 }
}

@MainActor
func verifyControlInput(_ view: NSView, labels: [String], present: () -> Void, count: () -> Int, traversalLabels: [String]? = nil) async -> [String] {
  let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
  let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  panel.isReleasedWhenClosed = false
  panel.alphaValue = 0
  let page = PageFocusView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
  panel.contentView = page
  panel.makeFirstResponder(page)
  page.addSubview(view)
  let retainedFocusOnMount = panel.firstResponder === page
  present()
  let retainedFocusOnPresentation = panel.firstResponder === page
  panel.orderBack(nil)
  defer {
    panel.orderOut(nil)
    view.removeFromSuperview()
    panel.close()
  }
  var failures: [String] = []
  func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
  }
  func find(_ label: String, in root: NSView) -> NSView? {
    if [.button, .radioButton].contains(root.accessibilityRole()) && root.accessibilityLabel() == label { return root }
    return root.subviews.lazy.compactMap { find(label, in: $0) }.first
  }
  let negative = FirstMouseControl(frame: CGRect(x: 760, y: 560, width: 40, height: 40))
  page.addSubview(negative)
  func mouseClick(_ target: NSView) {
    NSApp.deactivate()
    panel.resignKey()
    let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
      NSApp.sendEvent(event)
    }
  }
  mouseClick(negative)
  expect(negative.queries > 0 && negative.clicks == 0, "AppKit must consult first-mouse acceptance and reject the negative control")
  negative.permitsFirstMouse = true
  mouseClick(negative)
  expect(negative.clicks == 1, "AppKit must deliver the accepting control's first inactive click")
  negative.removeFromSuperview()
  panel.makeFirstResponder(page)
  panel.recalculateKeyViewLoop()
  expect(retainedFocusOnMount && retainedFocusOnPresentation, "mounting and presenting controls must preserve page focus")
  expect(!NSApp.isActive && !panel.isKeyWindow, "input fixture must remain an inactive window")
  panel.selectNextKeyView(nil)
  expect((traversalLabels ?? labels).contains((panel.firstResponder as? NSView)?.accessibilityLabel() ?? ""), "explicit key traversal must reach an overlay control")
  panel.makeFirstResponder(page)
  for label in labels {
    guard let control = find(label, in: view) else {
      failures.append("missing \(label) control")
      continue
    }
    expect(control.acceptsFirstResponder && control.canBecomeKeyView, "\(label) must accept explicit keyboard focus")
    panel.makeFirstResponder(control)
    expect(panel.firstResponder === control, "\(label) must become the explicit first responder")
    let next = control.nextValidKeyView
    let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
    panel.sendEvent(tab)
    expect(next != nil && panel.firstResponder === next, "\(label) Tab must move to the next key view")
    panel.makeFirstResponder(control)
    for (characters, code) in [(" ", UInt16(49)), ("\r", 36), ("\u{3}", 76)] {
      let before = count()
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        panel.sendEvent(event)
      }
      await Task.yield()
      expect(count() == before + 1, "\(label) key \(code) must activate once through the window")
    }
    let beforeAX = count()
    expect(control.accessibilityPerformPress(), "\(label) must expose AX press")
    await Task.yield()
    expect(count() == beforeAX + 1, "\(label) AX press must activate once")
    panel.makeFirstResponder(page)
    let beforeMouse = count()
    NSApp.deactivate()
    panel.resignKey()
    expect(!panel.isKeyWindow && !NSApp.isActive, "\(label) click must start inactive")
    mouseClick(control)
    await Task.yield()
    expect(count() == beforeMouse + 1, "\(label) first inactive click must activate through AppKit")
    expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "\(label) input must preserve the frontmost application")
  }
  return failures
}
