import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeSidebarShell {
  nonisolated static let topic = "sidebar.shell"
  private static var observer: UUID?
  private static var shellAppeared: NSObjectProtocol?
  private static var columns: [String: SidebarShellColumn] = [:]

  nonisolated static var enabled: Bool {
    NativeWindowShell.enabled
  }

  static func register() {
    guard enabled, !NativeWindowShell.nativeLayout, observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    shellAppeared = NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: nil, queue: .main) { note in
      guard note.object is WindowShellView else { return }
      MainActor.assumeIsolated { receive(SettingsJS.shared.latestValue(topic)) }
    }
    receive(SettingsJS.shared.latestValue(topic))
  }

  static func adopt(_ column: SidebarShellColumn) { columns[column.windowId] = column }

  static func release(_ column: SidebarShellColumn) {
    if columns[column.windowId] === column { columns[column.windowId] = nil }
  }

  static func column(_ windowId: String) -> SidebarShellColumn? { columns[windowId] }

  static func dropGlow(_ windowId: String, js: Bool) -> Bool {
    TabDragSession.current.map { $0.outside && $0.overWindow == windowId } ?? js
  }

  static func describe(_ windowId: String) -> String {
    guard let column = columns[windowId], let data = try? JSONSerialization.data(withJSONObject: column.describe()) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  private static func receive(_ value: Any?) {
    guard !NativeWindowShell.nativeLayout else { return }
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, column) in columns where windows[windowId] == nil { remove(windowId, column) }
    for (windowId, given) in windows {
      guard let given = given as? [String: Any], let state = given["state"] as? String, let column = columns[windowId] ?? make(windowId) else { continue }
      let number = { (key: String) in CGFloat((given[key] as? NSNumber)?.doubleValue ?? 0) }
      column.apply(
        state: state,
        layout: SidebarShellColumn.Layout(top: number("top"), header: number("header"), bottom: number("bottom"), clip: (given["clip"] as? Bool) ?? false),
        chrome: (given["chrome"] as? String).flatMap(SidebarChromeState.decode))
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
    }
  }

  private static func make(_ windowId: String) -> SidebarShellColumn? {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return nil }
    let host = SidebarHost(windowId: windowId, virtualizesRows: true)
    NativeSidebar.hosts[windowId] = host
    let column = SidebarShellColumn(windowId: windowId, host: host)
    columns[windowId] = column
    shell.mount(.sidebar, column)
    return column
  }

  private static func remove(_ windowId: String, _ column: SidebarShellColumn) {
    columns[windowId] = nil
    if let shell = NativeWindowShell.host(windowId)?.shell, shell.view(in: .sidebar) === column { shell.mount(.sidebar, nil) }
    column.removeFromSuperview()
    column.stop()
    if NativeSidebar.hosts[windowId] === column.host { NativeSidebar.hosts[windowId] = nil }
  }

  @discardableResult
  static func dropped(_ windowId: String, items: [[String: String]], placement: String?) -> Bool {
    if openDropped(windowId, items: items, placement: placement) { return true }
    send(windowId, "drop", ["items": items, "placement": placement ?? NSNull()])
    return false
  }

  static func openDropped(_ windowId: String, items: [[String: String]], placement: String?) -> Bool {
    guard let store = SettingsWrites.directStore else { return false }
    var parsed: JSONValue?
    if let placement {
      do {
        parsed = try JSONValue.parse(placement)
      } catch {
        NSLog("[drop] %@: a malformed placement opens nothing: %@", windowId, String(describing: error))
        return true
      }
    }
    let landing = parsed
    DispatchQueue.main.async { [weak owner = store] in
      MainActor.assumeIsolated {
        guard let store = SettingsWrites.directStore, store === owner else {
          return NSLog("[drop] %@: the store stood down before the drop opened", windowId)
        }
        DroppedTabs.open(store, windowId: windowId, items: items, placement: landing) { error in
          NSLog("[drop] %@: the store refused part of a drop: %@", windowId, String(describing: error))
        }
        FrameUpdates.flush()
      }
    }
    return true
  }

  static func send(_ windowId: String, _ event: String, _ extra: [String: Any] = [:]) {
    let payload = SidebarPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, event, payload.value)
    }
  }
}

@MainActor
final class SidebarShellColumn: NSView, DevDropDestination, NSSpringLoadingDestination {
  struct Layout: Equatable {
    var top: CGFloat = 0
    var header: CGFloat = 0
    var bottom: CGFloat = 0
    var clip = false
  }

  let windowId: String
  let host: SidebarHost
  let chrome = SidebarChromeView()
  private let list = FlippedContainerView()
  private var pagerObserver: NSObjectProtocol?
  private var dragObserver: NSObjectProtocol?
  #if DEBUG
  private var nativeDrops = 0
  #endif
  private var jsDropOver = false
  private var given = Layout()
  private var dropCount = 0
  private var carrySpring = DragCarrySpring()
  private var stopped = false

  override var isFlipped: Bool { true }

