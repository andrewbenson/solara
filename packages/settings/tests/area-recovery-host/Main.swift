import AppKit
import Foundation
import SolaraUI

@main
struct AreaRecoveryHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedAreaRecovery.register()
    var failures: [String] = []
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    func state(_ id: String, plain: Bool = false, fill: Bool = false) -> String {
      let value: [String: Any] = ["recoveryId": id, "fill": fill, "plain": plain, "textPrimary": "#eeeeee", "textSecondary": "#888888", "detail": "Forced area recovery fixture\n\nAreaRecoveryFixture"]
      return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    let content = HostedViews.make("areaRecovery", windowId: "w1", state: state("a"))!
    let view = content.view as! AreaRecoveryView
    view.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
    expect(!content.takesFocus, "recovery must not acquire page focus")
    expect(view.detailText.contains("AreaRecoveryFixture"), "Debug details must survive native hosting")
    expect(events.contains { $0["name"] as? String == "height" }, "nonfill recovery must report its height")
    view.onReload()
    expect(events.last?["name"] as? String == "reload", "reload must emit its existing action")
    expect((events.last?["payload"] as? [String: Any])?["recoveryId"] as? String == "a", "reload must identify the current recovery")
    failures += await verifyControlInput(view, labels: ["Reload"], present: { content.onState?(state("a")) }, count: { events.filter { $0["name"] as? String == "reload" }.count })
    content.onState?(state("b", plain: true))
    expect(view.detailText.isEmpty, "plain recovery must hide debug details")
    expect(view.reloadControl.frame.size == CGSize(width: 180, height: 16), "plain text must retain the TextKit measurement and Yoga pixel rounding of the original recovery link: \(view.reloadControl.frame.size)")
    view.onReload()
    expect((events.last?["payload"] as? [String: Any])?["recoveryId"] as? String == "b", "updates must fence actions to the current recovery")
    failures += await verifyControlInput(view, labels: ["Reload"], present: { content.onState?(state("b", plain: true)) }, count: { events.filter { $0["name"] as? String == "reload" }.count })
    content.onState?("{}")
    let count = events.count
    view.onReload()
    expect(view.isHidden && events.count == count, "malformed state must disarm recovery")
    content.onState?(state("c", fill: true))
    expect(view.state?.fill == true, "whole-window recovery must retain fill layout")
    view.frame = CGRect(x: 0, y: 0, width: 1360, height: 860)
    expect(view.detailViewportFrame.height == 320, "fill recovery must reserve the original 320 point debug scroll viewport")
    expect(view.detailDocumentHeight > 0, "Debug detail must have a measured TextKit document")
    expect(view.reloadControl.frame.minY < 300, "the debug viewport must keep the recovery row above the window center")
    content.onUnmount?()
    view.onReload()
    expect(events.count == count && view.isHidden, "unmount must stop action routes")
    content.onState?(state("d"))
    expect(view.state == nil, "late state must not resurrect an ended host")
    if failures.isEmpty { print("PASS area recovery host state, debug detail, plain fallback, height, reload fencing, keyboard, AX, first click, focus and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }
}
