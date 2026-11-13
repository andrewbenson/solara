import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

public class TopStripModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraTopStrip")

    OnCreate { DispatchQueue.main.async { FrameUpdates.readOnMain { NativeTopStrip.register() } } }

    AsyncFunction("items") { (windowId: String) -> String in
      FrameUpdates.readOnMain { NativeTopStrip.items(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("hoverShifts") { (windowId: String) -> String in
      FrameUpdates.readOnMain { NativeTopStrip.hoverShifts(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("groupSize") { (windowId: String, groupId: String) -> Double? in
      FrameUpdates.readOnMain { NativeTopStrip.hosts[windowId]?.view.current?.groupSize(groupId) }
    }.runOnQueue(.main)

    AsyncFunction("peekMonitors") { () -> Int in
      FrameUpdates.readOnMain { StripPeekView.monitors }
    }.runOnQueue(.main)

    AsyncFunction("traceGroup") { (windowId: String, groupId: String) in
      FrameUpdates.readOnMain { NativeTopStrip.hosts[windowId]?.view.current?.traceGroup(groupId) }
    }.runOnQueue(.main)

    AsyncFunction("groupTrace") { (windowId: String) -> [[Double]] in
      FrameUpdates.readOnMain { NativeTopStrip.hosts[windowId]?.view.current?.groupTrace ?? [] }
    }.runOnQueue(.main)

    AsyncFunction("traceSlot") { (windowId: String, tabIds: String) in
      FrameUpdates.readOnMain { NativeTopStrip.hosts[windowId]?.view.current?.traceSlot(tabIds) }
    }.runOnQueue(.main)

    AsyncFunction("slotTrace") { (windowId: String) -> [[Double]] in
      FrameUpdates.readOnMain { NativeTopStrip.hosts[windowId]?.view.current?.slotTrace ?? [] }
    }.runOnQueue(.main)

    AsyncFunction("incoming") { (windowId: String, x: Double?, y: Double?) -> String in
      FrameUpdates.readOnMain {
        guard let page = NativeTopStrip.incomingPage(windowId) else { return "null" }
        let point = x.flatMap { x in y.map { CGPoint(x: x, y: $0) } }
        guard case .some(let beforeId) = page.incoming(at: point) else { return "null" }
        return NativeTopStrip.json(["beforeId": beforeId.map { $0 as Any } ?? NSNull()]) ?? "null"
      }
    }.runOnQueue(.main)

    AsyncFunction("peekShow") { (windowId: String) in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId]?.view.peek.show() }
    }.runOnQueue(.main)

    AsyncFunction("peekHide") { (windowId: String) in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId]?.view.peek.hide() }
    }.runOnQueue(.main)

    AsyncFunction("pinPeek") { (windowId: String, value: Double) in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId]?.view.pin(value) }
    }.runOnQueue(.main)

    AsyncFunction("tracePeek") { (windowId: String) in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId]?.view.traceSlide() }
    }.runOnQueue(.main)

    AsyncFunction("peekTrace") { (windowId: String) -> [[Double]] in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId]?.view.slideTrace ?? [] }
    }.runOnQueue(.main)

    AsyncFunction("traceGlow") { (windowId: String) in
      FrameUpdates.readOnMain { TopStripGlowHost.hosts[windowId]?.view.startTrace() }
    }.runOnQueue(.main)

    AsyncFunction("glowTrace") { (windowId: String) -> [[Double]] in
      FrameUpdates.readOnMain { TopStripGlowHost.hosts[windowId]?.view.trace ?? [] }
    }.runOnQueue(.main)

    AsyncFunction("peekState") { (windowId: String) -> String in
      FrameUpdates.readOnMain { TopStripPeekHost.hosts[windowId].flatMap { NativeTopStrip.json($0.describe()) } ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("endIncoming") { (windowId: String) in
      FrameUpdates.readOnMain {
        NativeTopStrip.hosts[windowId]?.view.current?.endIncoming()
        TopStripPeekHost.hosts[windowId]?.strip.view.current?.endIncoming()
      }
    }.runOnQueue(.main)

    AsyncFunction("keys") { (windowId: String, profileId: String) -> [String] in
      FrameUpdates.readOnMain { NativeStoreHandle.store.map { StripQuery($0.state).keys(windowId: windowId, profileId: profileId) } ?? [] }
    }.runOnQueue(.main)
  }
}

