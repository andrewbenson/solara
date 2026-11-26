import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeExtensionSidePanel {
  nonisolated static let kind = "extensionSidePanel"
  static let roomDidChange = Notification.Name("SolaraSidePanelRoomChanged")

  private struct Source: Equatable {
    let id: String
    let tabId: String?
    let browserId: Int32
    let catalogProfile: String
    let pageProfile: String
  }

  @MainActor
  private final class OwnedPanel {
    let store: Store
    let generation: Int
    let lifecycle = ExtensionSidePanelLifecycle()
    var listener: Int?
    var state: SidePanelState?
    var source: Source?
    var resolvedURL: String?
    var room: CGFloat = 0
    var fullscreen = false

    @MainActor init(store: Store) {
      self.store = store
      generation = NativeStoreHandle.ownershipGeneration
    }
  }

  private static var panels: [String: OwnedPanel] = [:]
  private static var installed = false

  static func extensionId(windowId: String) -> String? { panels[windowId]?.lifecycle.extensionId }
  static func room(_ windowId: String) -> CGFloat { panels[windowId]?.room ?? 0 }

  static func install() {
    guard !installed else { return }
    installed = true
    _ = NativeStoreHandle.subscribeLifecycle {
      for (id, panel) in Array(panels) where !valid(id, panel) { close(id) }
    }
    _ = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraExtensionSidePanel"), object: nil, queue: .main) { note in
      guard let browserId = note.userInfo?["browserId"] as? Int, browserId != 0,
        let id = note.userInfo?["extensionId"] as? String, let opens = note.userInfo?["open"] as? Bool else { return }
      MainActor.assumeIsolated {
        guard let state = NativeStoreHandle.store?.state,
          let page = PageRegistry.shared.descriptors.first(where: { $0.ready?.browserId == browserId }),
          let windowId = state.tabs[page.tabID]?.windowId else { return }
        if opens { open(windowId, id) }
        else if extensionId(windowId: windowId) == id { close(windowId) }
      }
    }
  }

  static func toggle(_ windowId: String, _ id: String) {
    if extensionId(windowId: windowId) == id { close(windowId) }
    else { open(windowId, id) }
  }

  static func open(_ windowId: String, _ id: String) {
    guard let store = NativeStoreHandle.store, NativeStoreHandle.ownsWorkspace,
      store.state.windows[windowId] != nil, NativeWindowShell.host(windowId) != nil,
      row(windowId, id) != nil else { return }
    install()
    let panel: OwnedPanel
    if let existing = panels[windowId], valid(windowId, existing) {
      panel = existing
    } else {
      close(windowId)
      panel = OwnedPanel(store: store)
      panels[windowId] = panel
      panel.listener = store.subscribe { [weak panel] _ in
        DispatchQueue.main.async {
          guard let panel, panels[windowId] === panel else { return }
          refresh(windowId)
        }
      }
    }
    panel.lifecycle.request(id)
    refresh(windowId, resolveURL: true)
  }

  static func sync(_ profiles: Set<String>? = nil, resolveURL: Bool = true) {
    for windowId in Array(panels.keys) {
      if let profiles, !profiles.contains(NativeExtensionCatalog.profile(windowId)) { continue }
      refresh(windowId, resolveURL: resolveURL)
    }
  }

  static func fullscreenChanged(_ windowId: String, fullscreen: Bool) {
    guard let panel = panels[windowId], panel.fullscreen != fullscreen else { return }
    refresh(windowId)
  }

  private static func row(_ windowId: String, _ id: String) -> JSONObject? {
    NativeExtensionCatalog.visible(windowId).first { $0["id"]?.string == id }
  }

  private static func valid(_ windowId: String, _ panel: OwnedPanel) -> Bool {
    NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === panel.store &&
      NativeStoreHandle.ownershipGeneration == panel.generation && panel.store.state.windows[windowId] != nil
  }

  static func refresh(_ windowId: String, resolveURL: Bool = false) {
    guard let panel = panels[windowId], let id = panel.lifecycle.extensionId else { return }
    let state = panel.store.state
    guard valid(windowId, panel), let window = state.windows[windowId],
      let host = NativeWindowShell.host(windowId) else { return close(windowId) }
    let ext = row(windowId, id)
    let tabId = state.peeks[windowId]?.tabId ?? state.activeTabId(windowId)
    let engine = tabId.flatMap { PageEngine(rawValue: panel.store.pageEngine($0, in: state)) }
    let browserId = engine == .chromium ? tabId.flatMap { NativeExtensionCatalog.page($0) }?.browserId ?? 0 : 0
    let fallback = window.incognito ? nil : ext?["sidePanel"]?.string.flatMap { path -> String? in
      guard !path.isEmpty else { return nil }
      return "chrome-extension://\(id)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)"
    }
    panel.fullscreen = host.shell.input.fullscreen
    let catalogProfile = NativeExtensionCatalog.profile(windowId)
    let pageProfile = window.incognito ? state.engineProfile(window.profileId) : catalogProfile
    let source = Source(id: id, tabId: tabId, browserId: browserId, catalogProfile: catalogProfile, pageProfile: pageProfile)
    if panel.source != source || resolveURL {
      panel.source = source
      panel.resolvedURL = browserId == 0 || ext == nil ? nil : SolaraCoreHost.sidePanelURL(browserId: browserId, extension: id)
    }
    let url = ExtensionSidePanelLifecycle.URLSource(engine: engine, browserId: browserId, fallback: fallback, resolved: panel.resolvedURL)
    let shown = panel.lifecycle.reconcile(eligible: ext != nil, pageProfile: pageProfile, url: url, fullscreen: panel.fullscreen)
    guard panel.lifecycle.extensionId != nil else { return close(windowId) }
    guard let shown, let ext else { return apply(nil, windowId: windowId, panel: panel) }
    let width = SidePanelMetrics.presentationWidth(window.effectiveSidePanelWidth(state.settings))
    let room = shown.room(width: width)
    let custom = state.profiles[window.profileId]?.theme.flatMap {
      try? JSONDecoder().decode(ProfileThemeValue.self, from: Data($0.text().utf8))
    }
    let dark = window.incognito || (custom.map {
      ThemeMath.shown($0, appDark: state.ui.appDark, source: state.settings.bool("spacesFollowAppearance") ? .app : .own).dark
    } ?? state.ui.appDark)
    let title = ext["actionTitle"]?.truthy == true ? ext["actionTitle"]?.string : ext["name"]?.string
    let icon = ext["actionIcon"]?.truthy == true ? ext["actionIcon"]?.string : ext["icon"]?.string
    let look = SidePanelState.Look(
      card: dark ? "rgba(18,18,18,0.5)" : "rgba(255,255,255,0.7)", text: dark ? "#FFFFFF" : "#000000",
      icon: dark ? "#F7F5FFC6" : "#000000C6", hover: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)",
      pressed: dark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.1)",
      hairline: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)", radius: 10)
    let next = SidePanelState(key: shown.key, pageProfile: shown.pageProfile, url: shown.url,
      title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Extension", icon: icon, width: width, room: room, look: look)
    apply(next, windowId: windowId, panel: panel)
  }

  private static func apply(_ state: SidePanelState?, windowId: String, panel: OwnedPanel) {
    guard panel.state != state else { return }
    panel.state = state
    let room = state?.room ?? 0
    let roomChanged = panel.room != room
    panel.room = room
    NativeWindowShell.host(windowId)?.setSidePanel(state)
    if roomChanged { NotificationCenter.default.post(name: roomDidChange, object: windowId) }
  }

  static func close(_ windowId: String) {
    guard let panel = panels.removeValue(forKey: windowId) else { return }
    if let listener = panel.listener { panel.store.unsubscribe(listener) }
    apply(nil, windowId: windowId, panel: panel)
  }

  static func closeAll() {
    for windowId in Array(panels.keys) { close(windowId) }
  }

  static func extensionRemoved(_ id: String, profile: String) {
    for (windowId, panel) in Array(panels) {
      guard let catalogProfile = panel.source?.catalogProfile,
        panel.lifecycle.matchesRemoval(id, profile: profile, catalogProfile: catalogProfile) else { continue }
      close(windowId)
    }
  }

  static func handle(windowId: String, key: String, name: String, payload: [String: Any]) {
    guard let panel = panels[windowId], valid(windowId, panel), panel.lifecycle.accepts(key: key),
      let id = panel.lifecycle.extensionId else { return }
    switch name {
    case "close", "windowClose":
      if panel.lifecycle.close(key: key) { close(windowId) }
    case "resize":
      if payload["ended"] as? Bool == true, let width = payload["width"] as? Double {
        _ = panel.lifecycle.saveWidth(width, key: key, windowId: windowId, store: panel.store)
      }
    case "resetWidth":
      _ = panel.lifecycle.saveWidth(nil, key: key, windowId: windowId, store: panel.store)
    case "menu":
      NativeExtensionCommands.run(["command": "menu", "windowId": .string(windowId), "id": .string(id)])
    case "openWindow":
      guard let request = payload["request"] as? [String: Any], let pageProfile = panel.lifecycle.presentation?.pageProfile else { return }
      NativeExtensionPageNavigation.openWindow(request, windowId: windowId, pageProfile: pageProfile)
    default: break
    }
  }
}

