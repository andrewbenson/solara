import Foundation
import Observation
import SolaraModel

public struct SettingsProfile: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let engineProfile: String
  public var color: String = "plum"
  public var icon: String?
  public var dataId: String?
  public var theme: JSONValue?
  public var fileTheme: ProfileFileTheme?
}

@MainActor
@Observable
public final class SettingsModel {
  public private(set) var settings: Settings
  public private(set) var profiles: [SettingsProfile]
  @ObservationIgnored private let store: Store
  @ObservationIgnored private var subscription: Int?
  @ObservationIgnored private var adoptedRev: Int

  public init(store: Store) {
    self.store = store
    let snapshot = store.committedSnapshot
    adoptedRev = snapshot.rev
    settings = snapshot.state.settings
    profiles = Self.profiles(snapshot.state)
    store.sequence {
      subscription = store.subscribe { [weak self] commit in
        guard !commit.changes.settingsChanged.isEmpty || !commit.changes.settingsRemoved.isEmpty || !commit.changes.profiles.isEmpty
          || commit.changes.lists.contains("profileOrder")
        else { return }
        Task { @MainActor [weak self] in self?.adopt(commit) }
      }
      let current = store.committedSnapshot
      adopt(current.state, rev: current.rev)
    }
  }

  isolated deinit {
    if let subscription { store.unsubscribe(subscription) }
  }

  static func profiles(_ state: BrowserState) -> [SettingsProfile] {
    state.profileOrder.compactMap { id in
      state.profiles[id].map {
        SettingsProfile(
          id: $0.id, name: $0.name, engineProfile: state.engineProfile($0.id), color: $0.color, icon: $0.icon, dataId: $0.dataId, theme: $0.theme,
          fileTheme: $0.fileTheme)
      }
    }
  }

  func adopt(_ commit: Commit) {
    adopt(commit.state, rev: commit.rev)
  }

  private func adopt(_ state: BrowserState, rev: Int) {
    guard rev > adoptedRev else { return }
    adoptedRev = rev
    if state.settings != settings { settings = state.settings }
    let next = Self.profiles(state)
    if next != profiles { profiles = next }
  }

  public func writeProfile(_ command: Command) throws -> Commit? {
    try writeProfile { _ in command }
  }

  public func editProfile(_ id: String, fields: JSONObject) throws -> Commit? {
    try writeProfile { ProfileThemeEdit.command(profileId: id, fields: fields, state: $0) }
  }

  public func deleteProfile(_ id: String, engineProfile: String, shared: Bool) throws -> Bool {
    let commit = try writeProfile { state in
      guard let profile = state.profiles[id], profile.id.jsEquals(id), engineIdOf(profile).jsEquals(engineProfile) else { return nil }
      let sharesData = sharesProfileEngine(engineProfile, excluding: id, in: state)
      return sharesData == shared ? SettingsWrites.deleteProfile(id) : nil
    }
    return commit?.effects.contains {
      guard case .profileDeleted(let deleted, let keptData, let engine) = $0 else { return false }
      return deleted.jsEquals(id) && engine.jsEquals(engineProfile) && keptData == shared
    } ?? false
  }

  private func writeProfile(_ makeCommand: (BrowserState) -> Command?) throws -> Commit? {
    guard SettingsWrites.directStore === store else { return nil }
    let commit = try store.sequence { () -> Commit? in
      guard !NativeStoreHandle.frozen, let command = makeCommand(store.committedSnapshot.state) else { return nil }
      return try store.dispatch(command, origin: .native)
    }
    if let commit { adopt(commit) }
    return commit
  }

  public func value(_ key: String) -> JSONValue? { settings[key] }

  public func update(_ patch: JSONObject, fromSync: Bool = false) {
    do {
      let commit = try store.dispatch(Command("updateSettings", [.object(patch), ["fromSync": .bool(fromSync)]]), origin: .native)
      adopt(commit)
    } catch {
      FileHandle.standardError.write(Data("SettingsModel: updateSettings failed: \(error)\n".utf8))
    }
  }
}
