import AppKit
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

@MainActor
final class TabPoolHost {
  static let shared = TabPoolHost()

  nonisolated static var available: Bool { NativeSplitChrome.panesEnabled && NativePaneRoots.available && NativeStoreHandle.opened
    && ProcessInfo.processInfo.environment["SOLARA_TAB_POOL"] != "0" }

  var emit: ((String, [String: Any]) -> Void)?
  var onPageGone: ((String) -> Void)?
  var pageEventObservers: [@MainActor (String, String, [String: Any]) -> Void] = []
  var stateObservers: [@MainActor () -> Void] = []
  private var pool: TabViewPool?
  private var listener: Int?
  private var slotObserver: NSObjectProtocol?
  private var overlaysObserver: NSObjectProtocol?
  private var cardPageFollows: [String: (slot: NSView, observer: NSObjectProtocol)] = [:]
  private let commits = TabPoolCommits()
  private var state: BrowserState?
  private var props: [String: [String: Any]] = [:]
  private var pages: [String: PoolPage] = [:]
  private var warm: Set<String> = []
  private var shellWindows: Set<String> = []
  private var wanted: [TabViewWanted] = []
  private var closing: [String: ClosingWindow] = [:]
  private var park = TabViewPark()
  private var making: PoolPageToken?
  private var parkCheckDue: Date?
  private let shellNSWindows = NSMapTable<NSString, NSWindow>.strongToWeakObjects()

