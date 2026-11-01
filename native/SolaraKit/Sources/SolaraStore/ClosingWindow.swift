import SolaraModel

struct ClosingWindowUndo: Sendable, Equatable {
  var before: BrowserState
  var after: BrowserState
  var closedAt: Double
}

private func undoClosingMap<T: Equatable>(_ current: JSMap<T>, _ before: JSMap<T>, _ after: JSMap<T>) -> JSMap<T>? {
  let changed = Set(before.keys + after.keys).filter { before[$0] != after[$0] }
  guard changed.allSatisfy({ current[$0] == after[$0] }) else { return nil }
  var next = current
  for key in changed { next[key] = before[key] }
  return JSMap((before.keys + current.keys.filter { !before.contains($0) }).compactMap { key in next[key].map { (key, $0) } })
}

private func undoClosingTable<T: Sendable & Equatable>(_ current: Table<T>, _ before: Table<T>, _ after: Table<T>) -> Table<T>? {
  undoClosingMap(current.map, before.map, after.map).map(Table.init)
}

private func undoClosingValue<T: Equatable>(_ current: T, _ before: T, _ after: T) -> T? {
  if before == after { return current }
  return current == after ? before : nil
}

private func renamedClosingKey<T>(_ current: JSMap<T>, _ old: String, _ new: String) -> JSMap<T> {
  JSMap(current.map { ($0.key == old ? new : $0.key, $0.value) })
}

extension Session {
  func rememberClosingWindow(_ id: String, before: BrowserState) {
    memory.closingWindowUndos = memory.closingWindowUndos.filter { now - $0.value.closedAt <= 30_000 }
    var before = before
    before.live = [:]
    var after = state
    after.live = [:]
    memory.closingWindowUndos[id] = ClosingWindowUndo(before: before, after: after, closedAt: now)
    while memory.closingWindowUndos.count > 10 {
      guard let oldest = memory.closingWindowUndos.min(by: { $0.value.closedAt < $1.value.closedAt })?.key else { break }
      memory.closingWindowUndos.removeValue(forKey: oldest)
    }
  }