@MainActor
enum NativeTopStrip {
  static let kind = "topStrip"
  static let floatingKind = "topStripFloating"
  static let peekKind = "topStripPeek"
  static var hosts: [String: TopStripHost] = [:]

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeTopStrip)
  }

  static func register() {
    NativeNumberedTabs.register()
    guard enabled else { return }
    HostedViews.register(kind) { windowId in
      let host = TopStripHost(windowId: windowId)
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
    HostedViews.register(floatingKind) { windowId in
      let host = TopStripHost(windowId: windowId, takesDrops: false)
      return HostedContent(view: host.view, onUnmount: { host.stop() }, takesFocus: false, onState: { [weak host] json in host?.apply(json) })
    }
    TopStripPeekHost.register()
  }

  static func incomingPage(_ windowId: String) -> StripPageView? {
    if let page = hosts[windowId]?.view.current, page.window != nil { return page }
    guard let peek = TopStripPeekHost.hosts[windowId], peek.view.live else { return nil }
    return peek.strip.view.current
  }

  static func json(_ value: Any) -> String? {
    (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func items(windowId: String) -> String? {
    guard let host = hosts[windowId], let page = host.view.current, let window = page.window, let content = window.contentView else { return nil }
    let items = page.describe().map { item -> [String: Any] in
      var out = item
      let frame = NSRect(x: item["x"] as? CGFloat ?? 0, y: item["y"] as? CGFloat ?? 0, width: item["width"] as? CGFloat ?? 0, height: item["height"] as? CGFloat ?? 0)
      let inWindow = page.convert(frame, to: nil)
      out["windowX"] = inWindow.minX
      out["windowY"] = content.bounds.height - inWindow.maxY
      return out
    }
    return json(["items": items, "chip": page.pageLayout.chip, "scrolled": page.scrolledX, "keys": page.pageLayout.items.map(\.key)])
  }

  static func hoverShifts(windowId: String) -> String? {
    guard let page = hosts[windowId]?.view.current else { return nil }
    let result = page.hoverShifts()
    return json(["hovered": result.hovered, "shifts": result.shifts])
  }
}

final class TopStripCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false
  weak var host: TopStripHost?

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
final class TopStripHost {
  let windowId: String
  let view: TopStripView
  private var hostState: StripHostState?
  private var state: BrowserState?
  private var listener: Int?
  private let commits = TopStripCommits()
  private var markUri: String?
  private var pagerObserver: NSObjectProtocol?
  var pageWidth: Double? {
    didSet { if pageWidth != oldValue { render() } }
  }

  var swipeWidth: Double? {
    hostState.map { (pageWidth ?? $0.pageWidth) + ($0.floating ? 0 : 2 * Double(StripMetrics.flare)) }
  }

  init(windowId: String, takesDrops: Bool = true) {
    self.windowId = windowId
    view = TopStripView(windowId: windowId)
    view.takesDrops = takesDrops
    view.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    view.onAction = { [weak self] action in self?.handle(action) }
    view.dragBridge = TopStripDrag.shared
    commits.host = self
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.view.setPagerPosition(position) }
    }
    if let store = NativeStoreHandle.store {
      state = store.state
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
  }

  func stop() {
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
  }

  func apply(_ json: String) {
    guard let next = StripHostState.decode(json) else { return }
    if next == hostState { return }
    hostState = next
    loadMark(next.newTabMark)
    setNeedsRender()
  }

  func commit(_ next: BrowserState) {
    state = next
    setNeedsRender()
  }

  private func setNeedsRender() {
    FrameUpdates.schedule(self) { [weak self] in self?.render() }
  }

  private func render() {
    guard var hostState, let state = state ?? NativeStoreHandle.store?.state else { return }
    self.state = state
    if let pageWidth { hostState.pageWidth = pageWidth }
    view.update(state: state, host: hostState)
  }

  private func loadMark(_ uri: String?) {
    guard let uri, uri != markUri else { return }
    markUri = uri
    if let image = SettingsAdapters.image(uri) {
      image.isTemplate = true
      view.favicons.newTabMark = image
      return
    }
    guard let url = URL(string: uri) else { return }
    Task { @MainActor [weak self] in
      let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
      guard let self, let image else { return }
      image.isTemplate = true
      self.view.favicons.newTabMark = image
      self.setNeedsRender()
    }
  }

  private func handle(_ action: StripAction) {
    switch action {
    case .click(let tabId, let mods):
      call("click", tabId, ["meta": mods.meta, "shift": mods.shift, "alt": mods.alt])
    case .activate(let tabId):
      if !dispatch("activate", tabId) { call("activate", tabId) }
    case .close(let tabId): call("close", tabId)
    case .toggleMute(let tabId): call("toggleMute", tabId)
    case .tabMenu(let tabId): call("tabMenu", tabId)
    case .groupMenu(let groupId): call("groupMenu", groupId)
    case .toggleGroup(let groupId, let collapse): call("toggleGroup", groupId, ["collapse": collapse])
    case .closeGroup(let groupId): call("closeGroup", groupId)
    case .tuck(let groupId): call("tuck", groupId)
    case .folderMenu(let groupId): call("folderMenu", groupId)
    case .tileFolder(let folderId): call("tileFolder", folderId)
    case .tileFolderMenu(let folderId): call("tileFolderMenu", folderId)
    case .newTab(let split): call("newTab", "", ["split": split])
    }
  }

  private func dispatch(_ name: String, _ tabId: String) -> Bool {
    guard let store = NativeStoreHandle.store else { return false }
    do {
      _ = try store.dispatch(Command(name, [.string(tabId)]), origin: .native)
      FrameUpdates.flush()
      return true
    } catch {
      return false
    }
  }

  private func call(_ name: String, _ id: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js("topStrip.action", windowId, name, id, payload.value)
    }
  }
}

