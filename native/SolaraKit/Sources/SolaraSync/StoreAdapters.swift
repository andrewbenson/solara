import SolaraModel
import SolaraStore

public protocol SyncStore: AnyObject {
  var state: BrowserState { get }
  func run(_ command: Command) throws
}

extension Store: SyncStore {
  public func run(_ command: Command) throws { try dispatch(command, origin: .sync) }
}

public typealias SyncLinks = () -> JSMap<JSONValue>

let fromSyncArgument: JSONValue = ["fromSync": true]

func shown(_ visible: [(key: String, value: JSONValue)]) -> JSMap<JSONValue> {
  JSMap(visible.map { ($0.key, $0.value) })
}

func extraction(_ values: OrderedDict<String, JSONValue>, ignoring: Bool = true) -> Extraction {
  Extraction(values: values.map { ($0.key, $0.value) }, ignore: ignoring ? { values[$0] == nil } : nil)
}

public let syncedSettings = [
  "warnBeforeQuitting", "warnBeforeClosingWindow", "searchEngine", "customSearchUrl", "customSearchEngines", "searchSuggestions",
  "showSelectionSearch", "commandBarPreference", "tabLayout", "hideToolbarWhileScrolling", "showSidebarButton", "showClearButton",
  "balancedTopApps", "pinnedTabIconRing", "selectedTabGlow", "pageScrollBars", "fadeUnloadedTabs", "warnBeforeClosingTabGroup",
  "newTabPosition", "newTabButtonPosition", "newTabOpens", "warnBeforeClosingLastTab", "undoReopensClosedTab", "warnBeforeMovingTabsToProfile",
  "tabReorderHaptics", "extendWebsiteColor", "cmdClickCreatesTabGroup", "optShiftClickOpensInGroup", "peekModifier", "splitLinkModifier",
  "autoGroupMeetingTabs", "cleanUpInactiveTabsAfterHours", "mutedSites", "autoPictureInPicture", "videoUpscaling", "sidebarMediaControls",
  "showFullUrl", "bookmarksBar", "appearance", "addressBar", "commandBarPlacement", "shortcuts",
  "shortcutPrecedence",
]
let syncedSettingSet = OrderedSet(syncedSettings)

func skipsNull(_ value: JSONValue, _ name: String) -> Bool {
  value.isNull && Settings.defaults.values[name] != .null
}

public final class SettingsAdapter: SyncAdapter {
  public let prefix = "set:"
  public var adoptRemoteOnJoin: Bool { true }
  let store: SyncStore

  public init(store: SyncStore) { self.store = store }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let settings = store.state.settings
    let chosen = OrderedSet(settings.chosen ?? [])
    let inferred = OrderedSet(settings.inferred ?? [])
    func filledIn(_ name: String, _ value: JSONValue) -> Bool {
      guard inferred.contains(name), let fallback = Settings.defaults.values[name], value.text() == fallback.text() else { return false }
      guard let last = context.base("set:\(name)") else { return true }
      return last["v"] == nil || last["v"] == .null
    }
    var values = OrderedDict<String, JSONValue>()
    for name in syncedSettings {
      guard chosen.contains(name), let value = settings.values[name], !skipsNull(value, name), !filledIn(name, value) else { continue }
      values["set:\(name)"] = ["v": value]
    }
    return extraction(values)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    let records = shown(visible)
    var patch = JSONObject()
    for key in changed {
      let name = key.jsSlice(4)
      guard let record = records[key], record.truthy, syncedSettingSet.contains(name), let value = record["v"], !skipsNull(value, name) else { continue }
      patch[name] = value
    }
    if !patch.isEmpty { try store.run(Command("updateSettings", [.object(patch), fromSyncArgument])) }
    return nil
  }
}

func linkedProfiles(_ store: SyncStore, _ links: JSMap<JSONValue>) -> [(id: String, link: JSONValue)] {
  let profiles = store.state.profiles
  return links.filter { id, _ in profiles[id] != nil }.map { ($0.key, $0.value) }
}

