import SolaraModel

public struct StripTab: Sendable, Equatable {
  public var key: String?
  public var browser: Int
  public var index: Int
  public var active: Bool
  public var pinned: Bool
  public var group: String??
  public var extra: JSONObject = [:]

  init(json: JSONValue) {
    let o = json.object ?? [:]
    key = o["key"]?.string
    browser = o["browser"]?.int ?? 0
    index = o["index"]?.int ?? 0
    active = o["active"]?.truthy ?? false
    pinned = o["pinned"]?.truthy ?? false
    if let g = o["group"] { group = .some(g.string) } else { group = nil }
    extra = o.filter { k, _ in !["key", "browser", "index", "active", "pinned", "group"].contains(k) }
  }

  var json: JSONValue {
    var o = extra
    o["key"] = JSONValue(key)
    o["browser"] = JSONValue(browser)
    o["index"] = JSONValue(index)
    o["active"] = .bool(active)
    o["pinned"] = .bool(pinned)
    if let group { o["group"] = JSONValue(group) }
    return .object(o)
  }
}

public struct StripGroup: Sendable, Equatable {
  public var id: String
  public var title: String
  public var color: String
  public var collapsed: Bool

  init(json: JSONValue) {
    id = json["id"]?.string ?? ""
    title = json["title"]?.string ?? ""
    color = json["color"]?.string ?? "grey"
    collapsed = json["collapsed"]?.truthy ?? false
  }

  var json: JSONValue { ["id": .string(id), "title": .string(title), "color": .string(color), "collapsed": .bool(collapsed)] }
}

public struct StripState: Sendable, Equatable {
  public var strip: Int
  public var window: Int
  public var appWindow: String?
  public var profile: String
  public var tabs: [StripTab]
  public var activePickedOnClose: Bool?
  public var groups: [StripGroup]?
  public var closed: Bool?
  public var extra: JSONObject = [:]

  public init(json: JSONValue) {
    let o = json.object ?? [:]
    strip = o["strip"]?.int ?? 0
    window = o["window"]?.int ?? 0
    appWindow = o["appWindow"]?.string
    profile = o["profile"]?.string ?? ""
    tabs = (o["tabs"]?.array ?? []).map(StripTab.init(json:))
    activePickedOnClose = o["activePickedOnClose"]?.bool
    groups = o["groups"]?.array?.map(StripGroup.init(json:))
    closed = o["closed"]?.bool
    extra = o.filter { k, _ in !["strip", "window", "appWindow", "profile", "tabs", "activePickedOnClose", "groups", "closed"].contains(k) }
  }

  public var json: JSONValue {
    var o = extra
    o["strip"] = JSONValue(strip)
    o["window"] = JSONValue(window)
    if let appWindow { o["appWindow"] = .string(appWindow) }
    o["profile"] = .string(profile)
    o["tabs"] = .array(tabs.map(\.json))
    if let activePickedOnClose { o["activePickedOnClose"] = .bool(activePickedOnClose) }
    if let groups { o["groups"] = .array(groups.map(\.json)) }
    if let closed { o["closed"] = .bool(closed) }
    return .object(o)
  }
}

public struct StripTransaction: Sendable {
  public var rev: Int
  public var cmd: Int?
  public var strips: [StripState]

  public init(json: JSONValue) {
    rev = json["rev"]?.int ?? 0
    cmd = json["cmd"]?.int
    strips = (json["strips"]?.array ?? []).map(StripState.init(json:))
  }
}

public struct Inflight: Sendable, Equatable {
  public var kind: String
  public var cmd: Int?
  public var keys: [String]?
  public var makes: String?
  public var successor: Bool?
  public var moves: Bool?

  var json: JSONValue {
    var o: JSONObject = ["kind": .string(kind), "cmd": cmd.map { JSONValue($0) } ?? .null]
    if let keys { o["keys"] = JSONValue(keys) }
    if let makes { o["makes"] = .string(makes) }
    if let successor { o["successor"] = .bool(successor) }
    if let moves { o["moves"] = .bool(moves) }
    return .object(o)
  }

