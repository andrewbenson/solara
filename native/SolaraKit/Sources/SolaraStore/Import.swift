import SolaraModel

private struct ImportTab {
  let url: String
  let title: String
  let pinned: Bool
  let row: Bool
  let customTitle: String?
}

private struct ImportGroup {
  let name: String
  let indices: [Int]
  let pinned: Bool
}

private struct ImportSplit {
  let indices: [Int]
  let orientation: String
}

private struct ImportWindow {
  let windowId: String?
  let newWindow: Bool
  let tabs: [ImportTab]
  let groups: [ImportGroup]
  let splits: [ImportSplit]
  let drafts: [GroupDraft]
  let pinnedAgainst: String
  let skipExistingOpen: Bool
}

private func invalidImport() -> CommandError { CommandError("importWorkspace: malformed workspace") }

private func importString(_ value: JSONValue?) throws -> String? {
  guard let value, !value.isNull else { return nil }
  guard let string = value.string else { throw invalidImport() }
  return string
}

private func importBool(_ value: JSONValue?) throws -> Bool {
  guard let value, !value.isNull else { return false }
  guard let bool = value.bool else { throw invalidImport() }
  return bool
}

private func importArray(_ value: JSONValue?) throws -> [JSONValue] {
  guard let value, !value.isNull else { return [] }
  guard let array = value.array else { throw invalidImport() }
  return array
}

private func importIndices(_ value: JSONValue?, count: Int) throws -> [Int] {
  guard let values = value?.array, !values.isEmpty else { throw invalidImport() }
  let indices = try values.map { value -> Int in
    guard let n = value.number, n.isFinite, n >= 0, n < Double(count), n.rounded(.down) == n else { throw invalidImport() }
    return Int(n)
  }
  guard Set(indices).count == indices.count else { throw invalidImport() }
  return indices
}

private func importDraft(_ value: JSONValue, depth: Int = 0) throws -> GroupDraft {
  guard depth < 64, let object = value.object, object["title"]?.string != nil else { throw invalidImport() }
  _ = try importString(object["url"])
  _ = try importString(object["customTitle"])
  let children = try importArray(object["children"])
  for child in children { _ = try importDraft(child, depth: depth + 1) }
  return GroupDraft(json: value)
}

private func draftLinks(_ drafts: [GroupDraft]) -> [String] {
  drafts.flatMap { draft in draft.url.map { [$0] } ?? draftLinks(draft.children ?? []) }
}

private func importMode(_ value: JSONValue?, fallback: String) throws -> String {
  let mode = try importString(value) ?? fallback
  guard mode == "anyPin" || mode == "tiles" else { throw invalidImport() }
  return mode
}

