import AppKit
import SolaraModel
import SolaraStore

public struct TileFolderPanelSlot: Equatable, Sendable {
  public var windowId: String
  public var folderId: String
  public var profileId: String?
  public var activeTabId: String?

  public init(windowId: String, folderId: String, profileId: String?, activeTabId: String?) {
    self.windowId = windowId
    self.folderId = folderId
    self.profileId = profileId
    self.activeTabId = activeTabId
  }
}

public enum TileFolderToggle: Equatable, Sendable {
  case close
  case open
}

public struct TileFolderPanelState: Equatable, Sendable {
  public private(set) var open: TileFolderPanelSlot?

  public init(open: TileFolderPanelSlot? = nil) { self.open = open }

  public func toggle(windowId: String, folderId: String) -> TileFolderToggle {
    open?.windowId == windowId && open?.folderId == folderId ? .close : .open
  }

  public func folder(in windowId: String) -> String? {
    open?.windowId == windowId ? open?.folderId : nil
  }

  public mutating func opened(windowId: String, folderId: String, state: BrowserState) {
    open = TileFolderPanelSlot(windowId: windowId, folderId: folderId, profileId: state.windows[windowId]?.profileId, activeTabId: state.activeTabId(windowId))
  }

  @discardableResult
  public mutating func close() -> Bool {
    guard open != nil else { return false }
    open = nil
    return true
  }

  @discardableResult
  public mutating func close(in windowId: String?) -> Bool {
    guard let windowId, open?.windowId == windowId else { return false }
    return close()
  }

  @discardableResult
  public mutating func check(_ state: BrowserState) -> Bool {
    guard let slot = open else { return false }
    guard let window = state.windows[slot.windowId], window.profileId == slot.profileId, state.activeTabId(slot.windowId) == slot.activeTabId,
      !SidebarQuery(state).folderMembers(windowId: slot.windowId, slot.folderId).isEmpty
    else { return close() }
    return false
  }
}

public struct FolderPanelLook: Decodable, Equatable, Sendable {
  public var dark: Bool
  public var theme: [String: String]
  public var panelShadowOpacity: Double?

  public init(dark: Bool, theme: [String: String] = [:], panelShadowOpacity: Double? = nil) {
    self.dark = dark
    self.theme = theme
    self.panelShadowOpacity = panelShadowOpacity
  }

  public static func decode(_ json: String) -> FolderPanelLook? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(FolderPanelLook.self, from: $0) }
  }
}

public enum TileFolderPanel {
  public static func members(_ state: BrowserState, windowId: String, folderId: String) -> [String] {
    SidebarQuery(state).folderMembers(windowId: windowId, folderId)
  }

  public static func folder(_ state: BrowserState, windowId: String, folderId: String) -> TileFolder? {
    members(state, windowId: windowId, folderId: folderId).first.flatMap { state.tabs[$0]?.tileFolder }
  }

  public static func label(_ state: BrowserState, windowId: String, folderId: String) -> String {
    let name = folder(state, windowId: windowId, folderId: folderId)?.name.jsTrim() ?? ""
    return name.isEmpty ? "Folder" : name
  }

  public static func title(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if !tab.title.isEmpty { return tab.title }
    let label = urlLabel(tab.url)
    return label.isEmpty ? "New Tab" : label
  }

  static func urlLabel(_ url: String) -> String {
    var label = url.replacingOccurrences(of: "^[a-z][\\w+.-]*://", with: "", options: [.regularExpression, .caseInsensitive])
    if label.hasPrefix("www.") { label.removeFirst(4) }
    if label.hasSuffix("/") { label.removeLast() }
    return label
  }

  public static func request(_ state: BrowserState, windowId: String, folderId: String, look: FolderPanelLook) -> FolderPanelRequest {
    let active = state.activeTabId(windowId)
    let rows = members(state, windowId: windowId, folderId: folderId).compactMap { id in
      state.tabs[id].map { FolderPanelRequest.Member(tabId: id, title: title($0), active: id == active) }
    }
    return FolderPanelRequest(
      folderId: folderId, label: label(state, windowId: windowId, folderId: folderId), members: rows,
      dark: look.dark, theme: look.theme, panelShadowOpacity: look.panelShadowOpacity)
  }

  @MainActor public static func plainClick(windowId: String, tabId: String) -> Command {
    WorkspaceActionRouter.clickCommand(windowId: windowId, tabId: tabId, mods: SidebarClickMods([]))
  }
}

