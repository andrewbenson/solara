import SolaraModel

public struct CreateWindowOptions: Sendable {
  public var profileId: String?
  public var incognito: Bool?
  public var url: String?
  public var adoptId: String?
  public var tabIds: [String]?
  public var frame: [Double]?
  public var small: Bool?
  public var linkPointer: [Double]?
  public var background: Bool?
  public var chromeWindow: String?

  public init() {}
}

let maxClosedWindows = 10

extension Session {
  func emptyWindow(_ id: String, _ profileId: String, _ incognito: Bool, _ frame: [Double]? = nil) -> BrowserWindow {
    BrowserWindow(id: id, profileId: profileId, incognito: incognito, frame: frame, createdAt: now)
  }

  func smallWindow(_ id: String, _ profileId: String, _ frame: [Double]? = nil) -> BrowserWindow {
    var w = emptyWindow(id, profileId, false, frame)
    w.sidebarOpen = false
    w.kind = "small"
    return w
  }

  func lastProfileAfterClosing(_ s: BrowserState, _ id: String) -> String? {
    guard let w = s.windows[id], !w.incognito, s.ui.focusedWindowId == id else { return s.ui.lastProfileId }
    let next = s.ui.focusOrder.first { $0 != id && linkProfileOf(s, s.windows[$0]) != nil }
    return linkProfileOf(s, next.flatMap { s.windows[$0] }) ?? s.ui.lastProfileId
  }

  func withWindow(_ s: BrowserState, _ w: BrowserWindow) -> BrowserState {
    var next = s
    next.windows[w.id] = w
    next.windowOrder.append(w.id)
    next.ui.focusedWindowId = w.id
    next.ui.focusOrder = [w.id] + s.ui.focusOrder
    next.ui.lastProfileId = linkProfileOf(s, w) ?? s.ui.lastProfileId
    return next
  }

  enum MovedTabsLanding { case end, newTab }

  func moveTabsInto(_ s: BrowserState, _ ids: [String], _ targetId: String, landing: MovedTabsLanding = .end) -> BrowserState {
    guard let target = s.windows[targetId], !target.isSmall else { return s }
    let moving = ids.compactMap { s.tabs[$0] }.filter { $0.windowId != targetId && !Ids.isIncognitoProfile($0.profileId) && !target.incognito }
    if moving.isEmpty { return s }
    let sources = OrderedSet(moving.map(\.windowId))
    var next = removeTabs(s, moving.map(\.id), record: false)
    let w = next.windows[targetId]!
    var landed = w.tabIds
    landed.insert(contentsOf: moving.map(\.id), at: landing == .newTab ? newTabSlot(next, w, moving[0]) : w.tabIds.count)
    var tabs = next.tabs
    var activeTabIds = w.activeTabIds
    for tab in moving {
      var t = tab
      t.adoptId = nil
      t.windowId = targetId
      t.navigation = hasLoadedPage(tab) ? navigationTo(t.url) : nil
      tabs[t.id] = t
      if activeTabIds[t.profileId] == nil { activeTabIds[t.profileId] = t.id }
    }
    next.tabs = tabs
    var window = w
    window.tabIds = pinnedFirst(landed, tabs, next.groups)
    window.activeTabIds = activeTabIds
    next.windows[targetId] = window
    for id in sources {
      guard let src = next.windows[id], next.viewTabIds(id).isEmpty else { continue }
      let recent = src.tabIds.map { next.tabs[$0]! }.stableSorted { $0.lastActiveAt > $1.lastActiveAt }.first
      if let recent { next = activated(next, src.activeTabIds[recent.profileId] ?? recent.id) }
    }
    return settleMovedPins(s, next, moving.map(\.id), targetId)
  }

  func restoreGroup(_ groups: inout Table<TabGroup>, _ g: TabGroup) -> String {
    let id = groups[g.id] != nil ? newId("g") : g.id
    var group = g
    group.id = id
    groups[id] = group
    return id
  }

