import AppKit
import Observation
import SwiftUI

public enum SyncStatus: String, Sendable, Equatable {
  case off
  case starting
  case updating
  case updated
  case stalled
  case offline
  case locked
  case reset
  case unavailable
}

public enum SyncDataType: String, CaseIterable, Sendable, Identifiable {
  case bookmarks
  case history
  case tabs
  case pinned
  case passwords
  case extensions
  case settings

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .bookmarks: "Bookmarks"
    case .history: "History"
    case .tabs: "Open Tabs"
    case .pinned: "Pinned Tabs and Groups"
    case .passwords: "Passwords"
    case .extensions: "Extensions"
    case .settings: "Settings"
    }
  }

  var summary: String {
    switch self {
    case .bookmarks: "Each synced profile’s bookmarks bar and other bookmarks."
    case .history: "The last 90 days."
    case .tabs: "Your other devices’ tabs show in the tab overflow menu."
    case .pinned: "Pinned tabs and pinned tab groups."
    case .passwords: "Saved passwords. Turning sync off never removes them from this Mac."
    case .extensions: "Extensions from the Chrome Web Store, whether they’re on, and whether they’re pinned."
    case .settings: "Search engine, appearance, tab and keyboard settings."
    }
  }
}

public struct SyncFolderInfo: Sendable, Equatable {
  public var path: String
  public var defaultPath: String
  public var iCloudAvailable: Bool
  public var inICloud: Bool
  public var exists: Bool
  public var writable: Bool
  public var hasSyncData: Bool

  public init(path: String, defaultPath: String, iCloudAvailable: Bool, inICloud: Bool, exists: Bool, writable: Bool, hasSyncData: Bool) {
    self.path = path
    self.defaultPath = defaultPath
    self.iCloudAvailable = iCloudAvailable
    self.inICloud = inICloud
    self.exists = exists
    self.writable = writable
    self.hasSyncData = hasSyncData
  }
}

public struct SyncProfileBadge: Sendable, Equatable {
  public var name: String
  public var accentHex: String
  public var icon: String?

  public init(name: String, accentHex: String, icon: String?) {
    self.name = name
    self.accentHex = accentHex
    self.icon = icon
  }
}

public struct SyncLocalProfile: Sendable, Equatable, Identifiable {
  public var id: String
  public var badge: SyncProfileBadge
  public var sharesDataWith: String?
  public var synced: Bool?

  public init(id: String, badge: SyncProfileBadge, sharesDataWith: String? = nil, synced: Bool?) {
    self.id = id
    self.badge = badge
    self.sharesDataWith = sharesDataWith
    self.synced = synced
  }
}

public struct SyncRemoteProfile: Sendable, Equatable, Identifiable {
  public struct SharedOwner: Sendable, Equatable {
    public var name: String
    public var added: Bool

    public init(name: String, added: Bool) {
      self.name = name
      self.added = added
    }
  }

  public var syncId: String
  public var badge: SyncProfileBadge
  public var sharesWith: SharedOwner?
  public var waiting: Bool

  public var id: String { syncId }

  public init(syncId: String, badge: SyncProfileBadge, sharesWith: SharedOwner? = nil, waiting: Bool = false) {
    self.syncId = syncId
    self.badge = badge
    self.sharesWith = sharesWith
    self.waiting = waiting
  }
}

public struct SyncDevice: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var lastSeen: Date?
  public var current: Bool

  public init(id: String, name: String, lastSeen: Date?, current: Bool) {
    self.id = id
    self.name = name
    self.lastSeen = lastSeen
    self.current = current
  }
}

public struct SyncHeldPasswords: Sendable, Equatable, Identifiable {
  public var profileId: String
  public var profileName: String?
  public var count: Int
  public var id: String { profileId }

  public init(profileId: String, profileName: String? = nil, count: Int) {
    self.profileId = profileId
    self.profileName = profileName
    self.count = count
  }
}

