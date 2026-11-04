import AppKit
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeSidebarDock {
  static let topic = "sidebar.dock"
  private static var observer: UUID?
  private static var docks: [String: SidebarDock] = [:]
  private static var reactPeekRight: [String: CGFloat] = [:]

  nonisolated static var enabled: Bool { NativeSidebarShell.enabled }

  static func register() {
    guard enabled, observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
  }

  static func dock(_ windowId: String) -> SidebarDock? { docks[windowId] }

  static func setReactPeekRight(_ windowId: String, _ right: CGFloat) {
    let railRight = NativeWindowShell.host(windowId)?.shell.frames.sidebar?.maxX
    let rail = NativeWindowShell.host(windowId)?.shell.railFraction == 1
    reactPeekRight[windowId] = right > 0 ? (rail ? railRight ?? right : right) : nil
  }

  static func peekCovers(_ windowId: String, x: CGFloat) -> Bool {
    if let right = reactPeekRight[windowId], x < right { return true }
    guard let dock = docks[windowId], dock.peek.live, !dock.state.open, !dock.state.fullscreen else { return false }
    return x < (dock.shell.frames.sidebar?.maxX ?? (ShellMetrics.peekOrigin.x + CGFloat(dock.state.width)))
  }

  static func describe(_ windowId: String) -> [String: Any]? {
    guard let dock = docks[windowId] else { return nil }
    return [
      "dock": dock.dockValue, "moving": dock.moving, "live": dock.peek.live, "slide": dock.slideValue,
      "watching": dock.watchingHold.map { Double($0) } ?? NSNull(),
      "column": dock.panel.content != nil ? "panel" : dock.shell.view(in: .sidebar) == nil ? "none" : "slot",
    ]
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, dock) in docks where windows[windowId] == nil { remove(windowId, dock) }
    for (windowId, given) in windows {
      guard let json = given as? String, let data = json.data(using: .utf8),
        var state = try? JSONDecoder().decode(SidebarDockState.self, from: data)
      else { continue }
      if railShown(windowId) || state.width == 84 { state.width = SidebarRail.width }
      if let dock = docks[windowId] {
        dock.apply(state)
      } else {
        make(windowId, state)
      }
    }
  }

  static func railShown(_ windowId: String) -> Bool {
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return false }
    return window.effectiveSidebarIconsOnly(state.settings)
  }

  private static func make(_ windowId: String, _ state: SidebarDockState) {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
    let dock = SidebarDock(shell: shell, state: state)
    dock.column = { NativeSidebarShell.column(windowId) }
    dock.onWatch = { [weak dock] hold in
      ShellWindowEdge.watch(windowId, hold: hold) { over in dock?.edge(over: over) }
    }
    dock.onLights = { center in ShellWindowEdge.setLightsCenter(windowId, center) }
    dock.onDock = { value, moving in send(windowId, "dock", ["value": value, "moving": moving]) }
    dock.onPeek = { live, right in send(windowId, "peek", ["live": live, "right": right]) }
    dock.onSlideOut = { send(windowId, "slideOut") }
    docks[windowId] = dock
    dock.start()
  }

  private static func remove(_ windowId: String, _ dock: SidebarDock) {
    docks[windowId] = nil
    dock.stop()
  }

  private static func send(_ windowId: String, _ event: String, _ extra: [String: Any] = [:]) {
    let payload = SidebarPayload(extra)
    Task { @MainActor in _ = await SettingsAdapters.js(topic, windowId, event, payload.value) }
  }
}
