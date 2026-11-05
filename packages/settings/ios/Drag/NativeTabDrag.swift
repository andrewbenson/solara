import AppKit
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeTabDrag {
  static let shared = NativeTabDrag()
  static let endDeadline: Double = 2
  static let replyMargin: Double = 0.5

  private var chain: Task<Void, Never>?
  private var pendingMove: [Any]?
  private var picture: (chip: () -> NSRect, grab: CGPoint)?
  private var pointer = CGPoint.zero
  private var lifted: Bool?
  private var outside = false
  private var overWindow: String?
  private var jsOnPage = false
  private var zoneOnPage = false
  private var onPage: Bool { jsOnPage || zoneOnPage }
  private var insert = false
  private var zoneInsert: String??
  private var shape = "hidden"
  private var previewShown = false
  private var previewToken = 0
  private var closing: (() -> Bool)?
  private var owned = false
  private(set) var lastDrop: [String: Any] = [:]

  func send(_ name: String, _ args: [Any], done: (@MainActor (Any?) -> Void)? = nil) {
    let previous = chain
    let payload = SidebarPayload(["args": args])
    chain = Task { @MainActor in
      await previous?.value
      let args = payload.value["args"] as? [Any] ?? []
      let result: Any?
      do {
        result = try await SettingsJS.shared.invoke(name, args)
      } catch {
        result = nil
      }
      done?(result)
    }
  }

  func begin(windowId: String, tabId: String?, tabIds: [String], closing: @escaping () -> Bool) {
    pendingMove = nil
    clearDrag()
    TabDragSession.windowIdOf = { [weak self] window in
      guard let id = ShellDrag.windowId(of: window), let source = TabDragSession.current?.sourceWindow else { return nil }
      return id == source || self?.accepts(id, from: source) == true ? id : nil
    }
    TabDragSession.windowOf = { ShellDrag.window($0) }
    self.closing = closing
    owned = Self.ownsDrop(windowId)
    let session = TabDragSession.begin(tabIds: tabIds, from: windowId)
    session.sourceClosing = { [weak self] in self?.sourceClosing(windowId) }
    session.reaim = { [weak self] in
      guard let self else { return }
      self.move(windowId: windowId, at: self.pointer, lifted: self.lifted)
    }
    send("tabDrag.begin", [windowId, tabId ?? NSNull(), tabIds, owned])
  }

  func picture(windowId: String, chip: @escaping () -> NSRect, grab: CGPoint) {
    picture = (chip, grab)
    syncPreview(windowId)
  }

  func move(windowId: String, at point: CGPoint, lifted: Bool? = nil) {
    pointer = point
    self.lifted = lifted
    var over: String?
    var overPoint = CGPoint.zero
    if let session = session(windowId), let window = ShellDrag.window(windowId) {
      session.lifted = lifted
      session.move(screenPoint: CGPoint(x: window.frame.minX + point.x, y: window.frame.maxY - point.y))
      outside = session.outside
      zoneOnPage = session.aim.map(Self.onPage) ?? false
      if case .insert(let beforeId) = session.aim { zoneInsert = .some(beforeId) } else { zoneInsert = .none }
      if outside, let id = session.overWindow {
        over = id
        overPoint = session.point(in: id) ?? .zero
      }
    }
    overWindow = over
    publish()
    syncPreview(windowId)
    let queued = pendingMove != nil
    let zoneBefore: Any = zoneInsert.map { $0.map { $0 as Any } ?? NSNull() } ?? false
    let zoneTarget: Any = TabDragSession.current.flatMap { if case .split(let tabId, let side) = $0.aim { [tabId, side.rawValue] } else { nil } } ?? NSNull()
    pendingMove = [windowId, point.x, point.y, outside, over ?? NSNull(), overPoint.x, overPoint.y, lifted ?? NSNull(), zoneBefore, owned ? zoneOnPage : NSNull(), zoneTarget]
    if queued { return }
    let previous = chain
    chain = Task { @MainActor in
      await previous?.value
      guard let move = self.pendingMove else { return }
      self.pendingMove = nil
      _ = try? await SettingsJS.shared.invoke("tabDrag.move", move)
    }
  }

  func end(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    let session = session(windowId)
    let preview: Int? = previewShown ? previewToken : nil
    let tabIds = session?.tabIds ?? []
    let zoned = commit ? session?.end() ?? false : false
    let bookmarkDrop = commit && session?.endedAim == .bookmarks
    if !commit { session?.cancel() }
    let outside = session?.outside ?? self.outside
    let over = outside ? session?.overWindow : nil
    let zonePage = session?.endedAim.map(Self.onPage) ?? false
    let liftedPage = !outside && lifted == true
    let screen = session?.pointer
    let owned = self.owned
    clearDrag()
    let reply = EndReply()
    let finish: @MainActor (_ end: [String: Any]?) -> Void = { [weak self] end in
      guard let self else { return done(false) }
      let unanswered = !owned && end == nil
      guard commit else {
        self.endPreview(preview, cancel: true)
        return done(false)
      }
      if zoned || bookmarkDrop || end?["split"] as? Bool == true {
        self.endPreview(preview)
        if zoned, let over, self.open(over) { self.focus(over) }
        return done(true)
      }
      let onPage = !outside && (zonePage || liftedPage || end?["onPage"] as? Bool == true)
      self.lastDrop = [
        "outside": outside, "over": over ?? NSNull(), "zonePage": zonePage, "jsOnPage": end?["onPage"] ?? NSNull(), "jsPointer": end?["pointer"] ?? NSNull(),
        "timedOut": unanswered, "owned": owned, "screen": screen.map { [$0.x, $0.y] } ?? NSNull(), "source": ShellDrag.window(windowId).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? NSNull(),
      ]
      guard outside || (onPage && !unanswered), let screen else {
        self.endPreview(preview, cancel: unanswered)
        return done(false)
      }
      let before: String?? = end?["insert"] as? Bool == true ? .some(end?["before"] as? String) : .none
      self.dropOutside(tabIds, from: windowId, at: screen, over: over.flatMap { self.open($0) ? $0 : nil }, before: before, preview: preview)
      done(true)
    }
    if owned {
      send("tabDrag.end", [windowId, false])
      return finish(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDeadline) {
      MainActor.assumeIsolated {
        guard reply.open() else { return }
        finish(nil)
      }
    }
    let deadline = (Date().timeIntervalSince1970 + Self.endDeadline - Self.replyMargin) * 1000
    send("tabDrag.end", [windowId, commit && !zoned && !bookmarkDrop, deadline]) { result in
      guard reply.open() else { return }
      finish(result as? [String: Any])
    }
  }

  func pageChanged(onPage: Bool, insert: Bool) {
    jsOnPage = onPage
    self.insert = insert
    publish()
    if let source = TabDragSession.current?.sourceWindow { syncPreview(source) }
  }

  private func sourceClosing(_ windowId: String) {
    let closing = self.closing
    self.closing = nil
    if closing?() == true { return }
    let preview: Int? = previewShown ? previewToken : nil
    clearDrag()
    endPreview(preview, cancel: true)
    send("tabDrag.end", [windowId, false])
  }

  private static func onPage(_ aim: TabDropAim) -> Bool {
    switch aim {
    case .page, .split: true
    case .insert, .newWindow, .bookmarks: false
    }
  }

  private static func ownsDrop(_ windowId: String) -> Bool {
    guard TabDragSession.hasZone(in: windowId, .split), let state = NativeStoreHandle.store?.state else { return false }
    let layout = state.settings.string("tabLayout")
    return state.windows.values.allSatisfy { ($0.tabLayout ?? layout) == "top" ? NativeTopStrip.enabled : true }
  }

  private func session(_ windowId: String) -> TabDragSession? {
    TabDragSession.current.flatMap { $0.sourceWindow == windowId ? $0 : nil }
  }

  private func clearDrag() {
    picture = nil
    owned = false
    lifted = nil
    outside = false
    overWindow = nil
    jsOnPage = false
    zoneOnPage = false
    insert = false
    zoneInsert = .none
    shape = "hidden"
    previewShown = false
    publish()
  }

  private func publish() {
    let hub = SidebarDragHub.tabDrag
    guard hub.outside != outside || hub.onPage != onPage else { return }
    SidebarDragHub.tabDragChanged(outside: outside, onPage: onPage)
  }

  private func accepts(_ target: String, from source: String) -> Bool {
    guard let state = NativeStoreHandle.store?.state, let from = state.windows[source], !from.incognito, let to = state.windows[target] else { return false }
    return !to.incognito && to.kind != "small" && open(target)
  }

  private func open(_ windowId: String) -> Bool {
    guard let store = NativeStoreHandle.store, store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId) else { return false }
    return ShellDrag.window(windowId)?.isVisible == true
  }

  private func syncPreview(_ windowId: String) {
    guard session(windowId) != nil else { return }
    let next = outside ? (overWindow != nil && (insert || zoneInsert != nil) ? "pill" : "card") : ((lifted ?? onPage) ? "card" : "hidden")
    if next == "hidden" && shape == "hidden" { return }
    if next != "hidden", let picture {
      self.picture = nil
      previewShown = true
      let chip = picture.chip()
      previewToken += 1
      ShellDrag.previewBegin(windowId: windowId, chip: chip, grab: CGPoint(x: chip.minX + picture.grab.x, y: chip.minY + picture.grab.y))
      send("tabDrag.capture", [windowId])
    }
    shape = next
    ShellDrag.previewUpdate(next, at: pointer)
  }

  private func endPreview(_ token: Int?, windowId: String? = nil, fallback: NSRect? = nil, cancel: Bool = false) {
    guard let token, token == previewToken else { return }
    if cancel { ShellDrag.previewCancel() } else { ShellDrag.previewEnd(windowId: windowId, fallback: fallback) }
  }

  private func dropOutside(_ tabIds: [String], from source: String, at screen: CGPoint, over: String?, before: String??, preview: Int?) {
    guard let store = NativeStoreHandle.store, let from = store.state.windows[source], !from.incognito, !tabIds.isEmpty else {
      return endPreview(preview)
    }
    if let over {
      let moved = (try? store.dispatch(Command("moveTabsToWindow", [JSONValue(tabIds), JSONValue(over)]), origin: .native))?.result?.string
      endPreview(preview)
      guard moved == over, open(over) else { return }
      if let before {
        _ = try? store.dispatch(Command("placeTabs", [JSONValue(tabIds), ["pinned": false, "beforeId": JSONValue(before)]]), origin: .native)
      }
      return focus(over)
    }
    guard !from.tabIds.allSatisfy(tabIds.contains) else { return endPreview(preview) }
    let size = from.frame.flatMap { $0.count == 4 ? CGSize(width: $0[2], height: $0[3]) : nil } ?? CGSize(width: 1200, height: 800)
    let frame = NSRect(x: (screen.x - 90 + 0.5).rounded(.down), y: (screen.y - size.height + 70 + 0.5).rounded(.down), width: size.width, height: size.height)
    let options: JSONValue = [
      "profileId": JSONValue(store.state.tabs[tabIds[0]]?.profileId),
      "tabIds": JSONValue(tabIds),
      "frame": [JSONValue(frame.minX), JSONValue(frame.minY), JSONValue(frame.width), JSONValue(frame.height)],
    ]
    let created = (try? store.dispatch(Command("createWindow", [options]), origin: .native))?.result?.string
    endPreview(preview, windowId: created, fallback: frame)
    if let created, store.state.windows[created] != nil { focus(created) }
  }

  private func focus(_ windowId: String) {
    _ = try? NativeStoreHandle.store?.dispatch(Command("setFocusedWindow", [JSONValue(windowId)]), origin: .native)
    ShellDrag.focus(windowId)
  }
}

