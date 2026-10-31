import SolaraModel

public struct NewTabOptions: Sendable {
  public var url: String?
  public var background: Bool?
  public var adoptId: String?
  public var openerId: String?
  public var profileId: String?
  public var pinned: Bool?
  public var snapshot: TabPatch?
  public var index: Int?
  public var wakeAdoptId: String?
  public var newTabCommand: Bool?

  public init() {}
}

public struct TabUpdate: Sendable {
  public var set: JSONObject
  public var unset: [String]

  public init(set: JSONObject = [:], unset: [String] = []) {
    self.set = set
    self.unset = unset
  }

  func has(_ key: String) -> Bool { set.contains(key) || unset.contains(key) }
  func value(_ key: String) -> JSONValue? { set[key] }
}

func truthy(_ s: String?) -> Bool { !(s ?? "").isEmpty }

let maxClosedTabs = 50

public func fromLegacyUrl(_ url: String) -> String {
  let legacy: [(String, String)] = [("netnyahoo://yahu", "solara://game"), ("chrome://yahu", "chrome://game"), ("netnyahoo://", "solara://")]
  let lower = url.lowercased()
  for prefix in ["", "view-source:"] {
    for (old, now) in legacy {
      if !lower.jsStartsWith(prefix + old) { continue }
      let rest = url.jsSlice(prefix.jsLength + old.jsLength)
      if !old.hasSuffix("://"), !rest.isEmpty, !"/?#".contains(rest.first!) { continue }
      return url.jsSlice(0, prefix.jsLength) + now + rest
    }
  }
  return url
}

extension Session {
  func resolved(_ input: String, _ s: BrowserState) -> String {
    env.resolveInput(fromLegacyUrl(input.jsTrim()), searchUrlPrefix: env.searchUrlPrefix(s.settings))
  }

  func pinnedInsertionIndex(_ s: BrowserState, _ w: BrowserWindow) -> Int {
    var last = -1
    for (i, id) in w.tabIds.enumerated() where s.tabs[id]?.pinned == true { last = i }
    return last + 1
  }

  func tabSection(_ s: BrowserState, _ id: String) -> [String] {
    guard let tab = s.tabs[id], let w = s.windows[tab.windowId] else { return [] }
    return w.tabIds.filter { s.tabs[$0]?.profileId == tab.profileId && s.tabs[$0]?.pinSection == tab.pinSection }
  }

  public func activated(_ s: BrowserState, _ id: String, shareLivePins: Bool = true) -> BrowserState {
    guard let tab = s.tabs[id], let w = s.windows[tab.windowId], s.peeks[w.id]?.tabId != id else { return s }
    let lazy = isLazy(tab)
    let holder = lazy && shareLivePins ? holderOf(s, id) : nil
    let frozen = lazy && (holder != nil || truthy(tab.pageIn))
    var nextTab = tab
    nextTab.unloaded = nil
    nextTab.lastActiveAt = now
    if frozen {
      if let holder {
        nextTab.pageIn = holder.id
        nextTab.url = holder.url
        nextTab.title = holder.title
        nextTab.takeFavicon(from: holder)
        nextTab.muted = holder.muted
      }
    } else if lazy {
      wake(&nextTab)
    }
    var window = w
    if !w.incognito { window.profileId = tab.profileId }
    window.activeTabIds[tab.profileId] = id
    var next = s
    next.tabs[id] = nextTab
    next.windows[w.id] = window
    next.closePanel(w.id)
    return next
  }

