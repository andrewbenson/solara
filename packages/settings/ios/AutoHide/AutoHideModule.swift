import AppKit
import ExpoModulesCore
import SolaraCore
import SolaraModel
import SolaraStore
import SolaraUI

public class AutoHideModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraAutoHide")

    View(LegacyToolbarGeometryView.self) {
      Events("onToolbarFrame")
      Prop("windowId") { (view: LegacyToolbarGeometryView, value: String) in
        nonisolated(unsafe) let host = view
        MainActor.assumeIsolated { host.windowId = value }
      }
      Prop("tabId") { (view: LegacyToolbarGeometryView, value: String) in
        nonisolated(unsafe) let host = view
        MainActor.assumeIsolated { host.tabId = value }
      }
      OnViewDidUpdateProps { (view: LegacyToolbarGeometryView) in
        nonisolated(unsafe) let host = view
        MainActor.assumeIsolated { host.updateBinding() }
      }
    }

    Function("scrolledDown") { (tabId: String) -> Bool in
      if Thread.isMainThread { return MainActor.assumeIsolated { AutoHideHost.scrolledDown(tabId) } }
      return DispatchQueue.main.sync { AutoHideHost.scrolledDown(tabId) }
    }

    Function("sidebarToggleVisible") { (windowId: String) -> Bool in
      if Thread.isMainThread { return MainActor.assumeIsolated { AutoHideHost.sidebarToggleVisible(windowId) } }
      return DispatchQueue.main.sync { AutoHideHost.sidebarToggleVisible(windowId) }
    }

    Events("onToolbarScrollChanged", "onToolbarLayoutChanged")

    OnCreate {
      let sink = AutoHideSink(self)
      DispatchQueue.main.async {
        AutoHideHost.start()
        AutoHideHost.scrolled = { sink.module?.sendEvent("onToolbarScrollChanged", ["tabId": $0]) }
        AutoHideHost.layoutChanged = { sink.module?.sendEvent("onToolbarLayoutChanged", [:]) }
      }
    }

    #if DEBUG
    AsyncFunction("devStripHost") { (windowId: String, tabId: String) -> String? in
      MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed() else { return nil }
        return AutoHideHost.devStripHost(windowId: windowId, tabId: tabId)
      }
    }.runOnQueue(.main)

    AsyncFunction("devScroll") { (tabId: String, direction: String) in
      MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed(), let issuer = PageIssuer.shared, let binding = issuer.binding(tabId: tabId),
          let registration = binding.registration, let windowId = issuer.store.state.tabs[tabId]?.windowId else { return }
        AutoHideHost.scroll(windowId: windowId, registration: registration, direction: direction)
      }
    }.runOnQueue(.main)
    #endif
  }
}

private final class AutoHideSink: @unchecked Sendable {
  weak var module: AutoHideModule?
  init(_ module: AutoHideModule) { self.module = module }
}

@MainActor
final class LegacyToolbarGeometryView: ExpoView {
  let onToolbarFrame = EventDispatcher()
  var windowId = ""
  var tabId = ""
  private var mounted: (windowId: String, tabId: String)?
  var bookmarksHeight: Double = 0
  private var lastFrame: (top: Double, viewport: Double, onFrame: Bool, strip: Bool, bookmarksHeight: Double)?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func updateBinding() {
    guard mounted?.windowId != windowId || mounted?.tabId != tabId else { return }
    unmount()
    guard window != nil, !windowId.isEmpty, !tabId.isEmpty else { return }
    mounted = (windowId, tabId)
    AutoHideHost.mount(self, windowId: windowId, tabId: tabId)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateBinding()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { unmount() }
    super.viewWillMove(toWindow: newWindow)
  }

  private func unmount() {
    if let mounted { AutoHideHost.unmount(self, windowId: mounted.windowId, tabId: mounted.tabId) }
    mounted = nil
    lastFrame = nil
  }

  func deliver(top: Double, viewport: Double, onFrame: Bool, strip: Bool) {
    guard lastFrame?.top != top || lastFrame?.viewport != viewport || lastFrame?.onFrame != onFrame || lastFrame?.strip != strip || lastFrame?.bookmarksHeight != bookmarksHeight else { return }
    lastFrame = (top, viewport, onFrame, strip, bookmarksHeight)
    onToolbarFrame(["tabId": tabId, "top": top, "viewport": viewport, "onFrame": onFrame, "strip": strip, "bookmarksHeight": bookmarksHeight])
  }
}

