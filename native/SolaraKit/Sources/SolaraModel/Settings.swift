public struct Settings: Sendable, Hashable {
  public var values: JSONObject
  public internal(set) var fileLayer: SettingsFileLayer?

  public init(values: JSONObject, fileLayer: SettingsFileLayer? = nil) {
    var values = values
    values.removeValue(forKey: SettingsFileLayer.replicaKey)
    self.values = values
    self.fileLayer = fileLayer
  }

  public static let defaultProfileID = "default"
  static let toolbarStaysOnScroll = "toolbarStaysOnScroll"
  static let selectionSearchOff = "selectionSearchOff"
  public static let bookkeepingKeys: Set<String> = ["chosen", "inferred"]

  public static let defaults = Settings(values: [
    "warnBeforeQuitting": true,
    "warnBeforeClosingWindow": true,
    "restoreSession": true,
    "loadAllProfilesAtLaunch": false,
    "searchEngine": "google",
    "customSearchUrl": "",
    "customSearchEngines": [],
    "extensionSearchEngines": [],
    "searchSuggestions": true,
    "showSelectionSearch": false,
    "commandBarPreference": "website",
    "tabLayout": "sidebar",
    "hideToolbarWhileScrolling": false,
    "newTabPosition": "bottom",
    "newTabButtonPosition": "bottom",
    "newTabOpens": "page",
    "warnBeforeClosingLastTab": true,
    "undoReopensClosedTab": false,
    "showTabNumberHints": true,
    "warnBeforeMovingTabsToProfile": true,
    "shareTabsAcrossWindows": false,
    "tabReorderHaptics": true,
    "extendWebsiteColor": true,
    "cmdClickCreatesTabGroup": true,
    "optShiftClickOpensInGroup": true,
    "peekModifier": "shift",
    "pinnedLinkTarget": "peek",
    "splitLinkModifier": "altShift",
    "autoGroupMeetingTabs": true,
    "cleanUpInactiveTabsAfterHours": nil,
    "mutedSites": [],
    "neverTranslateSites": [:],
    "developerMode": [:],
    "autoPictureInPicture": true,
    "videoUpscaling": true,
    "sidebarMediaControls": true,
    "hoverCardMemoryUsage": true,
    "sidebarWidth": 190,
    "sidebarIconsOnly": false,
    "showSidebarButton": true,
    "showClearButton": true,
    "balancedTopApps": false,
    "pinnedTabIconRing": false,
    "selectedTabGlow": "full",
    "pageScrollBars": "system",
    "fadeUnloadedTabs": false,
    "showUnreadBadges": true,
    "sleepInactiveTabs": true,
    "sleepTabsAfterMinutes": 30,
    "keepAwakeSites": [],
    "keepAwakeAdoptedProfiles": [],
    "warnBeforeClosingTabGroup": true,
    "batterySaverWhen": "lowBattery",
    "extensionSidePanelWidth": 360,
    "showFullUrl": false,
    "allowJavaScriptFromAppleEvents": false,
    "cliControl": false,
    "bookmarksBar": "never",
    "hideBookmarksBarImport": false,
    "appearance": "auto",
    "addressBar": "toolbar",
    "commandBarPlacement": "field",
    "spacesFollowAppearance": true,
    "defaultProfileId": .string(defaultProfileID),
    "shortcuts": [:],
    "shortcutPrecedence": [:],
    "openLinksInLittleSolara": true,
    "littleSolaraKeepsNewTabLinks": false,
    "littleSolaraSize": [900, 640],
    "pageEngine": "chromium",
    "websiteEngines": [:],
    "migrations": [.string(toolbarStaysOnScroll), .string(selectionSearchOff)],
    "protectedVideoInWebKit": true,
  ])

  public subscript(key: String) -> JSONValue? {
    get { values[key] }
    set { values[key] = newValue }
  }

  public func string(_ key: String) -> String? { values[key]?.string }
  public func bool(_ key: String) -> Bool { values[key]?.truthy ?? false }
  public func number(_ key: String) -> Double? { values[key]?.number }
  public func strings(_ key: String) -> [String]? { values[key]?.array?.compactMap(\.string) }

  public var chosen: [String]? { strings("chosen") }
  public var inferred: [String]? { strings("inferred") }
  public var migrations: [String]? { strings("migrations") }

  public var loadAllProfilesAtLaunch: Bool { values["loadAllProfilesAtLaunch"]?.bool ?? false }
  public var restoreSession: Bool { values["restoreSession"]?.bool ?? true }
  public var defaultProfileId: String { string("defaultProfileId") ?? Self.defaultProfileID }
  public var peekModifier: String {
    let value = string("peekModifier") ?? ""
    return ["alt", "shift", "off"].contains(value) ? value : "shift"
  }
  public var splitLinkModifier: String {
    string("splitLinkModifier") == "alt" && peekModifier != "alt" ? "alt" : "altShift"
  }

  public var json: JSONValue { .object(values) }

  public func withLinkKeysApart(_ patch: JSONObject) -> JSONObject {
    var patch = patch
    if patch["peekModifier"]?.string == "alt", !patch.contains("splitLinkModifier"), string("splitLinkModifier") == "alt" {
      patch["splitLinkModifier"] = "altShift"
      return patch
    }
    if patch["splitLinkModifier"]?.string == "alt", !patch.contains("peekModifier"), peekModifier == "alt" {
      patch["peekModifier"] = "shift"
      return patch
    }
    return patch
  }

  public func choosing(_ patch: JSONObject) -> Settings {
    let chosen = self.chosen ?? []
    let added = patch.keys.filter { $0 != "chosen" && $0 != "inferred" && !chosen.contains($0) }
    let (routed, layer) = routedThroughFile(patch)
    var next = values
    for (key, value) in routed { next[key] = value }
    if !added.isEmpty { next["chosen"] = JSONValue(chosen + added) }
    if let inferred = self.inferred {
      next["inferred"] = JSONValue(inferred.filter { !patch.contains($0) })
    }
    return Settings(values: next, fileLayer: layer)
  }

  public func merging(_ patch: JSONObject) -> Settings {
    let (routed, layer) = routedThroughFile(patch)
    var next = values
    for (key, value) in routed { next[key] = value }
    return Settings(values: next, fileLayer: layer)
  }

  public func updated(_ patch: JSONObject, fromSync: Bool) -> Settings {
    fromSync ? merging(patch) : choosing(withLinkKeysApart(patch))
  }

  public static func migrateSaved(_ saved: JSONObject?) -> JSONObject? {
    guard let saved else { return nil }
    return withNewTabButtonPosition(selectionSearchOff(keepToolbarOnScroll(withoutBatterySaver(saved))))
  }

  public static func hydrated(from saved: JSONValue?) -> Settings {
    let migrated = migrateSaved(saved?.object)
    let legacy: [String]? = migrated.flatMap { ($0["chosen"]?.truthy ?? false) ? nil : $0.keys }
    var values = defaults.values
    for (key, value) in migrated ?? [:] { values[key] = value }
    let present = { (value: JSONValue?) in value.flatMap { $0.isNull ? nil : $0 } }
    values["chosen"] = legacy.map(JSONValue.init) ?? present(migrated?["chosen"]) ?? []
    values["inferred"] = legacy.map(JSONValue.init) ?? present(migrated?["inferred"]) ?? []
    return Settings(values: values)
  }

  public func repairingDefaultProfile(profileOrder: [String]) -> Settings {
    guard !profileOrder.contains(defaultProfileId), let first = profileOrder.first else { return self }
    var next = self
    next.values["defaultProfileId"] = .string(first)
    return next
  }

  static func keepToolbarOnScroll(_ saved: JSONObject) -> JSONObject {
    let migrations = saved["migrations"]?.array?.compactMap(\.string)
    if migrations?.contains(toolbarStaysOnScroll) == true { return saved }
    var next = saved
    next["hideToolbarWhileScrolling"] = false
    next["migrations"] = .array((saved["migrations"]?.array ?? []) + [.string(toolbarStaysOnScroll)])
    return next
  }

  static func selectionSearchOff(_ saved: JSONObject) -> JSONObject {
    let migrations = saved["migrations"]?.array?.compactMap(\.string)
    if migrations?.contains(selectionSearchOff) == true { return saved }
    let chosen = saved["chosen"]?.array?.compactMap(\.string)
    let inferred = saved["inferred"]?.array?.compactMap(\.string)
    let picked = chosen.map { $0.contains("showSelectionSearch") && inferred?.contains("showSelectionSearch") != true } ?? true
    var next = saved
    if !picked {
      next["showSelectionSearch"] = false
      next["chosen"] = JSONValue((chosen ?? []).filter { $0 != "showSelectionSearch" })
      if let inferred { next["inferred"] = JSONValue(inferred.filter { $0 != "showSelectionSearch" }) }
    }
    next["migrations"] = .array((saved["migrations"]?.array ?? []) + [.string(selectionSearchOff)])
    return next
  }

  static func withNewTabButtonPosition(_ saved: JSONObject) -> JSONObject {
    if saved.contains("newTabButtonPosition") || saved["newTabPosition"]?.string != "top" { return saved }
    func alongside(_ keys: [String]) -> [String] {
      keys.contains("newTabPosition") ? uniqued(keys + ["newTabButtonPosition"]) : keys
    }
    var next = saved
    next["newTabButtonPosition"] = "top"
    if let chosen = saved["chosen"]?.array?.compactMap(\.string) { next["chosen"] = JSONValue(alongside(chosen)) }
    if let inferred = saved["inferred"]?.array?.compactMap(\.string) { next["inferred"] = JSONValue(alongside(inferred)) }
    return next
  }

  static func withoutBatterySaver(_ saved: JSONObject) -> JSONObject {
    guard let batterySaver = saved["batterySaver"] else { return saved }
    var rest = saved
    rest.removeValue(forKey: "batterySaver")
    let chosen = rest["chosen"]?.array?.compactMap(\.string)
    let inferred = rest["inferred"]?.array?.compactMap(\.string)
    let explicit = batterySaver == .bool(false)
      || (batterySaver == .bool(true) && chosen?.contains("batterySaver") == true && inferred?.contains("batterySaver") != true)
    let without = { (keys: [String]) in keys.filter { $0 != "batterySaver" } }
    if let chosen {
      rest["chosen"] = JSONValue(explicit ? uniqued(without(chosen) + ["batterySaverWhen"]) : without(chosen))
    }
    if let inferred { rest["inferred"] = JSONValue(without(inferred)) }
    if explicit, rest["batterySaverWhen"] == nil {
      rest["batterySaverWhen"] = batterySaver == .bool(true) ? "unplugged" : "never"
    }
    return rest
  }
}

public func uniqued(_ keys: [String]) -> [String] {
  var seen = Set<String>()
  return keys.filter { seen.insert($0).inserted }
}
