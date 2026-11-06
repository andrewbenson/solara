import AppKit
import Foundation
import SolaraShell
import SolaraUI

final class EmbeddingContentView: NSView {
  @objc weak var solaraEmbeddedView: NSView?

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard let embedded = solaraEmbeddedView, embedded.superview === self else { return nil }
    return embedded.hitTest(local)
  }
}

@MainActor
final class SheetFixture {
  let windowId = "sheet-host"
  var window: NSWindow?
  var failures: [String] = []

  init(mounted: Bool = true, embedding: Bool = false) {
    HostedViews.events.removeAll()
    if mounted { mountWindow(embedding: embedding) }
  }

  func mountWindow(embedding: Bool = false) {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = embedding ? EmbeddingContentView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800)) : NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    content.addSubview(NSView(frame: content.bounds))
    if let content = content as? EmbeddingContentView {
      let embedded = NSView(frame: content.bounds)
      embedded.addSubview(NSView(frame: embedded.bounds))
      content.addSubview(embedded)
      content.solaraEmbeddedView = embedded
    }
    window.contentView = content
    self.window = window
    ShellDrag.windows[windowId] = window
    NotificationCenter.default.post(name: Notification.Name("RCTContentDidAppearNotification"), object: nil)
  }

  func apply(kind: String = "install", key: String = "K", busy: Bool = false, title: String = "Fixture Extension") {
    let state: [String: Any] = [
      "kind": kind,
      "key": key,
      "title": title,
      "busy": busy,
      "style": ["dark": false, "panel": "#ffffff", "panelBorder": "#cccccc", "panelShadowOpacity": 0.2],
      "install": [
        "status": busy ? "installing" : "ready",
        "title": title,
        "warnings": ["Read your browsing history"],
        "action": "Add Extension",
        "dark": false,
        "theme": [:],
        "goButton": "#111111",
        "goButtonText": "#ffffff",
      ],
      "pins": [
        "extensions": [["id": "fixture-extension", "name": "Fixture Extension", "pinned": false]],
        "dark": false,
        "theme": [:],
        "control": "#ffffff",
        "controlBorder": "#cccccc",
        "goButton": "#111111",
        "goButtonText": "#ffffff",
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: state)
    NativeSheets.set(windowId, String(data: data, encoding: .utf8)!)
  }

  func stop() {
    NativeSheets.set(windowId, nil)
    ShellDrag.windows[windowId] = nil
    window?.close()
    window = nil
  }

  func find<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
    guard let root else { return nil }
    if let view = root as? T { return view }
    for child in root.subviews {
      if let found = find(type, in: child) { return found }
    }
    return nil
  }

  var sheet: SheetView? { find(SheetView.self, in: window?.contentView) }
  var body: ExtensionDialogBody? { find(ExtensionDialogBody.self, in: sheet) }
  var events: [HostedViews.Event] {
    HostedViews.events.filter { $0.kind == "extensionSheet" && $0.windowId == windowId }
  }

  func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
  }

  func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
  }
}

