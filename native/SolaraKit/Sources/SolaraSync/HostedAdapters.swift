import SolaraModel
import SolaraStore
import Synchronization

public protocol BookmarksHost: AnyObject {
  func bookmarksReady(_ profileId: String) -> Bool
  var bookmarks: JSONValue { get }
  func setBookmarks(_ value: JSONValue)
  func engineProfile(_ profileId: String) -> String
}

public protocol HistoryHost: AnyObject {
  func historyReady(_ profileId: String) -> Bool
  func history(_ profileId: String) -> [JSONValue]?
  func historyFloor(_ profileId: String) -> Double?
  func engineProfile(_ profileId: String) -> String
  func addHistoryVisits(_ engineProfile: String, _ visits: [JSONValue], _ sameVisitMs: Double) async throws -> JSONValue?
  func deleteHistoryUrls(_ engineProfile: String, _ urls: [String]) async throws -> JSONValue?
  func setHistory(_ profileId: String, _ entries: [JSONValue])
}

public protocol PasswordsHost: AnyObject {
  func engineProfile(_ profileId: String) -> String
  func readLogins(_ engineProfile: String) async throws -> JSONValue?
  func savePassword(_ engineProfile: String, _ origin: JSONValue?, _ username: JSONValue?, _ password: JSONValue?) async throws -> JSONValue?
  func deletePassword(_ engineProfile: String, _ origin: String, _ username: String) async throws -> JSONValue?
  func sleep(_ ms: Double) async
}

func jsonFinite(_ value: JSONValue) -> JSONValue {
  switch value {
  case .number(let n): return n.isFinite ? value : .null
  case .array(let items): return .array(items.map(jsonFinite))
  case .object(let object): return .object(object.mapValues(jsonFinite))
  default: return value
  }
}

func jsMaxNumber(_ values: [JSONValue?]) -> Double {
  var out = -Double.infinity
  for v in values {
    let n = jsNumber(jsPrimitive(v))
    if n.isNaN { return .nan }
    if n > out || (n == 0 && out == 0 && n.sign == .plus) { out = n }
  }
  return out
}

let legacyBookmarkSeed = "netnyahoo-bookmark:"

public func isBookmarkUuid(_ id: String) -> Bool {
  let units = Array(id.utf8)
  guard units.count == 36 else { return false }
  for (i, u) in units.enumerated() {
    if i == 8 || i == 13 || i == 18 || i == 23 {
      if u != UInt8(ascii: "-") { return false }
    } else if !((u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x66)) {
      return false
    }
  }
  return true
}

func uuidFrom(_ words: [UInt32]) -> String {
  let hex = words.map { padStart(String($0, radix: 16), 8) }.joined()
  let units = Array(hex.utf8)
  let digit = Int(String(UnicodeScalar(units[16])), radix: 16)!
  let variant = String((digit & 0x3) | 0x8, radix: 16)
  func part(_ a: Int, _ b: Int) -> String { String(decoding: units[a..<b], as: UTF8.self) }
  return "\(part(0, 8))-\(part(8, 12))-4\(part(13, 16))-\(variant)\(part(17, 20))-\(part(20, 32))"
}

public func bookmarkUuidFor(_ id: String) -> String {
  if isBookmarkUuid(id) { return id }
  var h1: UInt32 = 1779033703, h2: UInt32 = 3144134277, h3: UInt32 = 1013904242, h4: UInt32 = 2773480762
  for k in (legacyBookmarkSeed + id).utf16.map(UInt32.init) {
    h1 = h2 ^ ((h1 ^ k) &* 597399067)
    h2 = h3 ^ ((h2 ^ k) &* 2869860233)
    h3 = h4 ^ ((h3 ^ k) &* 951274213)
    h4 = h1 ^ ((h4 ^ k) &* 2716044179)
  }
  h1 = (h3 ^ (h1 >> 18)) &* 597399067
  h2 = (h4 ^ (h2 >> 22)) &* 2869860233
  h3 = (h1 ^ (h3 >> 17)) &* 951274213
  h4 = (h2 ^ (h4 >> 19)) &* 2716044179
  h1 ^= h2 ^ h3 ^ h4
  h2 ^= h1
  h3 ^= h1
  h4 ^= h1
  return uuidFrom([h1, h2, h3, h4])
}