@MainActor
enum AutoHideHost {
  @MainActor
  private final class Pane {
    let strip = AutoHideStripView(frame: .zero)
    weak var toolbar: ToolbarView?
    let target: ToolbarAutoHideController.ActionTarget?
    var frame: AutoHideFrame?

    init(toolbar: ToolbarView, target: ToolbarAutoHideController.ActionTarget?) {
      self.toolbar = toolbar
      self.target = target
    }
  }

  @MainActor
  private final class Window {
    let controller: ToolbarAutoHideController
    var strips: [String: Pane] = [:]
    var legacyTops: Set<String> = []
    var legacyViewportExtra: [String: CGFloat] = [:]
    var views: [String: WeakGeometryView] = [:]
    var urls: [String: String] = [:]
    var contributions: [String: Contribution] = [:]

    init(windowId: String, generation: UInt64) {
      controller = ToolbarAutoHideController(windowId: windowId, windowGeneration: generation)
    }
  }

  private struct WeakGeometryView {
    weak var value: LegacyToolbarGeometryView?
  }

  private struct Contribution: Equatable {
    let palette: ToolbarPaletteState
    let card: String?
    let stripes: String?
    let held: Bool
  }

  private static var windows: [String: Window] = [:]
  private static var nextGeneration: UInt64 = 0
  private static var started = false
  private static weak var store: Store?
  private static var listener: Int?
  private static var pending: Set<String> = []
  static var scrolled: (String) -> Void = { _ in }
  static var layoutChanged: () -> Void = {}
  private static var sidebarToggles: [String: Bool] = [:]

  private static func entry(_ id: String) -> Window {
    if let value = windows[id] { return value }
    nextGeneration += 1
    let value = Window(windowId: id, generation: nextGeneration)
    windows[id] = value
    return value
  }

  static func controller(_ windowId: String) -> ToolbarAutoHideController { entry(windowId).controller }

  static func present(windowId: String, tabIds: Set<String>) {
    let controller = entry(windowId).controller
    let before = tabIds.filter { controller.facts[$0]?.scrolledDown == true }
    controller.present(tabIds)
    for id in before where controller.facts[id]?.scrolledDown != true { scrolled(id) }
  }

  static func start() {
    guard !started else { return }
    started = true
    PageIssuer.lifecycleObservers.append { issuer, binding, name, payload in
      guard PageIssuer.shared === issuer, let registration = binding.registration,
        let windowId = issuer.store.state.tabs[binding.tabId]?.windowId, let entry = windows[windowId] else { return }
      let controller = entry.controller
      controller.register(registration)
      let before = controller.facts[binding.tabId]
      switch name {
      case "onPageMessage":
        if payload["kind"]?.string == "scroll", let direction = payload["data"]?["state"]?.string {
          scroll(windowId: windowId, registration: registration, direction: direction)
        }
        return
      case "onNavigationChange":
        guard let url = payload["url"]?.string else { return }
        let key = String(url.prefix { $0 != "#" })
        if let previous = entry.urls.updateValue(key, forKey: binding.tabId), previous != key {
          controller.reveal(tabId: binding.tabId)
        }
      case "onFullscreen":
        if let on = payload["fullscreen"]?.bool { controller.setFullscreen(registration, on: on) }
      case "onCrashed", "onDiscarded", "onPagePhysicalReplaced":
        controller.setFullscreen(registration, on: false)
        controller.reveal(tabId: binding.tabId)
      default: return
      }
      changed(windowId, binding.tabId, previous: before)
    }
    _ = PageRegistry.shared.observe { event in
      guard case .retired(let registration) = event else { return }
      for (windowId, entry) in windows {
        let id = registration.tabID
        guard let before = entry.controller.facts[id], before.registration == String(registration.registrationGeneration) else { continue }
        entry.controller.retire(registration)
        entry.urls[id] = nil
        changed(windowId, id, previous: before)
      }
    }
    _ = NativeSelectionTools.observe {
      for id in windows.keys { refresh(id) }
    }
    _ = NativeStoreHandle.subscribeLifecycle {
      let current = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
      guard store !== current else { return }
      if let listener { store?.unsubscribe(listener) }
      store = current
      listener = current?.subscribe { commit in
        guard commit.changes.settings || !commit.changes.tabs.isEmpty || !commit.changes.windows.isEmpty ||
          !commit.changes.splits.isEmpty || !commit.changes.peeks.isEmpty ||
          !commit.changes.windowUi.isEmpty || !commit.changes.find.isEmpty else { return }
        let geometryChanged = commit.changes.settings || !commit.changes.windows.isEmpty
        Task { @MainActor in
          if geometryChanged { refreshSidebarToggles() }
          for id in windows.keys where !NativeWindowShell.active(id) { refresh(id) }
        }
      }
      refreshSidebarToggles()
      for id in windows.keys { refresh(id) }
    }
  }

