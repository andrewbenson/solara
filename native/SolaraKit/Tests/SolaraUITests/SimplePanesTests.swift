import AppKit
import Observation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
final class FakeAppearanceServices: AppearanceServices {
  var appearance: String?
  var icon: String?

  func appIcons(size: CGFloat) async -> (icons: [AppIconChoice], current: String?) {
    let image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
    return ([AppIconChoice(id: "default", name: "Default", preview: image), AppIconChoice(id: "night", name: "Night", preview: image), AppIconChoice(id: "glass", name: "Glass", preview: image)], icon ?? "default")
  }
  func setAppIcon(_ id: String) async { icon = id }
  func setAppearance(_ mode: String) async { appearance = mode }
}

@MainActor
@Observable
final class FakeSearchEngineServices: SearchEngineServices {
  var engines: [SearchEngineItem] = [
    SearchEngineItem(id: "google", name: "Google", keyword: "google.com", url: "https://www.google.com/search?q=%s", host: "www.google.com"),
    SearchEngineItem(id: "duckduckgo", name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q=%s", host: "duckduckgo.com"),
    SearchEngineItem(id: "kagi", name: "Kagi", keyword: "kagi.com", url: "https://kagi.com/search?q=%s", host: "kagi.com"),
    SearchEngineItem(id: "c1", name: "Wikipedia", keyword: "w", url: "https://en.wikipedia.org/w/index.php?search=%s", host: "en.wikipedia.org", custom: true),
    SearchEngineItem(id: "ext:abc", name: "Startpage", keyword: "sp", url: "https://startpage.com/?q=%s", host: "startpage.com", extensionName: "Startpage Search"),
  ]
  var selectedId = "google"
  var controlling: ControllingSearchExtension?
  var disabled: [String] = []

  func engineList() -> SearchEngineList { SearchEngineList(engines: engines, selectedId: selectedId, controlling: controlling) }
  func setSearchEngine(_ id: String) { selectedId = id }
  func addCustomEngine(_ input: SearchEngineInput) async -> String? {
    if !input.url.contains("%s") { return "The URL needs %s where the search terms go." }
    engines.append(SearchEngineItem(id: "c\(engines.count)", name: input.name, keyword: input.keyword, url: input.url, host: "example.com", custom: true))
    return nil
  }
  func updateCustomEngine(_ id: String, _ input: SearchEngineInput) async -> String? { nil }
  func removeCustomEngine(_ id: String) { engines.removeAll { $0.id == id } }
  func manageExtensions(profile: String) {}
  func disableExtension(profile: String, extensionId: String) async { disabled.append(extensionId) }
}

@MainActor
final class FakeEnginesServices: EnginesServices {
  let store: FakeSettingsStore
  var passkeys = PasskeyAccess(entitled: true, status: .notDetermined)

  init(store: FakeSettingsStore) { self.store = store }

  func setWebsiteEngine(_ site: String, _ engine: String?) {
    var rules = store.values["websiteEngines"]?.object ?? JSONObject()
    rules[site] = engine.map(JSONValue.string)
    store.updateSettings(["websiteEngines": .object(rules)])
  }
  func site(forTyped address: String) -> String? {
    guard address.contains("."), !address.contains(" ") else { return nil }
    let host = address.replacingOccurrences(of: "https://", with: "")
    return "https://\(host.lowercased())"
  }
  func passkeyAccess() async -> PasskeyAccess? { passkeys }
  func requestPasskeyAccess() async -> PasskeyAccess? {
    passkeys.status = .authorized
    return passkeys
  }
  func openPasskeySystemSettings() {}
}

@MainActor
@Observable
final class FakeAdvancedServices: AdvancedServices {
  var cliServer: CliServerStatus? = CliServerStatus(state: "off")
  var cliInstall = CliInstallState(installedVersion: "0.3.0", binPath: "/usr/local/bin/solara")
  var opened: [String] = []
  var resets = 0

