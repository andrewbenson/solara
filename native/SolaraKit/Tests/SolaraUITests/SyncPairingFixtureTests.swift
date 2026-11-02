#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
private final class FixtureSessionRecorder: SyncPairingFixtureSession {
  var actions: [String] = []
  var destroys = 0
  func drive(_ action: String, argument: String?) -> [String: Any] {
    actions.append(action)
    return ["fixture": true, "mounted": true]
  }
  func destroy() { destroys += 1 }
}

@MainActor
struct SyncPairingFixtureHostTests {
  private func environment(_ path: String) -> [String: String] {
    ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": path, "SOLARA_SYNC_PAIRING_FIXTURE": "1", "SOLARA_TEST_REAUTH": "granted"]
  }

  private func scratch() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data().write(to: url.appendingPathComponent(".solara-probe-scratch"))
    return url
  }

  @Test func P302_prewarmWithoutMarkerNeverConstructsProductionParent() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.removeItem(at: url.appendingPathComponent(".solara-probe-scratch"))
    var productionFactories = 0
    let pane = SyncPairingFixturePane.select(environment: environment(url.path)) {
      productionFactories += 1
      return SyncPaneModel(services: FakeSyncServices(state: SyncFixture.offState()))
    }
    #expect(pane is SyncPairingFixturePane)
    #expect(productionFactories == 0)
    #expect(!SettingsDevActionAdmission.admits("pairingFixture", environment: environment(url.path)))
    try Data().write(to: url.appendingPathComponent(".solara-probe-scratch"))
    #expect(SettingsDevActionAdmission.admits("pairingFixture", environment: environment(url.path)))
    #expect(pane is SyncPairingFixturePane)
    try FileManager.default.removeItem(at: url.appendingPathComponent(".solara-probe-scratch"))
    #expect(!SettingsDevActionAdmission.admits("pairingFixture", environment: environment(url.path)))
    #expect(productionFactories == 0)
  }

  @Test func P302_mountRequiresAllDebugIsolationGuards() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    for omitted in ["SOLARA_BACKGROUND", "SOLARA_DATA_DIR", "SOLARA_SYNC_PAIRING_FIXTURE"] {
      var env = environment(url.path)
      env.removeValue(forKey: omitted)
      var made = 0
      let host = SyncPairingFixtureHost(environment: env) { _ in made += 1; return FixtureSessionRecorder() }
      #expect(host.drive("mount", settingsWindow: window)["error"] != nil)
      #expect(made == 0)
    }
    var made = 0
    let host = SyncPairingFixtureHost(environment: environment(url.path)) { _ in made += 1; return FixtureSessionRecorder() }
    #expect(host.drive("mount", settingsWindow: window)["fixture"] as? Bool == true)
    #expect(made == 1)
  }

  @Test func P302_markerRevocationTearsDownAndReopenRequiresReadmission() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = FixtureSessionRecorder()
    let host = SyncPairingFixtureHost(environment: environment(url.path)) { _ in session }
    let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    _ = host.drive("mount", settingsWindow: window)
    try FileManager.default.removeItem(at: url.appendingPathComponent(".solara-probe-scratch"))
    #expect(host.drive("allow", settingsWindow: window)["error"] != nil)
    #expect(!host.isMounted)
    #expect(session.destroys == 1)
    try Data().write(to: url.appendingPathComponent(".solara-probe-scratch"))
    #expect(host.drive("state", settingsWindow: window)["error"] != nil)
    _ = host.drive("mount", settingsWindow: window)
    #expect(host.isMounted)
    host.destroy()
    #expect(session.destroys == 2)
  }

  @Test func P302_markerAndWindowAreRequired() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    var made = 0
    let host = SyncPairingFixtureHost(environment: environment(url.path)) { _ in made += 1; return FixtureSessionRecorder() }
    #expect(host.drive("mount", settingsWindow: nil)["error"] != nil)
    try FileManager.default.removeItem(at: url.appendingPathComponent(".solara-probe-scratch"))
    let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    #expect(host.drive("mount", settingsWindow: window)["error"] != nil)
    #expect(made == 0)
  }

  @Test func P302_absentDestroyedAndUnknownActionsNeverFallback() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = FixtureSessionRecorder()
    var made = 0
    let host = SyncPairingFixtureHost(environment: environment(url.path)) { _ in made += 1; return session }
    let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    #expect(host.drive("allow", settingsWindow: window)["error"] != nil)
    #expect(made == 0)
    _ = host.drive("mount", settingsWindow: window)
    #expect(host.drive("recovery", settingsWindow: window)["error"] != nil)
    #expect(host.drive("creation", settingsWindow: window)["error"] != nil)
    #expect(session.actions.isEmpty)
    host.destroy()
    #expect(session.destroys == 1)
    #expect(host.drive("allow", settingsWindow: window)["error"] != nil)
    #expect(session.actions.isEmpty)
    #expect(made == 1)
  }

  @Test func P302_everyActionTeardownAndReopenUseOnlyFixtureSession() throws {
    let url = try scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = FixtureSessionRecorder()
    var made = 0
    let host = SyncPairingFixtureHost(environment: environment(url.path)) { _ in made += 1; return session }
    let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    _ = host.drive("mount", settingsWindow: window)
    let actions = ["state", "select", "ready", "check", "uncheck", "allow", "space", "return", "enter", "escape", "saveTarget", "pressSaved", "inspect", "hide", "show", "remount", "present", "snapshot", "light", "dark", "longName", "confusable"]
    for action in actions {
      #expect(host.drive(action, settingsWindow: window)["fixture"] as? Bool == true)
    }
    #expect(session.actions == actions)
    #expect(made == 1)
    _ = host.drive("destroy", settingsWindow: window)
    #expect(session.destroys == 1)
    #expect(host.drive("state", settingsWindow: window)["error"] != nil)
    _ = host.drive("mount", settingsWindow: window)
    #expect(made == 2)
    host.destroy()
    #expect(session.destroys == 2)
  }
}
#endif
#if DEBUG
@MainActor
private final class FixtureProductionSpies: TrustedPairingService {
  var productionService = 0
  private func reached() { productionService += 1; Issue.record("Registered production pairing service entered from fixture") }
  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription { reached(); return TrustedSubscription {} }
  func attach(to settingsWindow: NSWindow) -> TrustedSurface { reached(); return TrustedSurface() }
  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm { reached(); return TrustedArm(deadline: 0) }
  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws { reached() }
  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws { reached() }
  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) { reached() }
  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? { reached(); return nil }
  func toleratesSoftLoss(_ arm: TrustedArm) -> Bool { false }
  func panelLive(_ arm: TrustedArm) -> Bool { false }
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws { reached() }
  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) { reached() }
}

