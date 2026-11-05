import AppKit
import Foundation
import SolaraUI

@MainActor
final class SidePanelFixture {
  let windowId = "side-panel-host"
  let shell: WindowShellView
  let host: SidePanelHost
  var failures: [String] = []

  init(width: Double = 360) {
    HostedViews.events.removeAll()
    shell = WindowShellView(windowId: windowId)
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    host = SidePanelHost(windowId: windowId, shell: shell)
    apply(width)
    expect(host.view.superview === shell.sidePanelClip, "the real shell must mount the side panel")
    expect(host.view.onResize != nil, "the host must install the resize callback")
    expect(host.view.onResetWidth != nil, "the host must install the reset callback")
  }

  func apply(_ width: Double, key: String = "K") {
    let state: [String: Any] = [
      "key": key,
      "pageProfile": "fixture-profile",
      "url": "https://example.invalid/side-panel",
      "title": "Side Panel Fixture",
      "icon": NSNull(),
      "width": width,
      "room": width + 6,
      "look": [
        "card": "#ffffff",
        "text": "#111111",
        "icon": "#333333",
        "hover": "#eeeeee",
        "pressed": "#dddddd",
        "hairline": "#cccccc",
        "radius": 8,
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: state)
    host.apply(String(data: data, encoding: .utf8)!)
  }

  func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
  }

  func expectWidth(_ width: CGFloat) {
    expect(host.view.width == width, "expected width \(width), got \(host.view.width)")
  }

  var savedWidths: [Double] {
    HostedViews.events.filter {
      $0.kind == "extensionSidePanel" && $0.windowId == windowId && $0.name == "resize" &&
        $0.payload["key"] as? String == "K" && $0.payload["ended"] as? Bool == true
    }.compactMap { $0.payload["width"] as? Double }
  }

  func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
  }
}

@main
struct SidePanelHostTests {
  @MainActor
  static func settleWithoutEchoFinishes() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(440, true)
    fixture.host.view.onResize?(630, true)
    fixture.expect(fixture.host.devResizeLinkActive, "oversize release must start the resize link")
    fixture.settle()
    fixture.expectWidth(600)
    fixture.expect(fixture.savedWidths == [440, 600], "ended resize widths must be [440, 600], got \(fixture.savedWidths)")
    fixture.expect(!fixture.host.devResizeLinkActive, "settle without an echo must stop the resize link")
    return fixture.failures
  }

  @MainActor
  static func staleEchoDoesNotCancelSettle() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(440, true)
    fixture.host.view.onResize?(630, true)
    fixture.apply(440)
    fixture.expect(fixture.host.devResizeLinkActive, "the stale 440 echo must leave the resize link active")
    fixture.settle()
    fixture.expectWidth(600)
    fixture.expect(fixture.savedWidths == [440, 600], "ended resize widths must be [440, 600], got \(fixture.savedWidths)")
    fixture.apply(600)
    fixture.expectWidth(600)
    fixture.expect(!fixture.host.devResizeLinkActive, "the final 600 echo must leave the resize link idle")
    return fixture.failures
  }

  @MainActor
  static func outsideWidthWinsOverDrag() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(500, false)
    fixture.expectWidth(500)
    fixture.apply(450)
    fixture.expectWidth(450)
    return fixture.failures
  }

  @MainActor
  static func droppedEchoFallsBack() -> [String] {
    let fixture = SidePanelFixture(width: 450)
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(470, true)
    fixture.expectWidth(470)
    fixture.expect(fixture.savedWidths == [470], "the unechoed release must save 470")
    fixture.apply(520)
    fixture.expectWidth(520)
    fixture.expect(!fixture.host.devResizeLinkActive, "an outside width must leave the resize link idle")
    return fixture.failures
  }

  @MainActor
  static func echoQueueIsBounded() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    for width: CGFloat in [400, 410, 420, 430, 440] {
      fixture.host.view.onResize?(width, true)
    }
    fixture.expectWidth(440)
    fixture.expect(fixture.savedWidths == [400, 410, 420, 430, 440], "all five releases must save their widths")
    fixture.apply(400)
    fixture.expectWidth(400)
    for width: Double in [410, 420, 430, 440, 500] {
      fixture.apply(width)
      fixture.expectWidth(CGFloat(width))
    }
    return fixture.failures
  }

  @MainActor
  static func keyChangeClearsQueue() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(440, true)
    fixture.apply(440, key: "K2")
    fixture.expectWidth(440)
    fixture.apply(500, key: "K2")
    fixture.expectWidth(500)
    return fixture.failures
  }

  @MainActor
  static func closeClearsQueue() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    fixture.host.view.onResize?(440, true)
    fixture.host.apply(nil)
    fixture.apply(360)
    fixture.expectWidth(360)
    fixture.apply(440)
    fixture.expectWidth(440)
    fixture.expect(!fixture.host.devResizeLinkActive, "close and reopen must leave the resize link idle")
    fixture.apply(380)
    fixture.expectWidth(380)
    return fixture.failures
  }

  @MainActor
  static func resetWidthEchoes() -> [String] {
    let fixture = SidePanelFixture(width: 500)
    defer { fixture.host.stop() }
    fixture.host.view.onResetWidth?()
    fixture.expectWidth(360)
    let resets = HostedViews.events.filter {
      $0.kind == "extensionSidePanel" && $0.windowId == fixture.windowId && $0.name == "resetWidth" &&
        $0.payload["key"] as? String == "K"
    }
    fixture.expect(resets.count == 1, "reset must send one resetWidth event for K")
    fixture.apply(360)
    fixture.expectWidth(360)
    return fixture.failures
  }

  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count == 2 else {
      print("FAIL: expected one SidePanelHost case name")
      exit(1)
    }
    let test = CommandLine.arguments[1]
    let run: @MainActor () -> [String]
    switch test {
    case "settleWithoutEchoFinishes": run = settleWithoutEchoFinishes
    case "staleEchoDoesNotCancelSettle": run = staleEchoDoesNotCancelSettle
    case "outsideWidthWinsOverDrag": run = outsideWidthWinsOverDrag
    case "droppedEchoFallsBack": run = droppedEchoFallsBack
    case "echoQueueIsBounded": run = echoQueueIsBounded
    case "keyChangeClearsQueue": run = keyChangeClearsQueue
    case "closeClearsQueue": run = closeClearsQueue
    case "resetWidthEchoes": run = resetWidthEchoes
    default:
      print("FAIL \(test): unknown test")
      exit(1)
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      print("SKIP \(test): Reduce Motion must be off")
      exit(0)
    }
    let failures = run()
    for failure in failures { print("FAIL \(test): \(failure)") }
    if failures.isEmpty { print("PASS \(test)") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
