import SolaraModel

public struct SidebarEntries: Sendable, Equatable {
  public var tiles: [String] = []
  public var cells: [String] = []
  public var pinned: [String] = []
  public var list: [String] = []

  public init(tiles: [String] = [], cells: [String] = [], pinned: [String] = [], list: [String] = []) {
    self.tiles = tiles
    self.cells = cells
    self.pinned = pinned
    self.list = list
  }
}

public struct NumberedTabRow: Sendable, Equatable {
  public let key: String
  public let tabId: String

  public init(key: String, tabId: String) {
    self.key = key
    self.tabId = tabId
  }
}

public enum SidebarCloseKind: String, Sendable {
  case close, unload, removePin
}

public enum SidebarGroupClose: String, Sendable {
  case close, unload
}

public struct SidebarQuery {
  public let state: BrowserState
  let session: Session
  private var splitIndex: [String: [SplitView]]

  public init(_ state: BrowserState, env: WebAddressing = PlainWebAddressing()) {
    self.state = state
    session = Session(state: state, memory: StoreMemory(), env: env, config: StoreConfig(), now: 0)
    var index: [String: [SplitView]] = [:]
    for v in state.splits.values { for id in v.tabIds { index[id, default: []].append(v) } }
    splitIndex = index
  }

  public static let folderCellPrefix = "folder:"

  public static func folderId(ofCell cell: String) -> String? {
    cell.hasPrefix(folderCellPrefix) ? String(cell.dropFirst(folderCellPrefix.count)) : nil
  }

  public func entries(windowId: String, profileId: String? = nil) -> SidebarEntries {
    var out = SidebarEntries()
    var groupOf: [String: String] = [:]
    for g in state.groups.values where g.windowId == windowId && g.parentId == nil { for id in g.tabIds { groupOf[id] = g.id } }
    var seen = Set<String>()
    let opensBar = state.settings.string("newTabOpens") == "commandBar"
    for id in state.viewTabIds(windowId, profileId) {
      guard let tab = state.tabs[id] else { continue }
      if (truthy(tab.liveItem) && !tab.pinned) || (!tab.pinned && opensBar && session.isEmptyCardTab(state, tab)) { continue }
      if tab.pinned {
        if tab.pinnedAsRow != true {
          out.tiles.append(id)
        } else {
          let entry = pinnedRowEntry(id)
          if seen.insert(entry).inserted { out.pinned.append(entry) }
        }
        continue
      }
      let groupId = groupOf[id]
      let entry = groupId.map { "g:\($0)" } ?? splitEntry(id)
      guard seen.insert(entry).inserted else { continue }
      if let groupId, state.groups[groupId]?.pinned == true { out.pinned.append(entry) } else { out.list.append(entry) }
    }
    out.cells = tileCells(out.tiles)
    return out
  }

  public func numberedRows(windowId: String, profileId: String? = nil) -> [NumberedTabRow] {
    guard let window = state.windows[windowId], window.kind != "small" else { return [] }
    return numberedRows(windowId: windowId, profileId: profileId, entries: entries(windowId: windowId, profileId: profileId))
  }

  public func numberedRows(windowId: String, profileId: String?, entries: SidebarEntries) -> [NumberedTabRow] {
    guard let window = state.windows[windowId], window.kind != "small" else { return [] }
    let active = state.activeTabId(windowId, profileId)
    var ancestors = Set<String>()
    func rows(_ entry: String) -> [NumberedTabRow] {
      let id = String(entry.dropFirst(2))
      if entry.hasPrefix("g:") {
        guard ancestors.insert(id).inserted else { return [] }
        defer { ancestors.remove(id) }
        return groupEntries(id).flatMap(rows)
      }
      guard entry.hasPrefix("s:") else {
        return state.tabs[id] == nil ? [] : [NumberedTabRow(key: entry, tabId: id)]
      }
      let panes = splitPanes(id)
      if let active, panes.contains(active) { return [NumberedTabRow(key: entry, tabId: active)] }
      let recent = panes.reduce(nil as String?) { previous, candidate in
        guard let previous else { return candidate }
        return (state.tabs[candidate]?.lastActiveAt ?? 0) > (state.tabs[previous]?.lastActiveAt ?? 0) ? candidate : previous
      }
      return recent.map { [NumberedTabRow(key: entry, tabId: $0)] } ?? []
    }
    return entries.tiles.map { NumberedTabRow(key: "t:\($0)", tabId: $0) }
      + (entries.pinned + entries.list).flatMap(rows)
  }

