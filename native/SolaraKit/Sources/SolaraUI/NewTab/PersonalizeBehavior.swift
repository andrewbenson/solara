import Foundation
import SolaraModel
import SolaraStore

public struct PersonalizeAppearance: Decodable, Sendable {
  public var dark: Bool
  public var tokens: [String: String]

  public static func decode(_ json: String) -> Self? {
    try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
  }
}

public enum PersonalizeBehavior {
  public static func project(_ state: BrowserState, windowId: String, open: Bool, appearance: PersonalizeAppearance) -> PersonalizeState? {
    guard let window = state.windows[windowId], !window.incognito else { return nil }
    let profile = state.profiles[window.profileId]
    return PersonalizeState(open: open, dark: appearance.dark, tokens: appearance.tokens,
      color: profile?.color, layout: window.tabLayout ?? state.settings.string("tabLayout") ?? "sidebar",
      canPickColor: profile != nil, profileId: window.profileId)
  }

  public static func command(_ action: String, value: String, presented: PersonalizeState?, state: BrowserState, windowId: String, closing: Set<String> = []) -> Command? {
    guard let presented, presented.open, let window = state.windows[windowId],
      !window.incognito, !closing.contains(windowId), window.profileId == presented.profileId else { return nil }
    switch action {
    case "color":
      guard presented.canPickColor, state.profiles[window.profileId] != nil, ProfileThemeEdit.presets.contains(value) else { return nil }
      return SettingsWrites.updateProfile(window.profileId, ["color": .string(value)])
    case "layout":
      guard ["sidebar", "top"].contains(value), value != (window.tabLayout ?? state.settings.string("tabLayout") ?? "sidebar") else { return nil }
      return Command("toggleTabLayout", [.string(windowId)])
    default: return nil
    }
  }
}
