import SolaraModel

public struct SessionDocument: Sendable, Equatable {
  public var profiles: JSMap<JSONValue>
  public var profileOrder: [String]
  public var orphanedProfileData: [String]
  public var settings: JSONValue
  public var windows: JSMap<JSONValue>
  public var windowOrder: [String]
  public var focusedWindowId: String?
  public var lastProfileId: String?
  public var launchTab: JSONValue
  public var launchBackdrop: JSONValue
  public var linkProfile: JSONValue
  public var tabs: JSMap<JSONValue>
  public var groups: JSMap<JSONValue>
  public var splits: JSMap<JSONValue>
  public var closedTabs: [JSONValue]
  public var closedWindows: [JSONValue]
  public var parkedPins: JSMap<JSONValue>
  public var pinChoices: JSMap<JSONValue>
  public var pinSync: JSMap<JSONValue>
  public var closedGroups: [JSONValue]
  public var deletedGroups: [JSONValue]
  public var cleanedTabs: [JSONValue]

  public func json(marker: JSONValue? = nil) -> JSONValue {
    var o: JSONObject = [
      "version": 2, "profiles": .object(profiles), "profileOrder": JSONValue(profileOrder), "orphanedProfileData": JSONValue(orphanedProfileData),
      "settings": settings, "windows": .array(windows.values), "windowOrder": JSONValue(windowOrder), "focusedWindowId": JSONValue(focusedWindowId),
      "lastProfileId": JSONValue(lastProfileId), "launchTab": launchTab, "launchBackdrop": launchBackdrop, "linkProfile": linkProfile,
      "tabs": .array(tabs.values), "groups": .array(groups.values), "splits": .array(splits.values), "closedTabs": .array(closedTabs),
      "closedWindows": .array(closedWindows), "parkedPins": .object(parkedPins), "pinChoices": .object(pinChoices), "pinSync": .object(pinSync),
      "closedGroups": .array(closedGroups), "deletedGroups": .array(deletedGroups), "cleanedTabs": .array(cleanedTabs),
    ]
    if let marker { o["nativeExport"] = marker }
    return .object(o)
  }
}

func publicProfile(_ profileId: String) -> Bool { !Ids.isIncognitoProfile(profileId) }

public func persistedTabJSON(_ t: Tab) -> JSONValue {
  var tab = t
  let wake = t.wakeAdoptId
  let held = truthy(t.pageIn)
  tab.navigation = nil
  tab.adoptId = nil
  tab.wakeAdoptId = nil
  tab.pageIn = nil
  if held { tab.unloaded = true }
  var json = tab.json
  json.removeValue(forKey: "navigation")
  if let wake, wake.hasPrefix("restore:"), publicProfile(tab.profileId) { json["wakeAdoptId"] = .string(wake) }
  return .object(json)
}

extension Session {
  func launchTab(_ s: BrowserState, _ windowId: String?) -> JSONValue {
    guard let windowId, let w = s.windows[windowId], !w.incognito, !w.isSmall, s.settings["restoreSession"] != .bool(false) || w.keptOnClose == true else { return .null }
    guard let t = s.tabs[w.activeTabIds[w.profileId] ?? ""], t.windowId == w.id, t.profileId == w.profileId else { return .null }
    let lower = t.url.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return .null }
    if truthy(t.wakeAdoptId) || tabEngine(s, t.id) != "chromium" { return .null }
    return ["id": .string(t.id), "url": .string(t.url), "profile": .string(s.engineProfile(t.profileId))]
  }

  public func sessionDocument(_ s: BrowserState) -> SessionDocument {
    var windows = JSMap<JSONValue>()
    for w in s.windows.values where !w.incognito && !w.isSmall { windows[w.id] = .object(w.persistedJSON) }
    let focusedWindowId = s.ui.focusOrder.first { windows[$0] != nil }
    var tabs = JSMap<JSONValue>()
    for t in s.tabs.values where windows[t.windowId] != nil && !isPeekTab(s, t.id) { tabs[t.id] = persistedTabJSON(t) }
    func publicTable<V>(_ table: Table<V>, _ encode: (V) -> JSONValue) -> JSMap<JSONValue> {
      var out = JSMap<JSONValue>()
      for (profileId, value) in table where publicProfile(profileId) { out[profileId] = encode(value) }
      return out
    }
    let early = s.caches.earlyLaunchTab ?? config.earlyLaunchTab
    return SessionDocument(
      profiles: s.profiles.map.mapValues(\.jsonValue), profileOrder: s.profileOrder, orphanedProfileData: s.orphanedProfileData,
      settings: s.settings.json, windows: windows, windowOrder: s.windowOrder.filter { windows[$0] != nil }, focusedWindowId: focusedWindowId,
      lastProfileId: s.ui.lastProfileId, launchTab: early ? launchTab(s, focusedWindowId) : .null,
      launchBackdrop: early ? LaunchBackdropProvider.document(s, windowId: focusedWindowId) : .null,
      linkProfile: early ? .string(s.engineProfile(lastActiveProfile(s))) : .null, tabs: tabs,
      groups: s.groups.map.filter { _, g in windows[g.windowId] != nil }.mapValues(\.jsonValue),
      splits: s.splits.map.filter { _, v in windows[v.windowId] != nil }.mapValues(\.jsonValue),
      closedTabs: s.closedTabs.filter { publicProfile($0.tab.profileId) }.map(\.jsonValue),
      closedWindows: s.closedWindows.filter { $0.tabs.allSatisfy { publicProfile($0.snapshot.profileId) } }.map(\.jsonValue),
      parkedPins: publicTable(s.parkedPins, \.jsonValue), pinChoices: publicTable(s.pinChoices) { .object($0.mapValues(JSONValue.number)) },
      pinSync: publicTable(s.pinSync) { .object($0) },
      closedGroups: s.closedGroups.filter { $0.tabs.allSatisfy { publicProfile($0.profileId) } }.map(\.jsonValue),
      deletedGroups: s.deletedGroups.filter { $0.tabs.allSatisfy { publicProfile($0.profileId) } }.map(\.jsonValue),
      cleanedTabs: s.cleanedTabs.filter { publicProfile($0.tab.profileId) }.map(\.jsonValue))
  }
}

extension Store {
  public func sessionDocument(of state: BrowserState? = nil) -> SessionDocument {
    let s = state ?? self.state
    let session = Session(state: s, memory: committedMemory, env: env, config: config, now: 0)
    return session.sessionDocument(s)
  }
}
