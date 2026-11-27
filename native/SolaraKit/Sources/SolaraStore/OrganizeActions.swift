import SolaraModel

extension Store {
  public func canUndoSidebarClear(_ cleared: JSONValue) -> Bool {
    sequence {
      let current = state
      let session = Session(state: current, memory: memory, env: PlainWebAddressing(), config: StoreConfig(), now: 0)
      return session.canUndoClear(current, cleared)
    }
  }
}

extension Session {
  public func createGroup(_ tabIds: [String], name: String?, icon: String??, color: String??) -> String {
    let s = state
    let tabs = Splits.withSplitRows(s, tabIds).compactMap { s.tabs[$0] }.filter { !$0.pinned }
    guard let first = tabs.first, !tabs.contains(where: { $0.windowId != first.windowId || $0.profileId != first.profileId }) else { return "" }
    let w = s.windows[first.windowId]!
    let members = Set(tabs.map(\.id))
    var window = w
    window.tabIds = Groups.placeBlock(w.tabIds, w.tabIds.filter { members.contains($0) })
    let group = TabGroup(
      id: newId("g"), windowId: w.id, profileId: first.profileId, name: name ?? "", icon: icon ?? nil, color: color ?? nil, collapsed: false,
      pinned: false, tabIds: window.tabIds.filter { members.contains($0) }, createdAt: now)
    var groups = Groups.leaveGroups(s.groups, members)
    groups[group.id] = group
    var next = s
    next.groups = groups
    next.windows[w.id] = window
    set(next)
    return group.id
  }

  public func updateGroup(_ id: String, _ patch: TabUpdate) {
    let s = state
    guard let g = s.groups[id] else {
      set(s)
      return
    }
    var json = g.json
    for (key, value) in patch.set where ["name", "icon", "color", "collapsed", "pinned"].contains(key) { json[key] = value }
    for key in patch.unset where ["name", "icon", "color", "collapsed", "pinned"].contains(key) { json.removeValue(forKey: key) }
    guard let updated = try? TabGroup(json: json) else { return }
    var groups = s.groups
    groups[id] = updated
    var next = s
    let pinnedPatch = patch.value("pinned")?.bool
    guard let pinned = pinnedPatch, pinned != g.pinned, let w = s.windows[g.windowId] else {
      next.groups = groups
      set(next)
      return
    }
    _ = pinned
    var window = w
    window.tabIds = Groups.orderSections(w.tabIds, s.tabs, groups)
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[w.id] = window
    set(next)
  }

  public func addTabsToGroup(_ groupId: String, _ tabIds: [String]) {
    let s = state
    guard let group = s.groups[groupId] else {
      set(s)
      return
    }
    let adding = Splits.withSplitRows(s, tabIds).filter { id in
      guard let t = s.tabs[id] else { return false }
      return !t.pinned && t.windowId == group.windowId && t.profileId == group.profileId && !group.tabIds.contains(id)
    }
    if adding.isEmpty {
      set(s)
      return
    }
    let w = s.windows[group.windowId]!
    let block = Groups.placeBlock(w.tabIds, group.tabIds + adding)
    var left = Groups.leaveGroups(s.groups, Set(adding))
    var grown = group
    grown.tabIds = group.tabIds + adding
    left[groupId] = grown
    let groups = Groups.nestGroups(left)
    var window = w
    window.tabIds = Groups.placeGroups(block, groups, w.id)
    var next = s
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[w.id] = window
    set(next)
  }

