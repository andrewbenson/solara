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

  public init(store: Store) {
    self.store = store
    let state = store.state
    settings = state.settings
    profiles = Self.profiles(state)
    subscription = store.subscribe { [weak self] commit in
      guard !commit.changes.settingsChanged.isEmpty || !commit.changes.settingsRemoved.isEmpty || !commit.changes.profiles.isEmpty
        || commit.changes.lists.contains("profileOrder")
      else { return }
      let state = commit.state
      Task { @MainActor [weak self] in self?.adopt(state) }
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

  func adopt(_ state: BrowserState) {
    if state.settings != settings { settings = state.settings }
    let next = Self.profiles(state)
    if next != profiles { profiles = next }
  }

  public func value(_ key: String) -> JSONValue? { settings[key] }

  public func update(_ patch: JSONObject, fromSync: Bool = false) {
    do {
      let commit = try store.dispatch(Command("updateSettings", [.object(patch), ["fromSync": .bool(fromSync)]]), origin: .native)
      adopt(commit.state)
    } catch {
      FileHandle.standardError.write(Data("SettingsModel: updateSettings failed: \(error)\n".utf8))
    }
  }
}
