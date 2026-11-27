import AppKit
import Foundation
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

@MainActor
enum NativeSelectionTools {
  private struct Entry {
    let identity: PageIdentity
    var page = PanePromptPage()
    var lifecycle = SelectionLifecycle()
    var shown: PaneSelection?
    var pending: PaneSelection?
    var revision = 0
  }

  private static var popovers = PanePopoverLifecycle()
  static var popoversChanged: (([String: String]) -> Void)?

  static func popoverSnapshot() -> [String: String] { popovers.values }
  static func zoomRevision(_ tabId: String) -> UInt64 { popovers.revision(tabId) }
  static func zoomShown(_ tabId: String) -> Bool { popovers.values[tabId] == "zoom" }

  static func setPopover(_ tabId: String, value: String?) -> [String: String] {
    if value != nil, popovers.values[tabId] == nil, let id = NativeStoreHandle.store?.state.tabs[tabId]?.windowId {
      NativeDownloadsPanel.setOpen(id, false)
    }
    popovers.set(value, tabId: tabId)
    popoversChanged?(popovers.values)
    changed(tabId)
    return popovers.values
  }

  static func dismissZoom(_ tabId: String, revision: UInt64) {
    guard popovers.dismissZoom(tabId, revision: revision) else { return }
    popoversChanged?(popovers.values)
    changed(tabId)
  }

  private static var entries: [String: Entry] = [:]
  private static var listeners: [UUID: () -> Void] = [:]
  private static var lifecycle: Int?
  private static var observed: Store?
  private static var subscription: Int?

  static func start() {
    guard lifecycle == nil else { return }
    PageIssuer.consumeLifecycleEvent = { issuer, binding, name, payload in
      guard issuer.store === observed, NativeStoreHandle.ownsWorkspace,
        name == "onCommand", payload["command"]?.string == "escape", zoomShown(binding.tabId) else { return false }
      dismissZoom(binding.tabId, revision: zoomRevision(binding.tabId))
      return true
    }
    PageIssuer.lifecycleEvent = receive
    _ = PageRegistry.shared.observe { event in
      if case .retired(let registration) = event,
        entries[registration.tabID]?.identity.registrationGeneration == registration.registrationGeneration {
        entries[registration.tabID] = nil
        changed(registration.tabID)
      }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { reconcile() }
  }

  static func observe(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    listeners[id] = action
    return id
  }

  static func stopObserving(_ id: UUID) { listeners[id] = nil }

  private static func changed(_ tabId: String) {
    for action in Array(listeners.values) { action() }
    NativePaneOverlays.refreshShowing(tabId, lastWindow: NativeStoreHandle.store?.state.tabs[tabId]?.windowId)
  }

  private static func reconcile() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observed !== store {
      if let observed, let subscription { observed.unsubscribe(subscription) }
      let tabs = Array(entries.keys)
      entries.removeAll()
      observed = store
      applied = nil
      subscription = store?.subscribe { commit in
        let changes = commit.changes
        guard !changes.tabs.isEmpty || !changes.windows.isEmpty || !changes.lists.isEmpty || !changes.settingsChanged.isEmpty
          || !changes.settingsRemoved.isEmpty || changes.fileOwnChanged else { return }
        Task { @MainActor in sync() }
      }
      for tabId in tabs { changed(tabId) }
    }
    sync()
  }

  private struct SyncInputs: Equatable {
    var enabled: Bool
    var engine: String
    var windowOrder: [String]
    var tabs: [String: TabPlacement]
  }

  private struct TabPlacement: Equatable {
    var windowId: String
    var zoom: Double
  }

  private static var applied: SyncInputs?

  private static func sync() {
    guard let store = observed, NativeStoreHandle.store === store, NativeStoreHandle.ownsWorkspace else { return }
    let state = store.state
    let enabled = state.settings["showSelectionSearch"]?.bool ?? true
    let engine = defaultSearchEngine(state.settings).name
    let inputs = SyncInputs(enabled: enabled, engine: engine, windowOrder: state.windowOrder,
      tabs: Dictionary(state.tabs.values.map { ($0.id, TabPlacement(windowId: $0.windowId, zoom: $0.zoom)) }, uniquingKeysWith: { first, _ in first }))
    guard inputs != applied else { return }
    let previousInputs = applied
    applied = inputs
    let previous = popovers.values
    popovers.retainTabs(Set(state.tabs.keys))
    if previous != popovers.values { popoversChanged?(popovers.values) }
    if previousInputs?.engine != engine { SolaraCoreWebView.setSearchEngineName(engine) }
    if previousInputs?.enabled != enabled { SolaraCoreWebView.setSelectionPopoverEnabled(enabled) }
    for action in Array(listeners.values) { action() }
    for windowId in store.state.windowOrder { NativePaneOverlays.refresh(windowId) }
    for tabId in Array(entries.keys) {
      entries[tabId]?.lifecycle.update(enabled: enabled)
      if !enabled { entries[tabId]?.shown = nil; entries[tabId]?.pending = nil; entries[tabId]?.revision += 1 }
      changed(tabId)
    }
  }

