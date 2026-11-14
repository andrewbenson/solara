import AppKit
import Foundation
import SolaraUI

@main
struct SadTabHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedSadTab.register()
    HostedSadTab.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    func state(_ tab: String, _ mode: String?) -> String {
      let value: [String: Any] = ["tabId": tab, "mode": mode.map { $0 as Any } ?? NSNull(), "dark": true, "textPrimary": "#ffffff", "textSecondary": "#ffffff99", "panel": "#2a2729", "panelBorder": "#ffffff11", "panelShadowOpacity": 0.3, "goButton": "#f2e8ef", "goButtonText": "#1b1618"]
      return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    let content = HostedViews.make("sadTab", windowId: "small", state: state("a", "crashed"))!
    content.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let view = content.view as! SadTabView
    expect(!content.takesFocus, "sad tab hosting must not acquire page focus")
    expect(view.showing == .crashed && view.controlFrames["Reload"] != nil, "the initial state must render the native crash controls")
    content.onState?(state("a", nil))
    failures += await verifyControlInput(view, labels: ["Reload"], present: { content.onState?(state("a", "crashed")) }, count: { SettingsAdapters.calls.count })
    view.onAction(.reload)
    await Task.yield()
    expect(SettingsAdapters.calls.last == ["pane.sadTab", "small", "a", "reload"], "reload must retain window and tab identity")
    content.onState?(state("b", "unresponsive"))
    expect(view.showing == .unresponsive && view.controlFrames["Wait"] != nil && view.controlFrames["Exit Page"] != nil, "state updates must switch to native unresponsive controls")
    content.onState?(state("b", nil))
    failures += await verifyControlInput(view, labels: ["Wait", "Exit Page"], present: { content.onState?(state("b", "unresponsive")) }, count: { SettingsAdapters.calls.count })
    for action in [SadTabAction.exit, .wait] {
      view.onAction(action)
      await Task.yield()
      expect(SettingsAdapters.calls.last == ["pane.sadTab", "small", "b", action.rawValue], "actions must use the current tab identity")
    }
    expect(HostedSadTab.describe("other") == nil, "hosting must remain scoped to its own window")
    content.onState?(state("b", nil))
    expect(view.isHidden && view.hitTest(CGPoint(x: 20, y: 20)) == nil, "a clear state must remove native drawing and hits")
    content.onState?("{}")
    let count = SettingsAdapters.calls.count
    view.onAction(.reload)
    await Task.yield()
    expect(SettingsAdapters.calls.count == count, "malformed state must disarm stale recovery actions")
    let replacement = HostedViews.make("sadTab", windowId: "small", state: state("b", "crashed"))!
    content.onUnmount?()
    expect(HostedSadTab.describe("small") != nil, "an old unmount must preserve the replacement host")
    replacement.onUnmount?()
    expect(HostedSadTab.describe("small") == nil, "unmount must release its inspection and action routes")
    if failures.isEmpty { print("PASS sad tab host state, recovery actions, keyboard traversal, Space/Return/Enter, AX press, inactive first click, page focus, replacement and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }
}
