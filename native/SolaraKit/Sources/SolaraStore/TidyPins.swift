import SolaraModel

struct TidyPlan {
  var closes: [(tabId: String, keeperId: String)] = []
  var files: [(tabId: String, groupId: String)] = []
  var newGroups: [(tabIds: [String], name: String)] = []
}

public struct TidiedPins: Sendable, Equatable {
  public var windowId: String
  public var order: [String]
  public var homes: JSMap<String?>
  public var closed: [ClosedTab]
  public var pins: Int
  public var folders: Int
  public var duplicates: Int

  public var json: JSONValue {
    var homesJSON = JSONObject()
    for (k, v) in homes { homesJSON[k] = JSONValue(v) }
    return [
      "windowId": .string(windowId), "order": JSONValue(order), "homes": .object(homesJSON), "closed": .array(closed.map(\.jsonValue)),
      "pins": JSONValue(pins), "folders": JSONValue(folders), "duplicates": JSONValue(duplicates),
    ]
  }

  public init(json: JSONValue) throws {
    windowId = json["windowId"]?.string ?? ""
    order = json["order"]?.array?.compactMap(\.string) ?? []
    var homes = JSMap<String?>()
    for (k, v) in json["homes"]?.object ?? [:] { homes[k] = v.string }
    self.homes = homes
    closed = try (json["closed"]?.array ?? []).map { try ClosedTab(value: $0) }
    pins = json["pins"]?.int ?? 0
    folders = json["folders"]?.int ?? 0
    duplicates = json["duplicates"]?.int ?? 0
  }

  init(windowId: String, order: [String], homes: JSMap<String?>, closed: [ClosedTab], pins: Int, folders: Int, duplicates: Int) {
    self.windowId = windowId
    self.order = order
    self.homes = homes
    self.closed = closed
    self.pins = pins
    self.folders = folders
    self.duplicates = duplicates
  }
}

extension Session {
  func foldersOf(_ s: BrowserState, _ order: [String], _ windowId: String, _ profileId: String) -> [TabGroup] {
    let at = Groups.positions(order)
    let mine = s.groups.values.filter { $0.pinned && $0.windowId == windowId && $0.profileId == profileId && !$0.tabIds.isEmpty }
    var ranked: [(group: TabGroup, top: Int, depth: Int)] = []
    for g in mine {
      let tops: [Int] = g.tabIds.map { at[$0] ?? JS.positiveInfinity }
      ranked.append((g, tops.min() ?? JS.positiveInfinity, Groups.depthOf(s.groups, g.id)))
    }
    let sorted = ranked.stableSorted { a, z in a.top != z.top ? a.top < z.top : a.depth < z.depth }
    return sorted.map(\.group)
  }

  func folderSites(_ s: BrowserState, _ g: TabGroup) -> [String] {
    let direct = g.tabIds.filter { Groups.innermostGroupOf(s.groups, $0)?.id == g.id && s.tabs[$0] != nil }
    var counts = OrderedDict<String, Int>()
    for id in direct {
      let site = siteKey(homeOf(s.tabs[id]!))
      if !site.isEmpty { counts[site] = (counts[site] ?? 0) + 1 }
    }
    let most = max(0, counts.values.max() ?? 0)
    if most == 0 || most * 2 < direct.count { return [] }
    return counts.filter { $0.value == most }.map(\.key)
  }

  func tidyPlan(_ s: BrowserState, _ windowId: String, _ profileId: String?) -> TidyPlan? {
    guard let w = s.windows[windowId], !w.incognito, !w.isSmall else { return nil }
    let profile = profileId ?? w.profileId
    let order = w.tabIds.filter { s.tabs[$0]?.profileId == profile }
    let rows = order.filter { s.tabs[$0]?.isPinnedRow == true }
    if rows.isEmpty { return nil }
    let folders = foldersOf(s, order, w.id, profile)
    let filed = OrderedSet(folders.flatMap(\.tabIds)).elements.compactMap { s.tabs[$0] }
    var plan = TidyPlan()
    var kept: [Tab] = []
    for id in rows {
      let t = s.tabs[id]!
      let home = homeOf(t)
      let inSplitRow = Splits.splitRowPanes(s, Splits.splitOf(s, id)).contains(id)
      let twin: Tab? =
        !home.isEmpty && !inSplitRow
        ? (filed.first { !homeOf($0).isEmpty && samePage(homeOf($0), home) } ?? kept.first { samePage(homeOf($0), home) }) : nil
      if let twin { plan.closes.append((id, twin.id)) } else { kept.append(t) }
    }
    var folderFor = OrderedDict<String, String>()
    for g in folders { for site in folderSites(s, g) where folderFor[site] == nil { folderFor[site] = g.id } }
    var loose = OrderedDict<String, [Tab]>()
    for t in kept {
      let site = siteKey(homeOf(t))
      if site.isEmpty { continue }
      if let groupId = folderFor[site] { plan.files.append((t.id, groupId)) } else { loose[site, default: []].append(t) }
    }
    plan.newGroups = loose.values.filter { $0.count >= 2 }.map { same in
      (same.map(\.id), siteName(same.map { (url: homeOf($0), title: $0.title) }))
    }
    return plan.closes.isEmpty && plan.files.isEmpty && plan.newGroups.isEmpty ? nil : plan
  }

