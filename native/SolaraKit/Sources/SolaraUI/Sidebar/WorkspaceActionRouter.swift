import SolaraModel
import SolaraStore

public enum WorkspaceCloseRoute: Equatable, Sendable {
  case unload([String])
  case removePinOrClose
  case close
}

@MainActor
public enum WorkspaceActionRouter {
  public static var ownedStore: Store? { NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil }

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
