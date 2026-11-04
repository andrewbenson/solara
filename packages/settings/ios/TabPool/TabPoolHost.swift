import AppKit
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class TabPoolHost {
  static let shared = TabPoolHost()

  nonisolated static var available: Bool { NativeSplitChrome.panesEnabled && NativePaneRoots.available && NativeStoreHandle.opened && NativeStoreHandle.ownedWorkspaceAtLaunch
    && ProcessInfo.processInfo.environment["SOLARA_TAB_POOL"] != "0" }

  var emit: (@MainActor (String, [String: Any]) -> Void)?
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
  private var following: Set<String> = []
  private var scheduledFollows: Set<String> = []
  private let shellNSWindows = NSMapTable<NSString, NSWindow>.strongToWeakObjects()

  func start() {
    guard pool == nil else { return }
    guard Self.available, let store = NativeStoreHandle.store else { return startWhenSlotsChange() }
    if let slotObserver { NotificationCenter.default.removeObserver(slotObserver) }
    let pool = TabViewPool(make: { [weak self] tabId, windowId in self?.makePage(tabId, windowId) })
    pool.hiddenContainer = { NativeWindowShell.hiddenPages($0) }
    pool.onPlaced = { [weak self] places in
      PageIssuer.shared?.afterIngress { [weak self] in self?.emit?("onPlaced", ["places": places]) }
    }
    pool.onReplace = { [weak self] tabId in
      guard let entry = self?.pages[tabId] else { return }
      if let binding = entry.token.binding { PageIssuer.shared?.retire(binding) }
      entry.page.discard()
    }
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

  func pageView(_ tabId: String) -> NSView? {
    guard let issuer = PageIssuer.shared else { return nil }
    return issuer.store.sequence {
      guard let entry = pages[tabId], let binding = entry.token.binding,
        issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return nil }
      return entry.page.view
    }
  }

  func pageCall(_ tabId: String, _ method: String, _ args: [Any], registrationGeneration: Double?, resolve: @escaping PageCalls.Resolve, reject: @escaping PageCalls.Reject) {
    guard let issuer = PageIssuer.shared else { return reject("ERR_NO_PAGE", "No native page issuer") }
    issuer.store.sequence {
      guard let binding = pages[tabId]?.token.binding else { return issuer.afterIngress { reject("ERR_NO_PAGE", "No pooled page for \(tabId)") } }
      guard let registrationGeneration, registrationGeneration.isFinite, registrationGeneration > 0,
        registrationGeneration <= 9_007_199_254_740_991, registrationGeneration.rounded(.towardZero) == registrationGeneration,
        binding.registrationGeneration == UInt64(registrationGeneration), let registration = binding.registration else {
        return issuer.afterIngress { reject("ERR_NO_PAGE", "The pooled page registration is no longer current") }
      }
      do {
        let command = try PageCommand.decode(method: method, args: args.map { try PageValue(any: $0) })
        issuer.registry.call(registration, command: command) { result in
          switch result {
          case .success(let value): resolve(value == .null ? nil : value.foundation)
          case .failure(let error): reject(error.code, error.message)
          }
        }
      } catch let error as PageRegistryError {
        issuer.afterIngress { reject(error.code, error.message) }
      } catch { issuer.afterIngress { reject("ERR_PAGE_VALUE", "Invalid page arguments") } }
    }
  }

  func windowOf(_ tabId: String) -> String? { NativeStoreHandle.store?.state.tabs[tabId]?.windowId }

  func claimFocusPage(_ generation: Int, tabId: String) -> Bool {
    guard let issuer = PageIssuer.shared else { return false }
    return issuer.store.sequence {
      guard let page = pageView(tabId) else { return false }
      FocusMoves.claim(generation, destination: page)
      return true
    }
  }

  func devPageEvent(_ tabId: String, _ name: String, _ payload: [String: Any]) -> Bool {
    #if DEBUG
      guard let entry = pages[tabId] else { return false }
      return reportEvent(tabId, token: entry.token, name: name, payload: payload)
    #else
      return false
    #endif
  }

  func setPageProps(_ tabId: String, _ changed: [String: Any]) {
    props[tabId, default: [:]].merge(changed) { _, new in new }
    guard let issuer = PageIssuer.shared else { return }
    issuer.store.sequence {
      guard let entry = pages[tabId], let binding = entry.token.binding,
        issuer.ensurePageEstablished(binding) else { return }
      let wasShowingNewTab = binding.context.newTabShownUrl != nil
      if let value = cachedPageProps(tabId), let context = PageHostContext(json: value) {
        _ = issuer.updateContext(binding, context: context)
      }
      if (binding.context.newTabShownUrl != nil) != wasShowingNewTab { refresh() }
      guard issuer.isCurrent(binding) else { return }
      entry.page.apply(changed)
      follow(entry)
    }
  }

  private func newTabShown(_ tabId: String) -> Bool {
    pages[tabId]?.token.binding?.context.newTabShownUrl != nil
  }

  func receive(_ next: BrowserState) {
    state = next
    for tabId in props.keys where next.tabs[tabId] == nil { props[tabId] = nil }
    refresh()
    stateObservers.forEach { $0() }
  }

  private func refresh() {
    guard let store = NativeStoreHandle.store else { return }
    store.sequence { refreshInScope(store.state) }
  }

  private func refreshInScope(_ state: BrowserState) {
    guard let pool else { return }
    self.state = state
    shellWindows.formUnion(NativeWindowShell.activeWindowIds)
    for windowId in shellWindows {
      if let window = NativeWindowShell.host(windowId)?.shell.window { shellNSWindows.setObject(window, forKey: windowId as NSString) }
    }
    for windowId in shellWindows where state.windows[windowId] == nil { holdUntilClosed(windowId, in: state) }
    shellWindows = shellWindows.filter { state.windows[$0] != nil }
    for key in shellNSWindows.keyEnumerator().allObjects.compactMap({ $0 as? String }) where !shellWindows.contains(key) {
      shellNSWindows.removeObject(forKey: key as NSString)
    }
    let fresh = TabViewWanted.from(state, windows: shellWindows, isInternal: Self.isInternal, frozen: { _ in false }, newTabShown: newTabShown)
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
    for entry in pages.values {
      if let binding = entry.token.binding { _ = PageIssuer.shared?.ensurePageEstablished(binding) }
      follow(entry)
    }
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

  func devPageIds() -> [String] { livePages().compactMap { $0["tabId"] as? String } }

  func livePages() -> [[String: Any]] {
    guard let issuer = PageIssuer.shared else { return [] }
    return issuer.store.sequence {
      pages.keys.sorted().compactMap { tabId in
        guard let entry = pages[tabId], let binding = entry.token.binding,
          issuer.ensurePageEstablished(binding), issuer.isCurrent(binding),
          let facts = issuer.store.pageFacts(tabId) else { return nil }
        let ready: Any
        if let value = facts.ready {
          var result: [String: Any] = ["browserId": value.browserId]
          if let tabId = value.tabId { result["tabId"] = tabId }
          ready = result
        } else { ready = NSNull() }
        return ["tabId": tabId, "engine": entry.page.spec.engine, "ready": ready,
          "navigation": PageValue(json: binding.navigation ?? .null).foundation, "generation": binding.sessionGeneration,
          "sessionGeneration": binding.sessionGeneration, "registrationGeneration": binding.registrationGeneration,
          "contextRevision": binding.context.contextRevision]
      }
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
    guard let issuer = PageIssuer.shared else { return nil }
    return issuer.store.sequence {
      let state = issuer.store.state
      guard let tab = state.tabs[tabId], tab.unloaded != true, (tab.pageIn ?? "").isEmpty,
        state.windows[tab.windowId] != nil else { return nil }
      let peek = state.peeks[windowId]
      let url = tab.navigation?.url ?? (tab.adoptId != nil ? tab.url : nil)
      let spec = PooledPageSpec(
        engine: issuer.store.pageEngine(tabId, in: state), profile: state.engineProfile(tab.profileId), url: url.map(toEngineUrl),
        adoptId: tab.adoptId, temporarySource: peek?.tabId == tabId ? peek?.sourceId : nil)
      let token = PoolPageToken()
      token.execution = PageExecutionMemory(initial: Self.navigation(tab.navigation))
      let context = PageHostContext.initial(navigationSeq: tab.navigation.flatMap { Int(exactly: $0.seq) },
        wasNewTab: tab.url.isEmpty, cached: cachedPageProps(tabId))
      guard let engine = PageEngine(rawValue: spec.engine),
        let binding = issuer.attach(tabId: tabId, engine: engine, host: .pooled, owner: token, context: context,
          onCreated: { [weak self] binding, reestablished in
            guard let self else { return }
            var payload: [String: Any] = ["engine": binding.engine.rawValue, "generation": binding.sessionGeneration,
              "reestablished": reestablished, "seq": binding.executedNavigationSeq ?? -1, "url": spec.url ?? ""]
            payload["tabId"] = tabId
            self.emitEvent(binding, name: "onPageCreated", payload: payload)
          }, onClearNewTabShown: { [weak self] binding, consumed in
            self?.refresh()
            self?.emitEvent(binding, name: "onPageIssue", payload: ["clearNewTabShown": true,
              "contextRevision": consumed.contextRevision,
              "navigation": PageValue(json: consumed.json["navigation"] ?? .null).foundation])
          }, onNeedsFollow: { [weak self] _ in self?.scheduleFollow(tabId) },
          perform: { [weak token] command, finish in
            guard let token, let page = token.page else { return finish(.failure(.noPage(tabId))) }
            if case .loadUrl(let url, let userInitiated) = command {
              let current = token.binding.flatMap { binding in
                (try? issuer.store.pageHostSnapshotInScope(tabId, generation: binding.sessionGeneration))?.state.tabs[tabId]?.navigation
              }
              token.execution.stage(navigation: Self.navigation(current), url: toAppUrl(url), userInitiated: userInitiated)
            }
            var engineArguments = command.arguments.map(\.foundation)
            if case .loadUrl(let url, _) = command { engineArguments[0] = toEngineUrl(url) }
            defer { token.execution.finishStaging() }
            PageCalls.run(page.view, command.method, engineArguments, resolve: { value in
              do { finish(.success(try PageValue(any: value))) }
              catch { finish(.failure(.invalidValue)) }
            }, reject: { code, message in finish(.failure(.failed("\(code): \(message)"))) })
          }) else { return nil }
      token.binding = binding
      making = token
      defer { if making === token { making = nil } }
      let page = PooledPage(tabId: tabId, spec: spec) { [weak self, weak token] name, payload in
        guard let self, let token else { return }
        _ = self.reportEvent(tabId, token: token, name: name, payload: payload)
      }
      token.page = page
      if let given = props[tabId] { page.apply(given) }
      let entry = PoolPage(page: page, token: token) { [weak self, weak token] in
        guard let token else { return }
        if let binding = token.binding { issuer.retire(binding) }
        guard let self, self.pages[tabId]?.token === token else { return }
        self.pages[tabId] = nil
        issuer.afterIngress { [weak self] in
          self?.emitEvent(binding, name: "onPageGone", payload: [:])
        }
      }
      entry.setWarm(warm.contains(tabId), neighbour: Self.neighbour(state, tabId))
      pages[tabId] = entry
      follow(entry)
      return entry
    }
  }

  @discardableResult
  private func reportEvent(_ tabId: String, token: PoolPageToken, name: String, payload: [String: Any]) -> Bool {
    guard let issuer = PageIssuer.shared, let binding = token.binding else { return false }
    return issuer.store.sequence {
      guard pages[tabId]?.token === token || making === token else { return false }
      if issuer.store.state.tabs[tabId] == nil {
        guard PageNativeReport.names.contains(name),
          let data = try? JSONSerialization.data(withJSONObject: payload), let value = try? JSONValue.parse(data),
          var report = PageNativeReport.report(name: name, payload: value)?.object else { return false }
        report["generation"] = .string(binding.sessionGeneration)
        issuer.store.enqueuePageReport(id: tabId, report: .object(report))
        issuer.store.sequence {}
        return true
      }
      guard issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return false }
      if name == "onPagePhysical" {
        guard let page = payload["page"] as? NSView else { return false }
        issuer.transferExecution(from: page, to: binding)
        issuer.associateNativePage(binding, page: page)
        return true
      }
      if name == "onPageConstructorCaptured" {
        guard let rawURL = payload["url"] as? String else { return false }
        token.execution.constructorCaptured(url: toAppUrl(rawURL))
        return true
      }
      if name == "onPageRequestAccepted" {
        guard let rawURL = payload["url"] as? String else { return false }
        token.execution.accepted(url: toAppUrl(rawURL))
        return true
      }
      if name == "onPageExecution" {
        guard let rawURL = payload["url"] as? String else { return false }
        issuer.noteExecuted(binding, navigationSeq: token.execution.executed(url: toAppUrl(rawURL),
          constructor: payload["constructor"] as? Bool == true))
        return true
      }
      if PageNativeReport.names.contains(name) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let value = try? JSONValue.parse(data),
          let report = PageNativeReport.report(name: name, payload: value),
          issuer.report(binding, report: report) else { return false }
      }
      issuer.afterIngress { [weak self] in self?.emitEvent(binding, name: name, payload: payload) }
      return true
    }
  }

  private func emitEvent(_ binding: PageHostBinding, name: String, payload: [String: Any]) {
    let envelope: [String: Any] = ["tabId": binding.tabId, "name": name, "payload": payload,
      "generation": binding.sessionGeneration, "sessionGeneration": binding.sessionGeneration,
      "registrationGeneration": binding.registrationGeneration, "contextRevision": binding.context.contextRevision, "factsOwner": "native", "navigationOwner": "native"]
    emit?("onPageEvent", envelope)
    pageEventObservers.forEach { $0(binding.tabId, name, payload) }
  }

  private func follow(_ entry: PoolPage) {
    guard let issuer = PageIssuer.shared, let binding = entry.token.binding,
      !following.contains(entry.tabId), !closing.values.contains(where: { $0.tabs.contains { $0.tabId == entry.tabId } }) else { return }
    following.insert(entry.tabId)
    defer { following.remove(entry.tabId) }
    _ = issuer.follow(binding)
  }

  private func scheduleFollow(_ tabId: String) {
    guard scheduledFollows.insert(tabId).inserted else { return }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.scheduledFollows.remove(tabId)
        if let entry = self.pages[tabId] { self.follow(entry) }
      }
    }
  }

  private static func navigation(_ value: SolaraModel.Navigation?) -> TabNavigationRequest? {
    guard let value, let sequence = Int(exactly: value.seq) else { return nil }
    return TabNavigationRequest(seq: sequence, url: toAppUrl(value.url), userInitiated: value.userInitiated ?? false)
  }

  private func cachedPageProps(_ tabId: String) -> JSONValue? {
    guard let props = props[tabId], let data = try? JSONSerialization.data(withJSONObject: props) else { return nil }
    return try? JSONValue.parse(data)
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
  var binding: PageHostBinding?
  var execution = PageExecutionMemory(initial: nil)
  weak var page: PooledPage?
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
    guard let issuer = PageIssuer.shared, let binding = token.binding else { return }
    issuer.issue(tabId: tabId, identity: binding.identity, command: .focus) { _ in }
  }

  func retire() {
    onRetire()
    page.retire()
  }

  private func apply() {
    guard let issuer = PageIssuer.shared, let binding = token.binding else { return }
    issuer.store.sequence {
      guard issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      page.setShown(shown, warm: warm && !shown, neighbour: neighbour && !shown)
    }
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
