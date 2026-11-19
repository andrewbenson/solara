import Foundation
import SolaraModel

public enum SettingsWrites {
  @MainActor public static var directStore: Store? {
    guard !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store, !store.config.safeMode else { return nil }
    return store
  }

  public static func createProfile(name: String, color: String, shareWith: String?) -> Command {
    Command("createProfile", [["name": .string(name), "color": .string(color), "shareWith": shareWith.map(JSONValue.string) ?? .null]])
  }

  public static func updateProfile(_ id: String, _ patch: JSONObject) -> Command {
    Command("updateProfile", [.string(id), .object(patch)])
  }

  public static func deleteProfile(_ id: String) -> Command {
    Command("deleteProfile", [.string(id)])
  }

  public static func reorderProfiles(_ ids: [String]) -> Command {
    Command("reorderProfiles", [.array(ids.map(JSONValue.string))])
  }

  public static func chooseTabLayout(_ layout: String, in state: BrowserState) -> [Command] {
    let choose = Command("updateSettings", [["tabLayout": .string(layout)]])
    let current = state.settings.string("tabLayout")
    let toggles = state.windows.values.filter { ($0.tabLayout ?? current) != layout }.map { Command("toggleTabLayout", [.string($0.id)]) }
    return [choose] + toggles + [choose]
  }
}