  public func removeTabs(_ s: BrowserState, _ ids: [String], record: Bool) -> BrowserState {
    let gone = Set(ids.filter { s.tabs[$0] != nil })
    if gone.isEmpty { return s }
    var closed: [ClosedTab] = []
    var windows = s.windows
    windows.touch()
    var removedWindows: [String] = []
    for w in s.windows.values {
      if !w.tabIds.contains(where: { gone.contains($0) }) { continue }
      if record {
        for (index, id) in w.tabIds.enumerated() {
          guard let t = s.tabs[id], gone.contains(id), !(t.url.isEmpty && !t.pinned) else { continue }
          let group = Groups.innermostGroupOf(s.groups, id)
          let parents = group.map { g in Groups.ancestorIds(s.groups, g.id).map { Groups.closedGroupInfo(s.groups[$0]!) } } ?? []
          closed.append(
            ClosedTab(
              id: newId("ct"), tab: snapshotTab(t), tabId: id, restoreFrom: pendingRestore(t), windowId: w.id, index: index,
              group: group.map(Groups.closedGroupInfo), parents: parents.isEmpty ? nil : parents, closedAt: now,
              small: w.isSmall ? true : nil))
        }
      }
      let tabIds = w.tabIds.filter { !gone.contains($0) }
      if tabIds.isEmpty {
        removedWindows.append(w.id)
        windows.remove([w.id])
        continue
      }
      var activeTabIds = w.activeTabIds
      for (profileId, activeId) in w.activeTabIds {
        if !gone.contains(activeId) { continue }
        let before = w.tabIds.filter { s.tabs[$0]?.profileId == profileId }
        let left = before.filter { !gone.contains($0) }
        let awake = left.filter { s.tabs[$0]?.unloaded != true }
        let after = awake.isEmpty ? left : awake
        let index = before.jsIndexOf(activeId)
        let next = openerSuccessor(s, activeId, before, left) ?? after.first { before.jsIndexOf($0) > index } ?? after.last
        if let next { activeTabIds[profileId] = next } else { activeTabIds.removeValue(forKey: profileId) }
      }
      var window = w
      window.tabIds = tabIds
      window.activeTabIds = activeTabIds
      windows[w.id] = window
    }
    var remaining = s.tabs
    remaining.remove(gone)
    var next = s
    next.tabs = adoptOrphans(remaining, s.tabs, gone)
    next.windows = windows
    if !removedWindows.isEmpty { next.windowOrder = s.windowOrder.filter { !removedWindows.contains($0) } }
    next.groups = Groups.leaveGroups(s.groups, gone)
    next.splits = Splits.removeFromSplits(s.splits, gone)
    if !closed.isEmpty { next.closedTabs = Array((s.closedTabs + closed).suffix(maxClosedTabs)) }
    for w in next.windows.values {
      guard let id = w.activeTabIds[w.profileId], let t = next.tabs[id] else { continue }
      if !t.url.isEmpty && t.navigation == nil && !truthy(t.adoptId) && !truthy(t.pageIn) { next = activated(next, t.id) }
    }
    return next
  }

  func adoptOrphans(_ tabs: Table<Tab>, _ before: Table<Tab>, _ gone: Set<String>) -> Table<Tab> {
    var next = tabs
    for t in tabs.values {
      var opener = t.openerId
      var seen = Set<String>()
      while let o = opener, !o.isEmpty, gone.contains(o), seen.insert(o).inserted { opener = before[o]?.openerId ?? nil }
      if opener == t.openerId { continue }
      var changed = t
      changed.openerId = opener == t.id ? nil : opener
      next[t.id] = changed
    }
    return next
  }

  struct BackToPin {
    var muted: Bool?
    var pinnedUrl: String?
    var url: String?
    var title: String?
    var favicon: String??

    func apply(to t: inout Tab) {
      if let muted { t.muted = muted }
      if let pinnedUrl { t.pinnedUrl = pinnedUrl }
      if let url { t.url = url }
      if let title { t.title = title }
      if let favicon { t.favicon = favicon }
    }
  }

  func historyHint(_ s: BrowserState, _ profileId: String, _ home: String) -> HistoryHint? {
    s.caches.historyHints[profileId]?.first { samePage($0.url, home) }
  }

  func backToPin(_ s: BrowserState, _ t: Tab) -> BackToPin {
    guard let home = t.pinnedUrl, !home.isEmpty, !t.url.isEmpty, !samePage(t.url, home) else { return BackToPin() }
    var back = BackToPin()
    let change = onUrlChange(s, t, home)
    back.muted = change.muted
    back.pinnedUrl = change.pinnedUrl
    back.url = home
    if let entry = historyHint(s, t.profileId, home) {
      back.title = entry.title
      back.favicon = .some(entry.favicon ?? t.favicon)
    }
    return back
  }

