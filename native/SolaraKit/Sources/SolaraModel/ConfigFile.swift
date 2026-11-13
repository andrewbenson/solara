import Foundation

public enum ConfigSettingKind: Sendable, Hashable {
  case bool
  case number(min: Double, max: Double)
  case numberOrNull(min: Double, max: Double)
  case string
  case choice([String])
  case strings
  case object
  case array
  case size

  public var expectation: String {
    switch self {
    case .bool: "true or false"
    case .number(let min, let max): "a number from \(jsNumberText(min)) to \(jsNumberText(max))"
    case .numberOrNull(let min, let max): "a number from \(jsNumberText(min)) to \(jsNumberText(max)), or null"
    case .string: "a string"
    case .choice(let options): "one of " + options.map { "\"\($0)\"" }.joined(separator: ", ")
    case .strings: "a list of strings"
    case .object: "an object"
    case .array: "a list"
    case .size: "a list of two numbers, [width, height]"
    }
  }

  public func accepts(_ value: JSONValue) -> Bool {
    switch self {
    case .bool: return value.bool != nil
    case .number(let min, let max):
      guard let n = value.number, n.isFinite else { return false }
      return n >= min && n <= max
    case .numberOrNull(let min, let max):
      if value.isNull { return true }
      guard let n = value.number, n.isFinite else { return false }
      return n >= min && n <= max
    case .string: return value.string != nil
    case .choice(let options): return value.string.map(options.contains) ?? false
    case .strings: return value.array?.allSatisfy { $0.string != nil } ?? false
    case .object: return value.object != nil
    case .array: return value.array != nil
    case .size:
      guard let items = value.array, items.count == 2 else { return false }
      return items.allSatisfy { ($0.number ?? 0) >= 200 && ($0.number ?? 0) <= 10_000 }
    }
  }
}

public enum ConfigCatalog {
  public static let settings: [(key: String, kind: ConfigSettingKind)] = [
    ("warnBeforeQuitting", .bool),
    ("warnBeforeClosingWindow", .bool),
    ("restoreSession", .bool),
    ("loadAllProfilesAtLaunch", .bool),
    ("searchEngine", .string),
    ("customSearchUrl", .string),
    ("customSearchEngines", .array),
    ("searchSuggestions", .bool),
    ("showSelectionSearch", .bool),
    ("commandBarPreference", .choice(["website", "search"])),
    ("tabLayout", .choice(["sidebar", "top"])),
    ("hideToolbarWhileScrolling", .bool),
    ("newTabPosition", .choice(["top", "bottom", "nextToCurrent"])),
    ("newTabButtonPosition", .choice(["top", "bottom"])),
    ("newTabOpens", .choice(["page", "commandBar"])),
    ("warnBeforeClosingLastTab", .bool),
    ("undoReopensClosedTab", .bool),
    ("showTabNumberHints", .bool),
    ("warnBeforeMovingTabsToProfile", .bool),
    ("shareTabsAcrossWindows", .bool),
    ("tabReorderHaptics", .bool),
    ("extendWebsiteColor", .bool),
    ("cmdClickCreatesTabGroup", .bool),
    ("optShiftClickOpensInGroup", .bool),
    ("peekModifier", .choice(["shift", "alt", "off"])),
    ("pinnedLinkTarget", .choice(["peek", "tab", "littleSolara"])),
    ("splitLinkModifier", .choice(["altShift", "alt"])),
    ("autoGroupMeetingTabs", .bool),
    ("cleanUpInactiveTabsAfterHours", .numberOrNull(min: 1, max: 24 * 365)),
    ("mutedSites", .strings),
    ("neverTranslateSites", .object),
    ("autoPictureInPicture", .bool),
    ("videoUpscaling", .bool),
    ("sidebarMediaControls", .bool),
    ("hoverCardMemoryUsage", .bool),
    ("sidebarWidth", .number(min: 140, max: 600)),
    ("sidebarIconsOnly", .bool),
    ("showSidebarButton", .bool),
    ("showClearButton", .bool),
    ("balancedTopApps", .bool),
    ("pinnedTabIconRing", .bool),
    ("classicPinnedTabs", .bool),
    ("selectedTabGlow", .choice(["full", "soft", "off"])),
    ("pageScrollBars", .choice(["system", "thin"])),
    ("fadeUnloadedTabs", .bool),
    ("showUnreadBadges", .bool),
    ("sleepInactiveTabs", .bool),
    ("sleepTabsAfterMinutes", .number(min: 1, max: 60 * 24 * 7)),
    ("keepAwakeSites", .strings),
    ("warnBeforeClosingTabGroup", .bool),
    ("batterySaverWhen", .choice(["lowBattery", "unplugged", "never"])),
    ("extensionSidePanelWidth", .number(min: 200, max: 1200)),
    ("showFullUrl", .bool),
    ("bookmarksBar", .choice(["always", "newTab", "never"])),
    ("hideBookmarksBarImport", .bool),
    ("appearance", .choice(["auto", "light", "dark"])),
    ("addressBar", .choice(["toolbar", "sidebar"])),
    ("commandBarPlacement", .choice(["field", "centred"])),
    ("spacesFollowAppearance", .bool),
    ("shortcutPrecedence", .object),
    ("openLinksInLittleSolara", .bool),
    ("littleSolaraKeepsNewTabLinks", .bool),
    ("littleSolaraSize", .size),
    ("pageEngine", .choice(["chromium", "webkit"])),
    ("websiteEngines", .object),
    ("protectedVideoInWebKit", .bool),
  ]

