import AppKit
import Foundation
import SolaraCore
import SolaraLive
import SolaraModel
import SolaraStore
import SolaraShell
import SolaraUI

@MainActor
enum NativeSidebar {
  static let kind = "sidebar"
  static var hosts: [String: SidebarHost] = [:]

  static func register() {
    NativeWorkspaceRename.start()
    NativeTileFolders.start()
    NativeNumberedTabs.register()
    NativeSidebarLive.start()
    NativeSidebarMaintenance.start()
    NativeSidebarHoverCard.start()
    NativeSidebarShell.register()
    NativeSidebarDock.register()
    guard !NativeWindowShell.nativeLayout else { return }
    HostedViews.register(kind) { windowId in
      guard !NativeWindowShell.nativeLayout else { return nil }
      let host = SidebarHost(windowId: windowId, virtualizesRows: true)
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in
          host?.stop()
          if hosts[windowId] === host { hosts[windowId] = nil }
        },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
  }

  static func players(windowId: String) -> [NSView] {
    func walk(_ view: NSView) -> [NSView] {
      if let stack = view as? SidebarPlayerStack { return stack.isHiddenOrHasHiddenAncestor ? [] : stack.cardViews + stack.leavingViews }
      if view is SidebarPlayerView { return view.isHiddenOrHasHiddenAncestor ? [] : [view] }
      return view.subviews.flatMap(walk)
    }
    return hosts[windowId].map { walk($0.view) } ?? []
  }

  static func refreshShortcutHints() {
    for host in hosts.values { host.presentationChanged() }
  }

  static func renameChanged(_ windowId: String) { hosts[windowId]?.renameChanged() }

  static func rowFrame(windowId: String, key: String) -> [String: Double]? {
    guard let host = hosts[windowId], let page = host.view.current, let window = page.window, let content = window.contentView,
      let frame = page.frameOf(key)
    else { return nil }
    let inWindow = page.convert(frame, to: nil)
    return ["x": inWindow.minX, "y": content.bounds.height - inWindow.maxY, "width": inWindow.width, "height": inWindow.height]
  }

  static func hoverShifts(windowId: String) -> String? {
    guard let page = hosts[windowId]?.view.current else { return nil }
    let result = page.hoverShifts()
    let json = try? JSONSerialization.data(withJSONObject: ["hovered": result.hovered, "shifts": result.shifts])
    return json.flatMap { String(data: $0, encoding: .utf8) }
  }

  static func motion(windowId: String) -> String? {
    guard let page = hosts[windowId]?.view.current else { return nil }
    let json = try? JSONSerialization.data(withJSONObject: ["t": CACurrentMediaTime(), "rows": page.motionSample()])
    return json.flatMap { String(data: $0, encoding: .utf8) }
  }

  static func pages(windowId: String) -> String? {
    guard let host = hosts[windowId] else { return nil }
    let json = try? JSONSerialization.data(withJSONObject: host.view.describePages())
    return json.flatMap { String(data: $0, encoding: .utf8) }
  }

  static func favicon(_ request: SidebarFaviconRequest) async throws -> NSImage? {
    await NativeHistoryCatalog.favicon(page: request.url, source: request.favicon, profileId: request.profileId, dark: request.dark)
  }
}

struct SidebarPayload: @unchecked Sendable {
  let value: [String: Any]

  init(_ value: [String: Any]) { self.value = value }
}

final class SidebarCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false
  weak var host: SidebarHost?

  func receive(_ state: BrowserState) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { host?.commit(state) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let state = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let state else { return }
      MainActor.assumeIsolated { host?.commit(state) }
    }
  }
}

@MainActor
final class SidebarHost {
  let windowId: String
  let view: SidebarPagerView
  private var stopped = false
  private var hostState: SidebarHostState?
  private var rowProjection: RowProjection?

  private struct RowProjection {
    var state: BrowserState
    var window: BrowserWindow
    var host: SidebarHostState
    var facts: [String: RowFacts]
    var storeId: ObjectIdentifier?

    func matches(_ next: BrowserState, window current: BrowserWindow, storeId currentStoreId: ObjectIdentifier?) -> Bool {
      storeId == currentStoreId && state.settings == next.settings
        && state.ui.appDark == next.ui.appDark && state.profileOrder == next.profileOrder && !next.profiles.changed(from: state.profiles)
        && !next.tabs.changed(from: state.tabs) && !next.groups.changed(from: state.groups) && !next.splits.changed(from: state.splits)
        && window.profileId == current.profileId && window.incognito == current.incognito && window.kind == current.kind
        && window.tabIds == current.tabIds
    }
  }

  private struct RowFacts {
    let tab: Tab
    let developer: Bool
    let engine: String?

