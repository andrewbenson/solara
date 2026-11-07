import AppKit
import Foundation
import SolaraLive
import SolaraModel
import SolaraUI

@MainActor
enum NativeSidebarHoverCard {
  static let topic = "sidebar.hoverCard"
  private static var observer: UUID?
  private static var hosts: [String: SidebarHoverCardHost] = [:]

  static func start() {
    guard NativeWindowShell.enabled, observer == nil else { return }
    NativeTabMemory.installEngineQuery()
    NativeHeavyTabs.start()
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil { host.show(nil) }
    for (windowId, card) in windows {
      let host = hosts[windowId] ?? SidebarHoverCardHost(windowId: windowId)
      hosts[windowId] = host
      host.show(card as? [String: Any])
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let info = hosts[windowId]?.describe(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  static func players(windowId: String) -> [NSView] { hosts[windowId]?.shownPlayers ?? [] }

  static func presented(_ windowId: String, at point: CGPoint, width: ClosedRange<Double>, height: ClosedRange<Double>) -> String {
    guard let view = NativeSidebar.hosts[windowId]?.view.window?.contentView, let root = view.layer?.presentation() ?? view.layer else { return "null" }
    let flipped = view.isFlipped || root.isGeometryFlipped
    let local = CGPoint(x: point.x, y: flipped ? point.y : root.bounds.height - point.y)
    func find(_ layer: CALayer) -> CALayer? {
      for sub in layer.sublayers ?? [] {
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
  static func send(_ windowId: String, _ id: String, _ event: String, _ extra: [String: Any] = [:]) {
    var payload = extra
    if payload["clickAt"] == nil {
      payload["clickAt"] = NSApp.currentEvent.map { $0.type == .leftMouseUp ? $0.timestamp * 1000 : 0 } ?? 0
    }
    let sendable = MediaPayload(payload)
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, id, event, sendable.value)
    }
  }
}

@MainActor
final class SidebarHoverCardHost {
  let windowId: String
  private let motion = HoverCardView()
  private lazy var tabCard: SidebarTabCardView = {
    let card = SidebarTabCardView()
    card.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      if action == SidebarTabCardState.Button.sleepHeavy.action {
        Task { @MainActor in _ = await HeavyTabs.sleep?(id) }
        return
      }
      NativeSidebarHoverCard.send(self.windowId, id, action)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var groupCard: SidebarGroupCardView = {
    let card = SidebarGroupCardView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.onEvent = { [weak self, weak card] event in
      guard let self, let id = card?.state?.groupId else { return }
      switch event {
      case .choose(let tabId): NativeSidebarHoverCard.send(self.windowId, id, "choose", ["tabId": tabId])
      case .close: NativeSidebarHoverCard.send(self.windowId, id, "close")
      case .hold(let on): NativeSidebarHoverCard.send(self.windowId, id, on ? "hold" : "release")
      case .focusPage: NativeSidebarHoverCard.send(self.windowId, id, "focusPage")
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
      case .openItem: NativeSidebarHoverCard.send(self.windowId, id, "openItem")
      case .open(let url): NativeSidebarHoverCard.send(self.windowId, id, "open", ["url": url])
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.coverChanged() }
    return card
  }()
  private lazy var playerCard: HoverPlayerCardView = {
    let card = HoverPlayerCardView()
    card.player.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      NativeMedia.player("hoverPlayer", self.windowId, id, action)
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
      case .activate: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "activate"])
      case .join(let id, _): NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "join", "eventId": id])
      case .refresh: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "refresh"])
      case .connect: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "connect"])
      case .height, .dismiss, .view: break
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.coverChanged() }
    return card
  }()
  private lazy var folderPeek: SidebarFolderPeekView = {
    let card = SidebarFolderPeekView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.onChoose = { [weak self, weak card] tabId in
      guard let self, let id = card?.state?.folderId else { return }
      NativeSidebarHoverCard.send(self.windowId, id, "choose", ["tabId": tabId])
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private var kind: String?
  private var tabCardId: String?
  private var tabCardInput: [String: Any]?

  var shownPlayers: [NSView] { kind == "player" && motion.phase != .hidden ? [playerCard.player] : [] }
  private var liveCardInput: [String: Any]?
  private var liveObserver: NSObjectProtocol?

  init(windowId: String) {
    self.windowId = windowId
    motion.autoresizingMask = [.width, .height]
    motion.onHidden = { [weak self] in self?.coverChanged() }
    liveObserver = NotificationCenter.default.addObserver(forName: SidebarLiveFeed.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.liveChanged() }
    }
  }

  private func liveChanged() {
    guard kind == "live", motion.phase != .leaving, motion.phase != .hidden, let card = liveCardInput else { return }
    show(card)
  }

  private func coverChanged() {
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  func show(_ card: [String: Any]?) {
    guard let card, let kind = card["kind"] as? String else {
      if kind == "group" { groupCard.live = false }
      tabCardInput = nil
      motion.hide()
      return coverChanged()
    }
    guard let overlay = NativeWindowShell.overlay(windowId) else { return }
    if motion.superview !== overlay {
      motion.frame = overlay.bounds
      overlay.addSubview(motion)
    }
    guard let placed = place(kind, card) else {
      motion.hide()
      return coverChanged()
    }
    if self.kind == "group", kind != "group" { groupCard.live = false }
    if kind != "tab" { tabCardInput = nil }
    self.kind = kind
    motion.show(placed.view, origin: placed.origin)
    NativeSidebarHoverCard.send(windowId, "", "layout", ["frame": [placed.origin.x, placed.origin.y, placed.view.frame.width, placed.view.frame.height]])
    coverChanged()
    DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardMotion.fadeDuration) { [weak self] in self?.coverChanged() }
  }

  private func place(_ kind: String, _ card: [String: Any]) -> (view: NSView, origin: CGPoint)? {
    switch kind {
    case "tab":
      guard let decoded = SidebarTabCardState.decode(card) else { return nil }
      let state = decoded.offeringSleep(heavy: HeavyTabs.current[decoded.tabId], canSleep: HeavyTabs.sleep != nil)
      let memoryEnabled = NativeTabMemory.enabled
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
    case "player":
      guard let json = card["state"] as? String, let state = MediaPlayerState.decode(json), let anchor = card["anchor"] as? [Double], anchor.count == 4 else { return nil }
      playerCard.set(state)
      let edge = card["edge"] as? Double ?? anchor[0] + anchor[2]
      return (playerCard, HoverCardMotion.origin(anchor: CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]), edge: edge))
    case "calendar":
      guard let tabId = card["tabId"] as? String, let json = card["state"] as? String, let data = json.data(using: .utf8),
        let state = try? JSONDecoder().decode(LiveCardModel.State.self, from: data),
        let lookValue = card["look"] as? [String: Any], let look = Self.decode(SidebarSurfaceLook.self, lookValue),
        let anchor = card["anchor"] as? [Double], anchor.count == 4
      else { return nil }
      calendarCard.set(tabId: tabId, state: state, look: look)
      return (calendarCard, HoverCardMotion.origin(anchor: CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])))
    case "live":
      liveCardInput = card
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

  private func pointer(_ inside: Bool) {
    NativeSidebarHoverCard.send(windowId, "", inside ? "enter" : "leave")
  }

  func describe() -> [String: Any] {
    var info: [String: Any] = ["kind": kind ?? NSNull(), "phase": motion.phase.rawValue, "opacity": motion.presentedOpacity, "scale": motion.scaleValue()]
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
  static let topic = "sidebar.iconPicker"
  private static var observer: UUID?
  private static var hosts: [String: SidebarIconPickerHost] = [:]

  static func register() {
    guard observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil { host.show(nil) }
    for (windowId, state) in windows {
      let host = hosts[windowId] ?? SidebarIconPickerHost(windowId: windowId)
      hosts[windowId] = host
      host.show(state as? [String: Any])
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let info = hosts[windowId]?.describe(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  static func devInput(_ windowId: String, _ action: String) { hosts[windowId]?.devInput(action) }

  static func send(_ windowId: String, _ id: String, _ event: String, _ extra: [String: Any] = [:]) {
    let sendable = MediaPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, id, event, sendable.value)
    }
  }
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

  init(windowId: String) {
    self.windowId = windowId
    view.autoresizingMask = [.width, .height]
    view.onEvent = { [weak self] event in
      guard let self, let id = self.view.state?.id else { return }
      switch event {
      case .choose(let icon): NativeSidebarIconPicker.send(self.windowId, id, "choose", ["icon": icon ?? NSNull()])
      case .close: NativeSidebarIconPicker.send(self.windowId, id, "close")
      }
    }
  }

  func show(_ input: [String: Any]?) {
    guard let input, let data = try? JSONSerialization.data(withJSONObject: input),
      let state = try? JSONDecoder().decode(SidebarIconPickerState.self, from: data),
      let overlay = NativeWindowShell.overlay(windowId)
    else { return hide() }
    let opening = view.superview !== overlay
    if opening {
      view.frame = overlay.bounds
      overlay.addSubview(view)
    }
    view.set(state)
    if opening { view.focus() }
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  private func hide() {
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
