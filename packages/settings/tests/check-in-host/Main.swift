import AppKit
import Foundation
import SolaraUI

@MainActor
private final class CheckInPage: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@main
struct CheckInHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    HostedCheckInBanner.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    let content = HostedViews.make("checkInBanner", windowId: "window")!
    let view = content.view as! CheckInBannerView
    view.frame = CGRect(x: 0, y: 0, width: 282, height: 69)
    expect(!content.takesFocus, "banner must preserve page focus on mounting")
    content.onState?(state())
    expect(view.card.frame == CGRect(x: 8, y: 8, width: 266, height: 53), "card geometry must match RN")
    expect(view.close.frame == CGRect(x: 259, y: 0, width: 23, height: 23), "close geometry must match RN")
    expect(view.hitTest(CGPoint(x: 2, y: 40)) == nil, "banner padding must pass through")
    expect(!view.card.acceptsFirstMouse(for: nil) && view.close.acceptsFirstMouse(for: nil), "feedback must reject first clicks while dismissal retains acceptance")
    expect(!CheckInControl().acceptsFirstMouse(for: nil), "shared control must reject first clicks by default")
    view.devHover(true)
    try? await Task.sleep(for: .milliseconds(650))
    if let layer = view.card.layer {
      let transformed = layer.bounds.applying(layer.affineTransform())
      expect(abs(transformed.midX - view.card.bounds.midX) < 0.001 && abs(transformed.midY - view.card.bounds.midY) < 0.001, "hover transform must preserve the RN center anchor")
    } else { failures.append("missing backing layer for hover transform") }
    expect(view.hitTest(CGPoint(x: 7, y: 30)) === view.card, "scaled hover edge must hit the card")
    let retained = view.close.onPress
    _ = view.close.accessibilityPerformPress()
    expect(events.isEmpty && view.motion?.leaving == true, "dismissal must wait for the 220ms motion")
    content.onState?(state(profile: "replacement", token: "replacement"))
    retained?()
    try? await Task.sleep(for: .milliseconds(260))
    expect(events.isEmpty && view.state?.profileId == "replacement", "replacement must cancel completion and retained control action")
    content.onState?(state())
    view.devHover(true)
    _ = view.close.accessibilityPerformPress()
    try? await Task.sleep(for: .milliseconds(260))
    expect(events.count == 1 && (events.last?["payload"] as? [String: Any])?["action"] as? String == "dismiss", "dismiss must emit once after exit")
    expect((events.last?["payload"] as? [String: Any])?["profileId"] as? String == "profile" && (events.last?["payload"] as? [String: Any])?["token"] as? String == "token", "events must retain profile and presentation identity")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let page = CheckInPage(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = page
    window.makeFirstResponder(page)
    page.addSubview(view)
    window.orderBack(nil)
    expect(window.firstResponder === page, "mounting banner must leave page focused")
    func reset() {
      content.onState?(state(visible: false))
      content.onState?(state())
      view.devHover(true)
      view.layoutSubtreeIfNeeded()
    }
    reset()
    try? await Task.sleep(for: .milliseconds(650))
    let edge = view.convert(CGPoint(x: 7, y: 30), to: nil)
    let beforeEdge = events.count
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(with: type, location: edge, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
      NSApp.sendEvent(event)
    }
    try? await Task.sleep(for: .milliseconds(260))
    expect(events.count == beforeEdge, "inactive expanded feedback edge must not start feedback")
    for control in [view.card, view.close] {
      for code: UInt16 in [49, 36, 76] {
        reset()
        expect(control.acceptsFirstResponder && window.makeFirstResponder(control), "each banner control must accept explicit keyboard focus")
        let before = events.count
        let characters = code == 49 ? " " : code == 36 ? "\r" : "\u{3}"
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
          window.sendEvent(event)
        }
        expect(!control.accessibilityPerformPress(), "disabled exit controls must reject repeated accessibility activation")
        try? await Task.sleep(for: .milliseconds(260))
        expect(events.count == before + 1, "Space, Return and keypad Enter must each activate once after exit")
      }
      reset()
      let beforeAX = events.count
      expect(control.accessibilityPerformPress(), "each control must expose VoiceOver press")
      try? await Task.sleep(for: .milliseconds(260))
      expect(events.count == beforeAX + 1, "VoiceOver must activate once")
      reset()
      window.makeFirstResponder(page)
      NSApp.deactivate()
      window.resignKey()
      expect(!window.isKeyWindow && !NSApp.isActive, "first-click fixture must remain inactive")
      let beforeMouse = events.count
      let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.sendEvent(event)
      }
      try? await Task.sleep(for: .milliseconds(260))
      expect(events.count == beforeMouse + (control === view.card ? 0 : 1), "inactive feedback must emit nothing while dismissal remains available")
      if control === view.card {
        expect(view.motion?.leaving == false, "first activation click must not begin feedback completion")
        let beforeDeliberate = events.count
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
          if type == .leftMouseDown { control.mouseDown(with: event) } else { control.mouseUp(with: event) }
        }
        try? await Task.sleep(for: .milliseconds(260))
        expect(events.count == beforeDeliberate + 1 && (events.last?["payload"] as? [String: Any])?["action"] as? String == "feedback", "deliberate feedback click must complete once")
      }
    }
    reset()
    view.devHover(false)
    try? await Task.sleep(for: .milliseconds(650))
    expect(window.makeFirstResponder(view.close) && view.close.alphaValue > 0.99, "keyboard focus must reveal the dismiss control without pointer hover")
    reset()
    window.recalculateKeyViewLoop()
    window.makeFirstResponder(page)
    window.selectNextKeyView(nil)
    expect(window.firstResponder === view.card || window.firstResponder === view.close, "keyboard traversal must reach a banner control")
    await verifyFocus(&failures)
    reset()
    let beforeUnmount = events.count
    _ = view.close.accessibilityPerformPress()
    content.onUnmount?()
    content.onState?(state())
    try? await Task.sleep(for: .milliseconds(260))
    expect(events.count == beforeUnmount && view.state == nil, "unmount must cancel motion, events and subsequent updates")
    expect(HostedCheckInBanner.drive("window", "state", nil)["active"] as? Bool == false, "unmount must remove inspection entry")
    view.removeFromSuperview()
    window.orderOut(nil)
    window.close()
    expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "testing must preserve the owner's active application")
    if failures.isEmpty { print("PASS check-in hosting, geometry, scaled hits, profile/token fences, exit timing, keyboard, AX, inactive first clicks and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }


  @MainActor
  static func verifyFocus(_ failures: inout [String]) async {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = root
    let field = NSTextField(string: "new tab selection")
    field.frame = CGRect(x: 300, y: 300, width: 200, height: 24)
    let other = CheckInPage(frame: CGRect(x: 300, y: 350, width: 100, height: 30))
    root.addSubview(field)
    root.addSubview(other)
    window.makeFirstResponder(field)
    let selection = NSRange(location: 4, length: 3)
    (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 1, length: 2))
    let host = NSView(frame: root.bounds)
    root.addSubview(host)
    let content = HostedViews.make(HostedCheckInBanner.kind, windowId: "focus")!
    let mount = HostedMount(content: content, in: host, window: window)
    let view = content.view as! CheckInBannerView
    content.onState?(state())
    func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
    expect(field.currentEditor() === window.firstResponder, "passive banner mount must preserve field editing")
    (field.currentEditor() as? NSTextView)?.setSelectedRange(selection)
    func dismiss() {
      window.makeFirstResponder(view.close)
      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
      view.close.keyDown(with: key)
    }
    dismiss()
    try? await Task.sleep(for: .milliseconds(260))
    expect(field.currentEditor() === window.firstResponder && field.stringValue == "new tab selection" && (field.currentEditor() as? NSTextView)?.selectedRange() == selection, "keyboard banner dismissal must restore field text and selection: responder=\(String(describing: window.firstResponder)) editor=\(String(describing: field.currentEditor())) selected=\(String(describing: (field.currentEditor() as? NSTextView)?.selectedRange()))")
    content.onState?(state(visible: false))
    content.onState?(state())
    dismiss()
    window.makeFirstResponder(other)
    try? await Task.sleep(for: .milliseconds(260))
    expect(window.firstResponder === other, "banner dismissal must preserve focus moved elsewhere")
    content.onState?(state(visible: false))
    content.onState?(state())
    dismiss()
    content.onState?(state(profile: "replacement", token: "replacement"))
    try? await Task.sleep(for: .milliseconds(260))
    expect(field.currentEditor() !== window.firstResponder, "profile replacement must not restore previous profile field")
    content.onState?(state(visible: false))
    content.onState?(state())
    dismiss()
    content.onState?(state(context: "other-page"))
    content.onState?(state())
    try? await Task.sleep(for: .milliseconds(260))
    expect(field.currentEditor() !== window.firstResponder, "page replacement must not restore previous page field")
    mount.end()
    window.contentView = nil
    window.close()
  }

  static func state(visible: Bool = true, profile: String = "profile", token: String = "token", context: String = "page") -> String {
    "{\"visible\":\(visible),\"dark\":false,\"title\":\"How are you liking Solara?\",\"action\":\"Leave us feedback\",\"profileId\":\"\(profile)\",\"token\":\"\(token)\",\"icon\":\"\",\"focusContext\":\"\(context)\"}"
  }
}
