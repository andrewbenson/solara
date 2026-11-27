import AppKit
import ExpoModulesCore
import Foundation
import SolaraCore
import SolaraModel
import SolaraShell
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

    #if DEBUG
    AsyncFunction("traceDock") { (windowId: String) in
      FrameUpdates.readOnMain {
        guard let dock = NativeSidebarDock.dock(windowId) else { return }
        dock.devDockPeekEnabled = { TopStripPeekHost.hosts[windowId]?.view.peek.enabled ?? false }
        dock.devTraceDock()
      }
    }.runOnQueue(.main)

    AsyncFunction("dockTrace") { (windowId: String) -> [[Double]] in
      FrameUpdates.readOnMain { NativeSidebarDock.dock(windowId)?.devDockTrace ?? [] }
    }.runOnQueue(.main)

    #endif

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

    #if DEBUG && SOLARA_PROBES
    AsyncFunction("devScreenVisibleFrame") { (windowId: String) -> [Double]? in
      FrameUpdates.readOnMain {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false,
          let screen = WindowHost.window(id: windowId)?.screen else { return nil }
        let frame = screen.visibleFrame
        return [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
      }
    }.runOnQueue(.main)

    AsyncFunction("devResizeWindow") { (windowId: String, width: Double, height: Double) -> Bool in
      FrameUpdates.readOnMain {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false,
          width.isFinite, height.isFinite, width > 0, height > 0,
          let window = WindowHost.window(id: windowId) else { return false }
        window.setContentSize(NSSize(width: width, height: height))
        return true
      }
    }.runOnQueue(.main)
    #endif
  }
}