  func chromiumVersion() async -> String? { "156.0.8078.47" }
  func widevineVersion() async -> String?? { .some("4.10.2891.0") }
  func installCli() { cliInstall.installing = true }
  func hasDeveloperModeChanges(_ developerMode: JSONValue?) -> Bool { !(developerMode?.object?.keys.isEmpty ?? true) }
  func resetDeveloperModeSites() { resets += 1 }
  func openInternalPage(_ page: String) { opened.append(page) }
  func openURL(_ url: String) { opened.append(url) }
  var systemInfo: AdvancedSystemInfo { AdvancedSystemInfo(releaseRepo: "andrewbenson/solara", appVersion: "0.3.0") }
}

final class ObservedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var raised: Bool { lock.withLock { value } }
  func raise() { lock.withLock { value = true } }
}

@MainActor
struct SimplePanesTests {
  @Test func linkKeysNormalizeAndExplainTheClash() {
    let store = FakeSettingsStore()
    store.values["peekModifier"] = "bogus"
    #expect(TabsPaneModel.peekModifier(store) == "shift")
    store.values["splitLinkModifier"] = "alt"
    #expect(TabsPaneModel.splitLinkModifier(store) == "alt")
    #expect(TabsPaneModel.peekOptions(splitWith: "alt")[1].title == "⌥-click (split view moves to ⌥⇧-click)")
    store.values["peekModifier"] = "alt"
    #expect(TabsPaneModel.splitLinkModifier(store) == "altShift")
    #expect(TabsPaneModel.splitOptions(peekWith: "alt")[1].title == "⌥-click (Peek moves to ⇧-click)")
  }

  @Test func pinnedLinkTargetFallsBackToPeek() {
    let store = FakeSettingsStore()
    #expect(TabsPaneModel.pinnedLinkTarget(store) == "peek")
    store.values["pinnedLinkTarget"] = "bogus"
    #expect(TabsPaneModel.pinnedLinkTarget(store) == "peek")
    store.values["pinnedLinkTarget"] = "tab"
    #expect(TabsPaneModel.pinnedLinkTarget(store) == "tab")
    store.values["pinnedLinkTarget"] = "littleSolara"
    #expect(TabsPaneModel.pinnedLinkTarget(store) == "littleSolara")
    #expect(TabsPaneModel.pinnedLinkTargets(app: "Solara").map(\.value) == ["tab", "peek", "littleSolara"])
    #expect(TabsPaneModel.pinnedLinkTargets(app: "Solara").last?.title == "Little Solara")
  }

  @Test func staticPaneCaptionsStayShort() {
    for (mode, caption) in AdvancedPaneModel.batterySaverDescriptions {
      #expect(caption.count <= 90, "Battery Saver \(mode): \(caption.count) characters")
    }
    for type in SyncDataType.allCases {
      #expect(type.summary.count <= 90, "Sync \(type.rawValue): \(type.summary.count) characters")
    }
    for status: PasskeyAccessStatus in [.entitlementRequired, .deviceNotConfigured, .notDetermined, .authorized, .denied] {
      #expect((EnginesPaneModel.passkeyStatus(status, app: "Solara")?.count ?? 0) <= 90)
    }
    for installed: Bool? in [false, true, nil] {
      #expect(PasswordsText.managerAppsNote(appName: "Solara", inApplicationsFolder: installed).count <= 90)
    }
    for on in [false, true] {
      for status: CliServerStatus? in [nil, CliServerStatus(state: "off"), CliServerStatus(state: "external"), CliServerStatus(state: "on", connections: 0), CliServerStatus(state: "on", connections: 1), CliServerStatus(state: "on", connections: 2)] {
        #expect(AdvancedPaneModel.serverNote(on: on, server: status).count <= 90)
      }
    }
    for state in [CliInstallState(), CliInstallState(installing: true), CliInstallState(installing: true, step: "copying"), CliInstallState(installedVersion: "1"), CliInstallState(installedVersion: "1", binPath: "/usr/local/bin/solara")] {
      #expect(AdvancedPaneModel.describeInstall(state).count <= 90)
    }
    let model = AdvancedPaneModel(services: FakeAdvancedServices(), store: FakeSettingsStore())
    #expect(model.widevineDescription.count <= 90)
    model.widevine = .some(.some(nil))
    #expect(model.widevineDescription.count <= 90)
    model.widevine = .some(.some("4.10.2891.0"))
    #expect(model.widevineDescription.count <= 90)
  }