func bookmarkRoots(_ engine: String) -> (bar: String, other: String) {
  let name = engine.isEmpty ? "default" : engine
  return ("bar@\(name)", "other@\(name)")
}

func ensureBookmarkRoots(_ b: JSONValue, _ profileId: String, _ engine: String) -> (JSONValue, bar: String, other: String) {
  if let existing = b["roots"]?[profileId], existing.truthy {
    return (b, existing["bar"].map(jsText) ?? "undefined", existing["other"].map(jsText) ?? "undefined")
  }
  let roots = bookmarkRoots(engine)
  var nodes = jsSpread(b["nodes"])
  for (id, title) in [(roots.bar, "Bookmarks Bar"), (roots.other, "Other Bookmarks")] where nullish(nodes[id]) {
    nodes[id] = ["kind": "folder", "id": .string(id), "parentId": .null, "title": .string(title), "children": [], "addedAt": 0]
  }
  var allRoots = jsSpread(b["roots"])
  allRoots[profileId] = ["bar": .string(roots.bar), "other": .string(roots.other)]
  return (["nodes": .object(nodes), "roots": .object(allRoots)], roots.bar, roots.other)
}

func nullish(_ v: JSONValue?) -> Bool { v == nil || v == .null }

public final class BookmarksAdapter: SyncAdapter {
  public let prefix = "bm:"
  let host: BookmarksHost
  let profileId: String