  func unloadPinnedTabs(_ s: BrowserState, _ requested: [String], expand: Bool = true) -> BrowserState {
    let pinnedIds = requested.filter { s.inPinnedContainer($0) }
    let ids = expand ? withSharedFamily(s, Splits.withPinnedPanes(s, pinnedIds)) : pinnedIds
    let closing = Set(requested + ids)
    let pinned = ids.filter { s.inPinnedContainer($0) }
    if pinned.isEmpty { return s }
    let gone = Set(pinned)
    var tabs = s.tabs
    tabs.touch()
    var closed: [ClosedTab] = []
    for id in pinned {
      let t = s.tabs[id]!
      let w = s.windows[t.windowId]
      if hasPage(t), !t.url.isEmpty {
        closed.append(
          ClosedTab(
            id: newId("ct"), tab: snapshotTab(t), tabId: id, restoreFrom: nil, windowId: t.windowId, index: w.map { $0.tabIds.jsIndexOf(id) } ?? 0,
            group: nil, parents: nil, closedAt: now, pinnedTile: true))
      }
      let back = backToPin(s, t)
      let pending = back.url == nil && pendingRestore(t) != nil ? t.wakeAdoptId : nil
      var u = t
      back.apply(to: &u)
      u.navigation = nil
      u.adoptId = nil
      u.wakeAdoptId = pending
      u.unloaded = true
      u.pageIn = nil
      tabs[id] = u
    }
    var next = s
    next.tabs = tabs
    let splitGone = Set(pinned.filter { id in !(Splits.splitOf(s, id)?.tabIds.allSatisfy { gone.contains($0) } ?? false) })
    next.splits = Splits.removeFromSplits(s.splits, splitGone)
    if !closed.isEmpty { next.closedTabs = Array((s.closedTabs + closed).suffix(maxClosedTabs)) }
    for w in s.windows.values {
      for (profileId, activeId) in w.activeTabIds {
        if !gone.contains(activeId) { continue }
        let shown = profileId == w.profileId
        var replacement = lastRegularTab(s, w, activeId, closing) ?? lastLivePinnedTab(s, w, activeId, closing)
        if replacement == nil {
          var o = NewTabOptions()
          o.profileId = profileId
          o.background = !shown
          let made = withNewTab(next, w.id, o)
          next = made.0
          replacement = made.1
        }
        if shown {
          next = activated(next, replacement!)
        } else {
          var win = next.windows[w.id]!
          win.activeTabIds[profileId] = replacement!
          next.windows[w.id] = win
        }
      }
    }
    return next
  }

  func lastRegularTab(_ s: BrowserState, _ w: BrowserWindow, _ id: String, _ closing: Set<String>) -> String? {
    let profileId = s.tabs[id]!.profileId
    let candidates = w.tabIds.filter { !closing.contains($0) && s.tabs[$0]?.profileId == profileId && !s.inPinnedContainer($0) }
    let panes = Splits.splitOf(s, id)?.tabIds.filter { candidates.contains($0) } ?? []
    let pool = panes.isEmpty ? candidates : panes
    return pool.reduce(nil as String?) { best, t in best == nil || s.tabs[t]!.lastActiveAt > s.tabs[best!]!.lastActiveAt ? t : best }
  }

  func lastLivePinnedTab(_ s: BrowserState, _ w: BrowserWindow, _ id: String, _ closing: Set<String>) -> String? {
    let profileId = s.tabs[id]!.profileId
    let live = w.tabIds.filter { t in
      guard let tab = s.tabs[t] else { return false }
      return !closing.contains(t) && tab.profileId == profileId && s.inPinnedContainer(t) && hasPage(tab)
    }
    return live.reduce(nil as String?) { best, t in best == nil || s.tabs[t]!.lastActiveAt > s.tabs[best!]!.lastActiveAt ? t : best }
  }

