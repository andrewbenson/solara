import AppKit
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
    guard enabled, observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    shellAppeared = NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: nil, queue: .main) { note in
      guard note.object is WindowShellView else { return }
      MainActor.assumeIsolated { receive(SettingsJS.shared.latestValue(topic)) }
    }
    receive(SettingsJS.shared.latestValue(topic))
  }

  static func column(_ windowId: String) -> SidebarShellColumn? { columns[windowId] }

  static func describe(_ windowId: String) -> String {
    guard let column = columns[windowId], let data = try? JSONSerialization.data(withJSONObject: column.describe()) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, column) in columns where windows[windowId] == nil { remove(windowId, column) }
    for (windowId, given) in windows {
      guard let given = given as? [String: Any], let state = given["state"] as? String, let column = columns[windowId] ?? make(windowId) else { continue }
      let number = { (key: String) in CGFloat((given[key] as? NSNumber)?.doubleValue ?? 0) }
      column.apply(
        state: state,
        layout: SidebarShellColumn.Layout(top: number("top"), header: number("header"), bottom: number("bottom"), clip: (given["clip"] as? Bool) ?? false),
        chrome: (given["chrome"] as? String).flatMap(SidebarChromeState.decode))
    }
  }

  private static func make(_ windowId: String) -> SidebarShellColumn? {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return nil }
    let host = SidebarHost(windowId: windowId)
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

  static func dropped(_ windowId: String, items: [[String: String]], placement: String?) {
    send(windowId, "drop", ["items": items, "placement": placement ?? NSNull()])
  }

  static func send(_ windowId: String, _ event: String, _ extra: [String: Any] = [:]) {
    let payload = SidebarPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, event, payload.value)
    }
  }
}

@MainActor
final class SidebarShellColumn: NSView, DevDropDestination {
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
  private var given = Layout()
  private var dropCount = 0

  override var isFlipped: Bool { true }

  init(windowId: String, host: SidebarHost) {
    self.windowId = windowId
    self.host = host
    super.init(frame: .zero)
    list.wantsLayer = true
    list.autoresizingMask = []
    host.view.autoresizingMask = [.width, .height]
    list.addSubview(host.view)
    addSubview(list)
    chrome.autoresizingMask = [.width, .height]
    chrome.isHidden = true
    chrome.onAction = { [weak self] action in self?.chromeAction(action) }
    chrome.onBlankMouseDown = { event in Self.blankMouseDown(event) }
    addSubview(chrome)
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.chrome.setPagerPosition(position) }
    }
    registerForDraggedTypes([.fileURL, .URL, .string])
  }

  required init?(coder: NSCoder) { fatalError() }

  func stop() {
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
    syncAddress(false)
    host.stop()
  }

  func apply(state: String, layout: Layout, chrome look: SidebarChromeState?) {
    let previousFooter = footerInset
    let previousTop = topInset
    let previousLift = listLift
    chrome.isHidden = look == nil
    if var look {
      look.iconsOnly = SidebarRail.contains(width: Double(bounds.width))
      chrome.update(look)
    }
    syncAddress(chrome.state?.addressBar == true && chrome.state?.rail != true)
    if layout != given || previousFooter != footerInset || previousTop != topInset || previousLift != listLift {
      given = layout
      placeList()
    }
    host.apply(state)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if var state = chrome.state {
      let rail = SidebarRail.contains(width: Double(newSize.width))
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

  private var topInset: CGFloat { chrome.state?.rail == true && !chrome.isHidden ? chrome.headerHeight : given.top }

  private var footerInset: CGFloat { chrome.state?.rail == true && !chrome.isHidden ? chrome.footerHeight : given.bottom }

  private var listLift: CGFloat {
    guard let state = chrome.state, state.rail, !chrome.isHidden else { return 0 }
    return SidebarRail.listLift(addressBar: state.addressBar)
  }

  private func placeList() {
    let lift = listLift
    list.frame = CGRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset - footerInset))
    list.layer?.masksToBounds = given.clip || lift > 0
    host.view.frame = CGRect(x: 0, y: -lift, width: list.bounds.width, height: list.bounds.height + lift)
    chrome.frame = bounds
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    if chrome.isHidden, local.y < given.header || local.y >= bounds.height - given.bottom || local.x >= bounds.width - SidebarChromeMetrics.resizeStrip {
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
      "frame": rect(inWindow), "list": rect(list), "header": given.header, "bottom": footerInset, "clip": given.clip,
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
    case .toggleDownloads: NativeSidebarShell.send(windowId, "toggleDownloads")
    case .switchProfile(let id):
      _ = try? NativeStoreHandle.store?.dispatch(Command("switchProfile", [.string(windowId), .string(id)]), origin: .native)
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
    guard dropCount > 0 else { return }
    dropCount = 0
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "leave", at: .zero, count: 0)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropCount > 0 }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard dropCount > 0 else { return false }
    dropCount = 0
    let items = DroppedLinks.items(sender.draggingPasteboard)
    let placement = NativeSidebarDrag.external(windowId: windowId, phase: "drop", at: windowPoint(sender), count: items.count)
    NativeSidebarShell.dropped(windowId, items: items, placement: placement)
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