  public func removeTabsFromGroup(_ tabIds: [String]) {
    let s = state
    var groups = s.groups
    var windows = s.windows
    windows.touch()
    var touched = OrderedSet<String>()
    for id in Splits.withSplitRows(s, tabIds) {
      guard let g = Groups.innermostGroupOf(groups, id), let w = windows[g.windowId] else { continue }
      touched.insert(w.id)
      let kept = g.tabIds.filter { $0 != id }
      if !kept.isEmpty {
        var order = w.tabIds.filter { $0 != id }
        order.jsSplice(order.jsIndexOf(kept.last!) + 1, 0, [id])
        var window = w
        window.tabIds = order
        windows[w.id] = window
        var shrunk = g
        shrunk.tabIds = kept
        groups[g.id] = shrunk
      } else {
        var rest = groups
        rest.remove([g.id])
        groups = Groups.reparent(rest, groups)
      }
    }
    var next = s
    next.windows = windows
    next.groups = groups
    for windowId in touched { next = Groups.withGroupsPlaced(next, windowId, next.groups) }
    var out = s
    out.groups = next.groups
    out.windows = next.windows
    set(out)
  }

  public func ungroup(_ groupId: String) {
    let s = state
    guard let group = s.groups[groupId] else {
      set(s)
      return
    }
    var rest = s.groups
    rest.remove([groupId])
    let groups = Groups.reparent(rest, s.groups)
    var next = s
    if s.windows[group.windowId] == nil {
      next.groups = groups
      set(next)
      return
    }
    let placed = Groups.withGroupsPlaced(s, group.windowId, groups)
    next.groups = placed.groups
    next.windows = placed.windows
    set(next)
  }

  public func newNestedGroup(_ parentId: String) -> String {
    let s = state
    guard let p = s.groups[parentId], let w = s.windows[p.windowId] else { return "" }
    var o = NewTabOptions()
    o.profileId = p.profileId
    o.index = w.tabIds.jsIndexOf(p.tabIds.last) + 1
    let (next, tabId) = withNewTab(s, w.id, o)
    var group = TabGroup(
      id: newId("g"), windowId: w.id, profileId: p.profileId, name: "", icon: nil, color: nil, collapsed: false, pinned: p.pinned, tabIds: [tabId],
      createdAt: now)
    group.parentId = parentId
    var groups = next.groups
    var parent = p
    parent.collapsed = false
    groups[parentId] = parent
    groups[group.id] = group
    set(Groups.withGroupsPlaced(next, w.id, Groups.nestGroups(groups)))
    return group.id
  }

  public func closeGroup(_ groupId: String) { set(closingGroup(state, groupId)) }

  public func deleteGroup(_ groupId: String) { set(closingGroup(state, groupId, deleted: true)) }

  public func placeTabs(_ ids: [String], _ placement: TabPlacement) { set(placing(state, ids, placement)) }

  public func pinTabs(_ ids: [String], pinned: Bool, row: Bool?) {
    let s = state
    guard let first = s.tabs[ids.first ?? ""], let w = s.windows[first.windowId] else { return }
    let pinnedGroupMembers = Set(s.groups.values.filter(\.pinned).flatMap(\.tabIds))
    let beforeId: String? = pinned ? nil : w.tabIds.first { id in s.tabs[id]?.pinned != true && !pinnedGroupMembers.contains(id) && !ids.contains(id) }
    set(placing(s, ids, TabPlacement(pinned: pinned, row: row, beforeId: .some(beforeId))))
  }

  public func returnToPinnedUrl(_ tabId: String) {
    guard let t = state.tabs[tabId], let pinned = t.pinnedUrl, !pinned.isEmpty, !samePage(t.url, pinned) else { return }
    navigate(tabId, pinned)
  }

  public func setPinnedUrl(_ tabId: String, _ url: String?) {
    let t = state.tabs[tabId]
    let next = url ?? t?.url
    guard let t, let next, !next.isEmpty, state.inPinnedContainer(tabId) else { return }
    updateTab(tabId, TabUpdate(set: ["pinnedUrl": .string(next)]))
    if let url, !url.isEmpty, !samePage(t.url, url) { navigate(tabId, url) }
  }

  public func setMuted(_ ids: [String], _ muted: Bool) {
    var next = state
    for id in ids {
      if var t = next.tabs[id], t.muted != muted {
        t.muted = muted
        next.tabs[id] = t
      }
    }
    set(next)
  }

