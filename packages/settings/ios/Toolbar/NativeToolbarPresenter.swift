import AppKit
import SolaraEngine
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeToolbarPresenter {
  private static let live = NSHashTable<NativeToolbarPresenter>.weakObjects()
  private let host = UUID().uuidString
  private let deliver: (ToolbarState?, SidebarAddressBarState?) -> Void
  private var input: ToolbarPresenter.Input?
  private var fallback: JSONValue?
  private var rawInput: String?
  private var fullscreen: Bool?
  private weak var store: Store?
  private var observedStore: ObjectIdentifier?
  private var listener: Int?
  private var lifecycle: Int?
  private var bookmarkTask: Task<Void, Never>?
  private var bookmarkEngine: String?
  private var invalidated = false
  private var target: (profile: String, createdAt: Double)?
  private var holder: String?
  private var opener: String?
  private var endedEditRequest: Int?
  private var bookmarkLookup: (engine: String, revision: Int, url: String, found: Bool)?
  private var extensionProjection: JSONValue?
  private var extensionButtons: [ToolbarButtonState] = []
  private var lastToolbar: ToolbarState?
  private var lastSidebar: SidebarAddressBarState?

  init(deliver: @escaping (ToolbarState?, SidebarAddressBarState?) -> Void) {
    self.deliver = deliver
    Self.live.add(self)
  }

  func update(_ json: String?) {
    guard rawInput != json else { return }
    guard let json, let next = try? JSONDecoder().decode(ToolbarPresenter.Input.self, from: Data(json.utf8)) else {
      end()
      return
    }
    if input?.windowId != next.windowId || input?.tabId != next.tabId {
      releaseExtensionHost()
      resetTarget()
      invalidated = false
    }
    rawInput = json
    input = next
    let values = try? JSONValue.parse(Data(json.utf8))
    fallback = values?["fallback"]
    if lifecycle == nil {
      lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcileStore() }
    } else {
      refresh()
    }
  }

  func end() {
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let listener { store?.unsubscribe(listener) }
    listener = nil
    store = nil
    observedStore = nil
    if input != nil { releaseExtensionHost() }
    input = nil
    fallback = nil
    rawInput = nil
    fullscreen = nil
    resetTarget()
    invalidated = false
    observeBookmarks(nil)
    publish(nil, nil)
  }

  static func refreshContributions() {
    for presenter in live.allObjects { presenter.refresh() }
  }

  static func refreshLayout(windowId: String, fullscreen: Bool) {
    for presenter in live.allObjects where presenter.input?.windowId == windowId && presenter.fullscreen != fullscreen {
      presenter.fullscreen = fullscreen
      presenter.refresh()
    }
  }

  private func reconcileStore() {
    let current = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    let identity = current.map(ObjectIdentifier.init)
    if observedStore != identity || store !== current {
      if let listener { store?.unsubscribe(listener) }
      if observedStore != nil {
        invalidated = true
        releaseExtensionHost()
      }
      observedStore = identity
      store = current
      listener = current?.subscribe { [weak self, weak current] commit in
        Task { @MainActor [weak self, weak current] in
          guard let self, let current, self.store === current else { return }
          self.storeChanged(commit.changes)
        }
      }
    }
    refresh()
  }

  private func storeChanged(_ changes: ChangeSet) {
    guard let input else { return }
    if changes.tabs.removed.contains(input.tabId) || changes.windows.removed.contains(input.windowId) {
      if !invalidated { releaseExtensionHost() }
      invalidated = true
    }
    let tabIds = [input.tabId, holder, opener].compactMap { $0 }
    guard invalidated || changes.settings || !changes.splits.isEmpty || !changes.groups.isEmpty || !changes.peeks.isEmpty
      || !changes.profiles.isEmpty || changes.windows.upserted.contains(input.windowId)
      || tabIds.contains(where: { changes.tabs.upserted.contains($0) || changes.tabs.removed.contains($0)
        || changes.live.upserted.contains($0) || changes.live.removed.contains($0) }) else { return }
    refresh()
  }

  private func observeBookmarks(_ engine: String?) {
    guard bookmarkEngine != engine else { return }
    bookmarkTask?.cancel()
    bookmarkEngine = engine
    bookmarkTask = engine.map { engine in
      Task { @MainActor [weak self] in
        for await _ in NativeHistoryCatalog.catalog.observeBookmarks(engineProfile: engine) {
          guard !Task.isCancelled, let self, bookmarkEngine == engine else { return }
          refresh()
        }
      }
    }
  }

  private func releaseExtensionHost() {
    NativeExtensionCommands.run(["command": "releaseToolbar", "id": .string(host)])
  }

  private func publish(_ toolbar: ToolbarState?, _ sidebar: SidebarAddressBarState?) {
    guard lastToolbar != toolbar || lastSidebar != sidebar else { return }
    lastToolbar = toolbar
    lastSidebar = sidebar
    deliver(toolbar, sidebar)
  }

  private func refresh() {
    guard let input, !invalidated, !NativeStoreHandle.frozen,
      let state = store?.state ?? fallbackState(input) else {
      observeBookmarks(nil)
      publish(nil, nil)
      return
    }
    let windowId = input.windowId
    let tabId = input.tabId
    guard let window = state.windows[windowId], input.sidebar == nil || (window.activeTabIds[window.profileId] ?? "") == tabId else {
      observeBookmarks(nil)
      publish(nil, nil)
      return
    }
    guard let page = ToolbarPresenter.page(windowId: windowId, tabId: tabId, state: state),
      target.map({ $0.profile == page.tab.profileId && $0.createdAt == page.tab.createdAt }) != false else {
      if target != nil {
        invalidated = true
        releaseExtensionHost()
      }
      observeBookmarks(nil)
      publish(nil, ToolbarPresenter.sidebar(input, state: state, toolbar: nil))
      return
    }
    target = (page.tab.profileId, page.tab.createdAt)
    holder = page.tab.pageIn
    opener = page.tab.openerId
    if input.editing && !page.developer && endedEditRequest != input.editRequest {
      endedEditRequest = input.editRequest
      Task { @MainActor in _ = await SettingsAdapters.js("toolbar.endEdit", tabId, input.editRequest) }
    }
    let engine = state.engineProfile(page.bookmarkProfile)
    observeBookmarks(store == nil ? nil : engine)
    let bookmarked = store == nil ? fallback?["bookmarked"]?.bool == true : bookmarkMembership(page.tab.url, engine: engine)
    let extensionInput: JSONValue = [
      "host": .string(host), "windowId": .string(windowId), "tabId": .string(tabId),
      "limit": input.extensionLimit.map { .number(Double($0)) } ?? .null,
      "accent": .string(input.accent),
    ]
    let projection = NativeExtensionCommands.toolbar(extensionInput)
    if extensionProjection != projection {
      extensionProjection = projection
      let data = projection["buttons"].flatMap { try? JSONSerialization.data(withJSONObject: $0.foundation) }
      extensionButtons = data.flatMap { try? JSONDecoder().decode([ToolbarButtonState].self, from: $0) } ?? []
    }
    let toolbar = ToolbarPresenter.present(input, state: state, page: page, shell: NativeWindowShell.active(windowId),
      fullscreen: fullscreen ?? ToolbarPresenter.fullscreen(input, state: state),
      engineBack: NativeEngineCommands.hasBack(page.tab.pageIn ?? tabId), bookmarked: bookmarked, extensions: extensionButtons,
      extensionsWidth: projection["width"]?.number ?? 0,
      translation: NativeTranslation.shared.toolbar(tabId: tabId, windowId: windowId))
    if input.sidebar != nil { publish(nil, ToolbarPresenter.sidebar(input, state: state, toolbar: toolbar)) }
    else { publish(toolbar, nil) }
  }

  private func resetTarget() {
    target = nil
    holder = nil
    opener = nil
    endedEditRequest = nil
    fullscreen = nil
    bookmarkLookup = nil
    extensionProjection = nil
    extensionButtons = []
  }

  private func bookmarkMembership(_ url: String, engine: String) -> Bool {
    guard !url.isEmpty else { return false }
    let snapshot = NativeHistoryCatalog.catalog.bookmarks(engineProfile: engine)
    if let cached = bookmarkLookup, cached.engine == engine, cached.revision == snapshot.revision,
      cached.url.utf16.elementsEqual(url.utf16) { return cached.found }
    let found = snapshot.nodes.values.contains { $0.kind == "url" && $0.url?.utf16.elementsEqual(url.utf16) == true }
    bookmarkLookup = (engine, snapshot.revision, url, found)
    return found
  }

  private func fallbackState(_ input: ToolbarPresenter.Input) -> BrowserState? {
    guard !NativeStoreHandle.ownedWorkspaceAtLaunch,
      let fallback, let rawWindow = fallback["window"]?.object,
      let window = try? BrowserWindow(json: rawWindow), window.id == input.windowId else { return nil }
    var state = BrowserState(settings: Settings.hydrated(from: fallback["settings"]))
    state.windows[window.id] = window
    if let rawTab = fallback["tab"]?.object, let tab = try? Tab(json: rawTab), tab.id == input.tabId {
      state.tabs[tab.id] = tab
      if let live = fallback["live"]?.object { state.live[tab.id] = try? PageLiveFacts(json: live) }
      if let holder = tab.pageIn, let live = fallback["holderLive"]?.object { state.live[holder] = try? PageLiveFacts(json: live) }
    }
    if let rawOpener = fallback["opener"]?.object, let opener = try? Tab(json: rawOpener) { state.tabs[opener.id] = opener }
    if let rawSplit = fallback["split"]?.object, let split = try? SplitView(json: rawSplit) { state.splits[split.id] = split }
    return state
  }

}
