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
    NativeSidebarLive.start()
    NativeSidebarHoverCard.start()
    NativeSidebarShell.register()
    NativeSidebarDock.register()
    HostedViews.register(kind) { windowId in
      let host = SidebarHost(windowId: windowId)
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
      if view is SidebarPlayerView { return view.isHiddenOrHasHiddenAncestor ? [] : [view] }
      return view.subviews.flatMap(walk)
    }
    return hosts[windowId].map { walk($0.view) } ?? []
  }

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
  private var hostState: SidebarHostState?
  private var state: BrowserState?
  private var listener: Int?
  private let commits = SidebarCommits()
  private var markUri: String?
  private var pagerObserver: NSObjectProtocol?

  init(windowId: String) {
    self.windowId = windowId
    view = SidebarPagerView(windowId: windowId)
    view.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    view.onAction = { [weak self] action in self?.handle(action) }
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
    guard let next = SidebarHostState.decode(json) else { return }
    if next == hostState { return }
    hostState = next
    loadMark(next.newTabMark)
    render()
  }

  func commit(_ next: BrowserState) {
    state = next
    render()
  }

  private func render() {
    guard let hostState, let state = state ?? NativeStoreHandle.store?.state else { return }
    self.state = state
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
      self.render()
    }
  }

  private func handle(_ action: SidebarAction) {
    switch action {
    case .click(let tabId, let mods):
      if mods.none, hostState?.selection.isEmpty == true, activate(tabId) {
        call("clicked", tabId)
      } else {
        call("click", tabId, ["meta": mods.meta, "shift": mods.shift, "alt": mods.alt])
      }
    case .close(let tabId): call("close", tabId)
    case .middleClick(let tabId): call("middleClick", tabId)
    case .rename(let kind, let id): call("rename", id, ["kind": kind])
    case .backToPinned(let tabId): call("backToPinned", tabId)
    case .tileDoubleClick(let tabId): call("tileDoubleClick", tabId)
    case .toggleMute(let tabId): call("toggleMute", tabId)
    case .tabMenu(let tabId): call("tabMenu", tabId)
    case .groupMenu(let groupId): call("groupMenu", groupId)
    case .toggleGroup(let groupId): call("toggleGroup", groupId)
    case .closeGroup(let groupId): call("closeGroup", groupId)
    case .sidebarMenu: call("sidebarMenu", "")
    case .overflowMenu: call("overflowMenu", "")
    case .newTab(let split): call("newTab", "", ["split": split])
    case .newTabDoubleClick: call("newTab", "", ["split": false])
    case .folder(let folderId): call("folder", folderId)
    case .folderMenu(let folderId): call("folderMenu", folderId)
    case .tidy: call("tidy", hostState?.profileId ?? "")
    case .clear: call("clear", "")
    case .cleanUp(let choice): call("cleanUp", choice.rawValue)
    case .hover(let kind, let id): call("hover", id ?? "", ["kind": kind ?? NSNull()])
    case .scrolled: call("scrolled", "")
    case .renamed(let kind, let id, let text): call("renamed", id, ["kind": kind, "text": text ?? NSNull()])
    case .live(let action, let folderId, let id, let meta): call("live", folderId, ["action": action, "item": id ?? NSNull(), "meta": meta])
    case .media(let tabId, let action): NativeMedia.player("sidebarPlayer", windowId, tabId, action)
    }
  }

  private func activate(_ tabId: String) -> Bool {
    guard let store = NativeStoreHandle.store else { return false }
    do {
      _ = try store.dispatch(Command("activate", [.string(tabId)]), origin: .native)
      return true
    } catch {
      return false
    }
  }

  private func call(_ name: String, _ id: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor in
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