struct SidePanelState: Equatable {
  struct Look: Equatable {
    let card: String
    let text: String
    let icon: String
    let hover: String
    let pressed: String
    let hairline: String
    let radius: Double
  }

  let key: String
  let pageProfile: String
  let url: String
  let title: String
  let icon: String?
  let width: Double
  let room: CGFloat
  let look: Look

}

@MainActor
final class SidePanelHost: NSObject, SolaraCoreWebViewDelegate {
  let view = ExtensionSidePanelView()
  private let windowId: String
  private weak var shell: WindowShellView?
  private let resizeAnimator = DockAnimator(value: Double(SidePanelMetrics.defaultWidth))
  private static let unacknowledgedWidthLimit = 4
  private var unacknowledgedWidths: [Double] = []
  private var dragging = false
  #if DEBUG
  var devResizeLinkActive: Bool { resizeAnimator.devLinkActive }
  #endif
  private var state: SidePanelState?
  private var look: SidePanelLook?
  private var room: CGFloat = 0
  private var roomInset: CGFloat = 0
  private var opened = false
  private var keepsLocalWidth = false
  private let pages = ExtensionSidePanelPageSlot<SolaraCoreWebView>()
  private var page: SolaraCoreWebView? { pages.page }
  private var key: String?
  private var iconSource: String?
  private var icon: NSImage?
  private var focusedWindowOnLeave: NSWindow?
  private let onEvent: (String, String, [String: Any]) -> Void

