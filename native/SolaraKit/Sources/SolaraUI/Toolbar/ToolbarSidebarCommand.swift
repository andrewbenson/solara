import SolaraModel
import SolaraStore

public enum ToolbarSidebarCommand {
  public enum Target {
    case window
    case pane(String)
  }

  public static func commands(click: ToolbarClick, windowId: String, target: Target, state: BrowserState, closing: Set<String>) -> [Command]? {
    guard click.id == "sidebar", !closing.contains(windowId), let window = state.windows[windowId] else { return nil }
    let toggle = Command("toggleSidebar", [.string(windowId)])
    switch target {
    case .window:
      return [toggle]
    case .pane(let tabId):
      guard let tab = state.tabs[tabId], tab.windowId == windowId, tab.profileId == window.profileId,
        window.tabIds.contains(tabId) else { return nil }
      let selected = state.activeTabId(windowId)
      if selected == tabId { return [toggle] }
      guard let split = Splits.splitOf(state, selected), split.windowId == windowId, split.tabIds.contains(tabId) else { return nil }
      return [Command("activate", [.string(tabId)]), toggle]
    }
  }
}
