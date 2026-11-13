import Foundation
import SolaraModel
import SwiftUI

public struct SettingsProfile: Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let engineProfile: String

  public init(id: String, name: String, engineProfile: String) {
    self.id = id
    self.name = name
    self.engineProfile = engineProfile
  }
}

@MainActor
public protocol SettingsStoreSource: AnyObject {
  func settingValue(_ key: String) -> JSONValue?
  func updateSettings(_ patch: JSONObject)
  var profiles: [SettingsProfile] { get }
  var topTabLayout: Bool { get }
  func chooseTabLayout(_ layout: String)
  func fileSource(_ key: String) -> String?
  func fileSource(shortcut id: String) -> String?
  func fileTheme(profile id: String) -> String?
}

public extension SettingsStoreSource {
  func fileSource(_ key: String) -> String? { nil }
  func fileSource(shortcut id: String) -> String? { nil }
  func fileTheme(profile id: String) -> String? { nil }

  func fileSource(keys: [String]) -> String? { keys.lazy.compactMap { self.fileSource($0) }.first }

  func engineProfile(_ profileId: String) -> String {
    profiles.first { $0.id == profileId }?.engineProfile ?? profileId
  }

  func bool(_ key: String) -> Bool { settingValue(key)?.bool ?? false }
  func string(_ key: String) -> String { settingValue(key)?.string ?? "" }

  func set(_ key: String, _ value: Bool) { updateSettings([key: .bool(value)]) }
  func set(_ key: String, _ value: String) { updateSettings([key: .string(value)]) }

  func toggle(_ key: String) -> Binding<Bool> {
    Binding(get: { self.bool(key) }, set: { self.set(key, $0) })
  }

  func choice(_ key: String) -> Binding<String> {
    Binding(get: { self.string(key) }, set: { self.set(key, $0) })
  }
}