    func matches(_ next: Tab) -> Bool {
      tab.openerId == nil && next.openerId == nil && next.adoptId?.hasPrefix("clone:") != true
        && tab.profileId == next.profileId && tab.url == next.url && tab.navigation?.url == next.navigation?.url
        && tab.engine == next.engine && tab.adoptId == next.adoptId
    }
  }
  private var state: BrowserState?
  private var listener: Int?
  var storeSubscriptions: Int { listener == nil ? 0 : 1 }
  private let commits = SidebarCommits()
  private var input: SidebarPresentationInput?
  var onPresentation: ((BrowserState, SidebarHostState) -> Void)?
  private var pagerObserver: NSObjectProtocol?
  private var fedByShell = false
  private var rendered = false
  private var mediaListener: UUID?
  #if SOLARA_PROBES
  private var probeStopped = false
  #endif

  init(windowId: String, subscribeToStore: Bool = true, virtualizesRows: Bool = false) {
    self.windowId = windowId
    view = SidebarPagerView(windowId: windowId, virtualizesRows: virtualizesRows)
    view.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    view.onAction = { [weak self] action in self?.handle(action) }
    commits.host = self
    #if SOLARA_PROBES
    NativeWorkCounters.host(self, windowId: windowId, kind: "sidebar") { host in
      (!host.probeStopped, (host.listener == nil ? 0 : 1) + (host.pagerObserver == nil ? 0 : 1))
    }
    #endif
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.view.setPagerPosition(position) }
    }
    mediaListener = NativeMediaStack.listen { [weak self] in
      guard let self, !self.stopped, !self.fedByShell else { return }
      self.setNeedsRender()
    }
    if subscribeToStore, let store = NativeStoreHandle.store {
      state = store.state
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    NativeWorkspaceRename.windowGone(windowId)
    NativeSidebarHoverCard.dismiss(windowId)
    NativeSidebarIconPicker.close(windowId)
    NativeTileFolders.hostStopped(windowId, page: view.current)
    commits.host = nil
    view.onAction = { _ in }
    onPresentation = nil
    rowProjection = nil
    if rendered, !fedByShell { NativeProfilePager.hosts[windowId]?.sidebarScrollOffsets = view.scrollOffsets }
    view.stop()
    #if SOLARA_PROBES
    probeStopped = true
    #endif
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
    NativeMediaStack.stopListening(mediaListener)
    mediaListener = nil
  }

  func apply(_ json: String) {
    guard !stopped, let next = SidebarPresentationInput.decode(json) else { return }
    input = next
    setNeedsRender()
  }

  func commit(_ next: BrowserState) {
    guard !stopped else { return }
    state = next
    setNeedsRender()
  }

  func apply(state: BrowserState, host: SidebarHostState) {
    guard !stopped else { return }
    fedByShell = true
    self.state = state
    hostState = host
    render()
  }

  private func setNeedsRender() {
    FrameUpdates.schedule(self) { [weak self] in self?.render() }
  }

  func renameChanged() { setNeedsRender() }

  func presentationChanged() { if !fedByShell { setNeedsRender() } }

  private func render() {
    guard !stopped, let state = state ?? NativeStoreHandle.store?.state,
      let window = state.windows[windowId] else { return }
    self.state = state
    if !fedByShell, let input {
      let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
      hostState = presentation(state: state, window: window, look: look, addressBar: input.addressBar)
    }
    guard var host = hostState else { return }
    if let renaming = NativeWorkspaceRename.override(windowId) { host.renaming = renaming }
    onPresentation?(state, host)
    if !rendered, !fedByShell { view.pendingScrollOffsets = NativeProfilePager.hosts[windowId]?.sidebarScrollOffsets ?? [:] }
    view.update(state: state, host: host)
    if !rendered && view.current != nil {
      rendered = true
      if let position = ACPager.snapshot(windowId)?["position"] as? Double { view.setPagerPosition(position) }
    }
    NativeTileFolders.render(windowId: windowId)
    NativeSidebarHoverCard.refresh(windowId)
  }

  func presentation(state: BrowserState, window: BrowserWindow, look: NativeLayoutAppearance, addressBar: Bool) -> SidebarHostState {
    let store = NativeStoreHandle.store
    var host: SidebarHostState
    if let rowProjection, rowProjection.matches(state, window: window, storeId: store.map(ObjectIdentifier.init)) {
      host = rowProjection.host
    } else {
      let projection = projectRows(state: state, window: window, look: look, store: store)
      host = projection.host
      rowProjection = projection
    }
    host.closeHint = ShortcutsAdapter.hint("closeTab")
    host.cleaned = WorkspaceCleanup.cleanedCount(state: state, windowId: windowId, now: Date().timeIntervalSince1970 * 1000)
    host.upsell = NativeSidebarMaintenance.suggestion(windowId: windowId, state: state)
    host.addressBar = addressBar
    host.applyRowPreferences(state: state, windowId: windowId)
    host.pip = window.tabIds.filter { NowPlayingStore.shared.pictureInPicture[$0] != nil }
    host.capture = NowPlayingStore.shared.capture
    let stacked = NativeMediaStack.players(state: state, windowId: windowId, look: look)
    host.player = stacked.first
    host.stack = stacked
    return host
  }

  private func projectRows(state: BrowserState, window: BrowserWindow, look: NativeLayoutAppearance, store: Store?) -> RowProjection {
    var host = SidebarHostState(profileId: window.profileId, dark: look.dark)
    host.theme = look.tokens
    host.border = look.border
    host.glow = look.glow
    host.badge = SidebarHostState.badgeColors(dark: look.dark)
    host.product = Bundle.main.productName
    let storeId = store.map(ObjectIdentifier.init)
    let previousFacts = rowProjection.flatMap { $0.storeId == storeId && $0.state.settings == state.settings ? $0.facts : nil } ?? [:]
    var facts = Dictionary<String, RowFacts>(minimumCapacity: window.tabIds.count)
    var pinnedRowProfiles = Set<String>()
    for tabId in window.tabIds {
      guard let tab = state.tabs[tabId] else { continue }
      if tab.isPinnedRow { pinnedRowProfiles.insert(tab.profileId) }
      let row: RowFacts
      if let previous = previousFacts[tabId], previous.matches(tab) {
        row = previous
      } else {
        row = RowFacts(tab: tab, developer: OmniboxCommandSources.isDeveloperURL(tab.url, settings: state.settings, profileId: tab.profileId),
          engine: store?.pageEngineMark(tab, in: state))
      }
      facts[tabId] = row
      if row.developer { host.developer.append(tabId) }
      host.engines[tabId] = row.engine
    }
    func canTidy(_ profileId: String) -> Bool {
      pinnedRowProfiles.contains(profileId) && CommandContext.canTidyPins(state: state, windowId: windowId, profileId: profileId)
    }
    host.tidy = canTidy(window.profileId)
    let currentTidy = host.tidy
    host.pages = SidebarPagerView.profileIDs(state: state, windowId: windowId).map { profileId in
      let page = profileId == window.profileId ? look : NativeLayoutAppearance(state: state, profileId: profileId, incognito: false)
      let tidy = profileId == window.profileId ? currentTidy : canTidy(profileId)
      return SidebarPageLook(profileId: profileId, dark: page.dark, theme: page.tokens, border: page.border, glow: page.glow,
        tidy: tidy, incognito: false)
    }
    return RowProjection(state: state, window: window, host: host, facts: facts, storeId: storeId)
  }

  private func handle(_ action: SidebarAction) {
    guard !stopped else { return }
    if case .hover(let kind, let id) = action {
      NativeSidebarHoverCard.row(windowId: windowId, kind: kind, id: id)
      return
    }
    NativeSidebarHoverCard.dismiss(windowId)
    switch action {
    case .click(let tabId, let mods):
      if WorkspaceActionRouter.ownedClick(windowId: windowId, tabId: tabId, mods: mods) {
        FrameUpdates.flush()
        call("handled", tabId)
      } else if mods.none, activateWithoutSelection(tabId) {
        call("handled", tabId)
      } else {
        NSLog("[sidebar] click refused: native store unavailable, dispatch failed or target stale")
      }
    case .close(let tabId):
      if let owned = WorkspaceActionRouter.ownedClose(tabId: tabId, middle: false) {
        call("handled", tabId)
        NativeWorkspaceCommands.runCloseRoute(owned.route, tabId: tabId, store: owned.store)
      } else {
        NSLog("[sidebar] close refused: native store unavailable, dispatch failed or target stale")
      }
    case .middleClick(let tabId):
      if let owned = WorkspaceActionRouter.ownedClose(tabId: tabId, middle: true) {
        call("handled", tabId)
        NativeWorkspaceCommands.runCloseRoute(owned.route, tabId: tabId, store: owned.store)
      } else {
        NSLog("[sidebar] middleClick refused: native store unavailable, dispatch failed or target stale")
      }
    case .rename(let kind, let id):
      if !NativeWorkspaceRename.begin(windowId: windowId, kind: kind == "group" ? .group : .tab, id: id) { NSLog("[sidebar] rename refused: native store unavailable, dispatch failed or target stale") }
    case .backToPinned(let tabId):
      if NativeTabMenu.sidebarAction("backToPinned", tabId: tabId, windowId: windowId) { call("handled", tabId) } else { NSLog("[sidebar] backToPinned refused: native store unavailable, dispatch failed or target stale") }
    case .tileDoubleClick(let tabId):
      if NativeTabMenu.sidebarAction("tileDoubleClick", tabId: tabId, windowId: windowId) { call("handled", tabId) } else { NSLog("[sidebar] tileDoubleClick refused: native store unavailable, dispatch failed or target stale") }
    case .toggleMute(let tabId):
      if NativeTabMenu.sidebarAction("toggleMute", tabId: tabId, windowId: windowId) { call("handled", tabId) } else { NSLog("[sidebar] toggleMute refused: native store unavailable, dispatch failed or target stale") }
    case .tabMenu(let tabId):
      if WorkspaceWrites.store != nil { call("handled", tabId) }
      let opened = NativeTabMenu.open(tabId, windowId: windowId)
      if !opened {
        NSLog("[sidebar] tabMenu refused: native store unavailable, dispatch failed or target stale")
      }
    case .groupMenu(let groupId):
      let opened = NativeGroupMenu.open(groupId, windowId: windowId)
      if !opened { NSLog("[sidebar] groupMenu refused: native store unavailable, dispatch failed or target stale") }
    case .toggleGroup(let groupId):
      if !NativeGroupActions.toggle(groupId, collapsed: { !$0.collapsed }) { NSLog("[sidebar] toggleGroup refused: native store unavailable, dispatch failed or target stale") }
    case .closeGroup(let groupId):
      if !NativeGroupActions.close(groupId) { NSLog("[sidebar] closeGroup refused: native store unavailable, dispatch failed or target stale") }
    case .sidebarMenu: NativeSidebarMenus.open(windowId: windowId, overflow: false)
    case .overflowMenu: NativeSidebarMenus.open(windowId: windowId, overflow: true)
    case .newTab(let split):
      if split { NativeSplitChrome.openPane(windowId: windowId) }
      else { _ = NativeWorkspaceCommands.perform("newTab", windowId: windowId) }
    case .newTabDoubleClick:
      _ = NativeWorkspaceCommands.perform("newTab", windowId: windowId)
    case .folder(let folderId):
      if NativeTileFolders.toggle(windowId: windowId, folderId: folderId) { call("handled", folderId) } else { NSLog("[sidebar] folder refused: native store unavailable, dispatch failed or target stale") }
    case .folderMenu(let folderId):
      if !NativeTileFolders.folderMenu(windowId: windowId, folderId: folderId) { NSLog("[sidebar] folderMenu refused: native store unavailable, dispatch failed or target stale") }
    case .tidy:
      if let store = WorkspaceWrites.store { NativeSidebarUndo.tidy(windowId: windowId, profileId: hostState?.profileId, store: store) }
    case .clear:
      if let store = WorkspaceWrites.store { NativeSidebarUndo.clear(windowId: windowId, store: store) }
    case .cleanUp(let choice):
      NativeSidebarMaintenance.choose(choice, windowId: windowId)
    case .hover: break
    case .scrolled:
      if NativeTileFolders.owned {
        NativeTileFolders.close(in: windowId)
        call("handled", "")
      } else {
        NSLog("[sidebar] scrolled refused: native store unavailable, dispatch failed or target stale")
      }
    case .renamed(let kind, let id, let text):
      if WorkspaceActionRouter.ownedStore == nil {
        NativeWorkspaceRename.reset(windowId: windowId)
        NSLog("[sidebar] renamed refused: native store unavailable, dispatch failed or target stale")
      } else if let text {
        NativeWorkspaceRename.commit(windowId: windowId, kind: kind == "group" ? .group : .tab, id: id, text: text)
      } else {
        NativeWorkspaceRename.end(windowId: windowId, id: id)
      }
    case .live(let action, let folderId, let id, let meta): NativeSidebarLive.action(action, windowId: windowId, folderId: folderId, id: id, background: meta)
    case .media(let tabId, let action): NativeMediaStack.perform(windowId: windowId, tabId: tabId, action: action)
    }
  }

  private func activateWithoutSelection(_ tabId: String) -> Bool {
    guard let store = WorkspaceWrites.store, store.state.tabs[tabId]?.windowId == windowId,
      store.state.selection[windowId]?.ids.isEmpty != false else { return false }
    do {
      try store.dispatch([
        Command("activate", [.string(tabId)]),
        Command("setSelectionAnchor", [.string(windowId), .string(tabId)]),
      ], origin: .native)
      FrameUpdates.flush()
      return true
    } catch {
      NSLog("[sidebar] activate refused: %@", String(describing: error))
      return false
    }
  }

  private func call(_ name: String, _ id: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
      _ = await SettingsAdapters.js("sidebar.action", windowId, name, id, payload.value)
    }
  }
}

