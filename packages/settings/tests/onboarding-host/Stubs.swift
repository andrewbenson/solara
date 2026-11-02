import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

extension Bundle {
  var productName: String { "Solara" }
}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
  func bool(_ key: String) -> Bool? { self[key] as? Bool }
  func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
  func list(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
  func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
}

@MainActor
enum DocumentStore {
  static var documents: [String: String] = [:]
  static var staged: [String: String] = [:]
  static var holdWrites = false
  static var writeError: Error?
  static var pending: [(name: String, text: String, done: ((Error?) -> Void)?)] = []
  static func read(_ name: String) -> String? { staged[name] ?? documents[name] }
  static func readDurable(_ name: String) -> String? { documents[name] }
  static func write(_ name: String, _ text: String, done: ((Error?) -> Void)? = nil) throws {
    if let writeError { throw writeError }
    staged[name] = text
    let waiters = pending.filter { $0.name == name }.compactMap(\.done) + (done.map { [$0] } ?? [])
    pending.removeAll { $0.name == name }
    pending.append((name, text, waiters.isEmpty ? nil : { error in
      for waiter in waiters { waiter(error) }
    }))
    if !holdWrites { finishPending(nil) }
  }
  static func finishPending(_ error: Error?) {
    let writes = pending
    pending = []
    for write in writes {
      if error == nil {
        documents[write.name] = write.text
        if staged[write.name] == write.text { staged[write.name] = nil }
      } else {
        pending.append((write.name, write.text, nil))
      }
      write.done?(error)
    }
  }
  static func landRetries() {
    let retries = pending.filter { $0.done == nil }
    pending.removeAll { $0.done == nil }
    for retry in retries {
      documents[retry.name] = retry.text
      if staged[retry.name] == retry.text { staged[retry.name] = nil }
    }
  }
}

@MainActor
enum AppModule {
  static var systemInfo: [String: Any] { ["isolatedInstance": true, "appVersion": "1.0"] }
}

@MainActor
enum NativeSettingsHandle {
  static var model: SettingsModel?
  static var unavailable: Unavailable? { nil }
  struct Unavailable { var detail: String }
}

@MainActor
enum NativeStoreHandle {
  static var opened = false
  static var ownedWorkspaceAtLaunch = false
  static var ownsWorkspace = false
  static var store: Store?
}

@MainActor
enum NativeMenuCommands {
  static var handlers: [String: (String?) -> Void] = [:]
}

@MainActor
enum NativeSettingsWindow {
  nonisolated static var enabled: Bool { true }
}

@MainActor
final class StoreSettingsSource: SettingsStoreSource {
  let model: SettingsModel
  init(model: SettingsModel) { self.model = model }
  func settingValue(_ key: String) -> JSONValue? { model.value(key) }
  func updateSettings(_ patch: JSONObject) { model.update(patch) }
  var profiles: [SolaraUI.SettingsProfile] { [] }
  var topTabLayout: Bool { model.value("tabLayout")?.string == "top" }
  func chooseTabLayout(_ layout: String) { model.update(["tabLayout": .string(layout)]) }
}

@MainActor
enum SettingsAdapters {
  static func loginItemStatus() -> LoginItemStatus { .notRegistered }
  static func setAsDefaultBrowser() async -> Bool { false }
  static func setLaunchAtLogin(_ on: Bool) {}
}

@MainActor
enum SystemServices {
  static func isDefaultBrowser() -> Bool { false }
  static var isInDock: Bool { false }
  static func addToDock() {}
  static func playIntroMusic(cues: [String: Double], muted: Bool) {}
  static func setIntroMusicMuted(_ muted: Bool) {}
  static func stopIntroMusic(fade: Double) {}
  static var appIconChoices: [(id: String, name: String)] { [] }
  static func appIconPreview(_ id: String, size: CGFloat) -> NSImage? { nil }
  static var currentAppIcon: String? { nil }
  static func setAppIcon(_ id: String) {}
}

