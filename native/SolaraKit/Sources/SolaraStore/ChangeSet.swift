import SolaraModel

public struct TableChange: Sendable, Equatable {
  public var upserted: [String] = []
  public var removed: [String] = []
  public var reordered = false

  public var isEmpty: Bool { upserted.isEmpty && removed.isEmpty && !reordered }

  public init() {}

  init<V>(_ after: Table<V>, _ before: Table<V>) {
    guard after.changed(from: before) else { return }
    for (id, value) in after.map where before.map[id] != value { upserted.append(id) }
    for id in before.keys where !after.contains(id) { removed.append(id) }
    let gone = Set(removed)
    let kept = before.keys.filter { !gone.contains($0) }
    let fresh = Set(upserted.filter { !before.contains($0) })
    let order = after.keys.filter { !fresh.contains($0) }
    reordered = kept != order || after.keys.suffix(fresh.count).contains { !fresh.contains($0) }
  }
}

public struct ChangeSet: Sendable, Equatable {
  public var profiles = TableChange()
  public var windows = TableChange()
  public var tabs = TableChange()
  public var live = TableChange()
  public var groups = TableChange()
  public var splits = TableChange()
  public var peeks = TableChange()
  public var parkedPins = TableChange()
  public var pinChoices = TableChange()
  public var pinSync = TableChange()
  public var find = TableChange()
  public var selection = TableChange()
  public var selectionAnchors = TableChange()
  public var windowUi = TableChange()
  public var lists: Set<String> = []
  public var settingsChanged: [String] = []
  public var settingsRemoved: [String] = []

  public init() {}

  public init(from before: BrowserState, to after: BrowserState) {
    profiles = TableChange(after.profiles, before.profiles)
    windows = TableChange(after.windows, before.windows)
    tabs = TableChange(after.tabs, before.tabs)
    if after.live != before.live {
      let current = Table(JSMap(after.live.keys.sorted().map { ($0, after.live[$0]!) }))
      let previous = Table(JSMap(before.live.keys.sorted().map { ($0, before.live[$0]!) }))
      live = TableChange(current, previous)
      live.reordered = false
    }
    groups = TableChange(after.groups, before.groups)
    splits = TableChange(after.splits, before.splits)
    peeks = TableChange(after.peeks, before.peeks)
    parkedPins = TableChange(after.parkedPins, before.parkedPins)
    pinChoices = TableChange(after.pinChoices, before.pinChoices)
    pinSync = TableChange(after.pinSync, before.pinSync)
    if after.profileOrder != before.profileOrder { lists.insert("profileOrder") }
    if after.orphanedProfileData != before.orphanedProfileData { lists.insert("orphanedProfileData") }
    if after.windowOrder != before.windowOrder { lists.insert("windowOrder") }
    if after.closedTabs != before.closedTabs { lists.insert("closedTabs") }
    if after.closedWindows != before.closedWindows { lists.insert("closedWindows") }
    if after.closedGroups != before.closedGroups { lists.insert("closedGroups") }
    if after.deletedGroups != before.deletedGroups { lists.insert("deletedGroups") }
    if after.cleanedTabs != before.cleanedTabs { lists.insert("cleanedTabs") }
    if after.privateCleanedTabs != before.privateCleanedTabs { lists.insert("privateCleanedTabs") }
    if after.privateSiteMutes != before.privateSiteMutes { lists.insert("privateSiteMutes") }
    if after.downloads != before.downloads { lists.insert("downloads") }
    if after.find != before.find { find = TableChange(Table(after.find), Table(before.find)) }
    if after.selection != before.selection { selection = TableChange(Table(after.selection), Table(before.selection)) }
    if after.selectionAnchors != before.selectionAnchors { selectionAnchors = TableChange(Table(after.selectionAnchors), Table(before.selectionAnchors)) }
    if after.windowUi != before.windowUi { windowUi = TableChange(Table(after.windowUi), Table(before.windowUi)) }
    if after.ui != before.ui { lists.insert("ui") }
    if after.caches != before.caches { lists.insert("caches") }
    if before.settings != after.settings {
      for (key, value) in after.settings.values where before.settings.values[key] != value { settingsChanged.append(key) }
      for key in before.settings.values.keys where !after.settings.values.contains(key) { settingsRemoved.append(key) }
    }
  }