  init(kind: String, cmd: Int?, keys: [String]?, makes: String?, successor: Bool?, moves: Bool?) {
    self.kind = kind
    self.cmd = cmd
    self.keys = keys
    self.makes = makes
    self.successor = successor
    self.moves = moves
  }

  init(json: JSONValue) {
    kind = json["kind"]?.string ?? ""
    cmd = json["cmd"]?.int
    keys = json["keys"]?.array?.compactMap(\.string)
    makes = json["makes"]?.string
    successor = json["successor"]?.bool
    moves = json["moves"]?.bool
  }
}

public struct ChromeTabsMemory: Sendable, Equatable {
  public var mirror = OrderedDict<Int, StripState>()
  public var lastRev = -1
  public var seen = OrderedSet<String>()
  public var inflight = OrderedDict<Int, Inflight>()
  public var groups = OrderedDict<String, String>()
  public var tried = OrderedDict<String, Tried>()
  public var changedAt = OrderedDict<Int, Int>()
  public var madeInFront = OrderedDict<Int, MadeInFront>()
  public var lastCommand = 0

  public struct Tried: Sendable, Equatable {
    public var sig: String
    public var since: Int
  }

  public struct MadeInFront: Sendable, Equatable {
    public var browser: Int
    public var over: String?
  }

  public init() {}

  public init(json: JSONValue?) {
    for s in json?["strips"]?.array ?? [] {
      let strip = StripState(json: s)
      mirror[strip.strip] = strip
    }
    lastRev = json?["lastRev"]?.int ?? -1
    seen = OrderedSet(json?["seen"]?.array?.compactMap(\.string) ?? [])
    for (k, v) in json?["inflight"]?.object ?? [:] { if let strip = Int(k) { inflight[strip] = Inflight(json: v) } }
    for (k, v) in json?["groups"]?.object ?? [:] { if let id = v.string { groups[k] = id } }
    for (k, v) in json?["tried"]?.object ?? [:] { tried[k] = Tried(sig: v["sig"]?.string ?? "", since: v["since"]?.int ?? 0) }
    for (k, v) in json?["changedAt"]?.object ?? [:] { if let strip = Int(k), let rev = v.int { changedAt[strip] = rev } }
    for (k, v) in json?["madeInFront"]?.object ?? [:] {
      if let strip = Int(k) { madeInFront[strip] = MadeInFront(browser: v["browser"]?.int ?? 0, over: v["over"]?.string) }
    }
    lastCommand = json?["lastCommand"]?.int ?? 0
  }

  public var json: JSONValue {
    var inflightJSON = JSONObject()
    for (k, v) in inflight { inflightJSON[String(k)] = v.json }
    var groupsJSON = JSONObject()
    for (k, v) in groups { groupsJSON[k] = .string(v) }
    var triedJSON = JSONObject()
    for (k, v) in tried { triedJSON[k] = ["sig": .string(v.sig), "since": JSONValue(v.since)] }
    var changedJSON = JSONObject()
    for (k, v) in changedAt { changedJSON[String(k)] = JSONValue(v) }
    var madeJSON = JSONObject()
    for (k, v) in madeInFront { madeJSON[String(k)] = ["browser": JSONValue(v.browser), "over": JSONValue(v.over)] }
    return [
      "strips": .array(mirror.values.map(\.json)), "lastRev": JSONValue(lastRev), "seen": JSONValue(seen.elements), "inflight": .object(inflightJSON),
      "groups": .object(groupsJSON), "tried": .object(triedJSON), "changedAt": .object(changedJSON), "madeInFront": .object(madeJSON),
      "lastCommand": JSONValue(lastCommand),
    ]
  }
}

struct Pending {
  var arranged: Set<String> = []
  var grouped: Set<String>? = nil
  var regrouped: Set<String>? = nil
  var active = false
}

