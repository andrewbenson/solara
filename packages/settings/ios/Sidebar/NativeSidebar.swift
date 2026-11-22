import AppKit
import Foundation
import SolaraModel
import SolaraStore
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
  private var state: BrowserState?
  private var listener: Int?
  var storeSubscriptions: Int { listener == nil ? 0 : 1 }
  private let commits = SidebarCommits()
  private var markUri: String?
  private var pagerObserver: NSObjectProtocol?
  private var fedByShell = false
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
    NativeTileFolders.hostStopped(windowId, page: view.current)
    commits.host = nil
    view.onAction = { _ in }
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
    guard !stopped, let next = SidebarHostState.decode(json) else { return }
    if next == hostState { return }
    hostState = next
    loadMark(next.newTabMark)
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
    loadMark(host.newTabMark)
    render()
  }

  private func setNeedsRender() {
    FrameUpdates.schedule(self) { [weak self] in self?.render() }
  }

  func renameChanged() { setNeedsRender() }

  private func render() {
    guard !stopped, var host = hostState, let state = state ?? NativeStoreHandle.store?.state else { return }
    self.state = state
    if let renaming = NativeWorkspaceRename.override(windowId) { host.renaming = renaming }
    if !fedByShell, let window = state.windows[windowId] {
      let stacked = NativeMediaStack.players(state: state, windowId: windowId,
        look: NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito))
      host.player = stacked.first
      host.stack = stacked
    }
    view.update(state: state, host: host)
    NativeTileFolders.render(windowId: windowId)
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
      guard let self, !self.stopped, self.markUri == uri, let image else { return }
      image.isTemplate = true
      self.view.favicons.newTabMark = image
      self.setNeedsRender()
    }
  }

  private func handle(_ action: SidebarAction) {
    guard !stopped else { return }
    switch action {
    case .click(let tabId, let mods):
      if WorkspaceActionRouter.ownedClick(windowId: windowId, tabId: tabId, mods: mods) {
        FrameUpdates.flush()
        call("handled", tabId)
      } else if mods.none, hostState?.selection.isEmpty == true, activate(tabId) {
        call("clicked", tabId)
      } else {
        call("click", tabId, ["meta": mods.meta, "shift": mods.shift, "alt": mods.alt])
      }
    case .close(let tabId):
      if let owned = WorkspaceActionRouter.ownedClose(tabId: tabId, middle: false) {
        call("handled", tabId)
        NativeWorkspaceCommands.runCloseRoute(owned.route, tabId: tabId, store: owned.store) { [weak self] cleared in
          self?.call("removedPin", tabId, ["cleared": cleared])
        }
      } else {
        call("close", tabId)
      }
    case .middleClick(let tabId):
      if let owned = WorkspaceActionRouter.ownedClose(tabId: tabId, middle: true) {
        call("handled", tabId)
        NativeWorkspaceCommands.runCloseRoute(owned.route, tabId: tabId, store: owned.store) { [weak self] cleared in
          self?.call("removedPin", tabId, ["cleared": cleared])
        }
      } else {
        call("middleClick", tabId)
      }
    case .rename(let kind, let id):
      if !NativeWorkspaceRename.begin(windowId: windowId, kind: kind == "group" ? .group : .tab, id: id) { call("rename", id, ["kind": kind]) }
    case .backToPinned(let tabId): call("backToPinned", tabId)
    case .tileDoubleClick(let tabId): call("tileDoubleClick", tabId)
    case .toggleMute(let tabId): call("toggleMute", tabId)
    case .tabMenu(let tabId): call("tabMenu", tabId)
    case .groupMenu(let groupId):
      let opened = NativeGroupMenu.open(groupId, windowId: windowId) { [weak self] id, choice in
        guard let self, !self.stopped else { return NSLog("[groups] %@: the %@ closed before its menu's %@ reached JS", id, "sidebar", choice) }
        self.call("groupMenuChoice", id, ["choice": choice])
      }
      if !opened { call("groupMenu", groupId) }
    case .toggleGroup(let groupId):
      if !NativeGroupActions.toggle(groupId, collapsed: { !$0.collapsed }) { call("toggleGroup", groupId) }
    case .closeGroup(let groupId):
      if !NativeGroupActions.close(groupId) { call("closeGroup", groupId) }
    case .sidebarMenu: call("sidebarMenu", "")
    case .overflowMenu: call("overflowMenu", "")
    case .newTab(let split): call("newTab", "", ["split": split])
    case .newTabDoubleClick: call("newTab", "", ["split": false])
    case .folder(let folderId):
      if NativeTileFolders.toggle(windowId: windowId, folderId: folderId) { call("handled", folderId) } else { call("folder", folderId) }
    case .folderMenu(let folderId):
      if !NativeTileFolders.folderMenu(windowId: windowId, folderId: folderId) { call("folderMenu", folderId) }
    case .tidy: call("tidy", hostState?.profileId ?? "")
    case .clear: call("clear", "")
    case .cleanUp(let choice): call("cleanUp", choice.rawValue)
    case .hover(let kind, let id): call("hover", id ?? "", ["kind": kind ?? NSNull()])
    case .scrolled:
      if NativeTileFolders.owned {
        NativeTileFolders.close(in: windowId)
        call("handled", "")
      } else {
        call("scrolled", "")
      }
    case .renamed(let kind, let id, let text):
      if WorkspaceActionRouter.ownedStore == nil {
        call("renamed", id, ["kind": kind, "text": text ?? NSNull()])
      } else if let text {
        NativeWorkspaceRename.commit(windowId: windowId, kind: kind == "group" ? .group : .tab, id: id, text: text)
      } else {
        NativeWorkspaceRename.end(windowId: windowId, id: id)
      }
    case .live(let action, let folderId, let id, let meta): call("live", folderId, ["action": action, "item": id ?? NSNull(), "meta": meta])
    case .media(let tabId, let action): NativeMediaStack.perform(windowId: windowId, tabId: tabId, action: action)
    }
  }

  private func activate(_ tabId: String) -> Bool {
    guard let store = NativeStoreHandle.store else { return false }
    do {
      _ = try store.dispatch(Command("activate", [.string(tabId)]), origin: .native)
      FrameUpdates.flush()
      return true
    } catch {
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
  static let topic = "sidebar.live"
  private static var observer: UUID?
  private static var generation = 0

  static func start() {
    guard observer == nil else { return }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
  }

  private static func receive(_ value: Any?) {
    guard let text = value as? String else { return }
    generation += 1
    let ticket = generation
    Task.detached(priority: .userInitiated) {
      guard let state = SidebarLive.decode(text) else { return }
      await MainActor.run {
        guard ticket == generation else { return }
        SidebarLiveFeed.shared.apply(state)
      }
    }
  }
}
