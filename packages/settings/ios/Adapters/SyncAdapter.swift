import AppKit
import Foundation
import SolaraUI
import SolaraSyncAdapter

@MainActor
final class SyncAdapter: SyncServices, SyncCreationServices {
  static let topic = "sync.state"

  func currentSyncState() async -> SyncState {
    if let latest = Self.state(SettingsJS.shared.latestValue(Self.topic)) { return latest }
    return Self.state(await SettingsAdapters.js("sync.state")) ?? SyncState(status: .unavailable, enabled: false, folder: nil)
  }

  func syncStateUpdates() -> AsyncStream<SyncState> {
    SettingsJS.shared.stream(Self.topic) { Self.state($0) }
  }

  func chooseSyncFolder() async -> String? { await SettingsAdapters.js("sync.chooseFolder") as? String }

  func turnOnSync(folder: String) async -> String? {
    do {
      return try await SettingsAdapters.jsThrowing("sync.turnOn", folder) as? String
    } catch {
      return "Sync isn’t available in this build."
    }
  }

  func inspectSyncCreation(folder: String) async -> SyncCreationInspection {
    guard let value = await SettingsAdapters.js("sync.inspectCreation", folder) as? [String: Any],
          let id = value.string("id"), let path = value.string("folder"),
          let candidates = value["candidates"] as? [String], let completeness = value.string("completeness") else {
      return SyncCreationInspection(id: "", folder: folder, candidates: [], completeness: "unknown")
    }
    return SyncCreationInspection(id: id, folder: path, candidates: candidates, completeness: completeness)
  }

  func invalidateSyncCreation(inspectionID: String) {
    SyncCreationAdmission.shared.invalidate(inspectionID: inspectionID)
  }

  func createSync(folder: String, inspectionID: String) async -> String? {
    guard SyncCreationAdmission.shared.consent(inspectionID: inspectionID) else {
      return "The sync folder changed or couldn't be checked. Check it again before starting a separate sync."
    }
    do {
      return try await SettingsAdapters.jsThrowing("sync.turnOn", folder, inspectionID) as? String
    } catch {
      return "Couldn't finish checking iCloud Drive."
    }
  }

  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult {
    Self.phraseResult(await SettingsAdapters.js("sync.enterRecoveryPhrase", folder, text) as? [String: Any])
  }

  func stopSync(deleteData: Bool) async { await SettingsAdapters.js("sync.stop", deleteData) }

  func syncNow() async { await SettingsAdapters.js("sync.syncNow") }

  func setTypeSynced(_ type: SyncDataType, _ on: Bool) { SettingsJS.shared.fire("sync.setTypeSynced", type.rawValue, on) }

  func setProfileSynced(_ profileId: String, _ on: Bool) { SettingsJS.shared.fire("sync.setProfileSynced", profileId, on) }

  func addRemoteProfile(_ syncId: String) { SettingsJS.shared.fire("sync.addRemoteProfile", syncId) }

  func resolveHeldPasswords(_ profileId: String, restore: Bool) { SettingsJS.shared.fire("sync.resolveHeldPasswords", profileId, restore) }

  func folderInfo(path: String?) async -> SyncFolderInfo? {
    guard let info = await SettingsAdapters.js("sync.folderInfo", jsonArg(path)) as? [String: Any], let path = info.string("path") else { return nil }
    return SyncFolderInfo(
      path: path,
      defaultPath: info.string("defaultPath") ?? path,
      iCloudAvailable: info.bool("iCloudAvailable") ?? false,
      inICloud: info.bool("inICloud") ?? false,
      exists: info.bool("exists") ?? false,
      writable: info.bool("writable") ?? false,
      hasSyncData: info.bool("hasSyncData") ?? false
    )
  }

  func recoveryWords() async -> [String]? { await SettingsAdapters.js("sync.recoveryWords") as? [String] }

  func phraseUnavailable() async -> String? { await SettingsAdapters.js("sync.phraseUnavailable") as? String }

  func recoveryQRCode() async -> Data? { Self.dataURL(await SettingsAdapters.js("sync.qrCode") as? String) }