extension SyncPairingOffscreenTests {
@MainActor
struct SyncPairingDisplayFixtureTests {
  private func yieldTasks() async {
    for _ in 0..<30 { await Task.yield() }
  }

  @Test(arguments: ["hide", "remount"])
  func hiddenComparisonReturnsUncheckedOnlyAfterExplicitPresentation(transition: String) async throws {
    await configurePairingTestApplication()
    let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-presentation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: data) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let environment = ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": data.path, "SOLARA_SYNC_PAIRING_FIXTURE": "1"]
    let host = SyncPairingFixtureHost(environment: environment)
    let settings = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.alphaValue = 0
    defer { host.destroy(); settings.contentView = nil; settings.orderOut(nil) }
    func drive(_ action: String) -> [String: Any] { host.drive(action, settingsWindow: settings) }
    #expect(drive("mount")["error"] == nil)
    #expect(drive("select")["error"] == nil)
    await yieldTasks()
    #expect(drive("ready")["comparisonPresent"] as? Bool == true)
    #expect(drive("check")["checked"] as? Bool == true)
    #expect(drive("saveTarget")["error"] == nil)
    _ = drive(transition)
    _ = drive("ready")
    _ = drive("show")
    _ = drive("pressSaved")
    await yieldTasks()
    let hidden = drive("state")
    #expect(hidden["armActive"] as? Bool == true)
    #expect(hidden["comparisonPresent"] as? Bool == false)
    #expect(hidden["allowRequests"] as? Int == 0)
    #expect(drive("present")["error"] == nil)
    await yieldTasks()
    let presented = drive("state")
    #expect(presented["armActive"] as? Bool == true)
    #expect(presented["comparisonPresent"] as? Bool == true)
    #expect(presented["checked"] as? Bool == false)
    #expect(presented["allowEnabled"] as? Bool == false)
    #expect(presented["allowRequests"] as? Int == 0)
    #expect(presented["realAuthenticationRequests"] as? Int == 0)
    #expect(presented["releaseRequests"] as? Int == 0)
  }