  public func createWindow(_ o: CreateWindowOptions = CreateWindowOptions()) -> String {
    let s = state
    let id = newId("w")
    let small = o.small == true && o.incognito != true
    let known = o.profileId.flatMap { !$0.isEmpty && s.profiles[$0] != nil ? $0 : nil }
    let restoredPrivate = o.incognito == true && o.chromeWindow != nil ? o.profileId.flatMap { Ids.isIncognitoProfile($0) && s.profiles[Ids.incognitoOriginal($0)] != nil ? $0 : nil } : nil
    let original: String? = o.incognito == true ? (restoredPrivate.map(Ids.incognitoOriginal) ?? known ?? lastActiveProfile(s)) : nil
    let profileId = restoredPrivate ?? original.map { Ids.incognitoProfileId(windowId: id, originalProfileId: $0) } ?? (known ?? (small ? lastActiveProfile(s) : s.settings.defaultProfileId))
    var w = small ? smallWindow(id, profileId, o.frame) : emptyWindow(id, profileId, o.incognito == true, o.frame)
    if let original { w.originalProfileId = original }
    if small, let pointer = o.linkPointer { w.linkPointer = pointer }
    if let chrome = o.chromeWindow, !chrome.isEmpty { w.chromeWindow = chrome }
    var next = withWindow(s, w)
    if let tabIds = o.tabIds, !tabIds.isEmpty, !small { next = moveTabsInto(next, tabIds, id) }
    if next.windows[id]!.tabIds.isEmpty {
      var t = NewTabOptions()
      t.url = o.url
      t.adoptId = o.adoptId
      next = withNewTab(next, id, t).0
    }
    let first = next.windows[id]!.tabIds[0]
    let shown = next.windows[id]!.activeTabIds[next.tabs[first]!.profileId] ?? first
    if !small { next = adoptParkedPins(next, id, next.tabs[shown]!.profileId) }
    next = activated(next, shown)
    if o.background == true, let focused = s.ui.focusedWindowId, s.windows[focused] != nil {
      next.ui.focusedWindowId = focused
      next.ui.focusOrder = [focused, id] + s.ui.focusOrder.filter { $0 != focused }
      next.ui.lastProfileId = s.ui.lastProfileId
    }
    set(next)
    return id
  }

  public func closeWindow(_ id: String) {
    let before = state
    let s = returnSharedPages(before, id)
    guard let w = s.windows[id] else { return }
    let tabs = w.tabIds.compactMap { s.tabs[$0] }.filter { !s.inPinnedContainer($0.id) && !sharedElsewhere(s, $0) }
    let tabIds = tabs.map(\.id)
    let small = w.isSmall
    var closedWindows = s.closedWindows
    if !w.incognito && !small && tabs.contains(where: { !$0.url.isEmpty }) {
      let active = Set(w.activeTabIds.values)
      let entryTabs = tabs.map { t -> ClosedWindowTab in
        let tabId: String? = hasLoadedPage(t) ? t.id : pendingRestore(t)
        return ClosedWindowTab(snapshot: snapshotTab(t), active: active.contains(t.id), tabId: tabId)
      }
      let groups = s.groups.values.filter { g in g.windowId == id && !g.pinned && (!sharesTabs(s) || g.tabIds.contains { tabIds.contains($0) }) }
        .map { ClosedWindowGroup(group: $0, tabIndexes: $0.tabIds.map { tabIds.jsIndexOf($0) }) }
      var entry = ClosedWindow(
        id: newId("cw"), profileId: w.profileId, sidebarOpen: w.sidebarOpen, frame: w.frame, tabs: entryTabs, groups: groups, closedAt: now)
      entry.keepPresentation(of: w)
      entry.absent = w.absent.intersection(["frame"])
      closedWindows = Array((closedWindows + [entry]).suffix(maxClosedWindows))
    }
    var next = removeTabs(s, w.tabIds, record: small)
    next.windows.remove([id])
    next.windowOrder = next.windowOrder.filter { $0 != id }
    next.closedWindows = closedWindows
    next.parkedPins = small ? s.parkedPins : parkWindowPins(s.parkedPins, w, s)
    if w.incognito { next.closedTabs = next.closedTabs.filter { $0.windowId != id } }
    let focusOrder = next.ui.focusOrder
    next.ui.focusOrder = focusOrder.filter { $0 != id }
    next.ui.focusedWindowId = next.ui.focusedWindowId == id ? focusOrder.first { $0 != id } : next.ui.focusedWindowId
    next.ui.lastProfileId = lastProfileAfterClosing(s, id)
    set(next)
    rememberClosingWindow(id, before: before)
  }