  public init(host: BookmarksHost, profileId: String) {
    self.host = host
    self.profileId = profileId
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    guard host.bookmarksReady(profileId) else { return nil }
    let b = host.bookmarks
    let nodes = b["nodes"]?.object ?? [:]
    guard let roots = b["roots"]?[profileId], roots.truthy else { return Extraction(values: []) }
    let bar = roots["bar"].map(jsText) ?? "undefined"
    let other = roots["other"].map(jsText) ?? "undefined"
    func keyOf(_ id: String) -> String {
      if id == bar { return "bar" }
      if id == other { return "other" }
      if let key = nodes[id]?["syncKey"], key.truthy, bookmarkUuidFor(jsText(key)) == id { return jsText(key) }
      return id
    }
    var values = OrderedDict<String, JSONValue>()
    var seen = OrderedSet<String>()
    func walk(_ folderId: String) throws {
      guard let folder = nodes[folderId], folder["kind"] == "folder", !seen.contains(folderId) else { return }
      seen.insert(folderId)
      let parent = keyOf(folderId)
      let children = (folder["children"]?.array ?? []).map(jsText).filter { nodes[$0]?.truthy ?? false }
      let positions = try assignPositions(children.map { id -> String? in
        let known = context.base("bm:\(keyOf(id))")
        return jsStrict(known?["p"], .string(parent)) ? known?["pos"]?.string : nil
      })
      for (i, id) in children.enumerated() {
        let node = nodes[id]!
        let isUrl = node["kind"] == "url"
        var value: JSONObject = ["k": .string(isUrl ? "u" : "f"), "p": .string(parent)]
        if let t = node["title"] { value["t"] = t }
        if isUrl, let u = node["url"] { value["u"] = u }
        if let a = node["addedAt"] { value["a"] = a }
        value["pos"] = .string(positions[i])
        values["bm:\(keyOf(id))"] = .object(value)
        if node["kind"] == "folder" { try walk(id) }
      }
    }
    try walk(bar)
    try walk(other)
    return Extraction(values: values.map { ($0.key, $0.value) })
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    guard host.bookmarksReady(profileId) else { return false }
    let (b, bar, other) = ensureBookmarkRoots(host.bookmarks, profileId, host.engineProfile(profileId))
    var values = OrderedDict<String, JSONValue>()
    var keys = OrderedDict<String, String>()
    for (k, v) in visible {
      let key = k.jsSlice(3)
      values[bookmarkUuidFor(key)] = v
      keys[bookmarkUuidFor(key)] = key
    }
    func rootOf(_ key: JSONValue?) -> String? {
      if jsStrict(key, "bar") { return bar }
      if jsStrict(key, "other") { return other }
      return nil
    }
    var parentOf = OrderedDict<String, String>()
    for (id, v) in values {
      let p = v["p"]
      if let root = rootOf(p) {
        parentOf[id] = root
      } else {
        let parent = bookmarkUuidFor(jsText(p))
        parentOf[id] = jsStrict(values[parent]?["k"], "f") ? parent : other
      }
    }
    for id in values.keys.sorted(by: jsKeyPrecedes) {
      var seen = OrderedSet([id])
      var at = parentOf[id]!
      while let next = parentOf[at] {
        if seen.contains(at) {
          parentOf[id] = other
          break
        }
        seen.insert(at)
        at = next
      }
    }
    var children = OrderedDict<String, [String]>()
    children[bar] = []
    children[other] = []
    for id in values.keys { children[parentOf[id]!, default: []].append(id) }
    func byPosition(_ a: String, _ z: String) -> Double {
      let pa = values[a]?["pos"]
      let pz = values[z]?["pos"]
      if jsLess(pa, pz) { return -1 }
      if jsLess(pz, pa) { return 1 }
      return jsKeyPrecedes(keys[a]!, keys[z]!) ? -1 : 1
    }
    let oldNodes = b["nodes"]?.object ?? [:]
    var nodes = jsSpread(b["nodes"])
    func drop(_ id: String) {
      if let node = nodes[id], node["kind"] == "folder" { for child in node["children"]?.array ?? [] { drop(jsText(child)) } }
      if id != bar && id != other { nodes.removeValue(forKey: id) }
    }
    drop(bar)
    drop(other)
    for (id, v) in values {
      let old = oldNodes[id]
      let key = keys[id]!
      var node: JSONObject
      if jsStrict(v["k"], "u") {
        node = ["kind": "url", "id": .string(id), "parentId": .string(parentOf[id]!)]
        if let t = v["t"] { node["title"] = t }
        node["url"] = nullish(v["u"]) ? "" : v["u"]!
        if old?["kind"] == "url" {
          if let favicon = old?["favicon"] { node["favicon"] = favicon }
        } else {
          node["favicon"] = .null
        }
      } else {
        node = ["kind": "folder", "id": .string(id), "parentId": .string(parentOf[id]!)]
        if let t = v["t"] { node["title"] = t }
        node["children"] = []
      }
      if let a = v["a"] { node["addedAt"] = a }
      if !isBookmarkUuid(key) { node["syncKey"] = .string(key) }
      nodes[id] = .object(node)
    }
    for (parent, ids) in children {
      guard var folder = nodes[parent]?.object, folder["kind"] == "folder" else { continue }
      folder["children"] = JSONValue(jsSort(ids, byPosition))
      nodes[parent] = .object(folder)
    }
    var next = jsSpread(b)
    next["nodes"] = .object(nodes)
    host.setBookmarks(.object(next))
    return nil
  }
}

let historyWindowMs: Double = 90 * 86_400_000
let sameVisitMs: Double = 1
let maxHistory = 5000
let maxVisitTimes = 50

func keptInHistory(_ url: String) -> Bool {
  let lower = url.lowercased()
  return lower.jsStartsWith("http:") || lower.jsStartsWith("https:") || lower.jsStartsWith("file:")
}

func lastVisitOf(_ value: JSONValue?) -> Double { jsMaxNumber([0] + (value?["vt"]?.array ?? []).map { Optional($0) }) }

func numericOrder(_ a: JSONValue, _ z: JSONValue) -> Double { jsNumber(jsPrimitive(a)) - jsNumber(jsPrimitive(z)) }

func closeVisit(_ a: JSONValue?, _ b: JSONValue?) -> Bool { abs(jsNumber(jsPrimitive(a)) - jsNumber(jsPrimitive(b))) <= sameVisitMs }

public func historyExpired(_ key: String, _ value: JSONValue, _ now: Double) -> Bool {
  key.jsStartsWith("h:") && lastVisitOf(value) < now - historyWindowMs
}

func sameValueZero(_ a: JSONValue, _ b: JSONValue) -> Bool {
  if case .number(let x) = a, case .number(let y) = b { return x == y || (x.isNaN && y.isNaN) }
  return jsStrict(a, b)
}