  private static func refreshSidebarToggles() {
    guard let state = store?.state else {
      if !sidebarToggles.isEmpty {
        sidebarToggles = [:]
        layoutChanged()
      }
      return
    }
    let show = state.settings["showSidebarButton"]?.bool != false
    let defaultLayout = state.settings.string("tabLayout") ?? "sidebar"
    let next = Dictionary(uniqueKeysWithValues: state.windows.values.map {
      ($0.id, show && ($0.tabLayout ?? defaultLayout) == "sidebar")
    })
    if next != sidebarToggles {
      sidebarToggles = next
      layoutChanged()
    }
  }

  static func sidebarToggleVisible(_ windowId: String) -> Bool { sidebarToggles[windowId] ?? true }

  static func mount(_ view: LegacyToolbarGeometryView, windowId: String, tabId: String) {
    let value = entry(windowId)
    value.views[tabId] = WeakGeometryView(value: view)
    refresh(windowId)
  }

  static func unmount(_ view: LegacyToolbarGeometryView, windowId: String, tabId: String) {
    guard let value = windows[windowId], value.views[tabId]?.value === view else { return }
    value.views[tabId] = nil
    remove(windowId: windowId, tabId: tabId)
    if value.views.isEmpty && !NativeWindowShell.active(windowId) { windowEnded(windowId) }
    else { refresh(windowId) }
  }

  private static func refresh(_ windowId: String) {
    if let host = NativeWindowShell.host(windowId) { host.scheduleLayoutProjection(); return }
    guard let window = windows[windowId], pending.insert(windowId).inserted else { return }
    DispatchQueue.main.async {
      pending.remove(windowId)
      guard windows[windowId] === window, var state = store?.state,
        let view = window.views.values.compactMap(\.value).first, let root = view.window?.contentView else { return }
      if !NativeBookmarksBar.enabled { state.settings["bookmarksBar"] = "never" }
      window.controller.retain(tabIds: Set(state.windows[windowId]?.tabIds ?? []))
      present(windowId: windowId, tabIds: Set(window.views.keys))
      let ids = Array(window.views.keys)
      for id in ids {
        if let registration = PageIssuer.shared?.binding(tabId: id)?.registration { window.controller.register(registration) }
      }
      guard let input = WindowLayoutInput(state: state, windowId: windowId, bounds: root.bounds,
        pageFacts: window.controller.facts, toolbarHolds: holds(windowId: windowId, tabIds: ids)) else { return }
      install(.of(input, generation: 1))
    }
  }

  static func scroll(windowId: String, registration: PageRegistration, direction: String) {
    guard let controller = windows[windowId]?.controller else { return }
    let before = controller.facts[registration.tabID]
    controller.register(registration)
    if controller.noteScroll(registration, state: direction) { changed(windowId, registration.tabID, previous: before) }
  }

  private static func changed(_ windowId: String, _ tabId: String, previous: WindowLayoutPageFacts?) {
    let next = windows[windowId]?.controller.facts[tabId]
    if previous?.scrolledDown != next?.scrolledDown { scrolled(tabId) }
    if previous != next { refresh(windowId) }
  }

