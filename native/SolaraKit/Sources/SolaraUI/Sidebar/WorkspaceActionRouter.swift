import SolaraModel
import SolaraStore

public enum WorkspaceCloseRoute: Equatable, Sendable {
  case unload([String])
  case removePinOrClose
  case close
}

@MainActor
public enum WorkspaceActionRouter {
  public static var ownedStore: Store? { WorkspaceWrites.store }

  public static func clickCommand(windowId: String, tabId: String, mods: SidebarClickMods) -> Command {
    Command("clickTab", [.string(windowId), .string(tabId), ["metaKey": .bool(mods.meta), "shiftKey": .bool(mods.shift), "altKey": .bool(mods.alt)]])
  }

  @discardableResult
  public static func click(_ store: Store, windowId: String, tabId: String, mods: SidebarClickMods) -> Bool {
    (try? store.dispatch(clickCommand(windowId: windowId, tabId: tabId, mods: mods), origin: .native)) != nil
  }

  public static func ownedClick(windowId: String, tabId: String, mods: SidebarClickMods) -> Bool {
    guard let store = ownedStore else { return false }
    return click(store, windowId: windowId, tabId: tabId, mods: mods)
  }
  public static func ownedClose(tabId: String, middle: Bool) -> (store: Store, route: WorkspaceCloseRoute)? {
    guard let store = ownedStore else { return nil }
    return (store, middle ? middleClickRoute(store.state, tabId: tabId) : closeRoute(store.state, tabId: tabId))
  }
  public static func closeRoute(_ state: BrowserState, tabId: String) -> WorkspaceCloseRoute {
    let query = SidebarQuery(state)
    guard query.closeKind(tabId) == .unload else { return .removePinOrClose }
    let pages = query.openPages(tabId)
    return .unload(pages.isEmpty ? [tabId] : pages)
  }

  public static func middleClickRoute(_ state: BrowserState, tabId: String) -> WorkspaceCloseRoute {
    guard let tab = state.tabs[tabId], tab.pinned, tab.pinnedAsRow != true else { return .removePinOrClose }
    return .close
  }
}

public enum WorkspaceRenameKind: String, Sendable { case tab, group }

public enum WorkspaceRenameRoute: Equatable, Sendable {
  case tileSheet
  case groupSheet
  case inline(expand: [String])
}

extension WorkspaceActionRouter {
  public static func renameRoute(_ state: BrowserState, windowId: String, kind: WorkspaceRenameKind, id: String) -> WorkspaceRenameRoute? {
    switch kind {
    case .tab:
      guard let tab = state.tabs[id] else { return nil }
      if tab.pinned && tab.pinnedAsRow != true { return .tileSheet }
      guard let group = Groups.innermostGroupOf(state.groups, id), state.activeTabId(windowId) != id else { return .inline(expand: []) }
      return .inline(expand: ([group.id] + Groups.ancestorIds(state.groups, group.id)).filter { state.groups[$0]?.collapsed == true })
    case .group:
      guard state.groups[id] != nil else { return nil }
      return sidebarShows(state, windowId: windowId) ? .inline(expand: []) : .groupSheet
    }
  }

  public static func sidebarShows(_ state: BrowserState, windowId: String) -> Bool {
    guard let window = state.windows[windowId] else { return false }
    let layout = window.tabLayout.flatMap { $0.isEmpty ? nil : $0 } ?? state.settings.string("tabLayout") ?? "sidebar"
    return layout == "sidebar" && window.sidebarOpen
  }

  public static func renameCommand(_ state: BrowserState, kind: WorkspaceRenameKind, id: String, text: String) -> Command? {
    let name = text.jsTrim()
    switch kind {
    case .tab:
      guard let tab = state.tabs[id] else { return nil }
      return Command("updateTab", [.string(id), ["customTitle": !name.isEmpty && name != tab.title ? .string(name) : .null]])
    case .group:
      guard state.groups[id] != nil else { return nil }
      return Command("updateGroup", [.string(id), ["name": .string(name)]])
    }
  }

  nonisolated public static func renameKey(_ kind: WorkspaceRenameKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

  nonisolated public static func renameKind(_ key: String) -> WorkspaceRenameKind? {
    key.split(separator: ":", maxSplits: 1).first.flatMap { WorkspaceRenameKind(rawValue: String($0)) }
  }

  nonisolated public static func renameId(_ key: String) -> String {
    key.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
  }
}

public struct WorkspaceRenameRegistry: Equatable, Sendable {
  public private(set) var keys: [String: String] = [:]
  private var sequences: [String: Int] = [:]

  public init() {}

  public var windowIds: [String] { keys.keys.sorted() }

  public func key(_ windowId: String) -> String? { keys[windowId] }

  public mutating func set(_ windowId: String, _ key: String?) -> Int {
    keys[windowId] = key
    let next = (sequences[windowId] ?? 0) + 1
    sequences[windowId] = next
    return next
  }

  public mutating func end(_ windowId: String, id: String) -> Int? {
    guard let current = keys[windowId], WorkspaceActionRouter.renameId(current) == id else { return nil }
    return set(windowId, nil)
  }

  public func live(_ windowId: String, state: BrowserState) -> Bool {
    guard state.windows[windowId] != nil, let key = keys[windowId], let kind = WorkspaceActionRouter.renameKind(key) else { return false }
    let id = WorkspaceActionRouter.renameId(key)
    return kind == .tab ? state.tabs[id] != nil : state.groups[id] != nil
  }

  public func stale(_ state: BrowserState) -> [String] { windowIds.filter { !live($0, state: state) } }

  public func override(_ windowId: String, state: BrowserState) -> String?? {
    .some(live(windowId, state: state) ? keys[windowId] : nil)
  }
}

public enum WorkspaceSheetGuard {
  public static func claim(_ pending: inout Set<String>, windowId: String, closing: Set<String>) -> Bool {
    !closing.contains(windowId) && pending.insert(windowId).inserted
  }
}
