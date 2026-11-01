import AppKit
import SolaraModel
import SolaraStore

public enum StripAction: Sendable {
  case click(tabId: String, mods: SidebarClickMods)
  case activate(tabId: String)
  case close(tabId: String)
  case toggleMute(tabId: String)
  case tabMenu(tabId: String)
  case groupMenu(groupId: String)
  case toggleGroup(groupId: String, collapse: Bool)
  case closeGroup(groupId: String)
  case tuck(groupId: String)
  case folderMenu(groupId: String)
  case tileFolder(folderId: String)
  case tileFolderMenu(folderId: String)
  case newTab(split: Bool)
}

@MainActor
final class StripContext {
  let state: BrowserState
  let query: StripQuery
  let sidebar: SidebarContext
  let host: StripHostState
  let palette: StripPalette
  let windowId: String
  let activeId: String
  let playing: Set<String>
  var send: (StripAction) -> Void = { _ in }

  init(state: BrowserState, host: StripHostState, windowId: String, favicons: SidebarFavicons, previous: StripContext?) {
    self.state = state
    query = StripQuery(state)
    sidebar = SidebarContext(state: state, host: host.sidebarLook, windowId: windowId, favicons: favicons, previous: previous?.sidebar)
    self.host = host
    palette = previous.flatMap { $0.host.dark == host.dark && $0.host.theme == host.theme && $0.host.border == host.border ? $0.palette : nil } ?? StripPalette(host)
    self.windowId = windowId
    activeId = state.windows[windowId]?.activeTabIds[host.profileId] ?? ""
    playing = Set(host.playing)
  }

  var base: SidebarPalette { palette.base }

  func title(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if !tab.title.isEmpty { return tab.title }
    return tab.url.isEmpty ? "New Tab" : tab.url
  }

  func tooltip(_ tab: Tab) -> String {
    let title = title(tab)
    return tab.url.isEmpty ? title : "\(title)\n\(tab.url)"
  }

  func band(_ tabId: String) -> StripBandPalette? {
    host.floating ? nil : StripBandPalette.of(host.bands[tabId])
  }

  func closeControl(_ tabId: String) -> (icon: String, tooltip: String) {
    let kind = sidebar.query.closeKind(tabId)
    if kind == .removePin { return ("xmark", "Remove Pinned Tab") }
    let title = kind == .unload ? "Unload Tab" : "Close Tab"
    return (kind == .unload ? "minus" : "xmark", host.closeHint.map { "\(title) (\($0))" } ?? title)
  }

  func groupClose(_ groupId: String) -> (icon: String, tooltip: String)? {
    switch sidebar.query.groupClose(groupId) {
    case .close: ("xmark", "Close Group")
    case .unload: ("minus", "Unload Tabs")
    case nil: nil
    }
  }
}
