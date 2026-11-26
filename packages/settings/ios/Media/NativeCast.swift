import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeCast {
  private static var state = CastLifecycle()
  private static weak var store: Store?
  private static var storeListener: Int?
  private static var started = false
  private static var refreshPending = false
  private static var privateProfiles: Set<String> = []
  private static var anchors: [UUID: Anchor] = [:]
  private static var pickers: [String: Picker] = [:]

  private struct Anchor {
    let windowID: String
    let tabID: String
    weak var view: PanePopoverWrap?
  }

  @MainActor
  private final class Picker {
    let receipt: CastLifecycle.Receipt
    let view = PanePopover(CastPickerView(frame: .zero))
    var state: CastPickerState?

    init(_ receipt: CastLifecycle.Receipt) { self.receipt = receipt }

    func place(in container: NSView?, state: CastPickerState) {
      let popover = view.popover
      view.place(in: container)
      popover.set(placement: PopoverPlacement(width: min(340, max(1, view.wrap.bounds.width - 24)), top: 8, right: 8), dark: state.theme.dark)
      if self.state != state {
        self.state = state
        view.body.update(state)
      }
      popover.layoutSubtreeIfNeeded()
    }
  }

  static func start() {
    guard !started else { return }
    started = true
    HostedViews.register(NativeMedia.castPicker) { windowID in
      let view = PanePopoverWrap()
      let id = UUID()
      view.onReturn = { scheduleRefresh() }
      view.onLeave = { scheduleRefresh() }
      return HostedContent(view: view, onUnmount: {
        anchors[id] = nil
        scheduleRefresh()
      }, takesFocus: false) { [weak view] tabID in
        anchors[id] = Anchor(windowID: windowID, tabID: tabID, view: view)
        scheduleRefresh()
      }
    }
    SolaraCoreEventTaps.observers.append { name, payload in receive(name, payload) }
    SolaraCoreEventTaps.installCast()
    _ = NativeStoreHandle.subscribeLifecycle { reconcileStore() }
    PageRegistry.shared.observe { _ in scheduleRefresh() }
    TabPoolHost.shared.stateObservers.append { scheduleRefresh() }
    for name in [PaneOverlays.changed, TabSlots.changed, NSWindow.didResizeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { scheduleRefresh() }
      }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let windowID = ShellDrag.windowId(of: window) else { return }
        closeDialogs { $0.windowID == windowID }
      }
    }
  }

  private static var currentStore: Store? {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen, NativeStoreHandle.store === store else { return nil }
    return store
  }

  private static func reconcileStore() {
    let next = NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen ? NativeStoreHandle.store : nil
    if store !== next {
      if let storeListener { store?.unsubscribe(storeListener) }
      closeDialogs { _ in true }
      store = next
      storeListener = next?.subscribe { commit in
        let changes = commit.changes
        guard !changes.tabs.isEmpty || !changes.windows.isEmpty || !changes.profiles.isEmpty
          || !changes.peeks.isEmpty || !changes.splits.isEmpty || !changes.live.isEmpty
          || changes.lists.contains("ui") || !changes.settingsChanged.isEmpty || !changes.settingsRemoved.isEmpty else { return }
        DispatchQueue.main.async { scheduleRefresh() }
      }
      NativeExtensionCatalog.emit?(true, false)
    }
    scheduleRefresh()
  }

  private static func scheduleRefresh() {
    guard !refreshPending else { return }
    refreshPending = true
    DispatchQueue.main.async {
      refreshPending = false
      refresh()
    }
  }

  private static func refresh() {
    let closes = state.prune { page($0) }
    closes.forEach { perform(.close($0)) }
    refreshPickers()
    guard let snapshot = currentStore?.state else { return }
    let windows = snapshot.windowOrder.compactMap { snapshot.windows[$0] }
    let privateNow = Set(windows.filter(\.incognito).map { snapshot.engineProfile($0.profileId) })
    for profile in privateProfiles.subtracting(privateNow) { state.forgetProfile(profile) }
    privateProfiles = privateNow
    let profiles = windows.map { snapshot.engineProfile($0.profileId) }
    for profile in state.profilesToWatch(profiles) { SolaraCoreHost.watchCastRoutes(profile) }
  }

  private static func page(_ tabID: String) -> CastLifecycle.Page? {
    guard let store = currentStore, let issuer = PageIssuer.shared, issuer.store === store,
      let binding = issuer.binding(tabId: tabID), binding.engine == .chromium,
      let registration = binding.registration, issuer.isCurrent(binding) else { return nil }
    let snapshot = store.state
    guard let tab = snapshot.tabs[tabID], let window = snapshot.windows[tab.windowId],
      tab.profileId == window.profileId, !store.memory.closingWindows.contains(tab.windowId) else { return nil }
    let view = binding.host == .pooled ? TabPoolHost.shared.pageView(tabID) : binding.owner as? NSView
    guard let web = NativeOmniboxExtensionActions.page(in: view), web.transferKey == tabID, web.browserId > 0 else { return nil }
    return .init(tabID: tabID, windowID: tab.windowId, profile: snapshot.engineProfile(tab.profileId),
      browserID: web.browserId, generation: registration.registrationGeneration)
  }

  private static func page(browserID: Int32) -> CastLifecycle.Page? {
    guard browserID > 0, let store = currentStore else { return nil }
    let tabs = store.state.tabs.keys
    if let tabID = tabs.first(where: { store.pageFacts($0)?.ready?.browserId == Int(browserID) }),
      let current = page(tabID), current.browserID == browserID { return current }
    return tabs.lazy.compactMap { page($0) }.first { $0.browserID == browserID }
  }

  private static func receive(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "castDialog":
      guard let dialog = decode(CastLifecycle.Dialog.self, payload) else { return }
      receive(dialog, page: page(browserID: dialog.browserID))
    case "castRoutes":
      guard let profile = payload["profile"] as? String, let routes = payload["routes"],
        let list = decode([CastLifecycle.Route].self, routes),
        state.receiveRoutes(list, profile: profile) else { return }
      NativeExtensionCatalog.emit?(true, false)
    default: break
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func receive(_ dialog: CastLifecycle.Dialog, page: CastLifecycle.Page?) {
    let closes = state.receive(dialog, page: page)
    closes.forEach { perform(.close($0)) }
    refreshPickers()
  }

  private static func closeDialogs(where matches: (CastLifecycle.Page) -> Bool) {
    let closes = state.prune { id in
      guard let current = page(id), !matches(current) else { return nil }
      return current
    }
    closes.forEach { perform(.close($0)) }
    refreshPickers()
  }

  static func command(windowID: String?) -> Bool {
    guard let store = currentStore else { return false }
    let target = CommandRoute.resolve("cast", windowId: windowID, state: store.state, closing: store.memory.closingWindows)
    if let windowID = target.windowId, let tabID = target.tabId { _ = toggle(windowID: windowID, tabID: tabID) }
    return true
  }

  @discardableResult
  static func toggle(windowID: String, tabID: String) -> Bool {
    guard let current = page(tabID), current.windowID == windowID else { return false }
    if let effect = state.toggle(current) {
      let token = state.pendingToken(for: current)
      let performed = perform(effect)
      if let token {
        if !performed { state.finishPending(current, token: token); return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.finishPending(current, token: token) }
      }
      refreshPickers()
    }
    return true
  }

  static func routes(windowID: String) -> [CastLifecycle.Route] {
    guard let store = currentStore, let window = store.state.windows[windowID] else { return [] }
    return state.routes[store.state.engineProfile(window.profileId)] ?? []
  }

  static func menu(windowID: String, tabID: String) {
    guard let current = page(tabID), current.windowID == windowID else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    let rows: [[String: Any]] = routes(windowID: windowID).map {
      ["id": "stop:\($0.id)", "title": "Stop Casting to \($0.sink)", "symbol": "stop.circle"]
    }
    ShellMenus.choose(rows + [["separator": true], ["id": "open", "title": "Cast…", "symbol": "tv.and.mediabox"]]) { choice in
      guard let choice, NativeStoreHandle.ownershipGeneration == generation, page(tabID) == current else { return }
      if choice == "open" { toggle(windowID: windowID, tabID: tabID) }
      else if choice.hasPrefix("stop:") { terminate(String(choice.dropFirst(5)), page: current) }
    }
  }

  private static func terminate(_ route: String, page: CastLifecycle.Page) {
    guard state.hasRoute(route, profile: page.profile) else { return }
    SolaraCoreHost.terminateCastRoute(route)
  }

  private static func action(_ event: CastPickerAction, receipt: CastLifecycle.Receipt) {
    guard page(receipt.page.tabID) == receipt.page, let entry = state.entry(receipt) else { return }
    let effect: CastLifecycle.Effect?
    switch event {
    case .cast(let id): effect = state.start(receipt, sinkID: id)
    case .stop(let id): effect = state.stop(receipt, sinkID: id)
    case .done: effect = state.dismiss(receipt)
    case .source:
      ShellMenus.choose([["id": "tab", "title": "Cast Tab", "checked": !entry.screen],
        ["id": "screen", "title": "Cast Screen", "checked": entry.screen]]) { choice in
        guard let choice, page(receipt.page.tabID) == receipt.page else { return }
        state.selectScreen(choice == "screen", receipt: receipt)
        refreshPickers()
      }
      return
    case .link:
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
        NSWorkspace.shared.open(url)
      }
      return
    case .height: return
    }
    if let effect { perform(effect); refreshPickers() }
  }

  @discardableResult
  private static func perform(_ effect: CastLifecycle.Effect) -> Bool {
    #if DEBUG
      if recordFixture(effect) { return true }
    #endif
    switch effect {
    case .show(let browserID): return SolaraCoreHost.showCastDialog(browserId: browserID)
    case .close(let id): SolaraCoreHost.closeCastDialog(id)
    case .start(let id, let sink, let mode): SolaraCoreHost.castDialog(id, start: sink, mode: mode)
    case .stop(let id, let route): SolaraCoreHost.castDialog(id, stop: route)
    }
    return true
  }

  private static func refreshPickers() {
    for (tabID, picker) in pickers where picker.receipt != state.dialogs[tabID]?.receipt {
      picker.view.wrap.removeFromSuperview()
      pickers[tabID] = nil
    }
    guard let snapshot = currentStore?.state else { return }
    for (tabID, entry) in state.dialogs {
      let page = entry.receipt.page
      guard let window = snapshot.windows[page.windowID] else { continue }
      let pane = container(page)
      guard let pane, pane.bounds.width > 24 else {
        pickers[tabID]?.view.place(in: nil)
        continue
      }
      let picker = pickers[tabID] ?? makePicker(entry.receipt)
      pickers[tabID] = picker
      let look = NativeLayoutAppearance(state: snapshot, profileId: window.profileId, incognito: window.incognito)
      let sinks = entry.dialog.sinks
      let content = CastPickerState(title: entry.screen ? "Cast screen" : entry.dialog.header.isEmpty ? "Cast tab" : entry.dialog.header,
        canScreen: sinks.contains { $0.modes & 4 != 0 }, rejected: entry.dialog.permissionRejected,
        rejectedText: "\(Bundle.main.productName) needs Local Network access to find Cast devices.",
        sinks: sinks.filter { $0.state != "unavailable" }.map { sink in
          let icon = [0: "tv", 1: "hifispeaker.2", 2: "hifispeaker", 6: "display", 7: "tv"][sink.icon] ?? "tv"
          let detail = sink.issue.isEmpty ? sink.status : sink.issue
          return CastSinkState(id: sink.id, name: sink.name, icon: icon, detail: detail.isEmpty ? nil : detail,
            issue: !sink.issue.isEmpty, active: sink.state == "connected" && !sink.routeID.isEmpty,
            busy: sink.state == "connecting" || sink.state == "disconnecting")
        }, theme: NativeMediaStack.theme(look))
      picker.place(in: pane, state: content)
    }
  }

  private static func makePicker(_ receipt: CastLifecycle.Receipt) -> Picker {
    let picker = Picker(receipt)
    picker.view.wrap.autoresizingMask = [.width, .height]
    picker.view.wrap.onResize = { scheduleRefresh() }
    picker.view.popover.onDismiss = { action(.done, receipt: receipt) }
    picker.view.body.onAction = { [weak picker] event in
      if case .height(let height) = event { picker?.view.setHeight(height) }
      else { action(event, receipt: receipt) }
    }
    return picker
  }

  private static func container(_ page: CastLifecycle.Page) -> NSView? {
    guard let window = ShellDrag.window(page.windowID) else { return nil }
    if currentStore?.state.peeks[page.windowID]?.tabId == page.tabID,
      let peek = TabSlots.shared.container(for: .peek(page.windowID)),
      peek.window === window, !peek.isHiddenOrHasHiddenAncestor { return peek }
    if let pane = PaneOverlays.shared.container(windowId: page.windowID, tabId: page.tabID, layer: .native),
      pane.window === window, !pane.isHiddenOrHasHiddenAncestor { return pane }
    return anchors.values.lazy.filter { $0.windowID == page.windowID && $0.tabID == page.tabID }
      .compactMap(\.view).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
  }

  static func views(windowID: String) -> [NSView] {
    pickers.values.filter { $0.receipt.page.windowID == windowID && $0.view.wrap.window != nil }.map { $0.view.popover }
  }

  #if DEBUG
    static func panePickers(_ windowID: String) -> [String: PanePopover<CastPickerView>] {
      pickers.filter { tabID, picker in
        guard picker.receipt.page.windowID == windowID,
          let pane = PaneOverlays.shared.container(windowId: windowID, tabId: tabID, layer: .native) else { return false }
        return picker.view.wrap.superview === pane
      }.mapValues(\.view)
    }

    private static var fixtureID: Int32 = -10000
    private static var fixtureActions: [String] = []

    private static func recordFixture(_ effect: CastLifecycle.Effect) -> Bool {
      switch effect {
      case .close(let id) where id < 0: fixtureActions.append("close")
      case .start(let id, let sink, _) where id < 0: fixtureActions.append("start:\(sink)")
      case .stop(let id, let route) where id < 0: fixtureActions.append("stop:\(route)")
      default: return false
      }
      return true
    }

    static func fixture(tabID: String, json: String) -> Bool {
      guard let page = page(tabID), let sinks = try? JSONDecoder().decode([CastLifecycle.Sink].self, from: Data(json.utf8)) else { return false }
      fixtureID += 1
      receive(.init(id: fixtureID, browserID: page.browserID, open: true, header: "Cast tab", sinks: sinks), page: page)
      return true
    }

    static func probe() -> String {
      struct Snapshot: Encodable {
        let dialogs: [String: CastLifecycle.Dialog]
        let routes: [String: [CastLifecycle.Route]]
        let fixtureActions: [String]
      }
      let snapshot = Snapshot(dialogs: state.dialogs.mapValues(\.dialog), routes: state.routes, fixtureActions: fixtureActions)
      return (try? JSONEncoder().encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func devAction(windowID: String, tabID: String, dialogID: Int32, name: String, value: String) -> Bool {
      guard let page = page(tabID), page.windowID == windowID else { return false }
      if name == "terminate" {
        guard state.hasRoute(value, profile: page.profile) else { return false }
        terminate(value, page: page)
        return true
      }
      guard let entry = state.dialogs[tabID], entry.dialog.id == dialogID, entry.receipt.page == page else { return false }
      switch name {
      case "start": action(.cast(value), receipt: entry.receipt)
      case "stop": action(.stop(value), receipt: entry.receipt)
      case "dismiss": action(.done, receipt: entry.receipt)
      default: return false
      }
      return true
    }
  #endif
}