  func start() {
    guard pool == nil else { return }
    guard Self.available, let store = NativeStoreHandle.store else { return startWhenSlotsChange() }
    if let slotObserver { NotificationCenter.default.removeObserver(slotObserver) }
    let pool = TabViewPool(make: { [weak self] tabId, windowId in self?.makePage(tabId, windowId) })
    pool.hiddenContainer = { NativeWindowShell.hiddenPages($0) }
    pool.onPlaced = { [weak self] places in self?.emit?("onPlaced", ["places": places]) }
    pool.onReplace = { [weak self] tabId in self?.pages[tabId]?.page.discard() }
    self.pool = pool
    commits.host = self
    let sink = commits
    listener = store.subscribe { commit in sink.receive(commit.state) }
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: TabSlots.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    overlaysObserver = NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: PaneOverlays.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.followCardPages() }
    }
    SolaraCoreWebView.setOwnedTabStillWanted { view in MainActor.assumeIsolated { TabPoolHost.shared.stillWants(view) } }
    receive(store.state)
  }

  private func startWhenSlotsChange() {
    guard slotObserver == nil, NativeSplitChrome.panesEnabled, ProcessInfo.processInfo.environment["SOLARA_TAB_POOL"] != "0" else { return }
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: TabSlots.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.start() }
    }
  }

  func pageView(_ tabId: String) -> NSView? { pages[tabId]?.page.view }

  func windowOf(_ tabId: String) -> String? { state?.tabs[tabId]?.windowId }

  func devPageEvent(_ tabId: String, _ name: String, _ payload: [String: Any]) -> Bool {
    #if DEBUG
      guard pages[tabId] != nil else { return false }
      emit?("onPageEvent", ["tabId": tabId, "name": name, "payload": payload])
      pageEventObservers.forEach { $0(tabId, name, payload) }
      return true
    #else
      return false
    #endif
  }

  func setPageProps(_ tabId: String, _ changed: [String: Any]) {
    props[tabId, default: [:]].merge(changed) { _, new in new }
    pages[tabId]?.page.apply(changed)
  }

  func receive(_ next: BrowserState) {
    state = next
    for tabId in props.keys where next.tabs[tabId] == nil { props[tabId] = nil }
    refresh()
    stateObservers.forEach { $0() }
  }

  private func refresh() {
    guard let pool, let state else { return }
    shellWindows.formUnion(NativeWindowShell.activeWindowIds)
    for windowId in shellWindows {
      if let window = NativeWindowShell.host(windowId)?.shell.window { shellNSWindows.setObject(window, forKey: windowId as NSString) }
    }
    for windowId in shellWindows where state.windows[windowId] == nil { holdUntilClosed(windowId, in: state) }
    shellWindows = shellWindows.filter { state.windows[$0] != nil }
    for key in shellNSWindows.keyEnumerator().allObjects.compactMap({ $0 as? String }) where !shellWindows.contains(key) {
      shellNSWindows.removeObject(forKey: key as NSString)
    }
    let fresh = TabViewWanted.from(state, windows: shellWindows, isInternal: Self.isInternal, frozen: { _ in false })
    let freshIds = Set(fresh.map(\.tabId))
    let absentIds = Set(closing.values.flatMap { $0.restoration.absentTabIds })
    let presentIds = Set(absentIds.filter { state.tabs[$0] != nil })
    let unloadedIds = Set(presentIds.filter { state.tabs[$0]?.unloaded == true })
    for (windowId, hold) in closing {
      let restored = hold.restoration.restored(presentTabIds: presentIds, freshTabIds: freshIds, unloadedTabIds: unloadedIds)
      if state.windows[windowId] != nil || hold.window == nil || restored { end(windowId, hold) }
    }
    let held = Set(closing.values.flatMap { $0.tabs.map(\.tabId) })
    let parked = parkAwaitingShell(state, freshIds: freshIds, held: held)
    wanted = fresh + parked + closing.sorted { $0.key < $1.key }.flatMap { $0.value.tabs.filter { !freshIds.contains($0.tabId) } }
    warm = Set(fresh.filter(\.warm).map(\.tabId))
    for page in pages.values { page.setWarm(warm.contains(page.tabId), neighbour: Self.neighbour(state, page.tabId)) }
    pool.update(wanted.map { identified($0, in: state) })
    followCardPages()
  }

  private func parkAwaitingShell(_ state: BrowserState, freshIds: Set<String>, held: Set<String>) -> [TabViewWanted] {
    let awaiting = Set(state.windows.keys).subtracting(shellWindows).filter { NativeWindowShell.enabled && NativeWindowShell.isBrowserWindow($0) }
    let moving = TabViewWanted.from(state, windows: awaiting, isInternal: Self.isInternal, frozen: { _ in false })
      .filter { pages[$0.tabId] != nil && !freshIds.contains($0.tabId) && !held.contains($0.tabId) }
    let now = Date()
    let parked = park.park(moving, now: now)
    if let due = park.nextExpiry(after: now), parkCheckDue.map({ due < $0 }) ?? true {
      parkCheckDue = due
      DispatchQueue.main.asyncAfter(deadline: .now() + due.timeIntervalSince(now) + 0.05) { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.parkCheckDue == due { self.parkCheckDue = nil }
          self.refresh()
        }
      }
    }
    return parked
  }

  private func holdUntilClosed(_ windowId: String, in state: BrowserState) {
    guard closing[windowId] == nil else { return }
    let tabs = wanted.filter { $0.windowId == windowId }
    let window = shellNSWindows.object(forKey: windowId as NSString) ?? tabs.lazy.compactMap({ self.pages[$0.tabId]?.page.view.window }).first
    guard let window else { return }
    let hold = ClosingWindow(tabs: tabs.map { TabViewWanted(tabId: $0.tabId, windowId: $0.windowId, shown: $0.shown) },
      restoration: TabViewCloseHold(tabIds: Set(tabs.map(\.tabId)), presentTabIds: Set(state.tabs.keys)), window: window)
    hold.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) {
      [weak self, weak hold] _ in
      MainActor.assumeIsolated {
        guard let self, let hold else { return }
        self.release(windowId, hold)
      }
    }
    closing[windowId] = hold
  }

  private func release(_ windowId: String, _ hold: ClosingWindow) {
    guard closing[windowId] === hold else { return }
    end(windowId, hold)
    refresh()
  }

  private func end(_ windowId: String, _ hold: ClosingWindow) {
    closing[windowId] = nil
    if let observer = hold.observer { NotificationCenter.default.removeObserver(observer) }
    hold.observer = nil
  }

  func stillWants(_ view: NSView) -> Bool {
    guard let tabId = pages.first(where: { $0.value.page.view === view })?.key, let store = NativeStoreHandle.store else { return true }
    let state = store.state
    guard let tab = state.tabs[tabId] else { return false }
    return state.windows[tab.windowId] != nil
  }

  func devPageIds() -> [String] { pages.keys.sorted() }

  func livePages() -> [[String: Any]] {
    pages.keys.sorted().compactMap { tabId in
      guard let entry = pages[tabId] else { return nil }
      return ["tabId": tabId, "engine": entry.page.spec.engine, "ready": entry.token.ready ?? NSNull(), "navigation": entry.token.navigation ?? NSNull()]
    }
  }

  func devClosingWindows() -> [String: Int] {
    closing.mapValues { $0.window?.windowNumber ?? -1 }
  }

  private func followCardPages() {
    guard let state else { return }
    var seen: Set<String> = []
    for windowId in NativeWindowShell.activeWindowIds {
      guard let shell = NativeWindowShell.host(windowId)?.shell, let window = state.windows[windowId] else { continue }
      seen.insert(windowId)
      let active = window.activeTabIds[window.profileId]
      let slot = active.flatMap { PaneOverlays.shared.container(windowId: windowId, tabId: $0, layer: .native)?.superview }
      if cardPageFollows[windowId]?.slot !== slot {
        if let old = cardPageFollows.removeValue(forKey: windowId) { NotificationCenter.default.removeObserver(old.observer) }
        if let slot {
          slot.postsFrameChangedNotifications = true
          let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: slot, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.followCardPages() }
          }
          cardPageFollows[windowId] = (slot, observer)
        }
      }
      shell.cardPageFrame = slot.flatMap { $0.superview == nil ? nil : $0.convert($0.bounds, to: shell.card) }
    }
    for (windowId, follow) in cardPageFollows where !seen.contains(windowId) {
      NotificationCenter.default.removeObserver(follow.observer)
      cardPageFollows[windowId] = nil
    }
  }

  private func identified(_ entry: TabViewWanted, in state: BrowserState) -> TabViewWanted {
    guard let store = NativeStoreHandle.store, let tab = state.tabs[entry.tabId] else { return entry }
    var entry = entry
    entry.identity = "\(store.pageEngine(tab.id, in: state))|\(state.engineProfile(tab.profileId))"
    return entry
  }

  private func makePage(_ tabId: String, _ windowId: String) -> TabPoolPage? {
    guard let state, let store = NativeStoreHandle.store, let tab = state.tabs[tabId] else { return nil }
    let peek = state.peeks[windowId]
    let url = tab.navigation?.url ?? (tab.adoptId != nil ? tab.url : nil)
    let spec = PooledPageSpec(
      engine: store.pageEngine(tabId, in: state), profile: state.engineProfile(tab.profileId), url: url.map(toEngineUrl),
      adoptId: tab.adoptId, temporarySource: peek?.tabId == tabId ? peek?.sourceId : nil)
    let token = PoolPageToken()
    making = token
    defer { if making === token { making = nil } }
    let page = PooledPage(tabId: tabId, spec: spec) { [weak self] name, payload in
      guard let self else { return }
      let current = self.pages[tabId]
      guard current?.token === token || self.making === token else { return }
      token.note(name, payload)
      self.emit?("onPageEvent", ["tabId": tabId, "name": name, "payload": payload])
      self.pageEventObservers.forEach { $0(tabId, name, payload) }
    }
    if let given = props[tabId] { page.apply(given) }
    let entry = PoolPage(page: page, token: token) { [weak self] in
      guard let self, self.pages[tabId]?.page === page else { return }
      self.pages[tabId] = nil
      self.onPageGone?(tabId)
      self.emit?("onPageEvent", ["tabId": tabId, "name": "onPageGone", "payload": [String: Any]()])
      self.pageEventObservers.forEach { $0(tabId, "onPageGone", [:]) }
    }
    entry.setWarm(warm.contains(tabId), neighbour: Self.neighbour(state, tabId))
    pages[tabId] = entry
    let seq = tab.adoptId == nil ? tab.navigation?.seq ?? -1 : -1
    emit?("onPageEvent", ["tabId": tabId, "name": "onPageCreated", "payload": ["engine": spec.engine, "seq": seq, "url": spec.url ?? ""]])
    pageEventObservers.forEach { $0(tabId, "onPageCreated", ["engine": spec.engine]) }
    if let ready = token.ready { emit?("onPageEvent", ["tabId": tabId, "name": "onReady", "payload": ready]) }
    return entry
  }

  static func neighbour(_ state: BrowserState, _ tabId: String) -> Bool {
    guard let tab = state.tabs[tabId], let window = state.windows[tab.windowId] else { return false }
    return window.profileId != tab.profileId
  }

  static func isInternal(_ tab: Tab) -> Bool {
    let url = tab.navigation?.url ?? tab.url
    guard let colon = url.range(of: "://") else { return false }
    let scheme = String(url[..<colon.lowerBound])
    guard isAppScheme(scheme) else { return false }
    let rest = url[colon.upperBound...]
    let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
    return ["history", "bookmarks", "downloads"].contains(host)
  }
}

