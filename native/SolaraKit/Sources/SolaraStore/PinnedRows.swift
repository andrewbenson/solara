import SolaraModel

public struct PinnedListSpot: Sendable, Equatable {
  public var windowId: String
  public var key: String
  public var list: [String]
  public var index: Int
  public var order: Int
  public var groupId: String?
}

struct PinnedRestore {
  var spot: PinnedListSpot
  var tabId: String
}

extension Session {
  public func togglePinnedRows(_ windowId: String) {
    let s = state
    guard let tab = s.activeTab(windowId) else { return }
    let selected = pinnedRowsSelection(s, windowId).compactMap { s.tabs[$0] }.filter { $0.profileId == tab.profileId }
    if !tab.pinned {
      moveToPinnedRows(s, windowId, selected.filter { !$0.pinned })
    } else {
      moveOutOfPinned(selected.filter(\.pinned))
    }
  }

  public func forgetListSpots() {
    memory.listSpots.removeAll()
  }

  func pinnedRowsSelection(_ s: BrowserState, _ windowId: String) -> [String] {
    let view = s.viewTabIds(windowId)
    let picked = Set((s.selection[windowId]?.ids ?? []).filter { view.contains($0) })
    if !picked.isEmpty { return view.filter { picked.contains($0) } }
    return s.activeTabId(windowId).map { [$0] } ?? []
  }

  func pinnedRowsListIds(_ s: BrowserState, _ windowId: String, _ profileId: String, except: Set<String>) -> [String] {
    (s.windows[windowId]?.tabIds ?? []).filter { id in
      guard let t = s.tabs[id] else { return false }
      return !t.pinned && t.profileId == profileId && !except.contains(id) && groupOf(s, id)?.pinned != true
    }
  }

  func moveToPinnedRows(_ s: BrowserState, _ windowId: String, _ tabs: [Tab]) {
    guard let first = tabs.first else { return }
    let list = pinnedRowsListIds(s, windowId, first.profileId, except: []).compactMap { s.tabs[$0]?.pinKeyOrId }
    for t in tabs {
      let group = groupOf(s, t.id)
      let key = t.pinKeyOrId
      memory.listSpots[key] = PinnedListSpot(
        windowId: windowId, key: key, list: list, index: list.firstIndex(of: key) ?? -1, order: memory.spotOrder,
        groupId: group.flatMap { $0.pinned ? nil : $0.id })
      memory.spotOrder += 1
    }
    pinTabs(tabs.map(\.id), pinned: true, row: true)
  }

  func moveOutOfPinned(_ tabs: [Tab]) {
    guard !tabs.isEmpty else { return }
    let before = state
    var spots: [PinnedRestore] = []
    for t in tabs {
      guard let spot = memory.listSpots[t.pinKeyOrId] else { continue }
      memory.listSpots[t.pinKeyOrId] = nil
      guard let tabId = before.windows[spot.windowId]?.tabIds.first(where: { before.tabs[$0]?.pinKeyOrId == spot.key }) else { continue }
      spots.append(PinnedRestore(spot: spot, tabId: tabId))
    }
    pinTabs(tabs.map(\.id), pinned: false, row: nil)
    hear()
    let ordered = Self.inListOrder(spots)
    var placed: [Int] = []
    for (n, restore) in ordered.enumerated() {
      let spot = restore.spot
      let s = state
      guard let t = s.tabs[restore.tabId], !t.pinned, t.windowId == spot.windowId else { continue }
      let pending = ordered.indices.filter { $0 != n && !placed.contains($0) }.map { ordered[$0].tabId }
      let now = pinnedRowsListIds(s, spot.windowId, t.profileId, except: Set([t.id] + pending))
      let keys = now.map { s.tabs[$0]!.pinKeyOrId }
      let prevKey = Self.jsSlice(spot.list, 0, spot.index).reversed().first { keys.contains($0) }
      let nextKey = Self.jsSlice(spot.list, spot.index + 1).first { keys.contains($0) }
      let reached = [prevKey.map { keys.firstIndex(of: $0) ?? -1 } ?? -1]
        + placed.filter { Self.precedes(ordered[$0].spot, spot) }.map { keys.firstIndex(of: ordered[$0].spot.key) ?? -1 }
      let after = reached.max() ?? -1
      let prev: String? = after >= 0 ? now[after] : nil
      var beforeId: String?
      if prev != nil {
        beforeId = after + 1 < now.count ? now[after + 1] : nil
      } else if let nextKey, let at = keys.firstIndex(of: nextKey) {
        beforeId = now[at]
      } else {
        beforeId = spot.index >= 0 && spot.index < now.count ? now[spot.index] : nil
      }
      let group = spot.groupId.flatMap { s.groups[$0] }
      let fits = group.map { !$0.pinned && $0.windowId == spot.windowId && $0.profileId == t.profileId } ?? false
      let groupId = fits ? group?.id : nil
      if let group, groupId != nil, !(beforeId.map { group.tabIds.contains($0) } ?? false) {
        beforeId = prev.map { group.tabIds.contains($0) } == true ? nil : group.tabIds.first { now.contains($0) }
      }
      placeTabs([t.id], TabPlacement(pinned: false, beforeId: .some(beforeId), groupId: groupId.map { .some($0) }))
      hear()
      placed.append(n)
    }
  }

  static func precedes(_ a: PinnedListSpot, _ b: PinnedListSpot) -> Bool {
    [a.list, b.list].contains { list in
      guard let i = list.firstIndex(of: a.key), let j = list.firstIndex(of: b.key) else { return false }
      return i < j
    }
  }

  static func inListOrder(_ spots: [PinnedRestore]) -> [PinnedRestore] {
    var left = spots.sorted { x, y in x.spot.index != y.spot.index ? x.spot.index < y.spot.index : x.spot.order < y.spot.order }
    var out: [PinnedRestore] = []
    while !left.isEmpty {
      let free = left.indices.first { i in !left.indices.contains { j in j != i && precedes(left[j].spot, left[i].spot) } }
      out.append(left.remove(at: free ?? 0))
    }
    return out
  }

  static func jsSlice(_ list: [String], _ start: Int, _ end: Int? = nil) -> ArraySlice<String> {
    func clamp(_ i: Int) -> Int { i < 0 ? max(0, list.count + i) : min(i, list.count) }
    let from = clamp(start)
    let to = clamp(end ?? list.count)
    return from < to ? list[from..<to] : []
  }
}
