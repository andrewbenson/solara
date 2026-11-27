import SolaraModel

struct PinnedBlock {
  var key: String
  var row: Bool
  var ids: [String]
}

func pinnedBlocks(_ s: BrowserState, _ w: BrowserWindow, _ profileId: String) -> [PinnedBlock] {
  var blocks: [PinnedBlock] = []
  var byRoot: [String: Int] = [:]
  var pinnedRoot: [String: TabGroup] = [:]
  for g in s.groups.values where g.pinned && g.windowId == w.id && g.profileId == profileId {
    let root = Groups.rootOf(s.groups, g.id) ?? g
    for id in g.tabIds { pinnedRoot[id] = root }
  }
  for id in w.tabIds {
    guard let t = s.tabs[id], t.profileId == profileId else { continue }
    if t.pinned {
      if t.pinnedAsRow == true { blocks.append(PinnedBlock(key: "t:\(t.pinKeyOrId)", row: true, ids: [id])) }
      continue
    }
    guard let root = pinnedRoot[id] else { continue }
    if let known = byRoot[root.id] {
      blocks[known].ids.append(id)
    } else {
      byRoot[root.id] = blocks.count
      blocks.append(PinnedBlock(key: "g:\(root.pinKeyOrId)", row: false, ids: [id]))
    }
  }
  return blocks
}

func anchorsOf(_ keys: [String]) -> OrderedDict<String, String?> {
  var anchors = OrderedDict<String, String?>()
  var row: String? = nil
  for key in keys {
    if key.hasPrefix("t:") {
      row = String(key.dropFirst(2))
    } else {
      anchors[String(key.dropFirst(2))] = .some(row)
    }
  }
  return anchors
}

func parkedBlocks(_ park: ParkedPins) -> [PinnedBlock] {
  var parentOf: [String: String?] = [:]
  for g in park.groups { parentOf[g.id] = g.parentId }
  func rootOf(_ id: String) -> String {
    var seen: Set<String> = [id]
    var root = id
    while let up = parentOf[root] ?? nil, parentOf[up] != nil, !seen.contains(up) {
      seen.insert(up)
      root = up
    }
    return root
  }
  var blocks: [PinnedBlock] = []
  var byKey: [String: Int] = [:]
  for t in park.tabs {
    let key: String?
    if let groupId = t.groupId {
      key = "g:\(rootOf(groupId))"
    } else if t.snapshot.pinnedAsRow == true {
      key = "t:\(t.id)"
    } else {
      key = nil
    }
    guard let key else { continue }
    if let known = byKey[key] {
      blocks[known].ids.append(t.id)
    } else {
      byKey[key] = blocks.count
      blocks.append(PinnedBlock(key: key, row: t.groupId == nil, ids: [t.id]))
    }
  }
  return blocks
}

func pinnedAreaKeys(_ s: BrowserState, _ w: BrowserWindow, _ profileId: String) -> [String] {
  pinnedBlocks(s, w, profileId).map(\.key)
}

public enum SidebarPinnedOrder {
  public static func anchorChanges(before: BrowserState, after: BrowserState, profileId: String) -> (ordered: [String], remaining: Set<String>)? {
    let session = Session(state: after, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 0)
    guard let windowId = session.mainWindowFor(after, profileId), let old = before.windows[windowId], let new = after.windows[windowId] else { return nil }
    let ordered = pinnedAreaKeys(before, old, profileId)
    let remaining = Set(pinnedAreaKeys(after, new, profileId))
    return ordered.allSatisfy(remaining.contains) ? nil : (ordered, remaining)
  }
}

func parkedAreaKeys(_ s: BrowserState, _ profileId: String) -> [String] {
  s.parkedPins[profileId].map { parkedBlocks($0).map(\.key) } ?? []
}