let chromeColors: Set<String> = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
func chromeColor(_ color: String?) -> String { color.flatMap { chromeColors.contains($0) ? $0 : nil } ?? "grey" }
func reportsGroups(_ strip: StripState) -> Bool { strip.tabs.contains { $0.group != nil } }

struct StripPlan {
  var keys: [String]
  var pinned: Int
  var active: String?
}

extension Session {
  func known(_ s: BrowserState, _ t: StripTab?) -> Bool {
    guard let key = t?.key, !key.isEmpty, s.tabs[key] != nil else { return false }
    return !isPeekTab(s, key)
  }

  func chromeGroupOf(_ s: BrowserState, _ key: String?) -> TabGroup? {
    guard let g = groupOf(s, key) else { return nil }
    return Groups.rootOf(s.groups, g.id)
  }

  func madeByChrome(_ s: BrowserState, _ key: String) -> Bool { s.tabs[key]?.adoptId?.hasPrefix("tab:") == true }

  func chromeChanged(_ input: BrowserState, _ before: StripState?, _ after: StripState, seen: OrderedSet<String>, siblings: [StripState],
    pending: Pending, groups: inout OrderedDict<String, String>) -> BrowserState
  {
    var s = input
    var was: [Int: StripTab] = [:]
    for t in before?.tabs ?? [] { was[t.browser] = t }
    let now = after.tabs.filter { known(s, $0) }
    func stayed(_ t: StripTab) -> Bool { was[t.browser]?.key == t.key }
    func firstFromChrome(_ t: StripTab) -> Bool { !stayed(t) && !seen.contains(t.key!) && madeByChrome(s, t.key!) }
    let home = homeWindow(s, after, siblings, stayed)
    func movedIn(_ t: StripTab) -> Bool {
      guard was[t.browser] == nil, let home, let tab = s.tabs[t.key!] else { return false }
      return tab.windowId != home && s.engineProfile(tab.profileId) == after.profile
    }
    let taken = Set(now.filter { firstFromChrome($0) || movedIn($0) }.map { $0.key! })
    for t in now where movedIn(t) { s = intoWindow(s, t.key!, home!) }
    let followed = now.filter { (stayed($0) || taken.contains($0.key!)) && !pending.arranged.contains($0.key!) }
    func weight(_ t: StripTab) -> Int { groupOf(s, t.key) != nil ? 2 : 1 }
    let keptFollowed = keptOrder(followed.filter(stayed), { was[$0.browser]!.index }, weight).map { $0.key! }
    let kept = OrderedSet(keptFollowed + Array(pending.arranged) + Array(pending.regrouped ?? []))
    var settled = kept
    func chromeGroup(_ t: StripTab) -> String?? {
      guard let token = t.group else { return nil }
      guard let token else { return .some(nil) }
      guard let id = groups[token], s.groups[id] != nil else { return nil }
      return .some(id)
    }
    for t in followed.reversed() {
      guard let tab = s.tabs[t.key!] else { continue }
      if tab.pinned != t.pinned && Splits.splitOf(s, t.key) != nil { continue }
      let pinFlip = tab.pinned != t.pinned && (taken.contains(t.key!) || was[t.browser]!.pinned != t.pinned)
      if kept.contains(t.key!) && !pinFlip { continue }
      s = placeLike(s, t.key!, pinFlip ? t.pinned : tab.pinned, now, settled, kept, chromeGroup(t))
      settled.insert(t.key!)
    }
    for t in followed {
      let want = chromeGroup(t)
      guard let want, let tab = s.tabs[t.key!], !tab.pinned, !t.pinned, !kept.contains(t.key!) else { continue }
      if chromeGroupOf(s, t.key)?.id != want { s = regroupInPlace(s, t.key!, want) }
    }
    if reportsGroups(after) {
      s = groupsChanged(s, before, after, now, { stayed($0) || taken.contains($0.key!) }, taken, &groups, pending)
    }
    if !pending.active {
      let active = after.tabs.first { $0.active }
      let previous = before?.tabs.first { $0.active }
      let left = after.activePickedOnClose ?? (previous != nil && !after.tabs.contains { $0.browser == previous!.browser })
      if known(s, active) && taken.contains(active!.key!) {
        s = show(s, active!.key!)
      } else if known(s, active) && stayed(active!) && active!.browser != previous?.browser && !left {
        s = show(s, active!.key!)
      } else if known(s, active) {
        if now.contains(where: { taken.contains($0.key!) && !$0.active && shownIn(s, $0.key!) }) { s = show(s, active!.key!) }
      }
    }
    return s
  }