  static func scrolledDown(_ tabId: String) -> Bool {
    guard let windowId = store?.state.tabs[tabId]?.windowId else { return false }
    return windows[windowId]?.controller.facts[tabId]?.scrolledDown == true
  }

  static func holds(windowId: String, tabIds: [String]) -> Set<String> {
    Set(tabIds.filter { id in
      windows[windowId]?.contributions[id]?.held == true || NativeExtensionActionPopup.visibleWindowId == windowId
        || NativeSelectionTools.popoverSnapshot()[id] != nil || NativePaneOverlays.host(windowId)?.holdsToolbar(id) == true
    })
  }

  static func holdsChanged(_ windowId: String) { refresh(windowId) }

  static func install(_ snapshot: WindowLayoutSnapshot) {
    let windowId = snapshot.input.windowId
    guard let state = store?.state ?? NativeStoreHandle.store?.state else { return }
    let window = entry(windowId)
    let visible = snapshot.toolbarModes.keys.filter {
      snapshot.input.hideToolbarWhileScrolling && snapshot.fullscreenTabId == nil && (snapshot.toolbars[$0]?.height ?? 0) > 0
    }
    let present = Set(snapshot.toolbarModes.keys)
    window.urls = window.urls.filter { state.tabs[$0.key]?.windowId == windowId }
    window.contributions = window.contributions.filter { state.tabs[$0.key]?.windowId == windowId }
    for id in Array(window.strips.keys) where !visible.contains(id) { remove(windowId: windowId, tabId: id) }
    for id in window.legacyTops.subtracting(present) {
      setLegacyTop(nil, viewport: nil, windowId: windowId, tabId: id)
    }
    if !NativeWindowShell.nativeLayoutActive(windowId) { window.legacyTops = present }
    for (id, mode) in snapshot.toolbarModes {
      guard let top = snapshot.shownTops[id] else { continue }
      window.views[id]?.value?.bookmarksHeight = Double(snapshot.input.bookmarksBarHeights[id] ?? 0)
      let mountedToolbar = NativeToolbarHostView.toolbar(windowId: windowId, tabId: id)
      guard visible.contains(id), let toolbar = mountedToolbar,
        let toolbarState = toolbar.state, toolbarState.tabId == id, toolbar.window != nil,
        let identity = ToolbarPageIdentity.resolve(windowId: windowId, tabId: id, state: state) else {
        remove(windowId: windowId, tabId: id)
        if !NativeWindowShell.nativeLayoutActive(windowId) {
          setLegacyTop(top, viewport: top, windowId: windowId, tabId: id)
        }
        window.views[id]?.value?.deliver(top: top, viewport: top, onFrame: mountedToolbar?.sitsOnWindowFrame == true, strip: false)
        continue
      }
      let target = window.controller.actionTarget(id)
      let pane: Pane
      if let current = window.strips[id], current.toolbar === toolbar, current.target == target {
        pane = current
      } else {
        remove(windowId: windowId, tabId: id)
        pane = Pane(toolbar: toolbar, target: target)
        window.strips[id] = pane
        let registration = PageIssuer.shared?.binding(tabId: id)?.registration
        pane.strip.onEvent = { [weak pane, weak window] event in
          guard let pane, let window, window.strips[id] === pane, let target = pane.target,
            PageIssuer.shared?.binding(tabId: id)?.registration == registration,
            pane.toolbar?.window != nil, pane.toolbar?.state?.tabId == id,
            let store, !NativeStoreHandle.frozen,
            ToolbarActionCommand.resolve(windowId: windowId, tabId: id, state: store.state,
              closing: store.memory.closingWindows) != nil else { return }
          let before = window.controller.facts[id]
          if window.controller.apply(event, from: target) { changed(windowId, id, previous: before) }
        }
        pane.strip.onFrame = { [weak pane, weak window] frame in
          guard let pane, let window, window.strips[id] === pane else { return }
          pane.frame = frame
          applyFrame(pane, windowId: windowId, tabId: id)
        }
        pane.strip.onMotion = { _ in NativeWindowShell.host(windowId)?.shell.coverChanged() }
      }
      let palette = toolbarState.palette
      let style = AutoHideStripStyle(card: toolbarState.autoHideCard.flatMap { CSSColor($0) } ?? CSSColor("#FFFFFF")!,
        band: palette.background.flatMap { CSSColor($0) }, divider: CSSColor(palette.divider) ?? CSSColor("#00000019")!,
        secondary: CSSColor(palette.secondary) ?? CSSColor("#00000080")!, host: identity.host,
        hasPage: identity.hasPage, stripes: toolbarState.stripes)
      toolbar.setAutoHideBackdrop(true)
      toolbar.placeBackdrop(pane.strip)
      pane.strip.set(style: style, mode: mode, shownTop: top)
      window.views[id]?.value?.deliver(top: pane.strip.presentationTop, viewport: pane.strip.viewportTop, onFrame: toolbar.sitsOnWindowFrame, strip: true)
    }
  }