  public static let refused: [String: String] = [
    "shortcuts": "set shortcuts under \"keybindings\" instead",
    "allowJavaScriptFromAppleEvents": "lets other apps run scripts in your pages, so it can only be turned on in Settings",
    "cliControl": "lets other programs control the browser, so it can only be turned on in Settings",
    "developerMode": "is kept per profile in Settings",
    "defaultProfileId": "is chosen in Settings › Profiles",
    "extensionSearchEngines": "is set by extensions",
    "keepAwakeAdoptedProfiles": "is kept by Solara itself",
    "chosen": "is kept by Solara itself",
    "inferred": "is kept by Solara itself",
    "migrations": "is kept by Solara itself",
  ]

  public static let kinds: [String: ConfigSettingKind] = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.kind) })
}

public struct ConfigTheme: Sendable, Hashable {
  public let name: String
  public let look: JSONValue

  public init(name: String, look: JSONValue) {
    self.name = name
    self.look = look
  }
}

public struct ConfigContents: Sendable, Hashable {
  public var settings: JSONObject = [:]
  public var keybindings: JSONObject = [:]
  public var theme: ConfigTheme?
  public var profileThemes: [String: ConfigTheme] = [:]

  public init() {}

  public func layer(source: String) -> SettingsFileLayer? {
    let layer = SettingsFileLayer(source: source, values: settings, shortcuts: keybindings)
    return layer.isEmpty ? nil : layer
  }

  public func theme(for profile: Profile) -> ConfigTheme? {
    if let byId = profileThemes[profile.id] { return byId }
    let name = profile.name.lowercased()
    if let byName = profileThemes.first(where: { $0.key.lowercased() == name }) { return byName.value }
    return theme
  }
}

public struct ConfigLoad: Sendable, Equatable {
  public var contents: ConfigContents?
  public var problems: [ConfigProblem]
  public var files: Set<String>

  public var good: Bool { problems.isEmpty }
}

public enum ConfigFile {
  public static let name = "config.json"
  public static let themes = "themes"
  public static let owner = "config"
  static let topLevel: Set<String> = ["$schema", "settings", "keybindings", "theme", "profiles"]