  func tidyingPins(_ s: BrowserState, _ windowId: String, _ profileId: String?) -> (BrowserState, TidiedPins?) {
    guard let plan = tidyPlan(s, windowId, profileId), let w = s.windows[windowId] else { return (s, nil) }
    var homes = JSMap<String?>()
    for id in Splits.withSplitRows(s, plan.files.map(\.tabId) + plan.newGroups.flatMap(\.tabIds)) { homes[id] = s.tabs[id]!.pinnedUrl }
    var next = s
    var closed: [ClosedTab] = []
    if !plan.closes.isEmpty {
      let ids = OrderedSet(plan.closes.map(\.tabId))
      let shown = s.activeTabId(windowId)
      next = removeTabs(next, ids.elements, record: true)
      let before = Set(s.closedTabs.map(\.id))
      closed = next.closedTabs.filter { !before.contains($0.id) && truthy($0.tabId) && ids.contains($0.tabId!) }
      let keeper = shown.flatMap { id in ids.contains(id) ? plan.closes.first { $0.tabId == id }!.keeperId : nil }
      if let keeper, next.tabs[keeper] != nil { next = activated(next, keeper) }
    }
    for f in plan.files { next = placing(next, [f.tabId], TabPlacement(pinned: false, groupId: .some(f.groupId))) }
    for g in plan.newGroups { next = withRowsGrouped(next, g.tabIds, name: g.name, pinned: true).0 }
    let folders = Set(plan.files.map(\.groupId)).count + plan.newGroups.count
    return (next, TidiedPins(windowId: windowId, order: w.tabIds, homes: homes, closed: closed, pins: homes.count, folders: folders, duplicates: plan.closes.count))
  }

  func untidyingPins(_ s: BrowserState, _ tidied: TidiedPins) -> BrowserState {
    guard let w = s.windows[tidied.windowId] else { return s }
    let gone = Set(tidied.closed.map(\.id))
    var next = s
    next.closedTabs = s.closedTabs.filter { !gone.contains($0.id) }
    var now = OrderedDict<String, String>()
    for id in tidied.homes.keys where next.tabs[id]?.windowId == w.id { now[id] = id }
    let back = tidied.closed.filter { next.tabs[$0.tabId ?? ""] == nil }
    let (restored, ids) = restoreSnapshots(next, w.id, back.map { SnapshotEntry(tab: $0.tab, tabId: $0.restoreFrom ?? $0.tabId, index: $0.index, shownAt: $0.shownAt) })
    next = restored
    for (i, e) in back.enumerated() where i < ids.count && !ids[i].isEmpty && truthy(e.tabId) { now[e.tabId!] = ids[i] }
    func inWindow(_ id: String) -> Bool { next.tabs[id]?.windowId == w.id }
    let returning = tidied.order.filter { now[$0] != nil }.reversed()
    var placed = Set<String>()
    for id in returning {
      let tabId = now[id]!
      if placed.contains(tabId) { continue }
      let block = Set(Splits.withSplitRows(next, [tabId]))
      let later = tidied.order.jsSliced(tidied.order.jsIndexOf(id) + 1).map { now[$0] ?? $0 }
      let beforeId = later.first { inWindow($0) && !block.contains($0) }
      next = placing(next, [tabId], TabPlacement(pinned: true, row: true, beforeId: .some(beforeId), last: beforeId == nil))
      placed.formUnion(block)
    }
    for (id, tabId) in now {
      if let home = tidied.homes[id] ?? nil, !home.isEmpty, next.tabs[tabId] != nil {
        var t = next.tabs[tabId]!
        t.pinnedUrl = home
        next.tabs[tabId] = t
      }
    }
    return next
  }
}
