import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeToolbarActions {
  #if DEBUG
  static var blockedFallbacks: Set<String> = []
  #endif

  static func allowsFallback(_ click: ToolbarClick) -> Bool {
    #if DEBUG
    return !blockedFallbacks.contains(click.id)
    #else
    return true
    #endif
  }

  static func perform(_ click: ToolbarClick, source: NSView?, windowId expectedWindowId: String? = nil,
    target: ToolbarSidebarCommand.Target?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, click.id != "urlEdit" || click.kind != .blur else { return false }
    guard let source, !source.isHiddenOrHasHiddenAncestor, let window = source.window,
      let windowId = ShellDrag.windowId(of: window), expectedWindowId == nil || expectedWindowId == windowId,
      let target, let store = NativeStoreHandle.store, !NativeStoreHandle.frozen else { return true }
    if click.id == "sidebar" {
      if let commands = ToolbarSidebarCommand.commands(click: click, windowId: windowId, target: target,
        state: store.state, closing: store.memory.closingWindows) {
        dispatch(commands, store: store)
      }
      return true
    }
    let tabId: String?
    switch target {
    case .pane(let id): tabId = id
    case .window: tabId = (source as? SidebarAddressBarView)?.state?.tabId
    }
    guard let tabId, let action = ToolbarActionCommand.resolve(windowId: windowId, tabId: tabId,
      state: store.state, closing: store.memory.closingWindows) else { return true }
    if let activate = action.activation {
      guard dispatch([activate], store: store), action.isCurrent(in: store.state, closing: store.memory.closingWindows) else { return true }
    }
    let tab = action.tab
    let generation = NativeStoreHandle.ownershipGeneration
    let binding = (source as? ToolbarView)?.bindingGeneration ?? (source as? SidebarAddressBarView)?.bindingGeneration
    let sourceCurrent: () -> Bool = { [weak source, weak window] in
      guard let source, let window, source.window === window, ShellDrag.windowId(of: window) == windowId,
        !source.isHiddenOrHasHiddenAncestor else { return false }
      if let toolbar = source as? ToolbarView { return toolbar.state?.tabId == tabId && toolbar.bindingGeneration == binding }
      if let bar = source as? SidebarAddressBarView { return bar.state?.tabId == tabId && bar.bindingGeneration == binding }
      return false
    }
    func current() -> Bool {
      NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen && NativeStoreHandle.store === store
        && NativeStoreHandle.ownershipGeneration == generation && sourceCurrent()
        && action.isCurrent(in: store.state, closing: store.memory.closingWindows)
    }
    switch click.id {
    case "back", "forward":
      let back = click.id == "back"
      if click.kind == .menu {
        guard let host = NativePaneOverlays.host(windowId), NativeWindowShell.nativeLayoutActive(windowId) else { return false }
        host.openNavigationMenu(tabId, direction: back ? .back : .forward)
        return true
      }
      NativePaneOverlays.host(windowId)?.closeNavigationMenu(tabId)
      let disposition = ToolbarActionCommand.historyDisposition(click)
      let shown = (source as? ToolbarView)?.state?.newTabShown ?? (source as? SidebarAddressBarView)?.state?.newTabShown
      if shown == true { return false }
      if disposition == .current {
        if NativePinnedPageCommands.perform(click.id, arg: argument(["tabId": .string(tabId)]), windowId: windowId) { return true }
        let live = store.state.live[tabId]
        if back ? live?.canGoBack == true : live?.canGoForward == true {
          return issue(back ? .goBack : .goForward, tabId: tabId)
        }
        if back && NativeEngineCommands.hasBack(tabId) {
          NativeEngineCommands.request(tabId: tabId, action: "back", options: [:]) { _ in }
          return true
        }
        return false
      }
      let holder = store.state.sharedPageHolder(tabId)?.id ?? tabId
      let holderNavigation = store.state.tabs[holder]?.navigation
      issue(.navigationEntries, tabId: holder) { result in
        guard current(),
          store.state.tabs[holder]?.navigation == holderNavigation, (store.state.sharedPageHolder(tabId)?.id ?? tabId) == holder,
          case .success(let value) = result, let entries = value.foundation as? [[String: Any]],
          let index = entries.firstIndex(where: { $0["current"] as? Bool == true }) else { return }
        let next = index + (back ? -1 : 1)
        guard entries.indices.contains(next), let url = entries[next]["url"] as? String, !url.isEmpty else { return }
        NativeBookmarkCommands.openURL(url, mode: disposition.rawValue, windowId: windowId)
      }
    case "reload":
      let developer = ToolbarPresenter.page(windowId: windowId, tabId: tabId, state: store.state)?.developer == true
      let owner = action.bookmarkProfile
      let modes = store.state.settings.json["developerMode"]?.object ?? [:]
      let mode = modes[owner]?["reload"]?.string == "forceReload" ? "forceReload" : "reload"
      func reload(_ choice: String) {
        NativePinnedPageCommands.request(choice, tabId: tabId)
      }
      if click.kind == .menu {
        ShellMenus.choose([
          ["id": "reload", "title": "Refresh page", "checked": mode == "reload"],
          ["id": "forceReload", "title": "Refresh (Ignore Cache)", "checked": mode == "forceReload"],
          ["id": "clearCookies", "title": "Clear Cookies and Refresh"],
        ]) { choice in
          guard let choice, current() else { return }
          if choice == "clearCookies" {
            issue(.clearSiteData, tabId: tabId) { _ in if current() { reload("reload") } }
          } else {
            if !action.privateWindow, choice != mode {
              var updated = store.state.settings["developerMode"]?.object ?? [:]
              var profile = updated[owner]?.object ?? ["on": [], "off": []]
              profile["reload"] = .string(choice)
              updated[owner] = .object(profile)
              dispatch([Command("updateSettings", [["developerMode": .object(updated)]])], store: store)
            }
            reload(choice)
          }
        }
      } else {
        switch ToolbarActionCommand.reload(click, loading: store.state.live[tabId]?.isLoading == true, ignoresCache: developer && mode == "forceReload") {
        case .stop: issue(.stopLoading, tabId: tabId)
        case .duplicate:
          dispatch([Command("newTab", [.string(windowId), ["url": .string(tab.url), "background": true, "openerId": .string(tabId)]])], store: store)
        case .forceReload: reload("forceReload")
        case .reload: reload("reload")
        }
      }
    case "url":
      let developer = (source as? ToolbarView)?.state?.url?.developer ?? (source as? SidebarAddressBarView)?.state?.url?.developer
      guard click.kind == .press, let developer else { return false }
      if !developer.editing {
        Task { @MainActor in
          guard current() else { return }
          _ = await SettingsAdapters.js("toolbar.startEdit", tabId)
        }
      }
    case "translate":
      Task { @MainActor in
        guard current() else { return }
        _ = await SettingsAdapters.js("toolbar.translation", windowId, tabId, tab.url, click.kind == .menu)
      }
    case "bookmark":
      NativeBookmarkCommands.toggle(tab, profile: action.bookmarkProfile, windowId: windowId, store: store)
    case "split":
      addPane(action, store: store)
    case "splitMenu":
      splitMenu(action, store: store, current: current)
    case "closePane":
      NativeWorkspaceCommands.closeFromControl(tabId, store: store)
    case "lock", "capture", "siteControls", "zoom", "popups":
      let name = click.id == "zoom" || click.id == "popups" ? click.id : "siteControls"
      _ = NativeSelectionTools.setPopover(tabId, value: NativeSelectionTools.popoverSnapshot()[tabId] == name ? nil : name)
    case "dev:console", "dev:network", "dev:elements":
      issue(.showDevTools("toggle:" + click.id.dropFirst(4)), tabId: tabId)
    case "update":
      AppUpdater.shared.installPendingUpdate(nil)
    case "webkit:openInChromium":
      NativeEngineCommands.request(tabId: tabId, action: "open", options: ["engine": "chromium"]) { _ in }
    case "ext-cast":
      if click.kind == .menu { NativeCast.menu(windowID: windowId, tabID: tabId) }
      else if click.kind == .press { NativeCast.toggle(windowID: windowId, tabID: tabId) }
    default:
      guard click.id == "ext-overflow" || click.id.hasPrefix("ext:") else { return false }
      let overflow = click.id == "ext-overflow"
      let id = overflow ? "*" : String(click.id.dropFirst(4))
      let anchor = (source as? ToolbarView)?.extensionAnchor(id, fallback: true) ?? (source as? SidebarAddressBarView)?.extensionAnchor(id, fallback: true)
      var options: JSONObject = [
        "command": .string(overflow ? "overflow" : click.kind == .menu ? "menu" : "openExtension"),
        "windowId": .string(windowId), "tabId": .string(tabId), "id": .string(id),
      ]
      if let anchor {
        options["anchor"] = ["x": .number(anchor.minX), "y": .number(anchor.minY),
          "width": .number(anchor.width), "height": .number(anchor.height)]
      }
      NativeExtensionCommands.run(.object(options))
    }
    return true
  }

  private static func argument(_ options: JSONObject) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: JSONValue.object(options).foundation) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  private static func dispatch(_ commands: [Command], store: Store) -> Bool {
    let before = store.state
    do {
      try store.dispatch(commands, origin: .native)
      NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
      FrameUpdates.flush()
      return true
    } catch {
      NSLog("[toolbar] action failed: %@", String(describing: error))
      return false
    }
  }

  @discardableResult
  private static func issue(_ command: PageCommand, tabId: String, completion: @escaping PageRegistry.Completion = { _ in }) -> Bool {
    guard let issuer = PageIssuer.shared else { return false }
    return issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return false }
      issuer.issueInScope(tabId: tabId, identity: binding.identity, command: command) { result in
        guard issuer.store.sequence({ issuer.binding(tabId: tabId)?.identity == binding.identity && issuer.isCurrent(binding) }) else { return }
        completion(result)
      }
      return true
    }
  }

  private static func addPane(_ target: ToolbarActionCommand.Target, side: String? = nil, store: Store) {
    var options: JSONObject = ["anchorTabId": .string(target.tab.id)]
    if let side { options["side"] = .string(side) }
    let before = store.state
    let result = try? store.dispatch(Command("openSplitPane", [.string(target.windowId), .object(options)]), origin: .native).result
    if result?["reason"]?.string == "max", let host = WindowHost.contentView(target.windowId) {
      LinkToast.show(in: host, title: "Split View can show up to \(Splits.maxPanes) tabs at once.")
    }
    NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
    FrameUpdates.flush()
  }

  private static func splitMenu(_ target: ToolbarActionCommand.Target, store: Store, current: @escaping () -> Bool) {
    let tab = target.tab.id
    guard let split = Splits.splitOf(store.state, tab), let index = split.tabIds.firstIndex(of: tab) else { return }
    let horizontal = split.orientation == "horizontal"
    let full = split.tabIds.count >= Splits.maxPanes
    let stacked = Splits.slotsOf(split).contains { $0.count == 2 && $0.contains(tab) }
    ShellMenus.choose([
      ["id": "add", "title": horizontal ? "Add Vertical Split View" : "Add Horizontal Split View",
        "symbol": horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2", "enabled": !full],
      ["id": "bottom", "title": horizontal ? "Add Bottom Split" : "Add Right Split",
        "symbol": horizontal ? "rectangle.bottomhalf.inset.filled" : "rectangle.righthalf.inset.filled", "enabled": !full && !stacked],
      ["separator": true],
      ["id": "left", "title": horizontal ? "Move Pane Left" : "Move Pane Up", "enabled": index > 0, "symbol": "rectangle.lefthalf.inset.filled.arrow.left"],
      ["id": "right", "title": horizontal ? "Move Pane Right" : "Move Pane Down", "enabled": index < split.tabIds.count - 1, "symbol": "rectangle.righthalf.inset.filled.arrow.right"],
      ["id": "flip", "title": "Flip Split View", "symbol": horizontal ? "arrow.left.arrow.right" : "arrow.up.arrow.down"],
      ["id": "convert", "title": horizontal ? "Convert to Vertical Split View" : "Convert to Horizontal Split View", "symbol": horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1"],
      ["separator": true],
      ["id": "remove", "title": "Remove from Split View", "symbol": "rectangle.portrait.and.arrow.right"],
      ["id": "separate", "title": "Separate All Tabs", "symbol": "rectangle.split.3x1"],
      ["separator": true], ["id": "close", "title": "Close Pane", "symbol": "xmark"],
    ]) { choice in
      guard let choice, current(), Splits.splitOf(store.state, tab) == split else { return }
      let command: Command
      switch choice {
      case "add": return addPane(target, side: horizontal ? "right" : "bottom", store: store)
      case "bottom": return addPane(target, side: horizontal ? "bottom" : "right", store: store)
      case "left": command = Command("movePane", [.string(tab), -1])
      case "right": command = Command("movePane", [.string(tab), 1])
      case "flip": command = Command("flipSplit", [.string(split.id)])
      case "convert": command = Command("toggleSplitOrientation", [.string(split.id)])
      case "remove": command = Command("removeTabFromSplit", [.string(tab)])
      case "separate": command = Command("separateSplit", [.string(split.id)])
      case "close": return NativeWorkspaceCommands.closeFromControl(tab, store: store)
      default: return
      }
      dispatch([command], store: store)
    }
  }
}