@main
struct SheetHostTests {
  @MainActor
  static func presentsOnTopOfTheWindowContentView() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply()
    guard let sheet = fixture.sheet, let content = fixture.window?.contentView else { return ["the real host must mount a SheetView in the window"] }
    fixture.expect(sheet.window === fixture.window, "the sheet must belong to the registered window")
    fixture.expect(sheet.isDescendant(of: content.subviews.last!), "the sheet must be on top of the window content")
    fixture.expect(sheet.frame.size == content.bounds.size, "the sheet must fill the window content")
    fixture.expect(sheet.autoresizingMask.contains([.width, .height]), "the sheet must resize with its host")
    fixture.expect(fixture.body is ExtensionInstallView, "the sheet must use the real install body")
    fixture.expect(sheet.cardFrame.width == 380, "the sheet card must be 380 points wide")
    fixture.expect(sheet.cardFrame.height > 40, "the body must report its height to the sheet")
    content.setFrameSize(NSSize(width: 1000, height: 700))
    fixture.expect(sheet.frame.size == content.bounds.size, "resizing the window content must resize the sheet")
    fixture.expect(abs(sheet.cardFrame.midX - sheet.bounds.midX) <= 0.5, "the card must remain horizontally centered")
    return fixture.failures
  }

  @MainActor
  static func replacingTheKeySwapsTheBodyWithoutAnimating() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply()
    guard let sheet = fixture.sheet, let body = fixture.body else { return ["the first sheet and body must exist"] }
    let staleEvent = body.onEvent
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      fixture.expect(sheet.devAppearAnimating, "the first presentation must animate")
    }
    fixture.settle()
    fixture.apply(key: "K2", title: "Replacement Extension")
    fixture.expect(fixture.sheet === sheet, "a key replacement must keep the same sheet")
    fixture.expect(fixture.body !== body, "a key replacement must create a new body")
    fixture.expect(!sheet.devAppearAnimating, "a key replacement must not animate the sheet again")
    fixture.expect(!fixture.events.contains { $0.name == "closed" }, "replacing the body must not close the sheet")
    staleEvent(.confirm)
    fixture.expect(fixture.events.isEmpty, "events from the replaced body must be dropped")
    fixture.body?.onEvent(.confirm)
    fixture.expect(fixture.events.last?.payload["key"] as? String == "K2", "the replacement body must send its new key")
    let replacement = fixture.body
    fixture.apply(kind: "pins", key: "K2")
    fixture.expect(fixture.body is ExtensionPinsView && fixture.body !== replacement, "a kind replacement must create the pins body")
    fixture.expect(fixture.sheet === sheet && !sheet.devAppearAnimating, "a kind replacement must retain the sheet without animation")
    return fixture.failures
  }

  @MainActor
  static func nilEndsAndSendsClosedWithTheKey() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply(key: "closing-key")
    let sheet = fixture.sheet
    NativeSheets.set(fixture.windowId, nil)
    fixture.expect(fixture.sheet == nil, "nil state must remove the sheet")
    fixture.expect(sheet?.window == nil, "an ended sheet must leave its window")
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.name == "closed", "nil state must send exactly one closed event")
    fixture.expect(fixture.events.first?.payload["key"] as? String == "closing-key", "closed must carry the key that ended")
    NativeSheets.set(fixture.windowId, nil)
    fixture.expect(fixture.events.count == 1, "a second nil must not send another closed event")
    return fixture.failures
  }

  @MainActor
  static func windowCloseEndsTheHost() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply()
    let sheet = fixture.sheet
    fixture.window?.close()
    fixture.expect(fixture.sheet == nil && sheet?.window == nil, "closing the window must remove the sheet")
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.name == "closed", "window close must end the host exactly once")
    fixture.expect(fixture.events.first?.payload["key"] as? String == "K", "window close must preserve the sheet key")
    return fixture.failures
  }

  @MainActor
  static func busyBlocksDismissButNotConfirm() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply(busy: true)
    guard let sheet = fixture.sheet, let body = fixture.body else { return ["the busy sheet must exist"] }
    fixture.expect(sheet.busy, "the host must apply busy to the sheet")
    sheet.cancelOperation(nil)
    fixture.expect(fixture.events.isEmpty, "busy must block dismiss")
    body.onEvent(.confirm)
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.name == "confirm", "busy must not block the body confirm event")
    fixture.expect(fixture.events.first?.payload["key"] as? String == "K", "confirm must carry the key")
    HostedViews.events.removeAll()
    fixture.apply(busy: false)
    fixture.expect(fixture.sheet === sheet && fixture.body === body, "an update with the same key and kind must retain the body")
    sheet.cancelOperation(nil)
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.name == "dismiss", "ending busy must allow dismiss")
    sheet.onSubmit()
    fixture.expect(fixture.events.last?.name == "submit", "the host must forward the sheet submit event")
    return fixture.failures
  }

  @MainActor
  static func toggleCarriesIdAndPinned() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply(kind: "pins", key: "pins")
    guard let body = fixture.body as? ExtensionPinsView else { return ["the real pins body must exist"] }
    body.onEvent(.toggle("fixture-extension", true))
    body.onEvent(.toggle("fixture-extension", false))
    fixture.expect(fixture.events.count == 2, "each toggle must send one event")
    fixture.expect(fixture.events.allSatisfy { $0.name == "toggle" && $0.payload["id"] as? String == "fixture-extension" && $0.payload["key"] as? String == "pins" }, "toggle must carry its id and sheet key")
    fixture.expect(fixture.events.map { $0.payload["pinned"] as? Bool } == [true, false], "toggle must preserve both pinned values")
    body.onEvent(.done)
    fixture.expect(fixture.events.last?.name == "done", "the pins body must forward done")
    return fixture.failures
  }

  @MainActor
  static func aStateBeforeTheWindowAppliesWhenItAppears() -> [String] {
    let fixture = SheetFixture(mounted: false)
    defer { fixture.stop() }
    fixture.apply(key: "pending")
    fixture.expect(fixture.sheet == nil && fixture.events.isEmpty, "a pending state must not present without a window")
    fixture.mountWindow()
    fixture.settle()
    fixture.expect(fixture.sheet != nil, "a pending state must present when the window appears")
    fixture.body?.onEvent(.confirm)
    fixture.expect(fixture.events.last?.payload["key"] as? String == "pending", "the pending state must keep its key")
    fixture.stop()
    HostedViews.events.removeAll()
    fixture.apply(key: "dropped")
    NativeSheets.set(fixture.windowId, nil)
    HostedViews.events.removeAll()
    fixture.mountWindow()
    fixture.settle()
    fixture.expect(fixture.sheet == nil && fixture.events.isEmpty, "nil before the window appears must discard the pending sheet")
    return fixture.failures
  }

  @MainActor
  static func afterTheRetriesAWindowBecomingKeyStillMountsTheSheet() -> [String] {
    let fixture = SheetFixture(mounted: false)
    defer { fixture.stop() }
    fixture.apply(key: "late")
    let deadline = Date(timeIntervalSinceNow: 8)
    while !NativeSheets.devWatchingForWindow(fixture.windowId), Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    fixture.expect(NativeSheets.devWatchingForWindow(fixture.windowId), "after its retries the host must watch for a window")
    fixture.expect(fixture.sheet == nil, "no sheet may present without a window")
    fixture.mountWindow()
    fixture.settle()
    fixture.expect(fixture.sheet == nil, "after the retries run out the sheet waits for the window to appear")
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
    fixture.settle()
    fixture.expect(fixture.sheet != nil, "a window becoming key must mount the pending sheet")
    fixture.body?.onEvent(.confirm)
    fixture.expect(fixture.events.last?.payload["key"] as? String == "late", "the late sheet must keep its key")
    return fixture.failures
  }

  @MainActor
  static func lateEventsAfterEndAreDropped() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply()
    guard let sheet = fixture.sheet, let body = fixture.body else { return ["the first sheet must exist"] }
    let dismiss = sheet.onDismiss
    let submit = sheet.onSubmit
    let event = body.onEvent
    NativeSheets.set(fixture.windowId, nil)
    HostedViews.events.removeAll()
    dismiss()
    submit()
    event(.confirm)
    event(.cancel)
    fixture.expect(fixture.events.isEmpty, "ended host callbacks must not send events")
    fixture.apply(key: "K2")
    dismiss()
    submit()
    event(.confirm)
    fixture.expect(fixture.events.isEmpty, "callbacks from the ended host must not target a replacement host")
    fixture.body?.onEvent(.confirm)
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.payload["key"] as? String == "K2", "the replacement host must still deliver current events")
    return fixture.failures
  }

  @MainActor
  static func hostViewLeavingWindowEndsTheHost() -> [String] {
    let fixture = SheetFixture()
    defer { fixture.stop() }
    fixture.apply()
    guard let sheet = fixture.sheet, let body = fixture.body, let content = fixture.window?.contentView,
      let host = content.subviews.last else { return ["the mounted sheet host must exist"] }
    let event = body.onEvent
    host.removeFromSuperview()
    fixture.expect(fixture.sheet == nil && sheet.window == nil, "removing the host view must remove its sheet from the window")
    fixture.expect(fixture.events.count == 1 && fixture.events.first?.name == "closed", "a host leaving its window must send one closed event")
    fixture.expect(fixture.events.first?.payload["key"] as? String == "K", "a detached host must close with its key")
    HostedViews.events.removeAll()
    event(.confirm)
    sheet.onDismiss()
    fixture.expect(fixture.events.isEmpty, "a detached host must drop late events")
    return fixture.failures
  }

  @MainActor
  static func mountsInsideTheEmbeddedViewOfAnEngineWindow() -> [String] {
    let fixture = SheetFixture(embedding: true)
    defer { fixture.stop() }
    fixture.apply()
    guard let sheet = fixture.sheet, let content = fixture.window?.contentView as? EmbeddingContentView,
      let embedded = content.solaraEmbeddedView else { return ["the real host must mount a SheetView in the engine window"] }
    fixture.expect(sheet.isDescendant(of: embedded.subviews.last!), "the sheet must be the top subview of the embedded view")
    fixture.expect(sheet.frame.size == embedded.bounds.size, "the sheet must fill the embedded view")
    let point = content.convert(NSPoint(x: 20, y: 400), to: nil)
    let hit = content.superview?.hitTest(point) ?? content.hitTest(point)
    fixture.expect(hit != nil && hit!.isDescendant(of: sheet), "a click on the scrim must reach the sheet through the window's hit testing")
    return fixture.failures
  }

  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count == 2 else {
      print("FAIL: expected one SheetHost case name")
      exit(1)
    }
    let test = CommandLine.arguments[1]
    let run: @MainActor () -> [String]
    switch test {
    case "presentsOnTopOfTheWindowContentView": run = presentsOnTopOfTheWindowContentView
    case "replacingTheKeySwapsTheBodyWithoutAnimating": run = replacingTheKeySwapsTheBodyWithoutAnimating
    case "nilEndsAndSendsClosedWithTheKey": run = nilEndsAndSendsClosedWithTheKey
    case "windowCloseEndsTheHost": run = windowCloseEndsTheHost
    case "busyBlocksDismissButNotConfirm": run = busyBlocksDismissButNotConfirm
    case "toggleCarriesIdAndPinned": run = toggleCarriesIdAndPinned
    case "aStateBeforeTheWindowAppliesWhenItAppears": run = aStateBeforeTheWindowAppliesWhenItAppears
    case "lateEventsAfterEndAreDropped": run = lateEventsAfterEndAreDropped
    case "afterTheRetriesAWindowBecomingKeyStillMountsTheSheet": run = afterTheRetriesAWindowBecomingKeyStillMountsTheSheet
    case "hostViewLeavingWindowEndsTheHost": run = hostViewLeavingWindowEndsTheHost
    case "mountsInsideTheEmbeddedViewOfAnEngineWindow": run = mountsInsideTheEmbeddedViewOfAnEngineWindow
    default:
      print("FAIL \(test): unknown test")
      exit(1)
    }
    let failures = run()
    for failure in failures { print("FAIL \(test): \(failure)") }
    if failures.isEmpty { print("PASS \(test)") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