  @Test func newTabPositionsFollowTheLayout() {
    #expect(TabsPaneModel.newTabPositions(top: false).map(\.title) == ["At the bottom", "At the top", "Below the current tab"])
    #expect(TabsPaneModel.newTabPositions(top: true).map(\.title) == ["On the right", "On the left", "Next to the current tab"])
  }

  @Test func cleanUpHoursReadsNullAsOff() {
    let store = FakeSettingsStore()
    #expect(TabsPaneModel.cleanUpHours(store) == nil)
    store.values["cleanUpInactiveTabsAfterHours"] = 168
    #expect(TabsPaneModel.cleanUpHours(store) == 168)
  }

  @Test func appearanceChoiceWritesTheSettingAndTellsTheApp() async {
    let store = FakeSettingsStore()
    let services = FakeAppearanceServices()
    let model = AppearancePaneModel(services: services, store: store)
    await model.prepare(SettingsPlace(pane: .appearance))
    #expect(model.isLoaded(SettingsPlace(pane: .appearance)))
    model.chooseAppearance("dark")
    #expect(store.values["appearance"] == "dark")
    model.chooseIcon("night")
    #expect(model.currentIcon == "night")
  }

  @Test func engineDescriptionsMatchRN() {
    let ext = SearchEngineItem(id: "e", name: "E", keyword: "", url: "u", host: "h", extensionName: "")
    #expect(SearchEnginePaneModel.description(ext) == "Added by an extension")
    let named = SearchEngineItem(id: "e", name: "E", keyword: "sp", url: "u", host: "h", extensionName: "Startpage")
    #expect(SearchEnginePaneModel.description(named) == "sp · Added by Startpage")
    let custom = SearchEngineItem(id: "c", name: "W", keyword: "w", url: "https://w/%s", host: "w", custom: true)
    #expect(SearchEnginePaneModel.description(custom) == "w · https://w/%s")
  }

  @Test func websiteRulesSortBySiteAndSaveThroughTheSiteParser() {
    let store = FakeSettingsStore()
    let services = FakeEnginesServices(store: store)
    let model = EnginesPaneModel(services: services, store: store)
    services.setWebsiteEngine("https://netflix.com", "webkit")
    services.setWebsiteEngine("http://apple.com", "chromium")
    #expect(model.rules.map(\.site) == ["http://apple.com", "https://netflix.com"])
    #expect(model.saveRule(address: "not a site", engine: "webkit", replacing: nil) == "Enter a website address, like netflix.com.")
    #expect(model.saveRule(address: " Disney.com ", engine: "webkit", replacing: "https://netflix.com") == nil)
    #expect(model.rules.map(\.site) == ["https://disney.com", "http://apple.com"])
  }

  @Test func passkeyStatusUsesTheAppName() {
    #expect(EnginesPaneModel.passkeyStatus(.denied, app: "Solara") == "Allow Solara in System Settings › Privacy & Security › Passkeys Access for Web Browsers.")
    #expect(EnginesPaneModel.passkeyStatus(.entitlementRequired, app: "Solara") == nil)
  }

  @Test func advancedNotesMatchRN() {
    #expect(AdvancedPaneModel.serverNote(on: true, server: CliServerStatus(state: "on", connections: 2)) == "Connected now: 2 sessions.")
    #expect(AdvancedPaneModel.serverNote(on: true, server: CliServerStatus(state: "on", connections: 0)) == "On. Nothing is connected.")
    #expect(AdvancedPaneModel.serverNote(on: false, server: CliServerStatus(state: "external")).hasPrefix("This instance already"))
    #expect(AdvancedPaneModel.describeInstall(CliInstallState(installing: true, step: "copying")) == "Installing (copying)…")
    #expect(AdvancedPaneModel.describeInstall(CliInstallState(installedVersion: "1")) == "Version 1 is installed.")
    #expect(AdvancedPaneModel.describeInstall(CliInstallState()) == "Not installed.")
  }

