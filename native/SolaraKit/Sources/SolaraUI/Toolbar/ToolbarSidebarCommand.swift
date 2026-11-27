import SolaraModel
import SolaraStore

public enum ToolbarSidebarCommand {
  public enum Target {
    case window
    case pane(String)
  }

  public static func commands(click: ToolbarClick, windowId: String, target: Target, state: BrowserState, closing: Set<String>) -> [Command]? {
    guard click.id == "sidebar", !closing.contains(windowId), state.windows[windowId] != nil else { return nil }
    let toggle = Command("toggleSidebar", [.string(windowId)])
    switch target {
    case .window:
      return [toggle]
    case .pane(let tabId):
      guard let picked = ToolbarActionCommand.resolve(windowId: windowId, tabId: tabId, state: state, closing: closing) else { return nil }
      return [picked.activation, toggle].compactMap { $0 }
    }
  }
}