  public static func load(_ read: (String) -> ConfigRead, knownShortcuts: Set<String>? = nil) -> ConfigLoad {
    var problems: [ConfigProblem] = []
    var files: Set<String> = [name]
    let data: Data
    switch read(name) {
    case .absent: return ConfigLoad(contents: nil, problems: [], files: files)
    case .unreadable(let reason): return ConfigLoad(contents: nil, problems: [ConfigProblem(file: name, message: "the file \(reason)")], files: files)
    case .contents(let bytes): data = bytes
    }
    let root: JSONObject
    switch parse(data, file: name) {
    case .failure(let problem): return ConfigLoad(contents: nil, problems: [problem], files: files)
    case .success(let value):
      guard let object = value.object else {
        return ConfigLoad(contents: nil, problems: [ConfigProblem(file: name, line: 1, message: "the file must hold one JSON object, { … }")], files: files)
      }
      root = object
    }
    func problem(_ key: String, _ message: String, anchor: String? = nil) {
      problems.append(ConfigProblem(file: name, key: key, line: ConfigProblem.line(ofKey: key.split(separator: ".").last.map(String.init) ?? key, after: anchor, in: data), message: message))
    }
    var contents = ConfigContents()
    for key in root.keys where !topLevel.contains(key) {
      problem(key, "isn't something config.json sets; use \"settings\", \"keybindings\", \"theme\" or \"profiles\"")
    }
    if let settings = root["settings"] {
      if let object = settings.object {
        for (key, value) in object {
          if let reason = ConfigCatalog.refused[key] {
            problem("settings.\(key)", "can't be set from a file: it \(reason)", anchor: "settings")
          } else if let kind = ConfigCatalog.kinds[key] {
            if kind.accepts(value) { contents.settings[key] = value } else { problem("settings.\(key)", "expected \(kind.expectation)", anchor: "settings") }
          } else {
            problem("settings.\(key)", "isn't a setting Solara knows\(suggestion(key))", anchor: "settings")
          }
        }
      } else {
        problem("settings", "expected an object of setting names and values")
      }
    }
    if let bindings = root["keybindings"] {
      if let object = bindings.object {
        for (id, value) in object {
          if let knownShortcuts, !knownShortcuts.contains(id) {
            problem("keybindings.\(id)", "isn't a shortcut name Solara knows (Settings › Keyboard Shortcuts › Copy Name)", anchor: "keybindings")
            continue
          }
          switch ConfigKeys.parse(value) {
          case .success(let stored): contents.keybindings[id] = .array(stored.map(JSONValue.string))
          case .failure(let failure): problem("keybindings.\(id)", failure.message, anchor: "keybindings")
          }
        }
      } else {
        problem("keybindings", "expected an object of shortcut names and keys, like \"newTab\": \"cmd+t\"")
      }
    }
    var themeCache: [String: ConfigTheme?] = [:]
    func theme(_ value: JSONValue, key: String, anchor: String?) -> ConfigTheme? {
      guard let themeName = value.string, !themeName.isEmpty else {
        problem(key, "expected the name of a theme file in themes/, like \"ocean\" for themes/ocean.json", anchor: anchor)
        return nil
      }
      if let cached = themeCache[themeName] { return cached }
      let loaded = ConfigThemeFile.load(themeName, read: read)
      files.insert(loaded.file)
      problems.append(contentsOf: loaded.problems)
      if loaded.look == nil && loaded.problems.isEmpty {
        problem(key, "there's no \(loaded.file)", anchor: anchor)
      }
      let result = loaded.look.map { ConfigTheme(name: themeName, look: $0) }
      themeCache[themeName] = .some(result)
      return result
    }
    if let value = root["theme"], !value.isNull { contents.theme = theme(value, key: "theme", anchor: nil) }
    if let profiles = root["profiles"] {
      if let object = profiles.object {
        for (profile, entry) in object {
          guard let fields = entry.object else {
            problem("profiles.\(profile)", "expected an object, like { \"theme\": \"ocean\" }", anchor: "profiles")
            continue
          }
          for key in fields.keys where key != "theme" { problem("profiles.\(profile).\(key)", "isn't something a profile entry sets; use \"theme\"", anchor: profile) }
          if let value = fields["theme"], !value.isNull, let loaded = theme(value, key: "profiles.\(profile).theme", anchor: profile) {
            contents.profileThemes[profile] = loaded
          }
        }
      } else {
        problem("profiles", "expected an object of profile names, like { \"Work\": { \"theme\": \"ocean\" } }")
      }
    }
    return ConfigLoad(contents: problems.isEmpty ? contents : nil, problems: problems, files: files)
  }