@MainActor
final class TopStripDrag: StripDragBridge {
  static let shared = TopStripDrag()

  private var dx: CGFloat = 0

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {
    dx = 0
    NativeTabDrag.shared.begin(windowId: windowId, tabId: tabId, tabIds: tabIds) { false }
  }

  func dragPicture(windowId: String, rect: CGRect, grab: CGPoint) {
    NativeTabDrag.shared.picture(windowId: windowId, chip: { [weak self] in rect.offsetBy(dx: self?.dx ?? 0, dy: 0) }, grab: CGPoint(x: grab.x - rect.minX, y: grab.y - rect.minY))
  }

  func dragMoved(windowId: String, at: CGPoint, lifted: Bool, dx: CGFloat) {
    self.dx = dx
    NativeTabDrag.shared.move(windowId: windowId, at: at, lifted: lifted)
  }

  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    NativeTabDrag.shared.end(windowId: windowId, commit: commit, done: done)
  }

  func land(ids: [String], from source: String, in windowId: String, beforeId: String?) -> Bool {
    guard let store = NativeStoreHandle.store, !ids.isEmpty else { return false }
    if source != windowId {
      guard (try? store.dispatch(Command("moveTabsToWindow", [JSONValue(ids), JSONValue(windowId)]), origin: .native)) != nil else { return false }
    }
    let placed = (try? store.dispatch(Command("placeTabs", [JSONValue(ids), ["pinned": false, "beforeId": JSONValue(beforeId)]]), origin: .native)) != nil
    FrameUpdates.flush()
    return placed
  }

  func drop(ids: [String], drop: JSONValue) -> Bool {
    guard let store = NativeStoreHandle.store, let commit = try? store.dispatch(Command("dropTabs", [JSONValue(ids), drop]), origin: .native) else { return false }
    FrameUpdates.flush()
    return !commit.changes.isEmpty
  }
}

#if SOLARA_PROBES
@MainActor
public enum TopStripRead {
  public static func snapshot(windowId: String, trace: String?) -> [String: Any]? {
    guard let store = NativeStoreHandle.store, let model = store.state.windows[windowId] else { return nil }
    let page = NativeTopStrip.hosts[windowId]?.view.current
    var sizes: [String: Double] = [:]
    var groups: [[String: Any]] = []
    for (id, group) in store.state.groups where group.windowId == windowId {
      if let size = page?.groupSize(id) { sizes[id] = size }
      groups.append(["id": id, "collapsed": group.collapsed])
    }
    var items: Any = NSNull()
    if let json = NativeTopStrip.items(windowId: windowId), let data = json.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) { items = value }
    return ["items": items, "keys": StripQuery(store.state).keys(windowId: windowId, profileId: model.profileId),
      "panelOpen": store.state.windowUi[windowId]?.panelOpen ?? false,
      "downloadsOpen": store.state.windowUi[windowId]?.downloadsOpen ?? false,
      "groupSizes": sizes, "groups": groups.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") },
      "groupTrace": trace == "group" ? samples(page?.groupTrace) : [], "slotTrace": trace == "slot" ? samples(page?.slotTrace) : [],
      "glowTrace": trace == "glow" ? samples(TopStripGlowHost.hosts[windowId]?.view.trace) : [],
      "peekTrace": trace == "peek" ? samples(TopStripPeekHost.hosts[windowId]?.view.slideTrace) : [],
      "peek": TopStripPeekHost.hosts[windowId]?.describe() ?? [:], "peekMonitors": StripPeekView.monitors]
  }

  private static func samples(_ source: [[Double]]?) -> [[Double]] {
    guard let source else { return [] }
    return Array(source.suffix(128))
  }
}
#endif