  public func withNewTab(_ input: BrowserState, _ windowId: String, _ o: NewTabOptions = NewTabOptions()) -> (BrowserState, String) {
    var s = input
    if truthy(o.openerId), o.background != true { s = forgetOpeners(s, windowId) }
    guard let w = s.windows[windowId] else { return (s, "") }
    let profileId = w.incognito ? w.profileId : (truthy(o.profileId) && s.profiles[o.profileId!] != nil ? o.profileId! : w.profileId)
    let url = truthy(o.url) ? resolved(o.url!, s) : ""
    var patch = o.snapshot ?? TabPatch()
    patch.pinned = o.pinned ?? o.snapshot?.pinned ?? false
    var tab = makeTab(windowId, profileId, url, patch)
    if tab.navigation != nil, o.snapshot == nil { tab.navigation = navigationTo(url, userInitiated: true) }
    tab.openerId = o.openerId
    if tab.pinned {
      tab.pinnedUrl = truthy(tab.pinnedUrl) ? tab.pinnedUrl : (url.isEmpty ? nil : url)
    } else {
      tab.pinnedUrl = truthy(tab.pinnedUrl) ? tab.pinnedUrl : nil
    }
    if truthy(o.adoptId) {
      tab.adoptId = o.adoptId
      tab.navigation = nil
    } else if truthy(o.wakeAdoptId) {
      tab.wakeAdoptId = o.wakeAdoptId
      tab.navigation = nil
    }
    var tabs = s.tabs
    tabs[tab.id] = tab
    var tabIds = w.tabIds
    let at = o.index ?? (tab.pinned ? pinnedInsertionIndex(s, w) : insertionIndex(s, w, tab, o.background == true))
    tabIds.jsSplice(min(at, tabIds.count), 0, [tab.id])
    var window = w
    window.tabIds = pinnedFirst(tabIds, tabs, s.groups)
    if w.activeTabIds[profileId] == nil || w.activeTabIds[profileId]!.isEmpty { window.activeTabIds[profileId] = tab.id }
    var next = s
    next.tabs = tabs
    next.windows[windowId] = window
    if o.background != true { next = activated(next, tab.id) }
    return (next, tab.id)
  }

  public func closingTabs(_ s: BrowserState, _ ids: [String], lastClosesWindow: Bool = false, windowClosedByChrome: Bool = false) -> (BrowserState, [String]) {
    var next = s
    for id in ids where isPeekTab(next, id) { next = withoutPeek(next, next.tabs[id]!.windowId) }
    let asked = ids.filter { next.tabs[$0] != nil }
    next = unloadPinnedTabs(next, asked)
    let gone = asked.filter { !next.inPinnedContainer($0) }
    let goneSet = Set(gone)
    var closedWindows: [String] = []
    for w in next.windows.values {
      let view = next.viewTabIds(w.id)
      let shown = view.filter { goneSet.contains($0) }
      if shown.isEmpty || !view.allSatisfy({ goneSet.contains($0) || next.tabs[$0]!.unloaded == true }) { continue }
      let probe = shown.count > 1 ? removeTabs(next, Array(shown.dropFirst()), record: false) : next
      let keepsWindow = !windowClosedByChrome && (!lastClosesWindow || leavesEmptyWindow(probe, shown[0]))
      if keepsWindow { next = withNewTab(next, w.id).0 } else { closedWindows.append(w.id) }
    }
    let removed = gone.filter { !closedWindows.contains(next.tabs[$0]!.windowId) }
    return (removeTabs(next, removed, record: true), closedWindows)
  }