  static func parse(_ data: Data, file: String) -> Result<JSONValue, ConfigProblem> {
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) {
      return .failure(ConfigProblem(file: file, line: 1, message: "the file is empty; write {} for no settings"))
    }
    do {
      return .success(try JSONValue.parse(data))
    } catch let error as JSONParseError {
      return .failure(ConfigProblem(file: file, line: ConfigProblem.line(ofOffset: error.offset, in: data), message: "isn't valid JSON: \(error.reason)"))
    } catch {
      return .failure(ConfigProblem(file: file, message: "isn't valid JSON: \(error)"))
    }
  }

  static func suggestion(_ key: String) -> String {
    let lower = key.lowercased()
    guard let match = ConfigCatalog.settings.map(\.key).first(where: { $0.lowercased() == lower }) else { return "" }
    return "; did you mean \"\(match)\"?"
  }
}

public enum ConfigThemeFile {
  static let textures = ["grain", "sand", "denim", "tweed"]
  static let modes = ["auto", "light", "dark"]
  static let fields: Set<String> = ["$schema", "mode", "colors", "stops", "angle", "intensity", "grain", "texture", "translucency", "dark"]
  static let darkFields: Set<String> = ["colors", "stops", "angle", "intensity", "grain", "texture", "translucency"]

  public static func file(_ name: String) -> String { "\(ConfigFile.themes)/\(name).json" }

  public static func load(_ name: String, read: (String) -> ConfigRead) -> (file: String, look: JSONValue?, problems: [ConfigProblem]) {
    let path = file(name)
    guard !name.contains("/"), !name.hasPrefix(".") else {
      return (path, nil, [ConfigProblem(file: ConfigFile.name, key: "theme", message: "a theme name can't contain / or start with a dot")])
    }
    let data: Data
    switch read(path) {
    case .absent: return (path, nil, [])
    case .unreadable(let reason): return (path, nil, [ConfigProblem(file: path, message: "the file \(reason)")])
    case .contents(let bytes): data = bytes
    }
    switch ConfigFile.parse(data, file: path) {
    case .failure(let problem): return (path, nil, [problem])
    case .success(let value):
      var problems: [ConfigProblem] = []
      let look = parse(value, file: path, data: data, problems: &problems)
      return (path, problems.isEmpty ? look : nil, problems)
    }
  }

  static func parse(_ value: JSONValue, file: String, data: Data, problems: inout [ConfigProblem]) -> JSONValue? {
    func problem(_ key: String?, _ message: String, anchor: String? = nil) {
      let line = key.flatMap { ConfigProblem.line(ofKey: $0.split(separator: ".").last.map(String.init) ?? $0, after: anchor, in: data) }
      problems.append(ConfigProblem(file: file, key: key, line: line, message: message))
    }
    guard let object = value.object else {
      problem(nil, "a theme file must hold one JSON object, { \"colors\": [\"#7B61FF\"] }")
      return nil
    }
    for key in object.keys where !fields.contains(key) { problem(key, "isn't part of a theme; use mode, colors, angle, intensity, grain, texture, translucency or dark") }
    var out = look(object, prefix: "", anchor: nil, allowed: fields, problem: problem) ?? [:]
    if let mode = object["mode"] {
      if let text = mode.string, modes.contains(text) { out["mode"] = mode } else { problem("mode", "expected \"auto\", \"light\" or \"dark\"") }
    } else {
      out["mode"] = "auto"
    }
    if let dark = object["dark"], !dark.isNull {
      if let fields = dark.object {
        for key in fields.keys where !darkFields.contains(key) { problem("dark.\(key)", "isn't part of a dark look", anchor: "dark") }
        if let look = look(fields, prefix: "dark.", anchor: "dark", allowed: darkFields, problem: problem) { out["dark"] = .object(look) }
      } else {
        problem("dark", "expected an object with the dark look's colors")
      }
    }
    return problems.isEmpty ? .object(out) : nil
  }

