import SolaraModel

public struct TabPlacement: Sendable {
  public var pinned: Bool
  public var row: Bool?
  public var beforeId: String??
  public var groupId: String??
  public var last: Bool?
  public var tileFolder: TileFolder??

  public init(pinned: Bool, row: Bool? = nil, beforeId: String?? = nil, groupId: String?? = nil, last: Bool? = nil, tileFolder: TileFolder?? = nil) {
    self.pinned = pinned
    self.row = row
    self.beforeId = beforeId
    self.groupId = groupId
    self.last = last
    self.tileFolder = tileFolder
  }

  var before: String? { beforeId.flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 } }
  var group: String? { groupId.flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 } }
}

public struct GroupPlacement: Sendable {
  public var pinned: Bool
  public var beforeId: String?
  public var parentId: String?

  public init(pinned: Bool, beforeId: String? = nil, parentId: String? = nil) {
    self.pinned = pinned
    self.beforeId = beforeId
    self.parentId = parentId
  }
}

func groupChoiceKey(_ key: String) -> String { "group:\(key)" }
func placeChoiceKey(_ key: String) -> String { "place:\(key)" }
func orderChoiceKey(_ key: String) -> String { "order:\(key)" }

let cleanUpAfterMs: Double = 12 * 60 * 60 * 1000
let duplicateIdleForMs: Double = 60 * 60 * 1000
let maxCleaned = 100
let maxClosedGroups = 20
let purgedAfterMs: Double = 7 * 86_400_000

func keptAWeek<T>(_ list: [T], _ now: Double, _ closedAt: (T) -> Double) -> [T] {
  list.filter { now - closedAt($0) < purgedAfterMs }
}

func livePinTable<V: Sendable & Equatable>(_ table: Table<JSMap<V>>, _ s: BrowserState) -> Table<JSMap<V>> {
  let profiles = table.keys
  if profiles.isEmpty { return table }
  var pinned: [String: Set<String>] = [:]
  func add(_ profileId: String, _ key: String) { pinned[profileId, default: []].insert(key) }
  var members = Set<String>()
  for g in s.groups.values where g.pinned {
    add(g.profileId, groupChoiceKey(g.pinKeyOrId))
    add(g.profileId, orderChoiceKey(g.pinKeyOrId))
    members.formUnion(g.tabIds)
  }
  for t in s.tabs.values where t.pinned || members.contains(t.id) {
    add(t.profileId, t.pinKeyOrId)
    add(t.profileId, placeChoiceKey(t.pinKeyOrId))
  }
  for (profileId, park) in s.parkedPins {
    for p in park.tabs {
      add(profileId, p.id)
      add(profileId, placeChoiceKey(p.id))
    }
    for g in park.groups {
      add(profileId, groupChoiceKey(g.id))
      add(profileId, orderChoiceKey(g.id))
    }
  }
  var changed = false
  var out = JSMap<JSMap<V>>()
  for profileId in profiles {
    let mine = table[profileId]!
    let keys = s.profiles[profileId] != nil ? pinned[profileId] : nil
    let kept = mine.filter { key, _ in keys?.contains(key) ?? false }
    let n = kept.count
    if n == 0 || n != mine.count { changed = true }
    if n > 0 { out[profileId] = n == mine.count ? mine : kept }
  }
  if !changed { return table }
  var result = table
  result.replace(with: out)
  return result
}

