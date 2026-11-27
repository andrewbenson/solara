import AppKit
import Foundation
import SolaraUI
import SolaraModel
import SolaraShell
import SolaraStore

@MainActor
enum NativePaneOverlays {
  static let topic = "pane.overlays"
  private static var started = false
  private static var hosts: [String: PaneOverlayHost] = [:]
  private static var inline: [UUID: InlineAnchor] = [:]

  private struct InlineAnchor {
    let windowId: String
    let tabId: String
    weak var view: PanePopoverWrap?
  }

  static func registerInline() {
    HostedViews.register(PanePrompts.kind) { windowId in
      let view = PanePopoverWrap()
      let id = UUID()
      func changed() { DispatchQueue.main.async { refresh(windowId) } }
      view.onReturn = changed
      view.onLeave = changed
      view.onResize = changed
      return HostedContent(view: view, onUnmount: {
        inline[id] = nil
        changed()
      }, takesFocus: false) { [weak view] tabId in
        inline[id] = InlineAnchor(windowId: windowId, tabId: tabId, view: view)
        changed()
      }
    }
  }

  static func promptSlot(_ windowId: String, _ tabId: String) -> NSView? {
    guard let window = ShellDrag.window(windowId) else { return nil }
    if NativeStoreHandle.store?.state.peeks[windowId]?.tabId == tabId,
      let peek = TabSlots.shared.container(for: .peek(windowId)), peek.window === window,
      !peek.isHiddenOrHasHiddenAncestor { return peek }
    if let pane = PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .native),
      pane.window === window, !pane.isHiddenOrHasHiddenAncestor { return pane }
    return inline.values.lazy.filter { $0.windowId == windowId && $0.tabId == tabId }
      .compactMap(\.view).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
  }

  static func start() {
    HostedSadTab.register()
    HostedSelectionBar.register()
    HostedSwipeCapsule.register()
    HostedFrozenPage.register()
    PanePrompts.start()
    guard !started else { return }
    started = true
    guard NativeWindowShell.enabled else { return }
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    _ = SettingsJS.shared.observe("pane.navigation") { value in
      navigation = (value as? [String: Any])?["windows"] as? [String: [String: Any]] ?? [:]
      navigationRevision &+= 1
      for host in hosts.values { host.relayout() }
    }
    _ = SettingsJS.shared.observe("pane.navigationMenu") { value in
      guard let value = value as? [String: Any], let windowId = value["windowId"] as? String,
        let tabId = value["tabId"] as? String,
        (value["generation"] as? NSNumber)?.uint64Value == NativeWindowShell.nativeLayoutGeneration(windowId),
        NativeWindowShell.nativeLayoutActive(windowId) else { return }
      hosts[windowId]?.openNavigationMenu(tabId, direction: (value["direction"] as? Int ?? -1) < 0 ? .back : .forward)
    }
    TabPoolHost.shared.stateObservers.append { for host in hosts.values { host.relayout() } }
    TabPoolHost.shared.pageEventObservers.append { _, _, _ in for host in hosts.values { host.relayout() } }
    NotificationCenter.default.addObserver(forName: TabSlots.changed, object: TabSlots.shared, queue: .main) { note in
      guard let windowId = note.userInfo?["windowId"] as? String else { return }
      MainActor.assumeIsolated { hosts[windowId]?.relayout() }
    }
    NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: nil, queue: .main) { note in
      guard let windowId = note.userInfo?["windowId"] as? String else { return }
      MainActor.assumeIsolated { hosts[windowId]?.relayout() }
    }
    NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: nil, queue: .main) { note in
      guard let windowId = (note.object as? WindowShellView)?.windowId else { return }
      MainActor.assumeIsolated { refresh(windowId) }
    }
    apply(SettingsJS.shared.latestValue(topic))
  }

  static var navigation: [String: [String: Any]] = [:]
  private(set) static var navigationRevision: UInt64 = 0

  static func host(_ windowId: String) -> PaneOverlayHost? { hosts[windowId] }

  static func adopt(_ windowId: String) -> PaneOverlayHost {
    let host = PaneOverlayHost(windowId: windowId)
    hosts[windowId] = host
    return host
  }

  static func end(_ windowId: String, ifHost host: PaneOverlayHost) {
    if hosts[windowId] === host { hosts[windowId] = nil }
    host.stop()
  }

  static func refresh(_ windowId: String) {
    guard started else { return }
    if let host = hosts[windowId] { return host.refresh() }
    guard PanePrompts.draws(windowId),
      NativeWindowShell.host(windowId) != nil || inline.values.contains(where: { $0.windowId == windowId }) else { return }
    let host = PaneOverlayHost(windowId: windowId)
    hosts[windowId] = host
    host.refresh()
  }

  static func refreshShowing(_ tabId: String, lastWindow: String?) {
    var windows = Set(hosts.compactMap { $0.value.shows(tabId) ? $0.key : nil })
    if let lastWindow { windows.insert(lastWindow) }
    for windowId in windows { refresh(windowId) }
  }

  private static func apply(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil {
      host.apply([:])
      if !PanePrompts.draws(windowId), !NativeWindowShell.nativeLayoutActive(windowId) { hosts[windowId] = nil }
    }
    for (windowId, tabs) in windows {
      guard let tabs = tabs as? [String: Any] else { continue }
      let host = hosts[windowId] ?? PaneOverlayHost(windowId: windowId)
      hosts[windowId] = host
      host.apply(tabs)
    }
  }

  static func swipe(_ windowId: String, _ tabId: String, _ json: String) {
    guard let data = json.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    guard !NativeWindowShell.nativeLayoutActive(windowId) else { return }
    if HostedSwipeCapsule.send(windowId, tabId, message) { return }
    guard NativeWindowShell.enabled else { return }
    guard let host = hosts[windowId] ?? (NativeWindowShell.host(windowId) != nil ? PaneOverlayHost(windowId: windowId) : nil) else { return }
    hosts[windowId] = host
    host.swipe(tabId, message)
  }

  #if DEBUG
    static func snapshot(_ windowId: String) -> [String: Any]? {
      var value = hosts[windowId]?.describe()
      let hosted = [
        HostedSadTab.describe(windowId),
        HostedSelectionBar.describe(windowId),
        HostedSwipeCapsule.describe(windowId),
        HostedFrozenPage.describe(windowId),
        NativeSplitChrome.frozenSnapshot(windowId),
      ].compactMap { $0 }
      for entry in hosted {
        var tabs = value?["tabs"] as? [String: [String: Any]] ?? [:]
        for (tabId, overlays) in entry["tabs"] as? [String: [String: Any]] ?? [:] {
          tabs[tabId, default: [:]].merge(overlays) { _, inline in inline }
        }
        if value == nil { value = ["top": false, "inCard": false] }
        value?["tabs"] = tabs
      }
      return value
    }

    static func describe(_ windowId: String) -> String {
      guard let value = snapshot(windowId) else { return "null" }
      let data = try? JSONSerialization.data(withJSONObject: value)
      return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
  #endif
}

