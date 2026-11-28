import AppKit
import ExpoModulesCore
import SolaraEngine
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI
import SwiftUI

public class PagesModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPages")

    Function("available") { () -> Bool in
      NativeSettingsHandle.active
    }

    Events("onMeetingAlertEvent", "onHistoryAction")

    OnStartObserving("onHistoryAction") {
      let sink = PagesEventSink(self)
      DispatchQueue.main.async {
        NativePageView.historyAction = { body in sink.module?.sendEvent("onHistoryAction", body) }
      }
    }

    AsyncFunction("historyActionCurrent") { (token: String) -> Bool in
      MainActor.assumeIsolated { NativePageView.historyView(token) != nil }
    }.runOnQueue(.main)

    AsyncFunction("finishHistoryAction") { (token: String, action: String) in
      MainActor.assumeIsolated { NativePageView.historyView(token)?.finishHistoryAction(action) }
    }.runOnQueue(.main)

    AsyncFunction("showMeetingAlert") { (windowId: String, json: String, left: Double, top: Double) -> Bool in
      let sink = PagesEventSink(self)
      return MainActor.assumeIsolated {
        MeetingAlertHost.show(windowId: windowId, json: json, left: left, top: top) { body in sink.module?.sendEvent("onMeetingAlertEvent", body) }
      }
    }.runOnQueue(.main)

    AsyncFunction("hideMeetingAlert") { (windowId: String) in
      MainActor.assumeIsolated { MeetingAlertHost.hide(windowId: windowId) }
    }.runOnQueue(.main)

    AsyncFunction("bookmarkScale") { (operation: String, value: String?) -> String in
      MainActor.assumeIsolated { NativePageView.bookmarkScale(operation, value) }
    }.runOnQueue(.main)

    AsyncFunction("devPages") { () -> String in
      MainActor.assumeIsolated { NativePageView.devState() }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devBookmarkForm") { (windowId: String, id: String, popover: Bool) -> String in
      MainActor.assumeIsolated {
        guard ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
          ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"]?.isEmpty == false else { return "environment" }
        return popover ? NativeBookmarkForms.showExisting(windowId: windowId, id: id) : NativeBookmarkForms.showEditor(windowId: windowId, id: id)
      }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("devDropTarget") { (windowNumber: Int, x: Double, y: Double, type: String) -> String in
      MainActor.assumeIsolated { DropProbe.json(DropProbe.target(windowNumber: windowNumber, x: x, y: y, type: type)) }
    }.runOnQueue(.main)

    AsyncFunction("devViewFrame") { (windowNumber: Int, needle: String) -> String in
      MainActor.assumeIsolated { DropProbe.json(DropProbe.frame(windowNumber: windowNumber, classContains: needle)) }
    }.runOnQueue(.main)

    AsyncFunction("devPageHover") { (key: String?) in
      MainActor.assumeIsolated { NativePageView.devHover(key) }
    }.runOnQueue(.main)

    View(NativePageExpoView.self) {
      Events("onPageEvent")

      Prop("kind") { (view: NativePageExpoView, v: String) in MainActor.assumeIsolated { view.page.setKind(v) } }
      Prop("internalTabId") { (view: NativePageExpoView, v: String?) in MainActor.assumeIsolated { view.page.setInlineTab(v) } }
      Prop("state") { (view: NativePageExpoView, v: String) in MainActor.assumeIsolated { view.page.setState(v) } }

      AsyncFunction("focusSearch") { (view: NativePageExpoView) in MainActor.assumeIsolated { view.page.focusSearch() } }.runOnQueue(.main)
    }
  }
}

@MainActor
enum PageNetwork {
  static let favicons = PageFavicons(
    load: { url, favicon, profile, dark in
      await NativeHistoryCatalog.favicon(page: url, source: favicon, profileId: profile, dark: dark)
    },
    bundled: { name in NativeSettingsWindow.bundledSiteIcon(name) })
}

final class NativePageExpoView: ExpoView {
  let onPageEvent = EventDispatcher()
  let page = NativePageView(frame: .zero)

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    page.onPageEvent = { [weak self] body in self?.onPageEvent(body) }
    page.frame = bounds
    page.autoresizingMask = [.width, .height]
    addSubview(page)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    page.isDisplaying ? super.hitTest(point) : nil
  }
}