  static func look(
    _ object: JSONObject, prefix: String, anchor: String?, allowed: Set<String>, problem: (String?, String, String?) -> Void
  ) -> JSONObject? {
    var stops: [JSONValue] = []
    if let colors = object["colors"] {
      if let items = colors.array, (1...3).contains(items.count) {
        for (index, item) in items.enumerated() {
          guard let color = item.string.flatMap(hexColor) else {
            problem("\(prefix)colors", "colour \(index + 1) should be a hex colour like \"#7B61FF\"", anchor)
            continue
          }
          let place = padPosition(color)
          stops.append(["color": colorJSON(color), "x": .number(place.x), "y": .number(place.y)])
        }
      } else {
        problem("\(prefix)colors", "expected a list of one to three hex colours, like [\"#7B61FF\", \"#FF7AB6\"]", anchor)
      }
    } else if let raw = object["stops"] {
      if let items = raw.array, (1...3).contains(items.count) {
        for (index, item) in items.enumerated() {
          guard let stop = item.object, let color = stopColor(stop["color"]) else {
            problem("\(prefix)stops", "stop \(index + 1) needs a \"color\", a hex string or { r, g, b, a } from 0 to 1", anchor)
            continue
          }
          let place = padPosition(color)
          let x = stop["x"]?.number.map { min(1, max(0, $0)) } ?? place.x
          let y = stop["y"]?.number.map { min(1, max(0, $0)) } ?? place.y
          stops.append(["color": colorJSON(color), "x": .number(x), "y": .number(y)])
        }
      } else {
        problem("\(prefix)stops", "expected a list of one to three stops", anchor)
      }
    } else {
      problem(prefix.isEmpty ? "colors" : "\(prefix)colors", "a theme needs \"colors\", a list of one to three hex colours", anchor)
    }
    var out: JSONObject = ["stops": .array(stops)]
    func unit(_ key: String, _ fallback: Double) {
      guard let value = object[key] else {
        out[key] = .number(fallback)
        return
      }
      if let n = value.number, n.isFinite, n >= 0, n <= 1 { out[key] = .number(n) } else { problem("\(prefix)\(key)", "expected a number from 0 to 1", anchor) }
    }
    unit("intensity", 0.6)
    unit("grain", 0)
    unit("translucency", 1)
    if let texture = object["texture"] {
      if let text = texture.string, textures.contains(text) { out["texture"] = texture } else {
        problem("\(prefix)texture", "expected one of \"grain\", \"sand\", \"denim\", \"tweed\"", anchor)
      }
    } else {
      out["texture"] = "grain"
    }
    if let angle = object["angle"] {
      if let n = angle.number, n.isFinite { out["angle"] = .number((n.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) } else {
        problem("\(prefix)angle", "expected a number of degrees", anchor)
      }
    }
    return out
  }

  struct RGBA {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
  }

  static func colorJSON(_ c: RGBA) -> JSONValue { ["r": .number(c.r), "g": .number(c.g), "b": .number(c.b), "a": .number(c.a)] }

  static func stopColor(_ value: JSONValue?) -> RGBA? {
    if let text = value?.string { return hexColor(text) }
    guard let c = value?.object else { return nil }
    let parts = [c["r"], c["g"], c["b"]].map { $0?.number }
    guard parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 && $0! <= 1 }) else { return nil }
    let a = c["a"]?.number ?? 1
    guard a.isFinite, a >= 0, a <= 1 else { return nil }
    return RGBA(r: parts[0]!, g: parts[1]!, b: parts[2]!, a: a)
  }

  static func hexColor(_ text: String) -> RGBA? {
    var hex = text.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") { hex.removeFirst() }
    if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
    let bytes = hex.count == 8 ? [(value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff] : [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff, 0xff]
    let unit = bytes.map { Double($0) / 255 }
    return RGBA(r: unit[0], g: unit[1], b: unit[2], a: unit[3])
  }

  static func padPosition(_ c: RGBA) -> (x: Double, y: Double) {
    let r = min(1, max(0, c.r)), g = min(1, max(0, c.g)), b = min(1, max(0, c.b))
    let maxV = max(r, g, b), minV = min(r, g, b), l = (maxV + minV) / 2, d = maxV - minV
    guard d != 0 else { return (0.5, 0.5) }
    let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
    let h: Double
    if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    let angle = h / 6 * 2 * .pi
    return (0.5 + 0.5 * s * cos(angle), 0.5 + 0.5 * s * sin(angle))
  }
}
