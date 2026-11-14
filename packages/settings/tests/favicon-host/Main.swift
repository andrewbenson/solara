import AppKit
import Foundation
import SolaraUI

@main
struct FaviconHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedFavicon.register()
    var failures: [String] = []
    var events: [[String: Any]] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func state(_ uri: String, token: Int) -> String {
      "{\"url\":\"https://fixture.invalid\",\"mode\":\"image\",\"size\":16,\"dark\":false,\"textSecondary\":\"#00000080\",\"uri\":\"\(uri)\",\"token\":\(token)}"
    }
    HostedViews.emit = { events.append($0) }
    let first = HostedViews.make("favicon", windowId: "little", state: state("fixture:valid", token: 1))!
    let view = first.view as! FaviconView
    expect(view.hasImage, "resolved icons load natively")
    expect(!first.takesFocus, "decorative icons cannot take page focus")
    expect(view.hitTest(NSPoint(x: 8, y: 8)) == nil, "decorative icons cannot intercept input")
    first.onState?(state("fixture:missing", token: 2))
    try? await Task.sleep(for: .milliseconds(30))
    expect(!view.hasImage, "a failed replacement cannot retain the old picture")
    let failure = events.last?["payload"] as? [String: Any]
    expect(events.count == 1 && failure?["token"] as? Int == 2 && failure?["uri"] as? String == "fixture:missing", "image failure must return its current receipt")
    first.onState?(state("fixture:missing-late", token: 3))
    first.onState?(state("fixture:valid", token: 4))
    try? await Task.sleep(for: .milliseconds(30))
    expect(view.hasImage && view.state?.token == 4, "a cancelled replacement cannot replace the current picture")
    expect(events.count == 1, "cancelled replacements cannot emit stale failures")
    first.onState?(state("fixture:missing-ended", token: 5))
    first.onUnmount?()
    try? await Task.sleep(for: .milliseconds(30))
    expect(view.state == nil && view.isHidden && !view.hasImage, "unmount clears drawing and cancels work")
    expect(events.count == 1 && HostedFavicon.describe("little").isEmpty, "an ended host cannot emit or remain inspectable")
    first.onState?(state("fixture:valid", token: 6))
    expect(view.state == nil, "late state cannot resurrect an ended host")
    if failures.isEmpty { print("PASS native favicon host (8 checks)") }
    else { for failure in failures { print("FAIL \(failure)") }; exit(1) }
  }
}
