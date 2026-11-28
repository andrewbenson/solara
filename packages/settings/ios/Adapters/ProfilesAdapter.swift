import AppKit
import SolaraCore
import SolaraImportAdapter
import SolaraShaders
import SolaraShell
import Foundation
import Observation
import SolaraModel
import SolaraOmnibox
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
    let engine = NativeStoreHandle.store?.displayState.engineProfile(profileId) ?? (profileId == "default" ? "" : profileId)
    return ProfileStats(historyPages: statsByProfile[profileId]?.historyPages ?? 0,
      bookmarks: NativeHistoryCatalog.catalog.bookmarks(engineProfile: engine).urlCount)
  }

  func createProfile(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    guard !refuseInSafeMode(ProfileWriteSafeModeAlert.creationMessage) else { return "" }
    let commit = writeProfile("createProfile") {
      try store.model.writeProfile(SettingsWrites.createProfile(name: name, color: color.rawValue, shareWith: shareWith))
    }
    return commit?.result?.string ?? ""
  }

  func updateProfile(_ id: String, _ patch: ProfilePatch) {
    guard patch != ProfilePatch(), !refuseInSafeMode(ProfileWriteSafeModeAlert.editMessage) else { return }
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      var profile = profiles[index]
      if let name = patch.name { profile.name = name }
      if let color = patch.color { profile.color = color }
      if let icon = patch.icon { profile.icon = icon }
      if let theme = patch.theme { profile.theme = theme }
      profiles[index] = profile
    }
    guard let fields = Self.fields(patch) else { return }
    writeProfile("updateProfile") { try store.model.editProfile(id, fields: fields) }
  }

  func deleteProfile(_ id: String, engineProfile: String, shared: Bool) -> Bool {
    guard !SolaraCoreHost.safeMode else { return false }
    do {
      return try store.model.deleteProfile(id, engineProfile: engineProfile, shared: shared)
    } catch {
      NSLog("[settings] deleteProfile failed: %@", String(describing: error))
      return false
    }
  }

  func reorderProfiles(_ ids: [String]) {
    guard !refuseInSafeMode(ProfileWriteSafeModeAlert.editMessage) else { return }
    let known = ids.compactMap { id in profiles.first { $0.id == id } }
    profiles = known + profiles.filter { !ids.contains($0.id) }
    writeProfile("reorderProfiles") { try store.model.writeProfile(SettingsWrites.reorderProfiles(ids)) }
  }

  private func refuseInSafeMode(_ message: String) -> Bool {
    guard SolaraCoreHost.safeMode else { return false }
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = ProfileWriteSafeModeAlert.title
      alert.informativeText = message
      alert.addButton(withTitle: "OK")
      alert.addButton(withTitle: "Cancel")
      alert.runModal()
    }
    return true
  }

  @discardableResult
  private func writeProfile(_ name: String, _ write: () throws -> Commit?) -> Commit? {
    do {
      return try write()
    } catch {
      NSLog("[settings] %@ failed: %@", name, String(describing: error))
      return nil
    }
  }

  func setDefaultProfile(_ id: String) { store.set("defaultProfileId", id) }

  func clearHistory(profileId: String, since: Date?) {
    SettingsJS.shared.fire("profiles.clearHistory", profileId, Self.millis(since))
  }

  func pruneProfileFavicons(profileId: String) {
    let profile = NativeStoreHandle.store?.displayState.engineProfile(profileId) ?? (profileId == "default" ? "" : profileId)
    NativeHistoryCatalog.catalog.favicons?.invalidate(engineProfile: profile)
  }

  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async {
    guard !SolaraCoreHost.safeMode else {
      _ = await SettingsAdapters.js("profiles.clearBrowsingData", engineProfile, kinds.map(\.rawValue), Self.millis(since))
      return
    }
    let types = kinds.map(\.rawValue)
    let from = since.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? 0
    let cleared = DispatchGroup()
    cleared.enter()
    cleared.enter()
    SolaraCoreServices.clearBrowsingData(profile: engineProfile, types: types, since: from) { @Sendable in cleared.leave() }
    SolaraCoreSettingsBridge.clearWebKitBrowsingData(profile: engineProfile, types: types, since: from) { @Sendable in cleared.leave() }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      cleared.notify(queue: .main) { done.resume() }
    }
  }

  func extensionsKeptOnDelete() async -> [String]? {
    await EngineCalls.result({ done in SolaraCoreServices.listExtensions(profile: "") { done($0) } }) {
      EngineCalls.failed($0, "listExtensions") ? nil : $0.list("extensions").filter { $0.bool("mayModify") == true }.compactMap { $0.string("name") }
    }
  }

  func adoptProfileTheme(_ id: String) { SettingsJS.shared.fire("profiles.adoptTheme", id) }

  func holdThemedWindowsKeyLook(_ on: Bool) { ThemedWindows.holdKeyLook(on) }

  func arcThemeChoices() async -> [ArcThemeChoice] {
    let spaces = await ImportService.shared.arcSpaces()
    return ArcThemeChoice.imported(from: spaces?.map { ($0.id, $0.name, $0.emoji, $0.theme) })
  }

  func themeSwatch(_ spec: ThemeSwatchSpec) -> AnyView? { nil }

  func hapticTick() {
    ACSwipe.performHaptic("alignment")
  }

  static func fields(_ patch: ProfilePatch) -> JSONObject? {
    var fields: [(String, JSONValue)] = []
    if let name = patch.name { fields.append(("name", .string(name))) }
    if let color = patch.color { fields.append(("color", .string(color.rawValue))) }
    if let icon = patch.icon { fields.append(("icon", icon.map(JSONValue.string) ?? .null)) }
    if let theme = patch.theme {
      guard let theme else {
        fields.append(("theme", .null))
        return JSONObject(fields)
      }
      guard let data = try? JSONEncoder().encode(theme), let value = try? JSONValue.parse(data) else { return nil }
      fields.append(("theme", value))
    }
    return JSONObject(fields)
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
      result[id] = ProfileStats(historyPages: entry.int("historyPages") ?? 0, bookmarks: 0)
    }
    return result
  }

}

