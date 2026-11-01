import AppKit
import SolaraCore
import SolaraShaders
import Foundation
import Observation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
@Observable
final class ProfilesAdapter: ProfilesServices {
  private(set) var appDark: Bool
  private var statsByProfile: [String: ProfileStats]
  private var pending: (base: [SolaraStore.SettingsProfile], profiles: [ProfileSummary])?
  @ObservationIgnored private let store: StoreSettingsSource
  @ObservationIgnored private var observers: [(String, UUID)] = []

  init(store: StoreSettingsSource) {
    self.store = store
    let js = SettingsJS.shared
    appDark = js.latestValue("profiles.appDark") as? Bool ?? true
    statsByProfile = Self.stats(js.latestValue("profiles.stats"))
    observers.append(("profiles.appDark", js.observe("profiles.appDark") { [weak self] in self?.appDark = $0 as? Bool ?? true }))
    observers.append(("profiles.stats", js.observe("profiles.stats") { [weak self] in self?.statsByProfile = Self.stats($0) }))
  }

  var profiles: [ProfileSummary] {
    get {
      let mirrored = store.model.profiles
      if let pending, pending.base == mirrored { return pending.profiles }
      return mirrored.map(Self.summary)
    }
    set { pending = (store.model.profiles, newValue) }
  }

  func stats(profileId: String) -> ProfileStats {
    statsByProfile[profileId] ?? ProfileStats(historyPages: 0, bookmarks: 0)
  }

  func createProfile(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    SettingsJS.shared.fire("profiles.create", name, color.rawValue, jsonArg(shareWith))
    return ""
  }

  func updateProfile(_ id: String, _ patch: ProfilePatch) {
    var arg: [String: Any] = [:]
    if let name = patch.name { arg["name"] = name }
    if let color = patch.color { arg["color"] = color.rawValue }
    if let icon = patch.icon { arg["icon"] = jsonArg(icon) }
    if let theme = patch.theme { arg["theme"] = theme.flatMap(Self.json) ?? NSNull() }
    guard !arg.isEmpty else { return }
    if SolaraCoreHost.safeMode {
      SettingsJS.shared.fire("profiles.update", id, arg)
      return
    }
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      var profile = profiles[index]
      if let name = patch.name { profile.name = name }
      if let color = patch.color { profile.color = color }
      if let icon = patch.icon { profile.icon = icon }
      if let theme = patch.theme { profile.theme = theme }
      profiles[index] = profile
    }
    SettingsJS.shared.fire("profiles.update", id, arg)
  }

  func deleteProfile(_ id: String, completion: @escaping @MainActor (Bool) -> Void) {
    guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { completion(false); return }
    Task {
      do {
        _ = try await SettingsAdapters.jsThrowing("profiles.delete", id)
        completion(true)
      } catch {
        NSLog("[settings] %@ failed: %@", "profiles.delete", String(describing: error))
        completion(false)
      }
    }
  }

  func reorderProfiles(_ ids: [String]) {
    if SolaraCoreHost.safeMode {
      SettingsJS.shared.fire("profiles.reorder", ids)
      return
    }
    let known = ids.compactMap { id in profiles.first { $0.id == id } }
    profiles = known + profiles.filter { !ids.contains($0.id) }
    Task { _ = await SettingsAdapters.js("profiles.reorder", ids) }
  }

  func setDefaultProfile(_ id: String) { store.set("defaultProfileId", id) }

  func clearHistory(profileId: String, since: Date?) {
    SettingsJS.shared.fire("profiles.clearHistory", profileId, Self.millis(since))
  }

  func pruneProfileFavicons(profileId: String) {
    SettingsJS.shared.fire("profiles.pruneFavicons", profileId)
  }

  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async {
    _ = await SettingsAdapters.js("profiles.clearBrowsingData", engineProfile, kinds.map(\.rawValue), Self.millis(since))
  }

  func extensionsKeptOnDelete() async -> [String]? {
    await EngineCalls.result({ done in SolaraCoreServices.listExtensions(profile: "") { done($0) } }) {
      EngineCalls.failed($0, "listExtensions") ? nil : $0.list("extensions").filter { $0.bool("mayModify") == true }.compactMap { $0.string("name") }
    }
  }

  func adoptProfileTheme(_ id: String) { SettingsJS.shared.fire("profiles.adoptTheme", id) }

  func holdThemedWindowsKeyLook(_ on: Bool) { ThemedWindows.holdKeyLook(on) }

  func arcThemeChoices() async -> [ArcThemeChoice] {
    let list = await SettingsAdapters.js("profiles.arcThemeChoices") as? [[String: Any]] ?? []
    return list.compactMap { choice in
      guard let id = choice.string("id"), let theme = Self.theme(choice["theme"]) else { return nil }
      return ArcThemeChoice(id: id, name: choice.string("name") ?? "", emoji: choice.string("emoji"), theme: theme)
    }
  }

  func themeSwatch(_ spec: ThemeSwatchSpec) -> AnyView? { nil }

  func hapticTick() {
    ACSwipe.performHaptic("alignment")
  }

  static func millis(_ date: Date?) -> Any {
    date.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? NSNull()
  }

  static func summary(_ profile: SolaraStore.SettingsProfile) -> ProfileSummary {
    ProfileSummary(
      id: profile.id,
      name: profile.name,
      color: ProfileColorValue(rawValue: profile.color) ?? .plum,
      icon: profile.icon,
      dataId: profile.dataId,
      theme: profile.theme.flatMap { try? JSONDecoder().decode(ProfileThemeValue.self, from: Data($0.text().utf8)) }
    )
  }

  static func stats(_ value: Any?) -> [String: ProfileStats] {
    guard let dict = value as? [String: Any] else { return [:] }
    var result: [String: ProfileStats] = [:]
    for (id, entry) in dict {
      guard let entry = entry as? [String: Any] else { continue }
      result[id] = ProfileStats(historyPages: entry.int("historyPages") ?? 0, bookmarks: entry.int("bookmarks") ?? 0)
    }
    return result
  }

  static func theme(_ value: Any?) -> ProfileThemeValue? {
    guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(ProfileThemeValue.self, from: data)
  }

  static func json(_ theme: ProfileThemeValue) -> Any? {
    guard let data = try? JSONEncoder().encode(theme) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
