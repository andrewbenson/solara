import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import Synchronization

@MainActor
enum PanePrompts {
  struct Shown {
    let tabId: String
    let kind: PanePromptKind
    let key: String
    let receipt: String
    let json: String
  }

  nonisolated static let kind = "panePrompts"
  static let topic = "pane.prompts"
  private static var started = false
  private static weak var observedStore: Store?
  private static var storeSubscription: Int?
  private struct Source {
    let identity: PageIdentity
    let profileId: String
    var browserId: Int?
  }

  private static var bindings: [String: Source] = [:]
  private static var documentRevisions: [String: UUID] = [:]
  private static var pendingPermissions: Set<String> = []
  private static var refreshing: Set<String> = []
  private nonisolated static let popupCountSnapshot = Mutex<[String: Int]>([:])
  private nonisolated static let permissionTabs = Mutex<Set<String>>([])
  static var popupCountsChanged: (([String: Int]) -> Void)?
  private static var pages: [String: PanePromptPage] = [:]
  private static var windows: [String: [String: Any]] = [:]
  private static var browsers = PaneBrowsers()
  private static var windowOfTab: [String: String] = [:]
  private struct EngineOffer {
    let id = UUID().uuidString
    let scope: PageActionScope
    let site: String
    let host: String
    var remember = false
    var canRemember: Bool { !Ids.isIncognitoProfile(scope.tab.profileId) }
  }

  private static var engineOffers: [String: EngineOffer] = [:]
  private static var declinedSites: [String: Set<String>] = [:]
  private static var automaticMoves: [String: EngineOffer] = [:]
  private static var movedToasts: [String: (id: Int, window: String, site: String, profile: String)] = [:]
  private static var nextMoveToast = -1_000_000
  private static var cliShown: [String: Bool] = [:]
  private static var cliRevealed: Set<String> = []
  private static var cliHideUntil: [String: TimeInterval] = [:]
  static let cliHideDelay: TimeInterval = 0.25
  private(set) static var activatedAt: TimeInterval = 0

