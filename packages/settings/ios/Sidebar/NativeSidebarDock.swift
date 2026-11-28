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
  private static var menuObservers: [NSObjectProtocol] = []
  private static var trackingMenus: Set<ObjectIdentifier> = []
  private static var reactPeekRight: [String: CGFloat] = [:]

  nonisolated static var enabled: Bool { NativeSidebarShell.enabled }

  static func register() {
    guard enabled, !NativeWindowShell.nativeLayout, observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
    _ = NativeSelectionTools.observe { recheckPeeks() }
    let center = NotificationCenter.default
    for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification, ToolbarInfoPopover.changed] {
      menuObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
        let menu = (note.object as? NSMenu).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
          if let menu {
            if name == NSMenu.didBeginTrackingNotification { trackingMenus.insert(menu) }
            if name == NSMenu.didEndTrackingNotification { trackingMenus.remove(menu) }
          }
          recheckPeeks()
        }
      })
    }
  }

  static func adopt(_ dock: SidebarDock, windowId: String) { docks[windowId] = dock }

  static func release(_ dock: SidebarDock, windowId: String) {
    if docks[windowId] === dock { docks[windowId] = nil }
  }

  static func dock(_ windowId: String) -> SidebarDock? { docks[windowId] }

  static func setReactPeekRight(_ windowId: String, _ right: CGFloat) {
    let railRight = NativeWindowShell.host(windowId)?.shell.frames.sidebar?.maxX
    let rail = NativeWindowShell.host(windowId)?.shell.railFraction == 1
    reactPeekRight[windowId] = right > 0 ? (rail ? railRight ?? right : right) : nil
  }

  static func peekCovers(_ windowId: String, point: CGPoint) -> Bool {
    if !NativeWindowShell.nativeLayoutActive(windowId), let right = reactPeekRight[windowId], point.x < right { return true }
    return docks[windowId]?.shell.sidebarPeekCoverage?.contains(point) == true
  }

  static func describe(_ windowId: String) -> [String: Any]? {
    guard let dock = docks[windowId] else { return nil }
    return [
      "dock": dock.dockValue, "moving": dock.moving, "live": dock.peek.live, "slide": dock.slideValue,
      "watching": dock.watchingHold.map { Double($0) } ?? NSNull(),
      "coverage": dock.shell.sidebarPeekCoverage.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull(),
      "side": dock.shell.input.sidebarSide.rawValue,
      "column": dock.panel.content != nil ? "panel" : dock.shell.view(in: .sidebar) == nil ? "none" : "slot",
    ]
  }

  private static func receive(_ value: Any?) {
    guard !NativeWindowShell.nativeLayout else { return }
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, dock) in docks where windows[windowId] == nil { remove(windowId, dock) }
    for (windowId, given) in windows {
      guard let json = given as? String, let data = json.data(using: .utf8),
        var state = try? JSONDecoder().decode(SidebarDockState.self, from: data)
      else { continue }
      if railShown(windowId) { state.width = SidebarRail.width }
      if let dock = docks[windowId] {
        dock.apply(state)
      } else {
        make(windowId, state)
      }
    }
  }

  static func panePopoverHeld(_ windowId: String, addressInSidebar: Bool, state: BrowserState?) -> Bool {
    guard addressInSidebar, let tabId = state?.activeTabId(windowId) else { return false }
    return NativeSelectionTools.popoverSnapshot()[tabId] != nil
  }

  private static func recheckPeeks() {
    for dock in docks.values { dock.peek.recheck() }
  }

  static func railShown(_ windowId: String) -> Bool {
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return false }
    return window.effectiveSidebarIconsOnly(state.settings)
  }

  private static func make(_ windowId: String, _ state: SidebarDockState) {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
    let dock = SidebarDock(shell: shell, state: state)
    dock.column = { NativeSidebarShell.column(windowId) }
    dock.revealHeld = { [weak dock] in
      guard let dock else { return false }
      let state = NativeStoreHandle.store?.state
      let toolbarWindow = ToolbarInfoPopover.current?.anchorView?.window
      let toolbarInWindow = toolbarWindow.map { $0 === dock.shell.window || $0 === dock.panel.content?.window } == true
      return !trackingMenus.isEmpty || state?.windowUi[windowId]?.downloadsOpen == true
        || NativeSidebarHoverCard.hasPointer(windowId) || NativeSidebarIconPicker.isOpen(windowId)
        || NativeWorkspaceRename.override(windowId).flatMap { $0 } != nil
        || toolbarInWindow || panePopoverHeld(windowId, addressInSidebar: dock.shell.input.addressBarInSidebar, state: state)
    }
    dock.onWatch = { [weak dock] hold in
      ShellWindowEdge.watch(windowId, hold: hold) { over in dock?.edge(over: over) }
    }
    dock.onLights = { center in ShellWindowEdge.setLightsCenter(windowId, center) }
    dock.onDock = { value, moving in send(windowId, "dock", ["value": value, "moving": moving]) }
    dock.onPeek = { live, right in send(windowId, "peek", ["live": live, "right": right]) }
    dock.onSlideOut = {
      NativeSidebarHoverCard.dismiss(windowId)
      send(windowId, "slideOut")
    }
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