final class NativePageView: NSView {
  var onPageEvent: ([String: Any]) -> Void = { _ in }
  var isDisplaying: Bool { !kind.isEmpty }
  private var kind = ""
  private var json = ""
  private var host: NSView?
  private lazy var downloads = DownloadsPageModel()
  private var displayedDownloads: DownloadScope?

  private struct DownloadScope: Equatable {
    let windowId: String
    let profileId: String
  }
  private var downloadsLifecycle: Int?
  private weak var observedDownloadStore: Store?
  private var downloadsListener: Int?
  private lazy var history = HistoryPageModel(catalog: NativeHistoryCatalog.catalog)
  private let bookmarks = BookmarksPageModel(catalog: NativeHistoryCatalog.catalog)
  private var bookmarkEditing: NativeBookmarkEditing?
  private var bookmarkLifecycle: Int?
  private weak var observedBookmarkStore: Store?
  private var bookmarkStoreListener: Int?
  private var observedBookmarkTab: String?
  private var observedBookmarkWindow: String?

  private var inlineTabId: String?
  private var inline = false
  private var internalTabId: String?
  private var internalScope: InternalScope?
  private var historyToken = UUID().uuidString
  private weak var scopeStore: Store?
  private var scopeOwnership = 0
  private var inlineLifecycle: Int?
  private weak var inlineStore: Store?
  private var inlineListener: Int?

  private struct InternalScope: Equatable {
    let tabId: String
    let windowId: String
    let profileId: String
    let engineProfile: String
    let destination: InternalPageDestination

    @MainActor init?(state: BrowserState, tabId: String, window: NSWindow) {
      guard let tab = state.tabs[tabId], !((tab.unloaded ?? false) || (tab.pageIn?.isEmpty == false)),
        ShellDrag.window(tab.windowId) === window,
        state.windows[tab.windowId]?.profileId == tab.profileId,
        let destination = InternalPageDestination(tab: tab) else { return nil }
      self.tabId = tab.id
      windowId = tab.windowId
      profileId = tab.profileId
      engineProfile = state.engineProfile(tab.profileId)
      self.destination = destination
    }
  }
  private let createProfile = CreateProfileFormModel()
  private let liveCard = LiveCardModel()

  override var isFlipped: Bool { true }

  static let live = NSHashTable<NativePageView>.weakObjects()
  static var historyAction: ([String: Any]) -> Void = { _ in }

  static func historyView(_ token: String) -> NativePageView? {
    live.allObjects.first { $0.historyToken == token && $0.currentHistoryScope != nil }
  }

  func finishHistoryAction(_ action: String) {
    if action == "selection" { history.selected = [] }
    if action == "clear" { history.clearOpen = false }
    if action == "clear" || action == "clearFailed" { history.clearBusy = false }
  }
  private struct ClearDataRequest {
    let store: Store
    let generation: Int
    let profileId: String
    let tabId: String
  }
  private static var pendingClearData: [String: ClearDataRequest] = [:]

  static func requestClearData(windowId: String) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let profileId = store.state.windows[windowId]?.profileId, let tabId = store.state.activeTabId(windowId) else { return }
    pendingClearData[windowId] = ClearDataRequest(store: store, generation: NativeStoreHandle.ownershipGeneration, profileId: profileId, tabId: tabId)
    for view in live.allObjects { view.consumeClearDataRequest() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    bindInlinePage()
    bindBookmarkScope()
    bindDownloadsScope()
    consumeClearDataRequest()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    kind.isEmpty ? nil : super.hitTest(point)
  }

  private func consumeClearDataRequest() {
    Self.pendingClearData = Self.pendingClearData.filter { windowId, request in
      NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === request.store
        && NativeStoreHandle.ownershipGeneration == request.generation && request.store.state.windows[windowId]?.profileId == request.profileId
        && request.store.state.activeTabId(windowId) == request.tabId
        && request.store.state.tabs[request.tabId].flatMap(InternalPageDestination.init(tab:))?.page == .history
    }
    guard let scope = currentHistoryScope, Self.pendingClearData[scope.windowId]?.tabId == scope.tabId else { return }
    Self.pendingClearData.removeValue(forKey: scope.windowId)
    history.clearOpen = true
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    downloads.onEvent = { [weak self] event in
      guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor,
        let scope = self.displayedDownloads, scope == self.downloadScope else { return }
      NativeDownloadActions.perform(event, windowId: scope.windowId, profileId: scope.profileId, in: window)
    }
    bookmarks.onEvent = { [weak self] event in self?.send(event) }
    createProfile.onEvent = { [weak self] event in self?.send(event) }
    liveCard.onEvent = { [weak self] event in self?.send(event) }
    Self.live.add(self)
    PageProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
  }