private func historyEngine(_ profile: Profile) -> String {
  let data = profile.dataId ?? profile.id
  return data.jsEquals(Settings.defaultProfileID) ? "" : data
}

private final class HistoryApplyLifetime: Sendable {
  let profileId: String
  let createdAt: Double
  let engine: String
  let retired = Atomic(false)

  init(_ profile: Profile) {
    profileId = profile.id
    createdAt = profile.createdAt
    engine = historyEngine(profile)
  }

  func matches(_ state: BrowserState) -> Bool {
    guard let profile = state.profiles[profileId] else { return false }
    return profile.id.jsEquals(profileId) && profile.createdAt == createdAt && historyEngine(profile).jsEquals(engine)
      && !state.orphanedProfileData.contains { $0.jsEquals(engine) }
  }
}

public final class HistoryAdapter: SyncAdapter {
  public let prefix = "h:"
  let store: Store
  let host: HistoryHost
  let profileId: String
  let now: () -> Double

  public init(store: Store, host: HistoryHost, profileId: String, now: @escaping () -> Double) {
    self.store = store
    self.host = host
    self.profileId = profileId
    self.now = now
  }

  private func ready(_ state: BrowserState) -> Bool {
    guard let profile = state.profiles[profileId], profile.id.jsEquals(profileId) else { return false }
    return host.historyReady(profileId) && !state.orphanedProfileData.contains { $0.jsEquals(historyEngine(profile)) }
  }

