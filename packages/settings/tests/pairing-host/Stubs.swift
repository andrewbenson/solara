import AppKit
import Foundation
import SwiftUI
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor final class SettingsModel {
  struct Profile { let id: String; let name: String; let engineProfile: String; let fileTheme: ProfileFileTheme? }
  let profiles: [Profile] = []
  let settings = Settings.defaults
  func value(_ key: String) -> JSONValue? { nil }
  func update(_ patch: JSONObject) {}
}
@MainActor enum NativeConfigNotifier {
  static let posted: [String] = []
}
@MainActor enum NativeSettingsHandle {
  static var model: SettingsModel? = SettingsModel()
  nonisolated static let active = true
  static let unavailable: String? = nil
}
@MainActor final class SettingsJS {
  static let shared = SettingsJS()
  func fire(_ name: String, _ argument: Any) {}
  func latestValue(_ key: String) -> Any? { nil }
  func invoke(_ name: String, _ arguments: [Any]) async throws -> Any? { nil }
}
@MainActor final class StubPane: SettingsPaneProvider {
  init(services: Any? = nil, store: Any? = nil, safeMode: Bool = false, experiments: Any? = nil, hooks: Any? = nil) {}
  func isLoaded(_ place: SettingsPlace) -> Bool { true }
  func prepare(_ place: SettingsPlace) async {}
  func view(_ place: SettingsPlace) -> AnyView { AnyView(EmptyView()) }
  func devSetFilterList(_ id: String, on: Bool) async -> Bool { false }
}
typealias GeneralPaneModel = StubPane
typealias TabsPaneModel = StubPane
typealias AppearancePaneModel = StubPane
typealias SearchEnginePaneModel = StubPane
typealias EnginesPaneModel = StubPane
typealias AdvancedPaneModel = StubPane
@MainActor final class NativeHooks {
  static let shared = NativeHooks()
  func sectionModel() -> Any? { nil }
}
typealias AboutPaneModel = StubPane
typealias PrivacyPaneModel = StubPane
typealias PasswordsPaneModel = StubPane
typealias AutofillPaneModel = StubPane
typealias ExtensionsPaneModel = StubPane
typealias ShortcutsPaneModel = StubPane
typealias ProfilesPaneModel = StubPane
typealias LiveFoldersPaneModel = StubPane
typealias CalendarPaneModel = StubPane
@MainActor final class StubAdapter {
  init(model: Any? = nil, store: Any? = nil) {}
  func setWebsiteEngine(_ site: String, _ engine: String?) {}
  func resetDeveloperModeSites() {}
  func disableExtension(profile: String, extensionId: String) async {}
}
typealias GeneralAdapter = StubAdapter
typealias AppearanceAdapter = StubAdapter
typealias SearchEngineAdapter = StubAdapter
typealias EnginesAdapter = StubAdapter
typealias AdvancedAdapter = StubAdapter
typealias AboutAdapter = StubAdapter
typealias PrivacyAdapter = StubAdapter
typealias PasswordsAdapter = StubAdapter
typealias AutofillAdapter = StubAdapter
typealias ExtensionsAdapter = StubAdapter
typealias ShortcutsAdapter = StubAdapter
typealias ProfilesAdapter = StubAdapter
typealias LiveAdapter = StubAdapter
@MainActor enum NativeOnboarding { static func register() {} }
@MainActor final class StubStartup {
  static let shared = StubStartup()
  func install() {}
  func startWhenReady() {}
}
typealias NativeAppStartup = StubStartup
typealias NativeCliControl = StubStartup
typealias NativeMemoryTrim = StubStartup
typealias NativeProfileWarmup = StubStartup
typealias NativeUserScripts = StubStartup
typealias NativeSiteControls = StubStartup
@MainActor final class NativeAppIntegration {
  static let active = false
  static let shared = NativeAppIntegration()
  enum Target { case page(String), mail(String, String) }
  func startWhenReady() {}
  func diagnostics() -> [String: Any] { [:] }
  func feedbackTarget() -> Target { .page("") }
  func sendFeedback(_ argument: String?) {}
}
@MainActor enum SettingsPrewarm { static let warming = false; static func schedule() {} }
@MainActor enum SettingsTimings { static func paneAppeared(_ pane: String) {}; static func navigating(_ pane: String) {} }
@MainActor enum NativeImportWindow { static let kind = "import"; static func makeController() -> NSViewController? { nil } }
struct StoreUnavailableView: View {
  init(failure: String, appName: String, quit: @escaping () -> Void, showDataFolder: @escaping (URL) -> Void) {}
  var body: some View { EmptyView() }
}
@MainActor enum NativeHistoryCatalog { static func favicon(page: String, profileId: String, dark: Bool) async -> NSImage? { nil } }
extension Bundle { var productName: String { "Fixture Integration" } }
@MainActor final class OnboardingTextNSView: NSView { var text = "" }
@MainActor enum NativeStoreHandle { static let store: StubStore? = nil }
struct StubStore {
  let state = 0
  func silencesNotifications(profileDirectory: String, origin: String) -> Bool { false }
}
enum ScriptState { static func build(_ state: Int, loading: [String]) -> [String: Any] { [:] } }