  func shownIn(_ s: BrowserState, _ key: String) -> Bool {
    let tab = s.tabs[key]!
    return s.windows[tab.windowId]?.activeTabIds[tab.profileId] == key
  }

  func groupsChanged(_ input: BrowserState, _ before: StripState?, _ after: StripState, _ now: [StripTab], _ followed: (StripTab) -> Bool,
    _ taken: Set<String>, _ bound: inout OrderedDict<String, String>, _ pending: Pending) -> BrowserState
  {
    var s = input
    var was: [Int: String?] = [:]
    for t in before?.tabs ?? [] { was[t.browser] = t.group ?? nil }
    var looks = OrderedDict<String, StripGroup>()
    for g in after.groups ?? [] { looks[g.id] = g }
    var looksBefore: [String: StripGroup] = [:]
    for g in before?.groups ?? [] { looksBefore[g.id] = g }
    for t in now {
      guard let tab = s.tabs[t.key!], !tab.pinned, followed(t), !(pending.grouped?.contains(t.key!) ?? false) else { continue }
      let token: String? = t.group ?? nil
      if !taken.contains(t.key!), let previous = was[t.browser], previous == token { continue }
      let current = chromeGroupOf(s, t.key)
      guard let token else {
        if current != nil { s = regroupInPlace(s, t.key!, nil) }
        continue
      }
      if let id = bound[token], s.groups[id] != nil {
        if current?.id != id { s = regroupInPlace(s, t.key!, id) }
        continue
      }
      let members = now.filter { ($0.group ?? nil) == token && s.tabs[$0.key!] != nil && !s.tabs[$0.key!]!.pinned }.map { $0.key! }
      var o = GroupOptions()
      o.pinned = false
      o.name = looks[token]?.title ?? ""
      o.parentId = .some(nil)
      let (next, made) = withGroup(s, members, o)
      if made.isEmpty { continue }
      bound[token] = made
      s = withLook(next, made, looks[token])
    }
    for (token, look) in looks {
      guard let id = bound[token], let g = s.groups[id] else { continue }
      if let was = looksBefore[token], was.title == look.title, was.color == look.color, was.collapsed == look.collapsed { continue }
      if g.tabIds.contains(where: { pending.grouped?.contains($0) ?? false }) { continue }
      s = withLook(s, id, look)
    }
    return s
  }

  func regroupInPlace(_ s: BrowserState, _ key: String, _ groupId: String?) -> BrowserState {
    guard let w = s.windows[s.tabs[key]!.windowId] else { return s }
    let at = w.tabIds.jsIndexOf(key) + 1
    let beforeId: String? = at < w.tabIds.count ? w.tabIds[at] : nil
    return placing(s, [key], TabPlacement(pinned: false, beforeId: .some(beforeId), groupId: .some(groupId)))
  }

  func withLook(_ s: BrowserState, _ id: String, _ look: StripGroup?) -> BrowserState {
    guard var g = s.groups[id], let look else { return s }
    let color = look.color == chromeColor(g.color) ? g.color : look.color
    if g.name == look.title && g.color == color && g.collapsed == look.collapsed { return s }
    g.name = look.title
    g.color = color
    g.collapsed = look.collapsed
    var next = s
    next.groups[id] = g
    return next
  }