extension Session {
  func hostOf(_ url: String) -> String {
    guard let host = env.parseURL(url)?.hostname else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  func isSiteMuted(_ s: BrowserState, _ tab: Tab, _ host: String) -> Bool {
    let own = Ids.isIncognitoProfile(tab.profileId) ? s.privateSiteMutes[tab.windowId]?[host] : nil
    return own ?? (s.settings.strings("mutedSites") ?? []).contains(host)
  }

  struct UrlChange {
    var muted: Bool?
    var pinnedUrl: String?
  }

  func onUrlChange(_ s: BrowserState, _ tab: Tab, _ url: String) -> UrlChange {
    var patch = UrlChange()
    let before = hostOf(tab.url)
    let after = hostOf(url)
    if before != after {
      if isSiteMuted(s, tab, after) {
        patch.muted = true
      } else if isSiteMuted(s, tab, before) {
        patch.muted = false
      }
    }
    if !truthy(tab.pinnedUrl) && !url.isEmpty && s.inPinnedContainer(tab.id) { patch.pinnedUrl = url }
    return patch
  }

  func isClosedPin(_ s: BrowserState, _ id: String) -> Bool {
    guard let t = s.tabs[id], s.inPinnedContainer(id), t.pinSection != .tile else { return false }
    return !hasPage(t) && s.activeTabId(t.windowId) != id && holderOf(s, id) == nil
  }

  func unpinnedTabIds(_ s: BrowserState, _ windowId: String) -> [String] {
    s.viewTabIds(windowId).filter { !s.inPinnedContainer($0) }
  }

  func clearedTabIds(_ s: BrowserState, _ windowId: String) -> [String] {
    let ids = unpinnedTabIds(s, windowId)
    let active = s.activeTabId(windowId)
    var kept = OrderedSet(ids.filter { $0 == active || s.live[$0]?.playingAudio == true })
    for id in kept.elements { for pane in Splits.splitOf(s, id)?.tabIds ?? [] { kept.insert(pane) } }
    return ids.filter { !kept.contains($0) }
  }

  func groupLabel(_ s: BrowserState, _ g: TabGroup) -> String {
    if !g.name.isEmpty { return g.name }
    let members = g.tabIds.compactMap { s.tabs[$0] }.filter { !$0.url.isEmpty }
    let label = autoGroupName(members.map { (url: $0.url, title: $0.title) })
    return label.isEmpty ? "New Group" : label
  }

  func groupWithOpener(_ s: BrowserState, _ tabId: String, _ openerId: String, background: Bool) -> BrowserState {
    guard let tab = s.tabs[tabId], let opener = s.tabs[openerId], opener.windowId == tab.windowId, opener.profileId == tab.profileId else { return s }
    let w = s.windows[tab.windowId]!
    if s.inPinnedContainer(openerId) {
      if let gathered = pinnedChildGroup(s, openerId, tab.profileId) { return joinGroup(s, w, gathered, tabId) }
      if !background || !s.settings.bool("cmdClickCreatesTabGroup") { return s }
      var o = GroupOptions()
      o.autoUngroup = true
      o.pinnedOpenerId = openerId
      return withGroup(s, [tabId], o).0
    }
    let existing = groupOf(s, openerId)
    if existing == nil && !(background && s.settings.bool("cmdClickCreatesTabGroup")) { return s }
    if let existing { return joinGroup(s, w, existing, tabId) }
    let panes = s.splits.values.first { $0.tabIds.contains(openerId) }?.tabIds ?? [openerId]
    var o = GroupOptions()
    o.autoUngroup = true
    return withGroup(s, panes + [tabId], o).0
  }

  func joinGroup(_ s: BrowserState, _ w: BrowserWindow, _ group: TabGroup, _ tabId: String) -> BrowserState {
    let members = group.tabIds + [tabId]
    var window = w
    window.tabIds = Groups.placeBlock(w.tabIds, w.tabIds.filter { members.contains($0) })
    var g = group
    g.tabIds = window.tabIds.filter { members.contains($0) }
    var next = s
    next.groups[group.id] = g
    next.windows[w.id] = window
    return next
  }

  public struct GroupOptions: Sendable {
    public var name: String?
    public var pinned: Bool?
    public var autoUngroup: Bool?
    public var pinnedOpenerId: String?
    public var parentId: String??
    public init() {}
  }

  func withGroup(_ s: BrowserState, _ ids: [String], _ o: GroupOptions = GroupOptions()) -> (BrowserState, String) {
    let tabs = Splits.withSplitRows(s, ids).compactMap { s.tabs[$0] }.filter { !$0.pinned }
    guard let first = tabs.first, !tabs.contains(where: { $0.windowId != first.windowId || $0.profileId != first.profileId }) else { return (s, "") }
    let w = s.windows[first.windowId]!
    let members = OrderedSet(tabs.map(\.id))
    let asked = o.parentId.flatMap { $0 }.flatMap { $0.isEmpty ? nil : s.groups[$0] }
    let container: TabGroup?
    switch o.parentId {
    case .none: container = Groups.commonGroup(s.groups, members.elements)
    case .some: container = asked.flatMap { $0.windowId == w.id && $0.profileId == first.profileId ? $0 : nil }
    }
    let keep = Set(container.map { [$0.id] + Groups.ancestorIds(s.groups, $0.id) } ?? [])
    var tabIds = Groups.placeBlock(w.tabIds, w.tabIds.filter { members.contains($0) })
    var group = TabGroup(
      id: newId("g"), windowId: w.id, profileId: first.profileId, name: o.name ?? "", icon: nil, color: nil, collapsed: false,
      pinned: container?.pinned ?? (o.pinned ?? false), tabIds: tabIds.filter { members.contains($0) }, createdAt: now)
    if o.autoUngroup == true { group.autoUngroup = true }
    if truthy(o.pinnedOpenerId) { group.pinnedOpenerId = o.pinnedOpenerId }
    if let container { group.parentId = container.id }
    var left = Groups.leaveGroups(s.groups, Set(members.elements), keep: keep)
    left[group.id] = group
    let groups = Groups.nestGroups(left)
    tabIds = Groups.orderSections(Groups.placeGroups(tabIds, groups, w.id), s.tabs, groups)
    var window = w
    window.tabIds = tabIds
    var next = s
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[w.id] = window
    return (next, group.id)
  }

  func withRowsGrouped(_ s: BrowserState, _ asked: [String], name: String?, pinned: Bool?) -> (BrowserState, String) {
    let ids = Splits.withSplitRows(s, asked)
    let rows = ids.filter { s.tabs[$0]?.isPinnedRow == true }
    var o = GroupOptions()
    o.name = name
    o.pinned = pinned
    if rows.isEmpty { return withGroup(s, ids, o) }
    var unrowed = s
    for id in rows {
      var t = unrowed.tabs[id]!
      t.pinnedAsRow = nil
      t.pinned = false
      unrowed.tabs[id] = t
    }
    o.pinned = true
    let (next, id) = withGroup(unrowed, ids, o)
    guard let g = next.groups[id] else { return (s, "") }
    if Ids.isIncognitoProfile(g.profileId) { return (next, id) }
    var mine = next.pinChoices[g.profileId] ?? JSMap()
    mine[groupChoiceKey(g.pinKeyOrId)] = nextPinChoice()
    for tabId in g.tabIds { mine[placeChoiceKey(next.tabs[tabId]?.pinKeyOrId ?? tabId)] = nextPinChoice() }
    var out = next
    out.pinChoices[g.profileId] = mine
    return (out, id)
  }

  func windowFingerprint(_ s: BrowserState, _ windowId: String) -> String {
    guard let w = s.windows[windowId] else { return "" }
    func inWindow(_ id: String) -> Bool { s.tabs[id]?.windowId == windowId }
    let tabs = w.tabIds.map { id -> String in
      guard let t = s.tabs[id] else { return id }
      let section: String
      switch t.pinSection {
      case .tile: section = "tile"
      case .row: section = "row"
      case .none: section = "none"
      }
      return [id, t.profileId, section, t.tileFolder?.id ?? ""].joined(separator: " ")
    }
    let groups = s.groups.values.filter { $0.windowId == windowId }.map { g in
      [g.id, g.parentId ?? "", g.pinned ? "true" : "false", g.tabIds.joined(separator: ",")].joined(separator: " ")
    }.jsSortedStrings()
    let splits = s.splits.values.filter { $0.tabIds.contains(where: inWindow) }.map { $0.tabIds.joined(separator: ",") }.jsSortedStrings()
    return (tabs + [""] + groups + [""] + splits).joined(separator: "\n")
  }

  func closedEntries(_ s: BrowserState, _ ids: [String]) -> [ClosedTab] {
    ids.compactMap { s.tabs[$0] }.filter { !$0.url.isEmpty }.map { t in
      let group = groupOf(s, t.id)
      let parents = group.map { g in Groups.ancestorIds(s.groups, g.id).map { Groups.closedGroupInfo(s.groups[$0]!) } } ?? []
      return ClosedTab(
        id: newId("ct"), tab: snapshotTab(t), tabId: t.id, restoreFrom: pendingRestore(t), windowId: t.windowId,
        index: s.windows[t.windowId].map { $0.tabIds.jsIndexOf(t.id) } ?? 0, group: group.map(Groups.closedGroupInfo),
        parents: parents.isEmpty ? nil : parents, closedAt: now)
    }
  }

  func closeQuietly(_ input: BrowserState, _ ids: [String]) -> BrowserState {
    var s = input
    for w in input.windows.values {
      let view = s.viewTabIds(w.id)
      if !view.isEmpty && view.allSatisfy({ ids.contains($0) }) { s = withNewTab(s, w.id).0 }
    }
    return removeTabs(s, ids, record: false)
  }

  func showAboveGroup(_ before: BrowserState, _ s: BrowserState, _ g: TabGroup) -> BrowserState {
    guard let w = s.windows[g.windowId], let was = before.windows[g.windowId]?.activeTabIds[g.profileId], !was.isEmpty, g.tabIds.contains(was) else {
      return s
    }
    let order = before.viewTabIds(g.windowId, g.profileId).filter { !before.inPinnedContainer($0) }
    let at = order.jsIndexOf(g.tabIds[0])
    func stays(_ id: String) -> Bool { s.tabs[id] != nil && !g.tabIds.contains(id) && s.tabs[id]!.unloaded != true }
    guard let pick = order.jsSliced(0, at).reversed().first(where: stays) ?? order.jsSliced(at).first(where: stays) else { return s }
    if w.profileId == g.profileId { return activated(s, pick) }
    var next = s
    var window = w
    window.activeTabIds[g.profileId] = pick
    next.windows[w.id] = window
    return next
  }

  public func closingGroup(_ s: BrowserState, _ groupId: String, deleted: Bool = false) -> BrowserState {
    var g = s.groups[groupId]
    var p = g?.parentId.flatMap { s.groups[$0] }
    while let current = g, let parent = p, parent.tabIds.count == current.tabIds.count {
      g = parent
      p = parent.parentId.flatMap { s.groups[$0] }
    }
    guard let g, let w = s.windows[g.windowId] else { return s }
    let nested = nestedSnapshot(s, g)
    let entry = ClosedGroup(
      id: newId("cg"),
      group: {
        var head = ClosedGroupHead(id: g.id, name: groupLabel(s, g), icon: g.icon, color: g.color, pinned: g.pinned, parentId: g.parentId)
        head.absent = g.absent.intersection(lookKeys)
        return head
      }(),
      tabs: g.tabIds.map { snapshotTab(s.tabs[$0]!) }, tabIds: g.tabIds.map { pendingRestore(s.tabs[$0]!) ?? $0 },
      nested: nested.isEmpty ? nil : nested, windowId: w.id, index: w.tabIds.jsIndexOf(g.tabIds.first), closedAt: now)
    let recordable = !w.incognito && entry.tabs.contains { !$0.url.isEmpty }
    var next = showAboveGroup(s, closeQuietly(s, g.tabIds), g)
    if !recordable { return next }
    if deleted {
      next.deletedGroups = keptAWeek(next.deletedGroups, now, \.closedAt) + [entry]
    } else {
      next.closedGroups = Array((next.closedGroups + [entry]).suffix(maxClosedGroups))
    }
    return next
  }

  func nestedSnapshot(_ s: BrowserState, _ g: TabGroup) -> [NestedGroupSnapshot] {
    Groups.descendantIds(s.groups, g.id).map { id in
      let c = s.groups[id]!
      var snap = NestedGroupSnapshot(
        id: id, name: c.name, icon: c.icon, color: c.color, collapsed: c.collapsed, parentId: c.parentId ?? "",
        tabIndexes: c.tabIds.map { g.tabIds.jsIndexOf($0) }.filter { $0 >= 0 })
      snap.absent = c.absent.intersection(lookKeys)
      return snap
    }
  }

  func rebuildNested(_ s: BrowserState, _ rootId: String, _ rootKey: String, _ ids: [String], _ nested: [NestedGroupSnapshot]?) -> BrowserState {
    guard let root = s.groups[rootId], let nested, !nested.isEmpty else { return s }
    var made: [String: String] = [rootKey: rootId]
    var groups = s.groups
    groups.touch()
    for n in nested {
      let tabIds = n.tabIndexes.compactMap { i in i >= 0 && i < ids.count ? ids[i] : nil }.filter { !$0.isEmpty && s.tabs[$0] != nil }
      guard let parentId = made[n.parentId], !tabIds.isEmpty else { continue }
      let id = groups[n.id] != nil ? newId("g") : n.id
      made[n.id] = id
      var group = TabGroup(
        id: id, windowId: root.windowId, profileId: root.profileId, name: n.name, icon: n.icon, color: n.color, collapsed: n.collapsed,
        pinned: root.pinned, tabIds: tabIds, createdAt: now)
      group.setLook(icon: n.icon, color: n.color, absent: n.absent)
      group.parentId = parentId
      groups[id] = group
    }
    let settled = Groups.nestGroups(groups)
    let w = s.windows[root.windowId]!
    var window = w
    window.tabIds = Groups.placeGroups(w.tabIds, settled, w.id)
    var next = s
    next.groups = Groups.syncGroupOrder(settled, window)
    next.windows[w.id] = window
    return next
  }

  struct SnapshotEntry {
    var tab: TabSnapshot
    var tabId: String?
    var index: Int?
  }

  func restoreSnapshots(_ input: BrowserState, _ windowId: String, _ entries: [SnapshotEntry]) -> (BrowserState, [String]) {
    var s = input
    var ids: [String] = []
    let w = s.windows[windowId]!
    for e in entries {
      let profileId = s.profiles[e.tab.profileId] != nil || w.incognito ? e.tab.profileId : w.profileId
      var o = NewTabOptions()
      o.url = e.tab.url.isEmpty ? nil : e.tab.url
      o.profileId = profileId
      o.snapshot = TabPatch(e.tab)
      o.index = e.index
      o.background = true
      o.wakeAdoptId = truthy(e.tabId) && !e.tab.url.isEmpty ? restoreId(e.tabId!) : nil
      let (next, id) = withNewTab(s, windowId, o)
      s = next
      ids.append(id)
    }
    return (s, ids)
  }

  func regroupRestored(_ input: BrowserState, _ windowId: String, _ entries: [ClosedTab], _ ids: [String]) -> BrowserState {
    var s = input
    var byGroup = OrderedDict<String, (info: ClosedGroupInfo, members: [String])>()
    for (i, e) in entries.enumerated() {
      guard let group = e.group, i < ids.count, !ids[i].isEmpty else { continue }
      var g = byGroup[group.id] ?? (group, [])
      g.members.append(ids[i])
      byGroup[group.id] = g
    }
    var parentsOf: [String: [ClosedGroupInfo]] = [:]
    for e in entries {
      if let group = e.group, let parents = e.parents, !parents.isEmpty, parentsOf[group.id] == nil { parentsOf[group.id] = parents }
    }
    var made: [String: String] = [:]
    for (_, entry) in byGroup {
      let profileId = s.tabs[entry.members[0]]!.profileId
      s.groups = rejoinGroups(s.groups, [entry.info] + (parentsOf[entry.info.id] ?? []), entry.members, windowId, profileId, made: &made)
    }
    let groups = Groups.nestGroups(s.groups)
    let w = s.windows[windowId]!
    var window = w
    window.tabIds = Groups.placeGroups(w.tabIds, groups, windowId)
    s.windows[windowId] = window
    s.groups = Groups.syncGroupOrder(groups, window)
    return s
  }

  func restoreTarget(_ s: BrowserState, _ original: String, _ requested: String?) -> String? {
    func ok(_ id: String?) -> Bool {
      guard let id, !id.isEmpty, let w = s.windows[id] else { return false }
      return !w.incognito
    }
    if ok(original) { return original }
    if ok(requested) { return requested! }
    return s.ui.focusOrder.first(where: ok) ?? s.windowOrder.first(where: ok)
  }

  func atSavedIndex(_ s: BrowserState, _ windowId: String, _ block: [String], _ index: Int) -> BrowserState {
    guard let w = s.windows[windowId] else { return s }
    let members = Set(block)
    var rest = w.tabIds.filter { !members.contains($0) }
    Groups.insertAll(&rest, min(index, rest.count), block)
    var window = w
    window.tabIds = Groups.orderSections(rest, s.tabs, s.groups)
    var next = s
    next.windows[windowId] = window
    next.groups = Groups.syncGroupOrder(s.groups, window)
    return next
  }

  func restoringGroup(_ s: BrowserState, _ entry: ClosedGroup, _ requested: String?) -> BrowserState {
    guard let windowId = restoreTarget(s, entry.windowId, requested) else { return s }
    var next = s
    next.closedGroups = s.closedGroups.filter { $0.id != entry.id }
    next.deletedGroups = s.deletedGroups.filter { $0.id != entry.id }
    let index: Int? = windowId == entry.windowId ? entry.index : nil
    let entries = entry.tabs.enumerated().map { i, tab -> SnapshotEntry in
      var t = tab
      t.pinned = false
      let tabId = entry.tabIds.flatMap { i < $0.count ? $0[i] : nil }
      return SnapshotEntry(tab: t, tabId: tabId, index: index.map { $0 + i })
    }
    let (restored, ids) = restoreSnapshots(next, windowId, entries)
    next = restored
    let home = entry.group.parentId.flatMap { next.groups[$0] }
    let parent = home.flatMap { $0.windowId == windowId ? $0 : nil }
    var o = GroupOptions()
    o.name = entry.group.name
    o.pinned = entry.group.pinned
    o.parentId = .some(parent?.id)
    let (grouped, groupId) = withGroup(next, ids, o)
    next = grouped
    if !groupId.isEmpty, var g = next.groups[groupId] {
      g.setLook(icon: entry.group.icon, color: entry.group.color, absent: entry.group.absent)
      next.groups[groupId] = g
      next = rebuildNested(next, groupId, entry.group.id, ids, entry.nested)
      if let index, entry.group.pinned, parent == nil { next = atSavedIndex(next, windowId, next.groups[groupId]!.tabIds, index) }
    }
    if let first = ids.first, !first.isEmpty { return activated(next, first) }
    return next
  }

  func cleanUpCandidates(_ s: BrowserState, _ windowId: String, _ inactiveForMs: Double) -> [String] {
    let view = s.viewTabIds(windowId)
    let active = s.activeTabId(windowId)
    let grouped = Set(s.groups.values.flatMap(\.tabIds))
    let inSplit = Set(s.splits.values.flatMap(\.tabIds))
    func keep(_ t: Tab) -> Bool { t.id == active || s.inPinnedContainer(t.id) || s.live[t.id]?.playingAudio == true }
    let used = sharedLastUsed(s)
    let duplicateIdleFor = min(inactiveForMs, duplicateIdleForMs)
    var out = Set<String>()
    var byPage = OrderedDict<String, [Tab]>()
    for id in view {
      let t = s.tabs[id]!
      if t.url.isEmpty { continue }
      byPage[t.url.jsBeforeFirst("#"), default: []].append(t)
    }
    for same in byPage.values {
      if same.count < 2 { continue }
      let keeper = same.first { $0.pinned } ?? same.first { $0.id == active } ?? same.stableSorted { lastUsedOf(used, $0) > lastUsedOf(used, $1) }[0]
      for t in same where t.id != keeper.id && !keep(t) && !inSplit.contains(t.id) && now - lastUsedOf(used, t) >= duplicateIdleFor { out.insert(t.id) }
    }
    for id in view {
      let t = s.tabs[id]!
      if keep(t) || grouped.contains(id) || inSplit.contains(id) { continue }
      if now - lastUsedOf(used, t) >= inactiveForMs { out.insert(id) }
    }
    return view.filter { out.contains($0) }
  }

  func abandonedNewTabs(_ s: BrowserState, _ windowId: String) -> [String] {
    guard let w = s.windows[windowId] else { return [] }
    let selected = Set(w.activeTabIds.values)
    let shown = w.activeTabIds[w.profileId]
    let out = w.tabIds.filter { id in
      guard let t = s.tabs[id] else { return false }
      return t.windowId == w.id && t.url.isEmpty && t.navigation == nil && !truthy(t.adoptId) && !t.pinned && id != shown && !selected.contains(id)
    }
    return out.count >= w.tabIds.count ? Array(out.prefix(w.tabIds.count - 1)) : out
  }

  public func placing(_ s: BrowserState, _ ids: [String], _ p: TabPlacement) -> BrowserState {
    guard let first = s.tabs[ids.first ?? ""], let w = s.windows[first.windowId] else { return s }
    let order = Groups.positions(w.tabIds)
    let moving = OrderedSet(Splits.withSplitRows(s, ids)).elements.filter { s.tabs[$0]?.windowId == w.id && s.tabs[$0]?.profileId == first.profileId }
      .stableSorted { a, b in
        guard let x = order[a], let y = order[b] else { return false }
        return x < y
      }
    if moving.isEmpty { return s }
    let paired = Set(moving.filter { Splits.splitRowPanes(s, Splits.splitOf(s, $0)).contains($0) })
    let target = !p.pinned ? p.group.flatMap { s.groups[$0] } : nil
    if let target, target.windowId != w.id || target.profileId != first.profileId { return s }
    let movingSet = Set(moving)
    var tabs = s.tabs
    tabs.touch()
    var chosen: JSMap<Double>? = nil
    var pinSync = s.pinSync
    func pinnedGroupOf(_ id: String) -> String? {
      let g = Groups.innermostGroupOf(s.groups, id)
      return g?.pinned == true ? g!.id : nil
    }
    let intoPinnedGroup = target?.pinned == true ? target!.id : nil
    for id in moving {
      let t = tabs[id]!
      if t.pinned != p.pinned {
        var changed = t
        changed.pinned = p.pinned
        changed.pinnedUrl = p.pinned || intoPinnedGroup != nil ? (truthy(t.pinnedUrl) ? t.pinnedUrl : (t.url.isEmpty ? nil : t.url)) : nil
        tabs[id] = changed
      }
      let row = p.pinned && (paired.contains(id) || (p.row ?? (t.pinned && t.pinnedAsRow == true)))
      let placed = t.pinned != p.pinned || (!p.pinned && pinnedGroupOf(id) != intoPinnedGroup)
      if placed || (t.pinnedAsRow == true) != row {
        var changed = tabs[id]!
        changed.pinnedAsRow = row ? true : nil
        tabs[id] = changed
        let key = t.pinKeyOrId
        if placed, let entry = pinSync[t.profileId]?[key]?.object, entry["g"]?.truthy == true {
          var kept = entry
          kept.removeValue(forKey: "g")
          kept.removeValue(forKey: "w")
          var mine = pinSync[t.profileId]!
          mine[key] = .object(kept)
          pinSync[t.profileId] = mine
        }
        if (p.pinned || intoPinnedGroup != nil) && !Ids.isIncognitoProfile(t.profileId) {
          if chosen == nil { chosen = s.pinChoices[t.profileId] ?? JSMap() }
          if p.pinned { chosen![key] = nextPinChoice() }
          if placed { chosen![placeChoiceKey(key)] = nextPinChoice() }
        }
      }
      let folder: TileFolder?
      if p.pinned && !row {
        switch p.tileFolder {
        case .none: folder = tabs[id]!.tileFolder
        case .some(let given): folder = given
        }
      } else {
        folder = nil
      }
      if tabs[id]!.tileFolder != folder {
        var changed = tabs[id]!
        changed.tileFolder = folder
        tabs[id] = changed
      }
    }
    var rest = w.tabIds.filter { !movingSet.contains($0) }
    var at: Int
    if let before = p.before, rest.contains(before) {
      at = rest.jsIndexOf(Splits.splitRowHead(s, rest, before))
    } else if let target {
      let kept = target.tabIds.filter { !movingSet.contains($0) }
      at = kept.isEmpty ? min(order[target.tabIds.first ?? ""] ?? 0, rest.count) : rest.jsIndexOf(kept.last!) + 1
    } else if p.pinned {
      let toRow = tabs[moving[0]]!.pinnedAsRow == true
      let pinnedGroup = toRow && p.last == true ? Set(s.groups.values.filter(\.pinned).flatMap(\.tabIds)) : nil
      at = 0
      for (i, id) in rest.enumerated() {
        let t = tabs[id]
        if (t?.pinned == true && (toRow || t!.pinnedAsRow != true)) || pinnedGroup?.contains(id) == true { at = i + 1 }
      }
    } else {
      at = rest.count
    }
    Groups.insertAll(&rest, at, moving)
    var groups = Groups.leaveGroups(s.groups, movingSet)
    if let target {
      var kept = groups[target.id] ?? target
      let members = Set(kept.tabIds + moving)
      kept.tabIds = rest.filter { members.contains($0) }
      groups[target.id] = kept
      for a in Groups.ancestorIds(s.groups, target.id) where groups[a] == nil && s.groups[a] != nil {
        var ancestor = s.groups[a]!
        ancestor.tabIds = []
        groups[a] = ancestor
      }
      groups = Groups.reparent(groups, s.groups)
    }
    groups = Groups.nestGroups(groups)
    var tabIds = Groups.placeGroups(rest, groups, w.id)
    tabIds = Groups.orderSections(tabIds, tabs, groups)
    var window = w
    window.tabIds = tabIds
    var next = s
    next.tabs = tabs
    if let chosen { next.pinChoices[first.profileId] = chosen }
    next.pinSync = pinSync
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[w.id] = window
    return next
  }

  func withHomesOf(_ s: BrowserState, _ before: BrowserState, _ ids: [String]) -> BrowserState {
    let kept = ids.filter { id in
      guard let was = before.tabs[id], truthy(was.pinnedUrl), let now = s.tabs[id] else { return false }
      return now.pinnedUrl != was.pinnedUrl
    }
    if kept.isEmpty { return s }
    var next = s
    for id in kept {
      var t = next.tabs[id]!
      t.pinnedUrl = before.tabs[id]!.pinnedUrl
      next.tabs[id] = t
    }
    return next
  }

  func groupingOnto(_ s: BrowserState, _ ids: [String], _ targetId: String) -> (BrowserState, String) {
    guard let target = s.tabs[targetId], let w = s.windows[target.windowId], !(target.pinned && !target.isPinnedRow), groupOf(s, targetId) == nil else {
      return (s, "")
    }
    let moving = ids.filter { $0 != targetId && s.tabs[$0]?.windowId == w.id && s.tabs[$0]?.profileId == target.profileId }
    if moving.isEmpty { return (s, "") }
    let after = w.tabIds.jsSliced(w.tabIds.jsIndexOf(targetId) + 1).first { !moving.contains($0) }
    let placed = placing(s, moving, TabPlacement(pinned: false, beforeId: .some(after)))
    var (next, id) = withRowsGrouped(target.isPinnedRow ? withHomesOf(placed, s, moving) : placed, [targetId] + moving, name: nil, pinned: false)
    if id.isEmpty { return (s, "") }
    next.clearSelection(w.id)
    return (next, id)
  }

  func canMoveGroup(_ groups: Table<TabGroup>, _ groupId: String, _ p: GroupPlacement) -> Bool {
    guard let g = groups[groupId] else { return false }
    if let before = p.beforeId, !before.isEmpty, g.tabIds.contains(before) { return false }
    if let parent = p.parentId, !parent.isEmpty, groups[parent] == nil || !Groups.canNest(groups, groupId, parent) { return false }
    let staying = Set(p.parentId.flatMap { $0.isEmpty ? nil : [$0] + Groups.ancestorIds(groups, $0) } ?? [])
    let moving = Set(g.tabIds)
    return Groups.ancestorIds(groups, groupId).allSatisfy { a in staying.contains(a) || groups[a]!.tabIds.contains { !moving.contains($0) } }
  }

  func movingGroup(_ s: BrowserState, _ groupId: String, _ p: GroupPlacement) -> BrowserState? {
    guard let g = s.groups[groupId], let w = s.windows[g.windowId], canMoveGroup(s.groups, groupId, p) else { return nil }
    let parent = p.parentId.flatMap { $0.isEmpty ? nil : s.groups[$0] }
    let pinned = parent?.pinned ?? p.pinned
    let moving = Set(g.tabIds)
    var groups = s.groups
    groups.touch()
    let staying = Set(parent.map { [$0.id] + Groups.ancestorIds(s.groups, $0.id) } ?? [])
    for a in Groups.ancestorIds(s.groups, groupId) where !staying.contains(a) {
      var ancestor = groups[a]!
      ancestor.tabIds = ancestor.tabIds.filter { !moving.contains($0) }
      groups[a] = ancestor
    }
    var moved = g
    moved.pinned = pinned
    groups[groupId] = Groups.withParent(moved, parent?.id)
    groups = Groups.nestGroups(Groups.reparent(groups, s.groups))
    var pinChoices = s.pinChoices
    if pinned && !g.pinned && !Ids.isIncognitoProfile(g.profileId) {
      var mine = pinChoices[g.profileId] ?? JSMap()
      mine[groupChoiceKey(g.pinKeyOrId)] = nextPinChoice()
      for id in g.tabIds where s.tabs[id] != nil { mine[placeChoiceKey(s.tabs[id]!.pinKeyOrId)] = nextPinChoice() }
      pinChoices[g.profileId] = mine
    }
    var rest = w.tabIds.filter { !moving.contains($0) }
    var at: Int
    if let before = p.beforeId, !before.isEmpty, rest.contains(before) {
      let inner = Groups.innermostGroupOf(groups, before)
      let chain = inner.map { [$0.id] + Groups.ancestorIds(groups, $0.id) } ?? []
      let block = chain.compactMap { groups[$0] }.first { $0.parentId == parent?.id && $0.id != parent?.id }
      if let block {
        at = block.tabIds.first { rest.contains($0) }.map { rest.jsIndexOf($0) } ?? -1
      } else {
        at = rest.jsIndexOf(before)
      }
    } else if let parent {
      let kept = groups[parent.id]!.tabIds.filter { rest.contains($0) }
      at = kept.isEmpty ? min(w.tabIds.jsIndexOf(g.tabIds.first), rest.count) : rest.jsIndexOf(kept.last!) + 1
    } else if pinned {
      let pinnedGroup = Set(groups.values.filter { x in x.pinned && !moving.contains(x.tabIds.first ?? "") }.flatMap(\.tabIds))
      at = 0
      for (i, id) in rest.enumerated() where s.tabs[id]?.pinned == true || pinnedGroup.contains(id) { at = i + 1 }
    } else {
      at = rest.count
    }
    Groups.insertAll(&rest, at, g.tabIds)
    var window = w
    window.tabIds = Groups.orderSections(Groups.placeGroups(rest, groups, w.id), s.tabs, groups)
    var next = s
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[w.id] = window
    next.pinChoices = pinChoices
    return next
  }

  func forgetClosedPrivateWindows(_ s: BrowserState) -> BrowserState? {
    let cleaned = s.privateCleanedTabs.keys.filter { s.windows[$0] == nil }
    let mutes = s.privateSiteMutes.keys.filter { s.windows[$0] == nil }
    if cleaned.isEmpty && mutes.isEmpty { return nil }
    var next = s
    for id in cleaned { next.privateCleanedTabs.removeValue(forKey: id) }
    for id in mutes { next.privateSiteMutes.removeValue(forKey: id) }
    return next
  }
}
