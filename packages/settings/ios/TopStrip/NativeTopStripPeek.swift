import AppKit
import Foundation
import SolaraUI
import SolaraModel

struct StripPeekHostState: Decodable, Equatable {
  var strip: String
  var controls: StripControlsState
  var theme: [String: String]
  var enabled: Bool
  var held: Bool
  var bandLeft: Double
  var look: StripPeekLook

  static func decode(_ json: String) -> StripPeekHostState? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(StripPeekHostState.self, from: $0) }
  }
}

@MainActor
final class TopStripPeekHost {
  static var hosts: [String: TopStripPeekHost] = [:]

  let windowId: String
  let strip: TopStripHost
  let row: StripPeekRow
  let view = StripPeekView()
  var onDemand: (() -> Void)?
  private var stopped = false
  private var held = false
  private var externalDropHeld = false
  private var state: StripPeekHostState?

  init(windowId: String, subscribeToStore: Bool = true) {
    self.windowId = windowId
    strip = TopStripHost(windowId: windowId, takesDrops: false, subscribeToStore: subscribeToStore)
    row = StripPeekRow(strip: strip.view)
    view.content = row
    view.peek.held = { [weak self] in (self?.held ?? false) || (self?.externalDropHeld ?? false) }
    row.controls.onAction = { [weak self] action in self?.handle(action) }
    row.onPageWidth = { [weak self] width in self?.strip.pageWidth = Double(width) }
    view.onLive = { [weak self] live in
      guard let self, !self.stopped else { return }
      if self.onDemand != nil {
        self.strip.renderingEnabled = live
        NativeProfilePager.hosts[self.windowId]?.place()
      }
      if live { self.onDemand?() }
      self.send("live", ["live": live, "pageWidth": Double(self.row.pageWidth)])
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    onDemand = nil
    view.onLive = { _ in }
    row.onPageWidth = { _ in }
    row.controls.onAction = { _ in }
    strip.stop()
    view.stop()
  }

  func setExternalDropHeld(_ held: Bool) {
    guard !stopped, held != externalDropHeld else { return }
    externalDropHeld = held
    if !held { view.peek.recheck() }
  }

  func apply(_ json: String) {
    guard !stopped, let next = StripPeekHostState.decode(json), next != state else { return }
    let released = state?.held == true && !next.held
    state = next
    held = next.held
    view.look = next.look
    view.bandLeft = CGFloat(next.bandLeft)
    row.controls.update(next.controls, theme: next.theme)
    row.needsLayout = true
    strip.apply(next.strip)
    view.setEnabled(next.enabled)
    if released { view.peek.recheck() }
  }

  func apply(state: BrowserState, host: StripHostState, controls: StripControlsState, enabled: Bool, bandLeft: CGFloat, look: StripPeekLook, renderStrip: Bool = true) {
    guard !stopped else { return }
    let released = held && !controls.downloadsOpen
    held = controls.downloadsOpen
    view.look = look
    view.bandLeft = bandLeft
    row.controls.update(controls, theme: host.theme)
    row.needsLayout = true
    strip.renderingEnabled = renderStrip
    if renderStrip { strip.apply(state: state, host: host) }
    view.setEnabled(enabled)
    if released { view.peek.recheck() }
  }

  private func handle(_ action: StripControlAction) {
    switch action {
    case .profileMenu: send("profileMenu")
    case .toggleDownloads: send("toggleDownloads")
    }
  }

  private func send(_ name: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
      _ = await SettingsAdapters.js("topStrip.peek.action", windowId, name, payload.value)
    }
  }

  func describe() -> [String: Any] {
    let content = view.window?.contentView
    func inWindow(_ rect: NSRect?) -> [Double]? {
      guard let rect, let content else { return nil }
      return [rect.minX, content.bounds.height - rect.maxY, rect.width, rect.height].map(Double.init)
    }
    let downloads = view.live ? row.controls.downloadsRect : NativeLayoutChrome.downloadsRect(windowId) ?? row.controls.downloadsRect
    return [
      "live": view.live, "slide": view.slideValue, "watching": view.watching,
      "panel": inWindow(view.live ? view.panel.convert(view.panel.bounds, to: nil) : nil) ?? NSNull(),
      "downloads": inWindow(downloads) ?? NSNull(),
      "pageWidth": strip.pageWidth ?? 0,
    ]
  }

  static func register() {
    guard !NativeWindowShell.nativeLayout else { return }
    HostedViews.register(NativeTopStrip.peekKind) { windowId in
      guard !NativeWindowShell.nativeLayout else { return nil }
      let host = TopStripPeekHost(windowId: windowId)
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
    TopStripControlsHost.register()
  }
}

struct StripControlsHostState: Decodable, Equatable {
  var controls: StripControlsState
  var theme: [String: String]
  var leadingInset: Double?
}

struct StripGlowHostState: Decodable, Equatable {
  var over: Bool
  var accent: String
  var dark: Bool
}

@MainActor
final class TopStripControlsHost {
  static let kind = "topStripControls"
  static var hosts: [String: TopStripControlsHost] = [:]

  let windowId: String
  let view = StripControlsView()
  private var state: StripControlsHostState?

  init(windowId: String) {
    self.windowId = windowId
    view.onAction = { [weak self] action in self?.handle(action) }
  }

  func apply(_ json: String) {
    guard let next = json.data(using: .utf8).flatMap({ try? JSONDecoder().decode(StripControlsHostState.self, from: $0) }), next != state else { return }
    state = next
    view.leadingInset = CGFloat(next.leadingInset ?? 0)
    view.update(next.controls, theme: next.theme)
  }

  private func handle(_ action: StripControlAction) {
    let windowId = windowId
    let name = action == .profileMenu ? "profileMenu" : "toggleDownloads"
    Task { @MainActor in _ = await SettingsAdapters.js("topStrip.peek.action", windowId, name, SidebarPayload([:]).value) }
  }

  static func register() {
    guard !NativeWindowShell.nativeLayout else { return }
    HostedViews.register(kind) { windowId in
      guard !NativeWindowShell.nativeLayout else { return nil }
      let host = TopStripControlsHost(windowId: windowId)
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in if hosts[windowId] === host { hosts[windowId] = nil } },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
    TopStripGlowHost.register()
  }
}

@MainActor
final class TopStripGlowHost {
  static let kind = "topStripGlow"
  static var hosts: [String: TopStripGlowHost] = [:]

  let view = StripDropGlow()

  func apply(_ json: String) {
    guard let next = json.data(using: .utf8).flatMap({ try? JSONDecoder().decode(StripGlowHostState.self, from: $0) }) else { return }
    view.set(over: next.over, accent: next.accent, dark: next.dark)
  }

  static func register() {
    guard !NativeWindowShell.nativeLayout else { return }
    HostedViews.register(kind) { windowId in
      guard !NativeWindowShell.nativeLayout else { return nil }
      let host = TopStripGlowHost()
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in if hosts[windowId] === host { hosts[windowId] = nil } },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
  }
}