  public func editedAt(_ value: JSONValue) -> Double? { lastVisitOf(value) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    guard ready(store.state) else { return nil }
    let since = now() - historyWindowMs
    var values = OrderedDict<String, JSONValue>()
    var older = Set<JSKey>()
    let floor = host.historyFloor(profileId) ?? -.infinity
    for e in host.history(profileId) ?? [] {
      let url = jsText(e["url"])
      guard keptInHistory(url) else { continue }
      let key = "h:\(url)"
      if jsNumber(jsPrimitive(e["lastVisit"])) < since {
        older.insert(JSKey(key))
        continue
      }
      let times = e["visitTimes"]?.array ?? []
      var local = JSONObject()
      if let t = e["title"] { local["t"] = t }
      if let n = e["visits"] { local["n"] = n }
      local["vt"] = times.isEmpty ? .array([e["lastVisit"] ?? .null]) : .array(times)
      let vt = local["vt"]!.array!
      let known = context.base(key)
      let edited = known.map { k in !k.truthy || vt.contains { t in !(k["vt"]?.array ?? []).contains { closeVisit($0, t) } } } ?? true
      values[key] = edited ? .object(local) : known!
    }
    let base = context.base
    let ignore: (String) -> Bool = { key in
      if older.contains(JSKey(key)) || !keptInHistory(key.jsSlice(2)) { return true }
      guard let known = base(key), known.truthy else { return false }
      return lastVisitOf(known) < since || lastVisitOf(known) <= floor
    }
    return Extraction(values: values.map { ($0.key, $0.value) }, ignore: ignore)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    let started = store.sequence { () -> (lifetime: HistoryApplyLifetime, subscription: Int, deliveryCaughtUp: Bool)? in
      let cursor = store.deliveryCursor()
      let snapshot = store.snapshot
      guard ready(snapshot.state), let profile = snapshot.state.profiles[profileId] else { return nil }
      let lifetime = HistoryApplyLifetime(profile)
      let subscription = store.subscribe { commit in
        if commit.rev > snapshot.rev && !lifetime.matches(commit.state) { lifetime.retired.store(true, ordering: .releasing) }
      }
      return (lifetime, subscription, cursor.delivered == cursor.committed)
    }
    guard let started else { return false }
    defer { store.unsubscribe(started.subscription) }
    let since = now() - historyWindowMs
    let shown = shown(visible)
    var byUrl = OrderedDict<String, JSONValue>()
    for e in host.history(profileId) ?? [] { byUrl[jsText(e["url"])] = e }
    var add: [JSONValue] = []
    var remove: [String] = []
    var updates = OrderedDict<String, JSONValue>()
    for key in changed {
      let url = key.jsSlice(2)
      guard keptInHistory(url) else { continue }
      let old = byUrl[url]
      if let v = shown[key], v.truthy {
        let have = old?["visitTimes"]?.array ?? []
        let fresh = (v["vt"]?.array ?? []).filter { t in jsNumber(jsPrimitive(t)) >= since && !have.contains { closeVisit($0, t) } }
        if !fresh.isEmpty {
          var visit: JSONObject = ["url": .string(url)]
          if let t = v["t"] { visit["title"] = t }
          visit["visitTimes"] = .array(fresh)
          add.append(.object(visit))
        }
        let times = Array(jsSort(have + fresh, numericOrder).suffix(maxVisitTimes))
        guard let last = times.last else { continue }
        let title: JSONValue = [v["t"], old?["title"]].first { $0?.truthy ?? false }.flatMap { $0 } ?? ""
        updates[url] = [
          "url": .string(url), "title": title, "favicon": .null,
          "visits": .number(jsMaxNumber([v["n"], nullish(old?["visits"]) ? 0 : old?["visits"]])), "lastVisit": last, "visitTimes": .array(times),
        ]
      } else if let old, jsNumber(jsPrimitive(old["lastVisit"])) >= since {
        remove.append(url)
        updates[url] = .null
      }
    }
    if updates.isEmpty { return nil }
    let engine = started.lifetime.engine
    _ = try await host.addHistoryVisits(engine, add, sameVisitMs)
    _ = try await host.deleteHistoryUrls(engine, remove)
    try store.sequence {
      let cursor = store.deliveryCursor()
      guard started.deliveryCaughtUp, !started.lifetime.retired.load(ordering: .acquiring), ready(store.state), started.lifetime.matches(store.state), cursor.delivered == cursor.committed else {
        throw ApplyRefusal(changed)
      }
      var current = OrderedDict<String, JSONValue>()
      for e in host.history(profileId) ?? [] { current[jsText(e["url"])] = e }
      for (url, update) in updates {
        if update.isNull {
          current[url] = nil
        } else if let present = current[url] {
          var merged: [JSONValue] = []
          for t in (present["visitTimes"]?.array ?? []) + (update["visitTimes"]?.array ?? []) where !merged.contains(where: { sameValueZero($0, t) }) {
            merged.append(t)
          }
          let times = Array(jsSort(merged, numericOrder).suffix(maxVisitTimes))
          var next = update.object ?? [:]
          next["visits"] = .number(jsMaxNumber([present["visits"], update["visits"]]))
          if let last = times.last { next["lastVisit"] = last } else { next.removeValue(forKey: "lastVisit") }
          next["visitTimes"] = .array(times)
          current[url] = .object(next)
        } else {
          current[url] = update
        }
      }
      let list = jsSort(current.values) { a, z in jsNumber(jsPrimitive(z["lastVisit"])) - jsNumber(jsPrimitive(a["lastVisit"])) }
      host.setHistory(profileId, list.prefix(maxHistory).map(jsonFinite))
    }
    return nil
  }
}

let passwordReadInterval: Double = 30_000

func loginOrigin(_ login: JSONValue) -> String? {
  var realm = jsText(login["origin"])
  if realm.jsEndsWith("/") { realm = realm.jsSlice(0, -1) }
  let units = Array(realm.utf16)
  let scheme: [UInt16]
  if realm.jsStartsWith("https://") { scheme = Array("https://".utf16) } else if realm.jsStartsWith("http://") { scheme = Array("http://".utf16) } else { return nil }
  let rest = units[scheme.count...]
  guard !rest.isEmpty, !rest.contains(where: { $0 == 0x2F || JS.isWhitespace($0) }) else { return nil }
  return realm
}

public struct PasswordsMemory: Sendable, Equatable {
  public var lastRead: Double
  public var quietUntil: Double
  public var created: [(String, JSONValue?)]

  public init(lastRead: Double = 0, quietUntil: Double = 0, created: [(String, JSONValue?)] = []) {
    self.lastRead = lastRead
    self.quietUntil = quietUntil
    self.created = created
  }

