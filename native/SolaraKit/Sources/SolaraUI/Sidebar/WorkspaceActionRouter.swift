import SolaraModel
import SolaraStore

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
}