extension Session {
  public func importWorkspace(_ payload: JSONValue) throws -> JSONValue {
    guard !config.safeMode else {
      throw CommandError("Imported tabs, spaces and pinned tabs cannot be saved in safe mode. Open Solara normally to import them.")
    }
    guard let object = payload.object, let profileId = object["profileId"]?.string,
      state.profiles[profileId] != nil, !Ids.isIncognitoProfile(profileId), let values = object["windows"]?.array
    else { throw invalidImport() }
    if let theme = object["theme"], !theme.isNull, theme.object == nil { throw invalidImport() }
    let defaultMode = try importMode(object["pinnedAgainst"], fallback: "anyPin")
    let drafts: [ImportWindow] = try values.map { value in
      guard let o = value.object, let inputs = o["tabs"]?.array else { throw invalidImport() }
      let windowId = try importString(o["windowId"])
      let newWindow = try importBool(o["newWindow"])
      if let windowId {
        guard !newWindow, let window = state.windows[windowId], !window.incognito, !window.isSmall else { throw invalidImport() }
      }
      let tabs = try inputs.map { input -> ImportTab in
        guard let tab = input.object, let url = tab["url"]?.string, let title = tab["title"]?.string else { throw invalidImport() }
        return ImportTab(url: url, title: title, pinned: try importBool(tab["pinned"]), row: try importBool(tab["row"]), customTitle: try importString(tab["customTitle"]))
      }
      var grouped = Set<Int>()
      var groups = try importArray(o["groups"]).map { input -> ImportGroup in
        guard let group = input.object, let name = group["name"]?.string else { throw invalidImport() }
        let indices = try importIndices(group["tabIndices"], count: tabs.count)
        guard indices.allSatisfy({ !tabs[$0].pinned && grouped.insert($0).inserted }) else { throw invalidImport() }
        return ImportGroup(name: name, indices: indices, pinned: try importBool(group["pinned"]))
      }
      if let name = try importString(o["group"]) {
        let indices = tabs.indices.filter { !tabs[$0].pinned && !grouped.contains($0) }
        if !indices.isEmpty { groups.append(ImportGroup(name: name, indices: indices, pinned: false)) }
      }
      var splitTabs = Set<Int>()
      let splits = try importArray(o["splits"]).map { input -> ImportSplit in
        guard let split = input.object else { throw invalidImport() }
        let indices = try importIndices(split["tabIndices"], count: tabs.count)
        let orientation = try importString(split["orientation"]) ?? "horizontal"
        guard indices.count >= 2, indices.count <= Splits.maxPanes, orientation == "horizontal" || orientation == "vertical",
          indices.allSatisfy({ splitTabs.insert($0).inserted }) else { throw invalidImport() }
        let first = indices[0]
        let group = groups.firstIndex { $0.indices.contains(first) }
        guard indices.allSatisfy({ index in
          tabs[index].pinned == tabs[first].pinned && (!tabs[first].pinned || tabs[index].row == tabs[first].row)
            && groups.firstIndex(where: { $0.indices.contains(index) }) == group
        }) else { throw invalidImport() }
        return ImportSplit(indices: indices, orientation: orientation)
      }
      return ImportWindow(windowId: windowId, newWindow: newWindow, tabs: tabs, groups: groups, splits: splits,
        drafts: try importArray(o["drafts"]).map { try importDraft($0) }, pinnedAgainst: try importMode(o["pinnedAgainst"], fallback: defaultMode),
        skipExistingOpen: try importBool(o["skipExistingOpen"]))
    }
    var next = state
    if let theme = object["theme"], !theme.isNull, var profile = next.profiles[profileId] {
      profile.setOwnTheme(theme)
      next.profiles[profileId] = profile
    }
    var windowIds: [String] = []
    var tabIds: [[String]] = []
    var groupIds: [String] = []
    var splitIds: [String] = []
    var count = 0
    var skipped = 0
    func keys(_ urls: [String]) -> Set<String> { Set(urls.filter { !$0.isEmpty }.map(pageKey)) }
    for draft in drafts {
      let allGroups = Set(next.groups.values.flatMap(\.tabIds))
      let open = next.tabs.values.filter { $0.profileId == profileId }
      let parked = next.parkedPins[profileId]?.tabs ?? []
      var openPages = keys(open.flatMap { [$0.url, $0.pinnedUrl ?? ""] } + parked.flatMap { [$0.snapshot.url, $0.snapshot.pinnedUrl ?? ""] })
      let existingOpenPages = openPages
      var pinned = pinnedPages(next, profileId)
      if draft.pinnedAgainst == "tiles" {
        pinned = keys(open.filter { $0.pinSection == .tile && !allGroups.contains($0.id) }.flatMap { [$0.url, $0.pinnedUrl ?? ""] }
          + parked.filter { $0.snapshot.pinned && $0.snapshot.pinnedAsRow != true && $0.groupId == nil }.flatMap { [$0.snapshot.url, $0.snapshot.pinnedUrl ?? ""] })
      }
      var usable: [Int] = []
      for (index, tab) in draft.tabs.enumerated() {
        guard opensUrl(tab.url) else { continue }
        let key = pageKey(tab.url)
        if draft.skipExistingOpen && existingOpenPages.contains(key) { continue }
        let housed = tab.pinned || draft.groups.contains { $0.pinned && $0.indices.contains(index) }
        if housed {
          guard pinned.insert(key).inserted else { continue }
        } else {
          guard openPages.insert(key).inserted else { continue }
        }
        usable.append(index)
      }
      let havePins = pinnedPages(next, profileId)
      let hasDraftLinks = draftLinks(draft.drafts).contains { opensUrl($0) && !havePins.contains(pageKey($0)) }
      guard !usable.isEmpty || hasDraftLinks else { continue }
      let existing = draft.newWindow ? nil : draft.windowId
        ?? next.ui.focusOrder.first { next.windows[$0].map { !$0.incognito && !$0.isSmall } ?? false }
        ?? next.windowOrder.first { next.windows[$0].map { !$0.incognito && !$0.isSmall } ?? false }
      let windowId: String
      if let existing {
        windowId = existing
      } else {
        windowId = newId("w")
        next = withWindow(next, emptyWindow(windowId, profileId, false))
      }
      var window = next.windows[windowId]!
      var imported: [Int: String] = [:]
      var lastUnpinned: String?
      for index in usable {
        let input = draft.tabs[index]
        var tab = Tab(id: newId("tab"), windowId: windowId, profileId: profileId, url: input.url, now: now)
        tab.title = input.title
        tab.customTitle = input.customTitle
        tab.pinned = input.pinned
        tab.pinnedAsRow = input.pinned && input.row ? true : nil
        tab.pinnedUrl = input.pinned ? input.url : nil
        tab.navigation = nil
        tab.unloaded = true
        next.tabs[tab.id] = tab
        imported[index] = tab.id
        let after = lastUnpinned.flatMap { window.tabIds.firstIndex(of: $0) }.map { $0 + 1 }
        let at = input.pinned ? pinnedInsertionIndex(next, window) : after ?? insertionIndex(next, window, tab, true)
        window.tabIds.insert(tab.id, at: min(at, window.tabIds.count))
        if !input.pinned { lastUnpinned = tab.id }
        next.windows[windowId] = window
        if window.activeTabIds[profileId] == nil { window.activeTabIds[profileId] = tab.id }
      }
      for input in draft.groups {
        let ids = input.indices.compactMap { imported[$0] }
        guard !ids.isEmpty else { continue }
        let group = TabGroup(id: newId("g"), windowId: windowId, profileId: profileId, name: input.name, icon: nil, color: nil,
          collapsed: false, pinned: input.pinned, tabIds: ids, createdAt: now)
        next.groups[group.id] = group
        window.tabIds = Groups.placeBlock(window.tabIds, ids)
        groupIds.append(group.id)
      }
      window.tabIds = Groups.orderSections(window.tabIds, next.tabs, next.groups)
      next.windows[windowId] = window
      next.groups = Groups.syncGroupOrder(next.groups, window)
      for input in draft.splits {
        let ids = input.indices.compactMap { imported[$0] }
        guard ids.count >= 2 else { continue }
        let split = SplitView(id: newId("split"), windowId: windowId, tabIds: ids, orientation: input.orientation, sizes: Splits.equal(ids.count))
        next.splits[split.id] = split
        splitIds.append(split.id)
      }
      let beforeDrafts = next.tabs.count
      let beforeGroups = Set(next.groups.keys)
      let made = withDraftGroups(next, windowId, profileId, draft.drafts)
      next = made.0
      skipped += Int(made.1["skipped"]?.number ?? 0)
      groupIds.append(contentsOf: next.groups.keys.filter { !beforeGroups.contains($0) })
      if next.windows[windowId]?.activeTabIds[profileId] == nil, let id = next.windows[windowId]?.tabIds.first(where: { next.tabs[$0]?.profileId == profileId }) {
        next.windows[windowId]!.activeTabIds[profileId] = id
      }
      count += imported.count + next.tabs.count - beforeDrafts
      windowIds.append(windowId)
      tabIds.append(usable.compactMap { imported[$0] })
      set(next)
      hear()
      next = state
    }
    set(next)
    return ["tabs": JSONValue(count), "skipped": JSONValue(skipped), "windows": JSONValue(windowIds), "tabIds": .array(tabIds.map { JSONValue($0) }),
      "groups": JSONValue(groupIds), "splits": JSONValue(splitIds)]
  }
}