@MainActor
enum NativeSidebarLive {
  private static var revision: UInt64?
  private static var state: LiveState?
  private static var calendar = CalendarData()
  private static var showAll: [String: Bool] = [:]

  private static var ownershipListener: Int?
  private static var storeListener: Int?
  private static weak var orderStore: Store?
  private static var orderTask: Task<Void, Never>?

  static func start() {
    guard ownershipListener == nil else { return }
    _ = NativeLiveEngine.shared
    ownershipListener = NativeStoreHandle.subscribeLifecycle { observeOrder() }
    observeOrder()
  }

  private static func observeOrder() {
    let current = WorkspaceWrites.store
    guard current !== orderStore else { return }
    if let storeListener { orderStore?.unsubscribe(storeListener) }
    orderTask?.cancel()
    orderTask = nil
    storeListener = nil
    orderStore = current
    guard let current else { return }
    let (commits, observed) = AsyncStream<Commit>.makeStream()
    let initial = current.sequence {
      storeListener = current.subscribe { commit in
        let changes = commit.changes
        if !changes.windows.isEmpty || !changes.tabs.isEmpty || !changes.groups.isEmpty {
          observed.yield(commit)
        }
      }
      return current.snapshot
    }
    orderTask = Task { @MainActor [weak current] in
      defer { observed.finish() }
      var previous = initial
      let engine = NativeLiveEngine.shared.engine
      for await commit in commits {
        guard let current, current === WorkspaceWrites.store, !Task.isCancelled else { return }
        guard commit.rev > previous.rev else { continue }
        let before = previous.state
        previous = (commit.rev, commit.state)
        let after = commit.state
        await engine.update { state in
          guard !Task.isCancelled else { return }
          state.arrangeFolders(SidebarLive(state: state).removedAnchorPlacements(before: before, after: after))
        }
      }
    }
  }

