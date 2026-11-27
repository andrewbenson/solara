import AppKit
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeTabDrag {
  static let shared = NativeTabDrag()
  static let endDeadline: Double = 2
  static let captureDeadline: TimeInterval = 1
  static let hapticGap: TimeInterval = 0.1
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
  private var zoneInsert: String??
  private var shape = "hidden"
  private var previewShown = false
  private var previewToken = 0
  private var closing: (() -> Bool)?
  private var owned = false
  private var draggedTabId: String?
  private var lastTick = -TimeInterval.infinity
  #if DEBUG
  private(set) var windowTicks = 0
  #endif
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
    TabDragSession.windowIdOf = { ShellDrag.windowId(of: $0) }
    TabDragSession.windowOf = { ShellDrag.window($0) }
    self.closing = closing
    draggedTabId = tabId
    owned = Self.ownsDrop(windowId)
    let session = TabDragSession.begin(tabIds: tabIds, from: windowId)
    session.admitsWindow = { [weak self] in $0 == windowId || self?.accepts($0, from: windowId) == true }
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
    let wasOver = overWindow
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
    if let over, over != wasOver, NativeStoreHandle.store?.state.settings["tabReorderHaptics"]?.truthy ?? true, ProcessInfo.processInfo.systemUptime - lastTick >= Self.hapticGap {
      lastTick = ProcessInfo.processInfo.systemUptime
      #if DEBUG
      windowTicks += 1
      #endif
      ShellDrag.hapticTick()
    }
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
    let nativeAim = session?.endedAim
    let zonePage = session?.endedAim.map(Self.onPage) ?? false
    let liftedPage = !outside && lifted == true
    let screen = session?.pointer
    let owned = self.owned
    clearDrag()
    let generation = NativeStoreHandle.ownershipGeneration
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
      let tearOff = outside && (nativeAim == .newWindow || over != nil)
      guard (tearOff || onPage && !unanswered), let screen else {
        self.endPreview(preview, cancel: unanswered)
        return done(outside)
      }
      guard WorkspaceWrites.store != nil, NativeStoreHandle.ownershipGeneration == generation else {
        NSLog("[sidebar] dropOutside refused: ownership changed")
        self.endPreview(preview)
        return done(false)
      }
      switch nativeAim {
      case .split, .insert:
        self.endPreview(preview)
      default:
        self.dropOutside(tabIds, from: windowId, at: screen, over: over, preview: preview)
      }
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

  func pageChanged(onPage: Bool) {
    jsOnPage = onPage
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
    draggedTabId = nil
    lifted = nil
    outside = false
    overWindow = nil
    jsOnPage = false
    zoneOnPage = false
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
    guard let state = NativeStoreHandle.store?.state else { return false }
    return TabDragSession.canTransfer(from: state.windows[source], to: state.windows[target]) && open(target)
  }

  private func open(_ windowId: String) -> Bool {
    guard let store = NativeStoreHandle.store, store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId) else { return false }
    return ShellDrag.window(windowId)?.isVisible == true
  }

  private func syncPreview(_ windowId: String) {
    guard session(windowId) != nil else { return }
    let next = outside ? (overWindow != nil && zoneInsert != nil ? "pill" : "card") : ((lifted ?? onPage) ? "card" : "hidden")
    if next == "hidden" && shape == "hidden" { return }
    if next != "hidden", let picture {
      self.picture = nil
      previewShown = true
      let chip = picture.chip()
      previewToken += 1
      ShellDrag.previewBegin(windowId: windowId, chip: chip, grab: CGPoint(x: chip.minX + picture.grab.x, y: chip.minY + picture.grab.y))
      capturePage(windowId)
    }
    shape = next
    ShellDrag.previewUpdate(next, at: pointer)
  }

  private func capturePage(_ windowId: String) {
    let token = previewToken
    let dragged = draggedTabId
    let pictures = NativeTabPictures.shared.cache
    let showing: @MainActor () -> Bool = { [weak self] in self?.previewShown == true && self?.previewToken == token }
    let plan: @MainActor () -> TabDragPagePlan? = {
      NativeStoreHandle.store.map { TabDragPagePlan.make($0.state, windowId: windowId, draggedTabId: dragged) { pictures.picture($0) != nil } }
    }
    let viaJS: @MainActor () -> Void = { [weak self] in
      guard showing() else { return }
      self?.send("tabDrag.capture", [windowId])
    }
    let fallback: @MainActor () -> Void = {
      guard showing(), let plan = plan() else { return }
      switch plan.fallback {
      case .none: break
      case .picture(let tabId):
        if let picture = pictures.picture(tabId) { ShellDrag.previewPage(base64: picture.data, frame: picture.frame) }
      case .placeholder(let title, let favicon): ShellDrag.previewPlaceholder(title: title, favicon: favicon)
      }
    }
    guard let first = plan() else { return }
    guard NativeTabPictures.available else { return viaJS() }
    guard let live = first.liveTabId else { return fallback() }
    NativeTabPictures.capture(live, scale: 0.35, deadline: Self.captureDeadline) { outcome in
      guard showing() else { return }
      switch outcome {
      case .picture(let picture): ShellDrag.previewPage(base64: picture.data, frame: picture.frame)
      case .empty: fallback()
      case .unavailable: fallback()
      }
    }
  }

  private func endPreview(_ token: Int?, windowId: String? = nil, fallback: NSRect? = nil, cancel: Bool = false) {
    guard let token, token == previewToken else { return }
    if cancel { ShellDrag.previewCancel() } else { ShellDrag.previewEnd(windowId: windowId, fallback: fallback) }
  }

  @discardableResult
  private func dropOutside(_ tabIds: [String], from source: String, at screen: CGPoint, over: String?, preview: Int?) -> Bool {
    if let over {
      defer { endPreview(preview) }
      guard transfer(tabIds, from: source, to: over, before: nil) else { return false }
      focus(over)
      return true
    }
    guard let store = WorkspaceWrites.store, let from = store.state.windows[source], !from.incognito,
      !tabIds.isEmpty, tabIds.allSatisfy({ store.state.tabs[$0]?.windowId == source }),
      !from.tabIds.allSatisfy(tabIds.contains) else {
      endPreview(preview)
      return false
    }
    do {
      let before = store.state
      let size = from.frame.flatMap { $0.count == 4 ? CGSize(width: $0[2], height: $0[3]) : nil } ?? CGSize(width: 1200, height: 800)
      let frame = NSRect(x: (screen.x - 90 + 0.5).rounded(.down), y: (screen.y - size.height + 70 + 0.5).rounded(.down), width: size.width, height: size.height)
      let options: JSONValue = [
        "profileId": JSONValue(store.state.tabs[tabIds[0]]?.profileId),
        "tabIds": JSONValue(tabIds),
        "frame": [JSONValue(frame.minX), JSONValue(frame.minY), JSONValue(frame.width), JSONValue(frame.height)],
      ]
      let created = (try store.dispatch(Command("createWindow", [options]), origin: .native)).result?.string
      NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
      FrameUpdates.flush()
      endPreview(preview, windowId: created, fallback: frame)
      guard let created, store.state.windows[created] != nil else { return false }
      focus(created)
      return true
    } catch {
      NSLog("[sidebar] dropOutside refused: %@", String(describing: error))
      endPreview(preview)
      return false
    }
  }

  func transfer(_ tabIds: [String], from source: String, to target: String, before: String??) -> Bool {
    guard let store = WorkspaceWrites.store, source != target, accepts(target, from: source),
      !tabIds.isEmpty, tabIds.allSatisfy({ store.state.tabs[$0]?.windowId == source }) else { return false }
    let original = store.state
    do {
      try store.dispatch(Command("moveTabsToWindow", [JSONValue(tabIds), .string(target)]), origin: .native)
    } catch {
      return false
    }
    guard tabIds.allSatisfy({ store.state.tabs[$0]?.windowId == target }) else { return false }
    if let before {
      let anchor = before.flatMap { store.state.tabs[$0]?.windowId == target ? $0 : nil }
      _ = try? store.dispatch(Command("placeTabs", [JSONValue(tabIds), ["pinned": false, "beforeId": JSONValue(anchor)]]), origin: .native)
    }
    NativeWorkspaceCommands.materializeChanges(before: original, after: store.state)
    FrameUpdates.flush()
    return true
  }

  private func focus(_ windowId: String) {
    _ = try? WorkspaceWrites.store?.dispatch(Command("setFocusedWindow", [JSONValue(windowId)]), origin: .native)
    ShellDrag.focus(windowId)
  }
}