  static func start() {
    guard !started else { return }
    started = true
    TabSleepPermissionFeed.pending = { tabId in
      guard active(tabId) != nil, let browserId = NativeStoreHandle.store?.pageFacts(tabId)?.ready?.browserId,
        browsers.tab(browserId) == tabId else { return nil }
      return !(pages[tabId]?.permissions.isEmpty ?? true)
    }
    TabSleepPermissionFeed.coversPages = { TabPoolHost.available }
    TabPoolHost.shared.pageEventObservers.append { tabId, name, payload in
      guard ["onPasswordPrompt", "onAutofillPrompt"].contains(name), let binding = current(tabId), owns(tabId) else { return }
      pageEvent(binding, name, payload)
    }
    PageIssuer.consumePromptEvent = receive
    PageIssuer.lifecycleObservers.append { issuer, binding, name, payload in
      if name == "onPageMessage", payload["kind"] == "drm", issuer.store === observedStore {
        offerWebKit(binding)
        return
      }
      guard ["onReady", "onNavigationChange", "onDiscarded", "onCrashed", "onUnresponsive", "onResponsive", "onWindowClose", "onPagePhysicalReplaced"].contains(name),
        issuer.store === observedStore else { return }
      if name == "onWindowClose" || name == "onPagePhysicalReplaced" { retire(binding.tabId); return }
      guard current(binding.tabId) === binding else { return }
      pageEvent(binding, name, PageValue(json: payload).foundation as? [String: Any] ?? [:])
    }
    PageRegistry.shared.observe { event in
      guard case .retired(let registration) = event,
        bindings[registration.tabID]?.identity.registrationGeneration == registration.registrationGeneration else { return }
      retire(registration.tabID)
    }
    _ = NativeStoreHandle.subscribeLifecycle { reconcileStore() }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let id = ShellDrag.windowId(of: window) else { return }
        for tabId in Array(windowOfTab.keys) where windowOfTab[tabId] == id {
          if let current = TabPoolHost.shared.windowOf(tabId), current != id { continue }
          retire(tabId)
        }
      }
    }
    SolaraCoreEventTaps.observers.append { name, payload in coreEvent(name, payload) }
    SolaraCorePromptAnswers.installEventTap()
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { activatedAt = ProcessInfo.processInfo.systemUptime }
      }
    }
    _ = SettingsJS.shared.observe(topic) { value in applyWindows(value) }
    applyWindows(SettingsJS.shared.latestValue(topic))
    NativePaneOverlays.registerInline()
  }

  static func owns(_ tabId: String) -> Bool { started && TabPoolHost.shared.pageView(tabId) != nil }

  private static func current(_ tabId: String) -> PageHostBinding? {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen,
      let store = observedStore, let issuer = PageIssuer.shared, issuer.store === store,
      let binding = issuer.binding(tabId: tabId), issuer.isCurrent(binding),
      let tab = store.state.tabs[tabId], let window = store.state.windows[tab.windowId],
      window.keptOnClose != true,
      !store.memory.closingWindows.contains(tab.windowId) else { return nil }
    return binding
  }

  private static func active(_ tabId: String) -> PageHostBinding? {
    guard let binding = current(tabId), let source = bindings[tabId], source.identity == binding.identity,
      source.profileId == observedStore?.state.tabs[tabId]?.profileId else { return nil }
    return binding
  }

  private static func profileIsShown(_ tabId: String, _ windowId: String) -> Bool {
    guard let state = observedStore?.state, let tab = state.tabs[tabId], let window = state.windows[windowId] else { return false }
    return tab.windowId == windowId && tab.profileId == window.profileId
  }

  private static func webView(_ binding: PageHostBinding) -> SolaraCoreWebView? {
    let view = binding.host == .pooled ? TabPoolHost.shared.pageView(binding.tabId) : binding.owner as? NSView
    guard let web = NativeOmniboxExtensionActions.page(in: view), web.transferKey == binding.tabId,
      Int(web.browserId) == observedStore?.pageFacts(binding.tabId)?.ready?.browserId else { return nil }
    return web
  }

  private static func reconcileStore() {
    let next = NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen ? NativeStoreHandle.store : nil
    guard observedStore !== next else { return }
    if let storeSubscription { observedStore?.unsubscribe(storeSubscription) }
    observedStore = nil
    automaticMoves = [:]
    declinedSites = [:]
    for id in Array(movedToasts.keys) { hideMoveToast(id) }
    for tabId in Array(engineOffers.keys) { clearEngineOffer(tabId) }
    for tabId in Array(bindings.keys) { retire(tabId) }
    let orphaned = browsers.drain()
    for request in orphaned { SolaraCorePromptAnswers.permission(request.id, result: "dismiss", remember: false) }
    observedStore = next
    storeSubscription = next?.subscribe { commit in
      guard !commit.changes.tabs.isEmpty || !commit.changes.windows.isEmpty || !commit.changes.profiles.isEmpty else { return }
      DispatchQueue.main.async { tabsMoved() }
    }
  }

  private static func receive(_ issuer: PageIssuer, _ binding: PageHostBinding, _ name: String, _ payload: JSONValue) -> Bool {
    switch name {
    case "onPopupBlocked", "onDocumentCommitted", "onExternalApp":
      if name == "onDocumentCommitted" { DispatchQueue.main.async { NativeSiteControls.shared.refresh() } }
      if issuer.store === observedStore, current(binding.tabId) === binding {
        pageEvent(binding, name, PageValue(json: payload).foundation as? [String: Any] ?? [:])
      } else if name == "onExternalApp", payload["closed"]?.bool != true, let id = payload["id"]?.string {
        SolaraCorePromptAnswers.externalApp(id, open: false, remember: false)
      }
      return true
    case "onCommand":
      if issuer.store === observedStore, active(binding.tabId) === binding, payload["command"]?.string == "escape",
        popupShown(binding.tabId) { closePopups(binding.tabId); return true }
      return false
    default: return false
    }
  }

  private static func tabs(in windowId: String, where test: (PanePromptPage) -> Bool) -> [String] {
    pages.compactMap { tabId, page in test(page) && active(tabId) != nil && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func sadTabs(in windowId: String) -> [String] { tabs(in: windowId) { $0.sadMode != nil } }

  static func holds(_ windowId: String) -> Bool { !tabs(in: windowId) { $0.shown != PanePromptPage().shown }.isEmpty }

  static func draws(_ windowId: String) -> Bool {
    if holds(windowId) || !selections(in: windowId).isEmpty { return true }
    guard let window = windows[windowId] else { return false }
    if engineOffers.values.contains(where: { $0.scope.tab.windowId == windowId }) { return true }
    return ((window["theme"] as? [String: Any])?["cli"] as? [String: Any])?["shown"] as? Bool == true || (cliHideUntil[windowId] ?? 0) > ProcessInfo.processInfo.systemUptime
  }

  private static func tabsMoved() {
    for (id, offer) in engineOffers where NativeEngineCommands.pageScope(id) != offer.scope || !profileIsShown(id, offer.scope.tab.windowId) {
      clearEngineOffer(id)
    }
    for id in automaticMoves.keys where observedStore?.state.tabs[id] == nil { automaticMoves[id] = nil }
    for (id, toast) in movedToasts {
      guard let tab = observedStore?.state.tabs[id], tab.windowId == toast.window, tab.profileId == toast.profile, profileIsShown(id, toast.window),
        EngineCommand.site(tab.url) == toast.site else { hideMoveToast(id); continue }
    }
    if let state = observedStore?.state {
      for profile in declinedSites.keys where Ids.isIncognitoProfile(profile) && !state.windows.values.contains(where: { $0.profileId == profile }) {
        declinedSites[profile] = nil
      }
    }
    for tabId in Array(bindings.keys) {
      guard active(tabId) != nil else { retire(tabId); continue }
      let now = TabPoolHost.shared.windowOf(tabId)
      guard now != windowOfTab[tabId] else { continue }
      if let old = windowOfTab[tabId] { refresh(old) }
      changed(tabId)
    }
  }

  private static func retire(_ tabId: String) {
    let old = pages.removeValue(forKey: tabId)
    permissionTabs.withLock { _ = $0.remove(tabId) }
    bindings[tabId] = nil
    documentRevisions[tabId] = nil
    browsers.gone(tabId)
    clearEngineOffer(tabId)
    if let windowId = windowOfTab.removeValue(forKey: tabId) { refresh(windowId) }
    if let old {
      cancelRemoved(old, leaving: PanePromptPage())
      if !old.popups.isEmpty { closePopups(tabId) }
    }
    publishPopupCounts()
  }

  private static func pageEvent(_ binding: PageHostBinding, _ name: String, _ payload: [String: Any]) {
    let tabId = binding.tabId
    guard let profileId = observedStore?.state.tabs[tabId]?.profileId else { return }
    let ready = name == "onReady" ? (payload["browserId"] as? NSNumber)?.intValue : nil
    let old = bindings[tabId]
    let replacedBrowser = ready != nil && old?.browserId != nil && ready != old?.browserId
    if old?.identity != binding.identity || old?.profileId != profileId || replacedBrowser {
      retire(tabId)
      bindings[tabId] = Source(identity: binding.identity, profileId: profileId)
      documentRevisions[tabId] = UUID()
      windowOfTab[tabId] = TabPoolHost.shared.windowOf(tabId)
    }
    if let browserId = ready {
      bindings[tabId]?.browserId = browserId
      for found in browsers.ready(tabId, browserId: browserId) { enqueue(found.tabId, found.request) }
    }
    if ["onDocumentCommitted", "onDiscarded", "onCrashed"].contains(name) {
      documentRevisions[tabId] = UUID()
      clearEngineOffer(tabId)
    } else if let offer = engineOffers[tabId], NativeEngineCommands.pageScope(tabId) != offer.scope {
      clearEngineOffer(tabId)
    }
    var page = pages[tabId] ?? PanePromptPage()
    let previous = page
    guard page.take(name, payload) else { return }
    setPage(tabId, page)
    cancelRemoved(previous, leaving: page)
    if previous.popups != page.popups {
      publishPopupCounts()
      if page.popups.isEmpty { closePopups(tabId) }
      else if previous.popups.isEmpty, let popup = page.popups.first { checkPopupSetting(binding, popup) }
    }
    if page.shown != previous.shown { changed(tabId) }
  }

  private static func cancelRemoved(_ old: PanePromptPage, leaving page: PanePromptPage) {
    if let request = old.externalApp, request.id != page.externalApp?.id {
      SolaraCorePromptAnswers.externalApp(request.id, open: false, remember: false)
    }
    if let chooser = old.chooser, chooser.id != page.chooser?.id {
      SolaraCoreHost.deviceChooser(Int32(chooser.id), action: "cancel")
    }
    for request in old.permissions where !page.permissions.contains(where: { $0.id == request.id }) {
      pendingPermissions.remove(request.id)
      SolaraCorePromptAnswers.permission(request.id, result: "dismiss", remember: false)
    }
  }

  private static func checkPopupSetting(_ binding: PageHostBinding, _ popup: PaneBlockedPopup) {
    let tabId = binding.tabId
    let identity = binding.identity
    let revision = NativeSelectionTools.zoomRevision(tabId)
    SolaraCoreServices.siteSettings(profile: binding.profile, origin: popup.origin) { raw in
      let ask = (raw["popups"] as? [String: Any])?["isDefault"] as? Bool ?? true
      DispatchQueue.main.async {
        guard active(tabId)?.identity == identity, pages[tabId]?.popups.first == popup,
          NativeSelectionTools.zoomRevision(tabId) == revision, ask else { return }
        _ = NativeSelectionTools.setPopover(tabId, value: "popups")
      }
    }
  }

  nonisolated static func popupCounts() -> [String: Int] { popupCountSnapshot.withLock { $0 } }

  nonisolated static func permissionPending(_ tabId: String) -> Bool {
    permissionTabs.withLock { $0.contains(tabId) }
  }

  private static func publishPopupCounts() {
    let counts = pages.compactMapValues { $0.popups.isEmpty ? nil : $0.popups.count }
    let changed = popupCountSnapshot.withLock {
      guard $0 != counts else { return false }
      $0 = counts
      return true
    }
    if changed { popupCountsChanged?(counts) }
  }

  private static func popupShown(_ tabId: String) -> Bool {
    NativeSelectionTools.popoverSnapshot()[tabId] == "popups" && pages[tabId]?.popups.isEmpty == false
  }

  private static func closePopups(_ tabId: String) {
    if NativeSelectionTools.popoverSnapshot()[tabId] == "popups" { _ = NativeSelectionTools.setPopover(tabId, value: nil) }
  }

  static func selections(in windowId: String) -> [(tabId: String, state: SelectionBarState)] {
    guard let window = windows[windowId], let theme = window["theme"] as? [String: Any],
      let store = NativeStoreHandle.store else { return [] }
    return store.state.tabs.values.compactMap { tab in
      guard owns(tab.id), tab.windowId == windowId, let state = NativeSelectionTools.state(tab.id, theme: theme) else { return nil }
      return (tab.id, state)
    }
  }

  private static func anchoredTab(_ browserId: Int) -> String? {
    if let tabId = browsers.tab(browserId), active(tabId) != nil { return tabId }
    guard let store = observedStore, let tabId = store.state.tabs.keys.first(where: {
      store.pageFacts($0)?.ready?.browserId == browserId && current($0) != nil
    }), let binding = current(tabId) else { return nil }
    pageEvent(binding, "onReady", ["browserId": browserId])
    return browsers.tab(browserId)
  }

  static func coreEvent(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "permission":
      guard let request = PanePermissionRequest(payload), request.browserId != 0 else { return }
      guard observedStore != nil, !NativeStoreHandle.frozen else {
        SolaraCorePromptAnswers.permission(request.id, result: "dismiss", remember: false)
        return
      }
      guard let tabId = anchoredTab(request.browserId) ?? browsers.route(request) else {
        for dropped in browsers.overflow() {
          SolaraCorePromptAnswers.permission(dropped.id, result: "dismiss", remember: false)
        }
        return
      }
      enqueue(tabId, request)
    case "permissionDismissed":
      guard let id = payload["id"] as? String else { return }
      browsers.dismissed(id)
      pendingPermissions.remove(id)
      for tabId in Array(pages.keys) {
        guard var page = pages[tabId], page.dropPermission(id) else { continue }
        update(tabId, page)
      }
    case "deviceChooser":
      guard let chooser = PaneDeviceChooser(payload) else { return }
      guard let tabId = anchoredTab(chooser.browserId), active(tabId) != nil,
        bindings[tabId]?.browserId == chooser.browserId else {
        if chooser.open { SolaraCoreHost.deviceChooser(Int32(chooser.id), action: "cancel") }
        return
      }
      var page = pages[tabId] ?? PanePromptPage()
      let previous = page
      guard page.chooserEvent(chooser) else { return }
      update(tabId, page)
      if chooser.open { cancelRemoved(previous, leaving: page) }
    default: break
    }
  }

  private static func enqueue(_ tabId: String, _ request: PanePermissionRequest) {
    guard active(tabId) != nil else {
      SolaraCorePromptAnswers.permission(request.id, result: "dismiss", remember: false)
      return
    }
    var page = pages[tabId] ?? PanePromptPage()
    page.enqueue(request)
    update(tabId, page)
  }

  @discardableResult
  static func chooserAction(_ windowId: String, _ tabId: String, _ chooserId: Int, _ event: DeviceChooserEvent) -> Bool {
    guard active(tabId) != nil, profileIsShown(tabId, windowId), var page = pages[tabId],
      let chooser = page.chooser, chooser.id == chooserId, chooser.browserId == bindings[tabId]?.browserId else { return false }
    let id = Int32(chooser.id)
    switch event {
    case .select(let option):
      guard chooser.options.contains(where: { $0.id == option }) else { return false }
      page.chooserSelected = option
      update(tabId, page)
    case .choose(let option):
      guard let choice = chooser.choice(option, selected: nil) else { return false }
      SolaraCoreHost.deviceChooser(id, select: Int32(choice))
    case .cancel:
      guard page.answerChooser() else { return false }
      update(tabId, page)
      SolaraCoreHost.deviceChooser(id, action: "cancel")
    case .refresh: SolaraCoreHost.deviceChooser(id, action: "refresh")
    case .openSettings: SolaraCoreHost.deviceChooser(id, action: "settings")
    }
    return true
  }

  static func choosers(in windowId: String, paneWidth: (String) -> Double?) -> [(tabId: String, id: Int, json: String)] {
    guard let window = windows[windowId], let look = (window["theme"] as? [String: Any])?["prompt"] as? [String: Any] else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    return tabs(in: windowId, where: { $0.chooser != nil }).sorted().compactMap { tabId in
      guard profileIsShown(tabId, windowId), let page = pages[tabId], let chooser = page.chooser, panes[tabId]?["newTabShown"] as? Bool != true else { return nil }
      let left = PanePromptSpecs.promptLeft(urlLeft: urlLeft(tabId) ?? 0, paneWidth: paneWidth(tabId) ?? 0, width: PanePromptSpecs.deviceChooserWidth)
      let spec = PanePromptSpecs.deviceChooser(chooser, selected: page.chooserSelected, product: Bundle.main.productName, left: left)
      return encode(spec.merging(look) { _, theme in theme }).map { (tabId, chooser.id, $0) }
    }
  }

  static func sadTabAction(_ windowId: String, _ tabId: String, _ action: SadTabAction) {
    if var page = pages[tabId] {
      if action == .reload { page.crashed = false } else { page.unresponsive = false }
      pages[tabId] = page
      changed(tabId)
    }
    js("pane.sadTab", windowId, tabId, action.rawValue)
  }

  static func sadTab(_ windowId: String, _ tabId: String) -> SadTabState? {
    guard owns(tabId), let mode = pages[tabId]?.sadMode, let theme = windows[windowId]?["theme"] as? [String: Any] else { return nil }
    var object = theme
    object["mode"] = mode.rawValue
    return encode(object).flatMap(SadTabState.decode)
  }

  static func clearEngineOffer(_ tabId: String) {
    if let offer = engineOffers.removeValue(forKey: tabId) { refresh(offer.scope.tab.windowId) }
  }

  private static func offerWebKit(_ binding: PageHostBinding) {
    let id = binding.tabId
    guard binding.engine == .chromium, let scope = NativeEngineCommands.pageScope(id), scope.identity == binding.identity,
      profileIsShown(id, scope.tab.windowId), let store = observedStore, let site = EngineCommand.site(scope.tab.url),
      let hostname = URL(string: site)?.host, declinedSites[scope.tab.profileId]?.contains(site) != true,
      automaticMoves[id]?.scope != scope else { return }
    let host = hostname.hasPrefix("www.") ? String(hostname.dropFirst(4)) : hostname
    let offer = EngineOffer(scope: scope, site: site, host: host)
    switch store.chosenPageEngine(for: scope.tab.url, in: store.state) {
    case "chromium": return
    case "webkit":
      automaticMoves[id] = offer
      DispatchQueue.main.async {
        guard automaticMoves[id]?.id == offer.id else { return }
        guard NativeEngineCommands.pageScope(id) == scope else { automaticMoves[id] = nil; return }
        NativeEngineCommands.request(tabId: id, action: "open", options: ["engine": "webkit", "automatic": true]) { moved in
          guard automaticMoves[id]?.id == offer.id else { return }
          automaticMoves[id] = nil
          if moved { showMoveToast(offer) }
          else if NativeEngineCommands.pageScope(id) == scope { declinedSites[scope.tab.profileId, default: []].insert(site) }
        }
      }
    default:
      guard engineOffers[id]?.scope != scope else { return }
      engineOffers[id] = offer
      refresh(scope.tab.windowId)
    }
  }

  private static func showMoveToast(_ offer: EngineOffer) {
    let tab = offer.scope.tab
    hideMoveToast(tab.id)
    nextMoveToast -= 1
    let id = nextMoveToast
    movedToasts[tab.id] = (id, tab.windowId, offer.site, tab.profileId)
    NativeSplitChrome.showNativeToast(.init(id: id, title: "Opened in WebKit for protected video",
      message: "\(offer.host) plays here with FairPlay. WebKit keeps its own sign-ins.", icon: "play.rectangle", action: "Move Back"),
      windowId: tab.windowId) {
        guard movedToasts[tab.id]?.id == id, let current = NativeEngineCommands.pageScope(tab.id),
          current.tab.windowId == tab.windowId, current.tab.profileId == tab.profileId,
          EngineCommand.site(current.tab.url) == offer.site, profileIsShown(tab.id, tab.windowId) else { return }
        hideMoveToast(tab.id)
        NativeEngineCommands.request(tabId: tab.id, action: "open", options: ["engine": "chromium", "rule": "chromium"]) { _ in }
      }
  }

  private static func hideMoveToast(_ tabId: String) {
    guard let toast = movedToasts.removeValue(forKey: tabId) else { return }
    NativeSplitChrome.hideNativeToast(toast.id, windowId: toast.window)
  }

  static func prompts(in windowId: String, paneWidth: (String) -> Double?) -> [Shown] {
    guard let window = windows[windowId], let look = (window["theme"] as? [String: Any])?["prompt"] as? [String: Any] else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    var shown: [Shown] = []
    let asking = Set(tabs(in: windowId, where: { $0.password != nil || $0.autofill != nil || $0.externalApp != nil || $0.permission != nil || !$0.popups.isEmpty }))
    for tabId in asking.union(engineOffers.compactMap { $0.value.scope.tab.windowId == windowId ? $0.key : nil }).sorted() {
      guard let binding = current(tabId) else { continue }
      let page = active(tabId) === binding ? pages[tabId] ?? PanePromptPage() : PanePromptPage()
      let pane = panes[tabId] ?? [:]
      func add(_ kind: PanePromptKind, _ key: String, _ spec: [String: Any]) {
        let receipt = Self.receipt(binding, kind == .popups ? popupKey(tabId, key) : key)
        if let json = encode(spec.merging(look) { _, theme in theme }) {
          shown.append(Shown(tabId: tabId, kind: kind, key: key, receipt: receipt, json: json))
        }
      }
      if let prompt = page.password { add(.password, prompt.key, PanePromptSpecs.password(prompt, chosen: page.chosenUsername)) }
      if let prompt = page.autofill { add(.autofill, prompt.key, PanePromptSpecs.autofill(prompt)) }
      let newTabShown = pane["newTabShown"] as? Bool == true
      func left(_ width: Double) -> Double {
        PanePromptSpecs.promptLeft(urlLeft: (pane["urlLeft"] as? NSNumber)?.doubleValue ?? 0, paneWidth: paneWidth(tabId) ?? 0, width: width)
      }
      if let request = page.externalApp, profileIsShown(tabId, windowId), !newTabShown {
        add(.externalApp, request.key, PanePromptSpecs.externalApp(request, always: page.alwaysOpen, left: left(PanePromptSpecs.externalAppWidth)))
      }
      if let request = page.permission, !newTabShown {
        add(.permission, request.key, PanePromptSpecs.permission(request, left: left(PanePromptSpecs.permissionWidth)))
      }
      if popupShown(tabId), let first = page.popups.first,
        let popups = PanePromptSpecs.popups(["side": pane["popupSide"] ?? "right", "list": page.popups.map(\.payload)]) {
        add(.popups, first.id, popups.spec)
      }
      if let offer = engineOffers[tabId], NativeEngineCommands.pageScope(tabId) == offer.scope, profileIsShown(tabId, windowId), !newTabShown {
        let spec = PanePromptSpecs.engineOffer(host: offer.host, canRemember: offer.canRemember, remember: offer.remember,
          product: Bundle.main.productName, left: left(PanePromptSpecs.externalAppWidth))
        add(.engineOffer, offer.id, spec)
      }
    }
    return shown
  }

  static func urlLeft(_ tabId: String) -> Double? {
    guard let windowId = TabPoolHost.shared.windowOf(tabId), let panes = windows[windowId]?["panes"] as? [String: [String: Any]] else { return nil }
    return (panes[tabId]?["urlLeft"] as? NSNumber)?.doubleValue
  }

  private static func receipt(_ binding: PageHostBinding, _ key: String) -> String {
    "\(binding.sessionGeneration):\(key)"
  }

  private static func popupKey(_ tabId: String, _ id: String) -> String {
    "\(id):\(NativeSelectionTools.zoomRevision(tabId))"
  }

  static func promptEvent(_ windowId: String, _ tabId: String, _ kind: PanePromptKind, _ shown: String, _ event: PromptEvent) {
    guard let binding = current(tabId), profileIsShown(tabId, windowId) else { return }
    if kind == .engineOffer {
      guard var offer = engineOffers[tabId], shown == receipt(binding, offer.id),
        NativeEngineCommands.pageScope(tabId) == offer.scope,
        NativePaneOverlays.promptSlot(windowId, tabId) != nil else { return }
      switch event {
      case .toggle(let on):
        guard offer.canRemember else { return }
        offer.remember = on
        engineOffers[tabId] = offer
        refresh(windowId)
      case .button("webkit"):
        clearEngineOffer(tabId)
        NativeEngineCommands.request(tabId: tabId, action: "open", options: ["engine": "webkit", "rule": "webkit"]) { _ in }
      case .button("stay"), .close:
        declinedSites[offer.scope.tab.profileId, default: []].insert(offer.site)
        if case .button("stay") = event, offer.remember, offer.canRemember, let store = observedStore {
          try? NativeEngineCommands.remember("chromium", url: offer.site, store: store)
        }
        clearEngineOffer(tabId)
      default: break
      }
      return
    }
    guard active(tabId) === binding, var page = pages[tabId] else { return }
    switch kind {
    case .password:
      guard let prompt = page.password, shown == receipt(binding, prompt.key) else { return }
      if case .choice(let name) = event {
        page.chosenUsername = name
        return update(tabId, page)
      }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      let username = page.chosenUsername ?? prompt.username
      page.password = nil
      page.chosenUsername = nil
      update(tabId, page)
      js("pane.password", windowId, tabId, action, username, prompt.key)
    case .autofill:
      guard let prompt = page.autofill, shown == receipt(binding, prompt.key) else { return }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      page.autofill = nil
      update(tabId, page)
      js("pane.autofill", windowId, tabId, prompt.id, action)
    case .externalApp:
      guard let request = page.externalApp, shown == receipt(binding, request.key) else { return }
      if case .toggle(let on) = event {
        guard request.remember != nil else { return }
        page.alwaysOpen = on
        return update(tabId, page)
      }
      let open: Bool
      switch event {
      case .button("open") where request.app != nil: open = true
      case .button("cancel"), .button("ok"), .close: open = false
      default: return
      }
      let remember = open && page.alwaysOpen
      page.clearExternalApp()
      update(tabId, page)
      SolaraCorePromptAnswers.externalApp(request.id, open: open, remember: remember)
    case .permission:
      guard let request = page.permission, request.browserId == bindings[tabId]?.browserId, shown == receipt(binding, request.key),
        let result = answer(event) else { return }
      answerPermission(tabId, windowId: windowId, request: request, identity: binding.identity, result: result)
    case .popups:
      guard let first = page.popups.first, shown == receipt(binding, popupKey(tabId, first.id)), popupShown(tabId) else { return }
      if case .row(let id) = event, page.popups.contains(where: { $0.id == id }), let web = webView(binding) {
        page.popups.removeAll { $0.id == id }
        update(tabId, page)
        publishPopupCounts()
        if page.popups.isEmpty { closePopups(tabId) }
        web.openBlockedPopup(id, always: false)
        return
      }
      guard let action = answer(event), ["deny", "once", "allow", "dismiss"].contains(action) else { return }
      closePopups(tabId)
      if action == "dismiss" { return }
      let list = page.popups
      page.popups = []
      update(tabId, page)
      publishPopupCounts()
      if action == "deny" {
        SolaraCoreServices.setSiteSetting("block", profile: binding.profile, origin: first.origin, type: "popups")
      } else if let web = webView(binding) {
        let document = documentRevisions[tabId]
        for popup in list {
          guard active(tabId) === binding, profileIsShown(tabId, windowId), documentRevisions[tabId] == document, pages[tabId]?.pageKey == page.pageKey else { break }
          web.openBlockedPopup(popup.id, always: action == "allow")
        }
      }
    case .engineOffer: break
    }
  }

  private static func answer(_ event: PromptEvent) -> String? {
    switch event {
    case .button(let action): action
    case .close: "dismiss"
    default: nil
    }
  }

  private static func answerPermission(_ tabId: String, windowId: String, request: PanePermissionRequest, identity: PageIdentity, result: String) {
    guard ["accept", "deny", "dismiss"].contains(result), pendingPermissions.insert(request.id).inserted else { return }
    if result == "accept", request.permissions.contains("notifications") {
      Task { @MainActor in
        let allowed = await ShellLiveNotifications.requestCalendarAlertPermission()
        finishPermission(tabId, windowId: windowId, request: request, identity: identity, result: allowed ? result : "dismiss")
      }
    } else {
      finishPermission(tabId, windowId: windowId, request: request, identity: identity, result: result)
    }
  }

  private static func finishPermission(_ tabId: String, windowId: String, request: PanePermissionRequest, identity: PageIdentity, result: String) {
    guard pendingPermissions.remove(request.id) != nil, active(tabId)?.identity == identity,
      request.browserId == bindings[tabId]?.browserId,
      var page = pages[tabId], page.permission == request else { return }
    let result = profileIsShown(tabId, windowId) ? result : "dismiss"
    _ = page.dropPermission(request.id)
    update(tabId, page)
    SolaraCorePromptAnswers.permission(request.id, result: result, remember: result != "dismiss")
  }

  #if DEBUG
  static func devFixture(_ tabId: String, name: String, payload: [String: Any]) -> Bool {
    guard let binding = current(tabId) else { return false }
    if name == "onPageMessage", payload["kind"] as? String == "drm", let issuer = PageIssuer.shared,
      let data = try? JSONSerialization.data(withJSONObject: payload), let value = try? JSONValue.parse(data) {
      return issuer.reserveEvent(binding, name: name, payload: value) != nil
    }
    guard ["onExternalApp", "onPopupBlocked", "onDocumentCommitted"].contains(name) else { return false }
    pageEvent(binding, name, payload)
    return true
  }

  static func devState(_ tabId: String) -> String {
    let offer = engineOffers[tabId].flatMap { offer in NativeEngineCommands.pageScope(tabId) == offer.scope ? offer : nil }
    let page = active(tabId) == nil ? nil : pages[tabId]
    guard page != nil || offer != nil else { return "{}" }
    let pageState = page ?? PanePromptPage()
    var data: [String: Any] = ["popups": pageState.popups.map(\.payload)]
    if let offer {
      data["engineOffer"] = ["id": offer.id, "canRemember": offer.canRemember]
    }
    if let prompt = pageState.externalApp {
      data["externalApp"] = ["id": prompt.id, "app": prompt.app as Any? ?? NSNull(), "remember": prompt.remember as Any? ?? NSNull(),
        "origin": prompt.origin as Any? ?? NSNull(), "hasIcon": prompt.icon != nil]
    }
    if let prompt = pageState.permission {
      data["permission"] = ["id": prompt.id, "origin": prompt.origin, "permissions": prompt.permissions, "browserId": prompt.browserId]
    }
    if let chooser = pageState.chooser {
      data["deviceChooser"] = ["id": chooser.id, "title": chooser.title, "unauthorized": chooser.unauthorized,
        "options": chooser.options.map { ["optionId": $0.id, "name": $0.name] },
        "optionCount": chooser.options.count, "refreshing": chooser.refreshing]
    }
    return encode(data) ?? "{}"
  }

  static func devAnswer(_ tabId: String, kind: String, id: String, action: String, option: String) -> Bool {
    if kind == "engineOffer" {
      guard let offer = engineOffers[tabId], offer.id == id, let binding = current(tabId),
        NativeEngineCommands.pageScope(tabId) == offer.scope else { return false }
      promptEvent(offer.scope.tab.windowId, tabId, .engineOffer, receipt(binding, offer.id), .button(action))
      return engineOffers[tabId]?.id != id
    }
    guard let binding = active(tabId), let page = pages[tabId], let windowId = TabPoolHost.shared.windowOf(tabId),
      profileIsShown(tabId, windowId) else { return false }
    if kind == "deviceChooser" {
      guard let chooser = page.chooser, String(chooser.id) == id else { return false }
      let event: DeviceChooserEvent
      switch action {
      case "select":
        guard let option = Int(option) else { return false }
        event = .choose(option)
      case "cancel": event = .cancel
      case "refresh": event = .refresh
      case "settings": event = .openSettings
      default: return false
      }
      return chooserAction(windowId, tabId, chooser.id, event)
    }
    guard let kind = PanePromptKind(rawValue: kind) else { return false }
    let key: String?
    switch kind {
    case .password, .autofill: return false
    case .permission: key = page.permission?.key
    case .externalApp: key = page.externalApp?.key
    case .popups: key = page.popups.first?.id
    case .engineOffer: return false
    }
    guard key == id else { return false }
    let shown = receipt(binding, kind == .popups ? popupKey(tabId, id) : id)
    if kind == .externalApp, option == "remember" { promptEvent(windowId, tabId, kind, shown, .toggle(true)) }
    promptEvent(windowId, tabId, kind, shown, action == "row" ? .row(option) : .button(action))
    return kind != .externalApp || pages[tabId]?.externalApp?.id != id
  }
  #endif

  private static func js(_ name: String, _ args: Any...) {
    Task { @MainActor in
      do {
        _ = try await SettingsJS.shared.invoke(name, args)
      } catch {
        NSLog("[pane prompts] %@ failed: %@", name, String(describing: error))
      }
    }
  }

  private static func setPage(_ tabId: String, _ page: PanePromptPage) {
    let hadPermission = pages[tabId]?.permission != nil
    let hasPermission = page.permission != nil
    pages[tabId] = page
    if hadPermission != hasPermission {
      permissionTabs.withLock {
        if hasPermission { _ = $0.insert(tabId) }
        else { _ = $0.remove(tabId) }
      }
    }
  }

  private static func update(_ tabId: String, _ page: PanePromptPage) {
    setPage(tabId, page)
    changed(tabId)
  }

  private static func encode(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func changed(_ tabId: String) {
    guard let windowId = TabPoolHost.shared.windowOf(tabId) else { return refreshAll() }
    windowOfTab[tabId] = windowId
    refresh(windowId)
  }

  private static func refresh(_ windowId: String) {
    guard refreshing.insert(windowId).inserted else { return }
    DispatchQueue.main.async {
      refreshing.remove(windowId)
      NativePaneOverlays.refresh(windowId)
    }
  }

  private static func refreshAll() {
    for windowId in Set(windows.keys) { NativePaneOverlays.refresh(windowId) }
  }

  private static func applyWindows(_ value: Any?) {
    windows = ((value as? [String: Any])?["windows"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    for (windowId, window) in windows {
      let shown = ((window["theme"] as? [String: Any])?["cli"] as? [String: Any])?["shown"] as? Bool == true
      if shown == (cliShown[windowId] ?? false) { continue }
      cliShown[windowId] = shown
      if shown {
        cliRevealed.remove(windowId)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard cliShown[windowId] == true else { return }
            cliRevealed.insert(windowId)
            NativePaneOverlays.refresh(windowId)
          }
        }
      } else {
        cliRevealed.remove(windowId)
        cliHideUntil[windowId] = ProcessInfo.processInfo.systemUptime + cliHideDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + cliHideDelay + 0.01) {
          MainActor.assumeIsolated { NativePaneOverlays.refresh(windowId) }
        }
      }
    }
    for windowId in cliShown.keys where windows[windowId] == nil {
      cliShown[windowId] = nil
      cliRevealed.remove(windowId)
      cliHideUntil[windowId] = nil
    }
    refreshAll()
  }

  static func cliPills(in windowId: String) -> [(tabId: String, state: CliPillState)] {
    guard let window = windows[windowId], var cli = (window["theme"] as? [String: Any])?["cli"] as? [String: Any] else { return [] }
    let shown = cli["shown"] as? Bool == true
    guard shown || (cliHideUntil[windowId] ?? 0) > ProcessInfo.processInfo.systemUptime else { return [] }
    cli["shown"] = shown && cliRevealed.contains(windowId)
    guard let state = encode(cli).flatMap(CliPillState.decode) else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    return panes.keys.sorted().compactMap { tabId in panes[tabId]?["cliPill"] as? Bool == true && owns(tabId) ? (tabId, state) : nil }
  }
}