  public var isEmpty: Bool {
    profiles.isEmpty && windows.isEmpty && tabs.isEmpty && live.isEmpty && groups.isEmpty && splits.isEmpty && peeks.isEmpty && parkedPins.isEmpty
      && pinChoices.isEmpty && pinSync.isEmpty && find.isEmpty && selection.isEmpty && selectionAnchors.isEmpty && windowUi.isEmpty
      && lists.isEmpty && settingsChanged.isEmpty && settingsRemoved.isEmpty
  }

  public var downloads: Bool { lists.contains("downloads") }
  public var settings: Bool { !settingsChanged.isEmpty || !settingsRemoved.isEmpty }
}

struct TablePatch: @unchecked Sendable {
  var upsert: [any JSONConvertible]
  var ids: [String]
  var remove: [String]
  var order: [String]?
  let encode: @Sendable (String, any JSONConvertible) -> JSONValue

  init?<V: JSONConvertible>(_ change: TableChange, _ table: Table<V>, encode: @escaping @Sendable (String, V) -> JSONValue) {
    if change.isEmpty { return nil }
    var values: [any JSONConvertible] = []
    var ids: [String] = []
    for id in change.upserted { if let value = table[id] { values.append(value); ids.append(id) } }
    upsert = values
    self.ids = ids
    remove = change.removed
    order = change.reordered ? table.keys : nil
    self.encode = { id, value in encode(id, value as! V) }
  }

  var json: JSONValue {
    var out: JSONObject = ["upsert": .array(zip(ids, upsert).map { encode($0, $1) }), "remove": JSONValue(remove)]
    if let order { out["order"] = JSONValue(order) }
    return .object(out)
  }
}

enum ListValue: @unchecked Sendable {
  case strings([String])
  case closedTabs([ClosedTab])
  case closedWindows([ClosedWindow])
  case closedGroups([ClosedGroup])
  case privateCleaned(JSMap<[ClosedTab]>)
  case privateMutes(JSMap<JSMap<Bool>>)
  case downloads([Download])
  case focus(FocusState)

  var json: JSONValue {
    switch self {
    case .strings(let v): JSONValue(v)
    case .closedTabs(let v): .array(v.map(\.jsonValue))
    case .closedWindows(let v): .array(v.map(\.jsonValue))
    case .closedGroups(let v): .array(v.map(\.jsonValue))
    case .privateCleaned(let v): .object(v.mapValues { .array($0.map(\.jsonValue)) })
    case .privateMutes(let v): .object(v.mapValues { .object($0.mapValues(JSONValue.bool)) })
    case .downloads(let v): .array(v.map { .object($0.json) })
    case .focus(let ui): ["appDark": .bool(ui.appDark), "focusedWindowId": JSONValue(ui.focusedWindowId), "focusOrder": JSONValue(ui.focusOrder), "lastProfileId": JSONValue(ui.lastProfileId)]
    }
  }
}

public struct Patch: @unchecked Sendable {
  public let rev: Int
  var tables: [(String, TablePatch)] = []
  var lists: [(String, ListValue)] = []
  public var settings: JSONObject? = nil
  public var settingsRemoved: [String] = []
  public var fromBridge = false
  public var fromSync = false