  init(windowId: String, host: SidebarHost) {
    self.windowId = windowId
    self.host = host
    super.init(frame: .zero)
    NativeDragCarry.register()
    list.wantsLayer = true
    list.autoresizingMask = []
    host.view.autoresizingMask = [.width, .height]
    list.addSubview(host.view)
    addSubview(list)
    chrome.autoresizingMask = [.width, .height]
    chrome.isHidden = true
    chrome.onAction = { [weak self] action in self?.chromeAction(action) }
    chrome.onFullScreenPresentationChange = { [weak self] in self?.placeList() }
    chrome.onBlankMouseDown = { event in Self.blankMouseDown(event) }
    addSubview(chrome)
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.chrome.setPagerPosition(position) }
    }
    dragObserver = NotificationCenter.default.addObserver(forName: TabDragSession.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.dragChanged() }
    }
    registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])
  }

  required init?(coder: NSCoder) { fatalError() }

  private var debugNativeDrops: Any {
    #if DEBUG
    nativeDrops
    #else
    NSNull()
    #endif
  }

  private func dragChanged() {
    guard !stopped else { return }
    let over = NativeSidebarShell.dropGlow(windowId, js: jsDropOver)
    guard var state = chrome.state, state.dropOver != over else { return }
    state.dropOver = over
    chrome.update(state)
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    unregisterDraggedTypes()
    leave()
    chrome.onAction = { _ in }
    chrome.onFullScreenPresentationChange = nil
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
    if let dragObserver { NotificationCenter.default.removeObserver(dragObserver) }
    dragObserver = nil
    if NativeSidebar.hosts[windowId] === host { syncAddress(false) }
    host.stop()
  }

  func apply(state: String, layout: Layout, chrome look: SidebarChromeState?) {
    guard !stopped else { return }
    let previousFooter = footerInset
    let previousTop = topInset
    let previousLift = listLift
    chrome.isHidden = look == nil
    if var look {
      look.iconsOnly = effectiveRail(width: bounds.width)
      jsDropOver = look.dropOver
      look.dropOver = NativeSidebarShell.dropGlow(windowId, js: jsDropOver)
      chrome.update(look)
    }
    syncAddress(chrome.state?.addressBar == true && chrome.state?.rail != true)
    if layout != given || previousFooter != footerInset || previousTop != topInset || previousLift != listLift {
      given = layout
      placeList()
    }
    host.apply(state)
  }

  func apply(state: BrowserState, host look: SidebarHostState, layout: Layout, chrome: SidebarChromeState, renderHost: Bool = true) {
    guard !stopped else { return }
    self.chrome.isHidden = false
    var chrome = chrome
    chrome.iconsOnly = effectiveRail(width: bounds.width)
    jsDropOver = chrome.dropOver
    chrome.dropOver = NativeSidebarShell.dropGlow(windowId, js: jsDropOver)
    self.chrome.update(chrome)
    given = layout
    syncAddress(chrome.addressBar && !chrome.rail)
    placeList()
    if renderHost { host.apply(state: state, host: look) }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    guard !stopped else { return }
    if var state = chrome.state {
      let rail = effectiveRail(width: newSize.width)
      if state.rail != rail {
        state.iconsOnly = rail
        chrome.update(state)
        syncAddress(state.addressBar && !rail)
      }
    }
    placeList()
  }

  private var shellView: WindowShellView? {
    var up = superview
    while let at = up, !(at is WindowShellView) { up = at.superview }
    return up as? WindowShellView
  }

  private func effectiveRail(width: CGFloat) -> Bool {
    if let shell = shellView, shell.input.windowFullscreen, !shell.input.topTabs {
      return SidebarRail.contains(width: Double(shell.input.sidebarWidth))
    }
    return SidebarRail.contains(width: Double(width))
  }

  private var topInset: CGFloat {
    chrome.isHidden ? given.top : chrome.sidebarListTopInset(given.top)
  }

  private var footerInset: CGFloat { chrome.isHidden ? given.bottom : chrome.footerHeight }

  private var bottomBarHeight: CGFloat { !chrome.isHidden && chrome.state?.rail != true ? footerInset : 0 }

  private var listLift: CGFloat {
    guard let state = chrome.state, state.rail, !chrome.isHidden else { return 0 }
    return SidebarRail.listLift(addressBar: state.addressBar)
  }

  private func placeList() {
    let lift = listLift
    let barHeight = bottomBarHeight
    host.view.bottomBarHeight = barHeight
    list.frame = CGRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset - footerInset + barHeight))
    list.layer?.masksToBounds = given.clip || lift > 0 || chrome.reservesFullScreenCaption
    host.view.frame = CGRect(x: 0, y: -lift, width: list.bounds.width, height: list.bounds.height + lift)
    let chromeTop = chrome.state?.rail == true ? chrome.toolbarBandBottom : 0
    chrome.frame = CGRect(x: 0, y: chromeTop, width: bounds.width, height: max(0, bounds.height - chromeTop))
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    if chrome.isHidden, local.y < given.header || local.y >= bounds.height - given.bottom || (shellView?.input.sidebarSide == .right ? local.x < SidebarChromeMetrics.resizeStrip : local.x >= bounds.width - SidebarChromeMetrics.resizeStrip) {
      return nil
    }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func describe() -> [String: Any] {
    let inWindow = convert(bounds, to: nil)
    let list = host.view.convert(host.view.bounds, to: nil)
    let height = window?.contentView?.bounds.height ?? 0
    let rect = { (r: CGRect) -> [Double] in [r.minX, height - r.maxY, r.width, r.height] }
    return [
      "nativeDrops": debugNativeDrops, "frame": rect(inWindow), "list": rect(list), "header": given.header, "bottom": footerInset, "clip": given.clip,
      "slot": shellView?.slot(containing: self)?.rawValue ?? NSNull(), "hidden": isHiddenOrHasHiddenAncestor,
      "hover": host.view.current?.hoverKey ?? NSNull(),
      "reactUnder": reactUnderList().map { [$0.0, $0.1.minX, height - $0.1.maxY, $0.1.width, $0.1.height] },
      "chrome": chrome.isHidden ? NSNull() : chrome.describe(), "downloads": chrome.downloadsRect.map(rect) ?? NSNull(),
    ]
  }

  private func reactUnderList() -> [(String, CGRect)] {
    #if DEBUG
    guard let shell = superview as? WindowShellView, let react = shell.view(in: .react), let window else { return [] }
    let list = host.view.convert(host.view.bounds, to: nil)
    var found: [(String, CGRect)] = []
    func visit(_ view: NSView) {
      guard !view.isHidden, view.alphaValue > 0.01 else { return }
      let box = view.convert(view.bounds, to: nil)
      if view !== react, box.intersects(list), Self.draws(view) { found.append((NSStringFromClass(type(of: view)), box)) }
      for child in view.subviews { visit(child) }
    }
    if window.contentView != nil { visit(react) }
    return found
    #else
    return []
    #endif
  }

  private static func draws(_ view: NSView) -> Bool {
    let name = NSStringFromClass(type(of: view))
    guard name.hasPrefix("RCT"), !name.contains("Text"), !name.contains("Image") else { return true }
    if view.responds(to: Selector(("backgroundColor"))), let color = view.value(forKey: "backgroundColor") as? NSColor, (color.usingColorSpace(.sRGB)?.alphaComponent ?? 1) > 0 { return true }
    return view.layer?.contents != nil || (view.layer?.backgroundColor?.alpha ?? 0) > 0
  }

  private func syncAddress(_ shown: Bool) {
    let bars = SidebarAddressBars.shared
    guard shown else {
      if let bar = bars.existing(windowId), bar.superview === chrome.addressSlot { bar.removeFromSuperview() }
      return bars.release(windowId)
    }
    bars.claim(windowId)
    let bar = bars.view(windowId)
    guard bar.superview !== chrome.addressSlot else { return }
    bar.removeFromSuperview()
    bar.frame = chrome.addressSlot.bounds
    bar.autoresizingMask = [.width, .height]
    chrome.addressSlot.addSubview(bar)
  }

  private func chromeAction(_ action: SidebarChromeAction) {
    let shell = NativeWindowShell.host(windowId)?.shell
    switch action {
    case .profileMenu: NativeSidebarShell.send(windowId, "profileMenu")
    case .manageProfiles: NativeSidebarShell.send(windowId, "manageProfiles")
    case .toggleDownloads: NativeSidebarShell.send(windowId, "toggleDownloads")
    case .switchProfile(let id):
      _ = try? NativeStoreHandle.store?.dispatch(Command("switchProfile", [.string(windowId), .string(id)]), origin: .native)
      FrameUpdates.flush()
    case .changeProfileIcon(let id, let icon):
      _ = try? NativeStoreHandle.store?.dispatch(Command("updateProfile", [.string(id), .object(["icon": icon.map(JSONValue.string) ?? .null])]), origin: .native)
      FrameUpdates.flush()
    case .profileIntent(let id): NativeProfileWarmup.shared.hover(id, source: "footer")
    case .liveWidth(let width):
      shell?.widthDragActive = width != nil
      if let width { shell?.update { $0.sidebarWidth = CGFloat(width) } }
      NativeSidebarShell.send(windowId, "liveWidth", ["width": width ?? NSNull()])
    case .commitWidth(let width): NativeSidebarShell.send(windowId, "commitWidth", ["width": width])
    case .resetWidth:
      shell?.update { $0.sidebarWidth = CGFloat(SidebarChromeMetrics.defaultWidth) }
      NativeSidebarShell.send(windowId, "commitWidth", ["width": SidebarChromeMetrics.defaultWidth])
    case .installUpdate: AppUpdater.shared.installPendingUpdate(nil)
    case .iconsOnly(let on):
      let full = SidebarResizeMath.clamp(chrome.state?.savedWidth ?? SidebarChromeMetrics.defaultWidth)
      shell?.update { $0.sidebarWidth = CGFloat(on ? SidebarRail.width : full) }
      NativeSidebarShell.send(windowId, "iconsOnly", ["on": on])
    }
  }

  private static func blankMouseDown(_ event: NSEvent) {
    guard let window = event.window else { return }
    var key = NSApp.keyWindow
    while let k = key, k !== window { key = k.parent }
    if key == nil, window.canBecomeKey, !event.modifierFlags.contains(.command) { window.makeKeyAndOrderFront(nil) }
    if event.clickCount == 2 { return WindowTitlebar.doubleClick(window, event.modifierFlags) }
    window.performDrag(with: event)
  }

  private func windowPoint(_ info: NSDraggingInfo) -> CGPoint {
    CGPoint(x: info.draggingLocation.x, y: (window?.contentView?.bounds.height ?? 0) - info.draggingLocation.y)
  }

  private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
    guard dropCount > 0 else { return [] }
    let mask = info.draggingSourceOperationMask
    if mask.contains(.copy) { return .copy }
    if mask.contains(.generic) { return .generic }
    return mask.contains(.link) ? .link : []
  }

  private func carryTarget(_ sender: NSDraggingInfo) -> DragCarryTarget? {
    guard !stopped, window != nil, !isHiddenOrHasHiddenAncestor, TabDragSession.current == nil,
      NativeDragCarry.admits(sequence: sender.draggingSequenceNumber, windowId: windowId),
      DragCarrySpring.accepts(sender.draggingPasteboard), bounds.contains(convert(sender.draggingLocation, from: nil)) else { return nil }
    if let id = chrome.dragCarryProfile(at: sender.draggingLocation) { return .profile(id) }
    return host.view.current?.dragCarryTab(at: sender.draggingLocation).map(DragCarryTarget.tab)
  }

  func springLoadingEntered(_ sender: NSDraggingInfo) -> NSSpringLoadingOptions { springLoadingUpdated(sender) }

  func springLoadingUpdated(_ sender: NSDraggingInfo) -> NSSpringLoadingOptions {
    let target = carryTarget(sender)
    if carrySpring.update(target, sequence: sender.draggingSequenceNumber) { sender.resetSpringLoading() }
    return target == nil ? [] : .enabled
  }

  func springLoadingActivated(_ activated: Bool, draggingInfo sender: NSDraggingInfo) {
    guard activated, let target = carrySpring.activate(carryTarget(sender), sequence: sender.draggingSequenceNumber) else { return }
    _ = NativeDragCarry.activate(target, windowId: windowId)
  }

  func springLoadingHighlightChanged(_ sender: NSDraggingInfo) {}

  func springLoadingExited(_ sender: NSDraggingInfo) { carrySpring.cancel() }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropCount = DroppedLinks.count(sender.draggingPasteboard)
    guard dropCount > 0 else { return [] }
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "enter", at: windowPoint(sender), count: dropCount)
    return operation(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard dropCount > 0 else { return [] }
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "move", at: windowPoint(sender), count: dropCount)
    return operation(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { leave() }

  override func draggingEnded(_ sender: NSDraggingInfo) { leave() }

  private func leave() {
    carrySpring.cancel()
    guard dropCount > 0 else { return }
    dropCount = 0
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "leave", at: .zero, count: 0)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropCount > 0 }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    carrySpring.cancel()
    guard dropCount > 0 else { return false }
    dropCount = 0
    let items = DroppedLinks.items(sender.draggingPasteboard)
    let placement = NativeSidebarDrag.external(windowId: windowId, phase: "drop", at: windowPoint(sender), count: items.count)
    #if DEBUG
    if NativeSidebarShell.dropped(windowId, items: items, placement: placement) { nativeDrops += 1 }
    #else
    NativeSidebarShell.dropped(windowId, items: items, placement: placement)
    #endif
    return !items.isEmpty
  }
}