  init(windowId: String, shell: WindowShellView, onEvent: ((String, String, [String: Any]) -> Void)? = nil) {
    self.onEvent = onEvent ?? { key, name, payload in
      NativeExtensionSidePanel.handle(windowId: windowId, key: key, name: name, payload: payload)
    }
    self.windowId = windowId
    self.shell = shell
    super.init()
    view.onMenu = { [weak self] in self?.send("menu") }
    view.onClose = { [weak self] in self?.send("close") }
    view.onResize = { [weak self] width, ended in self?.resize(width, ended: ended) }
    view.onResetWidth = { [weak self] in self?.resetWidth() }
    view.onWillLeaveWindow = { [weak self] in self?.noteLeaving() }
    shell.onSidePanelChange = { [weak self] _ in self?.place() }
    shell.onSidePanelSettle = { [weak self] value in
      guard let self, !self.opened, value == 0 else { return }
      self.end()
    }
    resizeAnimator.onChange = { [weak self] width in self?.setWidth(CGFloat(width)) }
    resizeAnimator.onSettle = { [weak self] width in
      guard let self, self.opened else { return }
      self.expectEcho(width)
      self.send("resize", ["width": width, "ended": true])
    }
  }

  func apply(_ next: SidePanelState?) {
    guard let next else {
      guard opened else { return }
      noteLeaving()
      opened = false
      keepsLocalWidth = false
      dragging = false
      unacknowledgedWidths = []
      resizeAnimator.stop()
      shell?.setSidePanelRoom(room, open: false, animated: true)
      return
    }
    guard next.width.isFinite, next.room.isFinite, next.width > 0, next.room > 0, let shell else { return }
    let wasOpen = opened
    if !wasOpen { focusedWindowOnLeave = nil }
    let changedPage = next.key != key
    let changedWidth = state?.width != next.width
    let acknowledged = wasOpen && !changedPage && changedWidth ? unacknowledgedWidths.firstIndex(of: next.width) : nil
    if let acknowledged { unacknowledgedWidths.removeFirst(acknowledged + 1) }
    if !wasOpen || changedPage || (changedWidth && acknowledged == nil) {
      resizeAnimator.stop()
      keepsLocalWidth = false
      dragging = false
      unacknowledgedWidths = []
    } else if acknowledged != nil, unacknowledgedWidths.isEmpty, !dragging, !resizeAnimator.moving {
      keepsLocalWidth = false
    }
    state = next
    opened = true
    roomInset = next.room - CGFloat(next.width)
    if iconSource != next.icon {
      iconSource = next.icon
      icon = next.icon.flatMap(Self.dataImage)
    }
    let l = next.look
    look = SidePanelLook(
      card: Self.color(l.card), text: Self.color(l.text), icon: Self.color(l.icon), hover: Self.color(l.hover),
      pressed: Self.color(l.pressed), hairline: Self.color(l.hairline), radius: l.radius)
    let width = keepsLocalWidth ? view.width : CGFloat(next.width)
    room = width + roomInset
    if let look { view.set(title: next.title, icon: icon, width: width, look: look) }
    if view.superview !== shell.sidePanelClip {
      shell.sidePanelClip.addSubview(view)
    }
    place()
    shell.setSidePanelRoom(room, open: true, animated: true)
    if changedPage { open(next) }
  }