  public func forgetClosedWindow(_ id: String) {
    var next = state
    next.closedWindows = next.closedWindows.filter { $0.id != id }
    set(next)
  }

  public func setWindowFrame(_ id: String, _ frame: [Double]) {
    var next = state
    guard var w = next.windows[id], w.frame != frame else {
      set(next)
      return
    }
    w.frame = frame
    next.windows[id] = w
    if w.isSmall {
      let size = [frame.count > 2 ? (frame[2] + 0.5).rounded(.down) : .nan, frame.count > 3 ? (frame[3] + 0.5).rounded(.down) : .nan]
      let current = next.settings["littleSolaraSize"]?.array?.compactMap(\.number) ?? []
      if current != size { next.settings = next.settings.merging(["littleSolaraSize": .array(size.map(JSONValue.number))]) }
    }
    set(next)
  }

  public func setWindowFullScreen(_ id: String, _ on: Bool) {
    var next = state
    guard var w = next.windows[id], (w.fullScreen.map { $0 != 0 } ?? false) != on else {
      set(next)
      return
    }
    w.fullScreen = on ? now : nil
    next.windows[id] = w
    set(next)
  }

  public func setWindowSidebar(_ windowId: String, _ patch: JSONObject) throws {
    guard let window = state.windows[windowId], !window.isSmall else { return }
    let widths = ["sidebarWidth", "sidePanelWidth"]
    for key in patch.keys {
      guard widths.contains(key) ? patch[key]?.number != nil : key == "sidebarIconsOnly" && patch[key]?.bool != nil else {
        throw CommandError("setWindowSidebar: invalid sidebar patch")
      }
    }
    var next = state
    var settingsPatch: JSONObject = [:]
    for (key, value) in patch {
      let setting = key == "sidePanelWidth" ? "extensionSidePanelWidth" : key
      settingsPatch[setting] = value
      for original in state.windows.values where !original.isSmall {
        var changed = next.windows[original.id]!
        let target = original.id == windowId
        switch key {
        case "sidebarWidth":
          if target { changed.sidebarWidth = value.number }
          else if original.sidebarWidth == nil { changed.sidebarWidth = original.effectiveSidebarWidth(state.settings) }
        case "sidebarIconsOnly":
          if target { changed.sidebarIconsOnly = value.bool }
          else if original.sidebarIconsOnly == nil { changed.sidebarIconsOnly = original.effectiveSidebarIconsOnly(state.settings) }
        case "sidePanelWidth":
          if target { changed.sidePanelWidth = value.number }
          else if original.sidePanelWidth == nil { changed.sidePanelWidth = original.effectiveSidePanelWidth(state.settings) }
        default: break
        }
        next.windows[original.id] = changed
      }
    }
    next.settings = next.settings.choosing(settingsPatch)
    set(next)
  }

  public func toggleSidebar(_ windowId: String) {
    var next = state
    if var w = next.windows[windowId] {
      w.sidebarOpen.toggle()
      next.windows[windowId] = w
    }
    set(next)
  }

  public func switchProfile(_ windowId: String, _ profileId: String) {
    var s = state
    guard let w = s.windows[windowId], !w.incognito, !w.isSmall, s.profiles[profileId] != nil, w.profileId != profileId else { return }
    s = adoptParkedPins(s, windowId, profileId)
    let remembered = w.activeTabIds[profileId]
    var target = remembered.flatMap { s.tabs[$0]?.windowId == windowId ? $0 : nil }
    if target == nil { target = s.windows[windowId]!.tabIds.first { s.tabs[$0]?.profileId == profileId && s.tabs[$0]!.unloaded != true } }
    if target == nil {
      var o = NewTabOptions()
      o.profileId = profileId
      o.background = true
      let made = withNewTab(s, windowId, o)
      s = made.0
      target = made.1
    }
    s = activated(s, target!)
    if s.ui.focusedWindowId == windowId { s.ui.lastProfileId = profileId }
    set(s)
  }

