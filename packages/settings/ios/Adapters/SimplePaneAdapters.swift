import AppKit
import SolaraCore
import SolaraShell
import Foundation
import Observation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

@MainActor
final class GeneralAdapter: GeneralServices {
  func loginItemStatus() async -> LoginItemStatus { SettingsAdapters.loginItemStatus() }

  func setLaunchAtLogin(_ on: Bool) async { SettingsAdapters.setLaunchAtLogin(on) }

  func isDefaultBrowser() async -> Bool { SystemServices.isDefaultBrowser() }

  func setAsDefaultBrowser() async -> Bool { await SettingsAdapters.setAsDefaultBrowser() }

  func downloadSettings(profile: String) async -> DownloadSettings? {
    await Self.downloadsCall("ac_downloads_settings", profile: profile, args: nil)
  }

  func setDownloadSettings(folder: String?, askWhereToSave: Bool?, profile: String) async -> DownloadSettings? {
    var patch: [String: Any] = [:]
    if let folder { patch["folder"] = folder }
    if let askWhereToSave { patch["askWhereToSave"] = askWhereToSave }
    return await Self.downloadsCall("ac_downloads_set_settings", profile: profile, args: patch)
  }

  private static func downloadsCall(_ name: String, profile: String, args: [String: Any]?) async -> DownloadSettings? {
    guard !profile.hasPrefix("incognito") else { return nil }
    return await EngineCalls.result({ done in SolaraCoreServices.call(name, profile: profile, args: args) { done($0) } }) {
      EngineCalls.failed($0, name) ? nil : Self.downloads($0)
    }
  }

  func pickFolder(current: String, prompt: String) async -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
    let response = await panel.begin()
    return response == .OK ? panel.url?.path : nil
  }

  func openImport() { SettingsJS.shared.fire("general.openImport") }

  nonisolated static func downloads(_ dict: [String: Any]) -> DownloadSettings? {
    guard let folder = dict.string("folder") else { return nil }
    return DownloadSettings(folder: folder, askWhereToSave: dict.bool("askWhereToSave") ?? false, managed: dict.bool("managed") ?? false)
  }
}

@MainActor
final class AppearanceAdapter: AppearanceServices {
  func appIcons(size: CGFloat) async -> (icons: [AppIconChoice], current: String?) {
    let icons = SystemServices.appIconChoices.map { AppIconChoice(id: $0.id, name: $0.name, preview: SystemServices.appIconPreview($0.id, size: size)) }
    return (icons, SystemServices.currentAppIcon)
  }

  func setAppIcon(_ id: String) async { SystemServices.setAppIcon(id) }

  func setAppearance(_ mode: String) async {
    NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
  }
}

@MainActor
final class SearchEngineAdapter: SearchEngineServices {
  private let model: SettingsModel
  private var engineCounter = 0

  init(model: SettingsModel) {
    self.model = model
  }

  func engineList() -> SearchEngineList {
    let settings = model.settings
    let engines = SolaraOmnibox.searchEngines(settings).map { engine in
      SearchEngineItem(
        id: engine.id,
        name: engine.name,
        keyword: engine.keyword,
        url: engine.url,
        host: SolaraOmnibox.engineHost(engine),
        custom: engine.custom,
        extensionName: engine.extension.map(\.name)
      )
    }
    let controlling = SolaraOmnibox.controllingSearchExtension(settings).map {
      ControllingSearchExtension(extensionId: $0.extensionId, extensionName: $0.extensionName, profile: $0.profile)
    }
    return SearchEngineList(engines: engines, selectedId: SolaraOmnibox.defaultSearchEngine(settings).id, controlling: controlling)
  }

  func setSearchEngine(_ id: String) {
    guard SolaraOmnibox.searchEngines(model.settings).contains(where: { $0.id == id }) else { return }
    model.update(["searchEngine": .string(id)])
  }

  func addCustomEngine(_ input: SearchEngineInput) async -> String? {
    let settings = model.settings
    let typed = Self.engineInput(input)
    if let error = SolaraOmnibox.validateCustomEngine(settings, typed) { return error }
    engineCounter += 1
    let engine = SolaraOmnibox.makeCustomEngine(typed, id: Self.engineId(engineCounter))
    model.update(["customSearchEngines": .array(Self.stored(settings) + [Self.json(engine)])])
    return nil
  }

  func updateCustomEngine(_ id: String, _ input: SearchEngineInput) async -> String? {
    let settings = model.settings
    guard SolaraOmnibox.customSearchEngines(settings).contains(where: { $0.id == id }) else { return "This search engine no longer exists." }
    let typed = Self.engineInput(input)
    if let error = SolaraOmnibox.validateCustomEngine(settings, typed, ignoreId: id) { return error }
    let replacement = Self.json(SolaraOmnibox.makeCustomEngine(typed, id: id))
    model.update(["customSearchEngines": .array(Self.stored(settings).map { $0["id"]?.string == id ? replacement : $0 })])
    return nil
  }

