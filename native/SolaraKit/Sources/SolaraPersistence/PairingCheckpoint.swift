import Foundation
import SolaraModel

public enum PairingCheckpointFailure: Error { case unavailable, changed, mismatched }

public enum PairingProjection {
  public static let settings: Set<String> = [
    "warnBeforeQuitting", "warnBeforeClosingWindow", "searchEngine", "customSearchUrl", "customSearchEngines",
    "searchSuggestions", "showSelectionSearch", "commandBarPreference", "tabLayout", "hideToolbarWhileScrolling",
    "showSidebarButton", "showClearButton", "balancedTopApps", "pinnedTabIconRing", "selectedTabGlow", "pageScrollBars",
    "fadeUnloadedTabs", "showUnreadBadges", "sleepInactiveTabs", "sleepTabsAfterMinutes", "keepAwakeSites", "warnBeforeClosingTabGroup", "newTabPosition", "newTabButtonPosition", "newTabOpens",
    "warnBeforeClosingLastTab", "undoReopensClosedTab", "warnBeforeMovingTabsToProfile", "tabReorderHaptics",
    "extendWebsiteColor", "cmdClickCreatesTabGroup", "optShiftClickOpensInGroup", "peekModifier", "splitLinkModifier", "pinnedLinkTarget",
    "autoGroupMeetingTabs", "cleanUpInactiveTabsAfterHours", "mutedSites", "autoPictureInPicture", "videoUpscaling",
    "sidebarMediaControls", "hoverCardMemoryUsage", "showFullUrl", "bookmarksBar", "appearance", "addressBar", "commandBarPlacement", "shortcuts",
    "shortcutPrecedence",
  ]

  static func value(key: String, desired: JSONValue, settings: JSONObject, profiles: JSONObject, links: JSONValue) throws -> JSONValue {
    if key.hasPrefix("set:") {
      let name = String(key.dropFirst(4))
      guard Self.settings.contains(name), let value = settings[name] else { throw PairingCheckpointFailure.unavailable }
      return ["v": value]
    }
    guard let links = links.object else { throw PairingCheckpointFailure.unavailable }
    let matches = Array(links).filter { _, link in
      guard let sync = link["syncId"]?.string else { return false }
      return key == "prof:\(sync)" || key == "pth:\(sync)" || key == "pth:\(sync):angle" || key == "share:\(sync)"
    }
    guard matches.count == 1, let id = matches.first?.key, let profile = profiles[id], profile.object != nil else { throw PairingCheckpointFailure.unavailable }
    if key.hasPrefix("prof:") {
      guard let name = profile["name"], let color = profile["color"] else { throw PairingCheckpointFailure.unavailable }
      var value: JSONObject = ["n": name, "c": color, "i": profile["icon"] ?? .null]
      if desired.object?["theme"] != nil { value["theme"] = profile["theme"] ?? .null }
      return .object(value)
    }
    if key.hasPrefix("pth:") {
      if key.hasSuffix(":angle") { return ["a": profile["theme"]?["angle"] ?? .null, "d": profile["theme"]?["dark"]?["angle"] ?? .null] }
      return ["theme": profile["theme"] ?? .null]
    }
    if key.hasPrefix("share:") { return ["owner": profile["dataId"] ?? .string(id)] }
    throw PairingCheckpointFailure.unavailable
  }

  static func validateDisposition(key: String, desired: JSONValue, expected: JSONValue, disposition: String, settings: JSONObject, links: JSONValue, settingsOptedOut: Bool) throws {
    if disposition == "applied" {
      guard desired == expected else { throw PairingCheckpointFailure.mismatched }
      return
    }
    if disposition == "opt-out", key.hasPrefix("set:"), settingsOptedOut { return }
    if disposition == "local-choice", key.hasPrefix("set:") {
      guard settings["chosen"]?.array?.contains(.string(String(key.dropFirst(4)))) == true else { throw PairingCheckpointFailure.mismatched }
      return
    }
    if disposition == "opt-out", !key.hasPrefix("set:"), let links = links.object {
      let match = links.values.filter { link in
        guard let sync = link["syncId"]?.string else { return false }
        return key == "prof:\(sync)" || key == "pth:\(sync)" || key == "pth:\(sync):angle" || key == "share:\(sync)"
      }
      guard match.count == 1, match[0]["enabled"] == false || match[0]["retire"] == true else { throw PairingCheckpointFailure.mismatched }
      return
    }
    throw PairingCheckpointFailure.unavailable
  }
}

extension PersistenceWriter {
  public func pairingCheckpoint(key: String, desired: JSONValue, expected: JSONValue, disposition: String, links: JSONValue, settingsOptedOut: Bool = false, timeout: TimeInterval = 5) throws -> JSONValue {
    guard !store.config.safeMode, scope == .everything || key.hasPrefix("set:") else { throw PairingCheckpointFailure.unavailable }
    let captured = store.committedSnapshot
    let memoryProfiles = store.sessionDocument(of: captured.state).profiles
    try PairingProjection.validateDisposition(key: key, desired: desired, expected: expected, disposition: disposition, settings: captured.state.settings.ownValues, links: links, settingsOptedOut: settingsOptedOut)
    guard try PairingProjection.value(key: key, desired: desired, settings: captured.state.settings.ownValues, profiles: memoryProfiles, links: links) == expected else { throw PairingCheckpointFailure.mismatched }
    guard flush(timeout: timeout) == .saved else { throw PairingCheckpointFailure.unavailable }
    let disk = try database.load()
    guard let settings = disk.settings else { throw PairingCheckpointFailure.unavailable }
    let profiles = disk.workspace?.document()["profiles"]?.object ?? [:]
    try PairingProjection.validateDisposition(key: key, desired: desired, expected: expected, disposition: disposition, settings: settings, links: links, settingsOptedOut: settingsOptedOut)
    let saved = try PairingProjection.value(key: key, desired: desired, settings: settings, profiles: profiles, links: links)
    guard saved == expected else { throw PairingCheckpointFailure.mismatched }
    guard store.committedSnapshot.rev == captured.rev else { throw PairingCheckpointFailure.changed }
    return saved
  }
}
