import SolaraModel

public enum ProfileThemeEdit {
  public static let presets: Set<String> = ["plum", "blue", "purple", "pink", "red", "orange", "yellow", "green", "neutral"]

  public static func command(profileId: String, fields: JSONObject, state: BrowserState) -> Command? {
    guard state.profiles[profileId] != nil else { return nil }
    if let theme = fields["theme"] {
      if fields.count == 1 { return command(profileId: profileId, kind: "theme", value: theme, state: state) }
      if fields.count == 2, theme == .null, let color = fields["color"] {
        return command(profileId: profileId, kind: "preset", value: color, state: state)
      }
    }
    return SettingsWrites.updateProfile(profileId, fields)
  }

  public static func command(profileId: String, kind: String, value: JSONValue, state: BrowserState) -> Command? {
    guard state.profiles[profileId] != nil else { return nil }
    switch kind {
    case "theme":
      guard value == .null || value.object != nil else { return nil }
      return SettingsWrites.updateProfile(profileId, ["theme": value])
    case "preset":
      guard let color = value.string, presets.contains(color) else { return nil }
      return SettingsWrites.updateProfile(profileId, ["color": .string(color), "theme": .null])
    default: return nil
    }
  }
}