  func removeCustomEngine(_ id: String) {
    let settings = model.settings
    var patch: JSONObject = ["customSearchEngines": .array(Self.stored(settings).filter { $0["id"]?.string != id })]
    if settings.string("searchEngine") == id { patch["searchEngine"] = Settings.defaults["searchEngine"] }
    model.update(patch)
  }

  func manageExtensions(profile: String) {
    guard !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return }
    let profileId = SettingsOpening.extensionsProfile(engine: profile, in: store.state)
    NativeSettingsWindow.navigate(pane: "extensions", profileId: profileId, detail: nil)
    WindowHost.openAuxiliary(id: NativeSettingsWindow.windowId, kind: "settings", title: "Settings")
  }

  func disableExtension(profile: String, extensionId: String) async {
    _ = await EngineCalls.result({ done in SolaraCoreServices.setExtension(extensionId, enabled: false, profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "search.disableExtension")
    }
    SettingsJS.shared.fire("extensions.refresh", profile)
  }

  static func engineInput(_ input: SearchEngineInput) -> SolaraOmnibox.EngineInput {
    SolaraOmnibox.EngineInput(name: input.name, keyword: input.keyword, url: input.url)
  }

  static func stored(_ settings: Settings) -> [JSONValue] {
    settings["customSearchEngines"]?.array ?? []
  }

  static func json(_ engine: CustomSearchEngine) -> JSONValue {
    .object(["id": .string(engine.id), "name": .string(engine.name), "keyword": .string(engine.keyword), "url": .string(engine.url)])
  }

  static func engineId(_ counter: Int) -> String {
    "engine-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))-\(String(counter, radix: 36))"
  }
}

@MainActor
final class EnginesAdapter: EnginesServices {
  private let model: SettingsModel

  init(model: SettingsModel) {
    self.model = model
  }

  func setWebsiteEngine(_ site: String, _ engine: String?) {
    guard let site = Self.siteOf(site) else { return }
    var rules = model.settings["websiteEngines"]?.object ?? [:]
    rules[site] = engine.map(JSONValue.string)
    model.update(["websiteEngines": .object(rules)])
  }

  func site(forTyped address: String) -> String? {
    let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = typed.range(of: "^[a-z][\\w+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil ? typed : SolaraOmnibox.resolveInput(typed, search: "")
    return Self.siteOf(url)
  }

  nonisolated static func siteOf(_ url: String) -> String? {
    guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty else { return nil }
    let defaultPort = scheme == "https" ? 443 : 80
    let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)".lowercased()
  }

  func passkeyAccess() async -> PasskeyAccess? {
    Self.passkeys(SolaraCoreSettingsBridge.passkeyAccess())
  }

  func requestPasskeyAccess() async -> PasskeyAccess? {
    await EngineCalls.result({ done in SolaraCoreSettingsBridge.requestPasskeyAccess { done($0) } }) { Self.passkeys($0) }
  }

  func openPasskeySystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[settings] background instance, not opening %@", url.absoluteString) }
    NSWorkspace.shared.open(url)
  }

  nonisolated static func passkeys(_ dict: [String: Any]?) -> PasskeyAccess? {
    guard let dict, let status = dict.string("status").flatMap(PasskeyAccessStatus.init(rawValue:)) else { return nil }
    return PasskeyAccess(entitled: dict.bool("entitled") ?? false, status: status)
  }
}

@MainActor
@Observable
final class AdvancedAdapter: AdvancedServices {
  @ObservationIgnored private let model: SettingsModel
  private var jsCli: [String: Any]
  @ObservationIgnored private var observers: [UUID] = []

  init(model: SettingsModel) {
    self.model = model
    jsCli = SettingsJS.shared.latestValue("advanced.cli") as? [String: Any] ?? [:]
    observers.append(SettingsJS.shared.observe("advanced.cli") { [weak self] in self?.jsCli = $0 as? [String: Any] ?? [:] })
  }

  func chromiumVersion() async -> String? {
    if let version = AboutInfo.read().chromiumVersion { return version }
    return SolaraCoreHost.engineInfo["chromiumVersion"] as? String
  }

