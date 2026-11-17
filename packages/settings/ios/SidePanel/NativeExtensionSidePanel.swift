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
  @MainActor
  private final class OwnedPanel {
    let store: Store
    let generation: Int
    let profileId: String
    let extensionId: String
    let title: String
    let icon: String
    let optionsUrl: String?
    let key = UUID().uuidString
    var url: String
    var json = ""
    var listener: Int?
    var suspended = false
    var shownKey: String { "\(key)|\(url)" }

    init(store: Store, profileId: String, extensionId: String, url: String, title: String, icon: String, optionsUrl: String?) {
      self.store = store
      generation = NativeStoreHandle.ownershipGeneration
      self.profileId = profileId
      self.extensionId = extensionId
      self.url = url
      self.title = title
      self.icon = icon
      self.optionsUrl = optionsUrl
    }
  }

  private static var panels: [String: OwnedPanel] = [:]
  private static var lifecycleListener: Int?

  static func owns(_ windowId: String) -> Bool { panels[windowId] != nil }

  static func preferredJSON(_ windowId: String, fallback: String?) -> String? {
    guard let panel = panels[windowId] else { return fallback }
    return panel.suspended ? nil : panel.json
  }

  static func open(windowId: String, profileId: String, extensionId: String, url: String, title: String, icon: String, optionsUrl: String?, store: Store) {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      store.state.windows[windowId]?.profileId == profileId, NativeWindowShell.host(windowId) != nil,
      let parsed = URLComponents(string: url), parsed.scheme == "chrome-extension", parsed.host == extensionId else { return }
    if let existing = panels[windowId], existing.extensionId == extensionId,
      existing.profileId == profileId, existing.store === store, valid(windowId, panel: existing) { return close(windowId) }
    close(windowId)
    let panel = OwnedPanel(store: store, profileId: profileId, extensionId: extensionId, url: url, title: title, icon: icon, optionsUrl: optionsUrl)
    panels[windowId] = panel
    panel.listener = store.subscribe { [weak panel] _ in
      Task { @MainActor in
        guard let panel, panels[windowId] === panel else { return }
        refresh(windowId, panel: panel, state: panel.store.state)
      }
    }
    if lifecycleListener == nil {
      lifecycleListener = NativeStoreHandle.subscribeLifecycle {
        for (id, panel) in Array(panels) {
          if !valid(id, panel: panel) { close(id) }
        }
      }
    }
    refresh(windowId, panel: panel, state: store.state)
  }

  private static func valid(_ windowId: String, panel: OwnedPanel) -> Bool {
    NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === panel.store
      && NativeStoreHandle.ownershipGeneration == panel.generation && panel.store.state.windows[windowId]?.profileId == panel.profileId
  }

  private static func refresh(_ windowId: String, panel: OwnedPanel, state: BrowserState) {
    guard valid(windowId, panel: panel), let window = state.windows[windowId] else { return close(windowId) }
    if let tabId = state.activeTabId(windowId), let page = page(in: TabPoolHost.shared.pageView(tabId)), page.browserId != 0 {
      guard let url = SolaraCoreHost.sidePanelURL(browserId: page.browserId, extension: panel.extensionId),
        let parsed = URLComponents(string: url), parsed.scheme == "chrome-extension", parsed.host == panel.extensionId else { return close(windowId) }
      panel.url = url
    }
    let dark = state.ui.appDark
    let width = Double(SidePanelMetrics.clamp(CGFloat(window.effectiveSidePanelWidth(state.settings))))
    let payload: [String: Any] = [
      "key": panel.shownKey, "pageProfile": state.engineProfile(panel.profileId), "url": panel.url,
      "title": panel.title, "icon": panel.icon, "width": width, "room": width + 6,
      "look": ["card": dark ? "rgba(18,18,18,0.5)" : "rgba(255,255,255,0.7)", "text": dark ? "#FFFFFF" : "#000000",
        "icon": dark ? "#F7F5FFC6" : "#000000C6", "hover": dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.05)",
        "pressed": dark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.1)",
        "hairline": dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)", "radius": 10],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let json = String(decoding: data, as: UTF8.self)
    let suspended = NativeWindowShell.host(windowId)?.shell.input.fullscreen == true
    let changedSuspension = suspended != panel.suspended
    panel.suspended = suspended
    guard panel.json != json || changedSuspension else { return }
    panel.json = json
    NativeWindowShell.host(windowId)?.setSidePanel(suspended ? nil : json)
  }

  private static func close(_ windowId: String) {
    guard let panel = panels.removeValue(forKey: windowId) else { return }
    if let listener = panel.listener { panel.store.unsubscribe(listener) }
    NativeWindowShell.host(windowId)?.setSidePanel(nil)
  }

  private static func page(in view: NSView?) -> SolaraCoreWebView? {
    guard let view else { return nil }
    if let web = view as? SolaraCoreWebView { return web }
    for child in view.subviews { if let found = page(in: child) { return found } }
    return nil
  }

  static func windowEnded(_ windowId: String, key: String?) {
    guard let panel = panels[windowId], panel.shownKey == key || (key == nil && panel.suspended) else { return }
    panels.removeValue(forKey: windowId)
    if let listener = panel.listener { panel.store.unsubscribe(listener) }
  }

  static func handle(windowId: String, key: String, name: String, payload: [String: Any], view: NSView) -> Bool {
    guard let panel = panels[windowId], panel.shownKey == key else { return false }
    guard valid(windowId, panel: panel) else { close(windowId); return true }
    switch name {
    case "close", "windowClose": close(windowId)
    case "resize", "resetWidth":
      let width = name == "resetWidth" ? Double(SidePanelMetrics.defaultWidth) : payload["width"] as? Double
      if let width, width.isFinite {
        _ = try? panel.store.dispatch(Command("setWindowSidebar", [.string(windowId), ["sidePanelWidth": .number(Double(SidePanelMetrics.clamp(CGFloat(width))))]]), origin: .native)
      }
    case "menu":
      let target = SidePanelMenuTarget { choice in
        guard panels[windowId] === panel, valid(windowId, panel: panel) else { return }
        if choice == "close" { close(windowId) }
        if choice == "options", let url = panel.optionsUrl {
          _ = try? panel.store.dispatch(Command("newTab", [.string(windowId), ["url": .string(url), "profileId": .string(panel.profileId)]]), origin: .native)
        }
      }
      let menu = NSMenu()
      menu.autoenablesItems = false
      for (id, title, enabled) in [("options", "Extension Options", panel.optionsUrl != nil), ("close", "Close Side Panel", true)] {
        let item = NSMenuItem(title: title, action: #selector(SidePanelMenuTarget.choose(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = id
        item.isEnabled = enabled
        menu.addItem(item)
      }
      withExtendedLifetime(target) { menu.popUp(positioning: nil, at: CGPoint(x: 12, y: 32), in: view) }
    case "openWindow":
      guard let request = payload["request"] as? [String: Any], let url = request["url"] as? String,
        let window = panel.store.state.windows[windowId] else { return true }
      let disposition = request["disposition"] as? String ?? "foreground"
      let adopt = request["adoptId"] as? String
      var options: JSONObject = ["url": .string(url), "profileId": .string(panel.profileId)]
      if let adopt { options["adoptId"] = .string(adopt) }
      if disposition == "window" || disposition == "incognito" {
        if window.incognito || disposition == "incognito" {
          options["incognito"] = true
          options["profileId"] = .string(window.originalProfileId ?? Ids.incognitoOriginal(panel.profileId))
          if adopt?.hasPrefix("tab:") != true { options.removeValue(forKey: "adoptId") }
        }
        _ = try? panel.store.dispatch(Command("createWindow", [.object(options)]), origin: .native)
      } else if disposition == "split" {
        _ = try? panel.store.dispatch(Command("openSplitPane", [.string(windowId), .object(options)]), origin: .native)
      } else if disposition != "current" && disposition != "peek" {
        options["background"] = .bool(disposition == "background")
        _ = try? panel.store.dispatch(Command("newTab", [.string(windowId), .object(options)]), origin: .native)
      }
    default: break
    }
    return true
  }
}