  func recoveryKitPreview(width: Double) async -> Data? {
    Self.dataURL(await SettingsAdapters.js("sync.recoveryKitPreview", width) as? String)
  }

  func saveRecoveryKit(_ format: SyncKitFormat) async -> String? {
    await SettingsAdapters.js("sync.saveRecoveryKit", format.rawValue) as? String
  }

  func copyRecoveryKit() async { await SettingsAdapters.js("sync.copyRecoveryKit") }

  func shareRecoveryKit() async { await SettingsAdapters.js("sync.shareRecoveryKit") }

  func copyRecoveryPhrase() async { await SettingsAdapters.js("sync.copyRecoveryPhrase") }

  func revealFolder(_ path: String) async { await SettingsAdapters.js("sync.revealFolder", path) }

  func openICloudSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") else { return }
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[settings] background instance, not opening %@", url.absoluteString) }
    NSWorkspace.shared.open(url)
  }

  static func dataURL(_ uri: String?) -> Data? {
    guard let uri, uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
  }

  static func phraseResult(_ result: [String: Any]?) -> SyncPhraseResult {
    guard let result else { return .unavailable }
    if result.bool("ok") == true { return .ok }
    switch result.string("error") {
    case "wordCount": return .wordCount(result.int("count") ?? 0)
    case "unknownWord": return .unknownWord(result.string("word") ?? "")
    case "checksum": return .checksum
    case "mismatch": return .mismatch
    case "noData": return .noData
    case "keychain": return .keychain
    case "interrupted": return .interrupted
    default: return .unavailable
    }
  }

  static func state(_ value: Any?) -> SyncState? {
    guard let dict = value as? [String: Any], let status = dict.string("status").flatMap(SyncStatus.init(rawValue:)) else { return nil }
    let typeFlags = dict.dict("types") ?? [:]
    var types: [SyncDataType: Bool] = [:]
    for type in SyncDataType.allCases { types[type] = typeFlags[type.rawValue] as? Bool ?? true }
    return SyncState(
      status: status,
      enabled: dict.bool("enabled") ?? false,
      folder: dict.string("folder"),
      types: types,
      lastSyncedAt: dict.date("lastSyncedAt"),
      error: dict.string("error"),
      pending: dict.int("pending") ?? 0,
      devices: dict.list("devices").compactMap(device),
      localProfiles: dict.list("localProfiles").compactMap(localProfile),
      remoteProfiles: dict.list("remoteProfiles").compactMap(remoteProfile),
      heldPasswords: dict.list("heldPasswords").compactMap(heldPasswords),
      passwordsError: dict.string("passwordsError")
    )
  }

  static func badge(_ dict: [String: Any]) -> SyncProfileBadge {
    SyncProfileBadge(name: dict.string("name") ?? "", accentHex: dict.string("accentHex") ?? "", icon: dict.string("icon"))
  }

  static func heldPasswords(_ dict: [String: Any]) -> SyncHeldPasswords? {
    guard let id = dict.string("profileId"), let count = dict.int("count"), count > 0 else { return nil }
    return SyncHeldPasswords(profileId: id, profileName: dict.string("profileName"), count: count)
  }

  static func device(_ dict: [String: Any]) -> SyncDevice? {
    guard let id = dict.string("id") else { return nil }
    return SyncDevice(id: id, name: dict.string("name") ?? "", lastSeen: dict.date("lastSeen"), current: dict.bool("current") ?? false)
  }

  static func localProfile(_ dict: [String: Any]) -> SyncLocalProfile? {
    guard let id = dict.string("id") else { return nil }
    return SyncLocalProfile(id: id, badge: badge(dict), sharesDataWith: dict.string("sharesDataWith"), synced: dict.bool("synced"))
  }

  static func remoteProfile(_ dict: [String: Any]) -> SyncRemoteProfile? {
    guard let syncId = dict.string("syncId") else { return nil }
    let owner = dict.dict("sharesWith").map { SyncRemoteProfile.SharedOwner(name: $0.string("name") ?? "", added: $0.bool("added") ?? false) }
    return SyncRemoteProfile(syncId: syncId, badge: badge(dict), sharesWith: owner, waiting: dict.bool("waiting") ?? false)
  }
}