#if SOLARA_PROBES
@MainActor
public enum SidebarChromeRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let column = NativeSidebarShell.column(windowId) else { return nil }
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return nil }
    let committed = window.effectiveSidebarWidth(state.settings)
    let effective = SidebarRail.effectiveWidth(window, state.settings)
    return ["liveWidth": Double(column.frame.width), "committedWidth": committed, "effectiveWidth": effective, "iconsOnly": window.effectiveSidebarIconsOnly(state.settings)]
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum SidebarShellRead {
  public static func snapshot(windowId: String) -> [String: Any]? { NativeSidebarShell.column(windowId)?.describe() }
}
#endif

@MainActor
final class NativeLayoutChrome {
  private static var owners: [String: NativeLayoutChrome] = [:]
  private static var feeds: [UUID] = []

  static func renameChanged(_ windowId: String) {
    guard let owner = owners[windowId], !owner.stopped else { return }
    owner.refresh()
  }

  static func downloadsRect(_ windowId: String) -> NSRect? {
    guard let owner = owners[windowId], !owner.stopped, !owner.stripRow.isHiddenOrHasHiddenAncestor else { return nil }
    return owner.controls.downloadsRect
  }
  let shell: WindowShellView
  let generation: UInt64
  let column: SidebarShellColumn
  let strip: TopStripHost
  let peek: TopStripPeekHost
  let dock: SidebarDock
  let controls: StripControlsView
  private let glow = TopStripGlowHost()
  private var stripOver = false
  private var glowOver = false
  private var glowLook: (accent: String, dark: Bool)?
  #if DEBUG
  private var refreshes = 0
  private var stripNativeDrops = 0
  #endif
  private let stripRow: NativeLayoutStripRow
  private let stripDrop: NativeLayoutStripDropView
  private let peekDrop: NativeLayoutStripDropView
  private struct RefreshKey: Equatable {
    let revision: Int
    let feed: UInt64
    let bounds: CGRect
    let input: DockedLayoutInput
    let fullscreen: Bool
    let windowFullscreen: Bool
  }
  private var refreshing = false
  private var lastRefresh: RefreshKey?
  private var feedRevision: UInt64 = 0
  private var state: BrowserState?
  private var revision = -1
  private var sidebarFeed: SidebarHostState?
  private var stripFeed: StripHostState?
  private var featureChrome: SidebarChromeState?
  private var held = false
  private let revealHolds = RevealHolds()
  #if DEBUG
  static func devRevealHeld(_ windowId: String) -> Bool? { owners[windowId].map { $0.revealHolds.held } }
  #endif
  private var holdTokens: [String: UUID] = [:]
  private var holdObservers: [NSObjectProtocol] = []
  private var stopped = false