@MainActor
final class ClosingWindow {
  let tabs: [TabViewWanted]
  let restoration: TabViewCloseHold
  weak var window: NSWindow?
  var observer: NSObjectProtocol?

  init(tabs: [TabViewWanted], restoration: TabViewCloseHold, window: NSWindow) {
    self.tabs = tabs
    self.restoration = restoration
    self.window = window
  }
}

@MainActor
final class PoolPageToken {
  private(set) var ready: [String: Any]?
  private(set) var navigation: [String: Any]?

  func note(_ name: String, _ payload: [String: Any]) {
    if name == "onReady" { ready = payload } else if name == "onNavigationChange" { navigation = payload }
  }
}

@MainActor
final class PoolPage: TabPoolPage {
  let page: PooledPage
  let token: PoolPageToken
  var tabId: String { page.tabId }
  private var shown = false
  private var warm = false
  private var neighbour = false
  private let onRetire: () -> Void

  init(page: PooledPage, token: PoolPageToken, onRetire: @escaping () -> Void) {
    self.page = page
    self.token = token
    self.onRetire = onRetire
  }

  var view: NSView { page.view }

  func setShown(_ shown: Bool) {
    self.shown = shown
    apply()
  }

  func setWarm(_ warm: Bool, neighbour: Bool) {
    self.warm = warm
    self.neighbour = warm && neighbour
    apply()
  }

  func focus() {
    page.focus()
  }

  func retire() {
    page.retire()
    onRetire()
  }

  private func apply() {
    page.setShown(shown, warm: warm && !shown, neighbour: neighbour && !shown)
  }
}

final class TabPoolCommits: @unchecked Sendable {
  weak var host: TabPoolHost?
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false

  func receive(_ state: BrowserState) {
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let next = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let next else { return }
      MainActor.assumeIsolated { host?.receive(next) }
    }
  }
}

#if SOLARA_PROBES
@MainActor
public enum TabPoolRead {
  public static var available: Bool { TabPoolHost.available }

  public static func live(_ tabId: String) -> Bool? {
    guard TabPoolHost.available else { return nil }
    return TabPoolHost.shared.pageView(tabId) != nil
  }
}
#endif