@MainActor
private final class EndReply {
  private var taken = false

  func open() -> Bool {
    defer { taken = true }
    return !taken
  }
}

#if SOLARA_PROBES
extension NativeTabDrag {
  fileprivate var probeSnapshot: [String: Any] {
    let session = TabDragSession.current
    var target: Any = NSNull()
    if let aim = session?.aim {
      switch aim {
      case .split(let tabId, let side): target = ["tabId": tabId, "side": side.rawValue]
      case .insert(let beforeId): target = ["beforeId": beforeId as Any? ?? NSNull()]
      case .page: target = ["kind": "page"]
      case .newWindow: target = ["kind": "newWindow"]
      case .bookmarks: target = ["kind": "bookmarks"]
      }
    }
    return ["tabIds": session?.tabIds ?? [], "sourceWindow": session?.sourceWindow as Any? ?? NSNull(),
      "x": pointer.x, "y": pointer.y, "outside": outside, "overWindow": overWindow as Any? ?? NSNull(),
      "lifted": lifted as Any? ?? NSNull(), "onPage": onPage, "insert": insert, "target": target,
      "lastDrop": lastDrop]
  }
}

@MainActor
public enum TabDragRead {
  public static var snapshot: [String: Any] { NativeTabDrag.shared.probeSnapshot }
}
#endif