  func groupStep(_ s: BrowserState, _ strip: StripState, _ bound: OrderedDict<String, String>) -> JSONObject? {
    if !reportsGroups(strip) { return nil }
    let tabs = strip.tabs.filter { known(s, $0) && !$0.pinned && !s.tabs[$0.key!]!.pinned }
    var looks: [String: StripGroup] = [:]
    for g in strip.groups ?? [] { looks[g.id] = g }
    func tokenOf(_ id: String) -> String? { bound.first { $0.value == id && looks[$0.key] != nil }?.key }
    let strays = tabs.filter { t in
      guard let token = t.group ?? nil, !token.isEmpty else { return false }
      let mine = chromeGroupOf(s, t.key).flatMap { tokenOf($0.id) }
      return token != mine
    }
    if !strays.isEmpty { return ["keys": JSONValue(strays.map { $0.key! }), "group": .null] }
    var storeGroups: [TabGroup] = []
    for t in tabs { if let g = chromeGroupOf(s, t.key), !storeGroups.contains(where: { $0.id == g.id }) { storeGroups.append(g) } }
    for g in storeGroups {
      let keys = tabs.filter { chromeGroupOf(s, $0.key)?.id == g.id }.map { $0.key! }
      let token = tokenOf(g.id)
      let title = g.name
      let color = chromeColor(g.color)
      let collapsed = g.collapsed
      guard let token else {
        return ["keys": JSONValue(keys), "group": "new", "title": .string(title), "color": .string(color), "collapsed": .bool(collapsed), "makes": .string(g.id)]
      }
      let missing = tabs.filter { keys.contains($0.key!) && ($0.group ?? nil) != token }.map { $0.key! }
      if !missing.isEmpty { return ["keys": JSONValue(missing), "group": .string(token)] }
      let now = looks[token]!
      if now.title != title || now.color != color || now.collapsed != collapsed {
        return ["keys": JSONValue(keys), "group": .string(token), "title": .string(title), "color": .string(color), "collapsed": .bool(collapsed)]
      }
    }
    return nil
  }

  func homeWindow(_ s: BrowserState, _ strip: StripState, _ siblings: [StripState], _ stayed: (StripTab) -> Bool) -> String? {
    if let app = strip.appWindow, !app.isEmpty, s.windows[app] != nil { return app }
    let mine = strip.tabs.filter { known(s, $0) && stayed($0) }
    let other = siblings.flatMap(\.tabs).filter { known(s, $0) }
    guard let t = mine.first ?? other.first, let tab = s.tabs[t.key!], s.windows[tab.windowId] != nil else { return nil }
    return tab.windowId
  }

  func keptOrder<T>(_ items: [T], _ oldIndex: (T) -> Int, _ weight: (T) -> Int) -> [T] {
    var best: [Int] = []
    var back: [Int] = []
    var end = -1
    for (i, t) in items.enumerated() {
      best.append(weight(t))
      back.append(-1)
      for j in 0..<i where oldIndex(items[j]) < oldIndex(t) && best[j] + weight(t) > best[i] {
        best[i] = best[j] + weight(t)
        back[i] = j
      }
      if end < 0 || best[i] > best[end] { end = i }
    }
    var out: [T] = []
    var i = end
    while i >= 0 {
      out.append(items[i])
      i = back[i]
    }
    return out.reversed()
  }