@MainActor
enum SettingsDirectWrites {
  static var store: Store? {
    guard !SolaraCoreHost.safeMode else { return nil }
    return SettingsWrites.directStore
  }

  @discardableResult
  static func write(_ store: Store, _ command: Command) -> Commit? {
    do {
      return try store.dispatch(command, origin: .native)
    } catch {
      NSLog("[settings] %@ failed: %@", command.name, String(describing: error))
      return nil
    }
  }

  static var opening: SettingsOpening? {
    guard let store else { return nil }
    return SettingsOpening(state: { store.state }, run: { write(store, $0) }, focus: { ShellScripting.showWindow($0) })
  }
}

#if DEBUG
@MainActor
enum SettingsWritesDev {
  static func drive(_ action: String, _ argument: String?) async -> String {
    let env = ProcessInfo.processInfo.environment
    guard SolaraCoreHost.testBuild, env["SOLARA_BACKGROUND"] == "1", env["SOLARA_DATA_DIR"]?.isEmpty == false, let model = NativeSettingsHandle.model else {
      return #"{"error":"test instances only"}"#
    }
    let source = StoreSettingsSource(model: model)
    let adapter = ProfilesAdapter(store: source)
    let args = argument.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
    let viaJS = args.bool("viaJS") ?? false
    let id = args.string("id") ?? ""
    var out: [String: Any] = ["direct": SettingsDirectWrites.store != nil && !viaJS]
    switch action {
    case "create":
      guard !viaJS else { return #"{"error":"Create Profile is native only"}"# }
      let color = ProfileColorValue(rawValue: args.string("color") ?? "") ?? .blue
      out["id"] = adapter.createProfile(name: args.string("name") ?? "", color: color, shareWith: args.string("shareWith"))
    case "update":
      guard !viaJS else { return #"{"error":"Update Profile is native only"}"# }
      let icon: String?? = args.keys.contains("icon") ? .some(args.string("icon")) : .none
      let patch = ProfilePatch(name: args.string("name"), color: args.string("color").flatMap(ProfileColorValue.init(rawValue:)), icon: icon)
      adapter.updateProfile(id, patch)
    case "delete":
      guard !viaJS else { return #"{"error":"Delete Profile is native only"}"# }
      guard let context = NativeSettingsWindow.existingContext, context.navigation.pane == .profiles,
            let profiles = context.panes[.profiles] as? ProfilesPaneModel else {
        return #"{"error":"Open Profiles in Settings first"}"#
      }
      out["deleted"] = await profiles.devDeleteProfile(id, confirmed: args.bool("confirmed") == true, navigation: context.navigation)
      out["settingsProfile"] = context.navigation.profileId ?? NSNull()
    case "reorder":
      guard !viaJS else { return #"{"error":"Reorder Profiles is native only"}"# }
      adapter.reorderProfiles(args.strings("ids"))
    case "arcThemeChoices":
      guard let context = NativeSettingsWindow.existingContext, context.navigation.pane == .profiles,
            context.navigation.profileId == id, let profiles = context.panes[.profiles] as? ProfilesPaneModel else {
        return #"{"error":"Open a profile in Settings first"}"#
      }
      let choices = profiles.devArcThemeChoices(profile: id, choose: args.string("choose"))
      out["choices"] = choices.map { $0.map { ["id": $0.id, "name": $0.name, "emoji": $0.emoji ?? NSNull()] as [String: Any] } } as Any? ?? NSNull()
      if let theme = NativeStoreHandle.store?.state.profiles[id]?.theme {
        out["theme"] = try? JSONSerialization.jsonObject(with: Data(theme.text().utf8))
      }
    case "layout":
      guard !viaJS else { return #"{"error":"Tab layout is native only"}"# }
      out["direct"] = !NativeStoreHandle.frozen && NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store != nil
      source.chooseTabLayout(args.string("layout") ?? "sidebar")
    case "openURLs":
      guard !viaJS else { return #"{"error":"Open URLs is native only"}"# }
      out["opened"] = SettingsDirectWrites.opening?.openURLs(args.strings("urls")) ?? false
    case "openInNewTab":
      guard !viaJS else { return #"{"error":"Open in New Tab is native only"}"# }
      out["opened"] = SettingsDirectWrites.opening?.openInNewTab(args.string("url") ?? "") ?? false
    case "openInBrowser":
      guard !viaJS else { return #"{"error":"Open in Browser is native only"}"# }
      out["opened"] = SettingsDirectWrites.opening?.openInBrowser(args.string("url") ?? "") ?? false
    case "openInternalPage":
      guard !viaJS else { return #"{"error":"Open Internal Page is native only"}"# }
      let page = args.string("page") ?? ""
      out["opened"] = SettingsDirectWrites.opening?.openInternalPage(page, scheme: appScheme(), isAppScheme: isAppScheme) ?? false
    case "openImport":
      guard !viaJS else { return #"{"error":"Open Import is native only"}"# }
      GeneralAdapter().openImport()
      out["direct"] = true
      out["importOpen"] = NativeImportWindow.hosting?.viewIfLoaded?.window != nil
    case "installCli", "cliStatus":
      guard !viaJS else { return #"{"error":"CLI control is native only"}"# }
      if action == "installCli" { NativeCliControl.shared.install(reason: "settings") }
      out["direct"] = true
      out["cli"] = NativeCliControl.shared.topic
    case "manageExtensions":
      guard !viaJS else { return #"{"error":"Manage Extensions is native only"}"# }
      out["direct"] = !NativeStoreHandle.frozen && NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store != nil
      SearchEngineAdapter(model: model).manageExtensions(profile: args.string("engine") ?? "")
      let deadline = Date(timeIntervalSinceNow: 3)
      while NativeSettingsWindow.existingContext?.navigation.pane != .extensions, Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      let place = NativeSettingsWindow.existingContext?.navigation
      out["settingsPane"] = place?.pane.rawValue ?? NSNull()
      out["settingsProfile"] = place?.profileId ?? NSNull()
    case "clear":
      let kinds = args.strings("kinds").compactMap(BrowsingDataKind.init(rawValue:))
      if viaJS {
        _ = await SettingsAdapters.js("profiles.clearBrowsingData", args.string("engine") ?? "", kinds.map(\.rawValue), NSNull())
      } else {
        await adapter.clearBrowsingData(engineProfile: args.string("engine") ?? "", kinds: kinds, since: nil)
      }
      out["cleared"] = true
    default:
      break
    }
    if let state = NativeStoreHandle.store?.state {
      out["profileOrder"] = state.profileOrder
      out["profiles"] = state.profileOrder.compactMap { pid in
        state.profiles[pid].map { ["id": pid, "name": $0.name, "color": $0.color, "icon": $0.icon ?? NSNull(), "dataId": $0.dataId ?? NSNull()] as [String: Any] }
      }
      out["tabLayout"] = state.settings.string("tabLayout") ?? NSNull()
      out["windows"] = state.windows.values.map { window -> [String: Any] in
        ["id": window.id, "tabLayout": window.tabLayout ?? NSNull(), "incognito": window.incognito, "profileId": window.profileId]
      }
      out["focusedWindow"] = state.ui.focusedWindowId ?? NSNull()
      out["tabs"] = state.windowOrder.map { window in
        state.viewTabIds(window).compactMap { id -> [String: Any]? in
          guard let tab = state.tabs[id] else { return nil }
          return ["id": id, "window": window, "profileId": tab.profileId, "url": tab.navigation?.url ?? tab.url, "active": state.activeTabId(window) == id]
        }
      }
    }
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}
#endif