  init(windowId: String, shell: WindowShellView, generation: UInt64) {
    self.shell = shell
    self.generation = generation
    let host = SidebarHost(windowId: windowId, subscribeToStore: false, virtualizesRows: true)
    column = SidebarShellColumn(windowId: windowId, host: host)
    strip = TopStripHost(windowId: windowId, subscribeToStore: false)
    let floating = TopStripPeekHost(windowId: windowId, subscribeToStore: false)
    floating.strip.view.takesDrops = true
    peek = floating
    stripRow = NativeLayoutStripRow(strip: strip.view)
    stripDrop = NativeLayoutStripDropView(content: stripRow)
    peekDrop = NativeLayoutStripDropView()
    controls = stripRow.controls
    let initial = NativeStoreHandle.store?.state
    let window = initial?.windows[windowId]
    let topTabs = (window?.tabLayout ?? initial?.settings.string("tabLayout")) == "top"
    dock = SidebarDock(shell: shell, state: SidebarDockState(open: topTabs || (window?.sidebarOpen ?? true),
      arc: !topTabs && initial?.settings.string("addressBar") == "sidebar", topTabs: topTabs,
      width: window.flatMap { window in initial.map { SidebarRail.effectiveWidth(window, $0.settings) } } ?? Double(ShellMetrics.sidebarWidth),
      sidebarPosition: window.flatMap { window in initial.map { window.effectiveSidebarPosition($0.settings) } } ?? "left"))
    Self.owners[windowId] = self
    NativeSidebar.hosts[windowId] = host
    NativeSidebarShell.adopt(column)
    NativeSidebarDock.adopt(dock, windowId: windowId)
    NativeTopStrip.hosts[windowId] = strip
    TopStripPeekHost.hosts[windowId] = peek
    TopStripGlowHost.hosts[windowId] = glow
    stripRow.addSubview(glow.view)
    shell.mount(.sidebar, column)
    shell.mount(.topStrip, stripDrop)
    peek.view.content = nil
    peekDrop.hold(peek.row)
    peek.view.content = peekDrop
    shell.overlay.addSubview(peek.view)
    configureDrop(stripDrop, host: strip, floating: false)
    configureDrop(peekDrop, host: peek.strip, floating: true)
    dock.column = { [weak self] in self?.stopped == false ? self?.column : nil }
    dock.onWatch = { [weak self] hold in
      guard let self, !self.stopped, Self.owners[windowId] === self else { return }
      ShellWindowEdge.watch(windowId, hold: hold, side: self.shell.input.sidebarSide.rawValue) { [weak self] over in
        guard let self, !self.stopped, Self.owners[windowId] === self else { return }
        self.dock.edge(over: over)
      }
    }
    dock.onLights = { [weak self] center in
      guard let self, !self.stopped, Self.owners[windowId] === self else { return }
      ShellWindowEdge.setLightsCenter(windowId, center)
    }
    controls.onAction = { [weak self] action in
      guard let self, !self.stopped else { return }
      self.sendFeature("topStrip.peek.action", action == .profileMenu ? "profileMenu" : "toggleDownloads")
    }
    dock.onPeekCoverage = { [weak self] live, coverage in
      self?.sendFeature(NativeSidebarDock.topic, "peek", ["live": live, "right": coverage?.maxX ?? 0,
        "rect": coverage.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()])
    }
    dock.onSlideOut = { [weak self] in self?.sendFeature(NativeSidebarDock.topic, "slideOut") }
    stripRow.onPageWidth = { [weak strip] width in strip?.pageWidth = Double(width) }
    peek.onDemand = { [weak self] in
      guard let self, !self.stopped, Self.owners[windowId] === self else { return }
      self.lastRefresh = nil
      FrameUpdates.schedule(self) { [weak self] in
        guard let self, !self.stopped, Self.owners[windowId] === self else { return }
        self.refresh()
      }
    }
    strip.renderingEnabled = false
    peek.strip.renderingEnabled = false
    dock.revealHeld = { [weak self] in self?.revealHolds.held ?? false }
    let stripHeld = peek.view.peek.held
    peek.view.peek.held = { [weak self] in stripHeld() || (self?.revealHolds.held ?? false) }
    revealHolds.onChange = { [weak self] held in
      guard let self, !self.stopped else { return }
      if !held {
        self.dock.peek.recheck()
        self.peek.view.peek.recheck()
      }
    }
    let center = NotificationCenter.default
    for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification, TabDragSession.changed, ToolbarInfoPopover.changed] {
      holdObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        nonisolated(unsafe) let menu = note.object as? NSMenu
        MainActor.assumeIsolated {
          guard let self, !self.stopped else { return }
          if name == NSMenu.didBeginTrackingNotification, let menu {
            self.setHold("menu:\(ObjectIdentifier(menu))", true)
          } else if name == NSMenu.didEndTrackingNotification, let menu {
            self.setHold("menu:\(ObjectIdentifier(menu))", false)
          } else {
            let drag = TabDragSession.current
            self.setHold("drag", drag?.sourceWindow == windowId || drag?.overWindow == windowId)
            self.dragGlowChanged()
            self.setHold("toolbar", ToolbarInfoPopover.current?.anchorView?.window === self.shell.window && self.shell.window != nil)
          }
        }
      })
    }
    Self.installFeeds()
    dock.start()
  }

  private var debugRefreshes: Any {
    #if DEBUG
    refreshes
    #else
    NSNull()
    #endif
  }

  private var debugStripDrops: Any {
    #if DEBUG
    stripNativeDrops
    #else
    NSNull()
    #endif
  }

  func describe() -> [String: Any] {
    let identity: (AnyObject) -> String = { String(describing: ObjectIdentifier($0)) }
    return ["owner": identity(self), "column": identity(column), "dockedStrip": identity(strip.view),
      "floatingStrip": identity(peek.strip.view), "generation": generation, "stopped": stopped,
      "childStoreSubscriptions": column.host.storeSubscriptions + strip.storeSubscriptions + peek.strip.storeSubscriptions,
      "sidebarStoreSubscriptions": column.host.storeSubscriptions, "dockedStripStoreSubscriptions": strip.storeSubscriptions,
      "floatingStripStoreSubscriptions": peek.strip.storeSubscriptions,
      "sidebarRealized": column.host.view.current != nil, "dockedStripRealized": strip.view.current != nil,
      "floatingStripRealized": peek.strip.view.current != nil,
      "dockedStripRendering": strip.renderingEnabled, "floatingStripRendering": peek.strip.renderingEnabled,
      "dockedExternalDrop": stripDrop.active, "floatingExternalDrop": peekDrop.active, "chromeRefreshes": debugRefreshes, "stripNativeDrops": debugStripDrops,
      "sidebarRegistry": NativeSidebar.hosts[shell.windowId] === column.host,
      "stripRegistry": NativeTopStrip.hosts[shell.windowId] === strip,
      "peekRegistry": TopStripPeekHost.hosts[shell.windowId] === peek]
  }

  func apply(state: BrowserState, revision: Int) {
    guard !stopped, revision >= self.revision, state.windows[shell.windowId] != nil else { return }
    self.state = state
    self.revision = revision
    refresh()
  }

  private func dragGlowChanged() {
    let over = NativeSidebarShell.dropGlow(shell.windowId, js: stripOver)
    guard over != glowOver else { return }
    glowOver = over
    guard let glowLook else { return }
    glow.view.set(over: over || stripDrop.active, accent: glowLook.accent, dark: glowLook.dark)
  }

  func refresh() {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("chromeRefresh", "\(shell.windowId) \(revision)")
    defer { LayoutTrace.end(trace) }
    #endif
    guard !stopped, !refreshing else { return }
    #if DEBUG
    refreshes += 1
    #endif
    let nativeInput = state.flatMap(layoutInput)
    strip.renderingEnabled = nativeInput?.layout.topTabs == true
    peek.strip.renderingEnabled = peek.view.live
    let key = RefreshKey(revision: revision, feed: feedRevision, bounds: shell.bounds, input: shell.input, fullscreen: nativeInput?.layout.fullscreen ?? shell.input.fullscreen, windowFullscreen: nativeInput?.windowFullscreen ?? false)
    guard key != lastRefresh else { return }
    if let lastRefresh, lastRefresh.revision == revision, lastRefresh.feed == feedRevision,
      lastRefresh.fullscreen == key.fullscreen, lastRefresh.windowFullscreen == key.windowFullscreen {
      peek.view.frame = shell.overlay.bounds
      stripRow.needsLayout = true
      stripRow.layoutSubtreeIfNeeded()
      glow.view.frame = StripDropGlowMetrics.frame(width: stripRow.bounds.width, left: stripRow.leadingInset + controls.profileSlotWidth, right: StripControlsLayout.trailingReservation)
      self.lastRefresh = key
      return
    }
    refreshing = true
    defer {
      refreshing = false
      lastRefresh = RefreshKey(revision: revision, feed: feedRevision, bounds: shell.bounds, input: shell.input, fullscreen: key.fullscreen, windowFullscreen: key.windowFullscreen)
    }
    guard let state, let window = state.windows[shell.windowId],
      let input = nativeInput else { return }
    let effectiveOpen = input.layout.topTabs || window.sidebarOpen
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    var sidebar = SidebarHostState(profileId: window.profileId, dark: look.dark)
    sidebar.theme = look.tokens
    sidebar.border = look.border
    sidebar.glow = look.glow
    sidebar.addressBar = input.layout.addressBarInSidebar
    sidebar.selection = state.selection[shell.windowId]?.ids ?? []
    sidebar.clear = state.settings["showClearButton"]?.bool ?? true
    sidebar.iconRing = !state.settings.bool("classicPinnedTabs")
    sidebar.newTabAtTop = state.settings.string("newTabButtonPosition") == "top"
    sidebar.pages = window.incognito ? nil : state.profileOrder.map { id in
      let page = NativeLayoutAppearance(state: state, profileId: id, incognito: false)
      return SidebarPageLook(profileId: id, dark: page.dark, theme: page.tokens, border: page.border, glow: page.glow, tidy: false, incognito: false)
    }
    sidebar.incognito = window.incognito
    sidebar.tidy = CommandContext(state: state, windowId: shell.windowId).canTidyPins
    sidebar.cleaned = state.cleanedTabs.filter { $0.windowId == shell.windowId }.count
    if let feed = sidebarFeed {
      sidebar.player = feed.profileId == window.profileId ? feed.player : nil
      sidebar.pip = feed.pip
      sidebar.capture = feed.capture
      sidebar.badge = feed.badge
      sidebar.upsell = feed.profileId == window.profileId ? feed.upsell : nil
      sidebar.product = feed.product
      sidebar.renaming = feed.renaming
      sidebar.engines = feed.engines
      sidebar.developer = feed.developer
      sidebar.newTabMark = feed.newTabMark
      sidebar.closeHint = feed.closeHint
      sidebar.backHint = feed.backHint
    }
    if let renaming = NativeWorkspaceRename.override(shell.windowId) { sidebar.renaming = renaming }
    let dots = window.incognito ? [] : state.profileOrder.enumerated().compactMap { index, id -> SidebarChromeDot? in
      guard let profile = state.profiles[id] else { return nil }
      return SidebarChromeDot(id: id, name: profile.name, slot: Double(index), icon: profile.icon,
        shortcut: CommandShortcutSnapshot().hint("switchProfile:\(id)", state: state),
        color: NativeLayoutAppearance(state: state, profileId: id, incognito: false).tokens["accent"])
    }
    let downloadsTooltip = featureChrome?.controls.downloadsTooltip
      ?? CommandShortcutSnapshot().hint("downloads", state: state).map { "Downloads (\($0))" } ?? "Downloads"
    let controls = StripControlsState(title: input.profileTitle, incognito: window.incognito, profiles: input.profileCount,
      nameColor: look.nameColor, downloadsOpen: state.windowUi[shell.windowId]?.downloadsOpen ?? false,
      downloadsTooltip: downloadsTooltip)
    let chrome = SidebarChromeState(controls: controls, downloads: hasDownloads(state, window), addressBar: sidebar.addressBar,
      dark: look.dark, theme: look.tokens, dots: dots, savedWidth: window.effectiveSidebarWidth(state.settings),
      iconsOnly: window.effectiveSidebarIconsOnly(state.settings), dropOver: featureChrome?.dropOver ?? false,
      update: featureChrome?.update, currentProfileId: window.profileId, sidebarPosition: input.layout.sidebarSide.rawValue,
      windowFullscreen: input.windowFullscreen)
    shell.update {
      $0.topTabs = input.layout.topTabs
      $0.addressBarInSidebar = input.layout.addressBarInSidebar
      $0.sidebarSide = input.layout.sidebarSide
      $0.fullscreen = input.layout.fullscreen
      $0.windowFullscreen = input.windowFullscreen
      if !shell.widthDragActive { $0.sidebarWidth = input.layout.sidebarWidth }
    }
    let top = SidebarChromeMetrics.headerHeight(addressBar: sidebar.addressBar)
    let bottom = SidebarChromeMetrics.footerHeight(chrome)
    column.apply(state: state, host: sidebar, layout: .init(top: max(0, top - SidebarMetrics.glowRoom), header: top, bottom: bottom, clip: state.profileOrder.count > 1), chrome: chrome, renderHost: !input.layout.topTabs)
    setHold("downloads", controls.downloadsOpen)
    setHold("feature", held)
    dock.apply(SidebarDockState(open: effectiveOpen, arc: sidebar.addressBar, fullscreen: input.layout.fullscreen,
      topTabs: input.layout.topTabs, width: Double(input.layout.sidebarWidth), held: held || controls.downloadsOpen,
      sidebarPosition: input.layout.sidebarSide.rawValue, look: look.panel))
    let stripLook = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito, strip: true)
    var strip = StripHostState(profileId: window.profileId, dark: stripLook.dark)
    strip.theme = stripLook.tokens
    strip.border = look.border
    strip.glow = look.glow
    strip.pages = window.incognito ? nil : state.profileOrder.map { id in
      let page = NativeLayoutAppearance(state: state, profileId: id, incognito: false, strip: true)
      return SidebarPageLook(profileId: id, dark: page.dark, theme: page.tokens, border: page.border, glow: page.glow, tidy: false, incognito: false)
    }
    strip.selection = sidebar.selection
    strip.iconRing = sidebar.iconRing
    strip.engines = stripFeed?.engines ?? sidebar.engines
    strip.capture = stripFeed?.capture ?? sidebar.capture ?? [:]
    strip.bands = stripFeed?.bands ?? [:]
    strip.closeHint = stripFeed?.closeHint ?? sidebar.closeHint
    strip.newTabMark = stripFeed?.newTabMark ?? sidebar.newTabMark
    self.strip.renderingEnabled = input.layout.topTabs
    if self.strip.renderingEnabled { self.strip.apply(state: state, host: strip) }
    var stripControls = controls
    stripControls.nameColor = stripLook.nameColor
    stripRow.leadingInset = input.windowFullscreen ? 8 : ShellMetrics.topStripLeadingReservation
    self.controls.windowFullscreen = input.windowFullscreen
    self.controls.update(stripControls, theme: stripLook.tokens)
    stripRow.needsLayout = true
    stripRow.layoutSubtreeIfNeeded()
    glow.view.frame = StripDropGlowMetrics.frame(width: stripRow.bounds.width, left: stripRow.leadingInset + self.controls.profileSlotWidth, right: StripControlsLayout.trailingReservation)
    glowOver = NativeSidebarShell.dropGlow(shell.windowId, js: stripOver)
    glowLook = (stripLook.tokens["accent"] ?? "#4A77D4", stripLook.dark)
    glow.view.set(over: glowOver || stripDrop.active, accent: stripLook.tokens["accent"] ?? "#4A77D4", dark: stripLook.dark)
    strip.floating = true
    peek.view.frame = shell.overlay.bounds
    peek.apply(state: state, host: strip, controls: stripControls,
      enabled: input.layout.topTabs && !effectiveOpen && !input.layout.fullscreen,
      bandLeft: ShellMetrics.topStripLeadingReservation, look: look.panel, renderStrip: peek.view.live)
    if input.layout.topTabs && effectiveOpen { ShellWindowEdge.setLightsCenter(shell.windowId, ShellMetrics.topStripLightsCenter) }
  }

  func stop() {
    guard !stopped else { return }
    let current = Self.owners[shell.windowId] === self
    dock.stop()
    stopped = true
    holdObservers.forEach { NotificationCenter.default.removeObserver($0) }
    holdObservers = []
    revealHolds.onChange = { _ in }
    for token in holdTokens.values { revealHolds.release(token) }
    holdTokens = [:]
    column.stop()
    stripDrop.stop()
    peekDrop.stop()
    strip.stop()
    peek.stop()
    glow.view.stop()
    controls.onAction = { _ in }
    stripRow.onPageWidth = { _ in }
    peek.view.removeFromSuperview()
    if shell.view(in: .sidebar) === column { shell.mount(.sidebar, nil) }
    if shell.view(in: .topStrip) === stripDrop { shell.mount(.topStrip, nil) }
    NativeSidebarShell.release(column)
    NativeSidebarDock.release(dock, windowId: shell.windowId)
    if NativeSidebar.hosts[shell.windowId] === column.host { NativeSidebar.hosts[shell.windowId] = nil }
    if NativeTopStrip.hosts[shell.windowId] === strip { NativeTopStrip.hosts[shell.windowId] = nil }
    if TopStripPeekHost.hosts[shell.windowId] === peek { TopStripPeekHost.hosts[shell.windowId] = nil }
    if TopStripGlowHost.hosts[shell.windowId] === glow { TopStripGlowHost.hosts[shell.windowId] = nil }
    if current {
      ShellWindowEdge.watch(shell.windowId, hold: nil) { _ in }
      Self.owners[shell.windowId] = nil
    }
    state = nil
  }

  private func setHold(_ reason: String, _ held: Bool) {
    if held {
      if holdTokens[reason] == nil { holdTokens[reason] = revealHolds.acquire() }
    } else if let token = holdTokens.removeValue(forKey: reason) {
      revealHolds.release(token)
    }
  }

  private func configureDrop(_ target: NativeLayoutStripDropView, host: TopStripHost, floating: Bool) {
    target.accepts = { [weak self] in
      guard let self, !self.stopped, Self.owners[self.shell.windowId] === self else { return false }
      return floating ? self.peek.view.live && self.peek.strip.renderingEnabled : self.strip.renderingEnabled
    }
    target.incoming = { [weak host] point in host?.view.current?.incoming(at: point) }
    target.clearIncoming = { [weak host] in host?.view.current?.endIncoming() }
    target.carryAdmitted = { [weak self] sender in
      guard let self, !self.stopped else { return false }
      return NativeDragCarry.admits(sequence: sender.draggingSequenceNumber, windowId: self.shell.windowId)
    }
    target.carryTarget = { [weak host] point in host?.view.current?.dragCarryTab(at: point).map(DragCarryTarget.tab) }
    target.onSpring = { [weak self] destination in
      guard let self, !self.stopped, Self.owners[self.shell.windowId] === self else { return }
      _ = NativeDragCarry.activate(destination, windowId: self.shell.windowId)
    }
    target.onDrop = { [weak self] items, placement in
      guard let self else { return }
      if NativeSidebarShell.openDropped(self.shell.windowId, items: items, placement: placement) {
        #if DEBUG
        self.stripNativeDrops += 1
        #endif
        return
      }
      self.sendFeature("topStrip.peek.action", "drop", ["items": items, "placement": placement ?? NSNull()])
    }
    target.onActive = { [weak self] active in
      guard let self, !self.stopped, Self.owners[self.shell.windowId] === self else { return }
      self.setHold(floating ? "floatingDrop" : "stripDrop", active)
      if floating { self.peek.setExternalDropHeld(active) }
      self.lastRefresh = nil
      self.refresh()
    }
  }

  private func sendFeature(_ topic: String, _ event: String, _ values: [String: Any] = [:]) {
    let payload = SidebarPayload(values)
    Task { @MainActor [weak self] in
      guard let self, !self.stopped, Self.owners[self.shell.windowId] === self else { return }
      _ = await SettingsAdapters.js(topic, self.shell.windowId, event, payload.value)
    }
  }

  private func layoutInput(_ state: BrowserState) -> WindowLayoutInput? {
    if let host = NativeWindowShell.host(shell.windowId), host.ownsNativeLayout { return host.makeLayoutInput() }
    return WindowLayoutInput(state: state, windowId: shell.windowId, bounds: shell.bounds, presentation: shell.input)
  }

  private func hasDownloads(_ state: BrowserState, _ window: BrowserWindow) -> Bool {
    state.downloads.contains { download in
      let session = download.offTheRecord ? download.profile ?? "" : download.profile.flatMap { Ids.isIncognitoProfile($0) ? state.privateSession($0) : nil }
      return window.incognito ? session != nil && session == state.privateSession(window.profileId)
        : session == nil && (download.profile ?? "") == state.engineProfile(window.profileId)
    }
  }

  private static func installFeeds() {
    guard feeds.isEmpty else { return }
    for topic in ["sidebar.nativeFeed", "topStrip.nativeFeed"] {
      feeds.append(SettingsJS.shared.observe(topic) { value in receive(topic, value) })
    }
  }

  private static func receive(_ topic: String, _ value: Any?) {
    guard let windows = (value as? [String: Any])?["windows"] as? [String: Any] else { return }
    for (id, value) in windows {
      guard let owner = owners[id], !owner.stopped, let feed = value as? [String: Any],
        (feed["generation"] as? NSNumber)?.uint64Value == owner.generation else { continue }
      if topic == "sidebar.nativeFeed" {
        owner.sidebarFeed = (feed["state"] as? String).flatMap(SidebarHostState.decode)
        owner.featureChrome = (feed["chrome"] as? String).flatMap(SidebarChromeState.decode)
        owner.held = feed["held"] as? Bool ?? false
      } else if topic == "topStrip.nativeFeed", let json = feed["state"] as? String {
        owner.stripFeed = StripHostState.decode(json)
        owner.stripOver = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["dropOver"] as? Bool ?? false
      }
      owner.feedRevision += 1
      owner.refresh()
    }
  }
}

