import SolaraModel

public struct HydrateData: Sendable {
  public var profiles: JSMap<Profile>?
  public var profileOrder: [String]?
  public var orphanedProfileData: [String]?
  public var settings: JSONValue?
  public var windows: JSMap<BrowserWindow>?
  public var windowOrder: [String]?
  public var focusedWindowId: String?
  public var lastProfileId: String?
  public var tabs: [Tab]?
  public var groups: JSMap<TabGroup>?
  public var splits: JSMap<SplitView>?
  public var closedTabs: [ClosedTab]?
  public var closedWindows: [ClosedWindow]?
  public var parkedPins: JSMap<ParkedPins>?
  public var pinChoices: JSMap<JSMap<Double>>?
  public var pinSync: JSMap<JSMap<JSONValue>>?
  public var closedGroups: [ClosedGroup]?
  public var deletedGroups: [ClosedGroup]?
  public var cleanedTabs: [ClosedTab]?
  public var downloads: [Download]?

  public init() {}

  static func records<T: JSONConvertible>(_ value: JSONValue?) throws -> JSMap<T>? {
    guard let value, !value.isNull else { return nil }
    var out = JSMap<T>()
    if let list = value.array {
      for item in list {
        guard let model: T = readable(item, item["id"]?.string) else { continue }
        out[item["id"]?.string ?? ""] = model
      }
    } else {
      for (key, item) in value.object ?? [:] {
        if let model: T = readable(item, key) { out[key] = model }
      }
    }
    return out
  }

  static func list<T: JSONConvertible>(_ value: JSONValue?) throws -> [T]? {
    guard let value, !value.isNull else { return nil }
    let items = value.array ?? (value.object ?? [:]).values
    return items.compactMap { readable($0, $0["id"]?.string) }
  }

  static func readable<T: JSONConvertible>(_ item: JSONValue, _ id: String?) -> T? {
    do {
      return try T(value: item)
    } catch {
      DecodeLog.note("dropped unreadable \(T.self) \(id ?? "without an id"): \(error)")
      return nil
    }
  }

  static func tables<V>(_ value: JSONValue?, _ convert: (JSONValue) -> V?) -> JSMap<JSMap<V>>? {
    guard let object = value?.object else { return nil }
    var out = JSMap<JSMap<V>>()
    for (profileId, inner) in object {
      var mine = JSMap<V>()
      for (key, v) in inner.object ?? [:] { if let converted = convert(v) { mine[key] = converted } }
      out[profileId] = mine
    }
    return out
  }

  public init(json: JSONObject) throws {
    profiles = try Self.records(json["profiles"])
    profileOrder = json["profileOrder"]?.array?.compactMap(\.string)
    orphanedProfileData = json["orphanedProfileData"]?.array?.compactMap(\.string)
    settings = json["settings"].flatMap { $0.isNull ? nil : $0 }
    windows = try Self.records(json["windows"])
    windowOrder = json["windowOrder"]?.array?.compactMap(\.string)
    focusedWindowId = json["focusedWindowId"]?.string
    lastProfileId = json["lastProfileId"]?.string
    tabs = try Self.list(json["tabs"])
    groups = try Self.records(json["groups"])
    splits = try Self.records(json["splits"])
    closedTabs = try Self.list(json["closedTabs"])
    closedWindows = try Self.list(json["closedWindows"])
    parkedPins = try Self.records(json["parkedPins"])
    pinChoices = Self.tables(json["pinChoices"]) { $0.number }
    pinSync = Self.tables(json["pinSync"]) { $0 }
    closedGroups = try Self.list(json["closedGroups"])
    deletedGroups = try Self.list(json["deletedGroups"])
    cleanedTabs = try Self.list(json["cleanedTabs"])
    downloads = (json["downloads"]?.array).map { $0.compactMap { $0.object.map(Download.init) } }
  }
}