  @Test func widevineDescriptionTreatsZeroVersionAsMissing() async {
    let store = FakeSettingsStore()
    let model = AdvancedPaneModel(services: FakeAdvancedServices(), store: store)
    #expect(model.widevineDescription == "Checking…")
    model.widevine = .some(.some("0.0.0.0"))
    #expect(model.widevineDescription.hasPrefix("Not available in this build"))
    await model.prepare(SettingsPlace(pane: .advanced))
    #expect(model.widevineDescription == "Version 4.10.2891.0")
  }

  @Test func aboutReportIsPlainTextForBugReports() async {
    let services = FakeAboutServices()
    let model = AboutPaneModel(services: services)
    await model.prepare(SettingsPlace(pane: .about))
    model.copy(app: "Solara")
    #expect(services.copiedText == "Solara 0.3.0 (412), Stable\nChromium 156.0.8078.47\nmacOS 27.0.1 (26A434), Apple silicon (arm64)")
    services.updater?.channel = "nightly"
    await model.refreshUpdater()
    #expect(AboutPaneModel.versionLine(services.aboutInfo, channel: model.channel) == "0.3.0 (412), Nightly")
  }

  @Test func aboutCopyrightShowsTheUpstreamCreditOnlyWhenSet() {
    var info = FakeAboutServices().aboutInfo
    #expect(AboutPaneModel.copyrightLine(info) == "© 2026 Andrew Benson.")
    info.upstreamCredit = "Built on Solara, © 2026 Mantra Patel."
    #expect(AboutPaneModel.copyrightLine(info) == "© 2026 Andrew Benson. Built on Solara, © 2026 Mantra Patel.")
    info.copyright = nil
    info.upstreamCredit = nil
    #expect(AboutPaneModel.copyrightLine(info) == nil)
  }

  @Test func aboutInfoReadsTheBundleAndTheEngineFramework() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Solara.app/Contents")
    let framework = app.appendingPathComponent("Frameworks/Chromium Framework.framework/Resources")
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    let appPlist: [String: Any] = ["CFBundleIdentifier": "test.solara", "CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "500", "ACCopyright": "© 2026 Andrew Benson.", "ACUpstreamCredit": "", "CFBundlePackageType": "APPL"]
    try (appPlist as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
    let enginePlist: [String: Any] = ["CFBundleIdentifier": "test.chromium", "CFBundleShortVersionString": "156.0.8078.47", "CFBundlePackageType": "FMWK"]
    try (enginePlist as NSDictionary).write(to: framework.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: root.appendingPathComponent("Solara.app")))
    let info = AboutInfo.read(app: bundle)
    #expect(info.appVersion == "0.4.0")
    #expect(info.build == "500")
    #expect(info.chromiumVersion == "156.0.8078.47")
    #expect(info.copyright == "© 2026 Andrew Benson.")
    #expect(info.upstreamCredit == nil)
    #expect(!info.osVersion.isEmpty)
    try? FileManager.default.removeItem(at: root)
  }

  @Test func renamingAProfileRetitlesItsDetailsPane() {
    let (context, store) = SettingsFixture.context()
    context.navigation.go(.profiles, profileId: "work")
    #expect(context.title(for: context.navigation.place) == "Work")
    let notified = ObservedFlag()
    withObservationTracking {
      _ = context.title(for: context.navigation.place)
    } onChange: {
      notified.raise()
    }
    store.profiles[1] = SettingsProfile(id: "work", name: "Office", engineProfile: "work")
    #expect(notified.raised)
    #expect(context.title(for: context.navigation.place) == "Office")
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersSimplePanes() async throws {
    let (context, store) = await SettingsFixture.loaded()
    store.values["websiteEngines"] = ["https://netflix.com": "webkit", "https://www.disneyplus.com": "webkit"]
    try await Snapshot.renderPanes(context, [.tabs, .appearance, .search, .engines, .advanced, .about])
    store.topTabLayout = true
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .tabs, detail: "top")]) { _ in "tabs-top" }
  }
}