@MainActor
private final class NativeLayoutStripDropView: NSView, DevDropDestination, NSSpringLoadingDestination {
  var accepts: () -> Bool = { false }
  var incoming: (CGPoint?) -> String?? = { _ in nil }
  var clearIncoming: () -> Void = {}
  var onDrop: ([[String: String]], String?) -> Void = { _, _ in }
  var onActive: (Bool) -> Void = { _ in }
  var carryAdmitted: (NSDraggingInfo) -> Bool = { _ in false }
  var carryTarget: (CGPoint) -> DragCarryTarget? = { _ in nil }
  var onSpring: (DragCarryTarget) -> Void = { _ in }
  private var carrySpring = DragCarrySpring()
  private var count = 0
  private var stopped = false
  private var content: NSView?
  var active: Bool { count > 0 }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(content: NSView? = nil) {
    super.init(frame: .zero)
    if let content { hold(content) }
    registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])
  }

  required init?(coder: NSCoder) { fatalError() }

  func hold(_ view: NSView) {
    content?.removeFromSuperview()
    content = view
    addSubview(view)
    view.frame = bounds
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    content?.frame = bounds
  }

  override func layout() {
    super.layout()
    content?.frame = bounds
  }

  override func mouseDown(with event: NSEvent) {
    guard !stopped, let window else { return }
    if event.clickCount == 2 { WindowTitlebar.doubleClick(window, event.modifierFlags) } else { window.performDrag(with: event) }
  }

  private func admitted(_ sender: NSDraggingInfo) -> Bool {
    !stopped && window != nil && !isHiddenOrHasHiddenAncestor && TabDragSession.current == nil && accepts()
      && bounds.contains(convert(sender.draggingLocation, from: nil))
  }

  private func point(_ sender: NSDraggingInfo) -> CGPoint {
    CGPoint(x: sender.draggingLocation.x, y: (window?.contentView?.bounds.height ?? 0) - sender.draggingLocation.y)
  }

  private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
    let mask = sender.draggingSourceOperationMask
    if mask.contains(.copy) { return .copy }
    if mask.contains(.generic) { return .generic }
    return mask.contains(.link) ? .link : []
  }

  private func springTarget(_ sender: NSDraggingInfo) -> DragCarryTarget? {
    guard admitted(sender), carryAdmitted(sender), DragCarrySpring.accepts(sender.draggingPasteboard) else { return nil }
    return carryTarget(sender.draggingLocation)
  }

  func springLoadingEntered(_ sender: NSDraggingInfo) -> NSSpringLoadingOptions { springLoadingUpdated(sender) }

  func springLoadingUpdated(_ sender: NSDraggingInfo) -> NSSpringLoadingOptions {
    let target = springTarget(sender)
    if carrySpring.update(target, sequence: sender.draggingSequenceNumber) { sender.resetSpringLoading() }
    return target == nil ? [] : .enabled
  }

  func springLoadingActivated(_ activated: Bool, draggingInfo sender: NSDraggingInfo) {
    guard activated, let target = carrySpring.activate(springTarget(sender), sequence: sender.draggingSequenceNumber) else { return }
    onSpring(target)
  }

  func springLoadingHighlightChanged(_ sender: NSDraggingInfo) {}

  func springLoadingExited(_ sender: NSDraggingInfo) { carrySpring.cancel() }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard admitted(sender) else { return [] }
    count = DroppedLinks.count(sender.draggingPasteboard)
    guard active else { return [] }
    onActive(true)
    _ = incoming(point(sender))
    return operation(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard admitted(sender) else {
      leave()
      return []
    }
    guard active else { return [] }
    _ = incoming(point(sender))
    return operation(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { leave() }
  override func draggingEnded(_ sender: NSDraggingInfo) { leave() }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { admitted(sender) && active }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard admitted(sender), active else { return false }
    let items = DroppedLinks.items(sender.draggingPasteboard)
    guard !items.isEmpty else { leave(); return false }
    let placement: String?
    if case .some(let beforeId) = incoming(point(sender)) {
      placement = NativeTopStrip.json(["pinned": false, "beforeId": beforeId.map { $0 as Any } ?? NSNull()])
    } else {
      placement = nil
    }
    leave()
    onDrop(items, placement)
    return true
  }

  private func leave() {
    carrySpring.cancel()
    let was = active
    count = 0
    clearIncoming()
    if was { onActive(false) }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    unregisterDraggedTypes()
    leave()
    accepts = { false }
    incoming = { _ in nil }
    clearIncoming = {}
    onDrop = { _, _ in }
    onActive = { _ in }
    carryAdmitted = { _ in false }
    carryTarget = { _ in nil }
    onSpring = { _ in }
  }
}