@MainActor
private final class SidePanelMenuTarget: NSObject {
  let action: (String) -> Void
  init(_ action: @escaping (String) -> Void) { self.action = action }
  @objc func choose(_ item: NSMenuItem) { if let id = item.representedObject as? String { action(id) } }
}

struct SidePanelState: Decodable {
  struct Look: Decodable {
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
  let room: Double
  let look: Look

  static func decode(_ json: String) -> SidePanelState? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(SidePanelState.self, from: $0) }
  }
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
  private var page: SolaraCoreWebView?
  private var key: String?
  private var iconSource: String?
  private var icon: NSImage?
  private var focusedWindowOnLeave: NSWindow?
  private var nativeOwned = false

  init(windowId: String, shell: WindowShellView) {
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

  func apply(_ json: String?) {
    let json = NativeExtensionSidePanel.preferredJSON(windowId, fallback: json)
    guard let json, !json.isEmpty else {
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
    guard let next = SidePanelState.decode(json), next.width.isFinite, next.room.isFinite, next.width > 0, next.room > 0, let shell else { return }
    nativeOwned = NativeExtensionSidePanel.owns(windowId)
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
    roomInset = CGFloat(next.room - next.width)
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
    if changedPage { open(next) }
    shell.setSidePanelRoom(room, open: true, animated: true)
  }

  func place() {
    guard let shell, view.superview != nil else { return }
    view.frame = CGRect(x: shell.sidePanelClip.bounds.width - room, y: 0, width: room, height: shell.sidePanelClip.bounds.height)
    view.alphaValue = room > 0 ? min(1, max(0, shell.input.sidePanel / room)) : 0
    view.layoutSubtreeIfNeeded()
  }

  func windowChanged(_ window: NSWindow?) {
    if window == nil { stop() }
  }

  func stop() {
    NativeExtensionSidePanel.windowEnded(windowId, key: key)
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

  private func noteLeaving() {
    guard let page, let window = page.window, window.isVisible, Self.holdsFocus(page, in: window) else { return }
    focusedWindowOnLeave = window
  }

  private func refocus(_ window: NSWindow) {
    let windowId = windowId
    let key = key
    let nativeOwned = nativeOwned
    DispatchQueue.main.async { [weak window] in
      guard let window, window.isVisible, window.firstResponder === window else { return }
      if nativeOwned, let tabId = NativeStoreHandle.store?.state.activeTabId(windowId) {
        _ = SidePanelFocus.focus(windowId: windowId, tabId: tabId)
        return
      }
      HostedViews.send(NativeExtensionSidePanel.kind, windowId: windowId, "focusLost", ["key": key ?? ""])
    }
  }

  private static func holdsFocus(_ page: NSView, in window: NSWindow) -> Bool {
    (window.firstResponder as? NSView).map { $0 === page || $0.isDescendant(of: page) } ?? false
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
    view.content.addSubview(web)
    page = web
  }

  @discardableResult
  private func close() -> Bool {
    guard let page else { return false }
    let hadFocus = page.window.map { Self.holdsFocus(page, in: $0) } ?? false
    self.page = nil
    page.delegate = nil
    page.closeBrowser()
    page.removeFromSuperview()
    return hadFocus
  }

  nonisolated func webView(_ web: SolaraCoreWebView, event name: String, payload: [String: Any]) {
    let identity = ObjectIdentifier(web)
    nonisolated(unsafe) let body = payload
    MainActor.assumeIsolated {
      guard page.map(ObjectIdentifier.init) == identity else { return }
      if name == "windowClose" { send("windowClose") }
      if name == "openWindow" { send("openWindow", ["request": body]) }
    }
  }

  private func send(_ name: String, _ payload: [String: Any] = [:]) {
    guard let key else { return }
    if NativeExtensionSidePanel.handle(windowId: windowId, key: key, name: name, payload: payload, view: view) { return }
    var body = payload
    body["key"] = key
    HostedViews.send(NativeExtensionSidePanel.kind, windowId: windowId, name, body)
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
