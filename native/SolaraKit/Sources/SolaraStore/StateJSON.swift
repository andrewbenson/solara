import SolaraModel

extension BrowserState {
  static func table<V: JSONConvertible>(_ value: JSONValue?) throws -> Table<V> {
    var map = JSMap<V>()
    for (key, item) in value?.object ?? [:] { map[key] = try V(value: item) }
    return Table(map)
  }

  static func list<V: JSONConvertible>(_ value: JSONValue?) throws -> [V] {
    try (value?.array ?? []).map { try V(value: $0) }
  }

  public init(stateJSON json: JSONObject) throws {
    self.init()
    for key in Self.sliceKeys { try applySlice(key, json[key]) }
    try applySlice("caches", json["caches"])
  }

  public static let sliceKeys = [
    "profiles", "profileOrder", "orphanedProfileData", "windows", "windowOrder", "tabs", "groups", "splits", "peeks", "closedTabs", "closedWindows",
    "closedGroups", "deletedGroups", "cleanedTabs", "privateCleanedTabs", "privateSiteMutes", "parkedPins", "pinChoices", "pinSync", "downloads",
    "settings", "ui", "live", "find", "selection", "selectionAnchors", "windowUi",
  ]

  public mutating func applySlice(_ key: String, _ value: JSONValue?) throws {
    switch key {
    case "profiles": profiles = try Self.table(value)
    case "profileOrder": profileOrder = value?.array?.compactMap(\.string) ?? []
    case "orphanedProfileData": orphanedProfileData = value?.array?.compactMap(\.string) ?? []
    case "windows": windows = try Self.table(value)
    case "windowOrder": windowOrder = value?.array?.compactMap(\.string) ?? []
    case "tabs": tabs = try Self.table(value)
    case "live":
      var live: [String: PageLiveFacts] = [:]
      for (id, value) in value?.object ?? [:] { live[id] = try PageLiveFacts(value: value) }
      self.live = live
    case "groups": groups = try Self.table(value)
    case "splits": splits = try Self.table(value)
    case "peeks": peeks = try Self.table(value)
    case "closedTabs": closedTabs = try Self.list(value)
    case "closedWindows": closedWindows = try Self.list(value)
    case "closedGroups": closedGroups = try Self.list(value)
    case "deletedGroups": deletedGroups = try Self.list(value)
    case "cleanedTabs": cleanedTabs = try Self.list(value)
    case "privateCleanedTabs":
      var privateCleaned = JSMap<[ClosedTab]>()
      for (k, v) in value?.object ?? [:] { privateCleaned[k] = try Self.list(v) }
      privateCleanedTabs = privateCleaned
    case "privateSiteMutes":
      var mutes = JSMap<JSMap<Bool>>()
      for (k, v) in value?.object ?? [:] {
        var mine = JSMap<Bool>()
        for (host, muted) in v.object ?? [:] { if let b = muted.bool { mine[host] = b } }
        mutes[k] = mine
      }
      privateSiteMutes = mutes
    case "parkedPins": parkedPins = try Self.table(value)
    case "pinChoices":
      var choices = JSMap<JSMap<Double>>()
      for (k, v) in value?.object ?? [:] {
        var mine = JSMap<Double>()
        for (key, n) in v.object ?? [:] { if let d = n.number { mine[key] = d } }
        choices[k] = mine
      }
      pinChoices = Table(choices)
    case "pinSync":
      var sync = JSMap<JSMap<JSONValue>>()
      for (k, v) in value?.object ?? [:] { sync[k] = v.object ?? [:] }
      pinSync = Table(sync)
    case "downloads": downloads = (value?.array ?? []).compactMap { $0.object.map(Download.init) }
    case "settings": settings = Settings(values: value?.object ?? Settings.defaults.values)
    case "find":
      var find = JSMap<FindState>()
      for (id, value) in value?.object ?? [:] { find[id] = try FindState(value: value) }
      self.find = find
    case "selection":
      var selection = JSMap<TabSelection>()
      for (id, value) in value?.object ?? [:] { selection[id] = TabSelection(value.array?.compactMap(\.string) ?? []) }
      self.selection = selection
    case "selectionAnchors":
      var anchors = JSMap<SelectionAnchor>()
      for (id, value) in value?.object ?? [:] { if let tabId = value.string { anchors[id] = SelectionAnchor(tabId) } }
      selectionAnchors = anchors
    case "windowUi":
      var windowUi = JSMap<WindowUi>()
      for (id, value) in value?.object ?? [:] { windowUi[id] = try WindowUi(value: value) }
      self.windowUi = windowUi
    case "ui":
      let ui = value?.object ?? [:]
      self.ui = FocusState(
        focusedWindowId: ui["focusedWindowId"]?.string, focusOrder: ui["focusOrder"]?.array?.compactMap(\.string) ?? [],
        lastProfileId: ui["lastProfileId"]?.string, appDark: ui["appDark"]?.bool ?? true)
    case "caches":
      let caches = value?.object ?? [:]
      var hints = JSMap<[HistoryHint]>()
      for (profileId, list) in caches["historyHints"]?.object ?? [:] {
        hints[profileId] = (list.array ?? []).map { HistoryHint(url: $0["url"]?.string ?? "", title: $0["title"]?.string ?? "", favicon: $0["favicon"]?.string) }
      }
      self.caches.historyHints = hints
      self.caches.playingAudio = Set(caches["playingAudio"]?.array?.compactMap(\.string) ?? [])
      self.caches.launchBackdrop = caches["launchBackdrop"] ?? .null
      self.caches.earlyLaunchTab = caches["earlyLaunchTab"]?.bool
    default:
      throw CommandError("unknown slice \(key)")
    }
  }