@MainActor
private final class NativeLayoutStripRow: NSView {
  let strip: TopStripView
  let controls = StripControlsView()
  var leadingInset: CGFloat = ShellMetrics.topStripLeadingReservation {
    didSet {
      controls.leadingInset = leadingInset
      needsLayout = true
    }
  }
  var onPageWidth: (CGFloat) -> Void = { _ in }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(strip: TopStripView) {
    self.strip = strip
    super.init(frame: .zero)
    addSubview(strip)
    addSubview(controls)
    controls.leadingInset = leadingInset
    controls.captionAligned = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    controls.frame = CGRect(x: 0, y: ShellMetrics.topStripLightsCenter.y - StripControlsLayout.height / 2, width: max(0, bounds.width - 8), height: 34.5)
    let left = leadingInset + controls.profileSlotWidth
    let right = StripControlsLayout.trailingReservation
    let width = max(0, bounds.width - left - right)
    strip.frame = CGRect(x: left - StripMetrics.flare, y: 0, width: max(0, bounds.width - left + StripMetrics.flare - max(right - StripMetrics.flare, StripControlsLayout.downloadsBox + 8)), height: bounds.height)
    onPageWidth(width)
  }

  override func mouseDown(with event: NSEvent) {
    guard let window, controls.isHidden || controls.hitTest(convert(event.locationInWindow, from: nil)) == nil else { return }
    if event.clickCount == 2 { WindowTitlebar.doubleClick(window, event.modifierFlags) } else { window.performDrag(with: event) }
  }
}

@MainActor
struct NativeLayoutAppearance {
  let dark: Bool
  let tokens: [String: String]
  let border: [String]
  let glow: SidebarGlow
  let nameColor: String
  let panel: StripPeekLook