func syncIdOf(_ link: JSONValue?) -> String { link?["syncId"]?.string ?? "undefined" }

public func sanitizedTheme(_ value: JSONValue?) -> JSONValue? {
  guard let look = sanitizedLook(value), var out = look.object else { return nil }
  let mode = value?["mode"]
  out["mode"] = mode == "light" || mode == "dark" ? mode! : "auto"
  if let dark = sanitizedLook(value?["dark"]) { out["dark"] = dark }
  return .object(out)
}

let themeTextures = ["grain", "sand", "denim", "tweed"]

func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

func finite(_ v: JSONValue?, _ fallback: Double) -> Double {
  guard let n = v?.number, n.isFinite else { return fallback }
  return n
}

func jsModulo360(_ v: Double) -> Double {
  (v.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
}

func sanitizedColor(_ value: JSONValue?) -> JSONValue? {
  guard let c = value?.object else { return nil }
  let parts = [c["r"], c["g"], c["b"]].map { $0?.number }
  guard parts.allSatisfy({ $0 != nil && $0!.isFinite && abs($0!) < 4 }) else { return nil }
  return ["r": .number(parts[0]!), "g": .number(parts[1]!), "b": .number(parts[2]!), "a": .number(clamp01(finite(c["a"], 1)))]
}

func sanitizedLook(_ value: JSONValue?) -> JSONValue? {
  guard let t = value?.object, let raw = t["stops"]?.array else { return nil }
  var stops: [JSONValue] = []
  for stop in raw.prefix(16) {
    if stops.count >= 3 { break }
    guard let color = sanitizedColor(stop["color"]) else { continue }
    stops.append(["color": color, "x": .number(clamp01(finite(stop["x"], 0.5))), "y": .number(clamp01(finite(stop["y"], 0.5)))])
  }
  if stops.isEmpty { return nil }
  var out: JSONObject = [
    "stops": .array(stops), "intensity": .number(clamp01(finite(t["intensity"], 0.6))), "grain": .number(clamp01(finite(t["grain"], 0))),
    "texture": .string(t["texture"]?.string.flatMap { texture in themeTextures.contains(where: { $0.jsEquals(texture) }) ? texture : nil } ?? "grain"),
    "translucency": .number(clamp01(finite(t["translucency"], 1))),
  ]
  if let angle = t["angle"]?.number, angle.isFinite { out["angle"] = .number(jsModulo360(angle)) }
  return .object(out)
}

func jsSpread(_ value: JSONValue?) -> JSONObject {
  switch value {
  case .object(let object): return object
  case .array(let items): return JSONObject(items.enumerated().map { (String($0.offset), $0.element) })
  case .string(let text): return JSONObject(text.utf16.enumerated().map { (String($0.offset), .string(String(utf16Units: [$0.element]))) })
  default: return [:]
  }
}

func withoutAngles(_ theme: JSONValue) -> JSONObject {
  let fields = jsSpread(theme)
  var out = fields.filter { key, _ in key != "angle" && key != "dark" }
  guard let dark = fields["dark"], dark.truthy else { return out }
  out["dark"] = .object(jsSpread(dark).filter { key, _ in key != "angle" })
  return out
}

func anglesOf(_ theme: JSONObject) -> JSONObject {
  var out = JSONObject()
  if let a = theme["angle"] { out["a"] = a }
  if let d = theme["dark"]?.object?["angle"] { out["d"] = d }
  return out
}

public func themeFromRecord(_ record: JSONValue?, _ angles: JSONValue?) -> JSONValue?? {
  guard let object = record?.object else { return nil }
  if object["preset"] == .bool(true) { return .some(.null) }
  guard let theme = object["t"].map({ sanitizedTheme($0) }) ?? nil else { return nil }
  guard let angles = angles?.object else { return .some(theme) }
  var look = withoutAngles(theme)
  look["angle"] = angles["a"]
  if let dark = look["dark"]?.object {
    var withAngle = dark
    withAngle["angle"] = angles["d"]
    look["dark"] = .object(withAngle)
  }
  return .some(sanitizedTheme(.object(look)) ?? .null)
}

func legacyThemeOf(_ record: JSONValue) -> JSONValue? {
  guard let th = record["th"], th.truthy else { return nil }
  return sanitizedTheme(th)
}

func applySyncedProfilePatch(_ store: SyncStore, _ id: String, _ patch: JSONObject) throws {
  guard let profile = store.state.profiles[id] else { return }
  guard ProfileDataCleanup.validProfileId(id), ProfileDataCleanup.validProfileId(profile.id),
    ProfileDataCleanup.validProfileId(profile.dataId ?? profile.id) else {
    throw CommandError("Profile ids and data ids must use a generated lowercase profile id.")
  }
  try store.run(Command("updateProfile", [.string(id), .object(patch)]))
}

public final class ProfilesAdapter: SyncAdapter {
  public let prefix = "prof:"
  public var adoptRemoteOnJoin: Bool { true }
  let store: SyncStore
  let links: SyncLinks

  public init(store: SyncStore, links: @escaping SyncLinks) {
    self.store = store
    self.links = links
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    var values = OrderedDict<String, JSONValue>()
    let all = links()
    let profiles = store.state.profiles
    for (id, link) in linkedProfiles(store, all) {
      let p = profiles[id]!
      let syncId = syncIdOf(link)
      let sharesSyncedData = p.dataId.map { !$0.isEmpty && $0 != id && (all[$0]?.truthy ?? false) && profiles[$0] != nil } ?? false
      if sharesSyncedData && !context.known("share:\(syncId)") { continue }
      var record: JSONObject = ["n": .string(p.name), "c": .string(p.color)]
      if let icon = p.json["icon"] { record["i"] = icon }
      if id == Settings.defaultProfileID { record["d"] = true }
      let key = "prof:\(syncId)"
      let pending = link["themeAdopting"]?.truthy == true || context.unapplied(key)
      if pending && syncCanonical(context.base(key) ?? .null) != syncCanonical(.object(record)) {
        if let remoteTheme = context.remote(key)?["th"] { record["th"] = remoteTheme }
      }
      values[key] = .object(record)
    }
    return extraction(values)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    let shown = shown(visible)
    let changedSet = OrderedSet(changed)
    var refused = OrderedSet<String>()
    for (id, link) in linkedProfiles(store, links()) {
      let syncId = syncIdOf(link)
      let key = "prof:\(syncId)"
      guard let record = shown[key], record.truthy, changedSet.contains(key) else { continue }
      guard let profile = store.state.profiles[id] else { continue }
      var patch = JSONObject()
      if let n = record["n"] { patch["name"] = n }
      if let c = record["c"] { patch["color"] = c }
      if let i = record["i"] { patch["icon"] = i }
      if profile.theme == nil && !records.known("pth:\(syncId)"), let legacy = legacyThemeOf(record) { patch["theme"] = legacy }
      do {
        try applySyncedProfilePatch(store, id, patch)
      } catch {
        refused.insert(key)
      }
    }
    if !refused.isEmpty { throw ApplyRefusal(refused.elements) }
    return nil
  }
}

public final class ProfileThemesAdapter: SyncAdapter {
  public let prefix = "pth:"
  public var adoptRemoteOnJoin: Bool { true }
  let store: SyncStore
  let links: SyncLinks
  let records: () -> JSMap<JSONValue>?
  let adopted: (String) -> Void

  public init(store: SyncStore, links: @escaping SyncLinks, records: @escaping () -> JSMap<JSONValue>?, adopted: @escaping (String) -> Void = { _ in }) {
    self.store = store
    self.links = links
    self.records = records
    self.adopted = adopted
  }

  public static func angleKey(_ syncId: String) -> String { "pth:\(syncId):angle" }

  func unapplied(_ key: String, _ base: (String) -> JSONValue?) -> Bool {
    guard let record = records()?[key], record.truthy, let v = record["v"], !v.isNull else { return false }
    return syncCanonical(v) != syncCanonical(base(key) ?? .null)
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    var values = OrderedDict<String, JSONValue>()
    for (id, link) in linkedProfiles(store, links()) {
      let theme = store.state.profiles[id]!.theme
      let syncId = syncIdOf(link)
      let key = "pth:\(syncId)"
      let angleKey = Self.angleKey(syncId)
      guard let theme, !(link["themeAdopting"]?.truthy ?? false), !unapplied(key, context.base), !unapplied(angleKey, context.base) else { continue }
      values[key] = theme.truthy ? ["t": .object(withoutAngles(theme))] : ["preset": true]
      let angles = theme.truthy ? anglesOf(jsSpread(theme)) : [:]
      if !angles.isEmpty || context.known(angleKey) { values[angleKey] = .object(angles) }
    }
    return extraction(values)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    let shown = shown(visible)
    let changedSet = OrderedSet(changed)
    var refused = OrderedSet<String>()
    for (id, link) in linkedProfiles(store, links()) {
      let syncId = syncIdOf(link)
      let key = "pth:\(syncId)"
      let angleKey = Self.angleKey(syncId)
      if !changedSet.contains(key) && !changedSet.contains(angleKey) { continue }
      guard let theme = themeFromRecord(shown[key], shown[angleKey]) else { continue }
      do {
        try applySyncedProfilePatch(store, id, ["theme": theme ?? .null])
        adopted(id)
      } catch {
        for pending in [key, angleKey] where changedSet.contains(pending) { refused.insert(pending) }
      }
    }
    if !refused.isEmpty { throw ApplyRefusal(refused.elements) }
    return nil
  }
}

public final class SharedDataAdapter: SyncAdapter {
  public let prefix = "share:"
  public var adoptRemoteOnJoin: Bool { true }
  public var publishAfterPull: Bool { true }
  let store: SyncStore
  let links: SyncLinks

  public init(store: SyncStore, links: @escaping SyncLinks) {
    self.store = store
    self.links = links
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let all = links()
    let profiles = store.state.profiles
    func synced(_ id: String) -> Bool {
      profiles[id] != nil && (all[id]?["enabled"]?.truthy ?? false) && !(all[id]?["retire"]?.truthy ?? false)
    }
    var values = OrderedDict<String, JSONValue>()
    for (id, link) in all {
      guard synced(id), let ownerId = profiles[id]?.dataId, !ownerId.isEmpty, ownerId != id, synced(ownerId) else { continue }
      let key = "share:\(syncIdOf(link))"
      if !context.known(key) { values[key] = ["o": .string(syncIdOf(all[ownerId]))] }
    }
    return extraction(values)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { true }
}

public final class DeviceAdapter: SyncAdapter {
  public let prefix = "dev:"
  let key: String
  let name: () -> String
  let retired: Bool

  public init(deviceId: String, name: @escaping () -> String, retired: Bool = false) {
    key = "dev:\(deviceId)"
    self.name = name
    self.retired = retired
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let key = key
    let values: [(key: String, value: JSONValue?)] = retired ? [] : [(key, JSONValue.object(["n": .string(name())]))]
    return Extraction(values: values, ignore: { $0 != key })
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { true }
}

let maxDeviceTabs = 30

func isDeviceTabUrl(_ url: String) -> Bool {
  url.jsStartsWith("http:") || url.jsStartsWith("https:") || url.jsStartsWith("file:")
}

public final class DeviceTabsAdapter: SyncAdapter {
  public let prefix = "tabs:"
  let store: SyncStore
  let profileId: String
  let key: String
  let name: () -> String
  let retired: Bool

  public init(store: SyncStore, profileId: String, deviceId: String, name: @escaping () -> String, retired: Bool = false) {
    self.store = store
    self.profileId = profileId
    key = "tabs:\(deviceId)"
    self.name = name
    self.retired = retired
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let key = key
    if retired { return Extraction(values: [], ignore: { $0 != key }) }
    let s = store.state
    let open = s.tabs.map(\.value)
      .filter { t in
        t.profileId == profileId && !t.pinned && !(t.unloaded ?? false) && isDeviceTabUrl(t.url) && !(s.windows[t.windowId]?.incognito ?? false)
          && s.peeks[t.windowId]?.tabId != t.id
      }
      .enumerated().sorted { a, z in a.element.lastActiveAt != z.element.lastActiveAt ? a.element.lastActiveAt > z.element.lastActiveAt : a.offset < z.offset }
      .prefix(maxDeviceTabs)
      .map { item -> JSONValue in
        let t = item.element
        let title = t.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? t.title
        return ["u": .string(t.url), "t": .string(title)]
      }
    return Extraction(values: [(key, ["n": .string(name()), "tabs": .array(Array(open))])], ignore: { $0 != key })
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { true }
}

let developerModePrefix = "devmode:"
let defaultDeveloperHosts = ["localhost", "127.0.0.1", "[::1]"]

func isDefaultDeveloperHost(_ host: String) -> Bool {
  let h = host.lowercased()
  return defaultDeveloperHosts.contains(where: { $0.jsEquals(h) }) || h.jsEndsWith(".localhost")
}

func developerHostList(_ value: JSONValue?, _ keep: (String) -> Bool) -> [String] {
  guard let items = value?.array else { return [] }
  let hosts = OrderedSet(items.compactMap { item -> String? in
    guard let h = item.string, h.utf16.count > 0, h.utf16.count <= 253 else { return nil }
    return h.lowercased()
  })
  return Array(hosts.elements.filter(keep).suffix(1000))
}

public func developerModeOf(_ value: JSONValue?) -> JSONValue {
  guard let v = value, v.object != nil || v.array != nil else { return ["on": [], "off": [], "reload": "reload"] }
  return [
    "on": JSONValue(developerHostList(v["on"]) { !isDefaultDeveloperHost($0) }), "off": JSONValue(developerHostList(v["off"], isDefaultDeveloperHost)),
    "reload": v["reload"] == "forceReload" ? "forceReload" : "reload",
  ]
}

public final class DeveloperModeAdapter: SyncAdapter {
  public let prefix = developerModePrefix
  public var adoptRemoteOnJoin: Bool { true }
  let store: SyncStore
  let profileId: String

  public init(store: SyncStore, profileId: String) {
    self.store = store
    self.profileId = profileId
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let state = developerModeOf(store.state.settings.values["developerMode"]?[profileId])
    var values = OrderedDict<String, JSONValue>()
    for host in state["on"]?.array?.compactMap(\.string) ?? [] { values["\(developerModePrefix)on:\(host)"] = ["v": 1] }
    for host in state["off"]?.array?.compactMap(\.string) ?? [] { values["\(developerModePrefix)off:\(host)"] = ["v": 1] }
    if state["reload"] != "reload" { values["\(developerModePrefix)reload"] = ["r": state["reload"]!] }
    return extraction(values, ignoring: false)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    var on: [JSONValue] = []
    var off: [JSONValue] = []
    var reload: JSONValue = "reload"
    for (key, value) in visible {
      let rest = key.jsSlice(developerModePrefix.utf16.count)
      if rest.jsStartsWith("on:") {
        on.append(.string(rest.jsSlice(3)))
      } else if rest.jsStartsWith("off:") {
        off.append(.string(rest.jsSlice(4)))
      } else if rest.jsEquals("reload"), value.object != nil || value.array != nil {
        reload = value["r"] ?? .null
      }
    }
    let next = developerModeOf(["on": .array(on), "off": .array(off), "reload": reload])
    let all = store.state.settings.values["developerMode"]?.object ?? [:]
    if syncCanonical(next) == syncCanonical(developerModeOf(all[profileId])) { return nil }
    var updated = all
    updated[profileId] = next
    try store.run(Command("updateSettings", [["developerMode": .object(updated)], fromSyncArgument]))
    return nil
  }
}
