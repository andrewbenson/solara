import AppKit
import Foundation
import SolaraUI

@main
struct PersonalizeHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedPersonalize.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    let first = HostedViews.make("personalize", windowId: "first")!
    let other = HostedViews.make("personalize", windowId: "other")!
    let view = first.view as! PersonalizeView
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    expect(!first.takesFocus, "hosting must preserve page focus")
    first.onState?(state(open: false))
    expect(view.state?.layout == "sidebar" && view.state?.color == "plum", "state must map to native view")
    expect(view.buttonFrame == CGRect(x: 754, y: 555.5, width: 30, height: 30), "button must match RN insets")
    expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil, "closed overlay must pass through outside button")
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    expect(HostedPersonalize.drive("first", "press", "Personalize")["accepted"] as? Bool == true, "palette must expose AX press")
    expect((events.last?["payload"] as? [String: Any])?["open"] as? Bool == true, "palette must request open")
    first.onState?(state(open: true))
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    expect(view.panelFrame?.width == 352 && view.panelFrame?.maxY == 546, "panel must preserve width and bottom anchor")
    expect((other.view as! PersonalizeView).state == nil, "windows must keep independent state")
    let blue = HostedPersonalize.drive("first", "find", "Blue")
    expect(blue["found"] as? Bool == true && blue["value"] as? Int == 0, "existing Swift picker must expose native radio")
    _ = HostedPersonalize.drive("first", "press", "Blue")
    expect(events.last?["name"] as? String == "color" && (events.last?["payload"] as? [String: Any])?["color"] as? String == "blue", "color choice must emit current host action")
    expect((events.last?["payload"] as? [String: Any])?["profileId"] as? String == "profile", "choices must retain profile identity")
    _ = HostedPersonalize.drive("first", "press", "Classic")
    expect(events.last?["name"] as? String == "layout" && (events.last?["payload"] as? [String: Any])?["layout"] as? String == "top", "layout choice must retain mapping")
    first.onState?(state(open: false))
    failures += await verifyControlInput(view, labels: ["Personalize"], present: { first.onState?(state(open: false)) }, count: { events.count })
    first.onState?(state(open: true))
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    failures += await verifyControlInput(view, labels: ["Personalize", "Blue", "Classic"], present: {}, count: { events.count }, traversalLabels: ProfileColorValue.allCases.map(\.name) + ["Personalize", "Sidebar", "Classic"])
    first.onState?(state(open: true))
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    func control(_ label: String, in root: NSView) -> PersonalizeControl? {
      if let control = root as? PersonalizeControl, control.accessibilityLabel() == label { return control }
      return root.subviews.lazy.compactMap { control(label, in: $0) }.first
    }
    if let blueControl = control("Blue", in: view) {
      let saved = blueControl.onPress
      let point = blueControl.convert(CGPoint(x: blueControl.bounds.midX, y: blueControl.bounds.midY), to: nil)
      let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
      blueControl.mouseDown(with: down)
      first.onState?(state(open: true).replacingOccurrences(of: "profile\"", with: "replacement\""))
      view.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(80))
      let before = events.count
      saved?()
      expect(events.count == before, "retained UI action must not be relabeled with a replacement profile")
      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
      blueControl.mouseUp(with: up)
      expect(events.count == before, "a mouse sequence begun in another profile must be cancelled")
    } else { failures.append("missing Blue control for replacement fence") }
    first.onState?(state(open: true, canPickColor: false))
    view.layoutSubtreeIfNeeded()
    expect(HostedPersonalize.drive("first", "find", "Blue")["found"] as? Bool == false, "private state must omit color controls")
    let focusWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    focusWindow.isReleasedWhenClosed = false
    focusWindow.alphaValue = 0
    focusWindow.contentView = view
    first.onState?(state(open: true))
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    if let blue = control("Blue", in: view) {
      focusWindow.makeFirstResponder(blue)
      first.onState?(state(open: false))
      expect((focusWindow.firstResponder as? NSView)?.accessibilityLabel() == "Personalize", "closing a focused picker must return focus to palette")
    } else { failures.append("missing focusable Blue picker") }
    first.onState?(state(open: true))
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    if let blue = control("Blue", in: view) { focusWindow.makeFirstResponder(blue) }
    first.onState?("invalid")
    expect((focusWindow.firstResponder as? NSView).map { !$0.isDescendant(of: view) } ?? true, "invalidating the host must clear owned keyboard focus")
    focusWindow.contentView = nil
    focusWindow.close()
    expect(view.state == nil && view.panelFrame == nil && view.hitTest(CGPoint(x: 769, y: 570)) == nil, "invalid state must clear pixels and targets")
    first.onUnmount?()
    first.onState?(state(open: true))
    expect(view.state == nil && HostedPersonalize.drive("first", "state", nil)["active"] as? Bool == false, "ended host must ignore updates and leave no inspection entry")
    other.onUnmount?()
    let mountedContent = HostedViews.make("personalize", windowId: "lifecycle")!
    let mountedView = mountedContent.view as! PersonalizeView
    let lifecycleWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    lifecycleWindow.isReleasedWhenClosed = false
    lifecycleWindow.alphaValue = 0
    let lifecycleHost = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    lifecycleWindow.contentView = lifecycleHost
    let mount = HostedMount(content: mountedContent, in: lifecycleHost, window: lifecycleWindow)
    mountedContent.onState?(state(open: true))
    mountedView.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    if let blue = control("Blue", in: mountedView) {
      expect(lifecycleWindow.makeFirstResponder(blue) && lifecycleWindow.firstResponder === blue, "lifecycle fixture must focus its mounted picker")
      mount.end()
      expect(mountedView.window == nil && blue.window == nil, "HostedMount.end must detach picker views")
      expect(lifecycleWindow.firstResponder !== blue, "HostedMount.end must not retain a detached picker as first responder")
      expect((lifecycleWindow.firstResponder as? NSView).map { $0.window === lifecycleWindow } ?? true, "HostedMount.end must leave no detached view as first responder")
      expect(mountedView.state == nil && HostedPersonalize.drive("lifecycle", "state", nil)["active"] as? Bool == false, "real unmount must clear state and inspection entry")
    } else { failures.append("missing mounted picker for lifecycle test"); mount.end() }
    lifecycleWindow.contentView = nil
    lifecycleWindow.close()
    if failures.isEmpty { print("PASS personalize hosting, geometry, mapping, native pickers, focus, Space/Return/Enter, AX, first click, invalid state and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }

  static func state(open: Bool, canPickColor: Bool = true) -> String {
    "{\"open\":\(open),\"dark\":true,\"tokens\":{},\"color\":\"plum\",\"layout\":\"sidebar\",\"canPickColor\":\(canPickColor),\"profileId\":\"profile\"}"
  }
}
