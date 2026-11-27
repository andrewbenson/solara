import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeDownloadsPanel {
  nonisolated static let surfaceKind = "downloadsSurface"
  nonisolated static let buttonKind = "downloadsButton"
  private static weak var observed: Store?
  private static var lifecycle: Int?
  private static var listener: Int?
  private static var panels: [String: DownloadsPanelView] = [:]
  private static var profiles: [String: String] = [:]
  private static let inlineSurfaces = NSMapTable<NSString, DownloadsInlineSurface>.strongToWeakObjects()
  private static var buttons: [String: NSHashTable<DownloadButtonView>] = [:]
  private static var pending = false
  private static var escapeMonitor: Any?

  static func register() {
    HostedViews.register(surfaceKind) { windowId in
      let surface = DownloadsInlineSurface(frame: .zero)
      let key = windowId as NSString
      inlineSurfaces.setObject(surface, forKey: key)
      queueRefresh()
      return HostedContent(view: surface, onUnmount: {
        if inlineSurfaces.object(forKey: key) === surface {
          inlineSurfaces.removeObject(forKey: key)
          remove(windowId)
          queueRefresh()
        }
      }, takesFocus: false)
    }
    HostedViews.register(buttonKind) { windowId in
      let button = DownloadButtonView(frame: .zero)
      let windowButtons = buttons[windowId] ?? .weakObjects()
      windowButtons.add(button)
      buttons[windowId] = windowButtons
      updateButton(button, windowId: windowId)
      queueRefresh()
      button.onPress = { [weak button] in
        guard let button, button.window === ShellDrag.window(windowId),
          let store = NativeStoreHandle.store, NativeStoreHandle.ownsWorkspace else { return }
        setOpen(windowId, store.state.windowUi[windowId]?.downloadsOpen != true)
      }
      return HostedContent(view: button, onUnmount: {
        button.end()
        windowButtons.remove(button)
        if windowButtons.allObjects.isEmpty { buttons[windowId] = nil }
      }, takesFocus: false)
    }
  }

  static func start() {
    guard lifecycle == nil else { return }
    NotificationCenter.default.addObserver(forName: Notification.Name("SolaraWindowChromeCommitted"), object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { queueRefresh() }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle {
      let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
      guard observed !== store else { return }
      if let listener { observed?.unsubscribe(listener) }
      for id in Array(panels.keys) { remove(id) }
      NativeDownloadActions.reset()
      NativeDownloadMagnet.reset()
      observed = store
      listener = store?.subscribe { [weak store] commit in
        let changes = commit.changes
        guard changes.downloads || !changes.windowUi.isEmpty || !changes.windows.isEmpty || !changes.profiles.isEmpty
          || changes.settings || changes.lists.contains("ui") else { return }
        let fresh = changes.downloads && commit.commands.contains { $0.name == "upsertDownload" }
        DispatchQueue.main.async {
          guard let store, store === observed else { return }
          if changes.downloads {
            NativeDownloadActions.downloadsChanged(store.state)
            if fresh && !changes.windowUi.isEmpty { NativeDownloadMagnet.attach(store.state) }
            NativeDownloadMagnet.downloadsChanged(commit.state, fly: fresh)
          }
          if !changes.windowUi.isEmpty || !changes.windows.isEmpty || !changes.profiles.isEmpty || changes.settings || changes.lists.contains("ui") {
            queueRefresh()
          } else if changes.downloads {
            refreshOpenPanels(store.state)
          }
        }
      }
      NativeDownloadMagnet.seed(store?.state.downloads ?? [])
      queueRefresh()
    }
  }

  static func setOpen(_ windowId: String, _ open: Bool) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      store.state.windows[windowId] != nil else { return }
    _ = try? store.dispatch(Command("setDownloadsOpen", [.string(windowId), .bool(open)]), origin: .native)
  }

  static func queueRefresh() {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.async {
      pending = false
      refresh()
    }
  }

  private static func refresh() {
    guard let state = observed?.state else { return }
    for id in Array(panels.keys) where state.windows[id] == nil || !mountsInWindow(id) {
      remove(id)
    }
    for (id, window) in state.windows where panels[id] != nil || state.windowUi[id]?.downloadsOpen == true {
      updatePanel(id, window: window, state: state)
    }
    for (id, windowButtons) in buttons {
      for button in windowButtons.allObjects { updateButton(button, windowId: id) }
    }
    NativeDownloadMagnet.attach(state)
  }

  private static func refreshOpenPanels(_ state: BrowserState) {
    for id in Array(panels.keys) {
      if let window = state.windows[id], state.windowUi[id]?.downloadsOpen == true {
        updatePanel(id, window: window, state: state)
      }
    }
  }

  private static func updateButton(_ button: DownloadButtonView, windowId: String) {
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return }
    let open = state.windowUi[windowId]?.downloadsOpen == true
    let appearance = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let tooltip = appearance.controls(state: state, window: window).downloadsTooltip
    button.update(open: open, tooltip: open ? nil : tooltip, theme: appearance.tokens)
  }

  static func panel(_ id: String) -> DownloadsPanelView? { panels[id] }

  private static func mountsInWindow(_ id: String) -> Bool {
    panels[id]?.window != nil && panels[id]?.window === ShellDrag.window(id)
  }

  static func container(_ id: String) -> NSView? {
    guard let window = ShellDrag.window(id) else { return nil }
    if let overlay = NativeWindowShell.overlay(id), overlay.window === window { return overlay }
    guard let inline = inlineSurfaces.object(forKey: id as NSString), inline.window === window else { return nil }
    return inline
  }

  static func anchor(_ id: String, topStrip: Bool, in view: NSView) -> CGRect? {
    guard let window = view.window else { return nil }
    let peek = TopStripPeekHost.hosts[id]
    let strip = peek?.view.live == true ? peek?.row.controls.downloadsRect : NativeTopStrip.downloadsRect(id)
    let sidebar = NativeSidebarShell.column(id).flatMap { column in
      column.isHiddenOrHasHiddenAncestor || column.chrome.isHidden ? nil : column.chrome.downloadsRect
    }
    let button = buttons[id]?.allObjects.first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
    let rect = (topStrip ? strip : sidebar) ?? button.map { $0.convert($0.bounds, to: nil) }
    guard let rect else { return nil }
    let local = view.convert(rect, from: nil)
    guard !local.isEmpty, view.bounds.contains(local) else { return nil }
    if view.isFlipped { return local }
    return CGRect(x: local.minX, y: view.bounds.height - local.maxY, width: local.width, height: local.height)
  }

  private static func updatePanel(_ id: String, window: BrowserWindow, state: BrowserState) {
    let open = state.windowUi[id]?.downloadsOpen == true
    guard open else {
      if let panel = panels[id], var previous = panel.state {
        previous.closing = true
        panel.update(previous)
      }
      return
    }
    guard let container = container(id), container.window != nil, !container.bounds.isEmpty else { return }
    let panel = panels[id] ?? make(id)
    if panel.superview !== container {
      panel.frame = container.bounds
      panel.autoresizingMask = [.width, .height]
      container.addSubview(panel)
    }
    let top = (window.tabLayout ?? state.settings.string("tabLayout")) == "top"
    let footer = !top && state.settings.string("addressBar") == "sidebar"
    let geometry = DownloadsPanelPlacement.resolve(in: panel.bounds.size, anchor: anchor(id, topStrip: top, in: panel),
      topStrip: top, footer: footer, scale: panel.window?.backingScaleFactor ?? 2)
    let appearance = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito, strip: top)
    let downloads = state.visibleDownloads(in: id)
    profiles[id] = window.profileId
    let list = DownloadsListState(rows: downloads.prefix(Download.maxKept).map(DownloadRowState.init), clearable: downloads.contains { !$0.isDownloading },
      listMax: geometry.listMax, dark: appearance.dark, theme: appearance.tokens)
    panel.update(DownloadsPanelState(list: list, placement: geometry.placement, closing: false))
  }

  private static func make(_ id: String) -> DownloadsPanelView {
    let panel = DownloadsPanelView(frame: .zero)
    panels[id] = panel
    DownloadsHoverShifts.shown.add(panel.list)
    panel.onResize = { queueRefresh() }
    panel.onDismiss = { [weak panel] in
      guard let panel, panels[id] === panel, panel.window === ShellDrag.window(id) else { return }
      setOpen(id, false)
    }
    panel.onClosed = { [weak panel] in
      guard let panel, panels[id] === panel else { return }
      if observed?.state.windowUi[id]?.downloadsOpen == true { queueRefresh() }
      else { remove(id) }
    }
    panel.onEvent = { [weak panel] event in
      guard let panel, panels[id] === panel, let window = panel.window, let profile = profiles[id],
        observed?.state.windowUi[id]?.downloadsOpen == true else { return }
      NativeDownloadActions.perform(event, windowId: id, profileId: profile, in: window, panel: true)
    }
    if escapeMonitor == nil {
      escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 53, let window = event.window,
          let id = panels.first(where: { $0.value.window === window && !$0.value.isClosing })?.key else { return event }
        setOpen(id, false)
        return nil
      }
    }
    return panel
  }

  private static func remove(_ id: String) {
    guard let panel = panels.removeValue(forKey: id) else { return }
    profiles.removeValue(forKey: id)
    panel.end()
    panel.removeFromSuperview()
    if panels.isEmpty, let monitor = escapeMonitor {
      NSEvent.removeMonitor(monitor)
      escapeMonitor = nil
    }
  }

  #if DEBUG
  static func describe(_ windowId: String) -> String {
    guard let info = read(windowId) else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: info)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  static func read(_ windowId: String) -> [String: Any]? {
    guard let panel = panels[windowId], panel.superview != nil else { return nil }
    func inWindow(_ view: NSView, _ r: CGRect) -> [Double] {
      let w = view.convert(r, to: nil)
      let h = view.window?.contentView?.bounds.height ?? 0
      return [w.minX, h - w.maxY, w.width, w.height]
    }
    var controls: [String: [Double]] = [:]
    func walk(_ view: NSView) {
      if view.accessibilityRole() == .button, let name = view.accessibilityLabel(), !name.isEmpty { controls[name] = inWindow(view, view.bounds) }
      view.subviews.forEach(walk)
    }
    walk(panel.list)
    let top = observed?.state.windows[windowId]?.tabLayout ?? observed?.state.settings.string("tabLayout")
    let button = anchor(windowId, topStrip: top == "top", in: panel)
    let info: [String: Any] = [
      "button": button.map { inWindow(panel, $0) } ?? NSNull(),
      "card": panel.cardFrame.map { inWindow(panel, $0) } ?? NSNull(), "list": inWindow(panel.list, panel.list.bounds), "opacity": panel.presentedOpacity,
      "progress": panel.progress, "closing": panel.isClosing, "controls": controls,
      "root": inWindow(panel, panel.bounds), "rows": panel.state?.list.rows.map(\.id) ?? [],
      "placement": panel.state.map { state in
        var placement: [String: Any] = ["left": state.placement.left, "width": state.placement.width, "arrow": state.placement.arrow.rawValue, "arrowX": state.placement.arrowX]
        if let top = state.placement.top { placement["top"] = top }
        if let bottom = state.placement.bottom { placement["bottom"] = bottom }
        return placement
      } ?? [:],
    ]
    return info
  }
  #endif
}

@MainActor
private final class DownloadsInlineSurface: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { NativeDownloadsPanel.queueRefresh() }
  }
}

#if SOLARA_PROBES
@MainActor
public enum DownloadsPanelRead {
  public static func panel(windowId: String) -> [String: Any]? {
    guard var info = NativeDownloadsPanel.read(windowId) else { return nil }
    let controls = info["controls"] as? [String: [Double]] ?? [:]
    info["controls"] = controls.filter { ["View all downloads", "Clear"].contains($0.key) }
    return info
  }
}
#endif
