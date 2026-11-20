import Foundation
import Observation
import SolaraModel
@testable import SolaraUI

@MainActor
@Observable
final class FakeSettingsStore: SettingsStoreSource {
  var values: JSONObject = Settings.defaults.values
  var profiles: [SettingsProfile] = [
    SettingsProfile(id: "default", name: "Personal", engineProfile: "default"),
    SettingsProfile(id: "work", name: "Work", engineProfile: "work"),
  ]
  var topTabLayout = false
  var patches: [JSONObject] = []

  func settingValue(_ key: String) -> JSONValue? { values[key] }

  func updateSettings(_ patch: JSONObject) {
    patches.append(patch)
    for key in patch.keys { values[key] = patch[key] }
  }

  func chooseTabLayout(_ layout: String) {
    topTabLayout = layout == "top"
    values["tabLayout"] = .string(layout)
  }
}

@MainActor
final class FakeGeneralServices: GeneralServices {
  var login: LoginItemStatus = .notRegistered
  var isDefault = true
  var downloads: [String: DownloadSettings] = [
    "default": DownloadSettings(folder: "/Users/owner/Downloads", askWhereToSave: false, managed: false),
    "work": DownloadSettings(folder: "/Users/owner/Work Downloads", askWhereToSave: true, managed: false),
  ]
  var importOpened = 0

  func loginItemStatus() async -> LoginItemStatus { login }
  func setLaunchAtLogin(_ on: Bool) async { login = on ? .enabled : .notRegistered }
  func isDefaultBrowser() async -> Bool { isDefault }
  func setAsDefaultBrowser() async -> Bool {
    isDefault = true
    return true
  }
  func downloadSettings(profile: String) async -> DownloadSettings? { downloads[profile] }
  func setDownloadSettings(folder: String?, askWhereToSave: Bool?, profile: String) async -> DownloadSettings? {
    guard var current = downloads[profile] else { return nil }
    if let folder { current.folder = folder }
    if let askWhereToSave { current.askWhereToSave = askWhereToSave }
    downloads[profile] = current
    return current
  }
  func pickFolder(current: String, prompt: String) async -> String? { "/Users/owner/Desktop" }
  func openImport() { importOpened += 1 }
}

@MainActor
final class FakeAboutServices: AboutServices {
  var aboutInfo = AboutInfo(
    appVersion: "0.3.0",
    build: "412",
    chromiumVersion: "156.0.8078.47",
    osVersion: "27.0.1 (26A434)",
    architecture: "Apple silicon (arm64)",
    copyright: "© 2026 Andrew Benson.",
    upstreamCredit: nil,
    releaseRepo: "andrewbenson/solara"
  )
  var updater: UpdaterState? = UpdaterState(
    configured: true,
    automaticChecks: true,
    automaticDownloads: true,
    canCheck: true,
    sessionInProgress: false,
    lastCheck: Date(timeIntervalSince1970: 1_792_000_000),
    version: "0.3.0",
    channel: "stable"
  )
  var copiedText: String?
  var opened: [String] = []

  func updaterState() async -> UpdaterState? { updater }
  func setAutomaticUpdateChecks(_ on: Bool) async { updater?.automaticChecks = on }
  func setAutomaticUpdateDownloads(_ on: Bool) async { updater?.automaticDownloads = on }
  func setUpdateChannel(_ channel: String) async { updater?.channel = channel }
  func checkForUpdates() async { updater?.lastCheck = Date() }
  var updateChecksNote: String? { nil }
  func copyText(_ text: String) { copiedText = text }
  func openURL(_ url: String) { opened.append(url) }
  var bugReports = 0
  func reportBug() { bugReports += 1 }
}

@MainActor
enum SettingsFixture {
  static func context(liquidGlass: Bool = false) -> (SettingsContext, FakeSettingsStore) {
    let store = FakeSettingsStore()
    let context = SettingsContext(appName: "Solara", liquidGlass: liquidGlass, store: store)
    context.favicons = SettingsFavicons { _, _ in nil }
    context.panes[.general] = GeneralPaneModel(services: FakeGeneralServices(), store: store)
    context.panes[.tabs] = TabsPaneModel(store: store)
    context.panes[.appearance] = AppearancePaneModel(services: FakeAppearanceServices(), store: store)
    context.panes[.search] = SearchEnginePaneModel(services: FakeSearchEngineServices(), store: store)
    context.panes[.engines] = EnginesPaneModel(services: FakeEnginesServices(store: store), store: store)
    context.panes[.advanced] = AdvancedPaneModel(services: FakeAdvancedServices(), store: store)
    context.panes[.about] = AboutPaneModel(services: FakeAboutServices())
    context.profileForPane = { pane, current in pane == .extensions ? (current.pane == .extensions ? current.profileId : nil) ?? "default" : nil }
    return (context, store)
  }

  static func loaded(liquidGlass: Bool = false) async -> (SettingsContext, FakeSettingsStore) {
    let (context, store) = context(liquidGlass: liquidGlass)
    for (pane, provider) in context.panes { await provider.prepare(SettingsPlace(pane: pane)) }
    return (context, store)
  }
}
