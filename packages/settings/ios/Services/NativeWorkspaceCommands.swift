import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeWorkspaceCommands {
  private static var pending: Set<String> = []
  private static var sheetWindowObservers: [String: NSObjectProtocol] = [:]
  private struct NewTabFocus {
    let tabId: String
    let generation: Int?
    let ownership: Int
    let request: UUID
    let responder: ObjectIdentifier?
    let editorDelegate: ObjectIdentifier?
  }
  private static var newTabFocus: [String: NewTabFocus] = [:]
  private struct PanelFocus {
    let tabId: String?
    let generation: Int
    let ownership: Int
    let request: UUID
  }
  private static var panelFocus: [String: PanelFocus] = [:]

  static func install() {
    for command in WorkspaceMenuCommand.commands.union(ViewMenuCommand.commands) {
      NativeMenuCommands.argumentHandlers[command] = { arg, windowId in perform(command, arg: arg, windowId: windowId) }
    }
    NativeMenuCommands.keepsMenuDispatch = ViewMenuCommand.commands
    NativeMenuCommands.workspaceAvailability = { command, arg, windowId in
      guard NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state,
        WorkspaceMenuCommand.commands.contains(command) else { return nil }
      if command == "closeTab", windowId == nil, WindowHost.hasClosableForeignKeyWindow { return true }
      return WorkspaceMenuCommand.available(command, arg: arg, windowId: windowId, state: state)
    }
    WindowHost.closeRequest = { id in perform("closeWindow", windowId: id) }
    SolaraCoreServices.closeCancelledHandler = { request in
      MainActor.assumeIsolated { restoreCancelledClose(request) }
    }
  }

  private static func performView(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    guard let outcome = ViewMenuCommand.perform(command, arg: arg, windowId: windowId, store: store) else { return false }
    if let target = outcome.focusWindow { ShellScripting.showWindow(target) }
    if let appearance = outcome.appearance { ShellScripting.setAppearance(appearance) }
    FrameUpdates.flush()
    return true
  }

  private static func restoreCancelledClose(_ request: [String: Any]) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    guard let windowId = request["appWindow"] as? String, let token = request["chromeWindow"] as? String,
      let tabs = request["tabs"] as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: tabs),
      let text = String(data: data, encoding: .utf8), let live = try? JSONValue.parse(text) else { return true }
    let before = store.state
    do {
      let commit = try store.dispatch(Command("restoreCommandWindow", [.string(windowId), .string(token), live]), origin: .native)
      guard commit.result?.string != nil else {
        NSLog("[commands] a cancelled close could not restore window %@", windowId)
        return true
      }
      materializeChanges(before: before, after: store.state)
      FrameUpdates.flush()
    } catch { NSLog("[commands] restoring cancelled close failed: %@", String(describing: error)) }
    return true
  }

  @discardableResult
  static func perform(_ command: String, arg: String? = nil, windowId: String?) -> Bool {
    if ViewMenuCommand.commands.contains(command) { return performView(command, arg: arg, windowId: windowId) }
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      WorkspaceMenuCommand.commands.contains(command) else { return false }
    if command == "closeTab", windowId == nil, WindowHost.closeForeignKeyWindow() { return true }
    if let windowId, store.state.windows[windowId] == nil, command == "closeTab" || command == "closeWindow" {
      return WindowHost.closeAuxiliaryWindow(windowId)
    }
    guard let plan = WorkspaceMenuCommand.plan(command, arg: arg, windowId: windowId, state: store.state) else { return false }
    if let close = plan.close {
      switch close {
      case .window(let id): closeWindow(id, store: store)
      case .tabs(let id, let ids): closeTabs(ids, windowId: id, store: store)
      }
      return true
    }
    let before = store.state
    let focusWindow = before.resolveWindowId(windowId)
    let opensPanel = command == "newTab" && plan.commands.first?.name == "openPanel"
    let closesPanel = command == "newTab" && plan.commands.first?.name == "closePanel"
    if command == "newTab", let focusWindow {
      if let previous = newTabFocus.removeValue(forKey: focusWindow), let generation = previous.generation {
        WindowHost.cancelCommandFocus(generation, restoring: false)
      }
      if let previous = panelFocus.removeValue(forKey: focusWindow) {
        WindowHost.cancelCommandFocus(previous.generation, restoring: false)
      }
    }
    let focusGeneration = closesPanel ? nil : focusWindow.flatMap { WindowHost.beginCommandFocus(command, windowId: $0) }
    if opensPanel, let focusWindow, let focusGeneration {
      requestPanelFocus(windowId: focusWindow, tabId: before.activeTabId(focusWindow), generation: focusGeneration)
    }
    do {
      var commands = plan.commands
      if command == "moveTabToProfile", let move = commands.first {
        guard let tabId = move.args.first?.string, let profile = move.args.last?.string else { return true }
        guard let target = profile == "new" ? createProfile(store: store) : profile else { return true }
        guard let tab = store.state.tabs[tabId], store.state.profiles[target] != nil, tab.profileId != target else { return true }
        if store.state.settings.bool("warnBeforeMovingTabsToProfile"), store.state.engineProfile(tab.profileId) != store.state.engineProfile(target) {
          let alert = confirmAlert("Move Tab to Profile?", message: "Moving tabs between profiles could result in some data being lost.", button: "Move Tab", suppression: "Don't warn me again")
          askGuarded(alert, windowId: tab.windowId, setting: "warnBeforeMovingTabsToProfile", store: store) { finishMovingToProfile(tabId, target: target, store: store) }
          return true
        }
        guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, store.state.tabs[tabId] != nil else { return true }
        commands = [Command("moveTabToProfile", [.string(tabId), .string(target)])]
      }
      guard !commands.isEmpty else { return true }
      let commit = try store.dispatch(commands, origin: .native)
      materializeChanges(before: before, after: store.state)
      if command == "newTab", let id = commit.result?.string, before.windows[windowId ?? ""]?.isSmall == true,
        let target = store.state.tabs[id]?.windowId { ShellScripting.showWindow(target) }
      if command == "newTab", let id = commit.result?.string {
        let targetWindow = store.state.tabs[id]?.windowId ?? id
        let targetTab = store.state.tabs[id] != nil ? id : store.state.activeTabId(targetWindow)
        if let targetTab { requestHeroFocus(targetTab, windowId: targetWindow, generation: focusGeneration) }
        else if let focusGeneration { WindowHost.cancelCommandFocus(focusGeneration, restoring: true) }
      }
      if let target = plan.focusWindow {
        try store.dispatch(Command("setFocusedWindow", [.string(target)]), origin: .native)
        ShellScripting.showWindow(target)
      }
      if command == "moveTabToWindow", let target = commit.result?.string {
        try store.dispatch(Command("setFocusedWindow", [.string(target)]), origin: .native)
        ShellScripting.showWindow(target)
      }
      FrameUpdates.flush()
      if closesPanel, let focusWindow, let active = store.state.activeTabId(focusWindow),
        store.state.tabs[active]?.url.isEmpty == false {
        restoreContentFocus(windowId: focusWindow, store: store, tabId: active)
      }
      if command == "closeTab", let targetWindow = before.resolveWindowId(windowId) {
        if commands.first?.name == "closePeek" {
          restoreContentFocus(windowId: targetWindow, store: store)
        } else if commands.first?.name == "setFind", let peek = before.peeks[targetWindow] {
          restoreContentFocus(windowId: targetWindow, store: store, tabId: peek.tabId, stopFinding: true)
        }
      }
    } catch {
      if let focusGeneration { WindowHost.cancelCommandFocus(focusGeneration, restoring: true) }
      NSLog("[commands] %@ failed: %@", command, String(describing: error))
    }
    return true
  }

  private static func requestPanelFocus(windowId: String, tabId: String?, generation: Int) {
    let request = UUID()
    panelFocus[windowId] = PanelFocus(tabId: tabId, generation: generation,
      ownership: NativeStoreHandle.ownershipGeneration, request: request)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      guard let wanted = panelFocus[windowId], wanted.request == request else { return }
      panelFocus[windowId] = nil
      WindowHost.cancelCommandFocus(wanted.generation, restoring: false)
    }
  }

  static func panelDidFocus(_ view: NativeOmniboxView) {
    guard let wanted = panelFocus[view.windowId], let state = NativeStoreHandle.store?.state,
      NativeStoreHandle.ownsWorkspace, NativeStoreHandle.ownershipGeneration == wanted.ownership,
      state.activeTabId(view.windowId) == wanted.tabId,
      state.windowUi[view.windowId]?.json["panel"]?["open"]?.truthy == true,
      state.windowUi[view.windowId]?.json["panel"]?["newTab"]?.truthy == true,
      view.tabId == wanted.tabId, view.bar.model?.tabId == wanted.tabId,
      view.bar.model?.windowId == view.windowId,
      view.bar.model?.opensTab == true, view.bar.model?.field?.hasFocus == true,
      view.window?.isKeyWindow == true else { return }
    panelFocus[view.windowId] = nil
    FocusMoves.claim(wanted.generation, destination: view.bar)
  }

  private static func requestHeroFocus(_ tabId: String, windowId: String, generation: Int?) {
    if let previous = newTabFocus.removeValue(forKey: windowId), let generation = previous.generation {
      WindowHost.cancelCommandFocus(generation, restoring: false)
    }
    let responder = WindowHost.contentView(windowId)?.window?.firstResponder
    let request = UUID()
    newTabFocus[windowId] = NewTabFocus(tabId: tabId, generation: generation,
      ownership: NativeStoreHandle.ownershipGeneration, request: request,
      responder: responder.map(ObjectIdentifier.init),
      editorDelegate: (responder as? NSTextView)?.delegate.map { ObjectIdentifier($0) })
    if let root = WindowHost.contentView(windowId) { findNewTab(in: root) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      guard let wanted = newTabFocus[windowId], wanted.request == request else { return }
      newTabFocus[windowId] = nil
      if let generation = wanted.generation { WindowHost.cancelCommandFocus(generation, restoring: false) }
    }
  }

  static func newTabViewReady(_ view: NativeNewTabView) {
    guard let wanted = newTabFocus[view.windowId], wanted.tabId == view.tabId, let window = view.window else { return }
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.ownershipGeneration == wanted.ownership,
      NativeStoreHandle.store?.state.activeTabId(view.windowId) == wanted.tabId, window.isKeyWindow else {
      newTabFocus[view.windowId] = nil
      if let generation = wanted.generation { WindowHost.cancelCommandFocus(generation, restoring: false) }
      return
    }
    let responder = window.firstResponder
    let unchanged = responder == nil || (responder.map(ObjectIdentifier.init) == wanted.responder
      && (responder as? NSTextView)?.delegate.map { ObjectIdentifier($0) } == wanted.editorDelegate)
    newTabFocus[view.windowId] = nil
    guard unchanged || view.hero.model?.field?.hasFocus == true else {
      if let generation = wanted.generation { WindowHost.cancelCommandFocus(generation, restoring: false) }
      return
    }
    view.hero.focusBar()
    if let generation = wanted.generation { FocusMoves.claim(generation, destination: view.hero) }
  }

  private static func focusPage(_ tabId: String, stopFinding: Bool = false) {
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      if stopFinding { issuer.issueInScope(tabId: tabId, identity: binding.identity, command: .stopFinding(false)) { _ in } }
      issuer.issueInScope(tabId: tabId, identity: binding.identity, command: .focus) { _ in }
    }
  }

  private static func restoreContentFocus(windowId: String, store: Store, tabId: String? = nil, stopFinding: Bool = false) {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      WindowHost.contentView(windowId)?.window?.isKeyWindow == true,
      let target = tabId ?? store.state.peeks[windowId]?.tabId ?? store.state.activeTabId(windowId),
      let tab = store.state.tabs[target], tab.windowId == windowId else { return }
    newTabFocus[windowId] = nil
    WindowHost.endCommandFocus(windowId)
    TabPoolHost.shared.prepareCommandFocus()
    if tab.url.isEmpty { requestHeroFocus(target, windowId: windowId, generation: nil) }
    else { focusPage(target, stopFinding: stopFinding) }
  }

  private static func findNewTab(in view: NSView) {
    if let view = view as? NativeNewTabView { newTabViewReady(view) }
    for child in view.subviews { findNewTab(in: child) }
  }

  private static func materializeChanges(before: BrowserState, after: BrowserState) {
    for id in after.windowOrder where before.windows[id] == nil {
      guard let window = after.windows[id] else { continue }
      let title = after.activeTab(id).map { $0.customTitle ?? $0.title } ?? "New Tab"
      WindowHost.openBrowserWindow(id, frame: window.frame, incognito: window.incognito,
        profile: after.engineProfile(window.profileId), title: title, focus: after.ui.focusedWindowId == id,
        chromeWindow: window.chromeWindow, small: window.isSmall, size: after.settings["littleSolaraSize"]?.array?.compactMap(\.number))
    }
    for id in before.windowOrder where after.windows[id] == nil { WindowHost.closeBrowserWindow(id) }
  }

  private static func createProfile(store: Store) -> String? {
    let alert = NSAlert()
    alert.messageText = "New Profile"
    alert.addButton(withTitle: "Create Profile")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Profile name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.jsTrim().isEmpty,
      NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else { return nil }
    return (try? store.dispatch(Command("createProfile", [["name": .string(field.stringValue.jsTrim())]]), origin: .native))?.result?.string
  }

  private static func closeTabs(_ ids: [String], windowId: String, store: Store) {
    guard !store.memory.closingWindows.contains(windowId), !pending.contains(windowId) else { return }
    let before = store.state
    guard before.windows[windowId] != nil else { return }
    let decision = WorkspaceClosePolicy.tabs(ids, windowId: windowId, state: before, lastTabKeepsWindow: store.memory.lastTabKeepsWindow)
    let open = decision.tabIds
    guard !open.isEmpty else { return }
    let closes = decision.closesWindow
    let setting = decision.warningSetting
    guard let setting, before.settings.bool(setting) else { return finishClosingTabs(open, closes: closes, windowId: windowId, store: store) }
    askClose(windowId, setting: setting, store: store) { finishClosingTabs(open, closes: closes, windowId: windowId, store: store) }
  }

  private static func finishClosingTabs(_ open: [String], closes: Bool, windowId: String, store: Store) {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, !store.memory.closingWindows.contains(windowId) else { return }
    let current = store.state
    let remaining = open.filter { current.tabs[$0]?.windowId == windowId }
    guard !remaining.isEmpty else { return }
    let stillCloses = WorkspaceClosePolicy.tabs(remaining, windowId: windowId, state: current, lastTabKeepsWindow: store.memory.lastTabKeepsWindow).closesWindow
    _ = try? store.dispatch(Command("setSelection", [.string(windowId), []]), origin: .native)
    if closes && stillCloses { return animateClose(windowId, store: store) }
    _ = try? store.dispatch(Command("closeCommandTabs", [.array(remaining.map(JSONValue.string))]), origin: .native)
    materializeChanges(before: current, after: store.state)
    FrameUpdates.flush()
    if current.activeTabId(windowId) != store.state.activeTabId(windowId) {
      restoreContentFocus(windowId: windowId, store: store)
    }
  }

  static func runCloseRoute(_ route: WorkspaceCloseRoute, tabId: String, store: Store, removedPin: (String) -> Void) {
    switch route {
    case .unload(let ids):
      _ = try? store.dispatch(Command("closeTabs", [.array(ids.map(JSONValue.string))]), origin: .native)
      FrameUpdates.flush()
    case .close:
      closeFromControl(tabId, store: store)
    case .removePinOrClose:
      let removed = (try? store.dispatch(Command("removeClosedPin", [.string(tabId)]), origin: .native))?.result ?? .null
      if removed.isNull { return closeFromControl(tabId, store: store) }
      FrameUpdates.flush()
      if removed["entries"]?.array?.isEmpty == false { removedPin(removed.text()) }
    }
  }

  private static func closeFromControl(_ tabId: String, store: Store) {
    let before = store.state
    guard let close = WorkspaceClosePolicy.control(tabId, state: before, lastTabKeepsWindow: store.memory.lastTabKeepsWindow) else { return }
    let windowId = close.windowId
    guard !store.memory.closingWindows.contains(windowId), !pending.contains(windowId) else { return }
    guard let setting = WorkspaceClosePolicy.controlWarning(close, state: before) else { return finishControlClose(tabId, close, store: store) }
    askClose(windowId, setting: setting, store: store) { finishControlClose(tabId, close, store: store) }
  }

  private static func finishControlClose(_ tabId: String, _ close: WorkspaceControlClose, store: Store) {
    let windowId = close.windowId
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, !store.memory.closingWindows.contains(windowId),
      store.state.tabs[tabId] != nil else { return }
    let current = store.state
    let now = WorkspaceClosePolicy.control(tabId, state: current, lastTabKeepsWindow: store.memory.lastTabKeepsWindow)
    if close.last, now?.windowId == windowId, now?.closesItsWindow == true { return animateClose(windowId, store: store) }
    _ = try? store.dispatch(Command("closeTab", [.string(tabId)]), origin: .native)
    materializeChanges(before: current, after: store.state)
    FrameUpdates.flush()
  }

  private static func closeWindow(_ id: String, store: Store) {
    guard !store.memory.closingWindows.contains(id), !pending.contains(id) else { return }
    guard let window = store.state.windows[id] else { return }
    if !window.isSmall, WindowHost.retainLastWindow(id) { return }
    let small = window.isSmall
    guard let setting = WorkspaceClosePolicy.windowWarning(windowId: id, state: store.state), store.state.settings.bool(setting) else {
      return finishClosingWindow(id, small: small, store: store)
    }
    askClose(id, setting: setting, store: store) { finishClosingWindow(id, small: small, store: store) }
  }

  private static func finishClosingWindow(_ id: String, small: Bool, store: Store) {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, store.state.windows[id] != nil,
      !store.memory.closingWindows.contains(id) else { return }
    if !small, WindowHost.retainLastWindow(id, committingClose: true) { return }
    animateClose(id, store: store)
  }

  private static func animateClose(_ id: String, store: Store) {
    guard let window = store.state.windows[id] else { return }
    let leaving = Set(window.tabIds)
    let generation = NativeStoreHandle.ownershipGeneration
    _ = try? store.dispatch(Command("setWindowClosing", [.string(id), true]), origin: .native)
    WindowHost.animateClose(id) {
      let sameStore = NativeStoreHandle.store === store
      if sameStore { _ = try? store.dispatch(Command("setWindowClosing", [.string(id), false]), origin: .native) }
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.ownershipGeneration == generation, sameStore else {
        if sameStore { WindowHost.cancelWindowClose(id) }
        return
      }
      guard store.state.windows[id] != nil else { return }
      guard WorkspaceClosePolicy.canFinishClose(windowId: id, leaving: leaving, state: store.state) else {
        WindowHost.cancelWindowClose(id)
        return
      }
      _ = try? store.dispatch(Command("closeWindow", [.string(id)]), origin: .native)
      WindowHost.closeBrowserWindow(id)
      FrameUpdates.flush()
    }
  }

  private static func closingTabs(in state: BrowserState, windowId: String) -> [String] {
    guard let window = state.windows[windowId] else { return [] }
    return window.tabIds
  }

  private static func askClose(_ id: String, setting: String, store: Store, then proceed: @escaping @MainActor () -> Void) {
    guard let alert = closeAlert(id, store: store) else { return }
    askGuarded(alert, windowId: id, setting: setting, store: store, then: proceed)
  }

  @discardableResult
  static func askGuarded(
    _ alert: NSAlert, windowId: String, setting: String?, store: Store, then proceed: @escaping @MainActor () -> Void
  ) -> Bool {
    guard WorkspaceSheetGuard.claim(&pending, windowId: windowId, closing: store.memory.closingWindows) else { return false }
    let window = ShellDrag.window(windowId)
    if let window {
      sheetWindowObservers[windowId] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
        MainActor.assumeIsolated { settleSheet(windowId) }
      }
    }
    let decide: (NSApplication.ModalResponse) -> Void = { response in
      settleSheet(windowId)
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else { return }
      if let setting, alert.showsSuppressionButton, alert.suppressionButton?.state == .on {
        _ = try? store.dispatch(Command("updateSettings", [[setting: false]]), origin: .native)
      }
      if response == .alertFirstButtonReturn { proceed() }
    }
    if let window, window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: decide)
    } else {
      decide(alert.runModal())
    }
    return true
  }

  private static func settleSheet(_ windowId: String) {
    pending.remove(windowId)
    if let observer = sheetWindowObservers.removeValue(forKey: windowId) { NotificationCenter.default.removeObserver(observer) }
  }

  private static func finishMovingToProfile(_ tabId: String, target: String, store: Store) {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      let tab = store.state.tabs[tabId], store.state.profiles[target] != nil, tab.profileId != target else { return }
    let before = store.state
    _ = try? store.dispatch(Command("moveTabToProfile", [.string(tabId), .string(target)]), origin: .native)
    materializeChanges(before: before, after: store.state)
    FrameUpdates.flush()
  }

  static func confirmAlert(_ title: String, message: String, button: String, suppression: String = "Don’t ask me again") -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = suppression
    return alert
  }

  private static func profileName(_ profileId: String, in state: BrowserState) -> String {
    if Ids.isIncognitoProfile(profileId) { return "Incognito" }
    return (state.profiles[profileId] ?? state.profiles[state.settings.defaultProfileId])?.name ?? "Incognito"
  }

  private static func closeAlert(_ id: String, store: Store) -> NSAlert? {
    let state = store.state
    guard let window = state.windows[id] else { return nil }
    let ids = closingTabs(in: state, windowId: id)
    let count = ids.count
    let tabs = "\(count) \(count == 1 ? "tab" : "tabs")"
    var profiles: [(String, Int)] = []
    for id in ids {
      let profile = state.tabs[id]?.profileId ?? window.profileId
      if let index = profiles.firstIndex(where: { $0.0 == profile }) { profiles[index].1 += 1 } else { profiles.append((profile, 1)) }
    }
    let message = profiles.count > 1
      ? (["Closing this window closes all tabs open across profiles:"] + profiles.map { profile, count in
          "  • \(count) \(count == 1 ? "tab" : "tabs") in \(profileName(profile, in: state))"
        }).joined(separator: "\n")
      : "This window has \(tabs) open in your \(profileName(window.profileId, in: state)) profile."
    return confirmAlert("Close \(tabs)?", message: message, button: count == 1 ? "Close Tab" : "Close All Tabs")
  }
}
