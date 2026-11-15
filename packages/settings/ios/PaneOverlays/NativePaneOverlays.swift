import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativePaneOverlays {
  static let topic = "pane.overlays"
  private static var started = false
  private static var hosts: [String: PaneOverlayHost] = [:]

  static func start() {
    HostedSadTab.register()
    HostedSelectionBar.register()
    HostedSwipeCapsule.register()
    HostedFrozenPage.register()
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    PanePrompts.start()
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
    guard NativeWindowShell.host(windowId) != nil, PanePrompts.draws(windowId) else { return }
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
  let tabId: String
  let kind: PanePromptKind
  let popover: PanePopover<PromptBodyView>
  var placement: PopoverPlacement?
  var dark = false
  private var input = PromptInputGuard()
  private var fitWidth: CGFloat = -1

  static func id(_ tabId: String, _ kind: PanePromptKind) -> String { tabId + "\u{1}" + kind.rawValue }

  init(key: String, tabId: String, kind: PanePromptKind, popover: PanePopover<PromptBodyView>) {
    self.key = key
    self.tabId = tabId
    self.kind = kind
    self.popover = popover
    input.shown(at: ProcessInfo.processInfo.systemUptime)
  }

  func allowInput() -> Bool { input.allow(at: ProcessInfo.processInfo.systemUptime, activatedAt: PanePrompts.activatedAt) }

  func refit() {
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
  private var casts: [String: (id: String, popover: PanePopover<CastPickerView>)] = [:]
  private var shares: [String: (id: String, popover: PanePopover<SharePickerView>, focus: HostedMount?)] = [:]
  private var swipes: [String: (wrap: PanePopoverWrap, capsule: SwipeCapsuleView)] = [:]
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
    var casting = Set<String>()
    var piloted = Set<String>()
    var sharing = Set<String>()
    for (tabId, value) in tabs {
      if !PanePrompts.owns(tabId), let data = entry(value, kind: "sadTab", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = SadTabState.decode(json), state.mode != nil {
        sad.insert(tabId)
        (sadTabs[tabId] ?? makeSadTab(tabId)).update(state)
      }
      if let data = entry(value, kind: "zoom", tabId: tabId), let state = try? JSONDecoder().decode(ZoomPanelState.self, from: data), let placement = PanelPopover.placement(data) {
        zoomed.insert(tabId)
        let zoom = zooms[tabId] ?? makeZoom(tabId)
        zoom.body.update(state)
        zoom.popover.set(placement: placement, dark: state.dark)
      }
      if let data = entry(value, kind: "selection", tabId: tabId), let state = try? JSONDecoder().decode(SelectionBarState.self, from: data) {
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
      if let data = entry(value, kind: "castPicker", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = CastPickerState.decode(json), let placement = PopoverEnvelope.decode(json) {
        casting.insert(tabId)
        if casts[tabId]?.id != state.dialogId { casts[tabId]?.popover.wrap.removeFromSuperview(); casts[tabId] = (state.dialogId, makeCast(tabId)) }
        let cast = casts[tabId]!.popover
        cast.popover.set(placement: placement, dark: state.theme.dark)
        cast.body.update(state)
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
    for found in PanePrompts.prompts(in: windowId, paneWidth: { [weak self] in self?.slot($0).map { Double($0.bounds.width) } }) {
      guard let state = PromptState.decode(found.json), let placement = found.json.data(using: .utf8).flatMap(PanelPopover.placement) else { continue }
      let id = PanePromptEntry.id(found.tabId, found.kind)
      asking.insert(id)
      if prompts[id]?.key != found.key {
        prompts[id]?.popover.wrap.removeFromSuperview()
        prompts[id] = PanePromptEntry(key: found.key, tabId: found.tabId, kind: found.kind, popover: makePrompt(found.tabId, found.kind, id))
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
    for found in PanePrompts.choosers(in: windowId, paneWidth: { [weak self] in self?.slot($0).map { Double($0.bounds.width) } }) {
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
    for (tabId, cast) in casts where !casting.contains(tabId) {
      cast.popover.wrap.removeFromSuperview()
      casts[tabId] = nil
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

  private func makePrompt(_ tabId: String, _ kind: PanePromptKind, _ id: String) -> PanePopover<PromptBodyView> {
    let prompt = PanePopover(PromptBodyView(frame: .zero))
    let windowId = windowId
    prompt.body.onHeight = { [weak prompt] h in prompt?.setHeight(h) }
    prompt.body.onEvent = { [weak self] event in
      if case .choice = event {} else if self?.prompts[id]?.allowInput() != true { return }
      PanePrompts.promptEvent(windowId, tabId, kind, event)
    }
    if kind == .popups { prompt.popover.onDismiss = { PanePrompts.promptEvent(windowId, tabId, .popups, .close) } }
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
    let windowId = windowId
    zoom.body.onHeight = { [weak zoom] h in zoom?.setHeight(h) }
    zoom.popover.onDismiss = { Task { @MainActor in _ = await SettingsAdapters.js("pane.zoom", windowId, tabId, "dismiss", 0) } }
    zoom.body.onEvent = { event in
      switch event {
      case .step(let step): Task { @MainActor in _ = await SettingsAdapters.js("pane.zoom", windowId, tabId, "step", step) }
      }
    }
    zoom.wrap.autoresizingMask = [.width, .height]
    zooms[tabId] = zoom
    return zoom
  }

  private func makeSelection(_ tabId: String) -> SelectionBarView {
    let bar = SelectionBarView(frame: .zero)
    let windowId = windowId
    bar.onSearch = { click in
      if PanePrompts.searchSelection(windowId, tabId, ["metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt]) { return }
      Task { @MainActor in _ = await SettingsAdapters.js("pane.selection", windowId, tabId, ["metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt]) }
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

  private func makeCast(_ tabId: String) -> PanePopover<CastPickerView> {
    let cast = PanePopover(CastPickerView(frame: .zero))
    let windowId = windowId
    cast.popover.onDismiss = { NativeMedia.action(windowId, "castPicker", tabId, ["action": "dismiss"]) }
    cast.body.onAction = { [weak cast] event in
      if case .height(let h) = event { cast?.setHeight(CGFloat(h)); return }
      NativeMedia.castPicker(windowId, tabId, event)
    }
    cast.wrap.autoresizingMask = [.width, .height]
    return cast
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
    case NativeMedia.castPicker: return casts.values.map { $0.popover.popover }
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
    sadTabs.values.forEach { $0.removeFromSuperview() }
    zooms.values.forEach { $0.wrap.removeFromSuperview() }
    histories.values.forEach { $0.wrap.removeFromSuperview() }
    selections.values.forEach { $0.removeFromSuperview() }
    cliPills.values.forEach { $0.removeFromSuperview() }
    casts.values.forEach { $0.popover.wrap.removeFromSuperview() }
    swipes.values.forEach { $0.wrap.removeFromSuperview() }
    prompts.values.forEach { $0.popover.wrap.removeFromSuperview() }
    choosers.values.forEach { $0.popover.wrap.removeFromSuperview() }
    for id in shares.keys { endShare(id) }
    sadTabs = [:]
    zooms = [:]
    histories = [:]
    selections = [:]
    cliPills = [:]
    casts = [:]
    swipes = [:]
    prompts = [:]
    choosers = [:]
    fromJS = [:]
  }

  func relayout() {
    guard !stopped else { return }
    for (tabId, view) in sadTabs {
      Self.place(view, in: slot(tabId), bottom: true)
      view.isHidden = view.superview == nil || view.showing == nil
    }
    for (tabId, zoom) in zooms { zoom.place(in: slot(tabId)) }
    for entry in prompts.values {
      entry.popover.place(in: slot(entry.tabId))
      entry.refit()
    }
    for entry in choosers.values {
      entry.popover.place(in: slot(entry.tabId))
      entry.refit()
    }
    for (tabId, history) in histories { history.place(in: slot(tabId)) }
    for (tabId, pill) in cliPills { Self.place(pill, in: slot(tabId), bottom: false) }
    for (tabId, cast) in casts { cast.popover.place(in: slot(tabId)) }
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
      for (tabId, cast) in casts { tabs[tabId, default: [:]]["castPicker"] = cast.popover.describe(inWindow) }
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
