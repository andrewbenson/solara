import AppKit
import SolaraCore
import SolaraShell
import Foundation
import Observation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
@Observable
final class NativeCliControl {
  static let shared = NativeCliControl()
  static let document = "solara-cli.json"
  static let upgradeDelay: TimeInterval = 8
  static let indicatorHold: TimeInterval = 3

  nonisolated static var active: Bool { NativeSettingsHandle.active }

  private(set) var server: CliControlServer?
  private(set) var installing: String?
  private(set) var step: String?
  private(set) var installedVersion: String?
  private(set) var binPath: String?
  private(set) var error: String?
  private(set) var indicatorShown = false {
    didSet { showPill() }
  }

  var topic: [String: Any] {
    var out: [String: Any] = ["installing": installing != nil]
    if let server {
      var entry: [String: Any] = ["state": server.state]
      if let reason = server.reason { entry["reason"] = reason }
      if let connections = server.connections { entry["connections"] = connections }
      out["server"] = entry
    }
    if let step { out["step"] = step }
    if let installedVersion { out["installedVersion"] = installedVersion }
    if let binPath { out["binPath"] = binPath }
    if let error { out["error"] = error }
    return out
  }

  @ObservationIgnored private var sync = CliControlSync()
  @ObservationIgnored private var activeTabSync = CliActiveTabSync()
  @ObservationIgnored private var activeBrowsers = CliActiveTabBrowsers()
  @ObservationIgnored private var sentTabProfiles: [String: String]?
  @ObservationIgnored private var profileGeneration: Int?
  @ObservationIgnored private var model: SettingsModel?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var indicatorHide: DispatchWorkItem?
  @ObservationIgnored private var running: [([String: Any]) -> Void] = []

  private init() {
    let saved = Self.readSaved()
    installedVersion = CliTool.installedVersion()
    binPath = saved["binPath"] as? String
    error = saved["error"] as? String
  }

  func startWhenReady(tries: Int = 40) {
    guard Self.active, !started else { return }
    if let model = NativeSettingsHandle.model { return start(model: model) }
    guard tries > 0 else { return NSLog("[cli] the native store never opened, so CLI control stays off") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NativeCliControl.shared.startWhenReady(tries: tries - 1) }
  }