  static func arrange(_ placed: [FolderPlacement]) {
    guard !placed.isEmpty else { return }
    perform(.arrangeFolders(.object(["placed": .array(placed.map {
      .object(["id": .string($0.id), "after": $0.after.map(LiveAnyJSON.string) ?? .null])
    })])))
  }

  static func receive(_ state: LiveState, calendar: CalendarData, revision: UInt64) {
    guard self.revision.map({ revision > $0 }) ?? true else { return }
    self.revision = revision
    self.state = state
    self.calendar = calendar
    publish()
  }

  static func calendarPreview(tabId: String, dark: Bool) -> String? {
    guard state?.calendar.showPreview != false else { return nil }
    let now = Date()
    let time = now.timeIntervalSince1970 * 1000
    let day = Foundation.Calendar.current.dateInterval(of: .day, for: now)
    let start = (day?.start ?? now).timeIntervalSince1970 * 1000
    let end = (day?.end ?? now).timeIntervalSince1970 * 1000
    let today = calendar.events.filter { !$0.cancelled && !$0.declined && $0.start < end && $0.end > start }
    let upcoming = today.filter { $0.end > time }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
    let body: String
    if !calendar.connected { body = calendar.access == .denied || calendar.access == .restricted ? "denied" : "signIn" }
    else if calendar.lastFetch == nil && calendar.loading { body = "loading" }
    else if calendar.lastFetch == nil && calendar.error != nil { body = "error" }
    else if today.isEmpty { body = "none" }
    else { body = upcoming.isEmpty ? "noMore" : "events" }
    func row(_ event: CalendarEvent) -> [String: Any] {
      ["id": event.occurrence, "title": event.title.isEmpty ? "Untitled event" : event.title, "color": event.color]
    }
    let timed = upcoming.filter { !$0.allDay }.map { event -> [String: Any] in
      var entry = row(event)
      let running = event.start <= time
      entry["time"] = Meetings.timeRange(start: event.start, end: event.end)
      entry["running"] = running
      entry["when"] = running ? "Now" : Meetings.relativeTime(event.start, now: time)
      entry["past"] = false
      entry["people"] = event.attendees.filter { !$0.me }.map { $0.name.isEmpty ? $0.email : $0.name }
      if time >= event.start - 600_000, Meetings.isMeeting(event), let link = Meetings.joinLink(event) {
        entry["joinTitle"] = Meetings.joinTitle(link.provider)
      }
      return entry
    }
    let content: [String: Any] = [
      "card": "calendarPreview", "dark": dark, "nowColor": dark ? "#E5534B" : "#D1242F",
      "product": Bundle.main.productName, "date": formatter.string(from: now), "tabId": tabId,
      "connected": calendar.connected, "loading": calendar.loading, "body": body,
      "allDay": upcoming.filter(\.allDay).map(row), "events": timed,
    ]
    return (try? JSONSerialization.data(withJSONObject: content)).map { String(decoding: $0, as: UTF8.self) }
  }