  func placeLike(_ s: BrowserState, _ key: String, _ pinned: Bool, _ strip: [StripTab], _ settled: OrderedSet<String>, _ kept: OrderedSet<String>,
    _ group: String??) -> BrowserState
  {
    guard let w = s.windows[s.tabs[key]!.windowId] else { return s }
    let panes = Splits.splitOf(s, key)?.tabIds ?? [key]
    let moving = w.tabIds.filter { panes.contains($0) }
    let i = strip.firstIndex { $0.key == key } ?? -1
    func other(_ t: StripTab) -> Bool { s.tabs[t.key!] != nil && !panes.contains(t.key!) && s.tabs[t.key!]!.windowId == w.id }
    let next = strip.jsSliced(i + 1).first { other($0) && settled.contains($0.key!) }?.key
    let prior = strip.jsSliced(0, i).reversed().first { other($0) && kept.contains($0.key!) }?.key
    func rowStart(_ id: String) -> String { w.tabIds.first { Splits.splitOf(s, id)?.tabIds.contains($0) == true } ?? id }
    func rowAfter(_ id: String) -> String? {
      let row = Splits.splitOf(s, id)?.tabIds ?? [id]
      let last = JS.max(row.map { w.tabIds.jsIndexOf($0) })
      return w.tabIds.jsSliced(last + 1).first { !moving.contains($0) }
    }
    let beforeId: String?
    if let next {
      beforeId = rowStart(next)
    } else if let prior {
      beforeId = rowAfter(prior)
    } else {
      beforeId = w.tabIds.first { !moving.contains($0) }
    }
    let own = groupOf(s, key)?.id
    let around = [groupOf(s, prior)?.id, groupOf(s, next)?.id]
    let guessed: String? =
      around[0] != nil && around[0] == around[1] ? around[0] : (own != nil && around.contains(where: { $0 == own }) ? own : nil)
    let root = own.flatMap { Groups.rootOf(s.groups, $0) }
    if !pinned, beforeId == nil, let own, let root, root.id != own, case .some(.some(let wanted)) = group, root.id == wanted {
      let last = root.tabIds.filter { !moving.contains($0) }.last
      let groupId = last.map { s.groups[own]!.tabIds.contains($0) } == true ? own : root.id
      return placing(s, moving, TabPlacement(pinned: pinned, beforeId: .some(beforeId), groupId: .some(groupId)))
    }
    let wanted: String?
    switch group {
    case .some(let given): wanted = beforeId == nil ? nil : given
    case .none: wanted = guessed
    }
    let groupId: String?
    if pinned {
      groupId = nil
    } else if let own, let wantedId = wanted, wantedId != own, root?.id == wantedId, group != nil {
      groupId = own
    } else {
      groupId = wanted
    }
    return placing(s, moving, TabPlacement(pinned: pinned, beforeId: .some(beforeId), groupId: .some(groupId)))
  }

  func intoWindow(_ s: BrowserState, _ key: String, _ to: String) -> BrowserState {
    let tab = s.tabs[key]!
    if s.windows[to] == nil || tab.windowId == to { return s }
    var next = removeTabs(s, [key], record: false)
    guard let w = next.windows[to] else { return s }
    var moved = tab
    moved.windowId = to
    next.tabs[key] = moved
    var window = w
    window.tabIds = pinnedFirst(w.tabIds + [key], next.tabs, next.groups)
    next.windows[to] = window
    return settleMovedPins(s, next, [key], to)
  }

  func show(_ s: BrowserState, _ key: String) -> BrowserState {
    let tab = s.tabs[key]!
    guard let w = s.windows[tab.windowId], w.profileId == tab.profileId else { return s }
    let shown = w.activeTabIds[tab.profileId]
    if shown == key || (shown.flatMap { Splits.splitOf(s, $0)?.tabIds.contains(key) } ?? false) {
      return s.peeks[w.id] != nil ? withoutPeek(s, w.id) : s
    }
    var next = activated(s, key)
    if let shown, !shown.isEmpty, !switchKeepsOpeners(s, shown, key) { next = forgetOpeners(next, w.id) }
    return next
  }

