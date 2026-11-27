import AppKit
import Foundation
import SolaraLive
import SolaraEngine
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeSidebarHoverCard {
  private static var observers: [NSObjectProtocol] = []
  private static var hosts: [String: SidebarHoverCardHost] = [:]

  static func start() {
    guard observers.isEmpty else { return }
    NativeTabMemory.installEngineQuery()
    NativeHeavyTabs.start()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { dismiss() }
    })
    observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
      guard let window = note.object as? NSWindow else { return }
      let key = ObjectIdentifier(window)
      MainActor.assumeIsolated {
        for (id, host) in hosts where WindowHost.contentView(id)?.window.map(ObjectIdentifier.init) != key { host.dismiss() }
      }
    })
    observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { dismiss() }
    })
    for id in NativeWindowShell.windowIds { prepare(id) }
  }

  static func row(windowId: String, kind: String?, id: String?) {
    if let kind, let id {
      for (key, host) in hosts where key != windowId { host.dismiss() }
      host(windowId).row(SidebarHoverTarget(kind: kind, id: id))
    } else { hosts[windowId]?.row(nil) }
  }

  static func refresh(_ windowId: String) { hosts[windowId]?.refresh() }

  static func dismiss(_ windowId: String? = nil) {
    for (id, host) in hosts where windowId == nil || id == windowId { host.dismiss() }
  }

  static func hold(_ windowId: String, _ on: Bool) { hosts[windowId]?.hold(on) }

  static func hasPointer(_ windowId: String) -> Bool { hosts[windowId]?.onCard == true }

  private static func host(_ windowId: String) -> SidebarHoverCardHost {
    if let host = hosts[windowId] { return host }
    let host = SidebarHoverCardHost(windowId: windowId)
    hosts[windowId] = host
    return host
  }

  static func describe(_ windowId: String) -> String {
    guard let info = hosts[windowId]?.describe(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  static func prepare(_ windowId: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      guard !observers.isEmpty, NativeWindowShell.overlay(windowId)?.window != nil else { return }
      let host = host(windowId)
      if !host.prepared { host.prepare() }
    }
  }

  static func windowEnded(_ windowId: String) {
    hosts.removeValue(forKey: windowId)?.end()
  }

  static func players(windowId: String) -> [NSView] { hosts[windowId]?.shownPlayers ?? [] }

  static func presented(_ windowId: String, at point: CGPoint, width: ClosedRange<Double>, height: ClosedRange<Double>) -> String {
    guard let view = NativeSidebar.hosts[windowId]?.view.window?.contentView, let root = view.layer?.presentation() ?? view.layer else { return "null" }
    let flipped = view.isFlipped || root.isGeometryFlipped
    let local = CGPoint(x: point.x, y: flipped ? point.y : root.bounds.height - point.y)
    func find(_ layer: CALayer) -> CALayer? {
      for sub in layer.sublayers ?? [] where !sub.isHidden {
        let rect = sub.convert(sub.bounds, to: root)
        if rect.contains(local), width.contains(Double(rect.width)), height.contains(Double(rect.height)) { return sub }
        if let deeper = find(sub) { return deeper }
      }
      return nil
    }
    #if SOLARA_PROBES
    guard let hit = find(root) else { return presentationJSON(["opacity": 0, "scale": 0, "rect": [0, 0, 0, 0]], windowId: windowId) }
    #else
    guard let hit = find(root) else { return "{\"opacity\":0,\"scale\":0,\"rect\":[0,0,0,0]}" }
    #endif
    var opacity = 1.0
    var layer: CALayer? = hit
    while let current = layer, current !== root {
      if current.isHidden { opacity = 0 }
      opacity *= Double(current.opacity)
      layer = current.superlayer
    }
    let rect = hit.convert(hit.bounds, to: root)
    let info: [String: Any] = [
      "opacity": opacity, "scale": hit.bounds.width > 0 ? rect.width / hit.bounds.width : 0,
      "rect": [rect.minX, flipped ? rect.minY : root.bounds.height - rect.maxY, rect.width, rect.height],
      "layer": String(describing: type(of: hit)), "delegate": hit.delegate.map { String(describing: type(of: $0)) } ?? "",
    ]
    #if SOLARA_PROBES
    return presentationJSON(info, windowId: windowId)
    #else
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
    #endif
  }

  #if SOLARA_PROBES
  private static func presentationJSON(_ source: [String: Any], windowId: String) -> String {
    var info = source
    info["probeSequence"] = SidebarHoverPresentationTrace.record(windowId: windowId, source: source)
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  #endif

}

private struct SidebarHoverTarget: Equatable {
  let kind: String
  let id: String
}

@MainActor
final class SidebarHoverCardHost {
  let windowId: String
  private let motion = HoverCardView()
  private var target: SidebarHoverTarget?
  private var shown: SidebarHoverTarget?
  private var timer: Timer?
  private var held = false
  private(set) var onCard = false
  private var inline: Bool { NativeWindowShell.overlay(windowId) == nil }
  private var mediaListener: UUID?
  private var input: [String: Any]?
  private var attachment: (anchor: CGRect, y: CGFloat, gap: CGFloat)?
  private lazy var tabCard: SidebarTabCardView = {
    let card = SidebarTabCardView()
    card.prefersGlass = !inline
    card.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      if action == "pip" {
        return NativeMediaStack.togglePictureInPicture(tabId: id, windowId: self.windowId, window: card?.window)
      }
      if action == SidebarTabCardState.Button.sleepHeavy.action {
        Task { @MainActor in _ = await HeavyTabs.sleep?(id) }
        return
      }
      self.tabAction(action, id: id)
    }
    card.onPictureInPictureAccessibilityPress = { [weak self, weak card] in
      guard let self, let card, let id = card.state?.tabId else { return }
      NativeMediaStack.togglePictureInPicture(tabId: id, windowId: self.windowId, window: card.window, keyboardOrAccessibility: true)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var groupCard: SidebarGroupCardView = {
    let card = SidebarGroupCardView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.virtualizesRows = NativeSidebar.hosts[windowId]?.view.virtualizesRows ?? false
    #if SOLARA_PROBES
    card.probeRowBinding = { [windowId = self.windowId] view, profileId in
      NativeWorkCounters.bind(view, windowId: windowId, profileId: profileId, kind: "sidebar.groupCard.full")
    }
    #endif
    card.onEvent = { [weak self, weak card] event in
      guard let self, card?.state?.groupId == self.shown?.id else { return }
      switch event {
      case .choose(let tabId): self.choose(tabId)
      case .close: self.dismiss()
      case .hold(let on): self.hold(on)
      case .focusPage:
        if let store = WorkspaceWrites.store { NativeWorkspaceCommands.restoreContentFocus(windowId: self.windowId, store: store) }
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var liveCard: SidebarLiveCardView = {
    let card = SidebarLiveCardView(favicons: NativeSidebar.hosts[windowId]?.view.favicons)
    card.onEvent = { [weak self, weak card] event in
      guard let self, let id = card?.state?.id else { return }
      switch event {
      case .openItem:
        let key = SidebarLiveCardState.itemKey(id)
        self.dismiss()
        NativeSidebarLive.action("open", windowId: self.windowId, folderId: key.folderId, id: key.itemId, background: false)
      case .open(let url):
        self.dismiss()
        self.dispatch(Command("newTab", [.string(self.windowId), ["url": .string(url)]]))
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.contentResized() }
    return card
  }()
  private lazy var playerCard: HoverPlayerCardView = {
    let card = HoverPlayerCardView()
    card.player.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      if case .backToTab = action {
        self.dismiss()
      }
      NativeMediaStack.perform(windowId: self.windowId, tabId: id, action: action, fromHover: true)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var calendarCard: SidebarCalendarCardView = {
    PageProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
    let card = SidebarCalendarCardView()
    card.onEvent = { [weak self, weak card] event in
      guard let self, let tabId = card?.tabId else { return }
      switch event {
      case .activate: self.choose(tabId)
      case .join(let id, _):
        self.dismiss()
        NativeSidebarLive.joinCalendarEvent(id, windowId: self.windowId)
      case .refresh: NativeSidebarLive.perform(.refreshCalendar(.object([:])))
      case .connect: NativeSidebarLive.perform(.connectCalendar(.object([:])))
      case .height, .dismiss, .view: break
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.contentResized() }
    return card
  }()
  private lazy var folderPeek: SidebarFolderPeekView = {
    let card = SidebarFolderPeekView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.onChoose = { [weak self, weak card] tabId in
      guard let self, card?.state?.folderId == self.shown?.id else { return }
      self.choose(tabId)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private var kind: String?
  private var tabCardId: String?
  private var tabCardInput: [String: Any]?

  var shownPlayers: [NSView] { kind == "player" && motion.phase != .hidden ? [playerCard.player] : [] }
  private var liveObserver: NSObjectProtocol?

  init(windowId: String) {
    self.windowId = windowId
    mediaListener = NativeMediaStack.listen { [weak self] in
      guard let self, let input = self.input, input["kind"] as? String == "tab" else { return }
      self.show(input)
    }
    motion.autoresizingMask = [.width, .height]
    motion.onHidden = { [weak self] in self?.coverChanged() }
    liveObserver = NotificationCenter.default.addObserver(forName: SidebarLiveFeed.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.liveChanged() }
    }
  }

  private func liveChanged() { refresh() }

  private func coverChanged() {
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  private func contentResized() {
    if let attachment, let content = motion.content, motion.phase != .hidden, motion.phase != .leaving,
      let host = NativeWindowShell.host(windowId), host.ownsNativeLayout, host.shell.input.sidebarSide == .right {
      let origin = SidebarAttachment.origin(anchor: attachment.anchor, size: content.frame.size,
        visible: host.shell.bounds, side: .right, gap: attachment.gap, preferredY: attachment.y)
      motion.origin = origin
    }
    coverChanged()
  }

  private(set) var prepared = false

  func prepare() {
    guard motion.phase == .hidden, let overlay = NativeWindowShell.overlay(windowId) else { return }
    prepared = true
    if motion.superview !== overlay {
      motion.frame = overlay.bounds
      overlay.addSubview(motion)
    }
    motion.keepHidden(tabCard)
  }

  func end() {
    dismiss()
    input = nil
    NativeMediaStack.stopListening(mediaListener)
    mediaListener = nil
    motion.removeFromSuperview()
    if let liveObserver { NotificationCenter.default.removeObserver(liveObserver) }
    liveObserver = nil
  }

  func show(_ card: [String: Any]?) {
    attachment = nil
    input = card
    guard let card, var kind = card["kind"] as? String else {
      guard motion.content != nil else { tabCardInput = nil; return }
      if kind == "group" { groupCard.live = false }
      tabCardInput = nil
      motion.hide()
      return coverChanged()
    }
    guard let overlay = NativeWindowShell.overlay(windowId) ?? WindowHost.contentView(windowId) else { return }
    if motion.superview !== overlay {
      motion.frame = overlay.bounds
      overlay.addSubview(motion)
    }
    let placed: (view: NSView, origin: CGPoint)?
    if kind == "tab", let decoded = SidebarTabCardState.decode(card),
      let state = WorkspaceWrites.store?.state,
      let player = NativeMediaStack.hoverPlayer(tabId: decoded.tabId, state: state, windowId: windowId) {
      kind = "player"
      playerCard.set(player)
      let edge = max(decoded.anchorRect.maxX, decoded.sidebarWidth - (card["sidebarInset"] as? Double ?? 0))
      placed = (playerCard, HoverCardMotion.origin(anchor: decoded.anchorRect, edge: edge))
    } else {
      placed = place(kind, card)
    }
    guard let placed else {
      motion.hide()
      return coverChanged()
    }
    if self.kind == "group", kind != "group" { groupCard.live = false }
    if kind != "tab" { tabCardInput = nil }
    self.kind = kind
    var origin = placed.origin
    if let host = NativeWindowShell.host(windowId), host.ownsNativeLayout, host.shell.input.sidebarSide == .right,
      let values = card["anchor"] as? [Double], values.count == 4 {
      var anchor = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      let sidebar = host.shell.frames.sidebarCoverage(in: host.shell.bounds)
      let tabAtEdge = kind == "tab" && sidebar.map { anchor.minX >= $0.minX - 1 } == true
      if tabAtEdge, let sidebar { anchor.origin.x = sidebar.minX }
      let gap: CGFloat = tabAtEdge ? 0.5 : 8
      attachment = (anchor, placed.origin.y, gap)
      origin = SidebarAttachment.origin(anchor: anchor, size: placed.view.frame.size,
        visible: host.shell.bounds, side: .right, gap: gap, preferredY: placed.origin.y)
    }
    motion.show(placed.view, origin: origin)
    coverChanged()
    DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardMotion.fadeDuration) { [weak self] in self?.coverChanged() }
  }

  private func place(_ kind: String, _ card: [String: Any]) -> (view: NSView, origin: CGPoint)? {
    switch kind {
    case "tab":
      guard let decoded = SidebarTabCardState.decode(card) else { return nil }
      var state = inline ? decoded : decoded.offeringSleep(heavy: HeavyTabs.current[decoded.tabId], canSleep: HeavyTabs.sleep != nil)
      let pip = NowPlayingStore.shared.pictureInPicture[state.tabId] != nil
      if pip || NowPlayingStore.shared.entries[state.tabId]?.report.hasVideo == true {
        let index = state.buttons.firstIndex { $0.action == "back" || $0.action == "sleepHeavy" } ?? state.buttons.endIndex
        state.buttons.insert(.init(action: "pip", icon: pip ? "pip.exit" : "pip.enter",
          label: pip ? "Exit Picture in Picture" : "Picture in Picture"), at: index)
      }
      let memoryEnabled = !inline && NativeTabMemory.enabled
      let memoryKey = TabMemoryKey.key(tabId: state.tabId, document: NativeTabMemory.document(state.tabId) ?? "")
      let fresh = motion.phase == .hidden || motion.phase == .leaving || self.kind != "tab" || tabCardId != memoryKey
      tabCardId = memoryKey
      tabCardInput = card
      tabCard.set(state)
      if fresh && memoryEnabled {
        NativeTabMemory.cache.ask(memoryKey) { [weak self] key in
          Task { @MainActor [weak self] in
            guard let self, self.kind == "tab", self.motion.phase != .leaving, self.motion.phase != .hidden,
              self.tabCardId == key, let input = self.tabCardInput
            else { return }
            self.show(input)
          }
        }
      }
      tabCard.setMemory(memoryEnabled ? NativeTabMemory.cache.row(memoryKey, sleeping: state.sleeping) : .absent)
      return (tabCard, SidebarTabCardMetrics.origin(anchor: state.anchorRect, sidebarWidth: state.sidebarWidth, cardHeight: tabCard.height, windowHeight: state.windowHeight))
    case "group":
      guard let state = Self.decode(SidebarGroupCardState.self, card) else { return nil }
      groupCard.live = true
      groupCard.set(state)
      return (groupCard, SidebarGroupCardMetrics.origin(anchor: state.anchorRect, height: groupCard.frame.height, windowHeight: state.windowHeight))
    case "calendar":
      guard let tabId = card["tabId"] as? String, let json = card["state"] as? String, let data = json.data(using: .utf8),
        let state = try? JSONDecoder().decode(LiveCardModel.State.self, from: data),
        let lookValue = card["look"] as? [String: Any], let look = Self.decode(SidebarSurfaceLook.self, lookValue),
        let anchor = card["anchor"] as? [Double], anchor.count == 4
      else { return nil }
      calendarCard.set(tabId: tabId, state: state, look: look)
      return (calendarCard, HoverCardMotion.origin(anchor: CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])))
    case "live":
      guard let state = Self.liveState(card) else { return nil }
      liveCard.set(state)
      return (liveCard, HoverCardMotion.origin(anchor: state.anchorRect))
    case "folder":
      guard let state = Self.decode(SidebarFolderPeekState.self, card) else { return nil }
      folderPeek.set(state)
      return (folderPeek, HoverCardMotion.origin(anchor: state.anchorRect))
    default:
      return nil
    }
  }

  private static func liveState(_ card: [String: Any]) -> SidebarLiveCardState? {
    guard let id = card["id"] as? String, let anchor = card["anchor"] as? [Double],
      let lookValue = card["look"] as? [String: Any], let look = decode(SidebarLiveCardState.Look.self, lookValue)
    else { return nil }
    let key = SidebarLiveCardState.itemKey(id)
    guard let item = SidebarLiveFeed.shared.live?.state.items[key.folderId]?.first(where: { $0.id == key.itemId }) else { return nil }
    return SidebarLiveCardState(id: id, item: item, anchor: anchor, look: look, now: Date().timeIntervalSince1970 * 1000)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  fileprivate func row(_ next: SidebarHoverTarget?) {
    guard next != target else { return }
    target = next
    if onCard || held { return }
    schedule()
  }

  private func schedule() {
    timer?.invalidate()
    timer = nil
    if let target, shown == target { return }
    if let target, shown != nil {
      present(target)
    } else {
      let timer = Timer(timeInterval: target == nil ? 0.16 : 0.5, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.timer = nil
          if let target = self.target { self.present(target) }
          else { self.dismiss() }
        }
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func hold(_ on: Bool) {
    held = on
    if on {
      timer?.invalidate()
      timer = nil
    } else if !onCard { schedule() }
  }

  private func pointer(_ inside: Bool) {
    guard onCard != inside, !inside || shown != nil else { return }
    onCard = inside
    #if DEBUG
    Task { @MainActor in
      _ = await SettingsAdapters.js("sidebar.hoverProbe", windowId, ["pointer": inside])
    }
    #endif
    NativeLayoutChrome.transientHold(windowId, reason: "sidebarHover", held: inside)
    if inside {
      timer?.invalidate()
      timer = nil
    } else if !held && shown != nil { schedule() }
  }

  func dismiss() {
    timer?.invalidate()
    timer = nil
    target = nil
    if shown != nil { publishProbe(nil, anchor: nil) }
    shown = nil
    held = false
    pointer(false)
    timer?.invalidate()
    timer = nil
    show(nil)
  }

  func refresh() {
    if let shown { present(shown) }
  }

  private func present(_ target: SidebarHoverTarget) {
    guard let store = WorkspaceWrites.store, let window = store.state.windows[windowId],
      !store.memory.closingWindows.contains(windowId),
      store.state.windowUi[windowId]?.json["panel"]?["open"]?.truthy != true,
      NativeWorkspaceRename.override(windowId).flatMap({ $0 }) == nil,
      !NativeSidebarIconPicker.isOpen(windowId),
      let anchor = NativeSidebar.rowFrame(windowId: windowId, key: target.id),
      let root = WindowHost.contentView(windowId),
      let card = cardInput(target, anchor: anchor, window: window, height: root.bounds.height, state: store.state)
    else { return dismiss() }
    if shown != target { publishProbe(target, anchor: anchor) }
    shown = target
    if let input, NSDictionary(dictionary: input).isEqual(to: card) { return }
    show(card)
  }

  private func publishProbe(_ target: SidebarHoverTarget?, anchor: [String: Double]?) {
    #if DEBUG
    let payload = SidebarPayload(["kind": target?.kind ?? NSNull(), "id": target?.id ?? NSNull(), "anchor": anchor as Any? ?? NSNull()])
    Task { @MainActor in
      _ = await SettingsAdapters.js("sidebar.hoverProbe", windowId, payload.value)
    }
    #endif
  }

  private func dispatch(_ command: Command) {
    guard let store = WorkspaceWrites.store, store.state.windows[windowId] != nil,
      !store.memory.closingWindows.contains(windowId) else { return }
    _ = try? store.dispatch(command, origin: .native)
    FrameUpdates.flush()
  }

  private func choose(_ tabId: String) {
    guard let tab = WorkspaceWrites.store?.state.tabs[tabId], tab.windowId == windowId else { return }
    dismiss()
    dispatch(TileFolderPanel.plainClick(windowId: windowId, tabId: tabId))
  }

  private func tabAction(_ action: String, id: String) {
    guard let store = WorkspaceWrites.store, let tab = store.state.tabs[id], tab.windowId == windowId else { return }
    switch action {
    case "pin": dispatch(Command("togglePin", [.string(id)]))
    case "bookmark":
      NativeBookmarkCommands.toggle(tab, profile: store.state.bookmarkProfileId(store.state.windows[windowId]), windowId: windowId, store: store)
    case "split":
      guard let anchor = store.state.activeTabId(windowId), anchor != id else { return }
      dismiss()
      dispatch(Command("openSplitPane", [.string(windowId), ["tabId": .string(id), "anchorTabId": .string(anchor), "side": "right"]]))
    case "back":
      dismiss()
      NativePinnedPageCommands.request("returnToPinnedUrl", tabId: id)
    default: break
    }
  }

  private func cardInput(_ target: SidebarHoverTarget, anchor: [String: Double], window: BrowserWindow,
    height: Double, state: BrowserState) -> [String: Any]?
  {
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let dark = look.dark
    var theme = look.tokens
    theme["placeholder"] = dark ? "#FFFFFF59" : "#00000059"
    let frame = [anchor["x"] ?? 0, anchor["y"] ?? 0, anchor["width"] ?? 0, anchor["height"] ?? 0]
    var result: [String: Any] = ["kind": target.kind, "anchor": frame, "windowHeight": height, "dark": dark, "theme": theme]
    let width = NativeSidebar.hosts[windowId]?.view.frame.width ?? 0
    let shadow = look.panel.shadowOpacity
    func row(_ tab: Tab) -> [String: Any] {
      ["id": tab.id, "title": TileFolderPanel.title(tab), "url": tab.url, "usedAt": tab.lastActiveAt,
       "favicon": tab.favicon as Any? ?? NSNull(), "icon": tab.customIcon as Any? ?? NSNull(), "profileId": tab.profileId]
    }
    switch target.kind {
    case "tab":
      guard let tab = state.tabs[target.id], tab.windowId == windowId, tab.profileId == window.profileId else { return nil }
      if !window.incognito, tab.pinned, Meetings.isCalendarUrl(tab.pinnedUrl ?? tab.url),
        let preview = NativeSidebarLive.calendarPreview(tabId: tab.id, dark: dark) {
        result["kind"] = "calendar"
        result["tabId"] = tab.id
        result["state"] = preview
        result["look"] = ["dark": dark, "panel": theme["panel"]!, "panelBorder": theme["panelBorder"]!, "shadowOpacity": shadow]
        break
      }
      let catalog = NativeHistoryCatalog.catalog.bookmarks(engineProfile: state.engineProfile(state.bookmarkProfileId(window)))
      let bookmarked = catalog.nodes.values.contains { $0.kind == "url" && $0.url?.utf16.elementsEqual(tab.url.utf16) == true }
      let buttons = SidebarTabCardState.actions(for: tab, active: state.activeTabId(windowId) == tab.id, bookmarked: bookmarked)
      let host = URL(string: tab.url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
      result["tabId"] = tab.id
      result["title"] = TileFolderPanel.title(tab)
      result["host"] = tab.url.isEmpty ? nil : host ?? displayUrl(tab.url)
      result["sleeping"] = state.live[tab.id]?.discarded == true
      result["buttons"] = buttons.map { ["action": $0.action, "icon": $0.icon, "label": $0.label] }
      result["sidebarWidth"] = width
      result["sidebarInset"] = 6
      result["look"] = [
        "fill": dark ? "#262626" : theme["panel"]!, "border": dark ? "#404040" : theme["panelBorder"]!,
        "primary": dark ? "#FFFFFFDB" : theme["textPrimary"]!, "secondary": dark ? "#FFFFFF95" : theme["textSecondary"]!,
        "tertiary": theme["textTertiary"]!, "hover": theme["toolbarHover"]!, "pressed": theme["toolbarPressed"]!, "shadowOpacity": shadow,
      ]
    case "group":
      guard let group = state.groups[target.id], group.windowId == windowId, group.profileId == window.profileId else { return nil }
      result["groupId"] = group.id
      result["rows"] = SidebarGroupCardState.members(state, groupId: group.id, windowId: windowId).map(row)
    case "folder":
      guard NativeTileFolders.openFolder(windowId) != target.id else { return nil }
      let rows = SidebarQuery(state).folderMembers(windowId: windowId, target.id).compactMap { state.tabs[$0] }
      guard !rows.isEmpty else { return nil }
      result["folderId"] = target.id
      result["title"] = "\(TileFolderPanel.label(state, windowId: windowId, folderId: target.id)) · \(rows.count) \(rows.count == 1 ? "tab" : "tabs")"
      result["rows"] = rows.prefix(8).map(row)
      result["more"] = rows.count > 8 ? "and \(rows.count - 8) more" : nil
      result["shadowOpacity"] = shadow
    case "live":
      guard !window.incognito else { return nil }
      var liveLook: [String: Any] = theme
      liveLook["dark"] = dark
      liveLook["shadowOpacity"] = shadow
      liveLook["urlPill"] = dark ? "#FFFFFF12" : "#0000000D"
      liveLook["success"] = dark ? "#3FB950" : "#1A7F37"
      liveLook["failure"] = dark ? "#F85149" : "#CF222E"
      liveLook["pending"] = dark ? "#D29922" : "#9A6700"
      liveLook["draft"] = dark ? "#8B949E" : "#6E7781"
      liveLook["conflict"] = dark ? "#DB6D28" : "#BC4C00"
      liveLook["ciTrack"] = dark ? "#FFFFFF1A" : "#00000014"
      result["id"] = target.id
      result["look"] = liveLook
    default:
      return nil
    }
    return result
  }

  func describe() -> [String: Any] {
    var info: [String: Any] = ["target": shown?.id ?? NSNull(), "pointerRow": target?.id ?? NSNull(), "pointerOnCard": onCard, "kind": kind ?? NSNull(), "phase": motion.phase.rawValue, "opacity": motion.presentedOpacity, "scale": motion.scaleValue()]
    if let content = motion.content, let window = content.window, let root = window.contentView {
      let r = content.convert(content.bounds, to: nil)
      info["frame"] = [r.minX, root.bounds.height - r.maxY, r.width, r.height]
      info["inWindow"] = root.bounds.contains(r)
      info["typingInCard"] = (window.firstResponder as? NSView)?.isDescendant(of: content) ?? false
      info["onScreen"] = window.isVisible && !content.isHiddenOrHasHiddenAncestor && motion.superview != nil
      var buttons: [String: [Double]] = [:]
      func walk(_ view: NSView) {
        if view.accessibilityRole() == .button, let label = view.accessibilityLabel(), !label.isEmpty {
          let b = view.convert(view.bounds, to: nil)
          buttons[label] = [b.minX, root.bounds.height - b.maxY, b.width, b.height]
        }
        view.subviews.forEach(walk)
      }
      walk(content)
      info["buttons"] = buttons
      if kind == "tab", let look = tabCard.state?.look {
        info["fill"] = look.fill
        info["glass"] = tabCard.usesGlass
        info["titleShown"] = tabCard.titleShown
        info["memory"] = tabCard.memoryShown ?? NSNull()
      }
      if kind == "group" { info["rows"] = groupCard.state?.rows.map(\.id) ?? [] }
      if kind == "folder" { info["title"] = folderPeek.state?.title ?? ""; info["more"] = folderPeek.state?.more ?? NSNull() }
      if kind == "calendar" {
        let card = CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
        info["events"] = Dictionary(uniqueKeysWithValues: PageProbe.items.values.filter { $0.label.hasPrefix("event:") && card.contains($0.frame) }.map { ($0.label, [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]) })
      }
    }
    return info
  }
}

@MainActor
enum NativeSidebarIconPicker {
  private static var hosts: [String: SidebarIconPickerHost] = [:]

  static func open(windowId: String, kind: String, id: String) {
    guard let store = WorkspaceWrites.store, let window = store.state.windows[windowId],
      !store.memory.closingWindows.contains(windowId),
      let overlay = NativeWindowShell.overlay(windowId) ?? WindowHost.contentView(windowId) else { return }
    let current: String?
    switch kind {
    case "tab":
      guard let tab = store.state.tabs[id], tab.windowId == windowId else { return }
      current = tab.customIcon
    case "group":
      guard let group = store.state.groups[id], group.windowId == windowId else { return }
      current = group.icon
    case "live":
      guard !window.incognito,
        let folder = SidebarLiveFeed.shared.live?.state.folders[String(id.dropFirst("livefolder|".count))],
        folder.profileId == window.profileId else { return }
      current = folder.icon
    default: return
    }
    let look = NativeLayoutAppearance(state: store.state, profileId: window.profileId, incognito: window.incognito)
    var theme = look.tokens
    theme["placeholder"] = look.dark ? "#FFFFFF5C" : "#00000059"
    theme["urlPill"] = look.dark ? "#FFFFFF12" : "#0000000D"
    theme["pickerCellHover"] = look.dark ? "#FFFFFF1A" : "#0000000F"
    theme["noGroupIconInk"] = look.dark ? "#FFFFFF80" : "#00000080"
    let anchor = NativeSidebar.rowFrame(windowId: windowId, key: id).map {
      [$0["x"] ?? 0, $0["y"] ?? 0, $0["width"] ?? 0, $0["height"] ?? 0]
    }
    let width = SidebarRail.effectiveWidth(window, store.state.settings)
    let state = SidebarIconPickerState(id: id, kind: kind, current: current, anchor: anchor, sidebarWidth: width,
      dark: look.dark, shadowOpacity: look.panel.shadowOpacity, theme: theme)
    NativeSidebarHoverCard.dismiss(windowId)
    let host = hosts[windowId] ?? SidebarIconPickerHost(windowId: windowId)
    hosts[windowId] = host
    host.show(state, in: overlay, store: store)
    NativeLayoutChrome.transientHold(windowId, reason: "sidebarIcon", held: true)
  }

  static func close(_ windowId: String) {
    hosts.removeValue(forKey: windowId)?.hide()
    NativeLayoutChrome.transientHold(windowId, reason: "sidebarIcon", held: false)
  }

  static func isOpen(_ windowId: String) -> Bool { hosts[windowId]?.describe() != nil }

  static func describe(_ windowId: String) -> String {
    guard let info = hosts[windowId]?.describe(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  static func devInput(_ windowId: String, _ action: String) { hosts[windowId]?.devInput(action) }


}

#if SOLARA_PROBES
@MainActor
public enum SidebarIconPickerRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let data = NativeSidebarIconPicker.describe(windowId).data(using: .utf8),
      let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return ["panel": source["panel"] ?? NSNull(), "tab": source["tab"] ?? NSNull(),
      "focused": source["focused"] ?? NSNull(), "items": source["items"] ?? NSNull(),
      "first": source["first"] ?? NSNull(), "hovered": source["hovered"] ?? NSNull(),
      "footer": source["footer"] ?? NSNull(), "section": source["section"] ?? NSNull()]
  }
}
#endif

@MainActor
final class SidebarIconPickerHost {
  let windowId: String
  private let view = SidebarIconPickerView()
  private weak var store: Store?

  init(windowId: String) {
    self.windowId = windowId
    view.autoresizingMask = [.width, .height]
    view.onEvent = { [weak self] event in self?.receive(event) }
  }

  private func receive(_ event: SidebarIconPickerView.Event) {
    guard let state = view.state else { return }
    defer { NativeSidebarIconPicker.close(windowId) }
    guard case .choose(let icon) = event, let store, WorkspaceWrites.store === store,
      let window = store.state.windows[windowId], !store.memory.closingWindows.contains(windowId) else { return }
    let value = icon.map(JSONValue.string) ?? .null
    let id = state.id
    let command: Command
    switch state.kind {
    case "tab":
      guard store.state.tabs[id]?.windowId == windowId else { return }
      command = Command("updateTab", [.string(id), ["customIcon": value]])
    case "group":
      guard store.state.groups[id]?.windowId == windowId else { return }
      command = Command("updateGroup", [.string(id), ["icon": value]])
    case "live":
      let folderId = String(id.dropFirst("livefolder|".count))
      guard !window.incognito, SidebarLiveFeed.shared.live?.state.folders[folderId]?.profileId == window.profileId else { return }
      NativeSidebarLive.perform(.updateFolder(.object([
        "folderId": .string(folderId), "patch": .object(["icon": icon.map(LiveAnyJSON.string) ?? .null]),
      ])))
      return
    default: return
    }
    _ = try? store.dispatch(command, origin: .native)
    FrameUpdates.flush()
  }

  func show(_ state: SidebarIconPickerState, in overlay: NSView, store: Store) {
    self.store = store
    let opening = view.superview !== overlay
    if opening {
      view.frame = overlay.bounds
      overlay.addSubview(view)
    }
    view.set(state)
    if opening { view.focus() }
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  func hide() {
    guard view.superview != nil else { return }
    let focused = view.isEditing
    let window = view.window
    view.removeFromSuperview()
    if focused { window?.makeFirstResponder(nil) }
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  func devInput(_ action: String) { view.devInput(action) }

  func describe() -> [String: Any]? {
    guard view.superview != nil else { return nil }
    return view.describe()
  }
}

#if SOLARA_PROBES
@MainActor
private enum SidebarHoverPresentationTrace {
  private static var sequence = 0
  private static var samples: [String: [[String: Any]]] = [:]

  static func record(windowId: String, source: [String: Any]) -> Int {
    sequence += 1
    let sample: [String: Any] = ["sequence": sequence, "atNs": DispatchTime.now().uptimeNanoseconds,
      "opacity": source["opacity"] ?? NSNull(), "scale": source["scale"] ?? NSNull(), "rect": source["rect"] ?? NSNull()]
    var records = samples[windowId] ?? []
    records.append(sample)
    if records.count > 128 { records.removeFirst(records.count - 128) }
    samples[windowId] = records
    return sequence
  }

  static func read(windowId: String) -> [[String: Any]] { samples[windowId] ?? [] }

}

@MainActor
public enum SidebarHoverCardRead {
  public static func trace(windowId: String) -> [[String: Any]] { SidebarHoverPresentationTrace.read(windowId: windowId) }

  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let data = NativeSidebarHoverCard.describe(windowId).data(using: .utf8) else { return nil }
    guard let source = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var result: [String: Any] = [:]
    for key in ["kind", "phase", "opacity", "scale", "frame", "inWindow", "onScreen", "typingInCard", "buttons", "titleShown", "memory", "rows", "title", "more", "events"] { result[key] = source[key] }
    return result
  }

  public static func presentation(windowId: String, sample: [Double]) -> [String: Any]? {
    guard sample.count == 6,
      let data = NativeSidebarHoverCard.presented(windowId, at: CGPoint(x: sample[0], y: sample[1]), width: sample[2]...sample[3], height: sample[4]...sample[5]).data(using: .utf8),
      let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return ["opacity": source["opacity"] ?? NSNull(), "scale": source["scale"] ?? NSNull(), "rect": source["rect"] ?? NSNull()]
  }
}
#endif