  @Test func interruptedExchangeShowsLocalRetryCopyInSettings() async throws {
    await configurePairingTestApplication()
    let accessibility = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    defer { NSApp.accessibilitySetValue(accessibility ?? false, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")) }
    let service = TrustedPairingTestService()
    service.clock = TrustedPairingClock.now()
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    let pane = SyncPaneModel(services: services, pairingService: service)
    await pane.prepare(SettingsPlace(pane: .sync))
    let model = try #require(pane.pairing)
    let settings = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 1000), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.alphaValue = 0
    defer { model.teardown(); settings.contentView = nil; settings.orderOut(nil) }
    model.attach(to: settings)
    model.connect()
    _ = service.ready(model)
    model.surfaceChanged(.removed)
    settings.contentView = NSHostingView(rootView: SyncPane(model: pane))
    settings.orderFront(nil)
    await yieldTasks()
    settings.contentView?.layoutSubtreeIfNeeded()
    var visited = Set<ObjectIdentifier>()
    func strings(_ object: NSObject) -> [String] {
      guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
      var result = [(object as? NSTextField)?.stringValue, (object as? NSTextView)?.string].compactMap { $0 }
      for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String { result.append(value) }
      }
      var children = (object as? NSView)?.subviews.map { $0 as NSObject } ?? []
      let selector = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: selector), let values = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children += values }
      return result + children.flatMap(strings)
    }
    let rendered = settings.contentView.map(strings) ?? []
    #expect(rendered.contains("Pairing stopped. Try again."))
    #expect(rendered.contains("Connect another Mac"))
    #expect(!rendered.contains("This request ended. Start again on the other Mac."))
  }

  @Test func P302_debugFixtureActionsCannotReachRegisteredProductionServiceOrItsEntries() async throws {
    if ProcessInfo.processInfo.environment["SOLARA_PAIRING_OFFSCREEN_TESTS"] == "1" { await configurePairingTestApplication() }
    let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-isolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: data) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let spies = FixtureProductionSpies()
    func registered<T>(_ action: () throws -> T) rethrows -> T {
      let previous = TrustedPairingRegistration.service
      TrustedPairingRegistration.service = spies
      defer { TrustedPairingRegistration.service = previous }
      return try action()
    }
    let environment = ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": data.path, "SOLARA_SYNC_PAIRING_FIXTURE": "1", "SOLARA_TEST_REAUTH": "granted"]
    var productionFactories = 0
    let pane = registered { SyncPairingFixturePane.select(environment: environment) {
      productionFactories += 1
      return SyncPaneModel(services: FakeSyncServices(state: SyncFixture.offState()), pairingService: spies)
    } }
    await pane.prepare(SettingsPlace(pane: .sync))
    #expect(pane is SyncPairingFixturePane)
    #expect(pane.isLoaded(SettingsPlace(pane: .sync)))
    let host = SyncPairingFixtureHost(environment: environment)
    func drive(_ action: String, argument: String? = nil, settingsWindow: NSWindow?) -> [String: Any] {
      registered { host.drive(action, argument: argument, settingsWindow: settingsWindow) }
    }
    let settings = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.alphaValue = 0
    settings.contentView = NSHostingView(rootView: pane.view(SettingsPlace(pane: .sync)))
    settings.contentView?.layoutSubtreeIfNeeded()
    #expect(drive("allow", settingsWindow: settings)["error"] != nil)
    _ = drive("mount", settingsWindow: settings)
    _ = drive("select", settingsWindow: settings)
    await yieldTasks()
    #expect(drive("state", settingsWindow: settings)["preparing"] as? Bool == true)
    _ = drive("ready", settingsWindow: settings)
    #expect(drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == true)
    #expect(drive("check", settingsWindow: settings)["checked"] as? Bool == true)
    await yieldTasks()
    #expect(drive("uncheck", settingsWindow: settings)["checked"] as? Bool == false)
    #expect(drive("state", settingsWindow: settings)["allowEnabled"] as? Bool == false)
    #expect(drive("check", settingsWindow: settings)["checked"] as? Bool == true)
    await yieldTasks()
    _ = drive("allow", settingsWindow: settings)
    await yieldTasks()
    let allowed = drive("state", settingsWindow: settings)
    #expect(allowed["allowRequests"] as? Int == 1)
    #expect(allowed["realAuthenticationRequests"] as? Int == 0)
    #expect(allowed["releaseRequests"] as? Int == 0)
    #expect(allowed["authenticating"] as? Bool == true)
    #expect(allowed["comparisonPresent"] as? Bool == false)
    #expect(allowed["nameFullyRendered"] as? Bool == false)
    #expect(allowed["inspectionComplete"] as? Bool == false)
    let controls = try #require(allowed["controlsFound"] as? [String: Bool])
    #expect(controls["checkbox"] == false)
    #expect(controls["inspect"] == false)
    #expect(controls["name"] == false)
    #expect(allowed["requiredControlsFound"] as? Bool == true)
    _ = drive("hide", settingsWindow: settings)
    _ = drive("show", settingsWindow: settings)
    await yieldTasks()
    let stopped = drive("state", settingsWindow: settings)
    #expect(stopped["ended"] as? Bool == true)
    #expect(stopped["armActive"] as? Bool == false)
    #expect(stopped["comparisonPresent"] as? Bool == false)
    #expect(stopped["allowEnabled"] as? Bool == false)
    #expect(stopped["endedMessage"] as? String == "Pairing stopped. Try again.")
    #expect(stopped["retryAvailable"] as? Bool == true)
    #expect(stopped["allowRequests"] as? Int == 1)
    #expect(stopped["realAuthenticationRequests"] as? Int == 0)
    #expect(stopped["releaseRequests"] as? Int == 0)
    #expect(drive("present", settingsWindow: settings)["error"] == nil)
    await yieldTasks()
    #expect(drive("state", settingsWindow: settings)["choosing"] as? Bool == true)
    _ = drive("select", settingsWindow: settings)
    await yieldTasks()
    #expect(drive("state", settingsWindow: settings)["preparing"] as? Bool == true)
    _ = drive("ready", settingsWindow: settings)
    #expect(drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == true)
    _ = drive("destroy", settingsWindow: settings)
    _ = drive("mount", settingsWindow: settings)
    _ = drive("select", settingsWindow: settings)
    await yieldTasks()
    _ = drive("ready", settingsWindow: settings)
    let actions = ["check", "saveTarget", "uncheck", "check", "pressSaved", "return", "enter", "inspect", "light", "dark", "hide", "ready", "show", "remount", "present", "allow", "space", "escape"]
    for action in actions { _ = drive(action, settingsWindow: settings); await yieldTasks() }
    _ = drive("snapshot", argument: data.appendingPathComponent("fixture.png").path, settingsWindow: settings)
    _ = drive("longName", settingsWindow: settings)
    _ = drive("confusable", settingsWindow: settings)
    _ = drive("destroy", settingsWindow: settings)
    #expect(drive("allow", settingsWindow: settings)["error"] != nil)
    _ = drive("mount", settingsWindow: settings)
    registered { host.destroy() }
    #expect(productionFactories == 0)
    #expect(spies.productionService == 0)
  }
}
}
#endif
