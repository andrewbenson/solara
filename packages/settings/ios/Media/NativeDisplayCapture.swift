import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeDisplayCapture {
  typealias Lifetime = DisplayCaptureLifetime
  typealias Page = Lifetime.Page
  typealias Receipt = Lifetime.Receipt

  private struct Anchor {
    let windowID: String
    let tabID: String
    weak var wrap: PanePopoverWrap?
  }

  private struct Offer {
    let receipt: Receipt
    let origin: String
    let frame: String?
    let audio: [String: Any]
    let fixture: Bool
    let expires = ProcessInfo.processInfo.systemUptime + 300
    var sources: [[String: Any]]
    var selected: String?
    var audioChoices = ["tab": true, "screen": false, "window": false]
  }

  @MainActor
  private final class Picker {
    let receipt: Receipt
    let view = PanePopover(SharePickerView(frame: .zero))
    var content: SharePickerState?
    var focus: HostedMount?

    init(_ receipt: Receipt) { self.receipt = receipt }

    func place(_ pane: NSView?) {
      if view.wrap.superview !== pane {
        focus?.end()
        focus = nil
      }
      view.place(in: pane)
      if let window = view.wrap.window, focus == nil, !view.wrap.isHiddenOrHasHiddenAncestor {
        focus = HostedMount(content: HostedContent(view: view.popover, takesFocus: true), in: view.wrap, window: window)
      } else if view.wrap.isHiddenOrHasHiddenAncestor {
        focus?.end()
        focus = nil
      }
    }
  }

  private static var lifetime = Lifetime()
  private static var offers: [String: Offer] = [:]
  private static var origins: [Receipt: String] = [:]
  private static var anchors: [UUID: Anchor] = [:]
  private static var pickers: [String: Picker] = [:]
  private static var inline: [UUID: WeakInline] = [:]
  private static weak var store: Store?
  private static var storeListener: Int?
  private static var scheduled = false
  private static var polling = false
  private static var nextSources: TimeInterval = 0
  private static var started = false
  nonisolated private static let snapshotLock = NSLock()
  nonisolated(unsafe) private static var protectionReasons: [String: String] = [:]
  nonisolated(unsafe) private static var tabShare = false

  private struct WeakInline {
    weak var view: DisplayShareBarHost?
  }

  static func start() {
    guard !started else { return }
    started = true
    HostedViews.register(NativeMedia.sharePicker) { windowID in
      let wrap = PanePopoverWrap()
      let id = UUID()
      wrap.onReturn = { schedule() }
      wrap.onLeave = { schedule() }
      wrap.onResize = { schedule() }
      return HostedContent(view: wrap, onUnmount: {
        anchors[id] = nil
        schedule()
      }, takesFocus: false) { [weak wrap] tabID in
        anchors[id] = Anchor(windowID: windowID, tabID: tabID, wrap: wrap)
        schedule()
      }
    }
    SolaraCoreWebView.setDisplayCaptureHandler { view, name, body in
      MainActor.assumeIsolated { receive(view, name, body) }
    }
    _ = NativeStoreHandle.subscribeLifecycle { reconcileStore() }
    PageRegistry.shared.observe { _ in schedule() }
    TabPoolHost.shared.stateObservers.append { schedule() }
    for name in [PaneOverlays.changed, TabSlots.changed, NSWindow.didResizeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { schedule() }
      }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let windowID = ShellDrag.windowId(of: window) else { return }
        for offer in Array(offers.values) where store?.state.tabs[offer.receipt.page.tabID]?.windowId == windowID {
          cancel(offer.receipt)
        }
        schedule()
      }
    }
    CaptureSleepProtection.reason = { tabID in protection(tabID) }
  }

  private static func reconcileStore() {
    let next = NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen ? NativeStoreHandle.store : nil
    if store !== next {
      if let storeListener { store?.unsubscribe(storeListener) }
      for offer in Array(offers.values) { cancel(offer.receipt) }
      for share in lifetime.shares.values { _ = SolaraCoreHost.stopCapture(browserId: share.receipt.page.browserID) }
      lifetime = Lifetime()
      origins.removeAll()
      store = next
      storeListener = next?.subscribe { commit in
        let changes = commit.changes
        if !changes.tabs.isEmpty || !changes.windows.isEmpty || !changes.splits.isEmpty || !changes.peeks.isEmpty
          || !changes.profiles.isEmpty || changes.lists.contains("ui") || !changes.settingsChanged.isEmpty || !changes.settingsRemoved.isEmpty {
          DispatchQueue.main.async { schedule() }
        }
      }
    }
    schedule()
  }

  private static func page(_ tabID: String) -> Page? {
    guard let store, NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen, NativeStoreHandle.store === store,
      let tab = store.state.tabs[tabID], store.state.windows[tab.windowId] != nil,
      !store.memory.closingWindows.contains(tab.windowId),
      let web = SolaraCoreWebView.liveView(transferKey: tabID), web.browserId > 0 else { return nil }
    return Page(tabID: tabID, browserID: web.browserId, profile: store.state.engineProfile(tab.profileId))
  }

  private static func receive(_ view: SolaraCoreWebView, _ name: String, _ body: [String: Any]) {
    guard let tabID = view.transferKey else { return }
    if name == "displayMediaRequest", let id = body["id"] as? String {
      guard let current = page(tabID), current.browserID == view.browserId, receive(body, on: current, fixture: false) else {
        view.resolveDisplayMedia(id, sourceId: nil, audio: false)
        return
      }
    } else if name == "documentCommitted", let receipt = lifetime.pending[tabID], receipt.page.browserID == view.browserId {
      cancel(receipt)
    }
    if offers[tabID] != nil || lifetime.shares[tabID] != nil || name == "documentCommitted" || name == "ready" { schedule() }
  }

  @discardableResult
  private static func receive(_ body: [String: Any], on page: Page, fixture: Bool) -> Bool {
    guard let id = body["id"] as? String, let origin = body["origin"] as? String else { return false }
    if lifetime.pending[page.tabID]?.id == id { return true }
    let (receipt, old) = lifetime.offer(id, on: page)
    if let old, offers[page.tabID]?.fixture == false { send(old, source: nil) }
    offers[page.tabID] = Offer(receipt: receipt, origin: origin, frame: body["frameOrigin"] as? String,
      audio: body["audio"] as? [String: Any] ?? [:], fixture: fixture, sources: body["sources"] as? [[String: Any]] ?? [])
    nextSources = ProcessInfo.processInfo.systemUptime + 2.5
    refresh()
    return true
  }

  private static func send(_ receipt: Receipt, source: String?, audio: Bool = false) {
    SolaraCoreHost.answerDisplayCapture(browserId: receipt.page.browserID, receipt: receipt.id, source: source, audio: audio)
  }

  private static func cancel(_ receipt: Receipt) {
    guard lifetime.pending[receipt.page.tabID] == receipt, let offer = offers.removeValue(forKey: receipt.page.tabID) else { return }
    lifetime.close(receipt.page)
    if !offer.fixture { send(receipt, source: nil) }
  }

  private static func stop(_ page: Page) -> Bool {
    let fixture = isFixtureShare(lifetime.shares[page.tabID])
    let pendingFixture = offers[page.tabID]?.fixture == true
    let stopped = fixture || pendingFixture || SolaraCoreHost.stopCapture(browserId: page.browserID)
    lifetime.stop(page)
    offers[page.tabID] = nil
    refresh()
    return stopped
  }

  static func protection(_ tabID: String) -> String? {
    if lifetime.pending[tabID] != nil { return "choosing a screen to share" }
    if lifetime.shares[tabID] != nil { return "capturing" }
    return nil
  }

  nonisolated static var hasTabShare: Bool { snapshotLock.withLock { tabShare } }

  nonisolated static func protectionSnapshot(_ tabID: String) -> String? {
    snapshotLock.withLock { protectionReasons[tabID] }
  }

  private static func updateProtectionSnapshot() {
    var reasons = lifetime.shares.mapValues { _ in "capturing" }
    for id in lifetime.pending.keys { reasons[id] = "choosing a screen to share" }
    let sharing = lifetime.shares.values.contains { $0.target != nil }
    snapshotLock.withLock {
      protectionReasons = reasons
      tabShare = sharing
    }
  }

  private static func approved(_ receipt: Receipt, source: String, target: Page?, audio: Bool) -> Bool {
    guard let offer = offers[receipt.page.tabID], offer.receipt == receipt,
      page(receipt.page.tabID) == receipt.page, lifetime.answer(receipt, source: source, target: target) else { return false }
    offers[receipt.page.tabID] = nil
    origins[receipt] = offer.origin
    if !offer.fixture { send(receipt, source: source, audio: audio) }
    refresh()
    return true
  }

  private static func target(_ tabID: String, for caller: Page) -> Page? {
    guard let url = store?.state.tabs[tabID]?.url, Self.webURL(url),
      let candidate = page(tabID), candidate.profile == caller.profile else { return nil }
    return candidate
  }

  private static func webURL(_ url: String) -> Bool {
    guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
    return ["https", "http", "file"].contains(scheme)
  }

  private static func audioLabel(_ kind: String, offer: Offer) -> String? {
    switch kind {
    case "tab": return offer.audio["tab"] as? Bool == true ? "Also share tab audio" : nil
    case "screen": return offer.audio["screen"] as? Bool == true ? "Also share system audio" : nil
    case "window":
      guard let mode = offer.audio["window"] as? String else { return nil }
      return mode == "application" ? "Also share application audio" : "Also share system audio"
    default: return nil
    }
  }

  private static func kind(_ id: String?, _ offer: Offer) -> String? {
    guard let id else { return nil }
    if id.hasPrefix("tab:"), target(String(id.dropFirst(4)), for: offer.receipt.page) != nil { return "tab" }
    return offer.sources.first { $0["id"] as? String == id }?["kind"] as? String
  }

  private static func action(_ action: SharePickerAction, receipt: Receipt) {
    let tabID = receipt.page.tabID
    guard let offer = offers[tabID], offer.receipt == receipt, page(tabID) == receipt.page else { return }
    switch action {
    case .cancel: cancel(receipt)
    case .select(let id):
      guard kind(id, offer) != nil else { return }
      offers[tabID]?.selected = id
    case .audio(let on):
      guard let selected = kind(offer.selected, offer), audioLabel(selected, offer: offer) != nil else { return }
      offers[tabID]?.audioChoices[selected] = on
    case .share(let id):
      guard let id = id ?? offer.selected, let kind = kind(id, offer) else { return }
      let audio = audioLabel(kind, offer: offer) != nil && offer.audioChoices[kind] == true
      if kind == "tab" {
        guard let target = target(String(id.dropFirst(4)), for: receipt.page),
          let source = SolaraCoreWebView.liveView(transferKey: target.tabID)?.mediaCaptureSourceId else { return }
        _ = approved(receipt, source: source, target: target, audio: audio)
      } else {
        _ = approved(receipt, source: id, target: nil, audio: audio)
      }
    case .height: return
    }
    refresh()
  }

  private static func schedule() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async {
      scheduled = false
      refresh()
    }
  }

  private static func isFixtureShare(_ share: Lifetime.Share?) -> Bool {
    #if DEBUG
      return share?.receipt.id == fixtureShareID
    #else
      return false
    #endif
  }

  private static func refresh() {
    let now = ProcessInfo.processInfo.systemUptime
    for offer in Array(offers.values) where page(offer.receipt.page.tabID) != offer.receipt.page || offer.expires <= now {
      cancel(offer.receipt)
    }
    if now >= nextSources, offers.values.contains(where: { !$0.fixture }) {
      nextSources = now + 2.5
      let sources = SolaraCoreHost.displayMediaSources
      for (id, offer) in offers where !offer.fixture { offers[id]?.sources = sources }
      let pids = Set(sources.compactMap { $0["pid"] as? Int32 })
      icons = icons.filter { pids.contains($0.key) }
    }
    for (id, share) in lifetime.shares where !isFixtureShare(share) {
      let caller = share.receipt.page
      let phase = SolaraCoreHost.displayCaptureState(browserId: caller.browserID)?["state"] as? String
      if store?.state.tabs[id] == nil || (page(id).map { $0 != caller } ?? false) {
        _ = SolaraCoreHost.stopCapture(browserId: caller.browserID)
        lifetime.stop(caller)
      } else if phase != "active" && phase != "starting" {
        lifetime.ended(caller)
      }
    }
    origins = origins.filter { lifetime.shares[$0.key.page.tabID]?.receipt == $0.key }
    updateProtectionSnapshot()
    if offers.isEmpty { icons.removeAll() }
    refreshPickers()
    refreshBars()
    guard !polling, !offers.isEmpty || !lifetime.shares.isEmpty else { return }
    polling = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      polling = false
      refresh()
    }
  }

  private static func container(_ tabID: String, windowID: String) -> NSView? {
    guard let window = ShellDrag.window(windowID) else { return nil }
    if store?.state.peeks[windowID]?.tabId == tabID,
      let peek = TabSlots.shared.container(for: .peek(windowID)),
      peek.window === window, !peek.isHiddenOrHasHiddenAncestor { return peek }
    if let pane = PaneOverlays.shared.container(windowId: windowID, tabId: tabID, layer: .native),
      pane.window === window, !pane.isHiddenOrHasHiddenAncestor { return pane }
    return anchors.values.lazy.filter { $0.windowID == windowID && $0.tabID == tabID }
      .compactMap(\.wrap).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
  }

  private static func refreshPickers() {
    for (id, picker) in pickers where offers[id]?.receipt != picker.receipt {
      picker.place(nil)
      pickers[id] = nil
    }
    guard let snapshot = store?.state else { return }
    for (id, offer) in offers {
      guard let windowID = snapshot.tabs[id]?.windowId, let window = snapshot.windows[windowID],
        let pane = container(id, windowID: windowID), pane.bounds.width > 24 else {
        pickers[id]?.place(nil)
        continue
      }
      let picker = pickers[id] ?? makePicker(offer.receipt)
      pickers[id] = picker
      let width = min(460, pane.bounds.width - 24)
      let theme = NativeMediaStack.theme(NativeLayoutAppearance(state: snapshot, profileId: window.profileId, incognito: window.incognito))
      let next = pickerState(offer, snapshot: snapshot, width: width, theme: theme)
      picker.view.popover.set(placement: PopoverPlacement(width: width, top: 8, left: (pane.bounds.width - width) / 2), dark: theme.dark)
      if picker.content != next {
        picker.content = next
        picker.view.body.update(next)
      }
      picker.place(pane)
    }
  }

  private static func pickerState(_ offer: Offer, snapshot: BrowserState, width: CGFloat, theme: MediaThemeState) -> SharePickerState {
    let caller = offer.receipt.page
    let tabs: [ShareTabSource] = snapshot.tabs.values.sorted {
      if $0.id == caller.tabID { return false }
      if $1.id == caller.tabID { return true }
      return $0.lastActiveAt == $1.lastActiveAt ? $0.id < $1.id : $0.lastActiveAt > $1.lastActiveAt
    }.compactMap { tab in
      guard target(tab.id, for: caller) != nil else { return nil }
      return ShareTabSource(id: tab.id, title: tab.title.isEmpty ? tab.url : tab.title, url: tab.url,
        favicon: tab.favicon, profileId: tab.profileId, current: tab.id == caller.tabID)
    }
    let screens: [ShareScreenSource] = offer.sources.compactMap { item in
      guard item["kind"] as? String == "screen", let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
      let w = item["width"] as? Int ?? 0
      let h = item["height"] as? Int ?? 0
      return ShareScreenSource(id: id, name: name, size: w > 0 ? "\(w) × \(h)" : nil,
        aspect: w > 0 && h > 0 ? Double(h) / Double(w) : 10.0 / 16)
    }
    let windows: [ShareWindowSource] = offer.sources.compactMap { item in
      guard item["kind"] as? String == "window", let id = item["id"] as? String else { return nil }
      let app = item["app"] as? String
      let name = item["name"] as? String ?? ""
      let title = name.isEmpty ? app ?? "Window" : name
      let icon = (item["pid"] as? Int32).flatMap { appIcon($0) }
      return ShareWindowSource(id: id, title: title, app: app == title ? nil : app, icon: icon)
    }
    let selection = kind(offer.selected, offer)
    let audio = selection.flatMap { kind in
      audioLabel(kind, offer: offer).map { ShareAudioState(label: $0, value: offer.audioChoices[kind] == true) }
    }
    let host = URL(string: offer.origin)?.host ?? offer.origin
    let frame = offer.frame.flatMap { URL(string: $0)?.host } ?? ""
    let receiver = !frame.isEmpty && frame != host ? "\(frame), a frame on this page," : "The site"
    let subtitle = audio?.value == true ? "\(receiver) will see and hear what you choose."
      : "\(receiver) will see what you choose." + (!offer.audio.isEmpty && audioLabel("screen", offer: offer) == nil
        && audioLabel("window", offer: offer) == nil && selection != "tab" ? " Only tabs share their audio." : "")
    return SharePickerState(requestId: offer.receipt.id, tabId: caller.tabID, title: "Share your screen with \(host)",
      subtitle: subtitle, tabs: tabs, screens: screens, windows: windows, selected: offer.selected, valid: selection != nil,
      audio: audio, tileWidth: (width - 20) / 2, theme: theme)
  }

  private static var icons: [Int32: String] = [:]

  private static func appIcon(_ pid: Int32) -> String? {
    if let icon = icons[pid] { return icon }
    guard let image = NSRunningApplication(processIdentifier: pid)?.icon,
      let bytes = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: bytes),
      let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    let icon = "data:image/png;base64," + png.base64EncodedString()
    icons[pid] = icon
    return icon
  }

  private static func makePicker(_ receipt: Receipt) -> Picker {
    let picker = Picker(receipt)
    picker.view.wrap.autoresizingMask = [.width, .height]
    picker.view.wrap.onResize = { schedule() }
    picker.view.wrap.onReturn = { schedule() }
    picker.view.wrap.onLeave = { schedule() }
    picker.view.popover.onDismiss = { action(.cancel, receipt: receipt) }
    picker.view.body.onAction = { [weak picker] event in
      if case .height(let height) = event { picker?.view.setHeight(height) }
      else { action(event, receipt: receipt) }
    }
    return picker
  }

  static func views(windowID: String) -> [NSView] {
    guard let window = ShellDrag.window(windowID) else { return [] }
    return pickers.values.filter { $0.view.wrap.window === window }.map { $0.view.popover }
  }

  #if DEBUG
  static func panePickers(_ windowID: String) -> [String: PanePopover<SharePickerView>] {
    pickers.filter { id, picker in
      guard let pane = PaneOverlays.shared.container(windowId: windowID, tabId: id, layer: .native) else { return false }
      return picker.view.wrap.superview === pane
    }.mapValues(\.view)
  }
  #endif

  static func register(_ view: DisplayShareBarHost) {
    inline[view.id] = view.window == nil ? nil : WeakInline(view: view)
    schedule()
  }

  static func inlineBars(_ windowID: String) -> [NSView] {
    inline.values.compactMap(\.view).filter { $0.windowID == windowID && $0.clip.bounds.height > 0 }.map { $0.clip.bar }
  }

  static func barAction(_ event: ShareBarAction, row: ShareBarState) {
    let capturer = row.capturer
    guard let share = lifetime.shares[capturer], share.receipt.id == row.receiptID, page(capturer) == share.receipt.page,
      let target = target(row.tabId, for: share.receipt.page), lifetime.share(for: target)?.receipt == share.receipt else { return }
    switch event {
    case .stop: _ = stop(share.receipt.page)
    case .dismiss: lifetime.dismiss(share.receipt, from: target)
    case .shareInstead: _ = retarget(share, to: target)
    }
    refresh()
  }

  private static func retarget(_ share: Lifetime.Share, to target: Page) -> Bool {
    guard share.target != nil, page(share.receipt.page.tabID) == share.receipt.page, target.profile == share.receipt.page.profile,
      isFixtureShare(share) || SolaraCoreHost.shareTabInstead(capturer: share.receipt.page.browserID, target: target.browserID) else { return false }
    return lifetime.retarget(share.receipt, to: target)
  }

  private static func refreshBars() {
    let inlineViews = inline.values.compactMap(\.view)
    var bands: [String: [String: ShareBarState]] = [:]
    let snapshot = store?.state
    func state(_ id: String, in windowID: String) -> ShareBarState? {
      guard let snapshot, let tab = snapshot.tabs[id], tab.windowId == windowID,
        let window = snapshot.windows[windowID], webURL(tab.url), let target = page(id),
        let share = lifetime.share(for: target), let origin = origins[share.receipt] else { return nil }
      let host = (URL(string: origin)?.host ?? origin).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
      let caller = share.receipt.page
      let starting = !isFixtureShare(share) && SolaraCoreHost.displayCaptureState(browserId: caller.browserID)?["state"] as? String == "starting"
      let shared = share.target == target
      let receivingHost = target == caller && share.target.flatMap { snapshot.tabs[$0.tabID]?.windowId } != windowID
      let canStop = shared || receivingHost || (starting && target == caller)
      return ShareBarState(capturer: caller.tabID, tabId: id, shared: shared, host: host,
        theme: NativeMediaStack.theme(NativeLayoutAppearance(state: snapshot, profileId: window.profileId, incognito: window.incognito)),
        canStop: canStop, sourceLabel: share.target == nil ? "your screen" : nil, receiptID: share.receipt.id)
    }
    for view in inlineViews { view.update(state(view.tabID, in: view.windowID)) }
    if !lifetime.shares.isEmpty, let snapshot {
      for (windowID, window) in snapshot.windows where NativeWindowShell.host(windowID) != nil && !window.isSmall {
        let inlineIDs = Set(inlineViews.filter { $0.windowID == windowID }.map(\.tabID))
        for id in PaneOverlays.shared.tabIds(in: windowID) where !inlineIDs.contains(id) {
          if let row = state(id, in: windowID) { bands[windowID, default: [:]][id] = row }
        }
      }
    }
    NativeShareBand.update(bands)
  }

  #if DEBUG
    private static let fixtureShareID = "native-capture-fixture"

    static func fixture(_ tabID: String, _ json: String) -> Bool {
      guard let page = page(tabID), let body = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
      return receive(body, on: page, fixture: true)
    }

    static func fixtureBar(_ tabID: String, _ targetID: String) -> Bool {
      guard let caller = page(tabID) else { return false }
      guard !targetID.isEmpty else { return stop(caller) }
      guard let target = target(targetID, for: caller) else { return false }
      if let share = lifetime.shares[tabID], isFixtureShare(share) {
        guard retarget(share, to: target) else { return false }
      } else {
        guard receive(["id": fixtureShareID, "origin": "https://meet.test"], on: caller, fixture: true),
          let receipt = lifetime.pending[tabID], approved(receipt, source: "fixture", target: target, audio: false) else { return false }
      }
      refresh()
      return true
    }

    static func debugState() -> [String: Any] {
      ["pending": lifetime.pending.mapValues(\.id),
        "shares": lifetime.shares.mapValues { ["capturedTabId": $0.target?.tabID as Any? ?? NSNull()] }]
    }

    static func debugAction(_ tabID: String, _ name: String, _ value: String, _ audio: Bool) -> Bool {
      if name == "stop", let caller = page(tabID) { return stop(caller) }
      if name == "retarget", let share = lifetime.shares[tabID], let target = target(value, for: share.receipt.page) {
        let accepted = retarget(share, to: target)
        refresh()
        return accepted
      }
      guard let receipt = lifetime.pending[tabID] else { return false }
      switch name {
      case "cancel": action(.cancel, receipt: receipt); return true
      case "tab":
        guard let target = target(value, for: receipt.page),
          let source = SolaraCoreWebView.liveView(transferKey: target.tabID)?.mediaCaptureSourceId else { return false }
        return approved(receipt, source: source, target: target, audio: audio)
      case "source":
        guard let offer = offers[tabID], kind(value, offer) != nil else { return false }
        return approved(receipt, source: value, target: nil, audio: audio)
      default: return false
      }
    }
  #endif
}