extension Session {
  public func hydrated(_ data: HydrateData, base: BrowserState) -> BrowserState {
    let profilesData = data.profiles.flatMap { $0.isEmpty ? nil : $0 } ?? JSMap([(BrowserState.defaultProfile.id, BrowserState.defaultProfile)])
    let profileOrder = (data.profileOrder ?? []).filter { profilesData[$0] != nil } + profilesData.keys.filter { !(data.profileOrder ?? []).contains($0) }
    var settings = Settings.hydrated(from: data.settings)
    if profilesData[settings.defaultProfileId] == nil { settings.values["defaultProfileId"] = .string(profileOrder[0]) }
    for mine in (data.pinChoices ?? JSMap()).values { for n in mine.values where n > memory.lastPinChoice { memory.lastPinChoice = n } }
    let rawWindows = data.windows ?? JSMap()
    func profileOk(_ p: String) -> Bool { profilesData[p] != nil || Ids.isIncognitoProfile(p) }
    var tabs = JSMap<Tab>()
    for t in data.tabs ?? [] {
      if rawWindows[t.windowId] == nil || !profileOk(t.profileId) { continue }
      var kept = t
      kept.adoptId = nil
      kept.pageIn = nil
      let row = t.pinnedAsRow
      let folder = t.tileFolder
      kept.pinnedAsRow = row == true && t.pinned ? row : nil
      kept.tileFolder = folder != nil && t.pinned && row != true ? folder : nil
      kept.navigation = nil
      kept.pinnedUrl = t.pinnedUrl ?? (t.pinned ? (t.url.isEmpty ? nil : t.url) : nil)
      tabs[t.id] = kept
    }
    let tabTable = Table(tabs)
    let rawGroups = Table(data.groups ?? JSMap())
    var windows = JSMap<BrowserWindow>()
    for w in rawWindows.values {
      let tabIds = pinnedFirst(w.tabIds.filter { tabs[$0]?.windowId == w.id }, tabTable, rawGroups)
      if tabIds.isEmpty { continue }
      var activeTabIds = w.activeTabIds.filter { p, id in tabs[id]?.profileId == p }
      let profileId = tabIds.contains { tabs[$0]!.profileId == w.profileId } ? w.profileId : tabs[tabIds[0]]!.profileId
      if activeTabIds[profileId] == nil { activeTabIds[profileId] = tabIds.first { tabs[$0]!.profileId == profileId }! }
      var window = w
      window.tabIds = tabIds
      window.profileId = profileId
      window.activeTabIds = activeTabIds
      windows[w.id] = window
    }
    for t in tabs.values where windows[t.windowId] == nil { tabs.removeValue(forKey: t.id) }
    let windowOrder = (data.windowOrder ?? []).filter { windows[$0] != nil } + windows.keys.filter { !(data.windowOrder ?? []).contains($0) }
    var groups = JSMap<TabGroup>()
    for g in (data.groups ?? JSMap()).values {
      var kept = g
      kept.tabIds = g.tabIds.filter { tabs[$0]?.windowId == g.windowId }
      if !kept.tabIds.isEmpty { groups[g.id] = kept }
    }
    let finalTabs = Table(tabs)
    let splits = Splits.sanitizeSplits(Table(data.splits ?? JSMap()), finalTabs)
    let focused = data.focusedWindowId.flatMap { windows[$0] != nil ? $0 : nil } ?? windowOrder.last
    let engines = Set(profilesData.values.map(engineIdOf))
    var next = base
    next.profiles = Table(profilesData)
    next.profileOrder = profileOrder
    next.orphanedProfileData = (data.orphanedProfileData ?? []).filter { !engines.contains($0) }
    next.settings = settings
    next.windows = Table(windows)
    next.windowOrder = windowOrder
    next.tabs = finalTabs
    next.groups = Table(groups)
    next.splits = splits
    next.closedTabs = data.closedTabs ?? []
    next.closedWindows = data.closedWindows ?? []
    next.parkedPins = Table((data.parkedPins ?? JSMap()).filter { p, _ in profilesData[p] != nil })
    next.pinChoices = Table((data.pinChoices ?? JSMap()).filter { p, _ in profilesData[p] != nil })
    next.pinSync = Table((data.pinSync ?? JSMap()).filter { p, _ in profilesData[p] != nil })
    next.closedGroups = data.closedGroups ?? []
    next.deletedGroups = keptAWeek(data.deletedGroups ?? [], now, \.closedAt)
    next.cleanedTabs = keptAWeek((data.cleanedTabs ?? []).filter { !Ids.isIncognitoProfile($0.tab.profileId) }, now, \.closedAt)
    next.privateCleanedTabs = JSMap()
    next.privateSiteMutes = JSMap()
    next.downloads = data.downloads ?? []
    next.live = [:]
    next.peeks = Table()
    next.find = JSMap()
    next.selection = JSMap()
    next.selectionAnchors = JSMap()
    next.windowUi = JSMap()
    next.ui.focusedWindowId = focused
    next.ui.focusOrder = focused.map { f in [f] + windowOrder.filter { $0 != f }.reversed() } ?? []
    next.ui.lastProfileId = data.lastProfileId.flatMap { profilesData[$0] != nil ? $0 : nil }
    for id in next.ui.focusOrder {
      let w = windows[id]!
      next = activated(next, w.activeTabIds[w.profileId]!)
    }
    return next
  }

  public func hydrate(_ data: HydrateData) {
    let next = hydrated(data, base: state)
    memory.pages = [:]
    memory.feedWatermark = memory.feedWatermark.filter { next.tabs[$0.key] != nil }
    memory.pageProducerFence = memory.pageProducerFence.filter { next.tabs[$0.key] != nil }
    memory.closingWindowUndos = [:]
    memory.hydrating = true
    set(next)
    memory.hydrating = false
  }
}