public struct SyncState: Sendable, Equatable {
  public var status: SyncStatus
  public var enabled: Bool
  public var folder: String?
  public var types: [SyncDataType: Bool]
  public var lastSyncedAt: Date?
  public var error: String?
  public var pending: Int
  public var devices: [SyncDevice]
  public var localProfiles: [SyncLocalProfile]
  public var remoteProfiles: [SyncRemoteProfile]
  public var heldPasswords: [SyncHeldPasswords]
  public var passwordsError: String?

  public init(
    status: SyncStatus,
    enabled: Bool,
    folder: String?,
    types: [SyncDataType: Bool] = Dictionary(uniqueKeysWithValues: SyncDataType.allCases.map { ($0, true) }),
    lastSyncedAt: Date? = nil,
    error: String? = nil,
    pending: Int = 0,
    devices: [SyncDevice] = [],
    localProfiles: [SyncLocalProfile] = [],
    remoteProfiles: [SyncRemoteProfile] = [],
    heldPasswords: [SyncHeldPasswords] = [],
    passwordsError: String? = nil
  ) {
    self.status = status
    self.enabled = enabled
    self.folder = folder
    self.types = types
    self.lastSyncedAt = lastSyncedAt
    self.error = error
    self.pending = pending
    self.devices = devices
    self.localProfiles = localProfiles
    self.remoteProfiles = remoteProfiles
    self.heldPasswords = heldPasswords
    self.passwordsError = passwordsError
  }
}

public enum SyncPhraseResult: Sendable, Equatable {
  case ok
  case wordCount(Int)
  case unknownWord(String)
  case checksum
  case mismatch
  case noData
  case keychain
  case interrupted
  case unavailable

  var message: String? {
    switch self {
    case .ok: nil
    case .wordCount: "Recovery phrase must be exactly 24 words."
    case .unknownWord(let word): "“\(word)” is not a valid recovery phrase word."
    case .checksum: "This recovery phrase is not valid. Please check for typos."
    case .mismatch: "This recovery phrase doesn’t match the synced data in this folder. Check the phrase, or choose the folder your other devices sync to."
    case .noData: "There’s no synced data in this folder yet. Choose the folder your other devices sync to, or wait for it to finish downloading."
    case .keychain: "Couldn’t save the sync key in your Keychain."
    case .interrupted: "Sync was turned off or on again while this phrase was checked. Enter it again."
    case .unavailable: "Sync isn’t available in this build."
    }
  }
}

public enum SyncKitFormat: String, Sendable {
  case pdf
  case text
}

@MainActor
public protocol SyncServices: AnyObject {
  func invalidatePairing(_ reason: String)
  func currentSyncState() async -> SyncState
  func syncStateUpdates() -> AsyncStream<SyncState>
  func chooseSyncFolder() async -> String?
  func turnOnSync(folder: String) async -> String?
  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult
  func stopSync(deleteData: Bool) async
  func syncNow() async
  func setTypeSynced(_ type: SyncDataType, _ on: Bool)
  func setProfileSynced(_ profileId: String, _ on: Bool)
  func addRemoteProfile(_ syncId: String)
  func resolveHeldPasswords(_ profileId: String, restore: Bool)

  func folderInfo(path: String?) async -> SyncFolderInfo?
  func recoveryWords() async -> [String]?
  func phraseUnavailable() async -> String?
  func recoveryQRCode() async -> Data?
  func recoveryKitPreview(width: Double) async -> Data?
  func saveRecoveryKit(_ format: SyncKitFormat) async -> String?
  func copyRecoveryKit() async
  func shareRecoveryKit() async
  func copyRecoveryPhrase() async
  func revealFolder(_ path: String) async
  func openICloudSettings()
}

public extension SyncServices {
  func resolveHeldPasswords(_ profileId: String, restore: Bool) {}
}

public enum SyncSheet: Identifiable, Equatable {
  case recoveryKit
  case phrase(canChangeFolder: Bool)
  case connectDevice
  case stop
  case deleteData
  case trustedPairing(surfaceID: UUID)
  case separateSync(inspectionID: String)

