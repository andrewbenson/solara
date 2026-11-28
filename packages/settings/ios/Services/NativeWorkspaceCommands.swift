import AppKit
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeWorkspaceCommands {
  #if DEBUG
  private static var closeWarningProbe: (windowId: String, title: String?)?

  static func devCloseWarning(_ windowId: String, action: String) -> String? {
    guard SolaraCoreTestHooksAllowed(), ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" else { return nil }
    if action == "arm" { closeWarningProbe = (windowId, nil) }
    if action == "clear" { closeWarningProbe = nil }
    return closeWarningProbe?.windowId == windowId ? closeWarningProbe?.title : nil
  }
  #endif

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
  private struct FindFocus {
    let windowId: String
    let tabId: String
    let generation: Int
    let ownership: Int
  }
  private static var findFocus: [Int: FindFocus] = [:]
  private static var expiredFindRequests: [Int] = []
  private static var lastFindRequest = 0
  private static var menuLifecycle: Int?
  private static var menuListener: Int?
  private static var menuStore: Store?

  private static weak var urlStore: Store?
  private static var urlStoreListener: Int?
  private static var urlLifecycle: Int?

  private static func observeApplicationURLs() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard urlStore !== store else { return }
    if let urlStoreListener { urlStore?.unsubscribe(urlStoreListener) }
    urlStore = store
    let generation = NativeStoreHandle.ownershipGeneration
    urlStoreListener = store?.subscribe { [weak store] commit in
      for case .openSettings(let pane) in commit.effects {
        DispatchQueue.main.async {
          guard let store, store === NativeStoreHandle.store, NativeStoreHandle.ownsWorkspace,
            NativeStoreHandle.ownershipGeneration == generation, !NativeStoreHandle.frozen else { return }
          NativeSettingsWindow.openFromURL(pane: pane)
        }
      }
    }
  }

  static func install() {
    ShortcutsAdapter.install()
    if menuLifecycle == nil {
      menuLifecycle = NativeStoreHandle.subscribeLifecycle { bindMenus() }
    }
    NativeBookmarkCommands.installMenu()
    if urlLifecycle == nil { urlLifecycle = NativeStoreHandle.subscribeLifecycle { observeApplicationURLs() } }
    NativePinnedPageCommands.start()
    NativeDownloadsPanel.start()
    ToolbarView.commandURLFocusAllowed = { NativeCommandBarFocus.developerAllowed($0, field: $1) }
    ToolbarView.commandURLDidFocus = { NativeCommandBarFocus.developerDidFocus($0, field: $1) }
    for command in WorkspaceMenuCommand.commands.union(ViewMenuCommand.commands).union(PageMenuCommand.commands).union(FindMenuCommand.commands).union(BookmarkMenuCommand.commands).union(NativeBookmarkCommands.formCommands).union(CopyLinkCommand.commands).union(BrowserServiceCommand.commands).union(TabFocusCommand.commands).union(["togglePageEngine"]).union(PinnedPageCommand.commands).union(NativeSidebarMenus.commands).union(["focusCommandBar", "cast", "restoreArcFolders", "showHistory", "manageBookmarks", "clearBrowsingData"]) {
      NativeMenuCommands.argumentHandlers[command] = { arg, windowId in perform(command, arg: arg, windowId: windowId) }
    }
    NativeMenuCommands.keepsMenuDispatch = ViewMenuCommand.commands.union(PageMenuCommand.commands).union(BookmarkMenuCommand.commands).union(NativeBookmarkCommands.formCommands).union(CopyLinkCommand.commands).union(BrowserServiceCommand.commands).union(TabFocusCommand.commands).union(["showHistory", "manageBookmarks"])
    NativeMenuCommands.sidebarPositionInWindow = { NativeWindowShell.nativeLayoutActive($0) }
    NativeMenuCommands.browserRow = { command, arg, windowId in
      browserMenuRow(command, arg: arg, windowId: windowId).map { ($0.enabled, $0.checked, $0.title) }
    }
    NativeMenuCommands.workspaceAvailability = { command, arg, windowId in
      if command == "findInPage", windowId == NativeSettingsWindow.windowId { return true }
      if command == "returnToPinnedUrl" { return NativePinnedPageCommands.available(windowId: windowId) }
      guard WorkspaceMenuCommand.commands.contains(command) else { return nil }
      guard NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state else {
        return command == "reopenClosedTab" || command == "reopenClosedWindow" ? false : nil
      }
      if command == "closeTab", windowId == nil, WindowHost.hasClosableForeignKeyWindow { return true }
      return WorkspaceMenuCommand.available(command, arg: arg, windowId: windowId, state: state)
    }
    WindowHost.closeRequest = { id in perform("closeWindow", windowId: id) }
  }

  private static func browserMenuRow(_ command: String, arg: String?, windowId: String?) -> BrowserMenuRow? {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return nil }
    if command == "closeTab", windowId == nil, WindowHost.hasClosableForeignKeyWindow { return nil }
    let state = store.state
    let window = windowId.flatMap { state.windows[$0] }
    let peek = window.flatMap { state.peeks[$0.id]?.tabId }
    let tabId = peek ?? window.flatMap { state.activeTabId($0.id) }
    let page = tabId.flatMap { state.tabs[$0] }
    let destination = page.map { $0.navigation?.url ?? $0.url } ?? ""
    let internalPage = SettingsOpening.internalPage(of: destination, isAppScheme: isAppScheme) != nil
    let live = tabId.flatMap { state.live[$0] }
    let holder = page?.pageIn ?? tabId
    var back = false
    var forward = false
    if command == "back" || command == "forward", let page, let holder {
      let history = store.menuHistoryFacts(holder)
      let opener = page.openerId.flatMap { state.tabs[$0] }
      let holderLive = state.live[holder]
      let openerBack = history.historyKnown && holderLive != nil && opener?.windowId == page.windowId && opener?.profileId == page.profileId
        && peek == nil && Splits.splitOf(state, page.id) == nil && !state.inPinnedContainer(page.id)
      back = !history.newTabShown && (holderLive?.canGoBack == true || NativeEngineCommands.hasBack(holder)
        || history.backToNewTab || openerBack)
      forward = store.menuHistoryFacts(page.id).newTabShown || live?.canGoForward == true
    }
    let engine = command == "togglePageEngine" ? tabId.map { store.pageEngine($0, in: state) } ?? "chromium" : "chromium"
    let bookmarked = command == "bookmarkPage" && NativeBookmarkCommands.isBookmarked(page?.url, windowId: window?.id)
    let context = BrowserMenuContext(state: state, windowId: windowId, pageId: tabId, opensPeek: peek != nil, internalPage: internalPage,
      loading: live?.isLoading == true, back: back, forward: forward, engine: engine, bookmarked: bookmarked, product: Bundle.main.productName)
    return context.row(command, arg: arg)
  }

  private static func bindMenus() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard store !== menuStore else { return }
    if let menuListener { menuStore?.unsubscribe(menuListener) }
    menuStore = store
    menuListener = store?.subscribe { [weak store] commit in
      let changes = commit.changes
      let history = !changes.lists.isDisjoint(with: ["closedTabs", "closedWindows", "closedGroups"])
      let destinations = !changes.windows.isEmpty || !changes.profiles.isEmpty || !changes.tabs.isEmpty
        || !changes.lists.isDisjoint(with: ["profileOrder", "windowOrder", "ui"])
        || changes.settingsChanged.contains("defaultProfileId") || changes.settingsRemoved.contains("defaultProfileId")
      guard history || destinations else { return }
      Task { @MainActor in
        guard let store, menuStore === store else { return }
        if history { refreshHistoryMenu() }
        if destinations { refreshDestinations() }
      }
    }
    refreshHistoryMenu()
    refreshDestinations()
  }

  private static func refreshDestinations() {
    guard let store = menuStore else {
      ShellMenus.setWorkspaceDestinations(profiles: [], windows: [])
      NativeBookmarkCommands.setMenuProfile(nil, engine: nil)
      return
    }
    let state = store.state
    let menu = WorkspaceMenuDestinations(state: state, windowId: state.ui.focusedWindowId, closing: store.memory.closingWindows)
    ShellMenus.setWorkspaceDestinations(profiles: menu.profiles.map { ($0.id, $0.title, $0.current) },
                                        windows: menu.windows.map { ($0.id, $0.title) })
    NativeBookmarkCommands.setMenuProfile(menu.bookmarkProfile, engine: state.engineProfile(menu.bookmarkProfile))
  }

  static func littleProfileMenu(windowId: String, store: Store) {
    let state = store.state
    guard WorkspaceWrites.store === store, let window = state.windows[windowId],
      window.isSmall, !store.memory.closingWindows.contains(windowId) else { return }
    let profiles = WorkspaceMenuDestinations.profileRows(state: state, window: window)
    guard !profiles.isEmpty else { return }
    let shortcuts = ShortcutsAdapter.hints
    let rows: [[String: Any]] = profiles.map { profile in
      var row: [String: Any] = ["id": profile.id, "title": profile.title, "checked": profile.current,
                                 "swatch": NativeLayoutAppearance.profileSwatch(state.profiles[profile.id])]
      if let hint = shortcuts[JSKey("switchProfile:\(profile.id)")], let key = GroupMenu.menuKey(hint) {
        row["key"] = key.key
        row["modifiers"] = key.modifiers
      }
      return row
    }
    let ownership = NativeStoreHandle.ownershipGeneration
    ShellMenus.choose(rows) { [weak store] choice in
      guard let choice, let store, WorkspaceWrites.store === store,
        NativeStoreHandle.ownershipGeneration == ownership else { return }
      moveLittleSolara(windowId, to: choice, store: store)
    }
  }

  private static func refreshHistoryMenu() {
    let menu = menuStore.map { RecentlyClosedMenu(state: $0.state) }
    ShellMenus.setRecentlyClosed(entries: menu?.entries.map { ($0.id, $0.title) } ?? [],
                                 groups: menu?.groups.map { ($0.id, $0.title) } ?? [])
  }

  private static func performView(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    guard let outcome = ViewMenuCommand.perform(command, arg: arg, windowId: windowId, store: store) else { return false }
    if let target = outcome.focusWindow { ShellScripting.showWindow(target) }
    if let appearance = outcome.appearance { ShellScripting.setAppearance(appearance) }
    FrameUpdates.flush()
    return true
  }

  private static func performPage(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    guard let plan = PageMenuCommand.plan(command, arg: arg, windowId: windowId, state: store.state, closing: store.memory.closingWindows) else { return false }
    if let target = plan.focusWindow {
      do { try store.dispatch(Command("setFocusedWindow", [.string(target)]), origin: .native) } catch { return false }
      ShellScripting.showWindow(target)
    }
    let live = plan.tabId.flatMap(livePage)
    guard !plan.needsLivePage || live != nil else { return true }
    if !plan.commands.isEmpty {
      do { try store.dispatch(plan.commands, origin: .native) } catch {
        NSLog("[commands] %@ failed: %@", command, String(describing: error))
      }
    }
    if let action = plan.page, let tabId = plan.tabId, live != nil { issuePage(action, tabId: tabId) }
    if let external = plan.external { openExternal(external) }
    FrameUpdates.flush()
    return true
  }

  private static func nextFindRequest() -> Int {
    lastFindRequest = FindMenuCommand.nextFocusRequest(after: lastFindRequest, nowMilliseconds: Int(Date().timeIntervalSince1970 * 1000))
    return lastFindRequest
  }

  private static func performFind(_ command: String, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    let request = nextFindRequest()
    guard let plan = FindMenuCommand.plan(command, windowId: windowId, state: store.state, closing: store.memory.closingWindows, focusRequest: request) else { return false }
    if let target = plan.focusWindow {
      do { try store.dispatch(Command("setFocusedWindow", [.string(target)]), origin: .native) } catch { return false }
      ShellScripting.showWindow(target)
    }
    if plan.claimsFocus, let target = plan.windowId, let tabId = plan.tabId {
      requestFindFocus(request, windowId: target, tabId: tabId)
    }
    if !plan.commands.isEmpty {
      do { try store.dispatch(plan.commands, origin: .native) } catch {
        if let pending = findFocus.removeValue(forKey: request) { WindowHost.cancelCommandFocus(pending.generation, restoring: true) }
        NSLog("[commands] %@ failed: %@", command, String(describing: error))
      }
    }
    if let action = plan.page, let tabId = plan.tabId {
      if plan.readsSelection { readSelectionForFind(action, tabId: tabId) } else { issuePage(action, tabId: tabId) }
    }
    FrameUpdates.flush()
    return true
  }

  static func cancelPendingFindFocus(windowId: String) {
    for (request, pending) in findFocus where pending.windowId == windowId {
      findFocus[request] = nil
      expiredFindRequests = Array((expiredFindRequests + [request]).suffix(16))
      #if DEBUG
      findFocusTimes[request] = nil
      FocusMoves.trace("commandBar cancel pending find focus \(request)")
      #endif
      WindowHost.cancelCommandFocus(pending.generation, restoring: true)
    }
  }

  private static func requestFindFocus(_ request: Int, windowId: String, tabId: String) {
    let generation = WindowHost.beginCommandFocus("findInPage", windowId: windowId)
    for (key, previous) in findFocus where previous.windowId == windowId {
      findFocus[key] = nil
      WindowHost.cancelCommandFocus(previous.generation, restoring: true)
    }
    guard let generation else { return }
    findFocus[request] = FindFocus(windowId: windowId, tabId: tabId, generation: generation, ownership: NativeStoreHandle.ownershipGeneration)
    #if DEBUG
    findFocusTimes[request] = CACurrentMediaTime()
    #endif
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      guard let wanted = findFocus.removeValue(forKey: request) else { return }
      expiredFindRequests = Array((expiredFindRequests + [request]).suffix(16))
      NSLog("[commands] find focus for %@ expired before the find bar took it", wanted.tabId)
      #if DEBUG
      findFocusTimes[request] = nil
      findFocusExpiries += 1
      #endif
      WindowHost.cancelCommandFocus(wanted.generation, restoring: true)
    }
  }

  #if DEBUG
  private static var findFocusTimes: [Int: CFTimeInterval] = [:]
  static private(set) var findFocusDelays: [Double] = []
  static private(set) var findFocusExpiries = 0
  #endif

  static func findFocusAllowed(_ request: Int) -> Bool {
    let pending = findFocus[request]
    let allowed = FindMenuCommand.focusAllowed(expired: expiredFindRequests.contains(request),
      pendingGateLive: pending.map { WindowHost.commandFocusLive($0.generation) })
    if !allowed, let pending {
      findFocus[request] = nil
      expiredFindRequests = Array((expiredFindRequests + [request]).suffix(16))
      NSLog("[commands] find focus for %@ outlived its focus gate", pending.tabId)
      #if DEBUG
      findFocusTimes[request] = nil
      findFocusExpiries += 1
      #endif
      WindowHost.cancelCommandFocus(pending.generation, restoring: true)
    }
    return allowed
  }

  static func findDidFocus(_ view: NativeFindBarView, request: Int) {
    guard let wanted = findFocus.removeValue(forKey: request) else { return }
    #if DEBUG
    if let start = findFocusTimes.removeValue(forKey: request) { findFocusDelays.append((CACurrentMediaTime() - start) * 1000) }
    #endif
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.ownershipGeneration == wanted.ownership,
      let state = NativeStoreHandle.store?.state, state.tabs[wanted.tabId]?.windowId == wanted.windowId,
      state.find[wanted.tabId]?.json["open"]?.truthy == true,
      let window = view.window, window === WindowHost.contentView(wanted.windowId)?.window, window.isKeyWindow else {
      WindowHost.cancelCommandFocus(wanted.generation, restoring: true)
      return
    }
    FocusMoves.claim(wanted.generation, destination: view.bar)
  }

  private static func readSelectionForFind(_ action: PageCommand, tabId: String) {
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      let identity = binding.identity
      issuer.issueInScope(tabId: tabId, identity: identity, command: action) { result in
        guard case .success(let value) = result, let query = FindMenuCommand.selectionQuery(value) else { return }
        let current = issuer.store.sequence { () -> Bool in
          guard let now = issuer.binding(tabId: tabId), now.identity == identity else { return false }
          return issuer.isCurrent(now)
        }
        guard current, NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store, store.state.tabs[tabId] != nil,
          let command = FindMenuCommand.selectionFind(query, tabId: tabId, focusRequest: nextFindRequest()) else { return }
        do { try store.dispatch(command, origin: .native) } catch {
          NSLog("[commands] useSelectionForFind failed: %@", String(describing: error))
        }
        FrameUpdates.flush()
      }
    }
  }

  private static func livePage(_ tabId: String) -> PageIdentity? {
    guard let issuer = PageIssuer.shared else { return nil }
    return issuer.store.sequence { () -> PageIdentity? in
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return nil }
      return binding.identity
    }
  }

  private static func issuePage(_ action: PageCommand, tabId: String) {
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      issuer.issueInScope(tabId: tabId, identity: binding.identity, command: action) { result in
        if case .failure(let error) = result { NSLog("[commands] %@ on %@ failed: %@", action.method, tabId, String(describing: error)) }
      }
    }
  }

  #if DEBUG
  static private(set) var lastExternal: String?
  #endif

  private static func openExternal(_ address: String) {
    guard let target = URL(string: address), target.scheme != nil else { return }
    #if DEBUG
    lastExternal = target.absoluteString
    #endif
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" {
      return NSLog("%@: background instance, not opening %@", Bundle.main.productName, target.absoluteString)
    }
    _ = NSWorkspace.shared.open(target)
  }

  @discardableResult
  static func perform(_ command: String, arg: String? = nil, windowId: String?) -> Bool {
    #if SOLARA_PROBES
    let timing = NewTabMainThreadTiming.begin("command.\(command)", windowId: windowId)
    defer { NewTabMainThreadTiming.end(timing) }
    #endif
    if command == "openLibraryPage" {
      if let arg, let options = try? JSONValue.parse(arg), let page = options["page"]?.string {
        SettingsDirectWrites.opening?.openInternalPage(page, windowId: windowId, query: options["query"]?.string,
          background: options["background"]?.truthy == true, scheme: appScheme(), isAppScheme: isAppScheme)
      }
      return true
    }
    if command == "showHistory" || command == "manageBookmarks" || command == "clearBrowsingData" {
      if let store = SettingsDirectWrites.store {
        let route = CommandRoute.resolve(command, windowId: windowId, state: store.state, closing: store.memory.closingWindows)
        if let target = route.windowId {
          let page = command == "manageBookmarks" ? "bookmarks" : "history"
          if SettingsDirectWrites.opening?.openInternalPage(page, windowId: target, focusTarget: route.focusWindow == target,
            scheme: appScheme(), isAppScheme: isAppScheme) == true, command == "clearBrowsingData" {
            NativePageView.requestClearData(windowId: target)
          }
        }
      }
      return true
    }
    if command == "addFolderToSidebar" {
      guard let store = SettingsDirectWrites.store, let arg else { return true }
      if let windowId, store.state.windows[windowId] == nil, !CommandRoute.utilityWindowIds.contains(windowId) { return true }
      if let target = CommandRoute.resolve(command, windowId: windowId, state: store.state, closing: store.memory.closingWindows).windowId,
        let editing = NativeBookmarkEditing(windowId: target), let snapshot = editing.snapshot() {
        NativeBookmarkCommands.addFolderToSidebar(arg, editing: editing, snapshot: snapshot)
      }
      return true
    }
    if command == "restoreArcFolders" {
      guard let arg else { return true }
      if let windowId, SettingsDirectWrites.store != nil {
        guard let editing = NativeBookmarkEditing(windowId: windowId) else { return true }
        Task {
          guard editing.live else { return }
          await NativeBookmarkHolderRestoration.restore(id: arg, windowId: windowId)
        }
      } else {
        Task { await NativeBookmarkHolderRestoration.restore(id: arg, windowId: windowId) }
      }
      return true
    }
    if command == "moveLittleSolaraToProfile" {
      guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
      if let windowId, let arg { moveLittleSolara(windowId, to: arg, store: store) }
      return true
    }
    if command == "cast" { return NativeCast.command(windowID: windowId) }
    if command == "togglePageEngine" { return NativeEngineCommands.perform(command, arg: arg, windowId: windowId) }
    if command == "toggleDeveloperMode" { return NativeSiteControls.toggleDeveloperMode(windowId: windowId) }
    if NativeExtensionCommands.perform(command, arg: arg, windowId: windowId) { return true }
    if PinnedPageCommand.commands.contains(command) { return NativePinnedPageCommands.perform(command, arg: arg, windowId: windowId) }
    if TabFocusCommand.commands.contains(command) { return NativeTabFocusCommands.perform(command, arg: arg, windowId: windowId) }
    if BrowserServiceCommand.commands.contains(command) { return NativeBrowserServiceCommands.perform(command, arg: arg, windowId: windowId) }
    if NativeBookmarkCommands.formCommands.contains(command) { return NativeBookmarkCommands.showForm(command, arg: arg, windowId: windowId) }
    if BookmarkMenuCommand.commands.contains(command) { return NativeBookmarkCommands.perform(command, arg: arg, windowId: windowId) }
    if CopyLinkCommand.commands.contains(command) { return NativeLinkCommands.perform(command, arg: arg, windowId: windowId) }
    if NativeSidebarMenus.commands.contains(command) { return NativeSidebarMenus.perform(command, windowId: windowId) }
    if command == "focusCommandBar" { return NativeCommandBarFocus.perform(windowId: windowId) }
    if ["newTab", "findInPage", "closeTab", "closeWindow"].contains(command) { NativeCommandBarFocus.cancel(windowId: windowId) }
    if ViewMenuCommand.commands.contains(command) { return performView(command, arg: arg, windowId: windowId) }
    if PageMenuCommand.commands.contains(command) { return performPage(command, arg: arg, windowId: windowId) }
    if command == "findInPage", windowId == NativeSettingsWindow.windowId { NativeSettingsWindow.focusSearch(); return true }
    if FindMenuCommand.commands.contains(command) { return performFind(command, windowId: windowId) }
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
    let closesPanel = plan.commands.first?.name == "closePanel"
    if command == "newTab", let focusWindow {
      if let previous = newTabFocus.removeValue(forKey: focusWindow), let generation = previous.generation {
        WindowHost.cancelCommandFocus(generation, restoring: false)
      }
      if let previous = panelFocus.removeValue(forKey: focusWindow) {
        WindowHost.cancelCommandFocus(previous.generation, restoring: false)
      }
    }
    let focusGeneration = focusWindow.flatMap { WindowHost.beginCommandFocus(closesPanel ? "closePanel" : command, windowId: $0) }
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
      if closesPanel, let focusWindow {
        if let focusGeneration {
          claimContentFocus(focusGeneration, windowId: focusWindow, store: store)
        } else if command == "newTab", let active = store.state.activeTabId(focusWindow), store.state.tabs[active]?.url.isEmpty == false {
          restoreContentFocus(windowId: focusWindow, store: store, tabId: active)
        }
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

  static func cancelNewTabFocus(windowId: String, restoring: Bool = false) {
    if let previous = newTabFocus.removeValue(forKey: windowId), let generation = previous.generation {
      WindowHost.cancelCommandFocus(generation, restoring: restoring)
    }
    if let previous = panelFocus.removeValue(forKey: windowId) { WindowHost.cancelCommandFocus(previous.generation, restoring: restoring) }
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
    let readyTab = view.tabId
    DispatchQueue.main.async { TabPoolHost.shared.allowPlaceholderPage(readyTab) }
    guard let wanted = newTabFocus[view.windowId], wanted.tabId == view.tabId, let window = view.window else { return }
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.ownershipGeneration == wanted.ownership,
      NativeStoreHandle.store?.state.activeTabId(view.windowId) == wanted.tabId, window.isKeyWindow else {
      newTabFocus[view.windowId] = nil
      if let generation = wanted.generation { WindowHost.cancelCommandFocus(generation, restoring: false) }
      return
    }
    guard view.canFocusHero else { return }
    let responder = window.firstResponder
    let unchanged = responder == nil || (responder.map(ObjectIdentifier.init) == wanted.responder
      && (responder as? NSTextView)?.delegate.map { ObjectIdentifier($0) } == wanted.editorDelegate)
    newTabFocus[view.windowId] = nil
    guard unchanged || view.hero.model?.field?.hasFocus == true else {
      if let generation = wanted.generation { WindowHost.cancelCommandFocus(generation, restoring: false) }
      return
    }
    view.focusHero()
    if let generation = wanted.generation { FocusMoves.claim(generation, destination: view.hero) }
  }

  private static func focusPage(_ tabId: String, stopFinding: Bool = false) {
    #if SOLARA_PROBES
    let timing = NewTabMainThreadTiming.begin("focus.page", tabId: tabId)
    defer { NewTabMainThreadTiming.end(timing) }
    #endif
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      if stopFinding { issuer.issueInScope(tabId: tabId, identity: binding.identity, command: .stopFinding(false)) { _ in } }
      issuer.issueInScope(tabId: tabId, identity: binding.identity, command: .focus) { _ in }
    }
  }

  static func restoreContentFocus(windowId: String, store: Store, tabId: String? = nil, stopFinding: Bool = false) {
    #if SOLARA_PROBES
    let timing = NewTabMainThreadTiming.begin("focus.restore", windowId: windowId, tabId: tabId)
    defer { NewTabMainThreadTiming.end(timing) }
    #endif
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

  private static func claimContentFocus(_ generation: Int, windowId: String, store: Store) {
    guard WindowHost.commandFocusCurrent(generation) else { return }
    guard let target = store.state.peeks[windowId]?.tabId ?? store.state.activeTabId(windowId),
      let tab = store.state.tabs[target], tab.windowId == windowId else {
      return WindowHost.cancelCommandFocus(generation, restoring: false)
    }
    TabPoolHost.shared.prepareCommandFocus()
    if tab.url.isEmpty {
      requestHeroFocus(target, windowId: windowId, generation: generation)
    } else if !TabPoolHost.shared.claimFocusPage(generation, tabId: target), WindowHost.commandFocusCurrent(generation) {
      WindowHost.cancelCommandFocus(generation, restoring: false)
      focusPage(target)
    }
  }

  private static func findNewTab(in view: NSView) {
    if let view = view as? NativeNewTabView { newTabViewReady(view) }
    for child in view.subviews { findNewTab(in: child) }
  }

  static func materializeChanges(before: BrowserState, after: BrowserState) {
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
    let field = NSTextField.solaraPromptField(placeholder: "Profile name")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.jsTrim().isEmpty,
      NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else { return nil }
    return (try? store.dispatch(Command("createProfile", [["name": .string(field.stringValue.jsTrim())]]), origin: .native))?.result?.string
  }

  static func closeTabs(_ ids: [String], windowId: String, store: Store) {
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
    if closes && stillCloses { return animateClose(windowId, store: store) }
    _ = try? store.dispatch([
      Command("setSelection", [.string(windowId), []]),
      Command("closeCommandTabs", [JSONValue(remaining)]),
    ], origin: .native)
    let closedPlaceholder = WorkspaceClosePolicy.removedPlaceholder(remaining, before: current, after: store.state)
    if closedPlaceholder {
      newTabFocus[windowId] = nil
      WindowHost.endCommandFocus(windowId)
      if let window = WindowHost.contentView(windowId)?.window, let responder = window.firstResponder as? NSView,
        let hero = sequence(first: responder, next: { $0.superview }).first(where: { $0 is NewTabHeroView }) as? NewTabHeroView,
        let heroTab = hero.model?.tabId, remaining.contains(heroTab) {
        window.makeFirstResponder(nil)
      }
      if let next = store.state.activeTabId(windowId), let page = TabPoolHost.shared.pageView(next) as? SolaraCoreWebView {
        page.activateInChrome()
      }
    }
    materializeChanges(before: current, after: store.state)
    FrameUpdates.flush()
    if closedPlaceholder || current.activeTabId(windowId) != store.state.activeTabId(windowId) {
      restoreContentFocus(windowId: windowId, store: store)
    }
  }

  static func runCloseRoute(_ route: WorkspaceCloseRoute, tabId: String, store: Store) {
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
      NativeSidebarUndo.show(removed, title: "Removed Pinned Tab", icon: "pin.slash", store: store)
    }
  }

  static func closeWorkspaceTab(_ tabId: String, successor: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    closeFromControl(tabId, successor: successor, store: store)
    return true
  }

  static func closeFromControl(_ tabId: String, successor: String? = nil, store: Store) {
    let before = store.state
    guard let close = WorkspaceClosePolicy.control(tabId, state: before, lastTabKeepsWindow: store.memory.lastTabKeepsWindow) else { return }
    let windowId = close.windowId
    guard !store.memory.closingWindows.contains(windowId), !pending.contains(windowId) else { return }
    guard let setting = WorkspaceClosePolicy.controlWarning(close, state: before) else { return finishControlClose(tabId, close, successor: successor, store: store) }
    askClose(windowId, setting: setting, store: store) { finishControlClose(tabId, close, successor: successor, store: store) }
  }

  private static func finishControlClose(_ tabId: String, _ close: WorkspaceControlClose, successor: String?, store: Store) {
    let windowId = close.windowId
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, !store.memory.closingWindows.contains(windowId),
      store.state.tabs[tabId]?.windowId == windowId else { return }
    let current = store.state
    let now = WorkspaceClosePolicy.control(tabId, state: current, lastTabKeepsWindow: store.memory.lastTabKeepsWindow)
    if close.last, now?.windowId == windowId, now?.closesItsWindow == true { return animateClose(windowId, store: store) }
    _ = try? store.dispatch(Command("closeTab", [.string(tabId), successor.map(JSONValue.string) ?? .null]), origin: .native)
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

  private static func moveLittleSolara(_ id: String, to profileId: String, store: Store) {
    let before = store.state
    guard let window = before.windows[id], window.isSmall, !window.incognito, window.profileId != profileId,
      before.profiles[profileId] != nil, !store.memory.closingWindows.contains(id), !pending.contains(id) else { return }
    let tab = before.activeTab(id)
    let url = tab?.url ?? ""
    var options: JSONObject = ["small": true, "profileId": .string(profileId)]
    if !url.isEmpty { options["url"] = .string(url) }
    if let frame = window.frame { options["frame"] = .array(frame.map(JSONValue.number)) }
    guard let replacement = (try? store.dispatch(Command("createWindow", [.object(options)]), origin: .native))?.result?.string else { return }
    if url.isEmpty { _ = try? store.dispatch(Command("openPanel", [.string(replacement), ""]), origin: .native) }
    materializeChanges(before: before, after: store.state)
    animateClose(id, after: replacement, forgetTab: tab?.id, store: store)
  }

  private static func animateClose(_ id: String, after replacement: String? = nil, forgetTab: String? = nil, store: Store) {
    guard let window = store.state.windows[id] else { return }
    let leaving = Set(window.tabIds)
    let generation = NativeStoreHandle.ownershipGeneration
    guard (try? store.dispatch(Command("setWindowClosing", [.string(id), true]), origin: .native)) != nil else { return }
    WindowHost.animateClose(id, after: replacement) {
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
      var commands = [Command("closeWindow", [.string(id)])]
      if let forgetTab { commands.append(Command("forgetClosedTab", [.string(forgetTab)])) }
      guard (try? store.dispatch(commands, origin: .native)) != nil, store.state.windows[id] == nil else {
        WindowHost.cancelWindowClose(id)
        return
      }
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
    #if DEBUG
    if setting == "warnBeforeClosingWindow", closeWarningProbe?.windowId == windowId, closeWarningProbe?.title == nil {
      closeWarningProbe?.title = alert.messageText
      decide(.alertFirstButtonReturn)
      return true
    }
    #endif
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

  static func moveFromSidebar(_ tabId: String, windowId: String, target: String, store: Store) {
    guard let tab = store.state.tabs[tabId], tab.windowId == windowId, !Ids.isIncognitoProfile(tab.profileId) else { return }
    if target == "new" {
      Task { @MainActor [weak store] in
        guard let store, let profile = await SettingsAdapters.js("sidebar.profileForm", windowId) as? String,
          WorkspaceWrites.store === store else { return }
        moveFromSidebar(tabId, windowId: windowId, target: profile, store: store)
      }
      return
    }
    let profile = target
    guard store.state.profiles[profile] != nil else { return }
    let finish: @MainActor @Sendable () -> Void = {
      guard store.state.tabs[tabId]?.windowId == windowId else { return }
      finishMovingToProfile(tabId, target: profile, store: store)
    }
    if store.state.settings.bool("warnBeforeMovingTabsToProfile"), store.state.engineProfile(tab.profileId) != store.state.engineProfile(profile) {
      let alert = confirmAlert("Move Tab to Profile?", message: "Moving tabs between profiles could result in some data being lost.", button: "Move Tab", suppression: "Don't warn me again")
      askGuarded(alert, windowId: windowId, setting: "warnBeforeMovingTabsToProfile", store: store, then: finish)
    } else { finish() }
  }

  static func newTabInGroup(_ groupId: String, windowId: String, store: Store) {
    guard store.state.groups[groupId]?.windowId == windowId else { return }
    let command: Command
    if GroupMenu.newTabOpensBar(store.state, windowId: windowId) {
      if store.state.windowUi[windowId]?.json["panel"]?["newTab"]?.truthy == true {
        _ = try? store.dispatch(Command("closePanel", [.string(windowId)]), origin: .native)
        FrameUpdates.flush()
        restoreContentFocus(windowId: windowId, store: store)
        return
      }
      let generation = WindowHost.beginCommandFocus("newTab", windowId: windowId)
      if let generation { requestPanelFocus(windowId: windowId, tabId: store.state.activeTabId(windowId), generation: generation) }
      command = Command("openPanel", [.string(windowId), "", ["kind": "group", "groupId": .string(groupId)]])
    } else {
      command = Command("newTabInGroup", [.string(groupId)])
    }
    if let id = (try? store.dispatch(command, origin: .native))?.result?.string, !id.isEmpty {
      _ = try? store.dispatch(Command("activate", [.string(id)]), origin: .native)
    }
    FrameUpdates.flush()
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