  public func setSiteMuted(_ tabId: String, _ muted: Bool) {
    let s = state
    guard let tab = s.tabs[tabId] else { return }
    let host = hostOf(tab.url)
    if host.isEmpty {
      setMuted([tabId], muted)
      return
    }
    setMuted(s.tabs.values.filter { $0.profileId == tab.profileId && hostOf($0.url) == host }.map(\.id), muted)
    if Ids.isIncognitoProfile(tab.profileId) {
      var next = state
      var own = s.privateSiteMutes[tab.windowId] ?? JSMap()
      own[host] = muted
      next.privateSiteMutes[tab.windowId] = own
      set(next)
      return
    }
    var sites = OrderedSet(s.settings.strings("mutedSites") ?? [])
    if muted { sites.insert(host) } else { sites.remove(host) }
    updateSettings(["mutedSites": JSONValue(sites.elements)], fromSync: false)
  }

  public func groupTabs(_ ids: [String], pinned: Bool, name: String?) -> String {
    var (next, id) = withRowsGrouped(state, ids, name: name, pinned: pinned)
    if !id.isEmpty {
      next.clearSelection(next.groups[id]!.windowId)
      set(next)
    }
    return id
  }

  public func groupOnto(_ ids: [String], _ targetId: String) -> String {
    let (next, id) = groupingOnto(state, ids, targetId)
    if !id.isEmpty { set(next) }
    return id
  }

  public func moveGroup(_ groupId: String, _ p: GroupPlacement) {
    set(movingGroup(state, groupId, p) ?? state)
  }

  public func duplicateGroup(_ groupId: String) -> String {
    var s = state
    guard let g = s.groups[groupId], let w = s.windows[g.windowId] else { return "" }
    let original = s
    let after = w.tabIds.jsIndexOf(g.tabIds.last) + 1
    let entries = g.tabIds.enumerated().map { i, id -> SnapshotEntry in
      var snap = snapshotTab(s.tabs[id]!)
      snap.pinned = false
      return SnapshotEntry(tab: snap, tabId: nil, index: after + i)
    }
    let (restored, ids) = restoreSnapshots(s, w.id, entries)
    var o = GroupOptions()
    o.name = g.name
    o.pinned = g.pinned
    o.parentId = .some(g.parentId)
    let (grouped, groupId2) = withGroup(restored, ids, o)
    s = grouped
    if !groupId2.isEmpty {
      var made = s.groups[groupId2]!
      made.setLook(icon: g.icon, color: g.color, absent: g.absent)
      s.groups[groupId2] = made
      s = rebuildNested(s, groupId2, g.id, ids, nestedSnapshot(original, g))
    }
    set(s)
    return groupId2
  }

  public func newTabInGroup(_ groupId: String) -> String {
    let s = state
    guard let g = s.groups[groupId], let w = s.windows[g.windowId] else { return "" }
    var o = NewTabOptions()
    o.profileId = g.profileId
    o.index = w.tabIds.jsIndexOf(g.tabIds.last) + 1
    let (next, id) = withNewTab(s, w.id, o)
    var groups = next.groups
    var grown = g
    grown.collapsed = false
    grown.tabIds = g.tabIds + [id]
    groups[groupId] = grown
    set(Groups.withGroupsPlaced(next, w.id, Groups.nestGroups(groups)))
    return id
  }