  public var id: String {
    switch self {
    case .recoveryKit: "recoveryKit"
    case .phrase(let canChange): canChange ? "phrase-change" : "phrase"
    case .connectDevice: "connectDevice"
    case .stop: "stop"
    case .deleteData: "deleteData"
    case .trustedPairing(let id): "trusted-\(id)"
    case .separateSync(let id): "separate-\(id)"
    }
  }
}

@MainActor
@Observable
public final class SyncPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: SyncServices
  public let pairing: SyncTrustedPairingModel?
  public let creation: SyncCreationModel?
  var state: SyncState?
  var info: SyncFolderInfo?
  var prepared = false
  var turningOn = false
  var failure: String?
  var sheet: SyncSheet? {
    didSet {
      if oldValue != sheet {
        if case .trustedPairing = oldValue { services.invalidatePairing("reload") }
        if case .trustedPairing = oldValue { pairing?.surfaceChanged(.removed) }
        if case .separateSync = oldValue, case .separateSync = sheet {}
        else if case .separateSync = oldValue { creation?.cancel() }
      }
    }
  }
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private var infoRequest = 0

  public init(services: SyncServices, pairingService: (any TrustedPairingService)? = nil, creationService: (any SyncCreationServices)? = nil) {
    self.services = services
    pairing = (pairingService ?? TrustedPairingRegistration.service).map { SyncTrustedPairingModel(service: $0) }
    creation = (creationService ?? (services as? any SyncCreationServices)).map { SyncCreationModel(services: $0) }
  }

  public func pairingSurfaceAvailable(to window: NSWindow) { pairing?.attach(to: window) }

  public func pairingSurfaceRemoved() {
    services.invalidatePairing("reload")
    pairing?.teardown()
    creation?.cancel()
    sheet = nil
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { prepared }

  public func prepare(_ place: SettingsPlace) async {
    if state == nil { state = await services.currentSyncState() }
    listen()
    await reloadInfo()
    prepared = true
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(SyncPane(model: self))
  }

  private func listen() {
    guard listener == nil else { return }
    let updates = services.syncStateUpdates()
    listener = Task { [weak self] in
      for await next in updates {
        guard let self else { return }
        self.apply(next)
      }
    }
  }

  func apply(_ next: SyncState) {
    let previous = state
    if let previous, (previous.enabled && !next.enabled) ||
        (next.status == .locked && previous.status != .locked) || previous.folder != next.folder {
      services.invalidatePairing("reload")
      pairing?.surfaceChanged(.removed)
      creation?.cancel()
    }
    state = next
    guard let previous else { return }
    if previous.enabled != next.enabled || previous.status != next.status || previous.folder != next.folder {
      Task { await reloadInfo() }
    }
  }

  func reloadInfo(path: String? = nil) async {
    infoRequest += 1
    let request = infoRequest
    let loaded = await services.folderInfo(path: path ?? state?.folder)
    guard request == infoRequest else { return }
    info = loaded
  }

  var noICloud: Bool {
    guard let info else { return false }
    return info.path == info.defaultPath && !info.iCloudAvailable
  }

  var hasSyncData: Bool { info?.hasSyncData ?? false }

  var offDescription: String {
    if state?.status == .reset, let error = state?.error { return error }
    return hasSyncData ? "Enter a recovery phrase from another device to use the synced data in this folder." : "Off"
  }

  var folderDescription: String { info.map(SyncText.folderLabel) ?? " " }

  func invalidatePairing(_ reason: String) { services.invalidatePairing(reason) }

  func turnOn() async {
    services.invalidatePairing("rekey")
    guard let info else { return }
    pairing?.end(.cancel)
    turningOn = true
    failure = nil
    if let creation {
      await creation.start(folder: info.path)
      turningOn = false
      applyCreationState()
      return
    }
    let error = await services.turnOnSync(folder: info.path)
    turningOn = false
    if let error {
      failure = error
    } else {
      sheet = .recoveryKit
    }
  }

  func confirmSeparateSync(inspectionID: String) async {
    guard let creation, sheet == .separateSync(inspectionID: inspectionID),
          case .warning(let inspection) = creation.state, inspection.id == inspectionID else { return }
    services.invalidatePairing("rekey")
    turningOn = true
    await creation.confirmSeparateSync()
    turningOn = false
    applyCreationState()
  }

  private func applyCreationState() {
    guard let creation else { return }
    switch creation.state {
    case .warning(let inspection): sheet = .separateSync(inspectionID: inspection.id)
    case .created: sheet = .recoveryKit
    case .failed(let message): failure = message; sheet = nil
    default: break
    }
  }

  func connectAnotherMac(reviewing: TrustedRequest? = nil) {
    pairing?.connect(reviewing: reviewing)
    showPairingIfAdmitted()
  }

  func showPairingIfAdmitted() {
    guard let pairing, pairing.isPresented, let arm = pairing.arm else { return }
    sheet = .trustedPairing(surfaceID: arm.id)
  }

  func chooseFolder() async {
    services.invalidatePairing("folder")
    pairing?.end(.cancel)
    creation?.cancel()
    if let picked = await services.chooseSyncFolder() {
      await reloadInfo(path: picked)
    }
  }

  func changeFolderForPhrase() async {
    services.invalidatePairing("folder")
    pairing?.end(.cancel)
    creation?.cancel()
    let picked = await services.chooseSyncFolder()
    await reloadInfo(path: picked)
    sheet = .phrase(canChangeFolder: false)
  }

  func submitPhrase(_ text: String) async -> String? {
    services.invalidatePairing("rekey")
    pairing?.end(.cancel)
    creation?.cancel()
    guard let info else { return nil }
    let result = await services.enterRecoveryPhrase(folder: info.path, text: text)
    if let message = result.message { return message }
    sheet = nil
    return nil
  }

  func stop(deleteData: Bool) async {
    services.invalidatePairing("stop")
    pairing?.surfaceChanged(.removed)
    creation?.cancel()
    await services.stopSync(deleteData: deleteData)
    sheet = nil
  }

  func setType(_ type: SyncDataType, _ on: Bool) {
    state?.types[type] = on
    services.setTypeSynced(type, on)
  }

  func setProfile(_ profileId: String, _ on: Bool) {
    if let index = state?.localProfiles.firstIndex(where: { $0.id == profileId }), state?.localProfiles[index].synced != nil {
      state?.localProfiles[index].synced = on
    }
    services.setProfileSynced(profileId, on)
  }
}