  func place() {
    guard let shell, view.superview != nil else { return }
    view.frame = CGRect(x: shell.sidePanelClip.bounds.width - room, y: 0, width: room, height: shell.sidePanelClip.bounds.height)
    view.alphaValue = room > 0 ? min(1, max(0, shell.input.sidePanel / room)) : 0
    view.layoutSubtreeIfNeeded()
  }

  func stop() {
    opened = false
    resizeAnimator.stop()
    shell?.setSidePanelRoom(0, open: false, animated: false)
    end()
  }

  private func resetWidth() {
    guard opened else { return }
    resizeAnimator.stop()
    keepsLocalWidth = true
    dragging = false
    setWidth(SidePanelMetrics.defaultWidth)
    expectEcho(Double(SidePanelMetrics.defaultWidth))
    send("resetWidth")
  }

  private func resize(_ width: CGFloat, ended: Bool) {
    guard opened else { return }
    resizeAnimator.stop()
    keepsLocalWidth = true
    dragging = !ended
    setWidth(width)
    guard ended else { return }
    let target = SidePanelMetrics.clamp(width)
    if target == width || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      setWidth(target)
      expectEcho(Double(target))
      send("resize", ["width": Double(target), "ended": true])
      return
    }
    resizeAnimator.jump(to: Double(width))
    resizeAnimator.animate(to: Double(target), curve: .timed(duration: SidePanelMetrics.settleDuration, ease: .outBack(SidePanelMetrics.settleOvershoot)), in: view)
  }

  private func expectEcho(_ width: Double) {
    guard width != (unacknowledgedWidths.last ?? state?.width) else { return }
    unacknowledgedWidths.append(width)
    unacknowledgedWidths.removeFirst(max(0, unacknowledgedWidths.count - Self.unacknowledgedWidthLimit))
  }

  private func setWidth(_ width: CGFloat) {
    guard opened, let state, let look else { return }
    room = width + roomInset
    view.set(title: state.title, icon: icon, width: width, look: look)
    shell?.setSidePanelRoom(room, open: true, animated: false)
    place()
  }

  private func end() {
    noteLeaving()
    view.removeFromSuperview()
    let window = focusedWindowOnLeave
    focusedWindowOnLeave = nil
    close()
    if let window { refocus(window) }
    key = nil
    state = nil
    keepsLocalWidth = false
    dragging = false
    unacknowledgedWidths = []
  }

  private func noteLeaving(rendererHeldFocus: Bool = false) {
    guard let page, let window = page.window, window.isVisible,
      ExtensionSidePanelFocus.holdsFocus(window.firstResponder, in: page, beforeDetach: rendererHeldFocus) else { return }
    focusedWindowOnLeave = window
  }

  private func refocus(_ window: NSWindow) {
    let windowId = windowId
    DispatchQueue.main.async { [weak window] in
      guard let window, window.isVisible, window.firstResponder === window,
        let state = NativeStoreHandle.store?.state,
        let tabId = state.peeks[windowId]?.tabId ?? state.activeTabId(windowId) else { return }
      _ = SidePanelFocus.focus(windowId: windowId, tabId: tabId)
    }
  }

  private static func dataImage(_ source: String) -> NSImage? {
    guard source.hasPrefix("data:"), let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
      let data = Data(base64Encoded: String(source[source.index(after: comma)...]))
    else { return nil }
    return NSImage(data: data)
  }

  private func open(_ state: SidePanelState) {
    let window = page?.window
    let hadFocus = close()
    key = state.key
    defer { if hadFocus, let window { refocus(window) } }
    guard !state.url.isEmpty else { return }
    view.layoutSubtreeIfNeeded()
    let web = SolaraCoreWebView(frame: view.content.bounds)
    web.standalone = true
    web.extensionHost = "sidePanel"
    web.profile = state.pageProfile
    web.initialURL = state.url
    web.pageBackgroundColor = .white
    web.autoresizingMask = [.width, .height]
    web.delegate = self
    pages.page = web
    view.content.addSubview(web)
  }

  @discardableResult
  private func close() -> Bool {
    guard let page else { return false }
    let hadFocus = ExtensionSidePanelFocus.holdsFocus(page.window?.firstResponder, in: page)
    pages.remove { page in
      page.delegate = nil
      page.closeBrowser()
      page.removeFromSuperview()
    }
    return hadFocus
  }

  nonisolated func webView(_ web: SolaraCoreWebView, event name: String, payload: [String: Any]) {
    let identity = ObjectIdentifier(web)
    nonisolated(unsafe) let body = payload
    MainActor.assumeIsolated {
      guard page.map(ObjectIdentifier.init) == identity else { return }
      if name == "windowClose", opened {
        noteLeaving(rendererHeldFocus: body["rendererHeldFocus"] as? Bool == true)
        send("windowClose")
      }
      if name == "openWindow" { send("openWindow", ["request": body]) }
    }
  }

  private func send(_ name: String, _ payload: [String: Any] = [:]) {
    guard opened, let key else { return }
    onEvent(key, name, payload)
  }

  static func color(_ css: String) -> NSColor { CSSColor(css)?.ns ?? .clear }
}