  init(state: BrowserState, profileId: String, incognito: Bool, strip: Bool = false) {
    let profile = state.profiles[profileId]
    let swatches = ["plum": "#C07A98", "blue": "#4691C3", "purple": "#7873AF", "pink": "#D37B8B", "red": "#C1575C", "orange": "#D87249", "yellow": "#E3AC38", "green": "#3EB489", "neutral": "#8E8E93"]
    let color = profile?.color ?? "plum"
    let swatch = swatches[color] ?? swatches["plum"]!
    let custom = profile?.theme.flatMap { try? JSONDecoder().decode(ProfileThemeValue.self, from: Data($0.text().utf8)) }
    let shown = custom.map { ThemeMath.shown($0, appDark: state.ui.appDark, source: state.settings.bool("spacesFollowAppearance") ? .app : .own) }
    dark = incognito || (shown?.dark ?? state.ui.appDark)
    let accent = shown.map { ThemeMath.accent($0.look) } ?? (color == "plum" ? "#DD899B" : swatch)
    let base = ThemeMath.hexColor(swatch)
    let (h, _, _) = ThemeMath.rgbToHsl(base.r, base.g, base.b)
    let (r, g, b) = ThemeMath.hslToRgb(h, color == "neutral" ? 0 : 0.36, 0.527)
    let tint = incognito ? "#3A3A3C" : shown.map { ThemeMath.accent($0.look) } ?? (color == "plum" ? "#B25B6B" : ThemeMath.colorHex(.init(r: r, g: g, b: b)))
    let fill: String
    if let shown {
      fill = ThemeMath.opaqueTint(shown.look, dark: dark)
    } else {
      let over = ThemeMath.hexColor(tint)
      let a = (color == "neutral" || incognito ? 0.12 : 0.36) * (dark ? 0.5 : 0.75)
      let under = dark ? [24.42, 19.86, 19.08] : [251.0, 250.2, 250.0]
      fill = ThemeMath.colorHex(.init(r: a * over.r + (1 - a) * under[0] / 255,
        g: a * over.g + (1 - a) * under[1] / 255, b: a * over.b + (1 - a) * under[2] / 255))
    }
    var tokens = [
      "textTab": dark ? "#FFFFFFC7" : "#000000AD", "tabSelectedText": dark ? "#FFFFFF" : "#000000",
      "tabHover": dark ? "#FFFFFF29" : "#FFFFFF8C", "tabPressed": dark ? "#FFFFFF4F" : "#FFFFFFB3",
      "tabSelected": dark ? "#12121280" : "#FFFFFFB3", "rowHover": dark ? "#FFFFFF12" : "#0F182C0D",
      "divider": dark ? "#FFFFFF14" : "#00000014", "textPrimary": dark ? "#FFFFFF" : "#000000",
      "textSecondary": dark ? "#FFFFFF80" : "#00000080", "textTertiary": dark ? "#FFFFFF59" : "#00000059",
      "icon": dark ? "#F7F5FFC6" : "#000000C6", "pinnedResting": dark ? "#FFFFFF1A" : "#0000000D",
      "pinnedRestingStroke": dark ? "#FFFFFF24" : "#0000002E", "pinnedSelectedFill": dark ? "#FFFFFF40" : "#FFFFFFB3",
      "pinnedSelectedRim": dark ? "#000000D9" : "#0000001F", "pinnedSelectedOutline": dark ? "#FFFFFF33" : "#FFFFFFFA",
      "accent": dark ? "#4A77D4" : "#6395FC", "toolbarHover": dark ? "#FFFFFF1A" : "#0000000F",
      "toolbarPressed": dark ? "#FFFFFF2E" : "#0000001A", "card": dark ? "#12121280" : "#FFFFFFB3",
      "panel": dark ? "#2A2A2A" : "#FFFFFF", "panelBorder": dark ? "#FFFFFF1A" : "#0000001A",
      "windowTint": fill, "backdropTint": tint,
    ]
    if let shown, !state.settings.bool("lightColorsKeepWhiteText") {
      let ink = ThemeMath.textInk(shown.look, dark: dark, strip: strip)
      tokens["tabSelectedText"] = ink.selectedDark ? "#000000" : "#FFFFFF"
      if ink.dark == dark {
        tokens["ink"] = dark ? "dark" : "light"
        tokens["textPrimary"] = dark ? "#000000" : "#FFFFFF"
        tokens["textTab"] = dark ? "#000000AD" : "#FFFFFFC7"
        tokens["textSecondary"] = dark ? "#00000080" : "#FFFFFF80"
        tokens["textTertiary"] = dark ? "#00000059" : "#FFFFFF59"
        tokens["icon"] = dark ? "#000000C6" : "#F7F5FFC6"
      }
    }
    self.tokens = tokens
    border = dark ? ["#FFFFFF26", "#FFFFFF26"] : ["#FFFFFFFA", "#0000000F"]
    var host = SidebarHostState(profileId: profileId, dark: dark)
    host.glow.color = dark ? "#FFFFFF26" : "#0000001F"
    host.glow.opacity = 1
    host.glow.radius = dark ? 15 : 12.5
    glow = host.glow
    let lightInk = tokens["ink"].map { $0 == "light" } ?? dark
    let name = ThemeMath.hexColor(custom.map { ThemeMath.accent(ThemeMath.resolve($0, dark: lightInk)) } ?? accent)
    let mix = lightInk ? 0.6 : 0.4
    let target = lightInk ? 1.0 : 0.0
    nameColor = incognito ? "#FFFFFF" : ThemeMath.colorHex(.init(r: name.r + (target - name.r) * mix,
      g: name.g + (target - name.g) * mix, b: name.b + (target - name.b) * mix))
    panel = StripPeekLook(fill: fill, border: dark ? "#FFFFFF1A" : "#0000001A", shadowOpacity: dark ? 0.5 : 0.18)
  }
}

@MainActor
private enum NativeDragCarry {
  private struct Origin {
    let windowId: String
    let profileId: String
    let incognito: Bool
    let activeTabIds: JSMap<String>
    let ownership: Int
    weak var window: NSWindow?
  }

  private static var observers: [NSObjectProtocol] = []
  private static var origins: [Int: Origin] = [:]
  private static var inputMonitor: Any?
  private static var swipe: CarrySwipe?

  static func register() {
    guard observers.isEmpty else { return }
    observers = ["SolaraDragCarryBegan", "SolaraDragCarryEnded"].map { name in
      NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { note in
        guard let window = note.object as? NSWindow, let sequence = note.userInfo?["sequence"] as? Int else { return }
        let operation = note.userInfo?["operation"] as? UInt
        MainActor.assumeIsolated { receive(name: name, nativeWindow: window, sequence: sequence, operation: operation) }
      }
    }
    observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("SolaraDragCarryRouteInput"), object: nil, queue: nil) { note in
      guard Thread.isMainThread, let event = note.object as? NSEvent, let sequence = note.userInfo?["sequence"] as? Int,
        let reply = note.userInfo?["reply"] as? NSMutableDictionary else { return }
      nonisolated(unsafe) let synchronousEvent = event
      nonisolated(unsafe) let synchronousReply = reply
      MainActor.assumeIsolated { synchronousReply["handled"] = input(synchronousEvent, sequence: sequence) }
    })
  }

  private static func stopInput() {
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    inputMonitor = nil
    swipe?.stop()
    swipe = nil
  }

  private static func receive(name: String, nativeWindow: NSWindow, sequence: Int, operation: UInt?) {
    if name == "SolaraDragCarryBegan" {
      stopInput()
      origins.removeAll()
      guard let store = NativeStoreHandle.store,
        let windowId = store.state.windows.keys.first(where: { NativeWindowShell.host($0)?.shell.window === nativeWindow }),
        let window = store.state.windows[windowId] else { return }
      origins[sequence] = Origin(windowId: windowId, profileId: window.profileId, incognito: window.incognito,
        activeTabIds: window.activeTabIds, ownership: NativeStoreHandle.ownershipGeneration, window: nativeWindow)
      swipe = CarrySwipe(windowId: windowId, window: nativeWindow)
      inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
        let handled = MainActor.assumeIsolated {
          let handled = input(event, sequence: sequence)
          #if DEBUG
          NotificationCenter.default.post(name: Notification.Name("SolaraDragCarryInput"), object: event, userInfo: ["handled": handled])
          #endif
          return handled
        }
        return handled ? nil : event
      }
      return
    }
    guard let origin = origins.removeValue(forKey: sequence), origin.window === nativeWindow else { return }
    stopInput()
    guard operation == 0 else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { restore(origin) }
    }
  }

  private static func restore(_ origin: Origin) {
    guard origins.isEmpty, let nativeWindow = origin.window, let store = NativeStoreHandle.store,
      origin.ownership == NativeStoreHandle.ownershipGeneration,
      NativeWindowShell.host(origin.windowId)?.shell.window === nativeWindow,
      let current = store.state.windows[origin.windowId], current.incognito == origin.incognito,
      origin.incognito ? current.profileId == origin.profileId : store.state.profiles[origin.profileId] != nil else { return }
    for (profileId, tabId) in origin.activeTabIds {
      guard let tab = store.state.tabs[tabId], tab.windowId == origin.windowId, tab.profileId == profileId,
        store.state.activeTabId(origin.windowId, profileId) != tabId else { continue }
      _ = try? store.dispatch(Command("activate", [.string(tabId)]), origin: .native)
    }
    if store.state.windows[origin.windowId]?.profileId != origin.profileId {
      _ = try? store.dispatch(Command("switchProfile", [.string(origin.windowId), .string(origin.profileId)]), origin: .native)
    }
    FrameUpdates.flush()
  }

  static func admits(sequence: Int, windowId: String) -> Bool {
    guard let origin = origins[sequence], origin.windowId == windowId, let window = origin.window,
      origin.ownership == NativeStoreHandle.ownershipGeneration else { return false }
    return NativeWindowShell.host(windowId)?.shell.window === window
  }

  private static func input(_ event: NSEvent, sequence: Int) -> Bool {
    guard let origin = origins[sequence], let window = origin.window,
      admits(sequence: sequence, windowId: origin.windowId),
      event.windowNumber == 0 || event.windowNumber == window.windowNumber,
      let store = NativeStoreHandle.store else { return false }
    if event.type == .scrollWheel || event.type == .swipe {
      guard !origin.incognito else { return false }
      return swipe?.input(event) ?? false
    }
    let flags = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])
    var key = event.charactersIgnoringModifiers ?? ""
    if flags.contains(.shift), key == "{" || key == "}" { key = key == "{" ? "[" : "]" }
    let glyphs: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "🌐")]
    let shortcut = glyphs.filter { flags.contains($0.0) }.map(\.1).joined() + key.uppercased()
    let hints = CommandShortcutSnapshot().hints(state: store.state)
    let commands = (1...8).map { ("selectTab", String($0), "selectTab:\($0)") }
      + [("selectLastTab", "", "selectLastTab"), ("nextTab", "", "nextTab"), ("previousTab", "", "previousTab")]
    if let match = commands.first(where: { hints[JSKey($0.2)] == shortcut }) {
      guard event.type == .keyDown else { return true }
      guard let plan = WorkspaceMenuCommand.plan(match.0, arg: match.1, windowId: origin.windowId, state: store.state),
        !plan.commands.isEmpty else { return true }
      _ = try? store.dispatch(plan.commands, origin: .native)
      FrameUpdates.flush()
      return true
    }
    if !origin.incognito, let profile = store.state.profileOrder.first(where: { hints[JSKey("switchProfile:\($0)")] == shortcut }) {
      if event.type == .keyDown { _ = activate(.profile(profile), windowId: origin.windowId) }
      return true
    }
    return false
  }

  @MainActor
  private final class CarrySwipe: @preconcurrency ACPagerSurface {
    let windowId: String
    weak var window: NSWindow?
    private var dx = 0.0
    private var dy = 0.0
    private var tracking = false
    private var measuredWidth: Double?
    private var pager: ACPager?

    init(windowId: String, window: NSWindow) {
      self.windowId = windowId
      self.window = window
      pager = ACPager.existing(windowId)
      pager?.attach(self)
    }

    var pageWidth: Double { measuredWidth ?? Double(window?.contentView?.bounds.width ?? 0) }
    var surfaceWindow: NSWindow? { window }
    func pagerMoved(_ position: Double) {}
    func pagerChanged(_ event: [String: Any]) {}

    func stop() {
      if tracking { pager?.input(from: self, phase: "cancelled", distance: abs(dx), direction: dx > 0 ? 1 : -1, timestamp: ProcessInfo.processInfo.systemUptime) }
      tracking = false
      pager?.detach(self)
      pager = nil
    }

    func input(_ event: NSEvent) -> Bool {
      guard let pager else { return false }
      if event.type == .swipe {
        guard abs(event.deltaX) >= 0.5, let state = NativeStoreHandle.store?.state else { return false }
        return pager.step(event.deltaX > 0 ? -1 : 1, wrap: false, order: state.profileOrder.joined(separator: "\n"))
      }
      guard event.hasPreciseScrollingDeltas, event.phase != [] else { return false }
      if event.phase.contains(.mayBegin) { return true }
      if event.phase.contains(.began) {
        dx = 0
        dy = 0
        tracking = false
        if let host = NativeProfilePager.hosts[windowId] {
          let targets = [host.peekTarget, host.stripTarget, host.sidebarTarget].filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.pageWidth > 0
          }
          let target = targets.first { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? targets.first
          measuredWidth = target?.pageWidth
        }
      }
      dx += event.scrollingDeltaX
      dy += event.scrollingDeltaY
      let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
      if !tracking {
        guard !ended, dx != 0, abs(dx) >= abs(dy) else { return event.phase.contains(.began) }
        tracking = true
        pager.input(from: self, phase: "began", distance: abs(dx), direction: dx > 0 ? 1 : -1, timestamp: event.timestamp)
      } else {
        pager.input(from: self, phase: ended ? (event.phase.contains(.cancelled) ? "cancelled" : "ended") : "changed",
          distance: abs(dx), direction: dx > 0 ? 1 : -1, timestamp: event.timestamp)
      }
      if ended { tracking = false }
      return true
    }
  }

  static func activate(_ target: DragCarryTarget, windowId: String) -> Bool {
    guard origins.keys.contains(where: { admits(sequence: $0, windowId: windowId) }),
      let store = NativeStoreHandle.store, let window = store.state.windows[windowId] else { return false }
    let command: Command
    switch target {
    case .tab(let id):
      guard let tab = store.state.tabs[id], tab.windowId == windowId, tab.profileId == window.profileId,
        window.tabIds.contains(id), store.state.activeTabId(windowId, window.profileId) != id else { return false }
      command = Command("activate", [.string(id)])
    case .profile(let id):
      guard !window.incognito, window.profileId != id, store.state.profileOrder.contains(id), store.state.profiles[id] != nil else { return false }
      command = Command("switchProfile", [.string(windowId), .string(id)])
    }
    guard (try? store.dispatch(command, origin: .native)) != nil else { return false }
    FrameUpdates.flush()
    return true
  }
}

