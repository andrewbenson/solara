import SolaraModel

public enum Splits {
  public static let maxPanes = 3

  public static func slotsOf(_ split: SplitView) -> [[String]] {
    var slots: [[String]] = []
    var i = 0
    while i < split.tabIds.count {
      if split.stack?.index == i, i + 1 < split.tabIds.count {
        slots.append([split.tabIds[i], split.tabIds[i + 1]])
        i += 1
      } else if split.stack?.index == i {
        slots.append([split.tabIds[i]])
        i += 1
      } else {
        slots.append([split.tabIds[i]])
      }
      i += 1
    }
    return slots
  }

  static func equal(_ n: Int) -> [Double] { Array(repeating: 1 / Double(n), count: n) }

  static func fromSlots(_ split: SplitView, _ slots: [[String]], _ sizes: [Double]? = nil) -> SplitView {
    let tabIds = slots.flatMap { $0 }
    let stackAt = slots.firstIndex { $0.count == 2 }
    var next = split
    next.tabIds = tabIds
    next.sizes = sizes.flatMap { $0.count == slots.count ? $0 : nil } ?? equal(slots.count)
    if let stackAt {
      next.stack = SplitStack(index: slots[..<stackAt].flatMap { $0 }.count, sizes: split.stack?.sizes ?? [0.5, 0.5])
    } else {
      next.stack = nil
    }
    return next
  }

  public static func visiblePaneIds(_ state: BrowserState, windowId: String) -> [String] {
    guard let selected = state.activeTabId(windowId), state.tabs[selected]?.windowId == windowId else { return [] }
    guard let split = splitOf(state, selected), split.windowId == windowId else { return [selected] }
    return split.tabIds.filter { state.tabs[$0]?.windowId == windowId }
  }

  public static func splitOf(_ s: BrowserState, _ tabId: String?) -> SplitView? {
    guard let tabId else { return nil }
    for v in s.splits.values where v.tabIds.contains(tabId) { return v }
    return nil
  }

  public static func splitRowPanes(_ s: BrowserState, _ split: SplitView?) -> [String] {
    guard let split else { return [] }
    let unpinned = split.tabIds.filter { s.tabs[$0] != nil && !s.tabs[$0]!.pinned }
    if unpinned.count >= 2 { return unpinned }
    let rows = split.tabIds.filter { s.tabs[$0]?.isPinnedRow == true }
    return rows.count >= 2 ? rows : []
  }

  public static func withSplitRows(_ s: BrowserState, _ ids: [String]) -> [String] {
    var out = OrderedSet(ids)
    for id in ids {
      let panes = splitRowPanes(s, splitOf(s, id))
      if panes.contains(id) { for pane in panes { out.insert(pane) } }
    }
    return out.count == ids.count ? ids : out.elements
  }

  public static func withPinnedPanes(_ s: BrowserState, _ ids: [String]) -> [String] {
    var out = OrderedSet(ids)
    for id in ids { for pane in splitOf(s, id)?.tabIds ?? [] where s.inPinnedContainer(pane) { out.insert(pane) } }
    return out.count == ids.count ? ids : out.elements
  }

  public static func splitRowHead(_ s: BrowserState, _ order: [String], _ id: String) -> String {
    let panes = splitRowPanes(s, splitOf(s, id))
    return panes.contains(id) ? (order.first { panes.contains($0) } ?? id) : id
  }

  public static func removeFromSplits(_ splits: Table<SplitView>, _ gone: Set<String>) -> Table<SplitView> {
    if !splits.values.contains(where: { $0.tabIds.contains { gone.contains($0) } }) { return splits }
    var next = JSMap<SplitView>()
    for v in splits.values {
      if !v.tabIds.contains(where: { gone.contains($0) }) {
        next[v.id] = v
        continue
      }
      let slots = slotsOf(v).map { $0.filter { !gone.contains($0) } }.filter { !$0.isEmpty }
      if slots.flatMap({ $0 }).count < 2 { continue }
      let kept = slotsOf(v).map { $0.contains { !gone.contains($0) } }
      let sizes = v.sizes.enumerated().filter { $0.offset < kept.count && kept[$0.offset] }.map(\.element)
      let total = sizes.reduce(0, +)
      next[v.id] = fromSlots(v, slots, total > 0 ? sizes.map { $0 / total } : nil)
    }
    var out = splits
    out.replace(with: next)
    return out
  }

