import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeExtensionSidePanel {
  nonisolated static let kind = "extensionSidePanel"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeSidePanel)
  }

  static func register() {
    guard enabled else { return }
    HostedViews.declare(kind)
    HostedViews.register(kind) { windowId in
      let host = SidePanelHost(windowId: windowId)
      return HostedContent(view: host.view, onUnmount: { host.end() }, takesFocus: false, onState: { host.apply($0) })
    }
  }
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
  let look: Look

  static func decode(_ json: String) -> SidePanelState? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(SidePanelState.self, from: $0) }
  }
}

@MainActor
final class SidePanelHost: NSObject, SolaraCoreWebViewDelegate {
  let view = ExtensionSidePanelView()
  private let windowId: String
  private var page: SolaraCoreWebView?
  private var key: String?
  private var iconSource: String?
  private var icon: NSImage?
  private var focusedWindowOnLeave: NSWindow?

  init(windowId: String) {
    self.windowId = windowId
    super.init()
    view.onMenu = { [weak self] in self?.send("menu") }
    view.onClose = { [weak self] in self?.send("close") }
    view.onResize = { [weak self] width, ended in self?.send("resize", ["width": width, "ended": ended]) }
    view.onResetWidth = { [weak self] in self?.send("resetWidth") }
    view.onWillLeaveWindow = { [weak self] in self?.noteLeaving() }
  }

  func apply(_ json: String) {
    guard let state = SidePanelState.decode(json) else { return }
    if iconSource != state.icon {
      iconSource = state.icon
      icon = state.icon.flatMap(Self.dataImage)
    }
    let l = state.look
    let look = SidePanelLook(
      card: Self.color(l.card), text: Self.color(l.text), icon: Self.color(l.icon), hover: Self.color(l.hover),
      pressed: Self.color(l.pressed), hairline: Self.color(l.hairline), radius: l.radius)
    view.set(title: state.title, icon: icon, width: state.width, look: look)
    if state.key != key { open(state) }
  }

  func end() {
    let window = focusedWindowOnLeave
    focusedWindowOnLeave = nil
    close()
    key = nil
    if let window { refocus(window) }
  }

  private func noteLeaving() {
    guard let page, let window = page.window, window.isVisible, Self.holdsFocus(page, in: window) else { return }
    focusedWindowOnLeave = window
  }

  private func refocus(_ window: NSWindow) {
    let windowId = windowId
    DispatchQueue.main.async { [weak window] in
      guard let window, window.isVisible, window.firstResponder === window else { return }
      HostedViews.send(NativeExtensionSidePanel.kind, windowId: windowId, "focusLost", [:])
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
    guard !state.url.isEmpty else { return }
    key = state.key
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
    if hadFocus, let window { refocus(window) }
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
    nonisolated(unsafe) let body = payload
    MainActor.assumeIsolated {
      guard web === page else { return }
      if name == "windowClose" { send("windowClose") }
      if name == "openWindow" { send("openWindow", ["request": body]) }
    }
  }

  private func send(_ name: String, _ payload: [String: Any] = [:]) {
    guard let key else { return }
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