public struct TileFolderMenuItem: Equatable, Sendable {
  public var id: String?
  public var title = ""
  public var symbol: String?
  public var checked = false
  public var children: [TileFolderMenuItem] = []
  public var submenu = false
  public var separator = false

  public init(id: String? = nil, title: String = "", symbol: String? = nil, checked: Bool = false, children: [TileFolderMenuItem] = [], submenu: Bool = false, separator: Bool = false) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.checked = checked
    self.children = children
    self.separator = separator
    self.submenu = submenu
  }

  public static var divider: Self { Self(separator: true) }

  public var dictionary: [String: Any] {
    if separator { return ["separator": true] }
    var row: [String: Any] = ["title": title, "checked": checked, "enabled": true]
    if let id { row["id"] = id }
    if let symbol { row["symbol"] = symbol }
    if submenu || !children.isEmpty { row["children"] = children.map(\.dictionary) }
    return row
  }
}

public enum TileFolderMenuChoice: Equatable, Sendable {
  case rename, remove, unpin
  case tab(String)

  public init?(_ id: String) {
    if id.hasPrefix("t:") {
      self = .tab(String(id.dropFirst(2)))
      return
    }
    switch id {
    case "rename": self = .rename
    case "remove": self = .remove
    case "unpin": self = .unpin
    default: return nil
    }
  }
}

public enum TileFolderMenus {
  public static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

  public static func unpinTitle(_ count: Int) -> String { "Unpin \(plural(count, "Tab"))" }

  public static func folderMenu(_ state: BrowserState, windowId: String, folderId: String) -> [TileFolderMenuItem] {
    let members = TileFolderPanel.members(state, windowId: windowId, folderId: folderId)
    guard !members.isEmpty else { return [] }
    return [
      TileFolderMenuItem(id: "rename", title: "Rename Folder…", symbol: "character.cursor.ibeam"),
      TileFolderMenuItem(id: "remove", title: "Remove Folder", symbol: "folder.badge.minus"),
      .divider,
      TileFolderMenuItem(id: "unpin", title: unpinTitle(members.count), symbol: "pin.slash"),
    ]
  }

  public static func stripTileFolder(_ state: BrowserState, windowId: String, folderId: String) -> [TileFolderMenuItem] {
    let active = state.activeTabId(windowId)
    let tabs = TileFolderPanel.members(state, windowId: windowId, folderId: folderId).compactMap { id in
      state.tabs[id].map { TileFolderMenuItem(id: "t:\(id)", title: ScriptState.tabLabel($0), checked: id == active) }
    }
    return tabs + [.divider, TileFolderMenuItem(id: "rename", title: "Rename Folder…", symbol: "character.cursor.ibeam")]
  }

  public static func stripGroupFolder(_ state: BrowserState, groupId: String, activeId: String?) -> [TileFolderMenuItem] {
    let query = SidebarQuery(state)
    return query.groupEntries(groupId).flatMap { entry -> [TileFolderMenuItem] in
      let id = String(entry.dropFirst(2))
      if entry.hasPrefix("g:") {
        guard state.groups[id] != nil else { return [] }
        return [TileFolderMenuItem(id: entry, title: query.groupLabel(id), symbol: "folder", children: stripGroupFolder(state, groupId: id, activeId: activeId), submenu: true)]
      }
      let tabIds = entry.hasPrefix("s:") ? (state.splits[id]?.tabIds ?? []) : [id]
      return tabIds.compactMap { t in
        state.tabs[t].map { TileFolderMenuItem(id: "t:\(t)", title: ScriptState.tabLabel($0), checked: t == activeId) }
      }
    }
  }

  public static func command(_ choice: TileFolderMenuChoice, state: BrowserState, windowId: String, folderId: String) -> Command? {
    switch choice {
    case .remove: return Command("dissolveTileFolder", [.string(windowId), .string(folderId)])
    case .unpin: return Command("pinTabs", [JSONValue(TileFolderPanel.members(state, windowId: windowId, folderId: folderId)), false])
    case .rename, .tab: return nil
    }
  }

  public static func renameCommand(windowId: String, folderId: String, name: String) -> Command {
    Command("renameTileFolder", [.string(windowId), .string(folderId), .string(name)])
  }

  public static func newFolderCommand(tabId: String) -> Command { Command("newTileFolder", [JSONValue([tabId])]) }

  public static func leaveCommand(tabId: String) -> Command { Command("leaveTileFolder", [JSONValue([tabId])]) }
}
