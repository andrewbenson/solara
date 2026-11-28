import AppKit
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeOmniboxActions {
  static var ownsActions: Bool { NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store != nil }

  static func controller(view: @escaping () -> NSView?) -> OmniboxActionController {
    let controller = OmniboxActionController()
    controller.openSettings = { NativeSettingsWindow.openFromURL(pane: $0) }
    controller.performAction = { id, windowId in perform(id, windowId: windowId, view: view()) }
    controller.presentContextMenu = { model in
      guard let anchor = view() else { return }
      contextMenu(model, in: anchor)
    }
    controller.didSwitch = { windowId in ShellScripting.showWindow(windowId) }
    controller.didDismiss = { model, _ in
      NativeExtensionActionPopup.omniboxSessionEnded(windowId: model.windowId)
      if model.field?.hasFocus == true, let window = view()?.window {
        NotificationCenter.default.post(name: Notification.Name("SolaraBarRemovedWithFocus"), object: window)
      }
      model.field?.releaseFocus()
      guard let store = NativeStoreHandle.store, store.state.tabs[model.tabId]?.url.isEmpty == true else { return }
      let generation = NativeStoreHandle.ownershipGeneration
      DispatchQueue.main.async {
        guard current(model, store: store, generation: generation), store.state.windowUi[model.windowId]?.panelOpen != true else { return }
        _ = NativeNewTabView.focusHero(windowId: model.windowId, tabId: model.tabId)
      }
    }
    controller.performExtension = { suggestion, model in
      NativeOmniboxExtensionActions.open(suggestion, model: model, view: view())
      return true
    }
    controller.removeHistory = { url, model in
      guard let store = NativeStoreHandle.store, store.state.windows[model.windowId]?.incognito != true else { return true }
      let profile = store.state.engineProfile(model.profileId)
      Task { @MainActor in
        do { try await NativeHistoryCatalog.catalog.deleteHistory(urls: [url], engineProfile: profile) }
        catch { NSLog("[omnibox] deleting history failed: %@", String(describing: error)) }
      }
      return true
    }
    controller.dictate = { model in
      model.field?.focusField()
      _ = NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
      return true
    }
    return controller
  }

  static func contextMenu(_ model: HeroBarModel, in view: NSView) {
    var choices: [(String, String, Bool)] = []
    if let paste = model.pasteAction {
      choices.append(("pasteAndGo", pasteTitle(paste), true))
      choices.append(("", "", true))
    }
    choices += [
      ("cut", "Cut", model.selection.end > model.selection.start),
      ("copy", "Copy", model.selection.end > model.selection.start),
      ("paste", "Paste", model.pasteAction != nil),
      ("", "", true),
      ("copyURL", "Copy URL", !model.currentUrl.isEmpty),
      ("selectAll", "Select All", !model.value.isEmpty),
    ]
    guard let store = NativeStoreHandle.store else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    let session = model.editingSession
    menu(choices, in: view) { [weak model] choice in
      guard let model, current(model, store: store, generation: generation), model.editingSession == session,
        let action = HeroMenuChoice(rawValue: choice) else { return }
      model.apply(action)
    }
  }

  static func addressClick(_ click: ToolbarClick, windowId: String, tabId: String, view: NSView?) -> Bool {
    guard ownsActions, click.id == "url" || click.id == "urlEdit" else { return false }
    if click.id == "urlEdit", click.kind == .blur { return false }
    guard let store = NativeStoreHandle.store, let target = ToolbarActionCommand.resolve(windowId: windowId, tabId: tabId,
      state: store.state, closing: store.memory.closingWindows) else { return true }
    if let activate = target.activation {
      guard (try? store.dispatch(activate, origin: .native)) != nil else { return true }
    }
    let tab = target.tab
    if click.id == "urlEdit" {
      guard click.kind == .submit else { return false }
      let url = resolveInput(click.text ?? "", search: searchUrlPrefix(store.state.settings))
      if !url.isEmpty {
        openAddress(url, windowId: windowId, tabId: tabId, store: store)
      }
      return true
    }
    if click.kind == .menu {
      if let view { urlMenu(tabId: tabId, windowId: windowId, in: view) }
      return true
    }
    guard click.kind == .press else { return false }
    _ = try? store.dispatch(Command("openPanel", [.string(windowId), .string(tab.url)]), origin: .native)
    NativeOmniboxView.hosts[windowId]?.view?.openNativePanel(text: tab.url)
    return true
  }

  static func urlMenu(tabId: String, windowId: String, in view: NSView) {
    guard let store = NativeStoreHandle.store,
      let target = ToolbarActionCommand.resolve(windowId: windowId, tabId: tabId, state: store.state, closing: store.memory.closingWindows) else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    let paste = classifyPaste(NSPasteboard.general.string(forType: .string) ?? "")
    func choose(_ choice: String) {
      guard ownsActions, NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation,
        target.isCurrent(in: store.state, closing: store.memory.closingWindows) else { return }
      if choice == "copyURL" { copy(cleanUrl(target.tab.url)) }
      let currentPaste = target.small ? paste : classifyPaste(NSPasteboard.general.string(forType: .string) ?? "")
      if choice == "pasteAndGo", let currentPaste {
        let url: String
        switch currentPaste {
        case .go(let target): url = target
        case .search(let query): url = searchUrl(defaultSearchEngine(store.state.settings), query)
        }
        if target.small {
          _ = try? store.dispatch(Command("navigate", [.string(tabId), .string(url)]), origin: .native)
        } else {
          openAddress(url, windowId: windowId, tabId: tabId, store: store)
        }
      }
    }
    if target.small {
      var rows: [[String: Any]] = []
      if let paste {
        let title = pasteTitle(paste)
        rows.append(["id": "pasteAndGo", "title": title, "symbol": title == "Paste and Go" ? "arrow.right.circle" : "magnifyingglass"])
        rows.append(["separator": true])
      }
      rows.append(["id": "copyURL", "title": "Copy URL", "symbol": "link"])
      ShellMenus.choose(rows) { if let choice = $0 { choose(choice) } }
      return
    }
    var choices = [("copyURL", "Copy URL", true)]
    if let paste { choices += [("", "", true), ("pasteAndGo", pasteTitle(paste), true)] }
    menu(choices, in: view, choose: choose)
  }

  private static func openAddress(_ url: String, windowId: String, tabId: String, store: Store) {
    if store.state.peeks[windowId]?.tabId == tabId {
      _ = try? store.dispatch(Command("navigate", [.string(tabId), .string(url)]), origin: .native)
    } else {
      _ = open(url, windowId: windowId, tabId: tabId)
    }
  }

  static func openChip(_ model: HeroBarModel, in view: NSView) {
    guard let store = NativeStoreHandle.store else { return }
    let state = store.state
    let generation = NativeStoreHandle.ownershipGeneration
    let session = model.editingSession
    let tabs = state.viewTabIds(model.windowId).compactMap { state.tabs[$0] }
      .filter { $0.id != state.activeTabId(model.windowId) && !$0.url.isEmpty }.prefix(12)
    var choices = tabs.map { ("tab:\($0.id)", $0.title.isEmpty ? displayUrl($0.url) : $0.title, true) }
    if !choices.isEmpty { choices.append(("", "", true)) }
    choices.append(("files", "Open File…", true))
    menu(choices, in: view) { [weak model, weak view] choice in
      guard let model, current(model, store: store, generation: generation), model.editingSession == session else { return }
      if choice.hasPrefix("tab:") { model.events.switchTo(String(choice.dropFirst(4)), "", .current) }
      if choice == "files" { openFiles(model, in: view) }
    }
  }

  private static func openFiles(_ model: HeroBarModel, in view: NSView?) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard let store = NativeStoreHandle.store else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    let session = model.editingSession
    let target: JSONValue = model.opensTab ? store.state.windowUi[model.windowId]?.json["panel"]?["newTab"] ?? ["kind": "list"] : false
    let complete: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, current(model, store: store, generation: generation),
        model.editingSession == session, let url = panel.url else { return }
      _ = open(url.absoluteString, windowId: model.windowId, tabId: model.tabId, target: target)
    }
    if let window = view?.window { panel.beginSheetModal(for: window, completionHandler: complete) }
    else { panel.begin(completionHandler: complete) }
  }

  @discardableResult
  private static func open(_ url: String, windowId: String, tabId: String, target: JSONValue = false) -> JSONValue? {
    guard ownsActions, let store = NativeStoreHandle.store, store.state.activeTabId(windowId) == tabId,
      let tab = store.state.tabs[tabId], tab.windowId == windowId,
      store.state.windows[windowId]?.profileId == tab.profileId else { return nil }
    if let action = OmniboxActionController.applicationAction(for: url) {
      switch action {
      case .settings(let pane):
        _ = try? store.dispatch(Command("closePanel", [.string(windowId)]), origin: .native)
        if let pane { NativeSettingsWindow.navigate(pane: pane, profileId: nil, detail: nil) }
        WindowHost.openAuxiliary(id: "settings", kind: "settings", title: "Settings")
        return true
      case .newTab:
        let result = try? store.dispatch(Command("omniboxCommand", [.string(windowId), "newTab"]), origin: .native)
        if let windowId = result?.result?["windowId"]?.string { ShellScripting.showWindow(windowId) }
        return result?.result
      }
    }
    let destination = try? store.dispatch(Command("omniboxOpen", [
      .string(windowId), .string(tabId), .string(url), "current", target,
    ]), origin: .native)
    if let windowId = destination?.result?["windowId"]?.string { ShellScripting.showWindow(windowId) }
    return destination?.result
  }

  static func perform(_ id: String, windowId: String, view: NSView?) -> Bool {
    guard ownsActions, !id.isEmpty, let store = NativeStoreHandle.store else { return false }
    let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let command = parts[0]
    let argument = id == "newTab" ? "create" : parts.count > 1 ? parts[1] : nil
    if let run = NativeMenuCommands.argumentHandlers[command], run(argument, windowId) { return true }
    if let run = NativeMenuCommands.handlers[command] { run(windowId); return true }
    if let result = try? store.dispatch(Command("omniboxCommand", [.string(windowId), .string(id)]), origin: .native), result.result != .bool(false) {
      if let target = result.result?["windowId"]?.string { ShellScripting.showWindow(target) }
      return true
    }
    switch id {
    case "openSettings", "keyboardShortcuts", "profile:edit", "manageExtensions":
      let pane = id == "keyboardShortcuts" ? "shortcuts" : id == "profile:edit" ? "profiles" : id == "manageExtensions" ? "extensions" : nil
      if let pane { NativeSettingsWindow.navigate(pane: pane, profileId: store.state.windows[windowId]?.profileId, detail: nil) }
      WindowHost.openAuxiliary(id: "settings", kind: "settings", title: "Settings")
      return true
    case "importBrowserData":
      WindowHost.openAuxiliary(id: "import", kind: "import", title: "Import from Another Browser")
      return true
    case "clearBrowsingData":
      return NativeWorkspaceCommands.perform(id, windowId: windowId)
    case "newProfile":
      guard store.state.windows[windowId]?.incognito != true else { return true }
      let generation = NativeStoreHandle.ownershipGeneration
      let alert = NSAlert()
      alert.messageText = "New Profile"
      alert.addButton(withTitle: "Create Profile")
      alert.addButton(withTitle: "Cancel")
      let field = NSTextField.solaraPromptField(placeholder: "Profile name")
      alert.accessoryView = field
      alert.window.initialFirstResponder = field
      guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.jsTrim().isEmpty,
        ownsActions, NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation,
        store.state.windows[windowId]?.incognito == false else { return true }
      if let profile = (try? store.dispatch(Command("createProfile", [["name": .string(field.stringValue.jsTrim())]]), origin: .native))?.result?.string {
        _ = try? store.dispatch(Command("switchProfile", [.string(windowId), .string(profile)]), origin: .native)
      }
      return true
    case "searchTabs":
      return NativeTabFocusCommands.perform("searchTabs", arg: nil, windowId: windowId)
    case "split:withTab":
      return chooseSplitTab(windowId: windowId, view: view)
    default: return false
    }
  }

  private static func chooseSplitTab(windowId: String, view: NSView?) -> Bool {
    guard let store = NativeStoreHandle.store, let tabId = store.state.activeTabId(windowId) else { return true }
    let split = store.state.splits.values.first { $0.tabIds.contains(tabId) }
    let side = split?.orientation == "vertical" ? "bottom" : "right"
    guard let view else { return true }
    let tabs = store.state.viewTabIds(windowId).compactMap { store.state.tabs[$0] }
      .filter { $0.id != tabId && !$0.url.isEmpty && !(split?.tabIds.contains($0.id) ?? false) }
    let generation = NativeStoreHandle.ownershipGeneration
    menu(tabs.map { ($0.id, $0.title.isEmpty ? displayUrl($0.url) : $0.title, true) }, in: view) { target in
      guard ownsActions, NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation,
        store.state.activeTabId(windowId) == tabId else { return }
      _ = try? store.dispatch(Command("openSplitPane", [.string(windowId), ["anchorTabId": .string(tabId), "tabId": .string(target), "side": .string(side)]]), origin: .native)
    }
    return true
  }

  private static func current(_ model: HeroBarModel, store: Store, generation: Int) -> Bool {
    ownsActions && NativeStoreHandle.store === store && NativeStoreHandle.ownershipGeneration == generation
      && store.state.activeTabId(model.windowId) == model.tabId
      && store.state.windows[model.windowId]?.profileId == model.profileId
      && store.state.tabs[model.tabId]?.profileId == model.profileId
  }

  private static func pasteTitle(_ paste: PasteAction) -> String {
    if case .go = paste { return "Paste and Go" }
    return "Paste and Search"
  }

  private static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private static func menu(_ choices: [(String, String, Bool)], in view: NSView, choose: @escaping (String) -> Void) {
    let target = OmniboxMenuTarget(choose)
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (id, title, enabled) in choices {
      if id.isEmpty { menu.addItem(.separator()); continue }
      let item = NSMenuItem(title: title, action: #selector(OmniboxMenuTarget.choose(_:)), keyEquivalent: "")
      item.target = target
      item.representedObject = id
      item.isEnabled = enabled
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 8, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
    withExtendedLifetime(target) {}
  }
}

@MainActor
private final class OmniboxMenuTarget: NSObject {
  let action: (String) -> Void
  init(_ action: @escaping (String) -> Void) { self.action = action }
  @objc func choose(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { action(id) }
  }
}