  static func joinCalendarEvent(_ id: String, windowId: String) {
    guard let event = calendar.events.first(where: { $0.occurrence == id }), let link = Meetings.joinLink(event),
      let store = WorkspaceWrites.store, store.state.windows[windowId]?.incognito == false else { return }
    _ = try? store.dispatch(Command("newTab", [.string(windowId), ["url": .string(link.url)]]), origin: .native)
    perform(.dismissAlert(.object(["occurrence": .string(id)])))
    FrameUpdates.flush()
  }

  static func showMore(folderId: String, itemId: String) {
    showAll["\(folderId):\(itemId)"] = true
    publish()
  }

  static func calendarMenu() -> TabMenuItem {
    let settings = state?.calendar ?? .defaults
    func calendars(_ owned: Bool) -> [TabMenuItem] {
      let items = calendar.calendars.filter { $0.owned == owned }.map { item in
        TabMenuItem(id: "cal:toggle:\(item.id)", title: item.title, checked: !settings.hiddenCalendarIds.contains(item.id), swatch: item.color)
      }
      guard !items.isEmpty else { return [] }
      let title = TabMenuItem(title: owned ? "My Calendars" : "Other Calendars", enabled: false)
      return (owned ? [] : [TabMenuItem(separator: true)]) + [title] + items
    }
    var items: [TabMenuItem] = calendar.connected ? [] : [
      .init(id: "cal:connect", title: "Connect Calendar…", symbol: "calendar.badge.plus"), .init(separator: true),
    ]
    items += [
      .init(id: "cal:alerts", title: "Show Next Meeting Alert", children: CalendarAlertLeads.options.map {
        .init(id: "cal:lead:\($0.value)", title: $0.title, checked: settings.alertLead == $0.value)
      }),
      .init(id: "cal:preview", title: "Show Calendar Preview", checked: settings.showPreview),
      .init(id: "cal:badge", title: "Show Time to Next Meeting", checked: settings.showTimeToNext),
      .init(id: "cal:active", title: "Active Calendars", enabled: !calendar.calendars.isEmpty, children: calendars(true) + calendars(false)),
      .init(separator: true),
      .init(id: "cal:settings", title: "Calendar Settings…", symbol: "gearshape"),
    ]
    return .init(id: "cal", title: "Calendar", symbol: "calendar", children: items)
  }