  func widevineVersion() async -> String?? {
    let version = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      SolaraCoreServices.components { list in continuation.resume(returning: Self.widevine(list)) }
    }
    return .some(version)
  }

  nonisolated static func widevine(_ list: [Any]) -> String? {
    list.compactMap { $0 as? [String: Any] }.first { $0.string("id") == "oimompecagnajdejgnnjijobebaeigek" }?.string("version")
  }

  private var cli: [String: Any] { NativeCliControl.active ? NativeCliControl.shared.topic : jsCli }

  var cliServer: CliServerStatus? {
    cli.dict("server").map { CliServerStatus(state: $0.string("state") ?? "off", reason: $0.string("reason"), connections: $0.int("connections")) }
  }

  var cliInstall: CliInstallState {
    CliInstallState(
      installing: cli.bool("installing") ?? false,
      step: cli.string("step"),
      installedVersion: cli.string("installedVersion"),
      binPath: cli.string("binPath"),
      error: cli.string("error")
    )
  }

  func installCli() {
    if NativeCliControl.active { NativeCliControl.shared.install(reason: "settings") } else { SettingsJS.shared.fire("advanced.installCli") }
  }

  func hasDeveloperModeChanges(_ developerMode: JSONValue?) -> Bool {
    Self.hasDeveloperModeChanges(developerMode)
  }

  func resetDeveloperModeSites() {
    guard let all = model.settings["developerMode"]?.object else { return }
    model.update(["developerMode": .object(all.mapValues(Self.withoutSites))])
  }

  nonisolated static func hasDeveloperModeChanges(_ developerMode: JSONValue?) -> Bool {
    (developerMode?.object?.values ?? []).contains { state in
      hosts(state["on"]).contains { !isDefaultDeveloperHost($0) } || hosts(state["off"]).contains(where: isDefaultDeveloperHost)
    }
  }

  nonisolated static func withoutSites(_ state: JSONValue) -> JSONValue {
    let reload = state["reload"]?.string == "forceReload" ? "forceReload" : "reload"
    return .object(["on": .array([]), "off": .array([]), "reload": .string(reload)])
  }

  nonisolated static func hosts(_ list: JSONValue?) -> [String] {
    (list?.array ?? []).compactMap(\.string).filter { !$0.isEmpty && $0.count <= 253 }.map { $0.lowercased() }
  }

  nonisolated static func isDefaultDeveloperHost(_ host: String) -> Bool {
    let host = host.lowercased()
    return ["localhost", "127.0.0.1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
  }

  func openInternalPage(_ page: String) {
    guard let opening = SettingsDirectWrites.opening else {
      SettingsJS.shared.fire("app.openInternalPage", page)
      return
    }
    opening.openInternalPage(page, scheme: appScheme(), isAppScheme: isAppScheme)
  }

  func openURL(_ url: String) {
    guard !SettingsDirectWrites.openURLs([url]) else { return }
    SettingsJS.shared.fire("app.openUrls", [url])
  }

  var systemInfo: AdvancedSystemInfo {
    let info = AboutInfo.read(releaseRepo: Self.releaseRepo)
    return AdvancedSystemInfo(releaseRepo: info.releaseRepo, appVersion: info.appVersion)
  }

  static var releaseRepo: String? {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "ACReleaseRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    return repo.isEmpty || repo.hasPrefix("$(") ? nil : repo
  }
}

@MainActor
final class AboutAdapter: AboutServices {
  let aboutInfo = AboutInfo.read(releaseRepo: AdvancedAdapter.releaseRepo)

  func updaterState() async -> UpdaterState? {
    let state = AppUpdater.shared.state
    guard state["available"] as? Bool == true else { return nil }
    return UpdaterState(
      configured: state.bool("configured") ?? false,
      automaticChecks: state.bool("automaticChecks") ?? false,
      automaticDownloads: state.bool("automaticDownloads") ?? false,
      canCheck: state.bool("canCheck") ?? false,
      sessionInProgress: state.bool("sessionInProgress") ?? false,
      lastCheck: state.date("lastCheck"),
      version: state.string("version") ?? aboutInfo.appVersion,
      displayVersion: state.string("displayVersion"),
      channel: state.string("channel")
    )
  }

  func setAutomaticUpdateChecks(_ on: Bool) async { AppUpdater.shared.setAutomaticChecks(on) }
  func setAutomaticUpdateDownloads(_ on: Bool) async { AppUpdater.shared.setAutomaticDownloads(on) }
  func setUpdateChannel(_ channel: String) async { AppUpdater.shared.setChannel(channel) }
  func checkForUpdates() async { AppUpdater.shared.checkForUpdates(nil) }

  var updateChecksNote: String? { SettingsJS.shared.latestValue("about.updateChecksNote") as? String }

  func copyText(_ text: String) { SettingsAdapters.copyText(text) }

  func openURL(_ url: String) {
    guard !SettingsDirectWrites.openURLs([url]) else { return }
    SettingsJS.shared.fire("app.openUrls", [url])
  }

  func reportBug() { NativeBugReport.shared.report(windowId: "settings") }
}

extension SettingsAdapters {
  static func loginItemStatus() -> LoginItemStatus {
    LoginItemStatus(rawValue: SystemServices.launchAtLoginStatus()) ?? .notRegistered
  }

  static func setLaunchAtLogin(_ on: Bool) {
    do {
      try SystemServices.setLaunchAtLogin(on)
    } catch {
      NSLog("[settings] setLaunchAtLogin failed: %@", String(describing: error))
    }
  }

  static func setAsDefaultBrowser() async -> Bool {
    await withCheckedContinuation { continuation in SystemServices.setAsDefaultBrowser { continuation.resume(returning: $0) } }
  }
}
