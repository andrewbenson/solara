import SolaraModel

public struct StripMember: Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable { case tab, split, folder }

  public var kind: Kind
  public var id: String
  public var tabIds: [String]
  public var group: String?

  public init(kind: Kind, id: String, tabIds: [String], group: String?) {
    self.kind = kind
    self.id = id
    self.tabIds = tabIds
    self.group = group
  }

  public func holds(_ tabId: String) -> Bool { kind == .tab ? id == tabId : tabIds.contains(tabId) }

  public func units(active: String) -> Int {
    switch kind {
    case .split: min(tabIds.count, 2)
    case .folder: holds(active) ? 1 : 0
    case .tab: 1
    }
  }
}

public struct StripGroupEntry: Equatable, Sendable {
  public var id: String
  public var collapsed: Bool
  public var members: [StripMember]

  public init(id: String, collapsed: Bool, members: [StripMember]) {
    self.id = id
    self.collapsed = collapsed
    self.members = members
  }

  public func shown(active: String) -> Int? { members.firstIndex { $0.holds(active) } }
}

public enum StripEntry: Equatable, Sendable {
  case dock(cells: [String], members: [String: [String]])
  case group(StripGroupEntry)
  case member(StripMember)
}

public struct StripQuery {
  public let state: BrowserState
  let session: Session

  public init(_ state: BrowserState, env: WebAddressing = PlainWebAddressing()) {
    self.state = state
    session = Session(state: state, memory: StoreMemory(), env: env, config: StoreConfig(), now: 0)
  }

  public static let folderCellPrefix = SidebarQuery.folderCellPrefix

  public func keys(windowId: String, profileId: String) -> [String] {
    var groupOf: [String: TabGroup] = [:]
    var folderOf: [String: String] = [:]
    for g in state.groups.values {
      if let parent = g.parentId {
        if state.groups[parent]?.parentId == nil { for id in g.tabIds { folderOf[id] = g.id } }
        continue
      }
      for id in g.tabIds where groupOf[id] == nil { groupOf[id] = g }
    }
    var splitOf: [String: SplitView] = [:]
    for v in state.splits.values { for id in v.tabIds where splitOf[id] == nil { splitOf[id] = v } }
    let opensBar = state.settings.string("newTabOpens") == "commandBar"
    let activeId = state.windows[windowId]?.activeTabIds[profileId]
    var seen = Set<String>()
    var dock: [String] = []
    var out: [String] = []
    for id in state.viewTabIds(windowId, profileId) {
      guard let t = state.tabs[id] else { continue }
      if t.newTabPlaceholder == true || (!t.pinned && opensBar && session.isUnopenedEmptyTab(state, t)) { continue }
      if let folder = tileFolderOf(t) {
        if seen.insert("tf:\(folder.id)").inserted {
          dock.append("tilefolder:\(folder.id):\(SolaraStore.folderMembers(state, windowId, folder.id).joined(separator: ","))")
        }
        if id == activeId { dock.append("pinned:\(id)") }
        continue
      }
      if t.pinned {
        dock.append("pinned:\(id)")
        continue
      }
      let group = groupOf[id]
      if let group, seen.insert(group.id).inserted { out.append("group:\(group.id):\(group.collapsed ? 1 : 0)") }
      if let group, let folder = folderOf[id] {
        if seen.insert(folder).inserted { out.append("folder:\(folder):\((state.groups[folder]?.tabIds ?? []).joined(separator: ",")):\(group.id)") }
        continue
      }
      if let split = splitOf[id] {
        if seen.insert(split.id).inserted { out.append("split:\(split.id):\(split.tabIds.joined(separator: ",")):\(group?.id ?? "")") }
        continue
      }
      out.append("tab:\(id):\(group?.id ?? "")")
    }
    return dock + out
  }

  public func entries(windowId: String, profileId: String) -> [StripEntry] {
    Self.parse(keys(windowId: windowId, profileId: profileId))
  }

  public static func parse(_ keys: [String]) -> [StripEntry] {
    var out: [StripEntry] = []
    var groupAt: [String: Int] = [:]
    for key in keys {
      let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      let kind = parts[0]
      let id = parts.count > 1 ? parts[1] : ""
      let a = parts.count > 2 ? parts[2] : ""
      let b = parts.count > 3 ? parts[3] : ""
      if kind == "pinned" || kind == "tilefolder" {
        let cell = kind == "tilefolder" ? folderCellPrefix + id : id
        if case .dock(var cells, var members)? = out.last {
          cells.append(cell)
          if kind == "tilefolder" { members[cell] = a.split(separator: ",").map(String.init) }
          out[out.count - 1] = .dock(cells: cells, members: members)
        } else {
          out.append(.dock(cells: [cell], members: kind == "tilefolder" ? [cell: a.split(separator: ",").map(String.init)] : [:]))
        }
        continue
      }
      if kind == "group" {
        groupAt[id] = out.count
        out.append(.group(StripGroupEntry(id: id, collapsed: a == "1", members: [])))
        continue
      }
      let member: StripMember =
        kind == "split" || kind == "folder"
        ? StripMember(kind: kind == "split" ? .split : .folder, id: id, tabIds: a.split(separator: ",").map(String.init), group: b.isEmpty ? nil : b)
        : StripMember(kind: .tab, id: id, tabIds: [id], group: a.isEmpty ? nil : a)
      if let group = member.group, let at = groupAt[group], case .group(var entry) = out[at] {
        entry.members.append(member)
        out[at] = .group(entry)
      } else {
        out.append(.member(member))
      }
    }
    return out
  }

  public func tuckTarget(windowId: String, profileId: String, groupId: String) -> String? {
    let members = Set(state.groups[groupId]?.tabIds ?? [])
    var best: Tab?
    for id in state.viewTabIds(windowId, profileId) {
      guard let t = state.tabs[id], !members.contains(id) else { continue }
      if best == nil || t.lastActiveAt > best!.lastActiveAt { best = t }
    }
    return best?.id
  }

  public func folderLabel(windowId: String, folderId: String) -> String {
    let name = folderIn(state, windowId, folderId)?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? "Folder" : name
  }

  public func groupLabel(_ groupId: String) -> String {
    guard let g = state.groups[groupId] else { return "" }
    return session.groupLabel(state, g)
  }
}