  public static func sanitizeSplits(_ splits: Table<SplitView>, _ tabs: Table<Tab>) -> Table<SplitView> {
    var next = JSMap<SplitView>()
    var used = Set<String>()
    for v in splits.values {
      let first = tabs[v.tabIds.first ?? ""]
      func ok(_ id: String) -> Bool { tabs[id]?.windowId == v.windowId && tabs[id]?.profileId == first?.profileId && !used.contains(id) }
      let gone = Set(v.tabIds.filter { !ok($0) })
      var single = Table<SplitView>()
      single[v.id] = v
      let fixed = gone.isEmpty ? v : removeFromSplits(single, gone)[v.id]
      guard let fixed, fixed.tabIds.count <= maxPanes else { continue }
      used.formUnion(fixed.tabIds)
      next[v.id] = fixed
    }
    var out = splits
    out.replace(with: next)
    return out
  }
}

extension Session {
  func activateVisiblePane(_ windowId: String, tabId: String) {
    let current = state
    guard current.peeks[windowId] == nil, !memory.closingWindows.contains(windowId),
      current.activeTabId(windowId) != tabId,
      Splits.visiblePaneIds(current, windowId: windowId).contains(tabId) else { return }
    activate(tabId)
  }

  func prepareVisiblePanePages(_ windowIds: [String]) {
    let before = state
    var tabs = before.tabs
    for windowId in windowIds {
      for id in Splits.visiblePaneIds(before, windowId: windowId) {
        guard var tab = tabs[id], needsPage(tab) else { continue }
        if let holder = holderOf(before, id) {
          tab.pageIn = holder.id
          tab.unloaded = nil
        } else {
          wake(&tab)
        }
        tabs[id] = tab
      }
    }
    if tabs != before.tabs { update { $0.tabs = tabs } }
  }

  func gatherPinned(_ s: BrowserState, _ anchorId: String, _ members: [String]) -> BrowserState {
    let newcomers = members.filter { $0 != anchorId && s.tabs[$0] != nil && s.tabs[$0]?.isPinnedRow != true }
    let settled = (Splits.splitOf(s, anchorId)?.tabIds ?? []).filter { !newcomers.contains($0) && s.tabs[$0]?.isPinnedRow == true }
    if newcomers.isEmpty || settled.count < 2 { return s }
    var next = placing(s, newcomers, TabPlacement(pinned: true, row: true, beforeId: .some(anchorId)))
    var w = next.windows[s.tabs[anchorId]!.windowId]!
    let block = members.filter { $0 == anchorId || newcomers.contains($0) }
    var tabIds = w.tabIds.filter { !newcomers.contains($0) }
    tabIds.jsSplice(tabIds.jsIndexOf(anchorId), 1, block)
    w.tabIds = tabIds
    next.windows[w.id] = w
    return next
  }

  func gather(_ s: BrowserState, _ anchorId: String, _ members: [String]) -> BrowserState {
    guard let anchor = s.tabs[anchorId], let w = s.windows[anchor.windowId] else { return s }
    if anchor.pinned { return anchor.isPinnedRow ? gatherPinned(s, anchorId, members) : s }
    let moving = OrderedSet(members.filter { $0 != anchorId && s.tabs[$0] != nil && !s.tabs[$0]!.pinned })
    if moving.isEmpty { return s }
    let block = members.filter { $0 == anchorId || moving.contains($0) }
    var tabIds = w.tabIds.filter { !moving.contains($0) }
    tabIds.jsSplice(tabIds.jsIndexOf(anchorId), 1, block)
    var window = w
    window.tabIds = tabIds
    var groups = Groups.leaveGroups(s.groups, Set(moving.elements))
    if let group = Groups.innermostGroupOf(s.groups, anchorId), var kept = groups[group.id] {
      kept.tabIds += moving.elements
      groups[group.id] = kept
    }
    var next = s
    next.windows[w.id] = window
    next.groups = Groups.syncGroupOrder(groups, window)
    return next
  }

  func placedAfterSplit(_ s: BrowserState, _ split: SplitView, _ tabId: String) -> BrowserState {
    guard let w = s.windows[split.windowId], s.tabs[tabId]?.pinned != true else { return s }
    var tabIds = w.tabIds.filter { $0 != tabId }
    let last = JS.max(split.tabIds.map { tabIds.jsIndexOf($0) })
    tabIds.jsSplice(last + 1, 0, [tabId])
    var window = w
    window.tabIds = tabIds
    var next = s
    next.windows[w.id] = window
    next.groups = Groups.syncGroupOrder(s.groups, window)
    return next
  }

