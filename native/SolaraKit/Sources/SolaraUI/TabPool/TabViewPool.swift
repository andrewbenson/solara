import AppKit

@MainActor
public protocol TabPoolPage: AnyObject {
  var view: NSView { get }
  func setShown(_ shown: Bool)
  func focus()
  func retire()
  var holdsUntilDrawn: Bool { get }
  func hold(_ held: Bool)
  func whenDrawn(_ done: @escaping @MainActor (_ drawn: Bool) -> Void)
}

public extension TabPoolPage {
  var holdsUntilDrawn: Bool { false }
  func hold(_ held: Bool) {}
  func whenDrawn(_ done: @escaping @MainActor (_ drawn: Bool) -> Void) { done(true) }
}

@MainActor
public final class TabViewPool {
  public typealias Make = @MainActor (_ tabId: String, _ windowId: String) -> TabPoolPage?
  public typealias Schedule = @MainActor (@escaping @MainActor () -> Void) -> Void
  public typealias After = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  public static let holdLimit: TimeInterval = 0.25

  public let slots: TabSlots
  public let keeper: NSView
  public var hiddenContainer: @MainActor (String) -> NSView? = { _ in nil }
  public var onPlaced: (@MainActor ([String: String]) -> Void)?
  public var onReplace: (@MainActor (String) -> Void)?