@MainActor
final class PanePopoverWrap: NSView {
  var onLeave: (() -> Void)?
  var onReturn: (() -> Void)?
  var onResize: (() -> Void)?

  override func setFrameSize(_ size: NSSize) {
    let changed = frame.size != size
    super.setFrameSize(size)
    if changed { onResize?() }
  }

  override var isFlipped: Bool { true }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { onLeave?() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, !isHiddenOrHasHiddenAncestor { onReturn?() }
  }

  override func viewDidHide() {
    super.viewDidHide()
    onLeave?()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    if window != nil { onReturn?() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class PanePopover<Body: NSView> {
  let wrap = PanePopoverWrap()
  let popover: PopoverView
  let body: Body
  var mark: String?

  init(_ body: Body) {
    self.body = body
    popover = PopoverView(body: body)
    popover.autoresizingMask = [.width, .height]
    wrap.addSubview(popover)
  }

  func setHeight(_ h: CGFloat) { DispatchQueue.main.async { [weak self] in self?.popover.set(bodyHeight: h) } }

  func place(in container: NSView?) {
    PaneOverlayHost.place(wrap, in: container, bottom: false)
    popover.frame = wrap.bounds
  }

  #if DEBUG
    func describe(_ inWindow: (NSView, CGRect) -> [Double]) -> [String: Any] {
      var controls: [String: [Double]] = [:]
      func walk(_ view: NSView) {
        if view.accessibilityRole() == .button, let name = view.accessibilityLabel() { controls[name] = inWindow(view, view.bounds) }
        view.subviews.forEach(walk)
      }
      walk(body)
      return ["hidden": wrap.isHiddenOrHasHiddenAncestor, "frame": inWindow(wrap, wrap.bounds), "card": inWindow(popover, popover.cardFrame), "opacity": popover.presentedOpacity, "progress": popover.progress, "controls": controls]
    }
  #endif
}

@MainActor
final class PanePromptEntry {
  let key: String
  let receipt: String
  let tabId: String
  let kind: PanePromptKind
  let popover: PanePopover<PromptBodyView>
  var placement: PopoverPlacement?
  var dark = false
  private var input = PromptInputGuard()
  private var fitWidth: CGFloat = -1
  private weak var container: NSView?

  static func id(_ tabId: String, _ kind: PanePromptKind) -> String { tabId + "\u{1}" + kind.rawValue }

  init(key: String, receipt: String, tabId: String, kind: PanePromptKind, popover: PanePopover<PromptBodyView>) {
    self.key = key
    self.receipt = receipt
    self.tabId = tabId
    self.kind = kind
    self.popover = popover
    input.shown(at: ProcessInfo.processInfo.systemUptime)
  }

  func allowInput() -> Bool { input.allow(at: ProcessInfo.processInfo.systemUptime, activatedAt: PanePrompts.activatedAt) }

  func place(in container: NSView?) {
    if self.container !== container {
      self.container = container
      if container != nil { input.shown(at: ProcessInfo.processInfo.systemUptime) }
    }
    popover.place(in: container)
    refit()
  }

  private func refit() {
    let width = popover.wrap.bounds.width
    guard let leftWidth = kind.leftWidth, width != fitWidth, var placement, placement.left != nil else { return }
    fitWidth = width
    placement.left = PanePromptSpecs.promptLeft(urlLeft: PanePrompts.urlLeft(tabId) ?? 0, paneWidth: Double(width), width: leftWidth)
    self.placement = placement
    popover.popover.set(placement: placement, dark: dark)
  }
}

@MainActor
final class PaneChooserEntry {
  let id: Int
  let tabId: String
  let popover: PanePopover<DeviceChooserView>
  var placement: PopoverPlacement?
  var dark = false
  private var input = PromptInputGuard()
  private var fitWidth: CGFloat = -1

  init(id: Int, tabId: String, popover: PanePopover<DeviceChooserView>) {
    self.id = id
    self.tabId = tabId
    self.popover = popover
    input.shown(at: ProcessInfo.processInfo.systemUptime)
  }

  func allowInput() -> Bool { input.allow(at: ProcessInfo.processInfo.systemUptime, activatedAt: PanePrompts.activatedAt) }

  func refit() {
    let width = popover.wrap.bounds.width
    guard width != fitWidth, var placement else { return }
    fitWidth = width
    placement.left = PanePromptSpecs.promptLeft(urlLeft: PanePrompts.urlLeft(tabId) ?? 0, paneWidth: Double(width), width: PanePromptSpecs.deviceChooserWidth)
    self.placement = placement
    popover.popover.set(placement: placement, dark: dark)
  }
}

@MainActor
final class PaneOverlayHost {
  let windowId: String
  private var stopped = false
  private var sadTabs: [String: SadTabView] = [:]
  private var zooms: [String: PanePopover<ZoomPanelView>] = [:]
  private var histories: [String: PanePopover<HistoryPanelView>] = [:]
  private var selections: [String: SelectionBarView] = [:]
  private var cliPills: [String: CliControlPillView] = [:]
  private var shares: [String: (id: String, popover: PanePopover<SharePickerView>, focus: HostedMount?)] = [:]
  private var swipes: [String: (wrap: PanePopoverWrap, capsule: SwipeCapsuleView)] = [:]
  private var navigationSwipes: [String: NativeNavigationSwipe] = [:]
  private var fromJS: [String: Any] = [:]
  private var prompts: [String: PanePromptEntry] = [:]
  private var choosers: [String: PaneChooserEntry] = [:]
  private static let swipeFavicons: SidebarFavicons = {
    let made = SidebarFavicons()
    made.loader = { request in try await NativeSidebar.favicon(request) }
    return made
  }()

  init(windowId: String) {
    self.windowId = windowId
  }

  private func promptSlot(_ tabId: String) -> NSView? { NativePaneOverlays.promptSlot(windowId, tabId) }

  private func slot(_ tabId: String) -> NSView? { PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .native) }

  private func entry(_ value: Any?, kind: String, tabId: String) -> Data? {
    guard let object = (value as? [String: Any])?[kind] as? [String: Any] else { return nil }
    return try? JSONSerialization.data(withJSONObject: object)
  }

  func refresh() { apply(fromJS) }

  func shows(_ tabId: String) -> Bool {
    sadTabs[tabId] != nil || selections[tabId] != nil || cliPills[tabId] != nil || prompts.values.contains { $0.tabId == tabId } || choosers.values.contains { $0.tabId == tabId }
  }

  func apply(_ tabs: [String: Any]) {
    guard !stopped else { return }
    fromJS = tabs
    var sad = Set<String>()
    var zoomed = Set<String>()
    var listed = Set<String>()
    var selected = Set<String>()
    var piloted = Set<String>()
    var sharing = Set<String>()
    for (tabId, value) in tabs {
      if !PanePrompts.owns(tabId), let data = entry(value, kind: "sadTab", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = SadTabState.decode(json), state.mode != nil {
        sad.insert(tabId)
        (sadTabs[tabId] ?? makeSadTab(tabId)).update(state)
      }
      if NativeSelectionTools.zoomShown(tabId), let data = entry(value, kind: "zoom", tabId: tabId), var state = try? JSONDecoder().decode(ZoomPanelState.self, from: data), let placement = PanelPopover.placement(data) {
        zoomed.insert(tabId)
        let zoom = zooms[tabId] ?? makeZoom(tabId)
        state.zoom = NativeStoreHandle.store?.state.tabs[tabId]?.zoom ?? 1
        let identity = PageIssuer.shared?.binding(tabId: tabId)?.identity
        let revision = NativeSelectionTools.zoomRevision(tabId)
        zoom.popover.onDismiss = { NativeSelectionTools.dismissZoom(tabId, revision: revision) }
        zoom.body.onEvent = { event in
          if case .step(let step) = event { NativeSelectionTools.zoom(tabId, identity: identity, step: Double(step)) }
        }
        zoom.body.update(state)
        zoom.popover.set(placement: placement, dark: state.dark)
      }
      if let data = entry(value, kind: "selection", tabId: tabId), let theme = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let state = NativeSelectionTools.state(tabId, theme: theme) {
        selected.insert(tabId)
        (selections[tabId] ?? makeSelection(tabId)).update(state)
      }
      if let data = entry(value, kind: "history", tabId: tabId), let state = try? JSONDecoder().decode(HistoryPanelState.self, from: data), let placement = PanelPopover.placement(data) {
        listed.insert(tabId)
        let history = histories[tabId] ?? makeHistory(tabId)
        if let mark = ((value as? [String: Any])?["history"] as? [String: Any])?["newTabMark"] as? String, mark != history.mark {
          history.mark = mark
          HistoryPanelMark.load(mark, into: history.body)
        }
        history.body.update(state)
        history.popover.set(placement: placement, dark: state.dark)
      }
      if let data = entry(value, kind: "cliPill", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = CliPillState.decode(json) {
        piloted.insert(tabId)
        (cliPills[tabId] ?? makeCliPill(tabId)).update(state)
      }
      if let data = entry(value, kind: "sharePicker", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = SharePickerState.decode(json), let placement = PopoverEnvelope.decode(json) {
        sharing.insert(tabId)
        if shares[tabId]?.id != state.requestId { endShare(tabId); shares[tabId] = (state.requestId, makeShare(tabId), nil) }
        let share = shares[tabId]!.popover
        share.popover.set(placement: placement, dark: state.theme.dark)
        share.body.update(state)
      }
    }
    for found in PanePrompts.cliPills(in: windowId) {
      piloted.insert(found.tabId)
      (cliPills[found.tabId] ?? makeCliPill(found.tabId)).update(found.state)
    }
    for found in PanePrompts.selections(in: windowId) {
      selected.insert(found.tabId)
      (selections[found.tabId] ?? makeSelection(found.tabId)).update(found.state)
    }
    for tabId in PanePrompts.sadTabs(in: windowId) {
      guard let state = PanePrompts.sadTab(windowId, tabId) else { continue }
      sad.insert(tabId)
      (sadTabs[tabId] ?? makeSadTab(tabId)).update(state)
    }
    var asking = Set<String>()
    for found in PanePrompts.prompts(in: windowId, paneWidth: { [weak self] in self?.promptSlot($0).map { Double($0.bounds.width) } }) {
      guard let state = PromptState.decode(found.json), let placement = found.json.data(using: .utf8).flatMap(PanelPopover.placement) else { continue }
      let id = PanePromptEntry.id(found.tabId, found.kind)
      asking.insert(id)
      if prompts[id]?.receipt != found.receipt {
        prompts[id]?.popover.wrap.removeFromSuperview()
        prompts[id] = PanePromptEntry(key: found.key, receipt: found.receipt, tabId: found.tabId, kind: found.kind, popover: makePrompt(found, id))
      }
      let entry = prompts[id]!
      entry.placement = placement
      entry.dark = state.dark
      entry.popover.popover.set(placement: placement, dark: state.dark)
      entry.popover.body.update(state)
    }
    for (id, entry) in prompts where !asking.contains(id) {
      entry.popover.wrap.removeFromSuperview()
      prompts[id] = nil
    }
    var choosing = Set<String>()
    for found in PanePrompts.choosers(in: windowId, paneWidth: { [weak self] in self?.promptSlot($0).map { Double($0.bounds.width) } }) {
      guard let state = DeviceChooserState.decode(found.json), let placement = found.json.data(using: .utf8).flatMap(PanelPopover.placement) else { continue }
      choosing.insert(found.tabId)
      if choosers[found.tabId]?.id != found.id {
        choosers[found.tabId]?.popover.wrap.removeFromSuperview()
        choosers[found.tabId] = PaneChooserEntry(id: found.id, tabId: found.tabId, popover: makeChooser(found.tabId))
      }
      let entry = choosers[found.tabId]!
      entry.placement = placement
      entry.dark = state.dark
      entry.popover.popover.set(placement: placement, dark: state.dark)
      entry.popover.body.update(state)
    }
    for (tabId, entry) in choosers where !choosing.contains(tabId) {
      entry.popover.wrap.removeFromSuperview()
      choosers[tabId] = nil
    }
    for (tabId, view) in sadTabs where !sad.contains(tabId) {
      view.removeFromSuperview()
      sadTabs[tabId] = nil
    }
    for (tabId, zoom) in zooms where !zoomed.contains(tabId) {
      zoom.wrap.removeFromSuperview()
      zooms[tabId] = nil
    }
    for (tabId, bar) in selections where !selected.contains(tabId) {
      bar.removeFromSuperview()
      selections[tabId] = nil
    }
    for (tabId, history) in histories where !listed.contains(tabId) {
      history.wrap.removeFromSuperview()
      histories[tabId] = nil
    }
    for (tabId, pill) in cliPills where !piloted.contains(tabId) {
      pill.removeFromSuperview()
      cliPills[tabId] = nil
    }
    for tabId in shares.keys where !sharing.contains(tabId) { endShare(tabId) }
    relayout()
  }

  private func makeSadTab(_ tabId: String) -> SadTabView {
    let view = SadTabView(frame: .zero)
    let windowId = windowId
    view.onAction = { action in
      if PanePrompts.owns(tabId) { return PanePrompts.sadTabAction(windowId, tabId, action) }
      Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
    }
    view.autoresizingMask = [.width, .height]
    sadTabs[tabId] = view
    return view
  }

  private func makePrompt(_ found: PanePrompts.Shown, _ id: String) -> PanePopover<PromptBodyView> {
    let prompt = PanePopover(PromptBodyView(frame: .zero))
    let windowId = windowId
    let tabId = found.tabId
    let kind = found.kind
    let receipt = found.receipt
    prompt.body.onHeight = { [weak prompt] h in prompt?.setHeight(h) }
    prompt.body.onEvent = { [weak self] event in
      guard let entry = self?.prompts[id], entry.receipt == receipt,
        entry.popover.wrap.window != nil, !entry.popover.wrap.isHiddenOrHasHiddenAncestor else { return }
      if case .choice = event {} else if !entry.allowInput() { return }
      PanePrompts.promptEvent(windowId, tabId, kind, receipt, event)
    }
    if kind == .popups {
      prompt.popover.onDismiss = { [weak self] in
        guard self?.prompts[id]?.receipt == receipt else { return }
        PanePrompts.promptEvent(windowId, tabId, kind, receipt, .close)
      }
    }
    return prompt
  }

  private func makeChooser(_ tabId: String) -> PanePopover<DeviceChooserView> {
    let chooser = PanePopover(DeviceChooserView(frame: .zero))
    chooser.body.onHeight = { [weak chooser] h in chooser?.setHeight(h) }
    chooser.body.onEvent = { [weak self] event in
      if case .choose = event, self?.choosers[tabId]?.allowInput() != true { return }
      PanePrompts.chooserAction(tabId, event)
    }
    return chooser
  }

  private func makeZoom(_ tabId: String) -> PanePopover<ZoomPanelView> {
    let zoom = PanePopover(ZoomPanelView(frame: .zero))
    zoom.body.onHeight = { [weak zoom] h in zoom?.setHeight(h) }
    zoom.wrap.autoresizingMask = [.width, .height]
    zooms[tabId] = zoom
    return zoom
  }

  private func makeSelection(_ tabId: String) -> SelectionBarView {
    let bar = SelectionBarView(frame: .zero)
    bar.onSearch = { click in
      NativeSelectionTools.search(tabId, click: ["metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt])
    }
    bar.autoresizingMask = [.width, .height]
    selections[tabId] = bar
    return bar
  }

  private func makeHistory(_ tabId: String) -> PanePopover<HistoryPanelView> {
    let history = PanePopover(HistoryPanelView(frame: .zero))
    let windowId = windowId
    history.body.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    history.body.onHeight = { [weak history] h in history?.setHeight(h) }
    history.popover.onDismiss = { Task { @MainActor in _ = await SettingsAdapters.js("pane.history", windowId, tabId, ["kind": "dismiss"]) } }
    history.body.onEvent = { event in
      let payload: [String: Any]
      switch event {
      case .open(let index, let click): payload = ["kind": "open", "index": index, "metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt, "middle": click.middle]
      case .fullHistory: payload = ["kind": "fullHistory"]
      }
      Task { @MainActor in _ = await SettingsAdapters.js("pane.history", windowId, tabId, payload) }
    }
    history.wrap.autoresizingMask = [.width, .height]
    histories[tabId] = history
    return history
  }

  private func makeCliPill(_ tabId: String) -> CliControlPillView {
    let pill = CliControlPillView(frame: .zero)
    let windowId = windowId
    pill.onStop = { NativeMedia.action(windowId, "cliStop") }
    pill.autoresizingMask = [.width, .height]
    cliPills[tabId] = pill
    return pill
  }

  private func makeShare(_ tabId: String) -> PanePopover<SharePickerView> {
    let share = PanePopover(SharePickerView(frame: .zero))
    let windowId = windowId
    share.popover.onDismiss = { NativeMedia.action(windowId, "sharePicker", tabId, ["action": "cancel"]) }
    share.body.onAction = { [weak share] event in
      if case .height(let h) = event { share?.setHeight(CGFloat(h)); return }
      NativeMedia.sharePicker(windowId, tabId, event)
    }
    share.wrap.autoresizingMask = [.width, .height]
    share.wrap.onLeave = { [weak self] in self?.unfocusShare(tabId) }
    share.wrap.onReturn = { [weak self] in self?.focusShare(tabId) }
    return share
  }

  func mediaViews(_ kind: String) -> [NSView] {
    switch kind {
    case NativeMedia.sharePicker: return shares.values.map { $0.popover.popover }
    case NativeMedia.cliPill: return Array(cliPills.values)
    default: return []
    }
  }

  private func endShare(_ tabId: String) {
    guard let share = shares[tabId] else { return }
    share.focus?.end()
    share.popover.wrap.removeFromSuperview()
    shares[tabId] = nil
  }

  private func unfocusShare(_ tabId: String) {
    shares[tabId]?.focus?.end()
    shares[tabId]?.focus = nil
  }

  private func focusShare(_ tabId: String) {
    guard let share = shares[tabId], share.focus == nil, let window = share.popover.wrap.window, !share.popover.wrap.isHiddenOrHasHiddenAncestor else { return }
    shares[tabId]?.focus = HostedMount(content: HostedContent(view: share.popover.popover, takesFocus: true), in: share.popover.wrap, window: window)
  }

  func swipe(_ tabId: String, _ message: [String: Any]) {
    let op = message["op"] as? String
    if op == "show" {
      let entry = swipes[tabId] ?? makeSwipe(tabId)
      Self.place(entry.wrap, in: slot(tabId), bottom: false)
      entry.capsule.frame = entry.wrap.bounds
      let theme = message["theme"] as? [String: Any] ?? [:]
      let direction = SwipeCapsuleDirection(rawValue: message["direction"] as? String ?? "") ?? .back
      HostedSwipeCapsule.loadMark(message["newTabMark"] as? String, into: entry.capsule)
      entry.capsule.show(direction, theme: SwipeCapsuleTheme(dark: theme["dark"] as? Bool ?? false, textPrimary: theme["textPrimary"] as? String ?? "#000000D9", textSecondary: theme["textSecondary"] as? String ?? "#00000080"), profileId: message["profileId"] as? String ?? "")
      return relayout()
    }
    guard let capsule = swipes[tabId]?.capsule else { return }
    let number = { (key: String) -> CGFloat? in (message[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
    switch op {
    case "move": capsule.move(x: number("x"), nudge: number("nudge"))
    case "confirm": capsule.setConfirmed(message["confirmed"] as? Bool ?? false)
    case "list":
      let items = (message["items"] as? [[String: Any]] ?? []).map { SwipeCapsuleItem(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", favicon: $0["favicon"] as? String, newTab: $0["newTab"] as? Bool ?? false) }
      capsule.presentList(items)
    case "select":
      capsule.move(nudge: number("nudge"))
      capsule.select(message["index"] as? Int ?? 0)
    case "dismiss": capsule.dismiss(delay: (message["delay"] as? NSNumber)?.doubleValue ?? 0)
    default: break
    }
  }

  private func makeSwipe(_ tabId: String) -> (wrap: PanePopoverWrap, capsule: SwipeCapsuleView) {
    let wrap = PanePopoverWrap()
    let capsule = SwipeCapsuleView(frame: .zero)
    capsule.favicons = Self.swipeFavicons
    capsule.autoresizingMask = [.width, .height]
    wrap.addSubview(capsule)
    capsule.onDismissed = { [weak self, weak capsule] in
      guard let self, let capsule, self.swipes[tabId]?.capsule === capsule else { return }
      self.swipes[tabId]?.wrap.removeFromSuperview()
      self.swipes[tabId] = nil
      self.relayout()
    }
    wrap.autoresizingMask = [.width, .height]
    swipes[tabId] = (wrap, capsule)
    return (wrap, capsule)
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    navigationSwipes.values.forEach { $0.stop() }
    navigationSwipes = [:]
    sadTabs.values.forEach { $0.removeFromSuperview() }
    zooms.values.forEach { $0.wrap.removeFromSuperview() }
    histories.values.forEach { $0.wrap.removeFromSuperview() }
    selections.values.forEach { $0.removeFromSuperview() }
    cliPills.values.forEach { $0.removeFromSuperview() }
    swipes.values.forEach { $0.wrap.removeFromSuperview() }
    prompts.values.forEach { $0.popover.wrap.removeFromSuperview() }
    choosers.values.forEach { $0.popover.wrap.removeFromSuperview() }
    for id in shares.keys { endShare(id) }
    sadTabs = [:]
    zooms = [:]
    histories = [:]
    selections = [:]
    cliPills = [:]
    swipes = [:]
    prompts = [:]
    choosers = [:]
    fromJS = [:]
  }

  func relayout() {
    guard !stopped else { return }
    reconcileNavigationSwipes()
    for (tabId, view) in sadTabs {
      Self.place(view, in: slot(tabId), bottom: true)
      view.isHidden = view.superview == nil || view.showing == nil
    }
    for (tabId, zoom) in zooms { zoom.place(in: slot(tabId)) }
    for entry in prompts.values {
      entry.place(in: promptSlot(entry.tabId))
    }
    for entry in choosers.values {
      entry.popover.place(in: slot(entry.tabId))
      entry.refit()
    }
    for (tabId, history) in histories { history.place(in: slot(tabId)) }
    for (tabId, pill) in cliPills { Self.place(pill, in: slot(tabId), bottom: false) }
    for (tabId, share) in shares {
      share.popover.place(in: slot(tabId))
      focusShare(tabId)
    }
    for (tabId, bar) in selections {
      Self.place(bar, in: slot(tabId), bottom: false)
      bar.isHidden = bar.superview == nil
    }
    for (tabId, entry) in swipes {
      Self.place(entry.wrap, in: slot(tabId), bottom: false)
      entry.capsule.frame = entry.wrap.bounds
    }
  }

  func openNavigationMenu(_ tabId: String, direction: SwipeCapsuleDirection) {
    relayout()
    navigationSwipes[tabId]?.openMenu(direction)
  }

  func closeNavigationMenu(_ tabId: String) {
    navigationSwipes[tabId]?.dismissMenu()
  }

  private func reconcileNavigationSwipes() {
    guard NativeWindowShell.nativeLayoutActive(windowId), PageIssuer.shared != nil,
      let snapshot = NativeStoreHandle.store?.snapshot else { return }
    let state = snapshot.state
    let generation = NativeWindowShell.nativeLayoutGeneration(windowId)
    let feed = NativePaneOverlays.navigation[windowId]
    let presentations = (feed?["generation"] as? NSNumber)?.uint64Value == generation ? feed?["presentations"] as? [String: [String: Any]] ?? [:] : [:]
    let peekId = state.peeks[windowId]?.tabId
    func containers(_ tabId: String) -> (input: NSView?, drawing: NSView?) {
      if tabId == peekId {
        let peek = TabSlots.shared.container(for: .peek(windowId))
        return (peek, peek)
      }
      return (PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .rn), slot(tabId))
    }
    var candidates = PaneOverlays.shared.tabIds(in: windowId)
    if let peekId { candidates.insert(peekId) }
    let attached = candidates.compactMap { id -> (id: String, input: NSView, drawing: NSView?)? in
      guard state.tabs[id]?.windowId == windowId else { return nil }
      let slots = containers(id)
      guard let input = slots.input, input.window != nil else { return nil }
      return (id, input, slots.drawing)
    }
    let ids = Set(attached.map { $0.id })
    let visible = attached.filter { !$0.input.isHiddenOrHasHiddenAncestor }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("navigationCandidates", "\(windowId) \(ids.count) \(visible.count)")
    #endif
    for (id, entry) in navigationSwipes where !ids.contains(id) {
      entry.stop()
      navigationSwipes[id] = nil
    }
    for slots in visible {
      let id = slots.id
      let registration = TabPoolHost.shared.presentationRegistration(id) ?? PageRegistration(tabID: id, registrationGeneration: 0)
      if navigationSwipes[id]?.matches(registration, url: state.tabs[id]?.url) != true {
        navigationSwipes[id]?.stop()
        navigationSwipes[id] = NativeNavigationSwipe(windowId: windowId, generation: generation, registration: registration, compatibilityURL: state.tabs[id]?.url ?? "")
      }
      navigationSwipes[id]?.place(input: slots.input, drawing: slots.drawing, presentation: presentations[id] ?? [:], state: state, revision: snapshot.rev, presentationRevision: NativePaneOverlays.navigationRevision)
    }
  }

  static func place(_ view: NSView, in container: NSView?, bottom: Bool) {
    guard let container else { return view.removeFromSuperview() }
    if view.superview !== container {
      if bottom { container.addSubview(view, positioned: .below, relativeTo: nil) } else { container.addSubview(view) }
    }
    if view.frame != container.bounds { view.frame = container.bounds }
  }

  #if DEBUG
    func describe() -> [String: Any] {
      var tabs: [String: [String: Any]] = [:]
      func inWindow(_ view: NSView, _ r: CGRect) -> [Double] {
        let w = view.convert(r, to: nil)
        let h = view.window?.contentView?.bounds.height ?? 0
        return [w.minX, h - w.maxY, w.width, w.height]
      }
      for (tabId, view) in sadTabs {
        tabs[tabId, default: [:]]["sadTab"] = ["mode": (view.showing?.rawValue).map { $0 as Any } ?? NSNull(), "hidden": view.isHiddenOrHasHiddenAncestor, "frame": inWindow(view, view.bounds), "controls": view.controlFrames.mapValues { inWindow(view, $0) }]
      }
      for (tabId, zoom) in zooms { tabs[tabId, default: [:]]["zoom"] = zoom.describe(inWindow) }
      for entry in prompts.values { tabs[entry.tabId, default: [:]][entry.kind.rawValue] = entry.popover.describe(inWindow).merging(["key": entry.key]) { _, key in key } }
      for entry in choosers.values { tabs[entry.tabId, default: [:]]["deviceChooser"] = entry.popover.describe(inWindow).merging(["id": entry.id]) { _, id in id } }
      for (tabId, history) in histories { tabs[tabId, default: [:]]["history"] = history.describe(inWindow) }
      let casts = NativeCast.panePickers(windowId)
      for (tabId, cast) in casts { tabs[tabId, default: [:]]["castPicker"] = cast.describe(inWindow) }
      for (tabId, pill) in cliPills { tabs[tabId, default: [:]]["cliPill"] = ["frame": inWindow(pill, pill.bounds), "pill": inWindow(pill, pill.pillFrame), "shown": pill.shown, "progress": pill.progress] }
      for (tabId, share) in shares {
        var info = share.popover.describe(inWindow)
        info["focused"] = share.popover.wrap.window.map { window in (window.firstResponder as? NSView).map { $0 === share.popover.popover || $0.isDescendant(of: share.popover.popover) } ?? false } ?? false
        tabs[tabId, default: [:]]["sharePicker"] = info
      }
      for (tabId, bar) in selections {
        tabs[tabId, default: [:]]["selection"] = ["hidden": bar.isHiddenOrHasHiddenAncestor, "area": inWindow(bar, bar.bounds), "bar": bar.barFrame.map { inWindow(bar, $0) } ?? NSNull(),
          "button": bar.buttonFrame.map { inWindow(bar, $0) } ?? NSNull(), "above": bar.above, "opacity": bar.presentedOpacity]
      }
      for (tabId, entry) in swipes {
        let c = entry.capsule
        let s = c.sample()
        tabs[tabId, default: [:]]["swipe"] = ["shown": c.shown, "active": c.active, "direction": c.direction.rawValue, "confirmed": c.confirmed, "items": c.items?.map(\.title) ?? NSNull(), "selected": c.selected,
          "frame": inWindow(c, s.frame), "area": inWindow(entry.wrap, entry.wrap.bounds), "radius": s.radius, "opacity": s.opacity, "scale": s.scale, "iconScale": s.iconScale, "list": s.list, "pill": s.pill]
      }
      for (tabId, entry) in navigationSwipes {
        let c = entry.capsule
        let s = c.sample()
        tabs[tabId, default: [:]]["swipe"] = ["shown": c.shown, "active": c.active, "direction": c.direction.rawValue, "confirmed": c.confirmed,
          "items": c.items?.map(\.title) ?? NSNull(), "selected": c.selected, "frame": inWindow(c, s.frame), "area": inWindow(c, c.bounds),
          "radius": s.radius, "opacity": s.opacity, "scale": s.scale, "iconScale": s.iconScale, "list": s.list, "pill": s.pill]
      }
      let card = NativeWindowShell.host(windowId)?.shell.card
      let layer = PaneOverlays.shared.layer(windowId: windowId)
      return ["top": layer != nil && card?.subviews.last === layer, "inCard": !(sadTabs.isEmpty && zooms.isEmpty && histories.isEmpty && swipes.isEmpty && selections.isEmpty && cliPills.isEmpty && casts.isEmpty && shares.isEmpty) && layer != nil && layer?.superview === card, "tabs": tabs]
    }
  #endif
}

#if DEBUG && SOLARA_PROBES
@MainActor
public enum PaneOverlayRead {
  public static func snapshot(windowId: String) -> [String: Any]? { NativePaneOverlays.snapshot(windowId) }

  public static func selection(windowId: String, tabId: String) -> [String: Any]? {
    (NativePaneOverlays.snapshot(windowId)?["tabs"] as? [String: [String: Any]])?[tabId]?["selection"] as? [String: Any]
  }

  public static func zoom(windowId: String, tabId: String) -> [String: Any]? {
    (NativePaneOverlays.snapshot(windowId)?["tabs"] as? [String: [String: Any]])?[tabId]?["zoom"] as? [String: Any]
  }

  public static func history(windowId: String, tabId: String) -> [String: Any]? {
    (NativePaneOverlays.snapshot(windowId)?["tabs"] as? [String: [String: Any]])?[tabId]?["history"] as? [String: Any]
  }

  public static func sadTab(windowId: String, tabId: String) -> [String: Any]? {
    (NativePaneOverlays.snapshot(windowId)?["tabs"] as? [String: [String: Any]])?[tabId]?["sadTab"] as? [String: Any]
  }
}
#endif

@MainActor
private final class NativeNavigationSwipe {
  let registration: PageRegistration
  private let windowId: String
  private let generation: UInt64
  private let compatibilityURL: String
  private let target = NativeSwipeTarget(frame: .zero)
  private let controller = NavigationSwipeController()
  var capsule: SwipeCapsuleView { controller.capsule }
  private var presentation: [String: Any] = [:]
  private var configurationRevision: Int?
  private var configurationPresentationRevision: UInt64?
  private var stopped = false
  private var menu: PanePopover<HistoryPanelView>?
  private var menuSequence = 0

  init(windowId: String, generation: UInt64, registration: PageRegistration, compatibilityURL: String) {
    self.windowId = windowId
    self.generation = generation
    self.registration = registration
    self.compatibilityURL = compatibilityURL
    target.coversPage = true
    target.autoresizingMask = [.width, .height]
    controller.capsule.autoresizingMask = [.width, .height]
    controller.isCurrent = { [weak self] in self?.current == true }
    controller.onVerticalMotion = { [weak self] in self?.target.allowsVerticalMotion = $0 }
    controller.loadHistory = { [weak self] direction, completion in self?.history(direction, completion) }
    controller.navigate = { [weak self] action in self?.navigate(action) }
    target.onSwipe = { [weak self] event in
      guard let self else { return }
      self.controller.input(phase: event["phase"] as? String ?? "", direction: SwipeCapsuleDirection(rawValue: event["direction"] as? String ?? "") ?? .back,
        distance: (event["distance"] as? NSNumber)?.doubleValue ?? 0, dy: (event["dy"] as? NSNumber)?.doubleValue ?? 0)
    }
  }

  func matches(_ next: PageRegistration, url: String?) -> Bool {
    registration == next && (registration.registrationGeneration != 0 || url == compatibilityURL)
  }

  private var pageCurrent: Bool {
    guard let registry = PageIssuer.shared?.registry else { return false }
    if registration.registrationGeneration != 0 { return registry.descriptor(registration) != nil }
    return matches(registration, url: NativeStoreHandle.store?.state.tabs[registration.tabID]?.url) && !registry.descriptors.contains { $0.tabID == registration.tabID }
  }

  private var current: Bool {
    !stopped && target.window != nil && !target.isHiddenOrHasHiddenAncestor && NativeWindowShell.nativeLayoutGeneration(windowId) == generation
      && TabPoolHost.shared.windowOf(registration.tabID) == windowId && pageCurrent
  }

  func place(input: NSView?, drawing: NSView?, presentation: [String: Any], state: BrowserState, revision: Int, presentationRevision: UInt64) {
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("navigationPlace", "\(windowId) \(registration.tabID)")
    #endif
    menu?.place(in: drawing)
    PaneOverlayHost.place(target, in: input, bottom: false)
    PaneOverlayHost.place(controller.capsule, in: drawing, bottom: false)
    guard configurationRevision != revision || configurationPresentationRevision != presentationRevision else { return }
    configurationRevision = revision
    configurationPresentationRevision = presentationRevision
    self.presentation = presentation
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("navigationConfigure", "\(windowId) \(registration.tabID) \(revision) \(presentationRevision)")
    #endif
    let pageID = state.tabs[registration.tabID]?.pageIn.flatMap { $0.isEmpty ? nil : $0 } ?? registration.tabID
    let live = state.live[pageID]
    let newTabShown = presentation["newTabShown"] as? Bool == true
    target.canSwipeBack = !newTabShown && (live?.canGoBack == true || presentation["backToNewTab"] as? Bool == true || presentation["engineBack"] as? Bool == true || presentation["backToOpener"] as? Bool == true)
    target.canSwipeForward = newTabShown || live?.canGoForward == true
    controller.profileId = state.tabs[registration.tabID]?.profileId ?? ""
    if let theme = presentation["theme"] as? [String: Any] {
      controller.theme = SwipeCapsuleTheme(dark: theme["dark"] as? Bool ?? false, textPrimary: theme["textPrimary"] as? String ?? "#000000D9", textSecondary: theme["textSecondary"] as? String ?? "#00000080")
    }
  }

  private func history(_ direction: SwipeCapsuleDirection, _ completion: @escaping ([NavigationSwipeItem]) -> Void) {
    guard current, let registry = PageIssuer.shared?.registry else { return }
    if registration.registrationGeneration == 0 {
      completion(direction == .back && presentation["backToNewTab"] as? Bool == true ? [.init(title: "New Tab", url: "", offset: 0, newTab: true)] : [])
      return
    }
    registry.call(registration, command: .navigationEntries) { [weak self] result in
      guard let self, self.current, case .success(let value) = result, let entries = value.foundation as? [[String: Any]] else { return }
      let current = entries.firstIndex { $0["current"] as? Bool == true } ?? -1
      let step = direction == .back ? -1 : 1
      var items: [NavigationSwipeItem] = []
      let shown = self.presentation["newTabShown"] as? Bool == true
      if current >= 0, !shown {
        var index = current + step
        while entries.indices.contains(index), items.count < 15 {
          let entry = entries[index]
          let url = entry["url"] as? String ?? ""
          let title = entry["title"] as? String ?? ""
          items.append(.init(title: title.isEmpty ? url : title, url: url, offset: index - current))
          index += step
        }
      }
      if shown {
        Task { @MainActor [weak self] in
          guard let self, self.current else { return }
          let value = await SettingsAdapters.js("pane.navigationHistory", self.windowId, self.registration.tabID, Double(self.generation), step)
          guard self.current, let rows = value as? [[String: Any]] else { return }
          completion(rows.map { .init(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", offset: $0["offset"] as? Int ?? 0) })
        }
      } else {
        if step < 0, self.presentation["backToNewTab"] as? Bool == true, items.count < 15 {
          items.append(.init(title: "New Tab", url: "", offset: -max(0, current), newTab: true))
        }
        completion(items)
      }
    }
  }

  func openMenu(_ direction: SwipeCapsuleDirection) {
    guard current, let store = NativeStoreHandle.store,
      let target = ToolbarActionCommand.resolve(windowId: windowId, tabId: registration.tabID, state: store.state,
        closing: store.memory.closingWindows) else { return }
    let owner = NativeStoreHandle.ownershipGeneration
    func targetCurrent() -> Bool {
      NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store && NativeStoreHandle.ownershipGeneration == owner
        && target.isCurrent(in: store.state, closing: store.memory.closingWindows)
    }
    controller.stop()
    menuSequence += 1
    let sequence = menuSequence
    history(direction) { [weak self] items in
      guard let self, self.current, self.menuSequence == sequence, targetCurrent(), !items.isEmpty else { return }
      self.dismissMenu()
      let menu = PanePopover(HistoryPanelView(frame: .zero))
      self.menu = menu
      let theme = self.controller.theme
      let state: [String: Any] = ["items": items.map { ["title": $0.title, "url": $0.url, "newTab": $0.newTab] }, "profileId": self.controller.profileId,
        "dark": theme.dark, "theme": ["textPrimary": theme.textPrimary, "textSecondary": theme.textSecondary, "icon": theme.textSecondary]]
      guard let data = try? JSONSerialization.data(withJSONObject: state), let decoded = try? JSONDecoder().decode(HistoryPanelState.self, from: data) else { return }
      menu.body.favicons.loader = { request in try await NativeSidebar.favicon(request) }
      menu.body.onHeight = { [weak menu] in menu?.setHeight($0) }
      menu.popover.onDismiss = { [weak self] in self?.dismissMenu() }
      menu.body.onEvent = { [weak self] event in
        guard let self, self.current, targetCurrent() else { return }
        switch event {
        case .open(let index, let click):
          guard items.indices.contains(index) else { return }
          let item = items[index]
          if !click.meta && !click.shift && !click.alt && !click.middle || item.url.isEmpty {
            self.dismissMenu()
            self.navigate(.item(item))
          } else {
            if click.shift || click.alt { self.dismissMenu() }
            let mode = click.meta || click.middle ? (click.shift ? "foreground" : "background") : click.alt ? "split" : "window"
            NativeBookmarkCommands.openURL(item.url, mode: mode, windowId: self.windowId)
          }
        case .fullHistory:
          self.dismissMenu()
          _ = try? store.dispatch(Command("omniboxCommand", [.string(self.windowId), "showHistory"]), origin: .native)
        }
      }
      menu.place(in: self.controller.capsule.superview)
      var left = 12.0
      if let host = NativeWindowShell.host(self.windowId), let anchors = host.anchorPayload()?["anchors"] as? [String: [Double]],
        let rect = anchors[direction == .back ? "button:back" : "button:forward"], rect.count == 4 {
        let point = self.target.convert(NSPoint(x: rect[0], y: rect[1]), from: host.shell)
        left = max(12, point.x - 18)
      }
      menu.body.update(decoded)
      menu.popover.set(placement: PopoverPlacement(width: 300, top: 12, left: left), dark: theme.dark)
    }
  }

  func dismissMenu() {
    menuSequence += 1
    menu?.wrap.removeFromSuperview()
    menu = nil
  }

  private func navigate(_ action: NavigationSwipeAction) {
    guard current, let registry = PageIssuer.shared?.registry else { return }
    let state = NativeStoreHandle.store?.state
    let pageID = state?.tabs[registration.tabID]?.pageIn.flatMap { $0.isEmpty ? nil : $0 } ?? registration.tabID
    let live = state?.live[pageID]
    let shown = presentation["newTabShown"] as? Bool == true
    var compatibility: [String: Any]?
    switch action {
    case .step(let direction):
      if registration.registrationGeneration == 0 || shown || (direction == .back && live?.canGoBack != true) { compatibility = ["kind": direction.rawValue] }
      else { registry.call(registration, command: direction == .back ? .goBack : .goForward) { _ in } }
    case .item(let item):
      if shown || item.newTab { compatibility = ["kind": "item", "title": item.title, "url": item.url, "offset": item.newTab ? "newTab" : item.offset] }
      else { registry.call(registration, command: .goToOffset(item.offset)) { _ in } }
    }
    if let compatibility {
      Task { @MainActor [weak self] in
        guard let self, self.current else { return }
        _ = await SettingsAdapters.js("pane.navigationCompatibility", self.windowId, self.registration.tabID, Double(self.generation), Double(self.registration.registrationGeneration), self.compatibilityURL, compatibility)
      }
    }
  }

  func stop() {
    stopped = true
    dismissMenu()
    controller.stop()
    target.removeFromSuperview()
    controller.capsule.removeFromSuperview()
  }
}