@MainActor
final class NativeTabPictures {
  static let shared = NativeTabPictures()
  static let cacheDeadline: TimeInterval = 5

  let cache = TabDragPictures()
  private var lifecycle: Int?
  private var listener: Int?
  private weak var bound: Store?
  private var last: BrowserState?

  static func install() { shared.bind() }

  enum Outcome {
    case picture(PagePicture)
    case empty
    case unavailable
  }

  nonisolated static var available: Bool { TabPoolHost.available }

  static func capture(_ tabId: String, scale: Double, deadline: TimeInterval, _ done: @escaping @MainActor (Outcome) -> Void) {
    let reply = EndReply()
    let answer: @MainActor (Outcome) -> Void = { outcome in
      guard reply.open() else { return }
      done(outcome)
    }
    guard available else { return answer(.unavailable) }
    DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { MainActor.assumeIsolated { answer(.unavailable) } }
    let request = PageRequest<PagePicture?>.capturePicture(scale)
    PageRegistry.shared.call(tabID: tabId, command: request.command) { result in
      switch result {
      case .success(let value): answer(((try? request.decode(value)) ?? nil).map(Outcome.picture) ?? .empty)
      case .failure: answer(.unavailable)
      }
    }
  }

  private func bind() {
    guard lifecycle == nil else { return }
    cache.current = { NativeStoreHandle.store?.state }
    cache.capture = { tabId, done in
      Self.capture(tabId, scale: 0.25, deadline: Self.cacheDeadline) { outcome in
        if case .picture(let picture) = outcome { done(picture) } else { done(nil) }
      }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.rebind() }
    rebind()
  }

  private func rebind() {
    let store = NativeStoreHandle.store
    guard bound !== store else { return }
    if let listener, let bound { bound.unsubscribe(listener) }
    listener = nil
    bound = store
    last = store?.state
    cache.reset()
    guard let store else { return }
    let source = ObjectIdentifier(store)
    listener = store.subscribe { commit in
      let state = commit.state
      let windows = !commit.changes.windows.isEmpty
      let tabs = !commit.changes.tabs.isEmpty
      guard windows || tabs else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { NativeTabPictures.shared.receive(state, from: source, windows: windows, tabs: tabs) }
      }
    }
  }

  private func receive(_ state: BrowserState, from source: ObjectIdentifier, windows: Bool, tabs: Bool) {
    guard let bound, ObjectIdentifier(bound) == source else { return }
    guard let previous = last else {
      last = state
      return
    }
    last = state
    cache.changed(from: previous, to: state, windows: windows, tabs: tabs)
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
      "lifted": lifted as Any? ?? NSNull(), "onPage": onPage, "insert": zoneInsert != nil, "target": target,
      "lastDrop": lastDrop]
  }
}

@MainActor
public enum TabDragRead {
  public static var snapshot: [String: Any] { NativeTabDrag.shared.probeSnapshot }
}
#endif