  public func moveTabsToWindow(_ tabIds: [String], _ windowId: String?) -> String? {
    let s = state
    guard let windowId else {
      guard let first = s.tabs[tabIds.first ?? ""], !Ids.isIncognitoProfile(first.profileId) else { return nil }
      var o = CreateWindowOptions()
      o.profileId = first.profileId
      o.tabIds = tabIds
      return createWindow(o)
    }
    let beside = nextToActive(s, windowId, s.tabs[tabIds.first ?? ""]?.profileId)
    var next = moveTabsInto(s, tabIds, windowId, landing: .newTab)
    if let beside, !next.inPinnedContainer(beside.openerId) {
      for id in tabIds where s.tabs[id]?.windowId != windowId && next.tabs[id]?.windowId == windowId {
        next = groupWithOpener(next, id, beside.openerId, background: false)
      }
    }
    if let last = tabIds.last(where: { next.tabs[$0]?.windowId == windowId }) { next = activated(next, last) }
    set(next)
    return windowId
  }

  public func moveTabToProfile(_ tabId: String, _ profileId: String) {
    let s = state
    guard let tab = s.tabs[tabId], let w = s.windows[tab.windowId], !w.incognito, s.profiles[profileId] != nil, tab.profileId != profileId else { return }
    var next = removeTabs(s, [tabId], record: false)
    var base = next.windows[w.id] ?? w
    if next.windows[w.id] == nil {
      base.tabIds = []
      base.activeTabIds = JSMap()
    }
    let loaded = hasLoadedPage(tab)
    var moved = tab
    moved.adoptId = nil
    moved.wakeAdoptId = nil
    moved.profileId = profileId
    moved.navigation = loaded ? navigationTo(tab.url) : nil
    moved.lastActiveAt = now
    let movedKey = moved.pinKeyOrId
    if tab.pinned {
      var mine = next.pinChoices[profileId] ?? JSMap()
      mine[movedKey] = nextPinChoice()
      mine[placeChoiceKey(movedKey)] = nextPinChoice()
      next.pinChoices[profileId] = mine
    }
    next.tabs[tabId] = moved
    let index = min(w.tabIds.jsIndexOf(tabId), base.tabIds.count)
    var tabIds = base.tabIds
    tabIds.jsSplice(index, 0, [tabId])
    base.tabIds = pinnedFirst(tabIds, next.tabs, next.groups)
    next.windows[w.id] = base
    if !next.windowOrder.contains(w.id) { next.windowOrder = s.windowOrder }
    set(activated(next, tabId))
  }

  public func mergeAllWindows(_ windowId: String) {
    let s = state
    let current = s.windows[windowId]
    guard let target = current?.incognito == true || current?.isSmall == true ? mainWindowFor(s) : windowId else { return }
    let others = s.windowOrder.filter { $0 != target && s.windows[$0]?.incognito != true && s.windows[$0]?.isSmall != true }
    let tabIds = others.flatMap { s.windows[$0]?.tabIds ?? [] }
    if tabIds.isEmpty { return }
    var next = moveTabsInto(s, tabIds, target)
    var groups = next.groups
    groups.touch()
    let taken = Set(next.groups.values.flatMap(\.tabIds))
    for g in s.groups.values where others.contains(g.windowId) {
      let members = g.tabIds.filter { next.tabs[$0]?.windowId == target && !taken.contains($0) }
      if !members.isEmpty {
        var moved = g
        moved.windowId = target
        moved.tabIds = members
        groups[g.id] = moved
      }
    }
    next.groups = groups
    set(next)
  }

  func shownProfile(_ s: BrowserState, _ windowId: String?, _ profileId: String?) -> Bool {
    guard let windowId else { return true }
    return profileId == s.windows[windowId]!.profileId
  }

  func canRestoreTabInto(_ s: BrowserState, _ c: ClosedTab, _ windowId: String?) -> Bool {
    let w = windowId.flatMap { s.windows[$0] }
    if Ids.isIncognitoProfile(c.tab.profileId) { return c.windowId == windowId }
    return w?.incognito != true
  }

  func lastClosedTab(_ s: BrowserState, _ windowId: String?) -> ClosedTab? {
    s.closedTabs.last { c in
      canRestoreTabInto(s, c, windowId) && (Ids.isIncognitoProfile(c.tab.profileId) || shownProfile(s, windowId, c.tab.profileId))
    }
  }