  static func runCalendarChoice(_ choice: String, windowId: String) -> Bool {
    guard choice.hasPrefix("cal:") else { return false }
    let settings = state?.calendar ?? .defaults
    switch choice {
    case "cal:connect": perform(.connectCalendar(.object([:])))
    case "cal:preview": calendarPatch(["showPreview": .bool(!settings.showPreview)])
    case "cal:badge": calendarPatch(["showTimeToNext": .bool(!settings.showTimeToNext)])
    case "cal:settings": openSettings("calendar")
    default:
      if choice.hasPrefix("cal:lead:") {
        let value = String(choice.dropFirst(9))
        if CalendarAlertLeads.options.contains(where: { $0.value == value }) { calendarPatch(["alertLead": .string(value)]) }
      } else if choice.hasPrefix("cal:toggle:") {
        let id = String(choice.dropFirst(11))
        if calendar.calendars.contains(where: { $0.id == id }) {
          perform(.setCalendarHidden(.object(["id": .string(id), "hidden": .bool(!settings.hiddenCalendarIds.contains(id))])))
        }
      }
    }
    return true
  }

  static func openSettings(_ pane: String) {
    NativeSettingsWindow.navigate(pane: pane, profileId: nil, detail: nil)
    WindowHost.openAuxiliary(id: NativeSettingsWindow.windowId, kind: "settings", title: "Settings")
  }

  private static func calendarPatch(_ patch: [String: LiveAnyJSON]) {
    perform(.updateCalendarSettings(.object(["patch": .object(patch)])))
  }

  static func perform(_ command: LiveCommand, then followup: LiveCommand? = nil) {
    Task { @MainActor in
      do {
        _ = try await NativeLiveEngine.shared.perform(command)
        if let followup { _ = try await NativeLiveEngine.shared.perform(followup) }
      } catch {
        NSLog("[sidebar] Live action refused: %@", String(describing: error))
      }
    }
  }

  private static func publish() {
    guard var state else { return }
    state.showAll.merge(showAll) { _, local in local }
    SidebarLiveFeed.shared.apply(state)
  }
}

@MainActor
enum NativeSidebarMaintenance {
  private static var lifecycle: Int?
  private static weak var store: Store?
  private static var subscription: Int?
  private static var cleanupTimer: Timer?
  private static var presentationTimer: Timer?
  private static var observers: [NSObjectProtocol] = []
  private static var dismissed = false
  private static var cleaned: [String: Int] = [:]
  private static var suggestions: [String: Int] = [:]
  private static var suggestionWindows: [String: SuggestionWindow] = [:]
  private static var pendingSuggestions: BrowserState?
  private static var suggestionTask: Task<Void, Never>?
  private static var generation: UInt64 = 0

  private struct SuggestionWindow: Equatable {
    let profileId: String
    let tabIds: [String]
    let activeId: String?
  }