@MainActor
enum NativeTopStrip {
  static let kind = "topStrip"
  static let peekKind = "topStripPeek"
  static var hosts: [String: TopStripHost] = [:]

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeTopStrip)
  }

  static func register() {
    NativeNumberedTabs.register()
    guard !NativeWindowShell.nativeLayout else { return }
    HostedViews.register(kind) { windowId in
      guard !NativeWindowShell.nativeLayout else { return nil }
      let host = TopStripHost(windowId: windowId)
      let row = NativeLayoutStripRow(strip: host.view)
      let glow = TopStripGlowHost()
      hosts[windowId] = host
      host.dockedControls = row.controls
      TopStripGlowHost.hosts[windowId] = glow
      row.addSubview(glow.view, positioned: .below, relativeTo: host.view)
      host.onDropOver = {
        glow.applyDropOver(NativeSidebarShell.dropGlow(windowId, js: $0))
      }
      row.controls.onAction = { action in controlAction(action, windowId: windowId) }
      row.onPageWidth = { [weak host, weak row] width in
        host?.pageWidth = Double(width)
        guard let row else { return }
        glow.view.frame = StripDropGlowMetrics.frame(width: row.bounds.width, left: row.leadingInset + row.controls.profileSlotWidth,
          right: StripControlsLayout.trailingReservation)
      }
      host.onPresentation = { [weak row, weak host] state, window, look in
        guard let row, let host else { return }
        let fullscreen = window.fullScreen != nil && window.fullScreen != 0
        row.leadingInset = fullscreen ? 8 : ShellMetrics.topStripLeadingReservation
        row.controls.windowFullscreen = fullscreen
        row.controls.update(look.controls(state: state, window: window), theme: look.tokens)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        glow.look = (look.tokens["accent"] ?? "#4A77D4", look.dark)
        host.onDropOver(host.dropOver)
      }
      host.setNeedsRender()
      return HostedContent(
        view: row,
        onUnmount: {
          host.stop()
          glow.view.stop()
          if hosts[windowId] === host { hosts[windowId] = nil }
          if TopStripGlowHost.hosts[windowId] === glow { TopStripGlowHost.hosts[windowId] = nil }
        },
        takesFocus: false,
        onState: { [weak host] json in
          guard let host else { return }
          host.dropOver = (try? JSONValue.parse(json))?["dropOver"]?.bool ?? false
        })
    }
    TopStripPeekHost.register()
  }

  static func downloadsRect(_ windowId: String) -> NSRect? {
    if let controls = hosts[windowId]?.dockedControls, !controls.isHiddenOrHasHiddenAncestor { return controls.downloadsRect }
    return NativeLayoutChrome.downloadsRect(windowId)
  }

  static func controlAction(_ action: StripControlAction, windowId: String) {
    switch action {
    case .profileMenu:
      NativeSidebarShell.send(windowId, "profileMenu")
    case .toggleDownloads:
      guard let store = WorkspaceWrites.store, store.state.windows[windowId] != nil else { return }
      _ = try? store.dispatch(Command("setDownloadsOpen", [.string(windowId), .bool(store.state.windowUi[windowId]?.downloadsOpen != true)]), origin: .native)
      FrameUpdates.flush()
    }
  }

  static func presentation(state: BrowserState, window: BrowserWindow, look: NativeLayoutAppearance, floating: Bool = false) -> StripHostState {
    var host = StripHostState(profileId: window.profileId, dark: look.dark)
    host.theme = look.tokens
    host.border = look.border
    host.glow = look.glow
    host.floating = floating
    host.pages = SidebarPagerView.profileIDs(state: state, windowId: window.id).map { id in
      let page = id == window.profileId ? look : NativeLayoutAppearance(state: state, profileId: id, incognito: false, strip: true)
      return SidebarPageLook(profileId: id, dark: page.dark, theme: page.tokens, border: page.border, glow: page.glow, tidy: false, incognito: false)
    }
    host.closeHint = CommandShortcutSnapshot().hint("closeTab", state: state)
    let store = NativeStoreHandle.store
    host.applyWorkspace(state: state, windowId: window.id) { store?.pageEngineMark($0, in: state) }
    return host
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
    return json(["items": items, "chip": page.pageLayout.chip, "scrolled": page.scrolledX, "pageWidth": page.pageWidth, "keys": page.pageLayout.items.map(\.key)])
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
  var renderingEnabled = true
  private var stopped = false
  private var hostState: StripHostState?
  private var state: BrowserState?
  private var listener: Int?
  private var mediaListener: UUID?
  var storeSubscriptions: Int { listener == nil ? 0 : 1 }
  private let commits = TopStripCommits()
  weak var dockedControls: StripControlsView?
  var dropOver = false { didSet { if oldValue != dropOver { onDropOver(dropOver) } } }
  var onDropOver: (Bool) -> Void = { _ in }
  var onPresentation: ((BrowserState, BrowserWindow, NativeLayoutAppearance) -> Void)?
  private let floating: Bool
  private let projectsStore: Bool
  private var rendered = false
  private var rendering = false
  private var dragObserver: NSObjectProtocol?
  private var pagerObserver: NSObjectProtocol?
  #if SOLARA_PROBES
  private var probeStopped = false
  #endif
  var pageWidth: Double? {
    didSet { if pageWidth != oldValue { render() } }
  }

  var swipeWidth: Double? {
    hostState.map { (pageWidth ?? $0.pageWidth) + ($0.floating ? 0 : 2 * Double(StripMetrics.flare)) }
  }

  init(windowId: String, takesDrops: Bool = true, subscribeToStore: Bool = true) {
    self.windowId = windowId
    floating = !takesDrops
    projectsStore = subscribeToStore
    view = TopStripView(windowId: windowId)
    view.takesDrops = takesDrops
    view.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    view.onAction = { [weak self] action in self?.handle(action) }
    view.dragBridge = TopStripDrag.shared
    commits.host = self
    mediaListener = NativeMediaStack.listen { [weak self] in self?.setNeedsRender() }
    #if SOLARA_PROBES
    NativeWorkCounters.host(self, windowId: windowId, kind: takesDrops ? "topStrip" : "topStripPeek") { host in
      (!host.probeStopped, (host.listener == nil ? 0 : 1) + (host.pagerObserver == nil ? 0 : 1))
    }
    #endif
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.view.setPagerPosition(position) }
    }
    if subscribeToStore, takesDrops {
      dragObserver = NotificationCenter.default.addObserver(forName: TabDragSession.changed, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { if let self { self.onDropOver(self.dropOver) } }
      }
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
    if rendered, projectsStore { NativeProfilePager.hosts[windowId]?.stripScrollOffsets[floating] = view.scrollOffsets }
    commits.host = nil
    NativeMediaStack.stopListening(mediaListener)
    mediaListener = nil
    onPresentation = nil
    onDropOver = { _ in }
    if let dragObserver { NotificationCenter.default.removeObserver(dragObserver) }
    dragObserver = nil
    view.onAction = { _ in }
    view.stop()
    #if SOLARA_PROBES
    probeStopped = true
    #endif
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
  }

  func commit(_ next: BrowserState) {
    guard !stopped else { return }
    state = next
    setNeedsRender()
  }

  func apply(state: BrowserState, host: StripHostState) {
    guard !stopped else { return }
    self.state = state
    hostState = host
    render()
  }

  func setNeedsRender() {
    FrameUpdates.schedule(self) { [weak self] in self?.render() }
  }

  private func render() {
    guard !stopped, !rendering, let state = state ?? NativeStoreHandle.store?.state,
      let window = state.windows[windowId] else { return }
    rendering = true
    defer { rendering = false }
    self.state = state
    if projectsStore {
      let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito, strip: true)
      onPresentation?(state, window, look)
      guard renderingEnabled else { return }
      hostState = NativeTopStrip.presentation(state: state, window: window, look: look, floating: floating)
    }
    guard renderingEnabled, var hostState else { return }
    if let pageWidth { hostState.pageWidth = pageWidth }
    hostState.capture = NowPlayingStore.shared.capture
    if !rendered, projectsStore {
      view.pendingScrollOffsets = NativeProfilePager.hosts[windowId]?.stripScrollOffsets[floating] ?? [:]
    }
    view.update(state: state, host: hostState)
    if !rendered && view.current != nil {
      rendered = true
      if let position = ACPager.snapshot(windowId)?["position"] as? Double { view.setPagerPosition(position) }
    }
  }

  private func handle(_ action: StripAction) {
    guard !stopped else { return }
    switch action {
    case .click(let tabId, let mods):
      if WorkspaceActionRouter.ownedClick(windowId: windowId, tabId: tabId, mods: mods) {
        FrameUpdates.flush()
      } else {
        NSLog("[strip] click refused: native store unavailable, dispatch failed or target stale")
      }
    case .activate(let tabId):
      _ = dispatch("activate", tabId)
    case .close(let tabId):
      if let owned = WorkspaceActionRouter.ownedClose(tabId: tabId, middle: false) {
        NativeWorkspaceCommands.runCloseRoute(owned.route, tabId: tabId, store: owned.store)
      } else {
        NSLog("[strip] close refused: native store unavailable, dispatch failed or target stale")
      }
    case .toggleMute(let tabId):
      if !NativeTabMenu.sidebarAction("toggleMute", tabId: tabId, windowId: windowId) { NSLog("[strip] toggleMute refused: native store unavailable, dispatch failed or target stale") }
    case .tabMenu(let tabId):
      let opened = NativeTabMenu.open(tabId, windowId: windowId)
      if !opened {
        NSLog("[strip] tabMenu refused: native store unavailable, dispatch failed or target stale")
      }
    case .groupMenu(let groupId):
      let opened = NativeGroupMenu.open(groupId, windowId: windowId)
      if !opened { NSLog("[strip] groupMenu refused: native store unavailable, dispatch failed or target stale") }
    case .toggleGroup(let groupId, let collapse):
      if !NativeGroupActions.toggle(groupId, collapsed: { _ in collapse }) { NSLog("[strip] toggleGroup refused: native store unavailable, dispatch failed or target stale") }
    case .closeGroup(let groupId):
      if !NativeGroupActions.close(groupId) { NSLog("[strip] closeGroup refused: native store unavailable, dispatch failed or target stale") }
    case .tuck(let groupId):
      if !NativeGroupActions.tuck(groupId, windowId: windowId) { NSLog("[strip] tuck refused: native store unavailable, dispatch failed or target stale") }
    case .folderMenu(let groupId):
      if !NativeTileFolders.stripGroupMenu(windowId: windowId, groupId: groupId) { NSLog("[strip] folderMenu refused: native store unavailable, dispatch failed or target stale") }
    case .tileFolder(let folderId):
      if !NativeTileFolders.stripTileMenu(windowId: windowId, folderId: folderId) { NSLog("[strip] tileFolder refused: native store unavailable, dispatch failed or target stale") }
    case .tileFolderMenu(let folderId):
      if !NativeTileFolders.folderMenu(windowId: windowId, folderId: folderId) { NSLog("[strip] tileFolderMenu refused: native store unavailable, dispatch failed or target stale") }
    case .newTab(let split):
      if split { call("newTab", "", ["split": true]) }
      else { _ = NativeWorkspaceCommands.perform("newTab", windowId: windowId) }
    }
  }

  private func dispatch(_ name: String, _ tabId: String) -> Bool {
    guard let store = WorkspaceWrites.store else {
      NSLog("[strip] %@ refused: native store unavailable", name)
      return false
    }
    do {
      _ = try store.dispatch(Command(name, [.string(tabId)]), origin: .native)
      FrameUpdates.flush()
      return true
    } catch {
      NSLog("[strip] %@ refused: %@", name, String(describing: error))
      return false
    }
  }

  private func call(_ name: String, _ id: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
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
    guard let store = WorkspaceWrites.store, !ids.isEmpty else {
      NSLog("[strip] land refused: native store unavailable or no tabs")
      return false
    }
    do {
      if source != windowId {
        _ = try store.dispatch(Command("moveTabsToWindow", [JSONValue(ids), JSONValue(windowId)]), origin: .native)
      }
      _ = try store.dispatch(Command("placeTabs", [JSONValue(ids), ["pinned": false, "beforeId": JSONValue(beforeId)]]), origin: .native)
      FrameUpdates.flush()
      return true
    } catch {
      FrameUpdates.flush()
      NSLog("[strip] land refused: %@", String(describing: error))
      return false
    }
  }

  func drop(ids: [String], drop: JSONValue) -> Bool {
    guard let store = WorkspaceWrites.store else {
      NSLog("[strip] drop refused: native store unavailable")
      return false
    }
    let commit: Commit
    do {
      commit = try store.dispatch(Command("dropTabs", [JSONValue(ids), drop]), origin: .native)
    } catch {
      NSLog("[strip] drop refused: %@", String(describing: error))
      return false
    }
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
    #if DEBUG
    let devDockSnapshot = trace == "dock" ? NativeSidebarDock.dock(windowId)?.devDockTrace ?? [] : []
    #endif
    var result: [String: Any] = ["items": items, "keys": StripQuery(store.state).keys(windowId: windowId, profileId: model.profileId),
      "controls": controls(windowId: windowId) ?? NSNull(),
      "panelOpen": store.state.windowUi[windowId]?.panelOpen ?? false,
      "downloadsOpen": store.state.windowUi[windowId]?.downloadsOpen ?? false,
      "groupSizes": sizes, "groups": groups.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") },
      "groupTrace": trace == "group" ? samples(page?.groupTrace) : [], "slotTrace": trace == "slot" ? samples(page?.slotTrace) : [],
      "glowTrace": trace == "glow" ? samples(TopStripGlowHost.hosts[windowId]?.view.trace) : [],
      "peekTrace": trace == "peek" ? samples(TopStripPeekHost.hosts[windowId]?.view.slideTrace) : [],
      "peek": TopStripPeekHost.hosts[windowId]?.describe() ?? [:], "peekMonitors": StripPeekView.monitors]
    #if DEBUG
    result["dockTrace"] = devDockSnapshot
    #endif
    return result
  }

  private static func controls(windowId: String) -> [String: Any]? {
    guard let strip = NativeTopStrip.hosts[windowId]?.view, let content = strip.window?.contentView else { return nil }
    guard let host = NativeTopStrip.hosts[windowId]?.dockedControls ?? NativeLayoutChrome.stripControls(windowId),
      !host.isHiddenOrHasHiddenAncestor else { return nil }
    let profile = host.subviews.first { !$0.isHidden && $0.accessibilityLabel() != "Downloads" }
    let downloads = host.subviews.first { $0.accessibilityLabel() == "Downloads" }
    func rect(_ view: NSView?) -> Any {
      guard let view else { return NSNull() }
      let frame = view.convert(view.bounds, to: content)
      let y = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
      return [frame.minX, y, frame.width, frame.height].map(Double.init)
    }
    let slot = host.convert(CGRect(x: host.leadingInset, y: 0, width: host.profileSlotWidth, height: host.bounds.height), to: content)
    let slotY = content.isFlipped ? slot.minY : content.bounds.height - slot.maxY
    let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> Any? in
      guard let button = strip.window?.standardWindowButton(kind) else { return nil }
      return rect(button)
    }
    return ["container": rect(content), "host": rect(host), "profile": rect(profile), "downloads": rect(downloads),
      "strip": rect(strip), "title": profile?.accessibilityLabel() ?? "",
      "profileSlot": [slot.minX, slotY, slot.width, slot.height].map(Double.init), "trafficLights": lights]
  }

  private static func samples(_ source: [[Double]]?) -> [[Double]] {
    guard let source else { return [] }
    return Array(source.suffix(128))
  }
}
#endif