  public init(rev: Int, changes: ChangeSet, state s: BrowserState) {
    self.rev = rev
    func add<V: JSONConvertible>(_ name: String, _ change: TableChange, _ table: Table<V>, _ encode: @escaping @Sendable (String, V) -> JSONValue) {
      if let patch = TablePatch(change, table, encode: encode) { tables.append((name, patch)) }
    }
    add("profiles", changes.profiles, s.profiles) { _, v in v.jsonValue }
    add("windows", changes.windows, s.windows) { _, v in v.jsonValue }
    add("tabs", changes.tabs, s.tabs) { _, v in v.jsonValue }
    if !changes.live.isEmpty {
      add("live", changes.live, Table(JSMap(s.live.keys.sorted().map { ($0, s.live[$0]!) }))) { id, value in
        var object = value.json
        object["id"] = .string(id)
        return .object(object)
      }
    }
    add("groups", changes.groups, s.groups) { _, v in v.jsonValue }
    add("splits", changes.splits, s.splits) { _, v in v.jsonValue }
    add("peeks", changes.peeks, s.peeks) { id, v in
      var o = v.json
      o["windowId"] = .string(id)
      return .object(o)
    }
    add("parkedPins", changes.parkedPins, s.parkedPins) { id, v in
      var o = v.json
      o["profileId"] = .string(id)
      return .object(o)
    }
    if !changes.pinChoices.isEmpty,
      let patch = TablePatch(changes.pinChoices, Table(s.pinChoices.map.mapValues(PinTableValue.choices)), encode: { id, v in v.json(id) })
    {
      tables.append(("pinChoices", patch))
    }
    if !changes.pinSync.isEmpty, let patch = TablePatch(changes.pinSync, Table(s.pinSync.map.mapValues(PinTableValue.sync)), encode: { id, v in v.json(id) }) {
      tables.append(("pinSync", patch))
    }
    add("find", changes.find, Table(s.find)) { id, value in ["tabId": .string(id), "state": value.jsonValue] }
    add("selection", changes.selection, Table(s.selection)) { id, value in ["windowId": .string(id), "ids": JSONValue(value.ids)] }
    add("selectionAnchors", changes.selectionAnchors, Table(s.selectionAnchors)) { id, value in ["windowId": .string(id), "tabId": .string(value.tabId)] }
    add("windowUi", changes.windowUi, Table(s.windowUi)) { id, value in ["windowId": .string(id), "state": value.jsonValue] }
    for name in changes.lists.sorted() {
      switch name {
      case "profileOrder": lists.append((name, .strings(s.profileOrder)))
      case "orphanedProfileData": lists.append((name, .strings(s.orphanedProfileData)))
      case "windowOrder": lists.append((name, .strings(s.windowOrder)))
      case "closedTabs": lists.append((name, .closedTabs(s.closedTabs)))
      case "closedWindows": lists.append((name, .closedWindows(s.closedWindows)))
      case "closedGroups": lists.append((name, .closedGroups(s.closedGroups)))
      case "deletedGroups": lists.append((name, .closedGroups(s.deletedGroups)))
      case "cleanedTabs": lists.append((name, .closedTabs(s.cleanedTabs)))
      case "privateCleanedTabs": lists.append((name, .privateCleaned(s.privateCleanedTabs)))
      case "privateSiteMutes": lists.append((name, .privateMutes(s.privateSiteMutes)))
      case "downloads": lists.append((name, .downloads(s.downloads)))
      case "ui": lists.append((name, .focus(s.ui)))
      default: break
      }
    }
    settings = changes.settingsChanged.isEmpty ? nil : JSONObject(changes.settingsChanged.map { ($0, s.settings.values[$0]!) })
    settingsRemoved = changes.settingsRemoved
  }

  public var downloads: [Download]? {
    for (name, value) in lists where name == "downloads" { if case .downloads(let d) = value { return d } }
    return nil
  }

  public var json: JSONValue {
    var out: JSONObject = ["rev": JSONValue(rev)]
    if fromBridge { out["bridge"] = true }
    if fromSync { out["sync"] = true }
    for (name, table) in tables { out[name] = table.json }
    for (name, value) in lists { out[name] = value.json }
    if settings != nil || !settingsRemoved.isEmpty {
      var entry = JSONObject()
      if let settings { entry["set"] = .object(settings) }
      if !settingsRemoved.isEmpty { entry["remove"] = JSONValue(settingsRemoved) }
      out["settings"] = .object(entry)
    }
    return .object(out)
  }
}

enum PinTableValue: JSONConvertible {
  case choices(JSMap<Double>)
  case sync(JSMap<JSONValue>)

  init(json: JSONObject) throws { self = .sync(json) }

  var json: JSONObject {
    switch self {
    case .choices(let v): v.mapValues(JSONValue.number)
    case .sync(let v): v
    }
  }

  func json(_ profileId: String) -> JSONValue { ["profileId": .string(profileId), "table": .object(json)] }
}