  func start(model: SettingsModel) {
    guard Self.active, !started else { return }
    started = true
    self.model = model
    CliPillIndicator.shared.onStop = { NativeCliControl.shared.stop() }
    showPill()
    SolaraCoreCliSidebar.setHandler { request in
      MainActor.assumeIsolated { NativeCliControl.shared.sidebar(request) }
    }
    SolaraCoreEngineBridge.observe("cliControl") { @Sendable payload in
      let status = CliControlServer(payload)
      Task { @MainActor in NativeCliControl.shared.heard(status) }
    }
    observeActiveTabs()
    settingChanged()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.upgradeDelay) { [weak self] in self?.upgradeIfBehind() }
  }

  private func sidebar(_ request: String) -> String {
    do {
      guard !SolaraCoreHost.safeMode else { throw CommandError("Sidebar control is disabled in safe mode.") }
      guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else {
        throw CommandError("Sidebar control requires the native workspace.")
      }
      guard store.displayState.settings["cliControl"]?.bool == true else {
        throw CommandError("Let the solara command control Solara is off in Settings.")
      }
      return try store.cliSidebar(JSONValue.parse(request)).text()
    } catch {
      return JSONValue.object(["error": .string(String(describing: error))]).text()
    }
  }

  private var settingOn: Bool { model?.value("cliControl")?.bool ?? false }

  private func settingChanged() {
    withObservationTracking {
      _ = model?.settings
    } onChange: {
      Task { @MainActor in NativeCliControl.shared.settingChanged() }
    }
    guard let call = sync.settingChanged(settingOn) else { return }
    let args: [String: Any]? = switch call.call {
    case .status: nil
    case .set(let on): ["on": on]
    }
    SolaraCoreServices.call("ac_cli_control", profile: "", args: args) { @Sendable result in
      let status = CliControlServer(result)
      Task { @MainActor in NativeCliControl.shared.settled(call.request, status) }
    }
  }

  private func settled(_ request: Int, _ status: CliControlServer) {
    if sync.settled(request, status, settingOn: settingOn) { stop() }
    adoptServer()
  }

  private func heard(_ status: CliControlServer) {
    if sync.event(status, settingOn: settingOn) { stop() }
    adoptServer()
  }

  private func adoptServer() {
    if server != sync.server { server = sync.server }
    updateIndicator()
    pushActiveTab()
  }

  private func observeActiveTabs() {
    if let transaction = Self.stripTransaction(SolaraCoreTabStrip.allStrips) {
      activeBrowsers = CliActiveTabBrowsers(snapshot: transaction)
    }
    NativeStoreHandle.store?.subscribe { _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeCliControl.shared.pushActiveTab() } }
    }
    SolaraCoreEventTaps.observers.append { [weak self] name, payload in
      guard name == "tabStrip", let transaction = Self.stripTransaction(payload) else { return }
      self?.activeBrowsers.receive(transaction)
      self?.pushActiveTab()
    }
    TabPoolHost.shared.pageEventObservers.append { [weak self] _, name, _ in
      if name == "onReady" || name == "onPageGone" || name == "onDiscarded" { self?.pushActiveTab() }
    }
  }

  private static func stripTransaction(_ payload: [String: Any]) -> StripTransaction? {
    guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = try? JSONValue.parse(data) else { return nil }
    return StripTransaction(json: json)
  }

  private func pushActiveTab() {
    let serving = server?.state == "on" || server?.state == "starting"
    var chromeId: Int?
    if serving, let store = NativeStoreHandle.store {
      let memory = store.memory.chromeTabs
      let browsers = activeBrowsers.map(memory)
      var sessionIds: [String: Int] = [:]
      if SolaraCoreHost.responds(to: #selector(SolaraCoreHost.chromeTabId(browserId:))) {
        for (key, browser) in browsers {
          guard let bridgeId = Int32(exactly: browser) else { continue }
          let id = Int(SolaraCoreHost.chromeTabId(browserId: bridgeId))
          if id >= 0 { sessionIds[key] = id }
        }
      }
      let names = cliTabProfileNames(store.state, sessionIds: sessionIds)
      if sentTabProfiles != names || profileGeneration != server?.generation {
        sentTabProfiles = names
        profileGeneration = server?.generation
        SolaraCoreServices.call("ac_cli_control", profile: "", args: ["tabProfiles": names]) { @Sendable _ in }
      }
      if let browserId = cliActiveBrowserId(store.state, browsers: browsers), let bridgeId = Int32(exactly: browserId),
        SolaraCoreHost.responds(to: #selector(SolaraCoreHost.chromeTabId(browserId:)))
      {
        let id = Int(SolaraCoreHost.chromeTabId(browserId: bridgeId))
        if id >= 0 { chromeId = id }
      }
    } else {
      sentTabProfiles = nil
      profileGeneration = nil
    }
    guard let args = activeTabSync.update(serverState: server?.state, chromeId: chromeId) else { return }
    SolaraCoreServices.call("ac_cli_control", profile: "", args: args) { @Sendable _ in }
  }

  func stop() {
    model?.update(["cliControl": .bool(false)])
  }

  private func showPill() {
    CliPillIndicator.shared.set(shown: indicatorShown, product: CliTool.product, command: CliTool.command)
  }

  private func updateIndicator() {
    let on = server?.state == "on"
    let connected = on && (server?.connections ?? 0) > 0
    if connected || !on {
      indicatorHide?.cancel()
      indicatorHide = nil
      if indicatorShown != connected { indicatorShown = connected }
      return
    }
    guard indicatorShown, indicatorHide == nil else { return }
    let hide = DispatchWorkItem { [weak self] in
      self?.indicatorHide = nil
      self?.indicatorShown = false
    }
    indicatorHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.indicatorHold, execute: hide)
  }

  func install(reason: String, done: (([String: Any]) -> Void)? = nil) {
    if reason == "upgrade", SolaraCoreHost.safeMode {
      done?(["ok": false, "appVersion": CliTool.appVersion, "error": "Automatic CLI upgrades are paused in safe mode.", "lines": [String]()])
      return
    }
    if let done { running.append(done) }
    guard installing == nil else { return }
    installing = reason
    step = nil
    CliTool.install(
      onLine: { @Sendable line in
        guard line.hasPrefix("step "), let step = line.dropFirst(5).split(separator: " ").first else { return }
        Task { @MainActor in NativeCliControl.shared.step = String(step) }
      },
      done: { @Sendable result in
        nonisolated(unsafe) let result = result
        Task { @MainActor in NativeCliControl.shared.installed(result) }
      })
  }

  private func installed(_ result: [String: Any]) {
    let version = CliTool.installedVersion()
    if result["ok"] as? Bool == true {
      let path = result["binPath"] as? String
      Self.save(["binPath": path ?? NSNull(), "version": (result["version"] as? String) ?? version ?? NSNull(), "error": NSNull()])
      binPath = path
      error = nil
    } else {
      let message = (result["error"] as? String) ?? "The installer stopped."
      Self.save(["error": message])
      error = message
    }
    installing = nil
    step = nil
    installedVersion = version
    let waiting = running
    running = []
    for done in waiting { done(result) }
  }

  private func upgradeIfBehind() {
    guard !SolaraCoreHost.safeMode else { return }
    let installed = CliTool.installedVersion()
    installedVersion = installed
    let app = CliTool.appVersion
    guard let installed, !app.isEmpty, installed != app else { return }
    install(reason: "upgrade")
  }

  private static func readSaved() -> [String: Any] {
    guard let json = DocumentStore.read(document), let data = json.data(using: .utf8),
      let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return saved
  }

  private static func save(_ patch: [String: Any]) {
    var saved = readSaved()
    for (key, value) in patch { saved[key] = value }
    saved["at"] = (Date().timeIntervalSince1970 * 1000).rounded()
    guard let data = try? JSONSerialization.data(withJSONObject: saved), let json = String(data: data, encoding: .utf8) else { return }
    do { try DocumentStore.write(document, json) } catch { NSLog("[cli] couldn't save the install status: %@", String(describing: error)) }
  }
}