enum SyncText {
  static let intro = "Sync your browsing data across Macs through a folder you choose. Synced contents are encrypted."
  static let offNote = "Pairing shows this Mac’s name to the Mac you’re pairing with before you compare codes, even if you cancel. Anyone who can open your sync folder could start a pairing. Pairing files show when a pairing happened and how it ended, but none of your synced data."
  static let unavailable = "Sync isn’t available in this build."

  static func ago(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
    let hours = minutes / 60
    if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
    let days = hours / 24
    return days == 1 ? "yesterday" : "\(days) days ago"
  }

  static func heldPasswordsTitle(_ held: SyncHeldPasswords) -> String {
    let what = held.count == 1 ? "1 password was" : "\(held.count) passwords were"
    return "\(what) removed or changed on this Mac\(held.profileName.map { " in \($0)" } ?? "")."
  }

  static let heldPasswordsQuestion = "Remove or change them on your other Macs too, or restore them here?"

  static func statusLine(_ status: SyncStatus, lastSyncedAt: Date?, pending: Int, now: Date) -> String {
    let since = lastSyncedAt.map { ago($0, now: now) }
    let line: String
    switch status {
    case .starting: line = "starting up"
    case .updating: line = "updating"
    case .offline: line = "offline"
    case .stalled, .locked: line = since.map { "not syncing · last synced \($0)" } ?? "not syncing"
    default: line = since.flatMap { $0 == "just now" ? nil : "updated \($0)" } ?? "updated just now"
    }
    guard pending > 0 else { return line }
    return "\(line) · waiting for \(pending == 1 ? "1 file" : "\(pending) files") to download"
  }