  func stripPlan(_ s: BrowserState, _ strip: StripState) -> StripPlan? {
    let mine = strip.tabs.filter { known(s, $0) }
    if mine.isEmpty { return nil }
    let windowId = s.tabs[(mine.first { $0.active } ?? mine[0]).key!]!.windowId
    guard let w = s.windows[windowId] else { return nil }
    let inStrip = Set(mine.map { $0.key! })
    let keys = w.tabIds.filter { inStrip.contains($0) }
    let pinned = keys.filter { s.tabs[$0]!.pinned }
    let profiles = [w.profileId] + OrderedSet(keys.map { s.tabs[$0]!.profileId }).elements
    let peek = s.peeks[windowId]?.tabId
    let active: String? =
      peek.flatMap { p in strip.tabs.contains { $0.key == p } ? p : nil }
      ?? profiles.compactMap { w.activeTabIds[$0] }.first { !$0.isEmpty && inStrip.contains($0) }
    return StripPlan(keys: pinned + keys.filter { !s.tabs[$0]!.pinned }, pinned: pinned.count, active: active)
  }

  func stripActual(_ strip: StripState, _ plan: StripPlan) -> StripPlan {
    let planned = Set(plan.keys)
    let tabs = strip.tabs.filter { $0.key.map { planned.contains($0) } ?? false }
    return StripPlan(keys: tabs.map { $0.key! }, pinned: tabs.filter(\.pinned).count, active: strip.tabs.first { $0.active }?.key)
  }

  public func stripSnapshot(_ json: JSONValue) {
    var memo = memory.chromeTabs
    memo.inflight = OrderedDict()
    memo.tried = OrderedDict()
    memo.mirror = OrderedDict()
    for s in json["strips"]?.array ?? [] {
      let strip = StripState(json: s)
      memo.mirror[strip.strip] = strip
      for t in strip.tabs { if let key = t.key, !key.isEmpty { memo.seen.insert(key) } }
    }
    for strip in memo.changedAt.keys where memo.mirror[strip] == nil { memo.changedAt[strip] = nil }
    for strip in memo.madeInFront.keys where memo.mirror[strip] == nil { memo.madeInFront[strip] = nil }
    memo.lastRev = json["rev"]?.int ?? memo.lastRev
    memory.chromeTabs = memo
  }

  public func stripTransaction(_ tx: StripTransaction) {
    var memo = memory.chromeTabs
    if tx.rev <= memo.lastRev { return }
    memo.lastRev = tx.rev
    for (strip, f) in memo.inflight where f.cmd == tx.cmd {
      memo.inflight[strip] = nil
      if let makes = f.makes, let first = f.keys?.first,
        let made = tx.strips.first(where: { $0.strip == strip })?.tabs.first(where: { $0.key == first })?.group ?? nil, !made.isEmpty
      {
        memo.groups[made] = makes
      }
    }
    let start = state
    var s = start
    var changed = false
    for strip in tx.strips {
      let before = memo.mirror[strip.strip]
      if strip.closed == true {
        memo.mirror[strip.strip] = nil
        memo.madeInFront[strip.strip] = nil
      } else {
        memo.mirror[strip.strip] = strip
      }
      if tx.cmd == nil || tx.cmd! < 0 { memo.changedAt[strip.strip] = tx.rev }
      if tx.cmd == nil {
        let waiting = memo.inflight[strip.strip]
        let siblings = memo.mirror.values.filter { $0.window == strip.window && $0.strip != strip.strip }
        if let made = strip.tabs.first(where: { t in t.active && (t.key ?? "").isEmpty && !(before?.tabs.contains { $0.browser == t.browser } ?? false) }) {
          memo.madeInFront[strip.strip] = ChromeTabsMemory.MadeInFront(browser: made.browser, over: stripPlan(s, strip)?.active)
        }
        var pending = Pending()
        pending.arranged = Set(waiting?.kind == "arrange" ? waiting?.keys ?? [] : [])
        pending.regrouped = Set(waiting?.kind == "group" && waiting?.moves == true ? waiting?.keys ?? [] : [])
        pending.grouped = Set(waiting?.kind == "group" ? waiting?.keys ?? [] : [])
        pending.active = waiting?.kind == "activate" && waiting?.successor != true
        let seen = memo.seen
        var groups = memo.groups
        let next = chromeChanged(s, before, strip, seen: seen, siblings: siblings, pending: pending, groups: &groups)
        memo.groups = groups
        if !sameRef(next, s) { changed = true }
        s = next
      }
      for t in strip.tabs { if let key = t.key, !key.isEmpty { memo.seen.insert(key) } }
    }
    if memo.seen.count > 2 * s.tabs.count + 64 {
      for key in memo.seen.elements where s.tabs[key] == nil { memo.seen.remove(key) }
    }
    memory.chromeTabs = memo
    if changed { set(s) }
  }

