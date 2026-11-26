import AppKit
import Foundation
import os
import SolaraCore
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeExtensionCatalog {
  static var catalog = ExtensionCatalogLifecycle()
  static var actions: [Int: JSONValue] = [:]
  static var emit: (() -> Void)?
  private static var lifecycle: Int?
  private static var observed: Store?
  private static var subscription: Int?
  private static var timer: Timer?
  private static var flush: DispatchWorkItem?
  private static var observers: [NSObjectProtocol] = []
  private static var actionRunning = false
  private static var actionAgain = false
  private static var pendingAll = false
  private static var pendingProfiles: Set<String> = []
  private static var epoch = 0
  private static var waiters: [String: [() -> Void]] = [:]
  private static var nextWaiters: [String: [() -> Void]] = [:]
  static var legacyPanels: [String: String] = [:]
  static var legacyPopup: String?
  private static var actionTabs: [Int: String] = [:]
  private static var published: (lists: JSONValue, states: JSONValue)?


  static var current: Bool { NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === observed && observed != nil }
  static var active: Bool { NSApp.isActive }

  static func start() {
    guard lifecycle == nil else { return }
    for topic in ["extensions.changed", "extensions.action"] {
      SolaraCoreEngineBridge.observe(topic) { payload in
        let profile = payload["profile"] as? String ?? ""
        let id = payload["id"] as? String ?? ""
        let kind = payload["kind"] as? String ?? "action"
        DispatchQueue.main.async { MainActor.assumeIsolated {
          guard current else { return }
          if topic == "extensions.changed" { refresh(profile, afterChange: true); return }
          if kind == "registry" { catalog.changed(profile, registry: true) }
          else if showsAction(profile, id: id) { catalog.changed(profile, registry: false) }
          scheduleFlush()
        } }
      }
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { scheduleFlush() }
    })
    observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("SolaraExtensionsChanged"), object: nil, queue: .main) { note in
      let profile = note.userInfo?["profile"] as? String ?? ""
      MainActor.assumeIsolated { if current { refresh(profile) } }
    })
    SettingsJS.shared.onConnect { publish(force: true) }
    lifecycle = NativeStoreHandle.subscribeLifecycle { reconcile() }
  }

  private static func reconcile() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observed !== store {
      if let subscription { observed?.unsubscribe(subscription) }
      subscription = nil
      observed = store
      epoch += 1
      catalog.invalidate()
      let cancelled = Array(waiters.values).flatMap { $0 } + Array(nextWaiters.values).flatMap { $0 }
      waiters.removeAll()
      nextWaiters.removeAll()
      for completion in cancelled { completion() }
      actions.removeAll()
      actionTabs.removeAll()
      timer?.invalidate()
      timer = nil
      flush?.cancel()
      flush = nil
      if let store {
        let focus = OSAllocatedUnfairLock<String?>(initialState: store.state.ui.focusedWindowId)
        let queued = OSAllocatedUnfairLock(initialState: false)
        subscription = store.subscribe { commit in
          let focused = commit.state.ui.focusedWindowId
          let focusMoved = focus.withLock { last in
            defer { last = focused }
            return last != focused
          }
          guard focusMoved || affectsActions(commit) else { return }
          let first = queued.withLock { pending in
            defer { pending = true }
            return !pending
          }
          guard first else { return }
          DispatchQueue.main.async { MainActor.assumeIsolated {
            queued.withLock { $0 = false }
            reconcile()
          } }
        }
      }
    }
    guard let store else { publish(); return }
    for profile in catalog.loadProfiles(store.state.windowOrder.map { profile($0) }) {
      refresh(profile)
      watch(profile)
    }
    refreshActions()
    publish()
  }

  private nonisolated static func affectsActions(_ commit: Commit) -> Bool {
    let changes = commit.changes
    if !changes.windows.isEmpty || !changes.tabs.removed.isEmpty || changes.tabs.reordered || !changes.lists.isEmpty
      || !changes.live.removed.isEmpty { return true }
    let state = commit.state
    guard !changes.tabs.upserted.isEmpty || !changes.live.upserted.isEmpty else { return false }
    let upserted = Set(changes.tabs.upserted).union(changes.live.upserted)
    return state.windowOrder.contains { window in state.activeTabId(window).map(upserted.contains) == true }
  }

  static func page(_ tab: String) -> SolaraCoreWebView? {
    guard current, let issuer = PageIssuer.shared, let binding = issuer.binding(tabId: tab),
      issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return nil }
    let view = binding.host == .pooled ? TabPoolHost.shared.pageView(tab) : binding.owner as? NSView
    guard let page = NativeOmniboxExtensionActions.page(in: view), page.transferKey == tab else { return nil }
    return page
  }

  static func popupId(_ window: String) -> String? {
    guard let popup = NativeExtensionActionPopup.current, popup.intent.windowId == window else { return nil }
    return popup.intent.extensionId
  }

  static func profile(_ windowId: String) -> String {
    guard let state = observed?.state else { return "" }
    return OmniboxCommandSources.extensionProfile(state: state, windowId: windowId)
  }

  static func visible(_ windowId: String) -> [JSONObject] {
    catalog.visible(profile(windowId), privateWindow: observed?.state.windows[windowId]?.incognito == true)
  }

  static func refreshAndWait(_ profile: String, afterChange: Bool) async -> String {
    await withCheckedContinuation { continuation in
      refresh(profile, afterChange: afterChange) { continuation.resume() }
    }
    return String(data: (try? JSONSerialization.data(withJSONObject: (catalog.lists[profile] ?? []).map { JSONValue.object($0).foundation })) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
  }

  static func refresh(_ profile: String, afterChange: Bool = false, completion: (() -> Void)? = nil) {
    guard current else { completion?(); return }
    guard let request = catalog.begin(profile, afterChange: afterChange) else {
      if let completion {
        if afterChange { nextWaiters[profile, default: []].append(completion) }
        else { waiters[profile, default: []].append(completion) }
      }
      return
    }
    if let completion { waiters[profile, default: []].append(completion) }
    let generation = epoch
    Task { @MainActor in
      let rows: [JSONObject]? = await EngineCalls.result({ done in
        SolaraCoreServices.listExtensions(profile: profile) { done($0) }
      }) { result in
        guard result["error"] == nil, let rows = result["extensions"] as? [[String: Any]],
          let data = try? JSONSerialization.data(withJSONObject: rows), let parsed = try? JSONValue.parse(data) else { return nil }
        return parsed.array?.compactMap(\.object)
      }
      guard current, generation == epoch else { return }
      let again = catalog.finish(profile, request: request, rows: rows)
      publish()
      refreshActions()
      let completed = waiters.removeValue(forKey: profile) ?? []
      waiters[profile] = nextWaiters.removeValue(forKey: profile)
      if again { refresh(profile) }
      for completion in completed { completion() }
    }
  }

  private static func watch(_ profile: String) {
    if ExtensionCatalogLifecycle.forcePolling(ProcessInfo.processInfo.environment["SOLARA_EXTENSION_ACTION_POLL"]) { poll(); return }
    let generation = epoch
    SolaraCoreEngineBridge.call("ac_extensions_watch_actions", profile: profile, args: nil) { json in
      let failed = (try? JSONValue.parse(Data(json.utf8)))?["error"] != nil
      DispatchQueue.main.async { MainActor.assumeIsolated { if current, generation == epoch, failed { poll() } } }
    }
  }

  private static func poll() {
    guard timer == nil else { return }
    timer = Timer(timeInterval: ExtensionCatalogLifecycle.pollInterval, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard current, active else { return }
        refreshActions()
        SettingsJS.shared.fire("extensions.syncPanels", NSNull())
      }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  private static func showsAction(_ profile: String, id: String) -> Bool {
    guard let state = observed?.state else { return false }
    return state.windowOrder.contains { window in
      guard self.profile(window) == profile else { return false }
      return visible(window).contains { $0["id"]?.string == id && ($0["pinned"]?.truthy == true || legacyPopup == id) }
        || popupId(window) == id
        || NativeExtensionSidePanel.extensionId(windowId: window) == id || legacyPanels[window] == id
    }
  }

  private static func scheduleFlush() {
    guard current, active, flush == nil else { return }
    let work = DispatchWorkItem { MainActor.assumeIsolated {
      flush = nil
      guard current, let batch = catalog.flush(active: active) else { return }
      for profile in batch.lists { refresh(profile, afterChange: true) }
      if !batch.actions.isEmpty {
        refreshActions(batch.actions)
        SettingsJS.shared.fire("extensions.syncPanels", Array(batch.actions))
      }
    } }
    flush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + ExtensionCatalogLifecycle.coalesceDelay, execute: work)
  }

  static func refreshActions(_ profiles: Set<String>? = nil) {
    if let profiles { pendingProfiles.formUnion(profiles) } else { pendingAll = true }
    if actionRunning { actionAgain = true; return }
    guard current, let store = observed else { return }
    actionRunning = true
    repeat {
      actionAgain = false
      let only = pendingAll ? nil : pendingProfiles
      pendingAll = false
      pendingProfiles.removeAll()
      for window in store.state.windowOrder where only == nil || only!.contains(profile(window)) {
        let popup = popupId(window)
        let ids = visible(window).filter { $0["hasAction"] != .bool(false) && ($0["pinned"]?.truthy == true || $0["id"]?.string == popup || $0["id"]?.string == legacyPopup) }.compactMap { $0["id"]?.string }
        guard let tab = store.state.activeTabId(window), let web = page(tab), web.browserId != 0, !ids.isEmpty else { continue }
        let raw = SolaraCoreHost.actionStates(browserId: web.browserId, extensions: ids)
        if raw["error"] == nil, let data = try? JSONSerialization.data(withJSONObject: raw), let value = try? JSONValue.parse(data) {
          actions[Int(web.browserId)] = value
          actionTabs[Int(web.browserId)] = tab
        }
      }
    } while actionAgain
    actionRunning = false
    for (browserId, tab) in actionTabs where store.state.tabs[tab] == nil || page(tab).map({ Int($0.browserId) }) != browserId {
      actions[browserId] = nil
      actionTabs[browserId] = nil
    }
    publish()
  }

  static func publish(force: Bool = false) {
    let lists = JSONValue.object(JSONObject(catalog.lists.map { ($0.key, .array($0.value.map(JSONValue.object))) }))
    let states = JSONValue.object(JSONObject(actions.map { (String($0.key), $0.value) }))
    if !force, let published, published.lists == lists, published.states == states { return }
    published = (lists, states)
    emit?()
    guard SettingsJS.shared.connected else { return }
    SettingsJS.shared.fire("extensions.catalog", lists.foundation, states.foundation)
  }
}