  private let make: Make
  private let schedule: Schedule
  private var wanted: [TabViewWanted] = []
  private var pages: [String: TabPoolPage] = [:]
  private var places: [String: TabViewPlace] = [:]
  private var shown: [String: Bool] = [:]
  private var identities: [String: String] = [:]
  private var refocus: Set<String> = []
  private var held: [String: (page: TabPoolPage, generation: Int, over: String, key: TabSlotKey)] = [:]
  private var holdGeneration = 0
  private var drawnSinceShown: Set<String> = []
  private var showGenerations: [String: Int] = [:]
  private var showGeneration = 0
  private var inputMonitor: Any?
  static let heldInputEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .magnify, .rotate, .swipe,
    .leftMouseDragged, .leftMouseUp, .rightMouseDragged, .rightMouseUp, .otherMouseDragged, .otherMouseUp]
  static let gestureEnds: Set<NSEvent.EventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
  static let gestureMoves: Set<NSEvent.EventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
  static let gestureStarts: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
  enum DroppedGesture { case mouse, scroll }
  private var dropping: DroppedGesture?
  private weak var droppingWindow: NSWindow?
  private var droppingObserver: NSObjectProtocol?
  private let after: After
  private var scheduled = false
  private var slotObserver: NSObjectProtocol?

  public init(slots: TabSlots = .shared, make: @escaping Make, schedule: @escaping Schedule = { work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } },
    after: @escaping After = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) } }) {
    self.slots = slots
    self.make = make
    self.schedule = schedule
    self.after = after
    keeper = NSView(frame: .zero)
    keeper.isHidden = true
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: slots, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.setNeedsReconcile() }
    }
  }

  isolated deinit {
    if let slotObserver { NotificationCenter.default.removeObserver(slotObserver) }
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    if let droppingObserver { NotificationCenter.default.removeObserver(droppingObserver) }
  }

  public func page(_ tabId: String) -> TabPoolPage? { pages[tabId] }
  public var heldTabIds: Set<String> { Set(held.keys) }
  var isDroppingAGesture: Bool { dropping != nil }
  public func place(_ tabId: String) -> TabViewPlace? { places[tabId] }

  public func update(_ wanted: [TabViewWanted]) {
    guard wanted != self.wanted else { return }
    self.wanted = wanted
    setNeedsReconcile()
  }

  public func setNeedsReconcile() {
    guard !scheduled else { return }
    scheduled = true
    schedule { [weak self] in self?.reconcile() }
  }

  public func reconcile() {
    scheduled = false
    let replaced = retireChangedIdentities()
    let ops = TabViewPlan.plan(wanted: wanted, slots: slots.keys, current: places, visible: shown)
    let rehosted = rehost()
    endStaleHolds()
    guard !ops.isEmpty else {
      focusReplaced()
      if rehosted || replaced { onPlaced?(places.mapValues(Self.describe)) }
      return
    }
    var made: Set<String> = []
    let holding = holds(ops)
    for op in ops {
      switch op {
      case .attach(let id, _, _), .drop(let id): endHold(id, settle: false)
      default: break
      }
    }
    for op in ops {
      if case .visible(let id, false) = op {
        pages[id]?.setShown(false)
        notShown(id)
      }
    }
    for op in ops {
      switch op {
      case .drop(let id):
        identities[id] = nil
        notShown(id)
        guard let page = pages.removeValue(forKey: id) else { continue }
        page.retire()
      case .create(let id, let windowId):
        guard let page = make(id, windowId) else { continue }
        pages[id] = page
        identities[id] = identity(of: id)
        made.insert(id)
        move(page.view, into: hidden(windowId), below: false)
      case .attach(let id, let key, _):
        guard let view = pages[id]?.view, let container = slots.container(for: key) else { continue }
        move(view, into: container, below: false)
      case .behind(let id, let key, _):
        guard holding[id] == nil, let view = pages[id]?.view, let container = slots.container(for: key) else { continue }
        move(view, into: container, below: true)
      case .hide(let id, let windowId, _):
        guard holding[id] == nil, let view = pages[id]?.view else { continue }
        move(view, into: hidden(windowId), below: false)
      case .visible(let id, let on):
        if on, let page = pages[id] {
          page.setShown(true)
          watchFirstFrame(id, page: page)
        }
      }
    }
    var applied = TabViewPlan.apply(ops, to: places, visible: shown)
    for op in ops {
      if case .create(let id, _) = op, !made.contains(id) {
        applied.current[id] = nil
        applied.visible[id] = nil
      }
    }
    places = applied.current
    shown = applied.visible
    endStaleHolds()
    for (id, next) in holding.sorted(by: { $0.key < $1.key }) {
      guard let page = pages[id], let key = next.key else { continue }
      startHold(id, page: page, over: next.id, key: key)
    }
    focusReplaced()
    onPlaced?(places.mapValues(Self.describe))
  }

  private func holds(_ ops: [TabViewOp]) -> [String: (id: String, key: TabSlotKey?)] {
    var incoming: [TabSlotKey: String] = [:]
    for op in ops {
      if case .attach(let id, let key, _) = op, case .card = key { incoming[key] = id }
    }
    guard !incoming.isEmpty else { return [:] }
    var out: [String: (id: String, key: TabSlotKey?)] = [:]
    for op in ops {
      let id: String
      switch op {
      case .hide(let leaving, _, _), .behind(let leaving, _, _): id = leaving
      default: continue
      }
      guard case .slot(let key)? = places[id], let next = incoming[key], next != id, drawnSinceShown.contains(id), sameProfile(id, next),
        let page = pages[id], page.holdsUntilDrawn, let container = slots.container(for: key), page.view.superview === container,
        page.view.window != nil else { continue }
      out[id] = (next, key)
    }
    return out
  }

  private func sameProfile(_ a: String, _ b: String) -> Bool {
    let profiles = Dictionary(wanted.map { ($0.tabId, $0.profileId) }, uniquingKeysWith: { first, _ in first })
    return profiles[a] == profiles[b]
  }

  private func watchFirstFrame(_ id: String, page: TabPoolPage) {
    showGeneration += 1
    let generation = showGeneration
    showGenerations[id] = generation
    drawnSinceShown.remove(id)
    page.whenDrawn { [weak self] drawn in
      guard drawn, let self, self.showGenerations[id] == generation else { return }
      self.drawnSinceShown.insert(id)
    }
  }

  private func notShown(_ id: String) {
    showGenerations[id] = nil
    drawnSinceShown.remove(id)
  }

  private func endStaleHolds() {
    for (id, entry) in held.sorted(by: { $0.key < $1.key }) {
      guard places[entry.over] != .slot(entry.key) || !sameProfile(id, entry.over) else { continue }
      endHold(id, settle: true)
    }
  }

  private func startHold(_ id: String, page: TabPoolPage, over next: String, key: TabSlotKey) {
    guard let incoming = pages[next], let container = incoming.view.superview, incoming.view.window != nil else { return settle(id) }
    for (other, entry) in held.sorted(by: { $0.key < $1.key }) where entry.page.view.superview === container { endHold(other, settle: true) }
    holdGeneration += 1
    let generation = holdGeneration
    held[id] = (page, generation, next, key)
    let window = page.view.window
    let responder = window?.firstResponder as? NSView
    let hadFocus = responder.map { $0 === page.view || $0.isDescendant(of: page.view) } ?? false
    container.addSubview(page.view, positioned: .above, relativeTo: incoming.view)
    page.view.frame = container.bounds
    page.hold(true)
    if hadFocus, let window {
      window.makeFirstResponder(nil)
      schedule { [weak self, weak incoming, weak window] in
        guard let self, let incoming, let window, window.firstResponder === window, self.pages[next] === incoming,
          self.places[next] == .slot(key), incoming.view.window === window, !incoming.view.isHiddenOrHasHiddenAncestor else { return }
        incoming.focus()
      }
    }
    let release: @MainActor () -> Void = { [weak self] in self?.release(id, generation: generation) }
    incoming.whenDrawn { _ in release() }
    after(Self.holdLimit, release)
    watchInput()
  }

  private func watchInput() {
    if held.isEmpty && dropping == nil {
      if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
      inputMonitor = nil
      return
    }
    guard inputMonitor == nil else { return }
    inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.heldInputEvents) { [weak self] event in
      let type = event.type, windowNumber = event.windowNumber, point = event.locationInWindow
      let phase = type == .scrollWheel ? event.phase : [], momentum = type == .scrollWheel ? event.momentumPhase : []
      let swallow = MainActor.assumeIsolated {
        self?.inputArrived(type, window: NSApp.window(withWindowNumber: windowNumber), at: point, phase: phase, momentum: momentum) ?? false
      }
      return swallow ? nil : event
    }
  }

  func inputArrived(_ type: NSEvent.EventType, window: NSWindow?, at point: NSPoint, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> Bool {
    if dropping != nil, droppingWindow == nil || droppingWindow !== window { stopDropping() }
    guard let window else { return false }
    if let dropping {
      switch dropping {
      case .mouse where Self.gestureMoves.contains(type):
        return true
      case .mouse where Self.gestureEnds.contains(type):
        stopDropping()
        return true
      case .scroll where type == .scrollWheel && !phase.contains(.began) && !phase.contains(.mayBegin) && !(phase.isEmpty && momentum.isEmpty):
        if momentum.contains(.ended) || momentum.contains(.cancelled) || (momentum.isEmpty && phase.contains(.cancelled)) { stopDropping() }
        return true
      default:
        stopDropping()
      }
    }
    let starts = Self.gestureStarts.contains(type) || (type == .scrollWheel && (phase.contains(.began) || phase.contains(.mayBegin) || (phase.isEmpty && momentum.isEmpty)))
    let ends = !Self.gestureMoves.contains(type) && !Self.gestureEnds.contains(type)
    var swallow = false
    for (id, entry) in held.sorted(by: { $0.key < $1.key }) where entry.page.view.window === window {
      guard ends else { continue }
      if starts, let container = entry.page.view.superview, let content = window.contentView,
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point), hit.isDescendant(of: container) {
        swallow = true
      }
      endHold(id, settle: true)
    }
    if swallow, type == .scrollWheel, !phase.isEmpty {
      startDropping(.scroll, in: window)
    } else if swallow, Self.gestureStarts.contains(type) {
      startDropping(.mouse, in: window)
    }
    watchInput()
    return swallow
  }

  private func startDropping(_ gesture: DroppedGesture, in window: NSWindow) {
    stopDropping()
    dropping = gesture
    droppingWindow = window
    droppingObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopDropping() }
    }
  }

  private func stopDropping() {
    if let droppingObserver { NotificationCenter.default.removeObserver(droppingObserver) }
    droppingObserver = nil
    dropping = nil
    droppingWindow = nil
    watchInput()
  }

  private func release(_ id: String, generation: Int) {
    guard held[id]?.generation == generation else { return }
    endHold(id, settle: true)
  }

  private func endHold(_ id: String, settle shouldSettle: Bool) {
    guard let entry = held.removeValue(forKey: id) else { return }
    entry.page.hold(false)
    if shouldSettle { settle(id) }
    watchInput()
  }

  private func settle(_ id: String) {
    guard let view = pages[id]?.view, let place = places[id] else { return }
    switch place {
    case .hidden(let windowId): move(view, into: hidden(windowId), below: false)
    case .behind(let key): if let container = slots.container(for: key) { move(view, into: container, below: true) }
    case .slot(let key): if let container = slots.container(for: key) { move(view, into: container, below: false) }
    }
  }

  private func focusReplaced() {
    let ids = refocus
    refocus = []
    for id in ids.sorted() {
      guard let page = pages[id], page.view.window != nil, !page.view.isHiddenOrHasHiddenAncestor else { continue }
      page.focus()
    }
  }

  private func retireChangedIdentities() -> Bool {
    var replaced = false
    for entry in wanted where !entry.identity.isEmpty {
      guard pages[entry.tabId] != nil else { continue }
      guard let had = identities[entry.tabId], !had.isEmpty else {
        identities[entry.tabId] = entry.identity
        continue
      }
      guard had != entry.identity, let page = pages.removeValue(forKey: entry.tabId) else { continue }
      endHold(entry.tabId, settle: false)
      notShown(entry.tabId)
      let responder = page.view.window?.firstResponder as? NSView
      if let responder, responder === page.view || responder.isDescendant(of: page.view) { refocus.insert(entry.tabId) }
      identities[entry.tabId] = nil
      places[entry.tabId] = nil
      shown[entry.tabId] = nil
      page.setShown(false)
      onReplace?(entry.tabId)
      page.retire()
      replaced = true
    }
    return replaced
  }

  private func identity(of tabId: String) -> String {
    wanted.first { $0.tabId == tabId }?.identity ?? ""
  }

  private func rehost() -> Bool {
    var moved = false
    for (id, place) in places.sorted(by: { $0.key < $1.key }) where held[id] == nil {
      guard let view = pages[id]?.view else { continue }
      let container: NSView?
      switch place {
      case .slot(let key), .behind(let key): container = slots.container(for: key)
      case .hidden(let windowId): container = hidden(windowId)
      }
      guard let container, view.superview !== container else { continue }
      if case .behind = place { move(view, into: container, below: true) } else { move(view, into: container, below: false) }
      moved = true
    }
    return moved
  }

  private func hidden(_ windowId: String) -> NSView {
    hiddenContainer(windowId) ?? keeper
  }

  private func move(_ view: NSView, into container: NSView, below: Bool) {
    let window = view.window
    let responder = window?.firstResponder as? NSView
    let hadFocus = responder.map { $0 === view || $0.isDescendant(of: view) } ?? false
    let poolViews = Set(pages.values.map { ObjectIdentifier($0.view) })
    let topPage = below ? nil : container.subviews.last { $0 !== view && poolViews.contains(ObjectIdentifier($0)) }
    if let topPage {
      container.addSubview(view, positioned: .above, relativeTo: topPage)
    } else {
      container.addSubview(view, positioned: .below, relativeTo: nil)
    }
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    if hadFocus, let responder, let now = view.window, now === window, now.firstResponder !== responder {
      now.makeFirstResponder(responder)
    }
  }

  static func describe(_ place: TabViewPlace) -> String {
    switch place {
    case .slot(.card): return "card"
    case .slot(.pane): return "pane"
    case .slot(.peek): return "peek"
    case .slot(.popup): return "popup"
    case .slot(.sidePanel): return "sidePanel"
    case .behind: return "behind"
    case .hidden: return "hidden"
    }
  }
}
