import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeTabMenu {
  #if DEBUG
  private(set) static var handled = 0
  #endif

  static func open(_ tabId: String, windowId: String, js: @escaping @MainActor (String, String) -> Void) -> Bool {
    guard let store = WorkspaceWrites.store,
      let items = TabMenuPlan.items(store.state, windowId: windowId, tabId: tabId) else { return false }
    guard !items.isEmpty else { return true }
    if store.state.selection[windowId]?.ids.isEmpty == false {
      do {
        try store.dispatch(Command("setSelection", [.string(windowId), []]), origin: .native)
      } catch {
        return false
      }
      FrameUpdates.flush()
    }
    #if DEBUG
    handled += 1
    #endif
    let hints = CommandShortcutSnapshot().hints(state: store.state)
    ShellMenus.choose(items.map { dictionary($0, hints: hints) }) { [weak owner = store] choice in
      guard let choice else { return }
      guard let store = WorkspaceWrites.store, store === owner, store.state.tabs[tabId] != nil else {
        return NSLog("[tabs] %@: gone or stood down while its menu was open", tabId)
      }
      run(choice, tabId: tabId, windowId: windowId, store: store, js: js)
    }
    return true
  }

  static func sidebarAction(_ action: String, tabId: String, windowId: String) -> Bool {
    guard let store = WorkspaceWrites.store else { return false }
    guard let tab = store.state.tabs[tabId] else { return true }
    let command: Command
    switch action {
    case "tileDoubleClick":
      guard store.state.activeTabId(windowId) == tabId else { return true }
      command = Command("returnToPinnedUrl", [.string(tabId)])
    case "backToPinned":
      command = Command("returnToPinnedUrl", [.string(tabId)])
    case "toggleMute":
      command = Command("setSiteMuted", [.string(tabId), .bool(!tab.muted)])
    default:
      return false
    }
    guard dispatch(store, command) != nil else { return true }
    if action == "toggleMute" { mutePage(tabId, muted: !tab.muted) }
    return true
  }

  private static func run(
    _ choice: String, tabId: String, windowId: String, store: Store,
    js: @escaping @MainActor (String, String) -> Void
  ) {
    guard let command = TabMenuPlan.command(choice, windowId: windowId, tabId: tabId, state: store.state) else {
      return js(tabId, choice)
    }
    let muted = store.state.tabs[tabId].map { !$0.muted }
    guard let result = dispatch(store, command) else { return }
    if choice == "mute", let muted { mutePage(tabId, muted: muted) }
    if choice == "newGroup", let id = result.string, !id.isEmpty,
      WorkspaceActionRouter.sidebarShows(store.state, windowId: windowId) {
      if !NativeWorkspaceRename.begin(windowId: windowId, kind: .group, id: id) {
        Task { @MainActor in _ = await SettingsAdapters.js("sidebar.action", windowId, "groupMenuChoice", id, ["choice": "rename"]) }
      }
    }
    if choice.hasPrefix("window:"), let id = result.string, !id.isEmpty { ShellScripting.showWindow(id) }
  }

  private static func dictionary(_ item: TabMenuItem, hints: [JSKey: String]) -> [String: Any] {
    var row = item.dictionary
    let commands = ["copy": "copyUrl", "backToPin": "returnToPinnedUrl", "newGroup": "newGroupWithTabs", "bookmark": "bookmarkPage", "close": "closeTab"]
    if let id = item.id, let command = commands[id], let hint = hints[JSKey(command)], let key = GroupMenu.menuKey(hint) {
      row["key"] = key.key
      row["modifiers"] = key.modifiers
    }
    if !item.children.isEmpty { row["children"] = item.children.map { dictionary($0, hints: hints) } }
    return row
  }

  private static func mutePage(_ tabId: String, muted: Bool) {
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.isCurrent(binding) else { return }
      issuer.issueInScope(tabId: tabId, identity: binding.identity, command: .setMuted(muted)) { result in
        if case .failure(let error) = result { NSLog("[tabs] mute on %@ failed: %@", tabId, String(describing: error)) }
      }
    }
  }

  private static func dispatch(_ store: Store, _ command: Command) -> JSONValue? {
    defer { FrameUpdates.flush() }
    do {
      return try store.dispatch(command, origin: .native).result ?? .null
    } catch {
      NSLog("[tabs] %@ refused: %@", command.name, String(describing: error))
      return nil
    }
  }
}
