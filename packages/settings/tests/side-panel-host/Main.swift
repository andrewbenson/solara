import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraCore
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

  func apply(_ width: Double, key: String = "K", url: String = "https://example.invalid/side-panel", card: String = "#ffffff") {
    let state: [String: Any] = [
      "key": key,
      "pageProfile": "fixture-profile",
      "url": url,
      "title": "Side Panel Fixture",
      "icon": NSNull(),
      "width": width,
      "room": width + 6,
      "look": [
        "card": card,
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

  var page: SolaraCoreWebView? { host.view.content.subviews.compactMap { $0 as? SolaraCoreWebView }.first }

  func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
  }
}

@MainActor
final class NativeSidePanelFixture {
  let base = SidePanelFixture()
  let store: Store
  let previousResolver = NativeStoreHandle.resolve
  let previousOwnership = NativeStoreHandle.ownsWorkspace

  init() {
    var state = BrowserState()
    var window = BrowserWindow(id: base.windowId, profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["source"]
    window.activeTabIds["default"] = "source"
    state.windows[window.id] = window
    state.windowOrder = [window.id]
    state.tabs["source"] = Tab(id: "source", windowId: window.id, profileId: "default", url: "https://source.example/", now: 0)
    store = Store(state: state, checksInvariants: false)
    NativeWindowShell.hosts[base.windowId] = SidePanelHarnessShell(base.host, shell: base.shell)
    NativeStoreHandle.resolve = { [store] in store }
    NativeStoreHandle.ownsWorkspace = true
    NativeExtensionSidePanel.open(windowId: base.windowId, profileId: "default", extensionId: "fixture",
      url: "chrome-extension://fixture/panel.html", title: "Fixture", icon: "", optionsUrl: "chrome-extension://fixture/options.html", store: store)
    HostedViews.events.removeAll()
  }

  func stop() {
    base.host.stop()
    NativeWindowShell.hosts.removeValue(forKey: base.windowId)
    NativeStoreHandle.resolve = previousResolver
    NativeStoreHandle.ownsWorkspace = previousOwnership
  }
}

@main
struct SidePanelHostTests {
  @MainActor
  static func nativeResizeAndCloseAvoidJavaScript() -> [String] {
    let fixture = NativeSidePanelFixture()
    defer { fixture.stop() }
    fixture.base.expect(NativeExtensionSidePanel.owns(fixture.base.windowId), "native opening must own the panel")
    fixture.base.host.apply(nil)
    fixture.base.expect(fixture.base.host.view.superview != nil, "a legacy nil echo must not dismiss a native panel")
    fixture.base.host.view.onResize?(480, true)
    fixture.base.settle()
    fixture.base.expect(fixture.store.state.windows[fixture.base.windowId]?.sidePanelWidth == 480, "native resize must persist in the store")
    fixture.base.host.view.onResetWidth?()
    fixture.base.settle()
    fixture.base.expect(fixture.store.state.windows[fixture.base.windowId]?.sidePanelWidth == 360, "native reset must persist in the store")
    fixture.base.host.view.onClose?()
    fixture.base.settle()
    fixture.base.expect(!NativeExtensionSidePanel.owns(fixture.base.windowId), "close must release native ownership")
    fixture.base.expect(fixture.base.host.view.superview == nil, "close must remove the native side panel")
    fixture.base.expect(HostedViews.events.isEmpty, "native resize/reset/close must emit no JavaScript semantic events")
    return fixture.base.failures
  }

  @MainActor
  static func nativeOwnershipLossClosesAndUnsubscribes() -> [String] {
    let fixture = NativeSidePanelFixture()
    defer { fixture.stop() }
    NativeStoreHandle.ownsWorkspace = false
    fixture.base.settle()
    fixture.base.expect(!NativeExtensionSidePanel.owns(fixture.base.windowId), "ownership loss must release the native record")
    fixture.base.expect(fixture.base.host.view.superview == nil, "ownership loss must remove the panel page")
    fixture.base.expect(HostedViews.events.isEmpty, "native teardown must emit no JavaScript semantic events")
    return fixture.base.failures
  }

  @MainActor
  static func nativeOpenWindowUsesStore() -> [String] {
    let fixture = NativeSidePanelFixture()
    defer { fixture.stop() }
    guard let json = NativeExtensionSidePanel.preferredJSON(fixture.base.windowId, fallback: nil), let state = SidePanelState.decode(json) else {
      return ["native side panel must publish its state"]
    }
    let accepted = NativeExtensionSidePanel.handle(windowId: fixture.base.windowId, key: state.key, name: "openWindow",
      payload: ["request": ["url": "https://opened.example/", "disposition": "foreground"]], view: fixture.base.host.view)
    fixture.base.expect(accepted, "native panel must own its openWindow event")
    fixture.base.expect(fixture.store.state.tabs.values.contains { $0.url == "https://opened.example/" }, "the store must open the requested tab")
    fixture.base.expect(HostedViews.events.isEmpty, "native links must emit no JavaScript semantic events")
    return fixture.base.failures
  }

  @MainActor
  static func nativeHostStopReleasesOwnership() -> [String] {
    let fixture = NativeSidePanelFixture()
    defer { fixture.stop() }
    fixture.base.host.stop()
    fixture.base.expect(!NativeExtensionSidePanel.owns(fixture.base.windowId), "host stop must release the native record and listener")
    fixture.base.expect(fixture.base.host.view.superview == nil, "host stop must remove its extension page")
    fixture.base.expect(HostedViews.events.isEmpty, "host stop must emit no JavaScript semantic events")
    return fixture.base.failures
  }

  @MainActor
  static func nativeProfileSwitchReplacesSameExtensionBeforeQueuedTeardown() -> [String] {
    let fixture = NativeSidePanelFixture()
    defer { fixture.stop() }
    do {
      let created = try fixture.store.dispatch(Command("createProfile", [["name": "Replacement"]]))
      guard let profileId = created.result?.string else { return ["the replacement profile must be created"] }
      let oldJSON = NativeExtensionSidePanel.preferredJSON(fixture.base.windowId, fallback: nil)
      let oldKey = oldJSON.flatMap(SidePanelState.decode)?.key
      _ = try fixture.store.dispatch(Command("switchProfile", [.string(fixture.base.windowId), .string(profileId)]))
      NativeExtensionSidePanel.open(windowId: fixture.base.windowId, profileId: profileId, extensionId: "fixture",
        url: "chrome-extension://fixture/replacement.html", title: "Replacement", icon: "", optionsUrl: nil, store: fixture.store)
      fixture.base.expect(NativeExtensionSidePanel.owns(fixture.base.windowId), "the same extension must replace its previous-profile panel before queued teardown")
      fixture.base.settle()
      guard let json = NativeExtensionSidePanel.preferredJSON(fixture.base.windowId, fallback: nil), let state = SidePanelState.decode(json) else {
        return fixture.base.failures + ["queued previous-profile tasks must not close the replacement panel"]
      }
      fixture.base.expect(state.key != oldKey, "the replacement panel must have a new lifetime key")
      fixture.base.expect(state.pageProfile == fixture.store.state.engineProfile(profileId), "the replacement page must use the selected profile")
      fixture.base.expect(state.url == "chrome-extension://fixture/replacement.html", "the replacement page must keep its requested URL")
      fixture.base.expect(fixture.base.host.view.superview === fixture.base.shell.sidePanelClip, "the replacement panel must remain mounted")
      fixture.base.expect(HostedViews.events.isEmpty, "profile replacement must need no JavaScript semantic event")
    } catch {
      fixture.base.failures.append("profile replacement failed: \(error)")
    }
    return fixture.base.failures
  }
  @MainActor
  static func nativePageSurvivesWidthAndThemeChanges() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    guard let page = fixture.page else { return ["the native host must own its page"] }
    fixture.expect(page.standalone, "the side panel page must be standalone")
    fixture.expect(page.extensionHost == "sidePanel", "the page must carry the extension lifetime tag")
    fixture.expect(page.profile == "fixture-profile", "the page must retain its profile")
    fixture.expect(page.initialURL == "https://example.invalid/side-panel", "the page must retain its URL")
    fixture.expect(page.pageBackgroundColor == .white, "loading must keep the existing white page fill")
    fixture.apply(440, card: "#12121280")
    fixture.shell.devStepSidePanel(by: 0.3)
    fixture.host.view.layoutSubtreeIfNeeded()
    fixture.expect(fixture.page === page, "width and theme changes must not recreate the native page")
    fixture.expect(page.closeCount == 0, "width and theme changes must not close the page")
    fixture.expect(page.frame == fixture.host.view.content.bounds, "native layout must size the page to its content host")
    return fixture.failures
  }

  @MainActor
  static func replacementClosesTheOldPageAndRejectsItsEvents() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    guard let old = fixture.page else { return ["the native host must own its initial page"] }
    fixture.apply(360, key: "K2", url: "https://example.invalid/replacement")
    fixture.expect(old.closeCount == 1, "replacement must close the old page exactly once")
    fixture.expect(old.delegate == nil && old.superview == nil, "replacement must detach the old page and its delegate")
    guard let page = fixture.page else { return fixture.failures + ["replacement must mount a new native page"] }
    fixture.expect(page !== old, "replacement must create a distinct page")
    fixture.expect(page.initialURL == "https://example.invalid/replacement", "replacement must load the new URL")
    HostedViews.events.removeAll()
    fixture.host.webView(old, event: "windowClose", payload: [:])
    fixture.host.webView(old, event: "openWindow", payload: ["url": "https://example.invalid/stale"])
    fixture.expect(HostedViews.events.isEmpty, "events from a replaced page must be ignored")
    fixture.host.webView(page, event: "windowClose", payload: [:])
    fixture.expect(HostedViews.events.count == 1, "the current page must still forward window.close")
    fixture.expect(HostedViews.events.first?.payload["key"] as? String == "K2", "current page events must use the replacement key")
    return fixture.failures
  }

  @MainActor
  static func closingWaitsForNativeExitAndReleasesThePage() -> [String] {
    let fixture = SidePanelFixture()
    fixture.shell.devStepSidePanel(by: 0.3)
    guard let page = fixture.page else { return ["the native host must own its page before close"] }
    fixture.host.apply(nil)
    fixture.expect(page.closeCount == 0, "the page must remain alive during the native exit")
    fixture.shell.devStepSidePanel(by: 0.3)
    fixture.expect(page.closeCount == 1, "settled exit must close the page exactly once")
    fixture.expect(page.delegate == nil && page.superview == nil, "settled exit must detach the page and delegate")
    fixture.expect(fixture.page == nil && fixture.host.view.superview == nil, "settled exit must remove the page and native panel")
    fixture.host.stop()
    fixture.expect(page.closeCount == 1, "stopping an already closed host must not close the page twice")
    return fixture.failures
  }

  @MainActor
  static func emptyPageKeepsNativeControlsAndCurrentIdentity() -> [String] {
    let fixture = SidePanelFixture()
    defer { fixture.host.stop() }
    guard let old = fixture.page else { return ["the native host must own its initial page"] }
    fixture.apply(360, key: "empty", url: "")
    fixture.expect(old.closeCount == 1, "empty content must close the previous native page")
    fixture.expect(fixture.page == nil, "empty content must retain only the native white fill")
    HostedViews.events.removeAll()
    fixture.host.view.onMenu?()
    fixture.host.view.onClose?()
    fixture.expect(HostedViews.events.map(\.name) == ["menu", "close"], "empty native chrome must retain its actions")
    fixture.expect(HostedViews.events.allSatisfy { $0.payload["key"] as? String == "empty" }, "empty native chrome must use the current state identity")
    return fixture.failures
  }

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
    case "nativeResizeAndCloseAvoidJavaScript": run = nativeResizeAndCloseAvoidJavaScript
    case "nativeOwnershipLossClosesAndUnsubscribes": run = nativeOwnershipLossClosesAndUnsubscribes
    case "nativeOpenWindowUsesStore": run = nativeOpenWindowUsesStore
    case "nativeHostStopReleasesOwnership": run = nativeHostStopReleasesOwnership
    case "nativeProfileSwitchReplacesSameExtensionBeforeQueuedTeardown": run = nativeProfileSwitchReplacesSameExtensionBeforeQueuedTeardown
    case "nativePageSurvivesWidthAndThemeChanges": run = nativePageSurvivesWidthAndThemeChanges
    case "replacementClosesTheOldPageAndRejectsItsEvents": run = replacementClosesTheOldPageAndRejectsItsEvents
    case "closingWaitsForNativeExitAndReleasesThePage": run = closingWaitsForNativeExitAndReleasesThePage
    case "emptyPageKeepsNativeControlsAndCurrentIdentity": run = emptyPageKeepsNativeControlsAndCurrentIdentity
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