  public func newTab(_ windowId: String, _ options: NewTabOptions? = nil) -> String {
    if let small = state.windows[windowId], small.isSmall, !small.tabIds.isEmpty {
      let profileId = options?.profileId ?? small.profileId
      guard let main = mainWindowFor(state, profileId) else {
        var o = CreateWindowOptions()
        o.profileId = profileId
        o.url = options?.url
        o.adoptId = options?.adoptId ?? options?.wakeAdoptId
        o.background = options?.background
        let created = createWindow(o)
        return state.activeTabId(created) ?? ""
      }
      var o = options ?? NewTabOptions()
      o.profileId = profileId
      o.index = nil
      return newTab(main, o)
    }
    let beside = options?.newTabCommand == true && !truthy(options?.openerId) ? nextToActive(state, windowId, options?.profileId) : nil
    var o = options ?? NewTabOptions()
    if let beside {
      o.openerId = beside.openerId
      o.index = beside.index
    }
    var (next, id) = withNewTab(state, windowId, o)
    if beside != nil, let typed = next.tabs[id]?.navigation {
      var t = next.tabs[id]!
      t.engine = engineForUrl(next, typed.url)
      next.tabs[id] = t
    }
    if !id.isEmpty, let opener = options?.openerId, !opener.isEmpty {
      next = groupWithOpener(next, id, opener, background: options?.background == true)
    } else if !id.isEmpty, let beside, !next.inPinnedContainer(beside.openerId) {
      next = groupWithOpener(next, id, beside.openerId, background: false)
    }
    set(next)
    return id
  }

  public func closeTab(_ id: String) {
    closeTabs([id], lastClosesWindow: true)
  }

  public func closeTabs(_ ids: [String], lastClosesWindow: Bool = false, windowClosedByChrome: Bool = false) {
    let (next, closedWindows) = closingTabs(state, ids, lastClosesWindow: lastClosesWindow, windowClosedByChrome: windowClosedByChrome)
    set(next)
    for windowId in closedWindows { closeWindow(windowId) }
  }

  public func activate(_ id: String) {
    let s = state
    guard let tab = s.tabs[id] else { return }
    if tab.navigation == nil, !truthy(tab.adoptId), holderOf(s, id) != nil {
      if config.handOffPinsImmediately { handOffPin(id) } else { emit(.pinHandoff(tabId: id)) }
      return
    }
    let shown = s.activeTabId(tab.windowId)
    var next = activated(s, id)
    if let shown, shown != id, !switchKeepsOpeners(s, shown, id) { next = forgetOpeners(next, tab.windowId) }
    set(next)
  }

  public func handOffPin(_ id: String) {
    let s = state
    guard let tab = s.tabs[id] else { return }
    let swapped = swapPinPage(s, id)
    let base = swapped?.state ?? s
    let shown = s.activeTabId(tab.windowId)
    let target = swapped?.holderId ?? id
    var next = activated(base, target)
    if let shown, shown != id, !switchKeepsOpeners(base, shown, target) { next = forgetOpeners(next, tab.windowId) }
    set(next)
  }

  public func activateIndex(_ windowId: String, _ index: Int) {
    let view = state.viewTabIds(windowId)
    let id = index < 0 ? view.last : (index < view.count ? view[index] : nil)
    if let id { activate(id) }
  }

  public func cycle(_ windowId: String, _ delta: Int) {
    let s = state
    let view = s.viewTabIds(windowId)
    let active = s.windows[windowId].flatMap { $0.activeTabIds[$0.profileId] } ?? ""
    let i = view.jsIndexOf(active)
    if !view.isEmpty { activate(view[((i + delta) % view.count + view.count) % view.count]) }
  }

  public func navigate(_ id: String, _ input: String, userInitiated: Bool = true) {
    let copy = state.tabs[id]
    let holder = copy.flatMap { c in c.navigation == nil && !truthy(c.adoptId) ? holderOf(state, id) : nil }
    if let copy, let holder {
      if state.activeTabId(copy.windowId) != id {
        navigate(holder.id, input, userInitiated: userInitiated)
        return
      }
      handOffPin(id)
      if let held = state.tabs[holder.id], held.windowId == copy.windowId, !truthy(held.pageIn) {
        navigate(held.id, input, userInitiated: userInitiated)
      }
      return
    }
    let s = state
    let url = resolved(input, s)
    guard !url.isEmpty, let tab = s.tabs[id] else { return }
    let base = userInitiated && !tab.url.isEmpty ? forgetOpeners(s, tab.windowId) : s
    let navigation = navigationTo(url, userInitiated: userInitiated)
    let engine = userInitiated ? typedNavigationEngine(s, tab, url) : nil
    let switching = engine != nil && engine != tabEngine(s, id)
    if !switching { emit(.startNavigation(tabId: id, navigation: navigation)) }
    var t = tab
    t.unloaded = nil
    t.wakeAdoptId = nil
    t.takeOpener(from: base.tabs[id]!)
    t.navigation = navigation
    t.url = tab.url.isEmpty ? url : tab.url
    if let engine { t.engine = engine }
    if switching { t.adoptId = nil }
    var next = base
    next.tabs[id] = t
    next.closePanel(tab.windowId)
    set(next)
  }