  static func start() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { ownershipChanged() }
    let local = NotificationCenter.default
    observers.append(local.addObserver(forName: AppUpdater.pendingUpdateChanged, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { presentationChanged() }
    })
    observers.append(local.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { closeAbandoned() }
    })
    observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { closeAbandoned() }
    })
  }

  private static func ownershipChanged() {
    let next = WorkspaceWrites.store
    guard next !== store else { return }
    if let subscription { store?.unsubscribe(subscription) }
    subscription = nil
    cleanupTimer?.invalidate()
    cleanupTimer = nil
    presentationTimer?.invalidate()
    presentationTimer = nil
    generation += 1
    suggestionTask?.cancel()
    suggestionTask = nil
    pendingSuggestions = nil
    suggestionWindows = [:]
    suggestions = [:]
    cleaned = [:]
    store = next
    guard let next else { return }
    cleanupTimer = schedule(every: 30 * 60, run: cleanInactiveTabs)
    subscription = next.subscribe { [weak next] commit in
      let changes = commit.changes
      guard changes.settings || !changes.windows.isEmpty || changes.lists.contains("cleanedTabs")
        || changes.lists.contains("privateCleanedTabs") else { return }
      Task { @MainActor in
        guard let next, WorkspaceWrites.store === next else { return }
        updateCleanup(next.state)
      }
    }
    updateCleanup(next.state)
  }

  static func suggestion(windowId: String, state: BrowserState) -> Int? {
    SidebarCleanupPresentation.admitted(state: state, dismissed: dismissed) ? suggestions[windowId] : nil
  }

  private static func updateCleanup(_ state: BrowserState, tick: Bool = false) {
    let now = Date().timeIntervalSince1970 * 1000
    let nextCleaned = Dictionary(uniqueKeysWithValues: state.windows.keys.compactMap { id -> (String, Int)? in
      let count = WorkspaceCleanup.cleanedCount(state: state, windowId: id, now: now)
      return count > 0 ? (id, count) : nil
    })
    let cleanedChanged = nextCleaned != cleaned
    cleaned = nextCleaned
    var windows: [String: SuggestionWindow] = [:]
    if SidebarCleanupPresentation.admitted(state: state, dismissed: dismissed) {
      for window in state.windows.values where window.tabIds.count >= 10 {
        windows[window.id] = SuggestionWindow(profileId: window.profileId, tabIds: window.tabIds, activeId: window.activeTabIds[window.profileId])
      }
    }
    let retained = suggestions.filter { id, _ in windows[id] != nil && windows[id] == suggestionWindows[id] }
    let suggestionsChanged = retained != suggestions
    suggestions = retained
    if windows != suggestionWindows || tick {
      suggestionWindows = windows
      pendingSuggestions = windows.isEmpty ? nil : state
      calculateSuggestions()
    }
    if (!windows.isEmpty || !cleaned.isEmpty), presentationTimer == nil {
      presentationTimer = schedule(every: 60, run: refreshCleanup)
    } else if windows.isEmpty && cleaned.isEmpty {
      presentationTimer?.invalidate()
      presentationTimer = nil
    }
    if suggestionsChanged || (tick && cleanedChanged) { presentationChanged() }
  }

  private static func calculateSuggestions() {
    guard suggestionTask == nil, let state = pendingSuggestions else { return }
    pendingSuggestions = nil
    let ids = Array(suggestionWindows.keys)
    let ticket = generation
    suggestionTask = Task.detached(priority: .utility) {
      let now = Date().timeIntervalSince1970 * 1000
      var counts: [String: Int] = [:]
      for id in ids {
        guard !Task.isCancelled else { return }
        counts[id] = SidebarCleanupPresentation.suggestion(state: state, windowId: id, now: now, dismissed: false)
      }
      await acceptSuggestions(counts, generation: ticket)
    }
  }

  private static func acceptSuggestions(_ counts: [String: Int], generation ticket: UInt64) {
    guard generation == ticket, WorkspaceWrites.store === store else { return }
    suggestionTask = nil
    if pendingSuggestions == nil, !suggestionWindows.isEmpty, counts != suggestions {
      suggestions = counts
      presentationChanged()
    }
    calculateSuggestions()
  }

  private static func refreshCleanup() {
    guard let store = WorkspaceWrites.store else { return }
    updateCleanup(store.state, tick: true)
  }

  static func choose(_ choice: SidebarCleanUpChoice, windowId: String) {
    guard let store = WorkspaceWrites.store, store.state.windows[windowId] != nil else { return }
    let clean = Command("cleanUpTabs", [.string(windowId)])
    switch choice {
    case .once:
      if dispatch([clean], store: store) { dismissed = true }
    case .daily:
      _ = dispatch([Command("updateSettings", [["cleanUpInactiveTabsAfterHours": JSONValue(24)]]), clean], store: store)
    case .dismiss:
      dismissed = true
    case .dontAskAgain:
      _ = dispatch([Command("updateSettings", [["suggestTabCleanUp": .bool(false)]])], store: store)
    }
    updateCleanup(store.state)
    presentationChanged()
    FrameUpdates.flush()
  }

  private static func schedule(every: TimeInterval, run: @escaping @MainActor @Sendable () -> Void) -> Timer {
    let now = Date().timeIntervalSince1970
    let separate = ProcessInfo.processInfo.environment["SOLARA_SLOW_TIMERS"] == "separate"
    let next = separate ? now + every : (floor(now / every) + 1) * every
    let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: every, repeats: true) { _ in
      MainActor.assumeIsolated { run() }
    }
    timer.tolerance = separate ? 0 : 0.05
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private static func presentationChanged() {
    for host in NativeSidebar.hosts.values { host.presentationChanged() }
    NativeLayoutChrome.presentationChanged()
  }

  private static func cleanInactiveTabs() {
    guard let store = WorkspaceWrites.store else { return }
    let state = store.state
    guard let hours = state.settings.number("cleanUpInactiveTabsAfterHours") else { return }
    for id in state.windowOrder {
      _ = dispatch([Command("cleanUpTabs", [.string(id), ["inactiveForMs": JSONValue(hours * 3_600_000)]])], store: store)
    }
  }

  private static func closeAbandoned() {
    guard let store = WorkspaceWrites.store, NSApp.modalWindow == nil,
      !NSApp.windows.contains(where: { $0.attachedSheet != nil || $0.isSheet && $0.isVisible }) else { return }
    _ = dispatch([Command("closeAbandonedNewTabs", [])], store: store)
  }

  @discardableResult
  private static func dispatch(_ commands: [Command], store: Store) -> Bool {
    do {
      _ = try store.dispatch(commands, origin: .native)
      return true
    } catch {
      NSLog("[sidebar] maintenance refused: %@", String(describing: error))
      return false
    }
  }
}