  public func reopenClosed(_ windowId: String?) {
    let s = state
    let target = s.resolveWindowId(windowId)
    let lastTab = lastClosedTab(s, target)
    func regular(_ p: String?) -> Bool { s.windows[target ?? ""]?.incognito != true && shownProfile(s, target, p) }
    let lastWindow = s.closedWindows.last { regular($0.profileId) }
    let lastGroup = s.closedGroups.last { regular($0.tabs.first?.profileId) }
    let candidates: [(id: String, closedAt: Double)?] = [
      lastWindow.map { ($0.id, $0.closedAt) }, lastGroup.map { ($0.id, $0.closedAt) }, lastTab.map { ($0.id, $0.closedAt) },
    ]
    var latest: (id: String, closedAt: Double)? = nil
    for e in candidates { if let e, latest == nil || e.closedAt > latest!.closedAt { latest = e } }
    if let latest { restoreClosed(latest.id, target) }
  }

  public func reopenClosedTab(_ windowId: String?) {
    let s = state
    let target = s.resolveWindowId(windowId)
    if let entry = lastClosedTab(s, target) { restoreClosed(entry.id, target) }
  }

  public func reopenClosedWindow() {
    if let entry = state.closedWindows.last { restoreClosed(entry.id, nil) }
  }

  public func restoreClosed(_ entryId: String, _ requested: String?) {
    let s = state
    var windowId = requested
    if let w = windowId, s.windows[w]?.isSmall == true { windowId = mainWindowFor(s) }
    if let closedTab = s.closedTabs.first(where: { $0.id == entryId }) {
      set(restoreTab(s, closedTab, windowId))
      return
    }
    if let closedWindow = s.closedWindows.first(where: { $0.id == entryId }) {
      set(restoreWindow(s, closedWindow))
      return
    }
    if let closedGroup = s.closedGroups.first(where: { $0.id == entryId }) ?? s.deletedGroups.first(where: { $0.id == entryId }) {
      set(restoringGroup(s, closedGroup, windowId))
    }
  }

  func restoreTab(_ s: BrowserState, _ entry: ClosedTab, _ requested: String?) -> BrowserState {
    let owner = entry.tab.profileId
    if entry.pinnedTile == true, let tabId = entry.tabId, !tabId.isEmpty, s.tabs[tabId] == nil,
      s.parkedPins[owner]?.tabs.contains(where: { $0.id == tabId }) == true
    {
      let target = s.resolveWindowId(requested)
      var windowId = target.flatMap { t in !s.windows[t]!.incognito && s.windows[t]!.profileId == owner ? t : nil }
      var next = s
      if windowId == nil {
        let id = newId("w")
        windowId = id
        next = withWindow(next, emptyWindow(id, owner, false))
      }
      next = adoptParkedPins(next, windowId!, owner)
      if next.tabs[tabId] != nil { return restoreTab(next, entry, windowId) }
    }
    let closedTabs = s.closedTabs.filter { $0.id != entry.id }
    if entry.small == true && !Ids.isIncognitoProfile(entry.tab.profileId) {
      let id = newId("w")
      let profileId = s.profiles[entry.tab.profileId] != nil ? entry.tab.profileId : lastActiveProfile(s)
      var base = s
      base.closedTabs = closedTabs
      let next = withWindow(base, smallWindow(id, profileId))
      var snap = TabPatch(entry.tab)
      snap.pinned = false
      snap.profileId = profileId
      var o = NewTabOptions()
      o.url = entry.tab.url.isEmpty ? nil : entry.tab.url
      o.profileId = profileId
      o.snapshot = snap
      o.adoptId = truthy(entry.tabId) && !entry.tab.url.isEmpty ? restoreId(entry.restoreFrom ?? entry.tabId!) : nil
      return withNewTab(next, id, o).0
    }
    let tile = entry.pinnedTile == true ? entry.tabId.flatMap { s.tabs[$0] } : nil
    if let tile, !hasPage(tile), holderOf(s, tile.id) != nil {
      var base = s
      base.closedTabs = closedTabs
      if let swapped = swapPinPage(base, tile.id) { return activated(swapped.state, swapped.holderId) }
    }
    if let tile {
      var next = s
      next.closedTabs = closedTabs
      if !hasPage(tile) {
        var t = tile
        t.url = entry.tab.url
        t.title = entry.tab.title
        t.favicon = entry.tab.favicon
        t.muted = entry.tab.muted
        t.adoptId = restoreId(entry.restoreFrom ?? tile.id)
        next.tabs[tile.id] = t
      }
      return activated(next, tile.id)
    }
    let original = s.windows[entry.windowId]
    var windowId = original.flatMap { canRestoreTabInto(s, entry, $0.id) ? $0.id : nil } ?? s.resolveWindowId(requested)
    var next = s
    next.closedTabs = closedTabs
    if windowId == nil || !canRestoreTabInto(s, entry, windowId) {
      if Ids.isIncognitoProfile(entry.tab.profileId) { return next }
      let id = newId("w")
      windowId = id
      next = withWindow(next, emptyWindow(id, s.profiles[entry.tab.profileId] != nil ? entry.tab.profileId : s.settings.defaultProfileId, false))
    }
    let w = next.windows[windowId!]!
    let profileId = Ids.isIncognitoProfile(entry.tab.profileId) || s.profiles[entry.tab.profileId] != nil ? entry.tab.profileId : w.profileId
    var o = NewTabOptions()
    o.url = entry.tab.url.isEmpty ? nil : entry.tab.url
    o.profileId = profileId
    o.snapshot = TabPatch(entry.tab)
    o.index = w.id == entry.windowId ? entry.index : nil
    o.adoptId = truthy(entry.tabId) && !entry.tab.url.isEmpty ? restoreId(entry.restoreFrom ?? entry.tabId!) : nil
    let (withTab, tabId) = withNewTab(next, windowId!, o)
    next = withTab
    if let group = entry.group {
      var made: [String: String] = [:]
      next.groups = rejoinGroups(next.groups, [group] + (entry.parents ?? []), [tabId], windowId!, profileId, made: &made)
    }
    return next
  }