@MainActor
final class SyncAdapter: SyncServices {
  func invalidatePairing(_ reason: String) {}
  var state: SyncState
  var folders: [String: SyncFolderInfo]
  var defaultFolder = "/Users/owner/Library/Mobile Documents/com~apple~CloudDocs/Solara Sync"
  var pickedFolder: String? = "/Users/owner/Dropbox/Sync"
  var turnOnError: String?
  var phraseResult: SyncPhraseResult = .ok
  var words = ["abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire", "across", "act", "action", "actor", "actress", "actual"]
  var unavailable: String?
  var calls: [String] = []
  var folderInfoRequests: [String?] = []
  private var continuation: AsyncStream<SyncState>.Continuation?

  init(state: SyncState = SyncState(status: .off, enabled: false, folder: nil), folders: [String: SyncFolderInfo] = [:]) {
    Evidence.productionFactories += 1
    self.state = state
    self.folders = folders
  }

  func push(_ next: SyncState) {
    state = next
    continuation?.yield(next)
  }

  func currentSyncState() async -> SyncState { state }

  func syncStateUpdates() -> AsyncStream<SyncState> {
    let (stream, continuation) = AsyncStream<SyncState>.makeStream()
    self.continuation = continuation
    return stream
  }

  func chooseSyncFolder() async -> String? {
    calls.append("chooseSyncFolder")
    if let pickedFolder { state.folder = pickedFolder }
    return pickedFolder
  }

  func turnOnSync(folder: String) async -> String? {
    calls.append("turnOnSync \(folder)")
    return turnOnError
  }

  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult {
    calls.append("enterRecoveryPhrase \(folder) \(text.split(separator: " ").count)")
    return phraseResult
  }

  func stopSync(deleteData: Bool) async { calls.append("stopSync deleteData=\(deleteData)") }
  func syncNow() async { calls.append("syncNow") }
  func setTypeSynced(_ type: SyncDataType, _ on: Bool) { calls.append("setTypeSynced \(type.rawValue) \(on)") }
  func setProfileSynced(_ profileId: String, _ on: Bool) { calls.append("setProfileSynced \(profileId) \(on)") }
  func addRemoteProfile(_ syncId: String) { calls.append("addRemoteProfile \(syncId)") }

  func folderInfo(path: String?) async -> SyncFolderInfo? {
    folderInfoRequests.append(path)
    let key = path ?? defaultFolder
    return folders[key] ?? SyncFolderInfo(path: key, defaultPath: defaultFolder, iCloudAvailable: true, inICloud: key.contains("com~apple~CloudDocs"), exists: true, writable: true, hasSyncData: false)
  }

  func recoveryWords() async -> [String]? { words }
  func phraseUnavailable() async -> String? { unavailable }
  func recoveryQRCode() async -> Data? { SyncTestImages.qrCode(words.joined(separator: " ")) }
  func recoveryKitPreview(width: Double) async -> Data? { SyncTestImages.kitPreview() }
  func saveRecoveryKit(_ format: SyncKitFormat) async -> String? {
    calls.append("saveRecoveryKit \(format.rawValue)")
    return "/Users/owner/Documents/Solara Recovery Kit.pdf"
  }
  func copyRecoveryKit() async { calls.append("copyRecoveryKit") }
  func shareRecoveryKit() async { calls.append("shareRecoveryKit") }
  func copyRecoveryPhrase() async { calls.append("copyRecoveryPhrase") }
  func revealFolder(_ path: String) async { calls.append("revealFolder \(path)") }
  func openICloudSettings() { calls.append("openICloudSettings") }
}

enum SyncTestImages { static func qrCode(_ value: String) -> Data? { nil }; static func kitPreview() -> Data? { nil } }
