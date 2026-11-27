import AppKit
import Foundation
import SolaraUI
import SolaraModel
import SolaraShell

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

  init(windowId: String, subscribeToStore: Bool = true) {
    self.windowId = windowId
    strip = TopStripHost(windowId: windowId, takesDrops: false, subscribeToStore: subscribeToStore)
    row = StripPeekRow(strip: strip.view)
    view.content = row
    view.peek.held = { [weak self] in (self?.held ?? false) || (self?.externalDropHeld ?? false) }
    row.controls.onAction = { action in NativeTopStrip.controlAction(action, windowId: windowId) }
    row.onPageWidth = { [weak self] width in self?.strip.pageWidth = Double(width) }
    view.onLive = { [weak self] live in
      guard let self, !self.stopped else { return }
      self.strip.renderingEnabled = live
      NativeProfilePager.hosts[self.windowId]?.place()
      if live {
        if let onDemand = self.onDemand { onDemand() } else { self.strip.setNeedsRender() }
      }
      self.send("live", ["live": live, "pageWidth": Double(self.row.pageWidth)])
    }
    if subscribeToStore {
      let dragRegion = StripPeekDragRegion(frame: row.bounds)
      dragRegion.autoresizingMask = [.width, .height]
      row.addSubview(dragRegion, positioned: .below, relativeTo: strip.view)
      strip.renderingEnabled = false
      strip.onPresentation = { [weak self] state, window, look in
        self?.updateControls(look.controls(state: state, window: window), theme: look.tokens, look: look.panel)
      }
      strip.setNeedsRender()
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
    guard !stopped, let next = try? JSONValue.parse(json) else { return }
    view.bandLeft = CGFloat(next["bandLeft"]?.number ?? 0)
    view.setEnabled(next["enabled"]?.bool == true)
  }

  func apply(state: BrowserState, host: StripHostState?, controls: StripControlsState, theme: [String: String],
    enabled: Bool, bandLeft: CGFloat, look: StripPeekLook, renderStrip: Bool)
  {
    guard !stopped else { return }
    updateControls(controls, theme: theme, look: look)
    view.bandLeft = bandLeft
    strip.renderingEnabled = renderStrip
    if renderStrip, let host { strip.apply(state: state, host: host) }
    view.setEnabled(enabled)
  }

  private func updateControls(_ controls: StripControlsState, theme: [String: String], look: StripPeekLook) {
    let released = held && !controls.downloadsOpen
    held = controls.downloadsOpen
    view.look = look
    row.controls.update(controls, theme: theme)
    row.needsLayout = true
    if released { view.peek.recheck() }
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
    let downloads = view.live ? row.controls.downloadsRect : NativeTopStrip.downloadsRect(windowId)
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
  }
}

@MainActor
private final class StripPeekDragRegion: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    if event.clickCount == 2 {
      WindowTitlebar.doubleClick(window, event.modifierFlags)
    } else {
      window.performDrag(with: event)
    }
  }
}

@MainActor
final class TopStripGlowHost {
  static var hosts: [String: TopStripGlowHost] = [:]

  let view = StripDropGlow()
  var look = (accent: "#4A77D4", dark: true)

  func applyDropOver(_ over: Bool) {
    view.set(over: over, accent: look.accent, dark: look.dark)
  }
}