@MainActor
enum NativeHistoryCatalog {
  static func favicon(page: String, profileId: String, dark: Bool) async -> NSImage? { nil }
}

@MainActor
final class SettingsJS {
  static let shared = SettingsJS()
  var connected = true
  var calls: [String] = []
  var invocations: [(name: String, arguments: [Any])] = []
  func latestValue(_ topic: String) -> Any? { nil }
  func observe(_ topic: String, _ callback: @escaping (Any?) -> Void) -> UUID { UUID() }
  func stopObserving(_ topic: String, _ id: UUID) {}
  func invoke(_ name: String, _ arguments: [Any]) async throws -> Any? {
    calls.append(name)
    invocations.append((name, arguments))
    return nil
  }
}

@MainActor
final class SyncAdapter: SyncServices {
  static var folderChoice: CheckedContinuation<String?, Never>?
  func currentSyncState() async -> SyncState { fatalError() }
  func syncStateUpdates() -> AsyncStream<SyncState> { AsyncStream { $0.finish() } }
  func turnOnSync(folder: String) async -> String? { nil }
  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult { fatalError() }
  func stopSync(deleteData: Bool) async {}
  func syncNow() async {}
  func setTypeSynced(_ type: SyncDataType, _ on: Bool) {}
  func setProfileSynced(_ profileId: String, _ on: Bool) {}
  func addRemoteProfile(_ syncId: String) {}
  func folderInfo(path: String?) async -> SyncFolderInfo? { nil }
  func recoveryWords() async -> [String]? { nil }
  func phraseUnavailable() async -> String? { nil }
  func recoveryQRCode() async -> Data? { nil }
  func recoveryKitPreview(width: Double) async -> Data? { nil }
  func saveRecoveryKit(_ format: SyncKitFormat) async -> String? { nil }
  func copyRecoveryKit() async {}
  func shareRecoveryKit() async {}
  func copyRecoveryPhrase() async {}
  func revealFolder(_ path: String) async {}
  func chooseSyncFolder() async -> String? { await withCheckedContinuation { Self.folderChoice = $0 } }
  func openICloudSettings() {}
}

@MainActor
enum OnboardingPairingServices {
  static var joining: ((String) -> PairingJoining?)?
  static var committedJoinToken: (() -> String?)?
}

@MainActor
final class OnboardingDiscoveryAdapter: OnboardingDiscovering {
  var folder: URL
  static var callbacks: [@MainActor (OnboardingDiscoveryResult) -> Void] = []
  init(folder: URL) { self.folder = folder }
  func start(onResult: @escaping @MainActor (OnboardingDiscoveryResult) -> Void) -> OnboardingDiscoveryHandle {
    Self.callbacks.append(onResult)
    return Handle()
  }
  final class Handle: OnboardingDiscoveryHandle {
    func cancel() {}
  }
}

@MainActor
struct HostedContent {
  var view: NSView
  var onUnmount: () -> Void
}

@MainActor
enum HostedViews {
  private static var makers: [String: (String, String) -> HostedContent?] = [:]
  static func register(_ kind: String, _ make: @escaping (String) -> HostedContent?) {
    register(kind) { windowId, _ in make(windowId) }
  }
  static func register(_ kind: String, _ make: @escaping (String, String) -> HostedContent?) {
    makers[kind] = make
  }
  static func make(_ kind: String, windowId: String, state: String = "") -> HostedContent? {
    makers[kind]?(windowId, state)
  }
}

@MainActor
enum PowerUpViews {
  static func make(palette: [String], speed: Double, origin: Double, cornerRadius: Double, halo: CGRect?) -> NSView { NSView() }
}

@MainActor
enum ShellScripting {
  static func showWindow(_ id: String) {}
}

@MainActor
final class NativeImportWindow {
  static var current: NativeImportWindow?
  var disposed = false
  func dispose() { disposed = true }
}

@MainActor
final class ImportAdapter {
  static var closes = 0
  func close() { Self.closes += 1 }
}