  required init?(coder: NSCoder) { fatalError() }

  static func bookmarkScale(_ operation: String, _ value: String?) -> String {
    let environment = ProcessInfo.processInfo.environment
    guard !LaunchSwitches.shared.distribution, environment["AC_BENCH_BOOKMARKS"] == "1",
      environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false,
      let view = live.allObjects.first(where: { $0.window != nil && $0.kind == "bookmarks" }) else { return "null" }
    let model = view.bookmarks
    switch operation {
    case "folder": if let value { model.query = ""; model.folderId = value }
    case "query": model.query = value ?? ""
    case "selectAll": model.selected = model.ids
    case "delete":
      let selected = model.selected
      model.selected = []
      if !selected.isEmpty { model.emit(.delete(selected)) }
    case "scroll":
      func scrollViews(_ root: NSView) -> [NSScrollView] {
        (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap(scrollViews)
      }
      if let scroll = view.host.flatMap({ scrollViews($0).max(by: { $0.bounds.width < $1.bounds.width }) }), let document = scroll.documentView {
        let y = min(max(CGFloat(Double(value ?? "0") ?? 0), 0), max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    default: break
    }
    let ids = model.ids
    func scrollViews(_ root: NSView) -> [NSScrollView] {
      (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap(scrollViews)
    }
    let listScroll = view.host.flatMap { scrollViews($0).max(by: { $0.bounds.width < $1.bounds.width }) }
    let frameItems = PageProbe.items.values.filter { $0.label.hasPrefix("bookmark:") || $0.label.hasPrefix("folder:") || $0.label == "Search bookmarks" }
    let wanted = Set(ids.prefix(6).map { "bookmark:\($0)" })
    let visible = frameItems.filter { $0.frame.maxY > 0 && $0.frame.minY < (view.window?.frame.height ?? 0) }
    let frames: [[String: Any]] = visible.filter { wanted.contains($0.label) || !$0.label.hasPrefix("bookmark:") }.prefix(12).map { ["label": $0.label, "x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] }
    let node = value.flatMap { model.nodes[$0] }
    let output: [String: Any] = ["count": ids.count, "first": ids.first as Any? ?? NSNull(), "folder": model.folderId as Any? ?? NSNull(),
      "query": model.query, "selected": model.selected.count, "frames": frames, "materialized": frameItems.count,
      "scrollY": listScroll?.contentView.bounds.minY as Any? ?? NSNull(),
      "visibleIds": visible.filter { $0.label.hasPrefix("bookmark:") }.map { String($0.label.dropFirst(9)) },
      "firstMaterialized": ids.first.map { id in visible.contains { $0.label == "bookmark:\(id)" } } ?? false,
      "item": node.map { ["id": $0.id, "title": $0.title, "parentId": $0.parentId as Any? ?? NSNull()] } as Any? ?? NSNull()]
    guard let data = try? JSONSerialization.data(withJSONObject: output) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devState() -> String {
    let pages: [[String: Any]] = live.allObjects.filter { $0.window != nil && !$0.kind.isEmpty }.map { view in
      var page: [String: Any] = ["kind": view.kind]
      if let id = view.internalTabId { page["tabId"] = id }
      switch view.kind {
      case "downloads":
        page["query"] = view.downloads.query
        page["shown"] = view.downloads.shown.map(\.id)
      case "history":
        page["query"] = view.history.query
        page["shown"] = view.history.shown
        page["selected"] = view.history.selected.sorted()
        page["clearOpen"] = view.history.clearOpen
      case "bookmarks":
        page["query"] = view.bookmarks.query
        page["shown"] = view.bookmarks.ids
        page["selected"] = view.bookmarks.selected
        page["folder"] = view.bookmarks.folderId ?? NSNull()
        page["undo"] = view.bookmarks.undoCount ?? NSNull()
      default: break
      }
      page["ax"] = axLines(view.host, depth: 0)
      page["frames"] = probeFrames()
      return page
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["pages": pages + NativeBookmarkForms.probeRows()]), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

  static func devHover(_ key: String?) {
    for view in live.allObjects where view.window != nil {
      view.history.devHover = key
      view.bookmarks.devHover = key
    }
  }

  static func probeFrames() -> [[String: Any]] {
    PageProbe.items.values.map { item in
      ["label": item.label, "x": item.frame.minX, "y": item.frame.minY, "width": item.frame.width, "height": item.frame.height]
    }
  }

  static func axLines(_ element: Any?, depth: Int) -> [String] {
    guard let element = element as? NSAccessibilityElementProtocol & NSObject, depth < 30 else { return [] }
    let role = (element as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "?"
    let label = (element as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
    var lines = ["\(String(repeating: " ", count: depth))\(role)\(label.isEmpty ? "" : ": \(label)")"]
    for child in (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? [] { lines += axLines(child, depth: depth + 1) }
    return lines
  }

  func setKind(_ next: String) {
    guard next != kind else { return }
    if kind == "history" { history.leaveScope() }
    kind = next
    bindBookmarkScope()
    bindDownloadsScope()
    host?.removeFromSuperview()
    host = nil
    if next == "history" {
      history = HistoryPageModel(catalog: NativeHistoryCatalog.catalog)
      history.onEvent = { [weak self] event in self?.send(event) }
    }
    let made: NSView? =
      switch next {
      case "downloads": NSHostingView(rootView: DownloadsPageView(model: downloads))
      case "history": NSHostingView(rootView: HistoryPageView(model: history, favicons: PageNetwork.favicons))
      case "bookmarks": NSHostingView(rootView: BookmarksPageView(model: bookmarks, favicons: PageNetwork.favicons))
      case "createProfile": NSHostingView(rootView: CreateProfileFormView(model: createProfile))
      case "calendarPreview": NSHostingView(rootView: LiveCardView(model: liveCard))
      case "meetingAlert": MeetingAlertFrameView(frame: .zero)
      default: nil
      }
    guard let made else { return }
    if let meeting = made as? MeetingAlertFrameView {
      meeting.onEvent = { [weak self] event in self?.send(event) }
      meeting.onHeight = { [weak self] height in self?.send(LiveCardEvent.height(Double(height))) }
    }
    made.frame = bounds
    made.autoresizingMask = [.width, .height]
    addSubview(made)
    host = made
    if !json.isEmpty { apply() }
  }

  func setState(_ next: String) {
    guard next != json else { return }
    json = next
    apply()
  }

  func setInlineTab(_ tabId: String?) {
    guard inlineTabId != tabId else { return }
    inline = true
    if let inlineListener { inlineStore?.unsubscribe(inlineListener) }
    inlineListener = nil
    inlineStore = nil
    inlineTabId = tabId
    bindInlinePage()
  }

  private func bindInlinePage() {
    guard inline else { return }
    if window != nil && inlineTabId != nil {
      if inlineLifecycle == nil {
        inlineLifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.refreshInlinePage() }
      }
    } else {
      if let inlineLifecycle { NativeStoreHandle.unsubscribeLifecycle(inlineLifecycle) }
      inlineLifecycle = nil
    }
    refreshInlinePage()
  }

  private func refreshInlinePage() {
    let store = window != nil && inlineTabId != nil && NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if inlineStore !== store {
      if let inlineListener { inlineStore?.unsubscribe(inlineListener) }
      inlineStore = store
      if let store, let tabId = inlineTabId {
        inlineListener = store.subscribe { [weak self, weak store] commit in
          guard commit.changes.tabs.upserted.contains(tabId) || commit.changes.tabs.removed.contains(tabId)
            || ThemeScopeProjection.mayChange(commit.changes) else { return }
          DispatchQueue.main.async {
            guard let self, let store, self.inlineStore === store else { return }
            self.refreshInlinePage()
          }
        }
      } else {
        inlineListener = nil
      }
    }
    if let inlineTabId, let state = store?.state {
      updateInternalPage(tabId: inlineTabId, state: state)
    } else {
      internalScope = nil
      internalTabId = nil
      scopeStore = nil
      historyToken = UUID().uuidString
      setKind("")
    }
  }

  func updateInternalPage(tabId: String, state: BrowserState) {
    let scope = window.flatMap { InternalScope(state: state, tabId: tabId, window: $0) }
    let store = NativeStoreHandle.store
    let ownership = NativeStoreHandle.ownershipGeneration
    if internalScope != scope || scopeStore !== store || scopeOwnership != ownership {
      scopeStore = store
      scopeOwnership = ownership
      let old = internalScope
      internalScope = scope
      historyToken = UUID().uuidString
      if kind == "history" {
        history.clearBusy = false
        history.clearOpen = false
      }
      if old?.profileId != scope?.profileId || old?.engineProfile != scope?.engineProfile { setKind("") }
    }
    internalTabId = tabId
    let next = scope?.destination.page.rawValue ?? ""
    setKind(next)
    guard let scope, let window = state.windows[scope.windowId] else { return }
    let dark = ThemeScopeProjection.project(state, windowId: window.id, pageProfileId: scope.profileId).dark
    let theme = PageTheme(dark: dark, tokens: [:])
    switch scope.destination.page {
    case .bookmarks:
      if bookmarks.theme != theme { bookmarks.theme = theme }
    case .downloads:
      if downloads.theme != theme { downloads.theme = theme }
    case .history:
      let profileName = state.profileOrder.count > 1
        ? (window.incognito ? "Incognito" : state.profiles[scope.profileId]?.name ?? state.profiles[state.settings.defaultProfileId]?.name)
        : nil
      history.setScope(profileId: scope.profileId, engineProfile: scope.engineProfile, profileName: profileName,
        query: scope.destination.query, theme: theme)
    }
    consumeClearDataRequest()
  }

  func focusSearch() {
    switch kind {
    case "downloads": downloads.focusRequest += 1
    case "history": history.focusRequest += 1
    case "bookmarks": bookmarks.focusRequest += 1
    default: break
    }
  }

  private func apply() {
    switch kind {
    case "createProfile": createProfile.apply(json: json)
    case "calendarPreview": liveCard.apply(json: json)
    case "meetingAlert": (host as? MeetingAlertFrameView)?.apply(json: json)
    default: break
    }
    consumeClearDataRequest()
  }

  private var downloadScope: DownloadScope? {
    guard kind == "downloads", NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state,
      let window, let tab = internalTabId.flatMap({ state.tabs[$0] }), ShellDrag.window(tab.windowId) === window,
      state.windows[tab.windowId]?.profileId == tab.profileId,
      InternalPageDestination(tab: tab)?.page == .downloads else { return nil }
    return DownloadScope(windowId: tab.windowId, profileId: tab.profileId)
  }

  private func bindDownloadsScope() {
    if kind == "downloads", window != nil {
      if downloadsLifecycle == nil {
        downloadsLifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.refreshDownloads() }
      }
    } else if let downloadsLifecycle {
      NativeStoreHandle.unsubscribeLifecycle(downloadsLifecycle)
      self.downloadsLifecycle = nil
    }
    refreshDownloads()
  }

  private func refreshDownloads() {
    let store = kind == "downloads" && window != nil && NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observedDownloadStore !== store {
      if let downloadsListener { observedDownloadStore?.unsubscribe(downloadsListener) }
      observedDownloadStore = store
      downloadsListener = store?.subscribe { [weak self, weak store] commit in
        let changes = commit.changes
        guard changes.downloads || !changes.windows.isEmpty || !changes.tabs.isEmpty || !changes.profiles.isEmpty else { return }
        DispatchQueue.main.async {
          guard let self, let store, self.observedDownloadStore === store else { return }
          self.refreshDownloads()
        }
      }
    }
    let scope = downloadScope
    if displayedDownloads != scope {
      displayedDownloads = scope
      downloads.downloads = []
    }
    let next = scope.flatMap { store?.state.visibleDownloads(in: $0.windowId) }?.map(DownloadRowState.init) ?? []
    if downloads.downloads != next { downloads.downloads = next }
  }

  private var currentHistoryScope: InternalScope? {
    guard kind == "history", !isHiddenOrHasHiddenAncestor, NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen,
      scopeOwnership == NativeStoreHandle.ownershipGeneration, let scopeStore, scopeStore === NativeStoreHandle.store,
      let window, let tabId = internalTabId,
      let scope = InternalScope(state: scopeStore.state, tabId: tabId, window: window), scope == internalScope else { return nil }
    return scope
  }

  private func send(_ event: HistoryPageEvent) {
    guard let scope = currentHistoryScope else { return }
    var info: [String: Any] = ["token": historyToken, "profileId": scope.profileId, "windowId": scope.windowId]
    switch event {
    case .open(let url, let mode):
      guard let data = try? JSONSerialization.data(withJSONObject: ["url": url, "mode": mode.rawValue]) else { return }
      _ = NativeWorkspaceCommands.perform("openBookmarkItems", arg: String(decoding: data, as: UTF8.self), windowId: scope.windowId)
      return
    case .remove(let urls):
      info["kind"] = "remove"
      info["urls"] = urls
    case .deleteSelected(let urls):
      info["kind"] = "deleteSelected"
      info["urls"] = urls
    case .clearData(let request):
      info["kind"] = "clearData"
      info["range"] = request.range
      info["history"] = request.history
      info["siteData"] = request.siteData
    }
    Self.historyAction(info)
  }

  private func bindBookmarkScope() {
    if kind == "bookmarks", window != nil {
      if bookmarkLifecycle == nil {
        bookmarkLifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.refreshBookmarkScope() }
      }
    } else if let bookmarkLifecycle {
      NativeStoreHandle.unsubscribeLifecycle(bookmarkLifecycle)
      self.bookmarkLifecycle = nil
    }
    refreshBookmarkScope()
  }

  private func observeBookmarkScope(_ store: Store?, tabId: String?, windowId: String?) {
    guard observedBookmarkStore !== store || observedBookmarkTab != tabId || observedBookmarkWindow != windowId else { return }
    if let bookmarkStoreListener { observedBookmarkStore?.unsubscribe(bookmarkStoreListener) }
    observedBookmarkStore = store
    observedBookmarkTab = tabId
    observedBookmarkWindow = windowId
    bookmarkStoreListener = store?.subscribe { [weak self, weak store] commit in
      let changes = commit.changes
      let tabChanged = tabId.map { changes.tabs.upserted.contains($0) || changes.tabs.removed.contains($0) } ?? false
      let windowChanged = windowId.map { changes.windows.upserted.contains($0) || changes.windows.removed.contains($0) } ?? false
      guard tabChanged || windowChanged || !changes.profiles.isEmpty || changes.settingsChanged.contains("defaultProfileId") else { return }
      DispatchQueue.main.async {
        guard let self, let store, self.observedBookmarkStore === store else { return }
        self.refreshBookmarkScope()
      }
    }
  }

  private func refreshBookmarkScope() {
    let store = kind == "bookmarks" && window != nil && NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    let tab = internalTabId.flatMap { store?.state.tabs[$0] }
    observeBookmarkScope(store, tabId: store == nil ? nil : internalTabId, windowId: tab?.windowId)
    if kind == "bookmarks", window == nil { return }
    guard let window, let tab, ShellDrag.window(tab.windowId) === window,
      let editing = NativeBookmarkEditing(windowId: tab.windowId),
      editing.store.state.windows[tab.windowId]?.profileId == tab.profileId,
      InternalPageDestination(tab: tab)?.page == .bookmarks else {
      if bookmarkEditing != nil { bookmarks.clearScope() }
      bookmarkEditing = nil
      return
    }
    if bookmarkEditing?.live != true || bookmarkEditing?.target != editing.target {
      bookmarks.setScope(profileId: editing.profile, engineProfile: editing.target.engine)
    }
    bookmarkEditing = editing
  }

  private func send(_ event: BookmarksPageEvent) {
    let scope = bookmarks.scopeGeneration
    refreshBookmarkScope()
    guard bookmarks.scopeGeneration == scope, window != nil, !isHiddenOrHasHiddenAncestor, let editing = bookmarkEditing else { return }
    let windowId = editing.windowId
    switch event {
    case .open(let id, let mode): NativeBookmarkCommands.openItem(id, mode: mode.rawValue, windowId: windowId)
    case .openAll(let id, let newWindow): NativeBookmarkCommands.openItem(id, mode: newWindow ? "window" : "tabs", folder: true, windowId: windowId)
    case .edit(let id): NativeBookmarkForms.edit(windowId: windowId, id: id)
    case .addGroup(let id):
      if let snapshot = editing.snapshot() { NativeBookmarkCommands.addFolderToSidebar(id, editing: editing, snapshot: snapshot) }
    case .restoreArc(let id): _ = NativeWorkspaceCommands.perform("restoreArcFolders", arg: id, windowId: windowId)
    case .delete(let ids):
      writeBookmarks([.init(method: "removeBookmarks", args: [JSONValue(ids)])], editing: editing, onSuccess: { model, receipt in
        if let removed = receipt.results.first { model.recordRemoval(removed) }
      })
    case .undo:
      guard let undo = bookmarks.beginUndo() else { return }
      writeBookmarks([.init(method: "restoreBookmarks", args: [undo.removed])], editing: editing,
        onError: { $0.finishUndo(undo, restored: false) }) { model, _ in model.finishUndo(undo, restored: true) }
    case .move(let ids, let drop, let listed):
      guard let snapshot = editing.snapshot(),
        let mutations = BookmarkPageEdits.moves(ids, to: drop, listed: listed), !mutations.isEmpty else { return }
      let nodes = snapshot.document["nodes"]?.object ?? [:]
      let parent: String
      var conditions: [BookmarkMutation] = []
      switch drop {
      case .into(let id): parent = id
      case .at(let id, _):
        parent = id
        conditions = [.init(method: "expectChildren", args: [.string(editing.profile), .string(id), JSONValue(listed)])]
      }
      guard nodes[parent]?["kind"] == "folder" else { return }
      let moving = Set(ids)
      var ancestors: Set<String> = []
      var cursor: String? = parent
      while let id = cursor {
        guard !moving.contains(id), ancestors.insert(id).inserted else { return }
        cursor = nodes[id]?["parentId"]?.string
      }
      var expected: JSONObject = [:]
      for id in ancestors.union(moving) {
        guard let node = nodes[id], !moving.contains(id) || node["parentId"]?.string != nil else { return }
        expected[id] = node
      }
      conditions.append(.init(method: "expectBookmarkNodes", args: [.object(expected)]))
      writeBookmarks(conditions + mutations, editing: editing, binding: snapshot.binding)
    case .addBookmark(let parent): NativeBookmarkForms.edit(windowId: windowId, id: nil, parent: parent)
    case .addFolder(let parent): NativeBookmarkForms.edit(windowId: windowId, id: nil, folder: true, parent: parent)
    case .importBookmarks: NativeImportWindow.open()
    }
  }

  private func writeBookmarks(_ mutations: [BookmarkMutation], editing: NativeBookmarkEditing, binding: BookmarkWriterBinding? = nil,
    onError: @escaping (BookmarksPageModel) -> Void = { _ in }, onSuccess: @escaping (BookmarksPageModel, BookmarkReceipt) -> Void = { _, _ in }
  ) {
    let tabId = internalTabId
    let pageScope = bookmarks.scopeGeneration
    let currentBinding = binding ?? (try? NativeBookmarkOwner.displayCurrent?.binding(profile: editing.profile))
    Task { [weak self] in
      @MainActor func model() -> BookmarksPageModel? {
        guard let self, internalTabId == tabId, bookmarks.scopeGeneration == pageScope, editing.live else { return nil }
        return bookmarks
      }
      do {
        let receipt = try await editing.write(mutations, binding: currentBinding)
        if let model = model() { onSuccess(model, receipt) }
      } catch {
        if let model = model() { onError(model) }
        editing.report(error)
      }
    }
  }

  private func send(_ event: CreateProfileEvent) {
    switch event {
    case .create(let name, let color, let shareWith): onPageEvent(["kind": "create", "name": name, "color": color, "shareWith": shareWith ?? NSNull()])
    case .cancel: onPageEvent(["kind": "cancel"])
    }
  }

  private func send(_ event: LiveCardEvent) {
    switch event {
    case .height(let height): onPageEvent(["kind": "height", "height": height])
    case .activate: onPageEvent(["kind": "activate"])
    case .join(let id, let all): onPageEvent(["kind": "join", "id": id, "all": all])
    case .refresh: onPageEvent(["kind": "refresh"])
    case .connect: onPageEvent(["kind": "connect"])
    case .dismiss: onPageEvent(["kind": "dismiss"])
    case .view: onPageEvent(["kind": "view"])
    }
  }
}

private final class PagesEventSink: @unchecked Sendable {
  weak var module: PagesModule?
  init(_ module: PagesModule) { self.module = module }
}

#if SOLARA_PROBES
@MainActor
public extension PagesRead {
  static func snapshot() -> [[String: Any]] {
    guard let data = NativePageView.devState().data(using: .utf8),
      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pages = state["pages"] as? [[String: Any]] else { return [] }
    var result: [[String: Any]] = []
    for page in pages.prefix(16) {
      var row: [String: Any] = [:]
      for key in ["kind", "query", "shown", "selected", "clearOpen", "folder", "undo", "name", "url", "valid", "frames"] {
        if let value = page[key] { row[key] = value }
      }
      result.append(row)
    }
    return result
  }
}
#endif