@MainActor
enum SidePanelFocus {
  static func focus(windowId: String, tabId: String) -> Bool {
    guard let window = ShellDrag.window(windowId), window.isVisible, window.firstResponder === window else { return false }
    let page = (TabPoolHost.shared.pageView(tabId) as? SolaraCoreWebView) ?? find(tabId, in: window.contentView?.superview ?? window.contentView)
    guard let page, page.window === window, !page.isHiddenOrHasHiddenAncestor else { return false }
    if let focus = NativeAppIntegration.preparePageFocus(page) {
      return focus { [weak page, weak window] in
        guard let page, let window else { return false }
        return ShellDrag.window(windowId) === window && window.isVisible && window.firstResponder === window &&
          page.window === window && !page.isHiddenOrHasHiddenAncestor
      }
    }
    page.focusPage()
    return true
  }

  private static func find(_ tabId: String, in view: NSView?) -> SolaraCoreWebView? {
    guard let view, !view.isHidden else { return nil }
    if let web = view as? SolaraCoreWebView, web.transferKey == tabId, web.window != nil, !web.isHiddenOrHasHiddenAncestor { return web }
    for child in view.subviews { if let found = find(tabId, in: child) { return found } }
    return nil
  }
}

#if SOLARA_PROBES
@MainActor
public enum SidePanelRead {
  public static var liveViews: Int { SolaraCoreWebView.devLiveExtensionViews("sidePanel") }

  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let window = ShellDrag.window(windowId), let root = window.contentView else { return nil }
    var queue: [NSView] = [root]
    var pages: [[String: Any]] = []
    var focusedTabIds: [String] = []
    var card: [String: Any]?
    let responder = window.firstResponder as? NSView
    func frame(_ view: NSView) -> [Double] {
      let f = view.convert(view.bounds, to: nil)
      let y = root.bounds.height - f.maxY
      return [Double(f.minX), Double(y), Double(f.width), Double(f.height)]
    }
    while !queue.isEmpty {
      let view = queue.removeFirst()
      queue.append(contentsOf: view.subviews)
      if let panel = view as? ExtensionSidePanelView {
        let f = panel.convert(panel.frames.panel, to: nil)
        card = ["frame": [Double(f.minX), Double(root.bounds.height - f.maxY), Double(f.width), Double(f.height)],
          "width": Double(panel.width), "visible": !panel.isHiddenOrHasHiddenAncestor]
      }
      guard let web = view as? SolaraCoreWebView else { continue }
      let focused = responder.map { $0 === web || $0.isDescendant(of: web) } ?? false
      if focused, let tabId = web.transferKey { focusedTabIds.append(tabId) }
      guard web.extensionHost == "sidePanel" else { continue }
      let extensionId = web.initialURL.flatMap { URLComponents(string: $0)?.host }
      pages.append(["extensionId": extensionId ?? NSNull(), "frame": frame(web),
        "focused": focused, "visible": !web.isHiddenOrHasHiddenAncestor])
    }
    let shell = NativeWindowShell.host(windowId)?.shell
    var linkRunning = false
    #if DEBUG
    linkRunning = (shell?.devSidePanelLinkRunning ?? false) || (NativeWindowShell.host(windowId)?.devSidePanelResizeLinkActive ?? false)
    #endif
    return ["card": card ?? NSNull(), "pages": pages, "focusedTabIds": focusedTabIds.sorted(),
      "room": Double(shell?.input.sidePanel ?? 0), "moving": shell?.sidePanelMoving ?? false,
      "linkRunning": linkRunning, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
  }
}
#endif