  public func cleanUpTabs(_ windowId: String, inactiveForMs: Double?) -> Int {
    let s = state
    let hours = s.settings.number("cleanUpInactiveTabsAfterHours")
    let ids = cleanUpCandidates(s, windowId, inactiveForMs ?? (hours.flatMap { $0 != 0 ? $0 * 3_600_000 : nil } ?? cleanUpAfterMs))
    if ids.isEmpty { return 0 }
    let entries = closedEntries(s, ids)
    var next = closeQuietly(s, ids)
    if s.windows[windowId]?.incognito == true {
      let own = keptAWeek(next.privateCleanedTabs[windowId] ?? [], now, \.closedAt) + entries
      next.privateCleanedTabs[windowId] = Array(own.suffix(maxCleaned))
    } else {
      next.cleanedTabs = Array((keptAWeek(next.cleanedTabs, now, \.closedAt) + entries).suffix(maxCleaned))
    }
    set(next)
    return ids.count
  }

  public func restoreCleaned(_ entryId: String?, _ fromWindowId: String?) {
    let s = state
    let privateId: String? =
      fromWindowId.flatMap { s.windows[$0]?.incognito == true ? $0 : nil }
      ?? s.privateCleanedTabs.keys.first { id in truthy(entryId) && s.privateCleanedTabs[id]!.contains { $0.id == entryId } }
    let list = keptAWeek(privateId.map { s.privateCleanedTabs[$0] ?? [] } ?? s.cleanedTabs, now, \.closedAt)
    let entries = list.filter { !truthy(entryId) || $0.id == entryId }
    if entries.isEmpty { return }
    let chosen = Set(entries.map(\.id))
    let left = list.filter { !chosen.contains($0.id) }
    var next = s
    if let privateId { next.privateCleanedTabs[privateId] = left } else { next.cleanedTabs = left }
    for e in entries {
      let windowId: String? = privateId != nil ? (next.windows[privateId!]?.incognito == true ? privateId : nil) : restoreTarget(next, e.windowId, nil)
      guard let windowId, !(Ids.isIncognitoProfile(e.tab.profileId) && e.windowId != windowId) else { continue }
      let (restored, ids) = restoreSnapshots(
        next, windowId, [SnapshotEntry(tab: e.tab, tabId: e.restoreFrom ?? e.tabId, index: windowId == e.windowId ? e.index : nil, shownAt: e.shownAt)])
      next = restored
      if let id = ids.first, !id.isEmpty, e.group != nil { next = regroupRestored(next, windowId, [e], [id]) }
      if let id = ids.first, !id.isEmpty, truthy(entryId) { next = activated(next, id) }
    }
    set(next)
  }

  public func clearUnpinnedTabs(_ windowId: String) -> JSONValue {
    let s = state
    let ids = clearedTabIds(s, windowId)
    if ids.isEmpty { return .null }
    let entries = closedEntries(s, ids)
    closeTabs(ids)
    return undoable(s, state, windowId, s.windows[windowId]!.profileId, entries)
  }

  func undoable(_ before: BrowserState, _ after: BrowserState, _ windowId: String, _ profileId: String, _ entries: [ClosedTab]) -> JSONValue {
    let known = Set(before.closedTabs.map(\.id))
    return [
      "windowId": .string(windowId), "entries": .array(entries.map(\.jsonValue)),
      "closedEntryIds": JSONValue(after.closedTabs.filter { !known.contains($0.id) }.map(\.id)), "tabIds": JSONValue(before.windows[windowId]!.tabIds),
      "groups": .array(before.groups.values.filter { $0.windowId == windowId }.map(\.jsonValue)), "fingerprint": .string(windowFingerprint(after, windowId)),
      "profileId": .string(profileId), "remoteDeletions": .number(memory.remotePinDeletions[profileId] ?? 0),
    ]
  }

  func canUndoClear(_ s: BrowserState, _ cleared: JSONValue) -> Bool {
    let closed = Set(s.closedTabs.map(\.id))
    let profileId = cleared["profileId"]?.string ?? ""
    return (memory.remotePinDeletions[profileId] ?? 0) == (cleared["remoteDeletions"]?.number ?? 0)
      && (cleared["closedEntryIds"]?.array ?? []).allSatisfy { closed.contains($0.string ?? "") }
      && windowFingerprint(s, cleared["windowId"]?.string ?? "") == cleared["fingerprint"]?.string
  }