#if DEBUG || SOLARA_PERF_TRACE
@MainActor
enum SidebarLayoutWatch {
  private struct Place: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var commit: Int

    init?(_ frame: [String: Double], commit: Int) {
      guard let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else { return nil }
      self.x = x
      self.y = y
      self.width = width
      self.height = height
      self.commit = commit
    }

    func onScreen(_ frame: [Double]?) -> Bool {
      let bounds = frame.flatMap { $0.count >= 4 ? $0 : nil }
      return width > 0 && height > 0 && x >= 0 && x + width <= (bounds?[2] ?? .infinity) + 1
        && y + height > 0 && y < (bounds?[3] ?? .infinity)
    }
  }

  private struct Move: Codable {
    var row: String
    var from: Place
    var to: Place
  }

  private struct Report: Codable {
    var commits: Int
    var rows: Int
    var shown: Int
    var ms: Double
    var moves: [Move]
    var missing: [String]
    var edits: [String]
  }

  private static var last: [String: Place] = [:]
  private static var shown: Set<String> = []
  private static var moves: [Move] = []
  private static var edits: [String] = []
  private static var commits = 0
  private static var started: Date?
  private static var finished = false

  static func committed(editAt: Int) {
    guard !finished, let state = NativeStoreHandle.store?.state else { return }
    if started == nil {
      started = Date()
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
    }
    commits += 1
    if commits == editAt { DispatchQueue.main.async { edit() } }
    let query = SidebarQuery(state)
    for windowId in state.windowOrder {
      guard let window = state.windows[windowId] else { continue }
      let ids = Set(expectedRows(query, window: window)
        + window.tabIds.filter { state.tabs[$0]?.profileId == window.profileId }
        + state.groups.values.filter { $0.windowId == windowId && $0.profileId == window.profileId }.map(\.id)
        + state.splits.values.filter { $0.windowId == windowId }.map { "s:\($0.id)" })
      for id in ids {
        guard let frame = NativeSidebar.rowFrame(windowId: windowId, key: id), let place = Place(frame, commit: commits) else { continue }
        let key = "\(windowId)|\(id)"
        if let before = last[key], shown.contains(key), abs(before.x - place.x) > 0.5 || abs(before.y - place.y) > 0.5 {
          moves.append(Move(row: key, from: before, to: place))
        }
        last[key] = place
        if place.onScreen(window.frame) { shown.insert(key) }
      }
    }
  }

  private static func expectedRows(_ query: SidebarQuery, window: BrowserWindow) -> [String] {
    let entries = query.entries(windowId: window.id, profileId: window.profileId)
    return entries.cells + (entries.pinned + entries.list).map { $0.hasPrefix("s:") ? $0 : String($0.dropFirst(2)) }
  }

  private static func edit() {
    guard let store = NativeStoreHandle.store, let windowId = store.state.resolveWindowId(nil),
      let window = store.state.windows[windowId] else { return }
    let state = store.state
    let ids = window.tabIds.filter { state.tabs[$0]?.profileId == window.profileId && state.tabs[$0]?.pinned == false }
    guard let added = (try? store.dispatch(Command("newTab", [.string(windowId), ["url": "about:blank#layout-edit", "background": true]]), origin: .native))?.result?.string else { return }
    let closed = ids.count > 3 ? ids[3] : nil
    let moved = ids.last
    var commands = [Command("moveTab", [.string(added), 0])]
    if let closed { commands.append(Command("closeTab", [.string(closed)])) }
    if let moved { commands.append(Command("moveTab", [.string(moved), 1])) }
    _ = try? store.dispatch(commands, origin: .native)
    edits = ["added \(added)", "closed \(closed ?? "undefined")", "moved \(moved ?? "undefined")"]
  }

  private static func finish() {
    guard let started, let state = NativeStoreHandle.store?.state else { return }
    finished = true
    let query = SidebarQuery(state)
    var missing: [String] = []
    for windowId in state.windowOrder {
      guard let window = state.windows[windowId], window.sidebarOpen else { continue }
      for id in expectedRows(query, window: window) where NativeSidebar.rowFrame(windowId: windowId, key: id) == nil {
        missing.append("\(windowId)|\(id)")
      }
    }
    let result = Report(commits: commits, rows: last.count, shown: shown.count, ms: Date().timeIntervalSince(started) * 1000,
      moves: moves, missing: missing, edits: edits)
    if let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) {
      try? DocumentStore.write("layout-watch.json", json)
    }
  }
}
#endif