  private static func receive(_ issuer: PageIssuer, _ binding: PageHostBinding, _ name: String, _ payload: JSONValue) {
    guard issuer.store === observed, let store = observed, NativeStoreHandle.ownsWorkspace,
      let value = try? JSONSerialization.jsonObject(with: Data(payload.text().utf8)) as? [String: Any] else { return }
    let tabId = binding.tabId
    var entry = entries[tabId].flatMap { $0.identity == binding.identity ? $0 : nil } ?? Entry(identity: binding.identity)
    let was = entry.page.selection
    entry.lifecycle.update(enabled: store.state.settings["showSelectionSearch"]?.bool ?? true)
    _ = entry.page.take(name, value)
    if name == "onCommand", value["command"] as? String == "search", let text = value["text"] as? String {
      entries[tabId] = entry
      search(tabId, text: text, click: value["modifiers"] as? [String: Bool] ?? [:])
      return
    }
    guard entry.page.selection != was || entries[tabId]?.identity != binding.identity else {
      entries[tabId] = entry
      return
    }
    entry.revision += 1
    let revision = entry.revision
    entry.pending = entry.page.selection
    entry.lifecycle.receive(text: entry.pending?.text, page: binding.identity.sessionGeneration, now: ProcessInfo.processInfo.systemUptime)
    if entry.pending == nil { entry.shown = nil }
    entries[tabId] = entry
    changed(tabId)
    guard entry.pending != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + PanePromptSpecs.selectionDelay) {
      guard var current = entries[tabId], current.identity == binding.identity, current.revision == revision,
        issuer.isCurrent(binding), NativeStoreHandle.store === store, NativeStoreHandle.ownsWorkspace else { return }
      if current.lifecycle.shown(page: binding.identity.sessionGeneration, now: ProcessInfo.processInfo.systemUptime) != nil {
        current.shown = current.pending
        entries[tabId] = current
        changed(tabId)
      }
    }
  }

  static func state(_ tabId: String, theme: [String: Any]) -> SelectionBarState? {
    guard let store = observed, NativeStoreHandle.ownsWorkspace, let entry = entries[tabId],
      let selection = entry.shown, let issuer = PageIssuer.shared, let binding = issuer.binding(identity: entry.identity),
      issuer.isCurrent(binding), store.state.tabs[tabId] != nil else { return nil }
    return PanePromptSpecs.selectionBar(selection, zoom: store.state.tabs[tabId]?.zoom ?? 1,
      engine: defaultSearchEngine(store.state.settings).name, dark: theme["dark"] as? Bool ?? false,
      icon: theme["icon"] as? String ?? "", textPrimary: theme["textPrimary"] as? String ?? "")
  }

  static func search(_ tabId: String, text: String? = nil, click: [String: Bool]) {
    guard let store = observed, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      let entry = entries[tabId], let issuer = PageIssuer.shared, let binding = issuer.binding(identity: entry.identity),
      issuer.isCurrent(binding), let tab = store.state.tabs[tabId], let window = store.state.windows[tab.windowId] else { return }
    let query = SelectionLifecycle.query(text ?? entry.shown?.text ?? "")
    guard !query.isEmpty else { return }
    entries[tabId]?.shown = nil
    entries[tabId]?.pending = nil
    entries[tabId]?.page.selection = nil
    entries[tabId]?.revision += 1
    changed(tabId)
    let disposition = SelectionLifecycle.disposition(meta: click["metaKey"] == true, shift: click["shiftKey"] == true,
      alt: click["altKey"] == true, middle: click["middle"] == true)
    let url = searchUrl(defaultSearchEngine(store.state.settings), query)
    let sourceId = store.state.peeks[window.id]?.tabId == tabId ? store.state.peeks[window.id]?.sourceId ?? tabId : tabId
    let before = store.state
    do {
      if disposition == "window" {
        let profile = window.incognito ? window.originalProfileId ?? tab.profileId : tab.profileId
        try store.dispatch(Command("createWindow", [["url": .string(url), "profileId": .string(profile), "incognito": .bool(window.incognito)]]), origin: .native)
      } else if disposition == "split" && !window.isSmall {
        let split = Splits.splitOf(store.state, sourceId)
        let index = split?.tabIds.firstIndex(of: sourceId)
        let next = index.flatMap { index in split.flatMap { index + 1 < $0.tabIds.count ? $0.tabIds[index + 1] : nil } }
        let target = next ?? (split.map { $0.tabIds.count >= Splits.maxPanes } == true ? split?.tabIds.last : nil)
        var options: JSONObject = ["anchorTabId": .string(sourceId), "url": .string(url), "side": "right", "background": true]
        if let target, target != sourceId { options["inPlaceOf"] = .string(target) }
        try store.dispatch(Command("openSplitPane", [.string(window.id), .object(options)]), origin: .native)
      } else {
        try store.dispatch(Command("newTab", [.string(window.id), ["url": .string(url), "openerId": .string(sourceId),
          "profileId": .string(tab.profileId), "background": .bool(window.isSmall || disposition == "background" || tab.profileId != window.profileId)]]), origin: .native)
      }
      NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
      FrameUpdates.flush()
    } catch { NSLog("[selection] search failed: %@", String(describing: error)) }
  }

  static func zoom(_ tabId: String, identity: PageIdentity?, step: Double) {
    guard let value = ZoomLifecycle.step(step), let identity, let issuer = PageIssuer.shared,
      let binding = issuer.binding(identity: identity), binding.tabId == tabId,
      ZoomLifecycle.accepts(page: identity.sessionGeneration, currentPage: issuer.binding(tabId: tabId)?.sessionGeneration, eligible: issuer.isCurrent(binding)),
      NativeStoreHandle.ownsWorkspace else { return }
    issuer.issue(tabId: tabId, identity: binding.identity, command: .zoomStep(value)) { _ in }
  }
}