  public func updateTab(_ id: String, _ patch: TabUpdate) {
    updateTab(id, patch, live: nil)
  }

  func updateTab(_ id: String, _ patch: TabUpdate, live: PageLiveFacts?) {
    let s = state
    guard let tab = s.tabs[id] else { return }
    let url = patch.value("url")?.string
    let urlChanged = url != nil && url != tab.url
    let supersedes =
      truthy(tab.wakeAdoptId) && !patch.has("wakeAdoptId")
      && ((patch.value("navigation")?.truthy ?? false) || (patch.value("adoptId")?.truthy ?? false) || urlChanged)
    var json = tab.json
    if urlChanged {
      let change = onUrlChange(s, tab, url!)
      if let muted = change.muted { json["muted"] = .bool(muted) }
      if let pinned = change.pinnedUrl { json["pinnedUrl"] = .string(pinned) }
    }
    for (key, value) in patch.set { json[key] = value }
    for key in patch.unset { json.removeValue(forKey: key) }
    if supersedes { json.removeValue(forKey: "wakeAdoptId") }
    guard var next = try? Tab(json: json) else { return }
    next.id = tab.id
    if next == tab && (live == nil || live == s.live[id]) { return }
    var state = s
    if next != tab { state.tabs[id] = next }
    if let live { state.live[id] = live }
    set(state)
  }

  public func duplicateTab(_ id: String) -> String? {
    let s = state
    guard let source = s.tabs[id] else { return nil }
    let w = s.windows[source.windowId]!
    var snap = TabPatch(snapshotTab(source))
    snap.pinned = false
    var o = NewTabOptions()
    o.url = source.url.isEmpty ? nil : source.url
    o.profileId = source.profileId
    o.snapshot = snap
    o.index = w.tabIds.jsIndexOf(id) + 1
    o.adoptId = source.url.isEmpty ? nil : "clone:\(id)"
    let (next, copy) = withNewTab(s, w.id, o)
    set(next)
    return copy
  }

  public func togglePin(_ id: String) {
    if let tab = state.tabs[id] { pinTabs([id], pinned: !tab.pinned, row: nil) }
  }

  public func moveTab(_ id: String, _ toIndex: Int) {
    let s = state
    guard let tab = s.tabs[id], let w = s.windows[tab.windowId] else {
      set(s)
      return
    }
    let section = tabSection(s, id)
    let inSection = Set(section)
    var moved = section.filter { $0 != id }
    moved.jsSplice(min(max(toIndex, 0), moved.count), 0, [id])
    var k = 0
    var window = w
    window.tabIds = w.tabIds.map { t in
      guard inSection.contains(t) else { return t }
      defer { k += 1 }
      return moved[k]
    }
    var next = s
    next.windows[w.id] = window
    next.groups = Groups.syncGroupOrder(s.groups, window)
    set(next)
  }

  public func moveTabBy(_ id: String, _ delta: Int) {
    _ = dropTabs([id], stepDrop(state, id, delta))
  }

  func leavesEmptyWindow(_ s: BrowserState, _ id: String) -> Bool {
    guard let tab = s.tabs[id], let w = s.windows[tab.windowId], !w.isSmall else { return false }
    if memory.lastTabKeepsWindow { return s.closesWindow(id) }
    if w.incognito || isEmptyCardTab(s, tab) { return false }
    return s.closesWindow(id)
  }

  func isEmptyCardTab(_ s: BrowserState, _ tab: Tab?) -> Bool {
    guard let tab else { return false }
    return !tab.pinned && tab.url.isEmpty && tab.navigation == nil && !truthy(tab.adoptId) && Splits.splitOf(s, tab.id) == nil
  }
}
