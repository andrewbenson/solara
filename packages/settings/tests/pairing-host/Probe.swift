import AppKit
import Foundation
import SwiftUI
import SolaraUI

@MainActor enum Evidence {
  static var checks = 0
  static var failures = 0
  static var productionFactories = 0
  static func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("ASSERTION FAILED: \(message)") }
  }
}
@MainActor final class RegisteredProductionService: TrustedPairingService {
  var entries = 0
  func reached() { entries += 1; Evidence.check(false, "registered production service entry") }
  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription { reached(); return TrustedSubscription {} }
  func attach(to settingsWindow: NSWindow) -> TrustedSurface { reached(); return TrustedSurface() }
  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm { reached(); throw TrustedPairingFailure.refused(.removed) }
  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws { reached() }
  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws { reached() }
  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) { reached() }
  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? { reached(); return nil }
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws { reached() }
  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) { reached() }
}
@MainActor final class OffscreenSettingsPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@main struct Probe {
  @MainActor static func pause() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(80)) }
  @MainActor static func command(_ action: String, _ argument: String? = nil) -> [String: Any] {
    var payload = ["action": action]
    if let argument { payload["argument"] = argument }
    let body = try! JSONSerialization.data(withJSONObject: payload)
    let response = SettingsDev.drive("pairingFixture", String(data: body, encoding: .utf8))
    return (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any] ?? [:]
  }
  @MainActor static func step(_ action: String, _ argument: String? = nil) async -> [String: Any] {
    let state = command(action, argument)
    Evidence.check(state["error"] == nil, "\(action) succeeds: \(state)")
    Evidence.check(state["fixture"] as? Bool == true, "\(action) reaches fixture")
    if action != "destroy" {
      Evidence.check(state["actionControlFound"] as? Bool == true, "\(action) finds its control: \(state)")
    }
    await pause()
    return state
  }
  @MainActor static func mountReady(_ panel: NSPanel, _ variant: String? = nil) async {
    _ = await step("mount", variant)
    guard let sheet = panel.attachedSheet else { Evidence.check(false, "fixture is a real attached sheet"); return }
    sheet.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    Evidence.check(sheet.sheetParent === panel, "fixture sheet has Settings parent")
    Evidence.check(panel.sheets.contains { $0 === sheet }, "Settings lists fixture sheet")
    Evidence.check(!sheet.isKeyWindow && !panel.isKeyWindow, "fixture and Settings stay non-key")
    Evidence.check(panel.frame.maxX < 0 && sheet.frame.maxX < 0, "fixture and Settings stay offscreen")
    _ = await step("select")
    Evidence.check(command("state")["preparing"] as? Bool == true, "selection prepares comparison")
    _ = await step("ready")
    let state = await step("state")
    Evidence.check(state["comparisonPresent"] as? Bool == true, "ready reveals comparison")
    Evidence.check(state["requiredControlsFound"] as? Bool == true, "comparison finds every required control: \(state)")
  }
  @MainActor static func driverReplay(_ panel: NSPanel) async {
    await mountReady(panel)
    for action in ["allow", "space"] { _ = await step(action) }
    Evidence.check(command("state")["allowRequests"] as? Int == 0, "unchecked Allow and Space never authorize")
    _ = await step("check")
    for action in ["return", "enter"] { _ = await step(action) }
    Evidence.check(command("state")["allowRequests"] as? Int == 0, "Return and Enter never authorize")
    _ = await step("destroy")
    for checked in [false, true] {
      await mountReady(panel)
      if checked { _ = await step("check") }
      _ = await step("escape")
      let ended = await step("state")
      Evidence.check(ended["comparisonPresent"] as? Bool == false, "Escape cancels \(checked ? "checked" : "unchecked") comparison")
      Evidence.check(ended["checked"] as? Bool == false && ended["allowEnabled"] as? Bool == false, "Escape revokes acknowledgment and Allow")
      Evidence.check(ended["allowRequests"] as? Int == 0, "Escape never authorizes")
      _ = await step("destroy")
    }
    for transition in ["hide", "remount"] {
      await mountReady(panel)
      for action in ["check", "saveTarget", transition, "ready", "show", "pressSaved"] { _ = await step(action) }
      let hidden = await step("state")
      Evidence.check(hidden["comparisonPresent"] as? Bool == false, "\(transition) never restores comparison")
      Evidence.check(hidden["allowRequests"] as? Int == 0, "saved target remains revoked after \(transition)")
      _ = await step("present")
      let presented = await step("state")
      Evidence.check(presented["comparisonPresent"] as? Bool == true, "explicit presentation restores comparison")
      Evidence.check(presented["checked"] as? Bool == false, "explicit presentation stays unchecked")
      _ = await step("destroy")
    }
    for variant in ["longName", "confusable"] {
      await mountReady(panel, variant)
      _ = await step("inspect")
      for appearance in ["light", "dark"] {
        _ = await step(appearance)
        let state = await step("state")
        Evidence.check(state["nameFullyRendered"] as? Bool == true, "\(variant) \(appearance) renders full name: \(state)")
        Evidence.check(state["inspectionComplete"] as? Bool == true, "\(variant) \(appearance) renders character inspection: \(state)")
        Evidence.check(state["controlsVisible"] as? Bool == true, "\(variant) \(appearance) keeps required controls available: \(state)")
        Evidence.check(state["checked"] as? Bool == false, "\(variant) \(appearance) stays unchecked")
      }
      _ = await step("destroy")
    }
  }
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task {
      do { try await run() }
      catch { print("Settings integration error: \(error)"); exit(1) }
    }
    NSApp.run()
  }
  @MainActor static func run() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let marker = directory.appendingPathComponent(".solara-probe-scratch")
    try? FileManager.default.removeItem(at: marker)
    if CommandLine.arguments.contains("--late-mode") {
      unsetenv("SOLARA_SYNC_PAIRING_FIXTURE")
      let cached = NativeSettingsWindow.makeContext()
      Evidence.check(cached?.panes[.sync] is SyncPaneModel, "control prewarms production without fixture request")
      setenv("SOLARA_SYNC_PAIRING_FIXTURE", "1", 1)
      let service = RegisteredProductionService()
      TrustedPairingRegistration.service = service
      let panel = OffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 820, height: 620), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.alphaValue = 0
      panel.contentViewController = NativeSettingsWindow.controller()
      try Data().write(to: marker)
      Evidence.check(command("mount")["error"] != nil, "late fixture flag cannot mount over cached production provider")
      SettingsDev.destroyPairingFixture()
      Evidence.check(service.entries == 0, "rejected late mount avoids registered production service")
      panel.contentViewController = nil
      panel.orderOut(nil)
      TrustedPairingRegistration.service = nil
      print("Completed Settings integration: 1 test, \(Evidence.checks) assertions, \(Evidence.failures) failures")
      exit(Evidence.failures == 0 ? 0 : 1)
    }
    let service = RegisteredProductionService()
    TrustedPairingRegistration.service = service
    defer { TrustedPairingRegistration.service = nil }
    guard let cached = NativeSettingsWindow.makeContext() else { fatalError("missing context") }
    Evidence.check(cached.panes[.sync] is SyncPairingFixturePane, "prewarm isolates without marker")
    Evidence.check(Evidence.productionFactories == 0, "production factory never entered")
    Evidence.check(service.entries == 0, "production observer never installed")
    Evidence.check(command("mount")["error"] != nil, "missing marker denies mount")
    let panel = OffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 820, height: 620), styleMask: [.nonactivatingPanel, .closable], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.alphaValue = 0
    panel.contentViewController = NativeSettingsWindow.controller()
    panel.contentView?.layoutSubtreeIfNeeded()
    NativeSettingsWindow.observePairingLifecycle(panel)
    try Data().write(to: marker)
    await driverReplay(panel)
    Evidence.check(NativeSettingsWindow.makeContext() === cached, "context cache reused")
    Evidence.check(command("mount")["mounted"] as? Bool == true, "late marker mount admitted")
    Evidence.check(cached.panes[.sync] is SyncPairingFixturePane, "late admission has isolated parent")
    _ = command("select")
    await pause()
    _ = command("ready")
    await pause()
    Evidence.check(command("check")["error"] == nil, "native checkbox check dispatched")
    await pause()
    Evidence.check(command("state")["checked"] as? Bool == true, "check reaches binding")
    Evidence.check(command("uncheck")["error"] == nil, "native checkbox uncheck dispatched")
    await pause()
    Evidence.check(command("state")["checked"] as? Bool == false, "uncheck reaches binding")
    _ = command("check")
    await pause()
    Evidence.check(command("allow")["error"] == nil, "admitted Allow dispatched through SettingsDev")
    await pause()
    Evidence.check(command("state")["allowRequests"] as? Int == 1, "real SettingsDev Allow records one synthetic request")
    Evidence.check(service.entries == 0, "async Allow avoids permanently registered production service")
    try FileManager.default.removeItem(at: marker)
    Evidence.check(command("allow")["error"] != nil, "marker removal denies action")
    try Data().write(to: marker)
    Evidence.check(command("state")["error"] != nil, "revoked marker destroys prior session")
    _ = command("mount")
    _ = SettingsDev.drive("close", nil)
    Evidence.check(command("state")["error"] != nil, "close tears down fixture")
    panel.contentViewController = NativeSettingsWindow.controller()
    NativeSettingsWindow.observePairingLifecycle(panel)
    Evidence.check(NativeSettingsWindow.makeContext() === cached, "reopen retains isolated cached context")
    Evidence.check(command("mount")["mounted"] as? Bool == true, "reopen mounts new fixture")
    _ = command("destroy")
    Evidence.check(command("allow")["error"] != nil, "destroyed fixture denies allow")
    Evidence.check(service.entries == 0, "every real dev action avoids registered service")
    Evidence.check(Evidence.productionFactories == 0, "every real dev action avoids production factory")
    panel.contentViewController = nil
    panel.orderOut(nil)
    print("Completed Settings integration: 1 test, \(Evidence.checks) assertions, \(Evidence.failures) failures")
    exit(Evidence.failures == 0 ? 0 : 1)
  }
}