  func withPane(_ existing: SplitView?, _ anchorId: String, _ tabId: String, _ side: String, _ windowId: String) -> SplitView? {
    let horizontal = side == "left" || side == "right"
    let before = side == "left" || side == "top"
    guard let existing else {
      return SplitView(
        id: newId("split"), windowId: windowId, tabIds: before ? [tabId, anchorId] : [anchorId, tabId],
        orientation: horizontal ? "horizontal" : "vertical", sizes: [0.5, 0.5])
    }
    if existing.tabIds.count >= Splits.maxPanes { return nil }
    var slots = Splits.slotsOf(existing)
    guard let k = slots.firstIndex(where: { $0.contains(anchorId) }) else { return nil }
    if (existing.orientation == "horizontal") == horizontal {
      slots.jsSplice(before ? k : k + 1, 0, [[tabId]])
      return Splits.fromSlots(existing, slots)
    }
    slots[k] = before ? [tabId, anchorId] : [anchorId, tabId]
    var out = Splits.fromSlots(existing, slots, existing.sizes)
    out.stack = SplitStack(index: slots[..<k].flatMap { $0 }.count, sizes: [0.5, 0.5])
    return out
  }

  public func createSplit(_ tabIds: [String], orientation: String = "horizontal") -> String {
    let s = state
    let tabs = OrderedSet(tabIds).elements.compactMap { s.tabs[$0] }
    guard let first = tabs.first, tabs.count >= 2, tabs.count <= Splits.maxPanes else { return "" }
    if tabs.contains(where: { $0.windowId != first.windowId || $0.profileId != first.profileId }) { return "" }
    let ids = tabs.map(\.id)
    var splits = Splits.removeFromSplits(s.splits, Set(ids))
    let split = SplitView(id: newId("split"), windowId: first.windowId, tabIds: ids, orientation: orientation, sizes: Splits.equal(ids.count))
    splits[split.id] = split
    var next = s
    next.splits = splits
    set(gather(next, first.id, ids))
    return split.id
  }

  public struct OpenPaneOptions: Sendable {
    public var tabId: String?
    public var url: String?
    public var anchorTabId: String?
    public var side: String?
    public var background: Bool?
    public var adoptId: String?
    public var inPlaceOf: String?
    public init() {}
  }

  public func openSplitPane(_ windowId: String, _ o: OpenPaneOptions) -> JSONValue {
    var s = state
    let w = s.windows[windowId]
    let anchorId = o.anchorTabId ?? w.flatMap { $0.activeTabIds[$0.profileId] }
    guard w != nil, let anchorId, let anchor = s.tabs[anchorId], anchor.windowId == windowId else { return ["ok": false, "reason": "invalid"] }
    let existing = s.splits.values.first { $0.tabIds.contains(anchor.id) }
    let replaced = o.inPlaceOf.flatMap { $0 != anchor.id && existing?.tabIds.contains($0) == true ? $0 : nil }
    if let existing, existing.tabIds.count >= Splits.maxPanes, replaced == nil { return ["ok": false, "reason": "max"] }
    var tabId: String
    if let given = o.tabId, !given.isEmpty {
      guard let t = s.tabs[given], given != anchor.id, t.windowId == windowId, t.profileId == anchor.profileId else {
        return ["ok": false, "reason": "invalid"]
      }
      tabId = given
      s.splits = Splits.removeFromSplits(s.splits, [given])
    } else {
      var options = NewTabOptions()
      options.url = o.url
      let hasUrl = !(o.url ?? "").isEmpty
      options.adoptId = hasUrl ? o.adoptId : nil
      options.profileId = anchor.profileId
      options.openerId = hasUrl ? anchor.id : nil
      options.background = true
      (s, tabId) = withNewTab(s, windowId, options)
    }
    let current = existing.flatMap { s.splits[$0.id] }
    if let replaced, var split = current {
      split.tabIds = split.tabIds.map { $0 == replaced ? tabId : $0 }
      s = gather(s, anchor.id, split.tabIds)
      var withSplit = s
      withSplit.splits[split.id] = split
      s = placedAfterSplit(withSplit, split, replaced)
      if o.background != true { s = activated(s, tabId) }
      set(s)
      return ["ok": true, "tabId": .string(tabId), "splitId": .string(split.id)]
    }
    guard let split = withPane(current, anchor.id, tabId, o.side ?? "right", windowId) else { return ["ok": false, "reason": "max"] }
    var withSplit = s
    withSplit.splits[split.id] = split
    s = gather(withSplit, anchor.id, split.tabIds)
    if o.background != true { s = activated(s, tabId) }
    set(s)
    return ["ok": true, "tabId": .string(tabId), "splitId": .string(split.id)]
  }