  static func homeRelative(_ path: String) -> String {
    guard let match = path.range(of: "^/Users/[^/]+", options: .regularExpression) else { return path }
    return path.replacingCharacters(in: match, with: "~")
  }

  static func folderLabel(_ info: SyncFolderInfo) -> String {
    folderLabel(path: info.path, inICloud: info.inICloud)
  }

  static func folderLabel(path: String, inICloud: Bool) -> String {
    guard inICloud else { return homeRelative(path) }
    let parts = path.components(separatedBy: "com~apple~CloudDocs")
    let rest = parts.count > 1 ? parts[1].split(separator: "/").map(String.init) : []
    return (["iCloud Drive"] + rest).joined(separator: " › ")
  }

  static func remoteProfileDescription(_ profile: SyncRemoteProfile) -> String {
    if profile.waiting { return "On your other devices. Waiting for the profile it shares data with to sync." }
    guard let owner = profile.sharesWith else { return "On your other devices" }
    return owner.added
      ? "On your other devices. Shares data with \(owner.name), which is added too."
      : "On your other devices. Shares data with \(owner.name)."
  }

  static func sharedDataDescription(_ owner: String?) -> String? {
    owner.map { "Shares data with \($0): its tabs sync here, its data syncs with \($0)." }
  }

  static func deviceTitle(_ device: SyncDevice) -> String {
    device.current ? "\(device.name) (This Mac)" : device.name
  }

  static func deviceDescription(_ device: SyncDevice, state: SyncState, now: Date) -> String {
    if device.current { return statusLine(state.status, lastSyncedAt: state.lastSyncedAt, pending: 0, now: now) }
    return device.lastSeen.map { "last synced \(ago($0, now: now))" } ?? "hasn’t synced yet"
  }
}

struct SyncPane: View {
  @Bindable var model: SyncPaneModel

  var body: some View {
    SettingsForm {
      if let state = model.state {
        if state.status == .unavailable {
          Section {
            Text(state.error ?? SyncText.unavailable).foregroundStyle(.secondary)
          }
        } else if state.enabled {
          SyncOnSections(model: model, state: state)
          if let pairing = model.pairing {
            Section {
              if pairing.indicator == .pending || pairing.indicator == .overflow {
                SettingRow(title: "A Mac is requesting to connect", description: "Only review a connection you just started.") {
                  Button("Review request") { model.connectAnotherMac() }
                }
              }
              if pairing.phase == .sentUnconfirmed { Text(SyncPairingText.sent).foregroundStyle(.secondary) }
              if pairing.phase == .confirmed { Text("Approval received. Sync data is still downloading on your other Mac.").foregroundStyle(.secondary) }
              if pairing.indicator == .persistenceFailure { Text(SyncPairingText.persistenceFailure).foregroundStyle(.secondary) }
              if pairing.phase == .ended(.invalidLocalName) { SyncPairingNameRepairView(model: pairing) }
              if pairing.phase == .ended(.rateLimited) { SyncPairingLimitView(model: pairing) }
            }
          }
        } else {
          SyncOffSection(model: model, state: state)
        }
      }
    }
    .background {
      if let pairing = model.pairing { SyncPairingSurfaceProbe(model: pairing).frame(width: 0, height: 0) }
    }
    .onChange(of: model.pairing?.isPresented) { _, presented in
      if presented == true { model.showPairingIfAdmitted() }
      else if case .trustedPairing = model.sheet { model.sheet = nil }
    }
    .sheet(item: $model.sheet) { sheet in
      SyncSheetView(model: model, sheet: sheet)
    }
  }
}

