import AppKit
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeToolbarActions {
  static func perform(_ click: ToolbarClick, source: NSView?, windowId expectedWindowId: String? = nil,
    target: ToolbarSidebarCommand.Target?) -> Bool {
    guard click.id == "ext-cast" || (click.id == "sidebar" && NativeStoreHandle.ownsWorkspace) else { return false }
    guard let source, !source.isHiddenOrHasHiddenAncestor, let window = source.window,
      let windowId = ShellDrag.windowId(of: window), expectedWindowId == nil || expectedWindowId == windowId,
      let target, let store = NativeStoreHandle.store, !NativeStoreHandle.frozen else { return true }
    if click.id == "ext-cast" {
      let tab: String?
      switch target {
      case .pane(let tabID): tab = tabID
      case .window: tab = store.state.peeks[windowId]?.tabId ?? store.state.activeTabId(windowId)
      }
      if let tab {
        if click.kind == .menu { NativeCast.menu(windowID: windowId, tabID: tab) }
        else if click.kind == .press { NativeCast.toggle(windowID: windowId, tabID: tab) }
      }
      return true
    }
    do {
      let changed = try store.sequence {
        guard let commands = ToolbarSidebarCommand.commands(click: click, windowId: windowId, target: target,
          state: store.state, closing: store.memory.closingWindows) else { return false }
        try store.dispatch(commands, origin: .native)
        return true
      }
      if changed { FrameUpdates.flush() }
    } catch { NSLog("[toolbar] sidebar action failed: %@", String(describing: error)) }
    return true
  }
}