  public var stateJSON: JSONObject {
    func table<V: JSONConvertible>(_ t: Table<V>) -> JSONValue { .object(t.map.mapValues(\.jsonValue)) }
    return [
      "profiles": table(profiles), "profileOrder": JSONValue(profileOrder), "orphanedProfileData": JSONValue(orphanedProfileData),
      "windows": table(windows), "windowOrder": JSONValue(windowOrder), "tabs": table(tabs), "groups": table(groups), "splits": table(splits),
      "peeks": table(peeks), "closedTabs": .array(closedTabs.map(\.jsonValue)), "closedWindows": .array(closedWindows.map(\.jsonValue)),
      "closedGroups": .array(closedGroups.map(\.jsonValue)), "deletedGroups": .array(deletedGroups.map(\.jsonValue)),
      "cleanedTabs": .array(cleanedTabs.map(\.jsonValue)),
      "privateCleanedTabs": .object(privateCleanedTabs.mapValues { .array($0.map(\.jsonValue)) }),
      "privateSiteMutes": .object(privateSiteMutes.mapValues { .object($0.mapValues(JSONValue.bool)) }), "parkedPins": table(parkedPins),
      "pinChoices": .object(pinChoices.map.mapValues { .object($0.mapValues(JSONValue.number)) }), "pinSync": .object(pinSync.map.mapValues { .object($0) }),
      "downloads": .array(downloads.map { .object($0.json) }), "settings": settings.json,
      "live": .object(JSONObject(live.keys.sorted().map { ($0, live[$0]!.jsonValue) })),
      "find": .object(find.mapValues(\.jsonValue)),
      "selection": .object(selection.mapValues { JSONValue($0.ids) }), "selectionAnchors": .object(selectionAnchors.mapValues { .string($0.tabId) }),
      "windowUi": .object(windowUi.mapValues(\.jsonValue)),
      "ui": ["appDark": .bool(ui.appDark), "focusedWindowId": JSONValue(ui.focusedWindowId), "focusOrder": JSONValue(ui.focusOrder), "lastProfileId": JSONValue(ui.lastProfileId)],
    ]
  }
}

extension StoreMemory {
  public init(replayJSON json: JSONObject) {
    self.init(ids: IdSource(launch: json["launch"]?.string ?? "x", counter: json["counter"]?.int ?? 0))
    navSeq = json["navSeq"]?.int ?? 0
    lastPinChoice = json["lastPinChoice"]?.number ?? 0
    var deletions = JSMap<Double>()
    for (k, v) in json["remotePinDeletions"]?.object ?? [:] { deletions[k] = v.number ?? 0 }
    remotePinDeletions = deletions
    endedPrivateDownloads = Set(json["endedPrivateDownloads"]?.array?.compactMap(\.string) ?? [])
    closingWindows = Set(json["closingWindows"]?.array?.compactMap(\.string) ?? [])
    lastTabKeepsWindow = json["lastTabKeepsWindow"]?.truthy ?? false
    fromSyncDepth = json["fromSyncDepth"]?.int ?? 0
    chromeTabs = ChromeTabsMemory(json: json["chromeTabs"])
  }
}