@MainActor
enum NativeGroupActions {
  #if DEBUG
  private(set) static var handled = 0
  #endif

  static func toggle(_ groupId: String, collapsed: (TabGroup) -> Bool) -> Bool {
    guard let store = SettingsWrites.directStore else { return false }
    count()
    guard let group = store.state.groups[groupId] else { return true }
    dispatch(store, GroupActions.collapse(groupId, collapsed(group)))
    return true
  }

  static func tuck(_ groupId: String, windowId: String) -> Bool {
    guard let store = SettingsWrites.directStore else { return false }
    count()
    if let target = GroupActions.tuckTarget(store.state, windowId: windowId, groupId: groupId) {
      dispatch(store, Command("activate", [.string(target)]))
    }
    return true
  }

  static func close(_ groupId: String) -> Bool {
    guard let store = SettingsWrites.directStore else { return false }
    switch GroupActions.close(store.state, groupId: groupId) {
    case .nothing: count()
    case .unload(let ids):
      count()
      dispatch(store, Command("closeTabs", [JSONValue(ids)]))
    case .close(nil):
      count()
      dispatch(store, Command("closeGroup", [.string(groupId)]))
    case .close(let confirm?):
      let alert = NativeWorkspaceCommands.confirmAlert(confirm.title, message: confirm.message, button: confirm.confirmTitle, suppression: confirm.suppression)
      NativeWorkspaceCommands.askGuarded(alert, windowId: confirm.windowId, setting: "warnBeforeClosingTabGroup", store: store) { [weak owner = store] in
        guard let store = SettingsWrites.directStore, store === owner, store.state.groups[groupId] != nil else {
          return NSLog("[groups] %@: gone or stood down while the close warning was open", groupId)
        }
        dispatch(store, Command("closeGroup", [.string(groupId)]))
      }
      #if DEBUG
      if alert.window.sheetParent != nil || alert.window.isVisible { count() }
      #endif
    }
    return true
  }

  private static func count() {
    #if DEBUG
    handled += 1
    #endif
  }

  private static func dispatch(_ store: Store, _ command: Command) {
    do {
      try store.dispatch(command, origin: .native)
    } catch {
      NSLog("[groups] %@ refused: %@", command.name, String(describing: error))
    }
    FrameUpdates.flush()
  }
}

@MainActor
enum NativeGroupMenu {
  #if DEBUG
  private(set) static var handled = 0
  #endif

  static func open(_ groupId: String, windowId: String, js: @escaping @MainActor (_ groupId: String, _ choice: String) -> Void) -> Bool {
    guard let store = SettingsWrites.directStore else { return false }
    let shortcut = CommandShortcutSnapshot().hint("newTabInGroup", state: store.state)
    let items = GroupMenu.items(store.state, groupId: groupId, newTabShortcut: shortcut)
    guard !items.isEmpty else { return true }
    #if DEBUG
    handled += 1
    #endif
    ShellMenus.choose(items.map(\.dictionary)) { [weak owner = store] picked in
      guard let picked, let choice = GroupMenuChoice(picked) else { return }
      guard let store = SettingsWrites.directStore, store === owner, store.state.groups[groupId] != nil else {
        return NSLog("[groups] %@: gone or stood down while its menu was open", groupId)
      }
      run(choice, raw: picked, groupId: groupId, windowId: windowId, store: store, js: js)
    }
    return true
  }

  private static func run(
    _ choice: GroupMenuChoice, raw: String, groupId: String, windowId: String, store: Store,
    js: @escaping @MainActor (String, String) -> Void
  ) {
    switch choice {
    case .rename:
      if !rename(groupId, windowId: windowId) { js(groupId, "rename") }
    case .icon, .bookmarkBar:
      js(groupId, raw)
    case .close:
      _ = NativeGroupActions.close(groupId)
    case .copy(let markdown):
      guard let text = GroupMenu.copiedText(store.state, ids: store.state.groups[groupId]?.tabIds ?? [], markdown: markdown) else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case .newTab:
      if GroupMenu.newTabOpensBar(store.state, windowId: windowId) { return js(groupId, raw) }
      let tab = dispatch(store, Command("newTabInGroup", [.string(groupId)]))
      if let tab, !tab.isEmpty { _ = dispatch(store, Command("activate", [.string(tab)])) }
    case .nest:
      let child = dispatch(store, Command("newNestedGroup", [.string(groupId)])) ?? ""
      if let tab = store.state.groups[child]?.tabIds.first { _ = dispatch(store, Command("activate", [.string(tab)])) }
      if !child.isEmpty, !rename(child, windowId: windowId) { js(child, "rename") }
    case .color, .pin, .duplicate, .collapse, .ungroup, .delete:
      if let command = GroupMenu.command(choice, groupId: groupId, state: store.state) { _ = dispatch(store, command) }
    }
  }

  private static func rename(_ groupId: String, windowId: String) -> Bool {
    NativeWorkspaceRename.begin(windowId: windowId, kind: .group, id: groupId)
  }

  @discardableResult
  private static func dispatch(_ store: Store, _ command: Command) -> String? {
    defer { FrameUpdates.flush() }
    do {
      return try store.dispatch(command, origin: .native).result?.string
    } catch {
      NSLog("[groups] %@ refused: %@", command.name, String(describing: error))
      return nil
    }
  }
}