  public func replaceSplitPane(_ paneTabId: String, _ tabId: String) {
    var s = state
    guard let split = Splits.splitOf(s, paneTabId), let pane = s.tabs[paneTabId], let tab = s.tabs[tabId], !split.tabIds.contains(tabId),
      tab.windowId == pane.windowId, tab.profileId == pane.profileId
    else { return }
    s.splits = Splits.removeFromSplits(s.splits, [tabId])
    s = gather(s, paneTabId, [paneTabId, tabId])
    var current = s.splits[split.id]!
    current.tabIds = current.tabIds.map { $0 == paneTabId ? tabId : $0 }
    s.splits[split.id] = current
    s = removeTabs(s, [paneTabId], record: false)
    set(activated(s, tabId))
  }

  public func removeTabFromSplit(_ tabId: String) {
    let s = state
    guard let split = Splits.splitOf(s, tabId) else {
      set(s)
      return
    }
    let splits = Splits.removeFromSplits(s.splits, [tabId])
    var next = s
    next.splits = splits
    if splits[split.id] == nil {
      set(next)
      return
    }
    let w = s.windows[split.windowId]!
    let rest = split.tabIds.filter { $0 != tabId }
    var tabIds = w.tabIds.filter { $0 != tabId }
    let last = JS.max(rest.map { tabIds.jsIndexOf($0) })
    tabIds.jsSplice(last + 1, 0, [tabId])
    var window = w
    if s.tabs[tabId]?.pinned != true { window.tabIds = tabIds }
    next.windows[w.id] = window
    next.groups = Groups.syncGroupOrder(s.groups, window)
    set(next)
  }

  public func separateSplit(_ splitId: String) {
    var next = state
    next.splits.remove([splitId])
    set(next)
  }

  public func updateSplit(_ id: String, sizes: [Double]?, stackSizes: [Double]?) {
    var next = state
    guard var split = next.splits[id] else {
      set(next)
      return
    }
    if let sizes, sizes.count == split.sizes.count { split.sizes = sizes }
    if let stackSizes, var stack = split.stack {
      stack.sizes = stackSizes
      split.stack = stack
    }
    next.splits[id] = split
    set(next)
  }

  public func flipSplit(_ splitId: String) {
    var next = state
    guard let split = next.splits[splitId] else {
      set(next)
      return
    }
    next.splits[splitId] = Splits.fromSlots(split, Splits.slotsOf(split).reversed(), split.sizes.reversed())
    set(next)
  }

  public func toggleSplitOrientation(_ splitId: String) {
    var next = state
    guard var split = next.splits[splitId] else {
      set(next)
      return
    }
    split.orientation = split.orientation == "horizontal" ? "vertical" : "horizontal"
    next.splits[splitId] = split
    set(next)
  }

  public func movePane(_ tabId: String, _ delta: Int) {
    var next = state
    guard var split = Splits.splitOf(next, tabId) else {
      set(next)
      return
    }
    let i = split.tabIds.jsIndexOf(tabId)
    let j = i + delta
    if j < 0 || j >= split.tabIds.count {
      set(next)
      return
    }
    split.tabIds.swapAt(i, j)
    next.splits[split.id] = split
    set(next)
  }

  public func focusPane(_ windowId: String, _ delta: Int) {
    let s = state
    let w = s.windows[windowId]
    let active = w.flatMap { $0.activeTabIds[$0.profileId] }
    guard let split = Splits.splitOf(s, active), let active else { return }
    let i = split.tabIds.jsIndexOf(active)
    let count = split.tabIds.count
    activate(split.tabIds[((i + delta) % count + count) % count])
  }

  public func toggleTabLayout(_ windowId: String) {
    var next = state
    guard var w = next.windows[windowId] else {
      set(next)
      return
    }
    let tabLayout = (w.tabLayout ?? next.settings.string("tabLayout") ?? "sidebar") == "sidebar" ? "top" : "sidebar"
    w.tabLayout = tabLayout
    next.windows[windowId] = w
    next.settings = next.settings.choosing(["tabLayout": .string(tabLayout)])
    set(next)
  }
}