  public func undoClearTabs(_ cleared: JSONValue) {
    let s = state
    if !canUndoClear(s, cleared) { return }
    let windowId = cleared["windowId"]?.string ?? ""
    let entries = (cleared["entries"]?.array ?? []).compactMap { try? ClosedTab(value: $0) }
    let undone = Set((cleared["closedEntryIds"]?.array ?? []).compactMap(\.string))
    var base = s
    base.closedTabs = s.closedTabs.filter { !undone.contains($0.id) }
    let (restored, ids) = restoreSnapshots(base, windowId, entries.map { SnapshotEntry(tab: $0.tab, tabId: $0.restoreFrom ?? $0.tabId, index: nil, shownAt: $0.shownAt) })
    var renamed: [String: String] = [:]
    for (i, e) in entries.enumerated() { if let tabId = e.tabId { renamed[tabId] = i < ids.count ? ids[i] : nil } }
    func current(_ id: String) -> String { renamed[id] ?? id }
    let back = (cleared["tabIds"]?.array ?? []).compactMap(\.string).map(current).filter { restored.tabs[$0]?.windowId == windowId }
    let w = restored.windows[windowId]!
    var window = w
    window.tabIds = back + w.tabIds.filter { !back.contains($0) }
    var groups = restored.groups.filtered { $0.windowId != windowId }
    for value in cleared["groups"]?.array ?? [] {
      guard let g = try? TabGroup(value: value) else { continue }
      let tabIds = g.tabIds.map(current).filter { restored.tabs[$0] != nil }
      if let existing = restored.groups[g.id] {
        var updated = existing
        updated.pinned = g.pinned
        updated.tabIds = tabIds
        groups[g.id] = Groups.withParent(updated, g.parentId)
      } else {
        var copy = g
        copy.tabIds = tabIds
        groups[g.id] = copy
      }
    }
    var next = restored
    next.closedTabs = restored.closedTabs.map { c in
      guard let tabId = c.tabId, let moved = renamed[tabId] else { return c }
      var changed = c
      changed.tabId = moved
      changed.restoreFrom = c.restoreFrom ?? tabId
      return changed
    }
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[windowId] = window
    set(next)
  }

  public func removeClosedPin(_ id: String) -> JSONValue {
    let s = state
    if !isClosedPin(s, id) { return .null }
    let windowId = s.tabs[id]!.windowId
    set(removeTabs(s, [id], record: true))
    let after = state
    let known = Set(s.closedTabs.map(\.id))
    return undoable(s, after, windowId, s.tabs[id]!.profileId, after.closedTabs.filter { !known.contains($0.id) })
  }

  public func closeAbandonedNewTabs() {
    let s = state
    let abandoned = s.windows.values.flatMap { abandonedNewTabs(s, $0.id) }
    if !abandoned.isEmpty { set(removeTabs(s, abandoned, record: false)) }
  }

  public func tidyPins(_ windowId: String, _ profileId: String?) -> JSONValue {
    let (next, done) = tidyingPins(state, windowId, profileId)
    set(next)
    return done?.json ?? .null
  }

  public func untidyPins(_ tidied: TidiedPins) { set(untidyingPins(state, tidied)) }

  public func makeTileFolder(_ tabIds: [String], _ name: String) -> String? {
    let (next, folderId) = newTileFolder(state, tabIds, name)
    set(next)
    return folderId
  }

  public func openDraftGroups(_ windowId: String, _ profileId: String, _ drafts: [GroupDraft]) -> JSONValue {
    let (next, result) = withDraftGroups(state, windowId, profileId, drafts)
    if !(result["made"]?.array?.isEmpty ?? true) { set(next) }
    return result
  }

  public func forgetClosedTab(_ tabId: String) {
    var next = state
    next.closedTabs = next.closedTabs.filter { $0.tabId != tabId }
    set(next)
  }
}