  public func numberedTab(windowId: String, number: Int) -> String? {
    guard (1...9).contains(number) else { return nil }
    let rows = numberedRows(windowId: windowId)
    return number == 9 ? rows.last?.tabId : rows.indices.contains(number - 1) ? rows[number - 1].tabId : nil
  }

  public func tileCells(_ tiles: [String]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for id in tiles {
      guard let tab = state.tabs[id], tab.pinSection == .tile, let folder = tab.tileFolder else {
        out.append(id)
        continue
      }
      if seen.insert(folder.id).inserted { out.append(Self.folderCellPrefix + folder.id) }
    }
    return out
  }

  public func folderMembers(windowId: String, _ folderId: String) -> [String] {
    var profileId: String?
    return (state.windows[windowId]?.tabIds ?? []).filter { id in
      guard let t = state.tabs[id], t.pinSection == .tile, t.tileFolder?.id == folderId else { return false }
      if profileId == nil { profileId = t.profileId }
      return t.profileId == profileId
    }
  }

  public func groupEntries(_ groupId: String) -> [String] {
    guard let g = state.groups[groupId] else { return [] }
    var childOf: [String: String] = [:]
    for c in state.groups.values where c.parentId == groupId { for id in c.tabIds { childOf[id] = c.id } }
    var seen = Set<String>()
    var out: [String] = []
    for id in g.tabIds {
      let entry = childOf[id].map { "g:\($0)" } ?? splitEntry(id)
      if seen.insert(entry).inserted { out.append(entry) }
    }
    return out
  }

  public func splitPanes(_ splitId: String) -> [String] {
    Splits.splitRowPanes(state, state.splits[splitId])
  }

  func pinnedRowEntry(_ tabId: String) -> String {
    for v in splitIndex[tabId] ?? [] where Splits.splitRowPanes(state, v).contains(tabId) { return "s:\(v.id)" }
    return "t:\(tabId)"
  }

  func splitEntry(_ tabId: String) -> String {
    for v in splitIndex[tabId] ?? [] where v.tabIds.filter({ state.tabs[$0].map { !$0.pinned } ?? false }).count >= 2 { return "s:\(v.id)" }
    return "t:\(tabId)"
  }

  public func activeTabId(windowId: String, profileId: String? = nil) -> String? {
    state.activeTabId(windowId, profileId)
  }

  public func holdsTab(_ entry: String, _ tabId: String) -> Bool {
    let id = String(entry.dropFirst(2))
    if entry.hasPrefix("g:") { return state.groups[id]?.tabIds.contains(tabId) ?? false }
    if entry.hasPrefix("s:") { return state.splits[id]?.tabIds.contains(tabId) ?? false }
    return id == tabId
  }

  public func keptEntry(windowId: String, profileId: String, _ entries: [String]) -> String? {
    guard let active = state.activeTabId(windowId, profileId) else { return nil }
    return entries.first { holdsTab($0, active) }
  }

  public func closeKind(_ tabId: String) -> SidebarCloseKind {
    guard state.inPinnedContainer(tabId) else { return .close }
    return session.isClosedPin(state, tabId) ? .removePin : .unload
  }

  public func openPages(_ tabId: String) -> [String] {
    guard let t = state.tabs[tabId] else { return [] }
    if hasOwnOrSharedPage(t) { return [tabId] }
    return session.holderOf(state, tabId).map { [tabId, $0.id] } ?? []
  }

  public func groupClose(_ groupId: String) -> SidebarGroupClose? {
    guard state.groups[groupId] != nil else { return nil }
    if Groups.rootOf(state.groups, groupId)?.pinned != true { return .close }
    let open = (state.groups[groupId]?.tabIds ?? []).contains { !openPages($0).isEmpty }
    return open ? .unload : nil
  }

  public func groupLabel(_ groupId: String) -> String {
    guard let g = state.groups[groupId] else { return "" }
    return session.groupLabel(state, g)
  }

  public func pageUnloaded(_ tabId: String) -> Bool {
    guard let t = state.tabs[tabId], needsPage(t) else { return false }
    let key = shareKey(t)
    let live = state.tabs.values.contains { hasPage($0) && !truthy($0.pageIn) && shareKey($0) == key }
    return !live || session.holderOf(state, tabId) == nil
  }

  func shareKey(_ t: Tab) -> String { "\(t.profileId)\u{1}\(t.pinKeyOrId)" }

  public func awayFromPinnedUrl(_ tabId: String) -> Bool {
    guard let t = state.tabs[tabId] else { return false }
    return (t.isPinnedRow || !t.pinned) && awayFromPin(t)
  }
}