struct SyncIntroHeader: View {
  var body: some View {
    Text(SyncText.intro)
      .font(.callout)
      .fontWeight(.regular)
      .foregroundStyle(.secondary)
      .textCase(nil)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 6)
  }
}

struct SyncOffSection: View {
  let model: SyncPaneModel
  let state: SyncState

  var body: some View {
    let noICloud = model.noICloud
    Section {
      HStack(spacing: 10) {
        SyncIcon(on: false)
        SettingRow("sync.sync", description: model.offDescription) {
          HStack(spacing: 8) {
          if model.hasSyncData {
            Menu("Other Options") {
              Button("Set Up Without Another Device…") { model.invalidatePairing("rekey"); Task { await model.turnOn() } }
                .disabled(noICloud)
              Button("Enter Recovery Phrase") { model.sheet = .phrase(canChangeFolder: true) }
            }
            .settingsMenu()
            Button("Enter Recovery Phrase…") { model.sheet = .phrase(canChangeFolder: true) }
              .buttonStyle(.borderedProminent)
          } else {
            Button("Enter Recovery Phrase…") { model.sheet = .phrase(canChangeFolder: true) }
              .disabled(noICloud)
            Button(model.turningOn ? "Turning On…" : "Turn On Sync") { model.invalidatePairing("rekey"); Task { await model.turnOn() } }
              .buttonStyle(.borderedProminent)
              .disabled(model.turningOn || noICloud || model.info == nil)
          }
          }
        }
      }
      SettingRow("sync.folder", description: model.folderDescription) {
        Button("Choose…") { model.invalidatePairing("folder"); Task { await model.chooseFolder() } }
      }
      if noICloud {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.icloud")
            .font(.system(size: 14))
            .foregroundStyle(Color.orange)
            .frame(width: 28, height: 20)
          SettingRow(
            title: "iCloud Drive is off on this Mac",
            description: "Turn on iCloud Drive in System Settings, or choose another folder that syncs your Macs."
          ) {
            Button("Open iCloud Settings") { model.services.openICloudSettings() }
          }
        }
      }
    } header: {
      SyncIntroHeader()
    } footer: {
      VStack(alignment: .leading, spacing: 8) {
        if let failure = model.failure {
          Text(failure).foregroundStyle(Color.red)
        }
        Text(SyncText.offNote).foregroundStyle(.tertiary)
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct SyncOnSections: View {
  let model: SyncPaneModel
  let state: SyncState
  @State private var now = Date()

  var body: some View {
    let locked = state.status == .locked
    Section {
      HStack(spacing: 10) {
        SyncIcon(on: !locked)
        SettingRow("sync.sync", description: SyncText.statusLine(state.status, lastSyncedAt: state.lastSyncedAt, pending: state.pending, now: now)) {
          HStack(spacing: 8) {
            if locked {
              Button("Enter Recovery Phrase…") { model.sheet = .phrase(canChangeFolder: false) }
                .buttonStyle(.borderedProminent)
            } else {
              Button("Connect Another Device…") { model.sheet = .connectDevice }
            }
            SyncAdvancedMenu(model: model)
          }
        }
      }
      SettingRow("sync.folder", description: .text(model.folderDescription))
    } header: {
      SyncIntroHeader()
    } footer: {
      if let error = state.error, state.status != .updated {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.red)
          Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        now = Date()
      }
    }

    if let passwordsError = state.passwordsError {
      Section {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: "key.slash")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 20)
          Text(passwordsError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    ForEach(state.heldPasswords) { held in
      Section {
        HStack(spacing: 10) {
          Image(systemName: "key.fill")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 20)
          SettingRow(title: SyncText.heldPasswordsTitle(held), description: SyncText.heldPasswordsQuestion) {
            HStack(spacing: 8) {
              Button("Change Everywhere") { model.services.resolveHeldPasswords(held.profileId, restore: false) }
              Button("Restore Here") { model.services.resolveHeldPasswords(held.profileId, restore: true) }
                .buttonStyle(.borderedProminent)
            }
          }
        }
      }
    }

    SettingsSection("Profiles", description: "Choose which profiles sync on this Mac. Each syncs on its own.") {
      ForEach(state.localProfiles) { profile in
        HStack(spacing: 10) {
          SyncProfileBadgeView(badge: profile.badge, size: 24)
          SettingRow(title: profile.badge.name, description: SyncText.sharedDataDescription(profile.sharesDataWith).map(RowDescription.text) ?? RowDescription.none) {
            Toggle("", isOn: Binding(get: { profile.synced ?? false }, set: { model.setProfile(profile.id, $0) }))
              .labelsHidden()
              .toggleStyle(.settingsSwitch)
              .disabled(profile.synced == nil)
          }
        }
      }
      ForEach(state.remoteProfiles) { profile in
        HStack(spacing: 10) {
          SyncProfileBadgeView(badge: profile.badge, size: 24)
          SettingRow(title: profile.badge.name, description: SyncText.remoteProfileDescription(profile)) {
            Button("Add to This Mac") { model.services.addRemoteProfile(profile.syncId) }
              .disabled(profile.waiting)
          }
        }
      }
    }

    SettingsSection("What Syncs") {
      ForEach(SyncDataType.allCases) { type in
        SettingRow(title: type.title, description: type.summary) {
          Toggle("", isOn: Binding(get: { state.types[type] ?? false }, set: { model.setType(type, $0) }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
        }
      }
    }

    SettingsSection("Devices") {
      if state.devices.isEmpty {
        SettingRow(title: "Just this Mac so far", description: .text("Other devices show here once they sync."))
      } else {
        ForEach(state.devices) { device in
          HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
              .font(.system(size: 15))
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 20)
            SettingRow(title: SyncText.deviceTitle(device), description: .text(SyncText.deviceDescription(device, state: state, now: now)))
          }
        }
      }
    }
  }
}

struct SyncAdvancedMenu: View {
  let model: SyncPaneModel

  var body: some View {
    Menu("Advanced…") {
      Button("Save Recovery Kit…", systemImage: "arrow.down.doc") { model.sheet = .recoveryKit }
      Button("Copy Recovery Code", systemImage: "doc.on.doc") { Task { await model.services.copyRecoveryPhrase() } }
      Divider()
      Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.services.syncNow() } }
      Button("Show Sync Folder in Finder", systemImage: "folder") {
        guard let info = model.info else { return }
        Task { await model.services.revealFolder(info.path) }
      }
      .disabled(!(model.info?.exists ?? false))
      Divider()
      Button("Stop Syncing…", systemImage: "xmark.circle") { model.sheet = .stop }
    }
    .settingsMenu()
  }
}