  private static func applyFrame(_ pane: Pane, windowId: String, tabId: String) {
    guard let frame = pane.frame, let toolbar = pane.toolbar, toolbar.state?.tabId == tabId else { return }
    toolbar.setAutoHide(opacity: frame.controlsOpacity, scale: frame.toolbarScale, lift: -frame.toolbarLift, interactive: frame.interactive)
    if NativeWindowShell.nativeLayoutActive(windowId) {
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
    } else {
      setLegacyTop(frame.liveTop, viewport: pane.strip.viewportTop, windowId: windowId, tabId: tabId)
      windows[windowId]?.views[tabId]?.value?.deliver(top: frame.liveTop, viewport: pane.strip.viewportTop, onFrame: toolbar.sitsOnWindowFrame, strip: true)
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
    }
  }

  private static func setLegacyTop(_ top: CGFloat?, viewport: CGFloat?, windowId: String, tabId: String) {
    let extra = top.flatMap { top in viewport.map { top - $0 } }
    let changed = windows[windowId]?.legacyViewportExtra[tabId] != extra
    windows[windowId]?.legacyViewportExtra[tabId] = extra
    PaneOverlays.shared.setLiveTop(top, windowId: windowId, tabId: tabId)
    NativeSplitChrome.setLiveTop(top, viewport: viewport, windowId: windowId, tabId: tabId)
    if changed { TabPoolHost.shared.followCardPages() }
  }

  static func viewportExtra(windowId: String, tabId: String) -> CGFloat {
    windows[windowId]?.legacyViewportExtra[tabId] ?? 0
  }

  static func toolbarReady(windowId: String, tabId: String, toolbar supplied: ToolbarView? = nil) {
    guard let toolbar = supplied ?? NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId),
      let state = toolbar.state, state.tabId == tabId, toolbar.window != nil else { return }
    let window = entry(windowId)
    let contribution = Contribution(palette: state.palette, card: state.autoHideCard, stripes: state.stripes, held: state.autoHideHeld == true)
    if window.contributions.updateValue(contribution, forKey: tabId) != contribution
      || window.strips[tabId].map({ $0.toolbar !== toolbar }) == true {
      refresh(windowId)
    }
  }

  static func windowEnded(_ windowId: String) {
    guard let window = windows[windowId] else { return }
    window.controller.stop()
    for id in Array(window.strips.keys) { remove(windowId: windowId, tabId: id) }
    windows[windowId] = nil
  }

  private static func remove(windowId: String, tabId: String) {
    guard let pane = windows[windowId]?.strips.removeValue(forKey: tabId) else { return }
    pane.strip.retire()
    if pane.toolbar?.state?.tabId == tabId {
      pane.toolbar?.setAutoHideBackdrop(false)
      pane.toolbar?.setAutoHide(opacity: 1, scale: 1, lift: 0, interactive: true)
    }
    if !NativeWindowShell.nativeLayoutActive(windowId) {
      setLegacyTop(nil, viewport: nil, windowId: windowId, tabId: tabId)
    }
  }

  static func layoutTop(windowId: String, tabId: String) -> CGFloat? {
    windows[windowId]?.strips[tabId].map { CGFloat($0.strip.presentationTop) }
  }

  #if DEBUG
  static func devStripHost(windowId: String, tabId: String) -> String? {
    guard let strip = windows[windowId]?.strips[tabId]?.strip, strip.window != nil else { return nil }
    return strip.devLabelText
  }
  #endif
}