  func sentAlready(_ memo: ChromeTabsMemory, _ strip: Int, _ kind: String, _ sig: String) -> Bool {
    guard let last = memo.tried["\(strip):\(kind)"] else { return false }
    return last.sig == sig && last.since == (memo.changedAt[strip] ?? 0)
  }

  func send(_ memo: inout ChromeTabsMemory, _ strip: Int, _ kind: String, _ sig: String, _ command: JSONObject, makes: String? = nil,
    successor: Bool? = nil, moves: Bool? = nil)
  {
    if sentAlready(memo, strip, kind, sig) { return }
    memo.tried["\(strip):\(kind)"] = ChromeTabsMemory.Tried(sig: sig, since: memo.changedAt[strip] ?? 0)
    let keys = command["op"] != "activate" ? command["keys"]?.array?.compactMap(\.string) : nil
    memo.lastCommand += 1
    memo.inflight[strip] = Inflight(kind: kind, cmd: memo.lastCommand, keys: keys, makes: makes, successor: successor, moves: moves)
    emit(.stripCommand(strip: strip, id: memo.lastCommand, command: .object(command)))
  }

  public func projectStrips() {
    var memo = memory.chromeTabs
    if memo.lastRev < 0 { return }
    let s = state
    for strip in memo.mirror.values {
      if memo.inflight[strip.strip] != nil { continue }
      guard let plan = stripPlan(s, strip) else { continue }
      let actual = stripActual(strip, plan)
      let order = "\(plan.keys.joined(separator: ","))|\(plan.pinned)"
      let made = memo.madeInFront[strip.strip]
      let unadopted = made != nil && plan.active == made!.over && strip.tabs.contains { $0.browser == made!.browser && $0.active && ($0.key ?? "").isEmpty }
      if made != nil && !unadopted { memo.madeInFront[strip.strip] = nil }
      let step = groupStep(s, strip, memo.groups)
      func group() {
        var rest = step!
        let makes = rest.removeValue(forKey: "makes")?.string
        let moves = rest["group"]!.isNull || rest["group"] == "new" || rest["title"] == nil
        var command: JSONObject = ["op": "group", "strip": JSONValue(strip.strip)]
        for (k, v) in rest { command[k] = v }
        send(&memo, strip.strip, "group", JSONValue.object(step!).text(), command, makes: makes, moves: moves)
      }
      if let active = plan.active, active != actual.active, !unadopted {
        let successor = actual.active.map { s.tabs[$0] == nil } ?? false
        send(&memo, strip.strip, "activate", active, ["op": "activate", "strip": JSONValue(strip.strip), "key": .string(active)], successor: successor)
      } else if let step, step["group"]!.isNull, !sentAlready(memo, strip.strip, "group", JSONValue.object(step).text()) {
        group()
      } else if order != "\(actual.keys.joined(separator: ","))|\(actual.pinned)" {
        send(
          &memo, strip.strip, "arrange", order,
          ["op": "arrange", "strip": JSONValue(strip.strip), "keys": JSONValue(plan.keys), "pinned": JSONValue(plan.pinned)])
      } else if step != nil {
        group()
      }
    }
    memory.chromeTabs = memo
  }

  public func stripCommandSent(_ strip: Int, _ cmd: Int) {
    guard var f = memory.chromeTabs.inflight[strip], f.cmd == nil else { return }
    f.cmd = cmd
    memory.chromeTabs.inflight[strip] = f
  }
}