func orderBlocks(_ blocks: [PinnedBlock], _ anchorOf: (String) -> String??) -> [String]? {
  let rows = blocks.filter(\.row)
  let groups = blocks.filter { !$0.row }
  let rowKeys = Set(rows.map { String($0.key.dropFirst(2)) })
  var placed = OrderedDict<String?, [PinnedBlock]>()
  var last: [PinnedBlock] = []
  for g in groups {
    let anchor = anchorOf(String(g.key.dropFirst(2)))
    switch anchor {
    case .some(.none): placed[nil, default: []].append(g)
    case .some(.some(let a)) where rowKeys.contains(a): placed[a, default: []].append(g)
    default: last.append(g)
    }
  }
  if !groups.contains(where: { anchorOf(String($0.key.dropFirst(2))) != nil }) { return nil }
  var out: [PinnedBlock] = placed[nil] ?? []
  for r in rows {
    out.append(r)
    out.append(contentsOf: placed[String(r.key.dropFirst(2))] ?? [])
  }
  out.append(contentsOf: last)
  return out.flatMap(\.ids)
}

func rearranged(_ ids: [String], _ order: [String]) -> [String]? {
  let area = Set(order)
  let at = ids.firstIndex { area.contains($0) } ?? -1
  let rest = ids.filter { !area.contains($0) }
  let next = rest.jsSliced(0, at) + order + rest.jsSliced(at)
  return next == ids ? nil : next
}

func arrangeParked(_ park: ParkedPins, _ anchorOf: (String) -> String??) -> ParkedPins {
  guard let order = orderBlocks(parkedBlocks(park), anchorOf) else { return park }
  var byId: [String: ParkedTab] = [:]
  for t in park.tabs { byId[t.id] = t }
  guard let ids = rearranged(park.tabs.map(\.id), order) else { return park }
  var next = park
  next.tabs = ids.map { byId[$0]! }
  return next
}

func arrangePinnedArea(_ s: BrowserState, _ w: BrowserWindow, _ profileId: String, _ anchorOf: (String) -> String??) -> [String] {
  guard let order = orderBlocks(pinnedBlocks(s, w, profileId), anchorOf) else { return w.tabIds }
  return rearranged(w.tabIds, order) ?? w.tabIds
}

extension Session {
  func orderHomes(_ s: BrowserState) -> OrderedDict<String, String> {
    var out = OrderedDict<String, String>()
    for profileId in OrderedSet(s.groups.values.filter { $0.pinned && $0.parentId == nil }.map(\.profileId)) {
      if Ids.isIncognitoProfile(profileId) { continue }
      let home = (s.ui.focusOrder + s.windowOrder).compactMap { s.windows[$0] }.first { w in
        !w.incognito && !w.isSmall && w.tabIds.contains { s.tabs[$0]?.profileId == profileId }
      }
      if let home { out[profileId] = home.id }
    }
    return out
  }

  func groupsReordered(_ s: BrowserState, _ prev: BrowserState) -> Bool {
    if !s.groups.changed(from: prev.groups) { return false }
    func shape(_ g: TabGroup) -> String { "\(g.pinned)|\(g.parentId ?? "")|\(g.windowId)|\(g.profileId)|\(g.pinKey ?? "")" }
    for id in OrderedSet(s.groups.keys + prev.groups.keys) {
      guard let g = s.groups[id], let was = prev.groups[id] else { return true }
      if g.tabIds != was.tabIds || shape(g) != shape(was) { return true }
    }
    return false
  }

  func noteOrderChoices(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if memory.fromSyncDepth > 0 { return nil }
    if !groupsReordered(s, prev) && s.windows.values.allSatisfy({ $0.tabIds == prev.windows[$0.id]?.tabIds }) { return nil }
    let homesBefore = orderHomes(prev)
    var pinChoices = s.pinChoices
    var changed = false
    for (profileId, windowId) in orderHomes(s) {
      if homesBefore[profileId] != windowId { continue }
      let before = pinnedAreaKeys(prev, prev.windows[windowId]!, profileId)
      let after = pinnedAreaKeys(s, s.windows[windowId]!, profileId)
      let now = Set(after)
      let kept = Set(before.filter { now.contains($0) })
      let was = anchorsOf(before.filter { kept.contains($0) })
      let moved = anchorsOf(after.filter { kept.contains($0) }).filter { group, a in was[group] != .some(a) }.map { orderChoiceKey($0.key) }
      if !moved.isEmpty {
        var mine = pinChoices[profileId] ?? JSMap()
        for k in moved { mine[k] = nextPinChoice() }
        pinChoices[profileId] = mine
        changed = true
      }
    }
    guard changed else { return nil }
    var next = s
    next.pinChoices = pinChoices
    return next
  }
}