  func restoreWindow(_ s: BrowserState, _ entry: ClosedWindow) -> BrowserState {
    let id = newId("w")
    func profileOk(_ p: String) -> String { s.profiles[p] != nil ? p : s.settings.defaultProfileId }
    var w = emptyWindow(id, profileOk(entry.profileId), false, entry.frame)
    w.sidebarOpen = entry.sidebarOpen
    w.tabLayout = entry.tabLayout
    w.fullScreen = entry.fullScreen
    w.sidebarWidth = entry.sidebarWidth
    w.sidebarIconsOnly = entry.sidebarIconsOnly
    w.sidePanelWidth = entry.sidePanelWidth
    var tabs = s.tabs
    var ids: [String] = []
    for item in entry.tabs {
      var snap = TabPatch(item.snapshot)
      snap.profileId = profileOk(item.snapshot.profileId)
      var t = makeTab(id, profileOk(item.snapshot.profileId), "", snap)
      if let tabId = item.tabId, !tabId.isEmpty, !item.snapshot.url.isEmpty { t.wakeAdoptId = restoreId(tabId) }
      tabs[t.id] = t
      ids.append(t.id)
      if item.active || w.activeTabIds[t.profileId] == nil || w.activeTabIds[t.profileId]!.isEmpty { w.activeTabIds[t.profileId] = t.id }
    }
    w.tabIds = pinnedFirst(ids, tabs)
    var groups = s.groups
    var restored: [String: String] = [:]
    for g in entry.groups {
      let members = g.tabIndexes.compactMap { i in i >= 0 && i < ids.count ? ids[i] : nil }
      if members.isEmpty { continue }
      var group = TabGroup(
        id: g.id, windowId: id, profileId: g.profileId, name: g.name, icon: g.icon, color: g.color, collapsed: g.collapsed, pinned: g.pinned,
        tabIds: members, createdAt: g.createdAt)
      group.setLook(icon: g.icon, color: g.color, absent: g.absent)
      group.autoUngroup = g.autoUngroup
      group.pinnedOpenerId = g.pinnedOpenerId
      group.pinKey = g.pinKey
      group.extra = g.extra
      restored[g.id] = restoreGroup(&groups, group)
    }
    for g in entry.groups {
      if let groupId = restored[g.id], let parentKey = g.parentId, let parent = restored[parentKey] {
        var group = groups[groupId]!
        group.parentId = parent
        groups[groupId] = group
      }
    }
    var base = s
    base.tabs = tabs
    base.groups = groups
    base.closedWindows = s.closedWindows.filter { $0.id != entry.id }
    var next = withWindow(base, w)
    let shown = w.activeTabIds[w.profileId] ?? w.tabIds[0]
    next = adoptParkedPins(next, id, w.profileId)
    next = activated(next, shown)
    return next
  }
}