struct SyncIcon: View {
  let on: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background))
      if !on {
        Circle().strokeBorder(.separator, lineWidth: 1)
      }
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
    }
    .frame(width: 28, height: 28)
  }
}

struct SyncProfileBadgeView: View {
  let badge: SyncProfileBadge
  let size: CGFloat

  static let symbolPrefix = "symbol:"

  var symbol: String? {
    guard let icon = badge.icon, icon.hasPrefix(Self.symbolPrefix) else { return nil }
    return String(icon.dropFirst(Self.symbolPrefix.count))
  }

  var glyph: String {
    badge.icon ?? badge.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
  }

  var body: some View {
    ZStack {
      Circle().fill(SyncColor.hex(badge.accentHex) ?? Color(red: 0.75, green: 0.48, blue: 0.6))
      if size >= 22 {
        Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
      }
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(Color.white)
      } else {
        Text(glyph)
          .font(.system(size: badge.icon != nil ? size * 0.55 : size * 0.46, weight: .semibold))
          .foregroundStyle(Color.white)
      }
    }
    .frame(width: size, height: size)
  }
}

enum SyncColor {
  static func hex(_ text: String) -> Color? {
    var digits = text.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
    let rgb = digits.count == 8 ? value >> 8 : value
    let alpha = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
    return Color(
      .sRGB,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      opacity: alpha
    )
  }
}
