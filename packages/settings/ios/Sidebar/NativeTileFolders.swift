import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeTileFolders {
  private static var panel = TileFolderPanelState()
  private static var shown: (windowId: String, page: Weak<SidebarView>, request: FolderPanelRequest)?
  private static var lifecycle: Int?
  private static var owner: ObjectIdentifier?
  private static var sequence = 0
  #if DEBUG
  private(set) static var handled = 0
  #endif

  static func start() {
    guard lifecycle == nil else { return }
    owner = WorkspaceActionRouter.ownedStore.map(ObjectIdentifier.init)
    lifecycle = NativeStoreHandle.subscribeLifecycle { ownershipChanged() }
  }

  static var owned: Bool { WorkspaceActionRouter.ownedStore != nil }

  @discardableResult
  static func toggle(windowId: String, folderId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    switch panel.toggle(windowId: windowId, folderId: folderId) {
    case .close:
      close()
    case .open:
      guard let page = page(windowId), (page.frameOf("folder:\(folderId)") ?? page.frameOf(folderId)) != nil else { return true }
      let previous = panel.open
      panel.opened(windowId: windowId, folderId: folderId, state: store.state)
      if let previous, previous.windowId != windowId { hide(previous.windowId) }
      show(store.state)
      mirror()
    }
    return true
  }

  @discardableResult
  static func close() -> Bool {
    guard let slot = panel.open else { return false }
    panel.close()
    hide(slot.windowId)
    mirror()
    return true
  }

  @discardableResult
  static func close(in windowId: String?) -> Bool {
    guard let windowId, panel.folder(in: windowId) != nil else { return false }
    return close()
  }

  static func render(windowId: String) {
    guard panel.folder(in: windowId) != nil, let store = WorkspaceActionRouter.ownedStore else { return }
    if panel.check(store.state) {
      hide(windowId)
      mirror()
      return
    }
    show(store.state)
  }

  static func hostStopped(_ windowId: String, page: SidebarView?) {
    if let page, shown?.page.value === page { shown = nil }
    let gone = WorkspaceActionRouter.ownedStore?.state.windows[windowId] == nil
    guard panel.folder(in: windowId) != nil, gone else { return }
    close()
  }

  @discardableResult
  static func folderMenu(windowId: String, folderId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    dismissHover(windowId)
    let items = TileFolderMenus.folderMenu(store.state, windowId: windowId, folderId: folderId)
    guard !items.isEmpty else { return true }
    ShellMenus.choose(items.map(\.dictionary)) { [weak store] picked in
      guard let picked else { return }
      if let choice = TileFolderMenuChoice(picked), let store, WorkspaceActionRouter.ownedStore === store {
        switch choice {
        case .rename:
          rename(windowId: windowId, folderId: folderId)
        case .remove, .unpin:
          if let command = TileFolderMenus.command(choice, state: store.state, windowId: windowId, folderId: folderId) { dispatch(store, command) }
        case .tab:
          break
        }
      }
      close()
    }
    return true
  }

  @discardableResult
  static func stripGroupMenu(windowId: String, groupId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    let items = TileFolderMenus.stripGroupFolder(store.state, groupId: groupId, activeId: store.state.activeTabId(windowId))
    ShellMenus.choose(items.map(\.dictionary)) { [weak store] picked in
      guard case .tab(let tabId)? = picked.flatMap(TileFolderMenuChoice.init), let store, WorkspaceActionRouter.ownedStore === store,
        store.state.tabs[tabId] != nil else { return }
      dispatch(store, TileFolderPanel.plainClick(windowId: windowId, tabId: tabId))
    }
    return true
  }

  @discardableResult
  static func stripTileMenu(windowId: String, folderId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    let items = TileFolderMenus.stripTileFolder(store.state, windowId: windowId, folderId: folderId)
    ShellMenus.choose(items.map(\.dictionary)) { [weak store] picked in
      guard let choice = picked.flatMap(TileFolderMenuChoice.init), let store, WorkspaceActionRouter.ownedStore === store else { return }
      switch choice {
      case .rename:
        rename(windowId: windowId, folderId: folderId)
      case .tab(let tabId):
        if store.state.tabs[tabId] != nil { dispatch(store, TileFolderPanel.plainClick(windowId: windowId, tabId: tabId)) }
      case .remove, .unpin:
        break
      }
    }
    return true
  }

  @discardableResult
  static func rename(windowId: String, folderId: String, title: String = "Rename Folder") -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    guard let folder = TileFolderPanel.folder(store.state, windowId: windowId, folderId: folderId) else { return true }
    NativeWorkspaceRename.prompt(title, value: folder.name, placeholder: "Folder", windowId: windowId, store: store) { name in
      guard WorkspaceActionRouter.ownedStore === store else { return }
      dispatch(store, TileFolderMenus.renameCommand(windowId: windowId, folderId: folderId, name: name))
    }
    return true
  }

  @discardableResult
  static func newFolderWithTab(windowId: String, tabId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    guard let folderId = dispatch(store, TileFolderMenus.newFolderCommand(tabId: tabId)), !folderId.isEmpty else { return true }
    rename(windowId: windowId, folderId: folderId, title: "Name Folder")
    return true
  }

  @discardableResult
  static func leaveFolder(tabId: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore else { return false }
    count()
    dispatch(store, TileFolderMenus.leaveCommand(tabId: tabId))
    return true
  }

  private static func show(_ state: BrowserState) {
    guard let slot = panel.open, let page = page(slot.windowId), let window = state.windows[slot.windowId] else { return }
    let appearance = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let look = FolderPanelLook(dark: appearance.dark, theme: appearance.tokens)
    let request = TileFolderPanel.request(state, windowId: slot.windowId, folderId: slot.folderId, look: look)
    if let shown, shown.windowId == slot.windowId, shown.page.value === page, shown.request == request { return }
    if let old = shown?.page.value, old !== page { SidebarFolderPanelHost.hide(on: old) }
    shown = (slot.windowId, Weak(page), request)
    let windowId = slot.windowId
    let folderId = slot.folderId
    SidebarFolderPanelHost.show(on: page, windowId: windowId, request: request) { event in
      MainActor.assumeIsolated { handle(event, windowId: windowId, folderId: folderId) }
    }
  }

  private static func hide(_ windowId: String) {
    if let shown, shown.windowId == windowId {
      if let old = shown.page.value { SidebarFolderPanelHost.hide(on: old) }
      self.shown = nil
    }
    guard let page = page(windowId) else { return }
    SidebarFolderPanelHost.hide(on: page)
  }

  private static func handle(_ event: FolderPanelEvent, windowId: String, folderId: String) {
    if case .outsidePress = event {
      close(in: windowId)
      return
    }
    guard panel.open?.windowId == windowId, panel.open?.folderId == folderId else { return }
    switch event {
    case .open(let tabId):
      close()
      guard let store = WorkspaceActionRouter.ownedStore else { return }
      dispatch(store, TileFolderPanel.plainClick(windowId: windowId, tabId: tabId))
    case .tabMenu(let tabId):
      guard WorkspaceActionRouter.ownedStore?.state.tabs[tabId] != nil else { return }
      dismissHover(windowId)
      let opened = NativeTabMenu.open(tabId, windowId: windowId) { id, choice, ids in
        Task { @MainActor in _ = await SettingsAdapters.js("sidebar.action", windowId, ids == nil ? "tabMenuChoice" : "tabMenuSelectionChoice", id, ["choice": choice, "ids": ids ?? []]) }
      }
      if !opened, NativeTabMenu.calendarMenuInJS(tabId, windowId: windowId) {
        Task { @MainActor in _ = await SettingsAdapters.js("sidebar.action", windowId, "tabMenu", tabId, [String: Any]()) }
      } else if !opened {
        NSLog("[sidebar] tabMenu refused: native store unavailable, dispatch failed or target stale")
      }
    case .folderMenu:
      folderMenu(windowId: windowId, folderId: folderId)
    case .outsidePress, .drag:
      break
    }
  }

  private static func page(_ windowId: String) -> SidebarView? { NativeSidebar.hosts[windowId]?.view.current }

  private static func dismissHover(_ windowId: String) {
    Task { @MainActor in _ = await SettingsAdapters.js("sidebar.action", windowId, "handled", "", [String: Any]()) }
  }

  private static func mirror() {
    sequence += 1
    let seq = sequence
    let slot = panel.open
    Task { @MainActor in _ = await SettingsAdapters.js("folderPanel.state", slot?.windowId ?? "", slot?.folderId ?? "", seq) }
  }

  private static func ownershipChanged() {
    let current = WorkspaceActionRouter.ownedStore.map(ObjectIdentifier.init)
    guard current != owner else { return }
    owner = current
    close()
  }

  private static func count() {
    #if DEBUG
    handled += 1
    #endif
  }

  @discardableResult
  private static func dispatch(_ store: Store, _ command: Command) -> String? {
    defer { FrameUpdates.flush() }
    do {
      return try store.dispatch(command, origin: .native).result?.string
    } catch {
      NSLog("[tileFolders] %@ refused: %@", command.name, String(describing: error))
      return nil
    }
  }
}

private final class Weak<Value: AnyObject> {
  weak var value: Value?
  init(_ value: Value) { self.value = value }
}