  public static func == (a: PasswordsMemory, b: PasswordsMemory) -> Bool {
    a.lastRead == b.lastRead && a.quietUntil == b.quietUntil && a.created.map(\.0) == b.created.map(\.0) && a.created.map(\.1) == b.created.map(\.1)
  }
}

public final class PasswordsAdapter: SyncAdapter {
  public let prefix = "pw:"
  let host: PasswordsHost
  let profileId: String
  let forced: () -> Bool
  let now: () -> Double
  let redesign: () -> Bool
  public private(set) var memory: PasswordsMemory

  public init(
    host: PasswordsHost, profileId: String, forced: @escaping () -> Bool, now: @escaping () -> Double, redesign: @escaping () -> Bool = { false },
    memory: PasswordsMemory = PasswordsMemory()
  ) {
    self.host = host
    self.profileId = profileId
    self.forced = forced
    self.now = now
    self.redesign = redesign
    self.memory = memory
  }

  static func keyOf(_ origin: JSONValue?, _ username: JSONValue?) -> String { "pw:\(jsText(origin))\n\(jsText(username))" }

  func read() async throws -> OrderedDict<String, JSONObject>? {
    guard let logins = try await host.readLogins(host.engineProfile(profileId)), logins.truthy else { return nil }
    var out = OrderedDict<String, JSONObject>()
    for login in logins.array ?? [] {
      guard let origin = loginOrigin(login) else { continue }
      var value: JSONObject = ["o": .string(origin)]
      if let u = login["username"] { value["u"] = u }
      if let p = login["password"] { value["p"] = p }
      if let c = login["created"] { value["c"] = c }
      out[Self.keyOf(.string(origin), login["username"])] = value
    }
    return out
  }

  public func editedAt(_ value: JSONValue) -> Double? {
    let key = Self.keyOf(value["o"], value["u"])
    guard let created = memory.created.last(where: { $0.0.jsEquals(key) })?.1, created.truthy else { return nil }
    return jsNumber(jsPrimitive(created))
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let at = now()
    if at < memory.quietUntil || (at - memory.lastRead < passwordReadInterval && !forced()) { return nil }
    guard let logins = try await read() else { return nil }
    memory.lastRead = at
    memory.created = logins.map { ($0.key, $0.value["c"]) }
    return Extraction(values: logins.map { entry in (entry.key, JSONValue.object(entry.value.filter { key, _ in key != "c" })) })
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await applyKeys(visible, changed, base, records) != .failed
  }

  public func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome {
    guard let local = try await read() else { return .failed }
    let shown = shown(visible)
    let engine = host.engineProfile(profileId)
    var ok: JSONValue = true
    func and(_ result: JSONValue?) {
      if !(result?.truthy ?? false) { ok = result ?? .null }
    }
    var keptHere = Set<JSKey>()
    for key in changed {
      let v = shown[key]
      let have = local[key]
      let known = base(key)
      if let have, !jsStrict(known?["p"], have["p"]) {
        keptHere.insert(JSKey(key))
        continue
      }
      let newline = key.jsIndexOf("\n")
      let origin = key.jsSlice(3, newline)
      let username = key.jsSlice(newline + 1)
      if let v, v.truthy {
        if jsStrict(have?["p"], v["p"]) { continue }
        if have != nil { and(try await host.deletePassword(engine, origin, username)) }
        and(try await host.savePassword(engine, v["o"], v["u"], v["p"]))
      } else if have != nil {
        and(try await host.deletePassword(engine, origin, username))
      }
    }
    func confirmed(_ now: OrderedDict<String, JSONObject>?, _ k: String) -> Bool {
      guard let now else { return false }
      return jsStrict(shown[k]?["p"], now[k]?["p"])
    }
    var latest: OrderedDict<String, JSONObject>? = nil
    var settled = false
    var i = 0
    while i < 20 && !settled {
      latest = try await read()
      settled = changed.allSatisfy { k in (redesign() && keptHere.contains(JSKey(k))) || confirmed(latest, k) }
      if !settled { await host.sleep(250) }
      i += 1
    }
    if !settled { memory.quietUntil = now() + 30_000 }
    if !ok.truthy { return .failed }
    return .written(changed.filter { confirmed(latest, $0) })
  }
}