  public func restoreClosingWindow(_ window: BrowserWindow, _ tabs: [Tab], _ groups: [TabGroup], _ splits: [SplitView], chromeWindow: String, liveTabIds: [String]) -> String? {
    let s = state
    memory.closingWindowUndos = memory.closingWindowUndos.filter { now - $0.value.closedAt <= 30_000 }
    guard let undo = memory.closingWindowUndos[window.id], now - undo.closedAt <= 30_000,
          let original = undo.before.windows[window.id], original.profileId == window.profileId, original.kind == window.kind,
          original.incognito == window.incognito, original.tabIds == window.tabIds,
          Set(original.tabIds).count == original.tabIds.count,
          Set(tabs.map(\.id)) == Set(original.tabIds), tabs.count == original.tabIds.count,
          Set(groups.map(\.id)) == Set(undo.before.groups.values.filter { $0.windowId == window.id }.map(\.id)),
          Set(splits.map(\.id)) == Set(undo.before.splits.values.filter { $0.windowId == window.id }.map(\.id)) else { return nil }
    let profileId = original.incognito ? (original.originalProfileId ?? Ids.incognitoOriginal(original.profileId)) : original.profileId
    let wanted = Set(original.tabIds)
    let live = Set(liveTabIds).intersection(wanted)
    guard !live.isEmpty else { return nil }
    let wantedGroups = Set(groups.map(\.id))
    let wantedSplits = Set(splits.map(\.id))
    guard s.profiles[profileId] != nil,
          original.tabIds.allSatisfy({ s.tabs[$0] == nil && undo.before.tabs[$0].map { tab in
            s.profiles[Ids.isIncognitoProfile(tab.profileId) ? Ids.incognitoOriginal(tab.profileId) : tab.profileId] != nil
          } == true }),
          wantedGroups.allSatisfy({ s.groups[$0] == nil }),
          wantedSplits.allSatisfy({ s.splits[$0] == nil }),
          !s.windows.values.contains(where: { $0.tabIds.contains(where: wanted.contains) || $0.activeTabIds.values.contains(where: wanted.contains) }),
          !s.groups.values.contains(where: { !$0.tabIds.allSatisfy { !wanted.contains($0) } || $0.parentId.map(wantedGroups.contains) == true || $0.pinnedOpenerId.map(wanted.contains) == true }),
          !s.splits.values.contains(where: { !$0.tabIds.allSatisfy { !wanted.contains($0) } }) else { return nil }
    let before = undo.before
    let after = undo.after
    guard let windows = undoClosingTable(s.windows, before.windows, after.windows),
          let restoredTabs = undoClosingTable(s.tabs, before.tabs, after.tabs),
          let restoredGroups = undoClosingTable(s.groups, before.groups, after.groups),
          let restoredSplits = undoClosingTable(s.splits, before.splits, after.splits),
          let peeks = undoClosingTable(s.peeks, before.peeks, after.peeks),
          let parkedPins = undoClosingTable(s.parkedPins, before.parkedPins, after.parkedPins),
          let pinChoices = undoClosingTable(s.pinChoices, before.pinChoices, after.pinChoices),
          let pinSync = undoClosingTable(s.pinSync, before.pinSync, after.pinSync),
          let privateCleanedTabs = undoClosingMap(s.privateCleanedTabs, before.privateCleanedTabs, after.privateCleanedTabs),
          let privateSiteMutes = undoClosingMap(s.privateSiteMutes, before.privateSiteMutes, after.privateSiteMutes),
          let find = undoClosingMap(s.find, before.find, after.find),
          let selection = undoClosingMap(s.selection, before.selection, after.selection),
          let selectionAnchors = undoClosingMap(s.selectionAnchors, before.selectionAnchors, after.selectionAnchors),
          let windowUi = undoClosingMap(s.windowUi, before.windowUi, after.windowUi),
          let closedTabs = undoClosingValue(s.closedTabs, before.closedTabs, after.closedTabs),
          let closedWindows = undoClosingValue(s.closedWindows, before.closedWindows, after.closedWindows),
          let windowOrder = undoClosingValue(s.windowOrder, before.windowOrder, after.windowOrder),
          let focusedWindowId = undoClosingValue(s.ui.focusedWindowId, before.ui.focusedWindowId, after.ui.focusedWindowId),
          let focusOrder = undoClosingValue(s.ui.focusOrder, before.ui.focusOrder, after.ui.focusOrder),
          let lastProfileId = undoClosingValue(s.ui.lastProfileId, before.ui.lastProfileId, after.ui.lastProfileId) else { return nil }
    let pinTabs = Set(original.tabIds.compactMap { before.tabs[$0] }.filter { before.inPinnedContainer($0.id) }.map(\.pinKeyOrId))
    let pinGroups = Set(before.groups.values.filter { $0.windowId == window.id && $0.pinned }.map(\.pinKeyOrId))
    guard !parkedPins.values.contains(where: { park in
      park.tabs.contains { wanted.contains($0.id) || pinTabs.contains($0.id) || $0.groupId.map { wantedGroups.contains($0) || pinGroups.contains($0) } == true } || park.groups.contains { wantedGroups.contains($0.id) || pinGroups.contains($0.id) || $0.parentId.map { wantedGroups.contains($0) || pinGroups.contains($0) } == true }
        || (park.splits ?? []).contains { $0.ids.contains { wanted.contains($0) || pinTabs.contains($0) } }
    }) else { return nil }
    let id = newId("w")
    var next = s
    var restored = original
    restored.id = id
    restored.chromeWindow = chromeWindow
    var remappedWindows = windows.map
    remappedWindows[window.id] = restored
    next.windows = Table(renamedClosingKey(remappedWindows, window.id, id))
    next.tabs = Table(restoredTabs.map.mapValues { tab in
      var tab = tab
      if tab.windowId == window.id { tab.windowId = id }
      return tab
    })
    next.groups = Table(restoredGroups.map.mapValues { group in
      var group = group
      if group.windowId == window.id { group.windowId = id }
      return group
    })
    next.splits = Table(restoredSplits.map.mapValues { split in
      var split = split
      if split.windowId == window.id { split.windowId = id }
      return split
    })
    next.peeks = Table(renamedClosingKey(peeks.map, window.id, id))
    next.parkedPins = parkedPins
    next.pinChoices = pinChoices
    next.pinSync = pinSync
    next.privateCleanedTabs = renamedClosingKey(privateCleanedTabs, window.id, id)
    next.privateSiteMutes = renamedClosingKey(privateSiteMutes, window.id, id)
    next.closedTabs = closedTabs
    next.closedWindows = closedWindows
    next.windowOrder = windowOrder.map { $0 == window.id ? id : $0 }
    next.ui.focusedWindowId = focusedWindowId == window.id ? id : focusedWindowId
    next.ui.focusOrder = focusOrder.map { $0 == window.id ? id : $0 }
    next.ui.lastProfileId = lastProfileId
    next.find = find
    var activeTabIds = JSMap<String>()
    for tabId in original.tabIds where live.contains(tabId) {
      let profileId = before.tabs[tabId]!.profileId
      if activeTabIds[profileId] == nil { activeTabIds[profileId] = tabId }
    }
    for (profileId, tabId) in original.activeTabIds where live.contains(tabId) { activeTabIds[profileId] = tabId }
    next.windows[id]!.activeTabIds = activeTabIds
    if activeTabIds[original.profileId] == nil {
      let profileId = before.tabs[original.tabIds.first(where: live.contains)!]!.profileId
      next.windows[id]!.profileId = profileId
      if next.ui.focusedWindowId == id && !original.incognito { next.ui.lastProfileId = profileId }
    }
    if let peek = next.peeks[id], !live.contains(peek.tabId) { next = withoutPeek(next, id) }
    let missing = original.tabIds.filter { !live.contains($0) }
    next = unloadPinnedTabs(next, missing, expand: false)
    next = removeTabs(next, missing.filter { !next.inPinnedContainer($0) }, record: true)
    next.find = next.find.filter { tabId, _ in !wanted.contains(tabId) || live.contains(tabId) && next.tabs[tabId]?.unloaded != true }
    next.selection = renamedClosingKey(selection, window.id, id)
    if let picked = next.selection[id] {
      let kept = picked.ids.filter { live.contains($0) && next.tabs[$0]?.unloaded != true && next.tabs[$0] != nil }
      next.selection[id] = kept.isEmpty ? nil : TabSelection(kept)
    }
    next.selectionAnchors = renamedClosingKey(selectionAnchors, window.id, id)
    if let anchor = next.selectionAnchors[id], !live.contains(anchor.tabId) || next.tabs[anchor.tabId]?.unloaded == true || next.tabs[anchor.tabId] == nil {
      next.selectionAnchors[id] = nil
    }
    next.windowUi = renamedClosingKey(windowUi, window.id, id)
    memory.closingWindowUndos.removeValue(forKey: window.id)
    set(next)
    return id
  }
}
