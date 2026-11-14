import AppKit
import Foundation
import SolaraUI

@main
struct SelectionHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedSelectionBar.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    let first = HostedViews.make("selectionBar", windowId: "small")!
    let other = HostedViews.make("selectionBar", windowId: "other")!
    let bar = first.view as! SelectionBarView
    let second = other.view as! SelectionBarView
    bar.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    expect(!first.takesFocus, "selection hosting must preserve page focus")
    first.onState?(state("a", top: 100, dark: true))
    expect(bar.state?.dark == true && bar.state?.top == 100 && bar.state?.label == "Search Local", "state must reach the existing native view")
    expect(bar.barFrame?.minY == 62 && bar.above, "host geometry must remain page-local")
    expect(second.state == nil, "another window must retain its own state")
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    func button(_ view: NSView) -> NSView? {
      if view.accessibilityRole() == .button { return view }
      return view.subviews.lazy.compactMap { button($0) }.first
    }
    func press() {
      guard let target = button(bar) else { return }
      let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        if type == .leftMouseDown { target.mouseDown(with: event) }
        else { target.mouseUp(with: event) }
      }
    }
    expect(button(bar)?.accessibilityLabel() == "Search Local", "the native search button must retain its accessibility label")
    first.onState?("{\"tabId\":\"a\",\"selection\":null}")
    failures += await verifyControlInput(bar, labels: ["Search Local"], present: { first.onState?(state("a", top: 100, dark: true)) }, count: { events.count })
    press()
    expect(events.last?["windowId"] as? String == "small" && events.last?["kind"] as? String == "selectionBar", "search actions must retain their window")
    expect((events.last?["payload"] as? [String: Any])?["tabId"] as? String == "a", "search actions must retain their tab")
    first.onState?(state("b", top: 20, dark: false))
    expect(!bar.above && bar.barFrame?.minY == 38, "replacement state must relayout below a selection near the top")
    press()
    expect((events.last?["payload"] as? [String: Any])?["tabId"] as? String == "b", "a reused host must act on its current tab")
    first.onState?("{\"tabId\":\"b\",\"selection\":null}")
    expect(bar.state == nil && bar.barFrame == nil, "clearing selection must remove its pixels and hit target")
    first.onState?(state("b", top: 100, dark: true))
    first.onState?("invalid")
    expect(bar.state == nil, "invalid state must clear a previously shown selection")
    first.onUnmount?()
    first.onState?(state("a", top: 100, dark: true))
    expect(bar.state == nil, "an ended host must ignore stale state updates")
    other.onUnmount?()
    expect(HostedSelectionBar.describe("small") == nil && HostedSelectionBar.describe("other") == nil, "unmount must release inspection state")
    if failures.isEmpty { print("PASS selection host mapping, actions, keyboard traversal, Space/Return/Enter, AX press, inactive first click, page focus, replacement and cleanup") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }

  static func state(_ tabId: String, top: Int, dark: Bool) -> String {
    "{\"tabId\":\"\(tabId)\",\"selection\":{\"key\":\"\(top)\",\"top\":\(top),\"bottom\":\(top + 12),\"center\":300,\"dark\":\(dark),\"icon\":\"#ffffff\",\"textPrimary\":\"#ffffff\",\"tooltip\":\"Search Local\",\"label\":\"Search Local\"}}"
  }
}
