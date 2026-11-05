import AppKit
import SolaraModel
import SolaraStore

@MainActor
public protocol StripDragBridge: AnyObject {
  func dragBegan(windowId: String, tabId: String?, tabIds: [String])
  func dragPicture(windowId: String, rect: CGRect, grab: CGPoint)
  func dragMoved(windowId: String, at: CGPoint, lifted: Bool, dx: CGFloat)
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void)
  func drop(ids: [String], drop: JSONValue) -> Bool
  func land(ids: [String], from source: String, in windowId: String, beforeId: String?) -> Bool
}

public enum StripLane: Hashable, Sendable {
  case top, dock
  case group(String)
}

public enum StripDropTarget: Equatable, Sendable {
  case tab(String)
  case group(String)
}

struct StripMemberExit {
  var slot: Int
  var chip: CGFloat
  var expanded: Bool
  var left: CGFloat
}

struct StripDragSource {
  enum Axis { case x, y }
  enum Cross { case tabIn, pinOut }
  enum Drop {
    case none
    case leaveGroup(StripMemberExit)
    case moveGroup(String)
    case tileFolder
  }

  let view: NSView
  var lane: StripLane
  var from: Int
  var tabId: String?
  var ids: [String]?
  var pinned = false
  var groupId: String?
  var width: CGFloat
  var gap: CGFloat
  var axis: Axis?
  var local = false
  var aims = false
  var range: ClosedRange<CGFloat>?
  var drop = Drop.none
  var levels = 0
  var cross: Cross?

  var hasDrop: Bool {
    if case .none = drop { return false }
    return true
  }

  func claims(_ d: CGPoint) -> Bool {
    switch axis {
    case .y: abs(d.y) > 6 && abs(d.y) > abs(d.x)
    case .x: abs(d.x) > 4
    case nil: abs(d.x) > 4 || abs(d.y) > 6
    }
  }
}

public enum StripDrop {
  public static func firstStaying(_ slots: ArraySlice<[String]>, _ moving: [String]) -> String? {
    for slot in slots { for id in slot where !moving.contains(id) { return id } }
    return nil
  }

  public static func slotAnchor(_ slots: [[String]], from: Int, to: Int, moving: [String], after: (String) -> String?) -> String? {
    let others = slots.enumerated().filter { $0.offset != from }.map(\.element)
    let start = min(max(0, to), others.count)
    return firstStaying(others[start...], moving) ?? others.last?.last.flatMap(after)
  }

  @MainActor
  static func tabAfter(_ state: BrowserState, _ id: String, _ moving: [String]) -> String? {
    guard let window = state.windows[state.tabs[id]?.windowId ?? ""], let at = window.tabIds.firstIndex(of: id) else { return nil }
    return window.tabIds[(at + 1)...].first { !moving.contains($0) }
  }

  @MainActor
  static func slotDrop(_ state: BrowserState, ids: [String], slots: [[String]], from: Int, to: Int, pinned: Bool, groupId: String?) -> JSONValue {
    guard to != from, !ids.isEmpty else { return SidebarDrop.none }
    let beforeId = slotAnchor(slots, from: from, to: to, moving: ids) { tabAfter(state, $0, ids) }
    if let groupId { return SidebarDrop.resolve(state, DragSource(kind: .tab), .group(groupId: groupId, beforeId: beforeId)) }
    if pinned { return SidebarDrop.tabs([("pinned", true), ("beforeId", JSONValue(beforeId))]) }
    return SidebarDrop.resolve(state, DragSource(kind: .tab), .list(beforeId: beforeId))
  }

  @MainActor
  static func onto(_ state: BrowserState, _ target: StripDropTarget) -> JSONValue {
    switch target {
    case .tab(let id): SidebarDrop.resolve(state, DragSource(kind: .tab), .onto(targetId: id))
    case .group(let id): SidebarDrop.resolve(state, DragSource(kind: .tab), .group(groupId: id, beforeId: nil))
    }
  }
}

@MainActor
final class StripDrag {
  private unowned let page: StripPageView
  private(set) var source: StripDragSource?
  private(set) var fading: StripDragSource?
  private var press: (view: NSView, at: CGPoint, candidates: [StripDragSource])?
  private(set) var owns = false
  private var swallowing = false
  private(set) var dx = StripSpringValue(0)
  private(set) var lift = StripTimedValue(0)
  private(set) var grow = StripSpringValue(0)
  private(set) var crossed = false
  private var shifts: [StripLane: [Int: StripSpringValue]] = [:]
  private var ids: [String] = []
  private var origin = CGPoint.zero
  private var grab: CGFloat = 0
  private var stripBottom: CGFloat = 0
  private var lifted = false
  private var to = -1
  private(set) var onto: StripDropTarget?
  private var landing: (() -> Void)?
  private var landingToken = 0
  private var changed = false
  private var traceKey: String?
  private var trace: (lane: StripLane, index: Int, start: Double)?
  private(set) var traced: [[Double]] = []

  init(page: StripPageView) {
    self.page = page
  }

  var active: Bool { source != nil }
  var grabX: CGFloat { grab }

  var running: Bool { dx.running || lift.running || grow.running || shifts.values.contains { $0.values.contains(where: \.running) } }

  func offset(_ lane: StripLane, _ index: Int) -> CGFloat {
    CGFloat(shifts[lane]?[index]?.value ?? 0)
  }

  func translation(_ view: NSView) -> CGFloat {
    source?.view === view ? CGFloat(dx.value) : 0
  }

  func dragging(_ view: NSView) -> Bool { source?.view === view }

  func collapse(_ lane: StripLane) -> (index: Int, by: CGFloat)? {
    guard let fading, fading.lane == lane, fading.from >= 0, lift.value > 0 else { return nil }
    if case .group = lane { return nil }
    return (fading.from, CGFloat(lift.value) * (fading.width + fading.gap))
  }

  var fadingView: NSView? { fading?.view }
  var fadingAlpha: CGFloat { CGFloat(1 - lift.value) }

  func traceSlot(_ key: String) {
    traceKey = key
    trace = nil
    traced = []
  }

  func press(_ view: NSView, _ event: NSEvent) {
    press = (view, windowPoint(event), page.dragSources(from: view))
  }

  func dragged(_ view: NSView, _ event: NSEvent) -> Bool {
    let at = windowPoint(event)
    if owns {
      move(at)
      return true
    }
    if swallowing { return true }
    guard let press, press.view === view else { return false }
    let d = CGPoint(x: at.x - press.at.x, y: at.y - press.at.y)
    guard let source = press.candidates.first(where: { $0.claims(d) }) else { return false }
    self.press = nil
    swallowing = true
    begin(source, at: at)
    return true
  }

  func released(_ view: NSView, _ event: NSEvent) -> Bool {
    press = nil
    let swallowed = swallowing
    swallowing = false
    guard owns else { return swallowed }
    release(windowPoint(event))
    return true
  }

  private func begin(_ source: StripDragSource, at: CGPoint) {
    landing?()
    landingToken += 1
    dx.set(0)
    let state = page.dragState
    ids = source.ids ?? source.tabId.map { movingTabIds(state, $0) } ?? []
    self.source = source
    fading = source
    owns = true
    origin = at
    to = -1
    lifted = false
    grab = source.width / 2
    stripBottom = .infinity
    setOnto(nil)
    page.syncHover()
    if !source.local {
      page.bridge?.dragBegan(windowId: page.windowId, tabId: ids.count == 1 ? source.tabId : nil, tabIds: ids)
      if let rect = page.windowRect(source.view) {
        stripBottom = rect.minY + StripMetrics.height
        grab = max(0, min(rect.width, at.x - rect.minX))
        page.bridge?.dragPicture(windowId: page.windowId, rect: rect, grab: at)
      }
    }
    page.dragChanged()
  }

  private func movingTabIds(_ state: BrowserState?, _ tabId: String) -> [String] {
    let selection = Set(page.selection)
    guard selection.count > 1, selection.contains(tabId), let state, let window = state.windows[state.tabs[tabId]?.windowId ?? ""] else { return [tabId] }
    return window.tabIds.filter { selection.contains($0) }
  }

  private func range(_ source: StripDragSource) -> ClosedRange<CGFloat> {
    if let range = source.range { return range }
    let layout = page.pageLayout
    if source.cross == .tabIn, !layout.dockCells.isEmpty, source.from >= 0, source.from < layout.top.slots.count {
      let upper = StripLayout.dragRange(layout.top, from: source.from).upperBound
      let lower = min(0, page.dockLeft - layout.top.lefts[source.from] - grab + StripMetrics.pinnedCell / 2)
      return lower...max(lower, upper)
    }
    if source.cross == .pinOut, source.from >= 0, source.from < layout.dock.lefts.count {
      let top = layout.top
      let end = top.slots.isEmpty ? StripMetrics.maxChip : top.lefts[top.lefts.count - 1] + top.slots[top.slots.count - 1].width
      let lower = -layout.dock.lefts[source.from]
      return lower...max(lower, end - page.dockLeft - layout.dock.lefts[source.from] - StripMetrics.pinnedCell)
    }
    guard source.from >= 0, let g = page.geometry(source.lane), source.from < g.slots.count else { return 0...0 }
    return StripLayout.dragRange(g, from: source.from)
  }

  private func aim(_ source: StripDragSource, _ gdx: CGFloat) -> StripAim? {
    guard source.aims, source.from >= 0, let g = page.geometry(source.lane), source.from < g.slots.count else { return nil }
    let targets = page.dropTargets
    return StripLayout.aimDrop(g, from: source.from, pointer: g.lefts[source.from] + grab + gdx, target: { $0 < targets.count && targets[$0] != nil }, edge: StripMetrics.ontoEdge)
  }

  private func index(_ source: StripDragSource, _ gdx: CGFloat) -> Int {
    if let aim = aim(source, gdx) { return aim.to }
    guard let g = page.geometry(source.lane), source.from >= 0, source.from < g.slots.count else { return source.from }
    return StripLayout.dropIndex(g, from: source.from, dx: gdx)
  }

  private func move(_ at: CGPoint) {
    guard let source else { return }
    let gdx = at.x - origin.x
    let lifted = !source.local && source.tabId != nil && ids.count == 1 && at.y > stripBottom + StripMetrics.liftSlop
    setLifted(lifted)
    let bounds = range(source)
    if !lifted { dx.set(Double(min(bounds.upperBound, max(bounds.lowerBound, gdx)))) }
    let across = !lifted && crossAt(source)
    setCross(across)
    let aim = across || lifted ? nil : aim(source, gdx)
    let targets = page.dropTargets
    setOnto(aim?.onto.flatMap { $0 < targets.count ? targets[$0] : nil })
    if !across { makeRoom(lifted || source.from < 0 ? -1 : aim?.to ?? index(source, gdx)) }
    if !source.local { page.bridge?.dragMoved(windowId: page.windowId, at: at, lifted: lifted, dx: CGFloat(dx.value)) }
    page.dragChanged()
  }

  private func setLifted(_ on: Bool) {
    guard lifted != on else { return }
    lifted = on
    lift.animate(to: on ? 1 : 0, duration: StripMotionTiming.lift, easing: .cubic, at: StripTicker.now)
  }

  private func crossAt(_ source: StripDragSource) -> Bool {
    let layout = page.pageLayout
    guard let cross = source.cross, !layout.dockCells.isEmpty else { return false }
    let top = layout.top
    let dock = layout.dock
    let dx = CGFloat(self.dx.value)
    let from = source.from
    switch cross {
    case .tabIn:
      guard let j = StripLayout.tabInIndex(top: top, dock: dock, dockLeft: page.dockLeft, from: from, dx: dx, grab: grab) else { return false }
      shift(.dock, count: dock.slots.count, skip: -1) { $0 >= j ? StripMetrics.cellStep : 0 }
      shift(.top, count: top.slots.count, skip: from) { StripMetrics.cellStep - ($0 > from ? source.width + source.gap : 0) }
      growTo(StripMetrics.cellStep)
    case .pinOut:
      guard let k = StripLayout.pinOutIndex(top: top, dock: dock, dockLeft: page.dockLeft, from: from, dx: dx) else { return false }
      let shrink = StripLayout.dockShrink(dock.slots.count)
      shift(.dock, count: dock.slots.count, skip: from) { $0 > from ? -StripMetrics.cellStep : 0 }
      shift(.top, count: top.slots.count, skip: -1) { -shrink + ($0 >= k ? layout.chip + StripMetrics.gap : 0) }
      growTo(dock.slots.count > 1 ? -StripMetrics.cellStep : -StripMetrics.pinnedCell)
    }
    return true
  }

  private func crossLand(_ source: StripDragSource) -> (dx: CGFloat, drop: JSONValue)? {
    let layout = page.pageLayout
    guard let cross = source.cross, !layout.dockCells.isEmpty, let state = page.dragState else { return nil }
    let top = layout.top
    let dock = layout.dock
    let dx = CGFloat(self.dx.value)
    switch cross {
    case .tabIn:
      guard let j = StripLayout.tabInIndex(top: top, dock: dock, dockLeft: page.dockLeft, from: source.from, dx: dx, grab: grab) else { return nil }
      let target = page.dockLeft + StripLayout.dockCellLeft(dock, j)
      let beforeId = j < dock.slots.count ? dock.slots[j].tabIds.first : nil
      return (target - (top.lefts[source.from] + grab - StripMetrics.pinnedCell / 2), SidebarDrop.tabs([("pinned", true), ("beforeId", JSONValue(beforeId))]))
    case .pinOut:
      guard let k = StripLayout.pinOutIndex(top: top, dock: dock, dockLeft: page.dockLeft, from: source.from, dx: dx) else { return nil }
      let target = StripLayout.slotStart(top, k, gap: StripMetrics.gap) - StripLayout.dockShrink(dock.slots.count)
      let beforeId = k < top.slots.count ? top.slots[k].tabIds.first : nil
      return (target - (page.dockLeft + dock.lefts[source.from]), SidebarDrop.resolve(state, DragSource(kind: .tab), .list(beforeId: beforeId)))
    }
  }

  private func crossClear(_ source: StripDragSource) {
    switch source.cross {
    case .tabIn: shift(.dock, count: page.pageLayout.dock.slots.count, skip: -1) { _ in 0 }
    case .pinOut: shift(.top, count: page.pageLayout.top.slots.count, skip: -1) { _ in 0 }
    case nil: return
    }
    growTo(0)
  }

  private func growTo(_ target: CGFloat) {
    guard grow.target != Double(target) else { return }
    grow.animate(to: Double(target), .slide, at: StripTicker.now)
  }

  private func setCross(_ on: Bool) {
    guard crossed != on else { return }
    crossed = on
    if !on {
      if let source { crossClear(source) }
      to = Int.min
    }
    page.crossChanged()
  }

  private func settleStrip() {
    shifts[.top] = nil
    shifts[.dock] = nil
    grow.set(0)
  }

  private func settleAcross(_ source: StripDragSource, _ landing: (dx: CGFloat, drop: JSONValue)) {
    landingToken += 1
    let token = landingToken
    let ids = self.ids
    self.landing = { [weak self] in
      guard let self, self.landingToken == token else { return }
      self.landing = nil
      self.dx.set(0)
      self.source = nil
      self.lift.set(0)
      self.fading = nil
      self.lifted = false
      self.crossed = false
      self.settleStrip()
      self.page.crossChanged()
      _ = self.dispatch(ids, landing.drop)
      self.page.dragChanged()
      self.page.dragEnded()
    }
    dx.animate(to: Double(landing.dx), .slide, at: StripTicker.now)
    page.dragChanged()
  }

  private func setOnto(_ target: StripDropTarget?) {
    guard onto != target else { return }
    let old = onto
    onto = target
    page.ontoChanged(from: old, to: target)
  }

  private func makeRoom(_ to: Int) {
    guard let source, source.from >= 0, to != self.to, let g = page.geometry(source.lane) else { return }
    self.to = to
    let offsets = StripLayout.reorderOffsets(g, from: source.from, to: to < 0 ? source.from : to)
    shift(source.lane, count: g.slots.count, skip: source.from) { $0 < offsets.count ? offsets[$0] : 0 }
  }

  private func shift(_ lane: StripLane, count: Int, skip: Int, _ offsetOf: (Int) -> CGFloat) {
    var springs = shifts[lane] ?? [:]
    let extra = lane == .top ? 1 : 0
    for i in 0..<(count + extra) where i != skip {
      let target = Double(offsetOf(i))
      var spring = springs[i] ?? StripSpringValue(0)
      if spring.target == target { continue }
      if trace == nil, let key = traceKey, page.slotKey(lane, i) == key {
        trace = (lane, i, StripTicker.now)
        traced = [[0, spring.value]]
      }
      spring.animate(to: target, .slide, at: StripTicker.now)
      springs[i] = spring
    }
    shifts[lane] = springs
  }

  private func settleRoom(_ lane: StripLane) {
    shifts[lane] = nil
  }

  private func release(_ at: CGPoint) {
    guard let source else { return }
    move(at)
    owns = false
    let gdx = at.x - origin.x
    let lifted = self.lifted
    guard !source.local, let bridge = page.bridge else { return finish(source, gdx: gdx, lifted: lifted, ended: false) }
    let token = landingToken
    bridge.dragEnded(windowId: page.windowId, commit: true) { [weak self] ended in
      guard let self, self.landingToken == token, self.source != nil else { return }
      self.finish(source, gdx: gdx, lifted: lifted, ended: ended)
    }
  }

  private func finish(_ source: StripDragSource, gdx: CGFloat, lifted: Bool, ended: Bool) {
    if (!source.local && (ended || lifted)) || (source.from < 0 && !source.hasDrop) { return reset() }
    if crossed, let landing = crossLand(source) { return settleAcross(source, landing) }
    setCross(false)
    let onto = self.onto
    setOnto(nil)
    if !source.local, let onto, let state = page.dragState, dispatch(ids, StripDrop.onto(state, onto)) {
      settleRoom(source.lane)
      return reset()
    }
    let bounds = source.range ?? (source.cross != nil ? range(source) : nil)
    let travelled = bounds.map { min($0.upperBound, max($0.lowerBound, gdx)) } ?? gdx
    if !source.local {
      changed = false
      let moved = drop(source, travelled) || (source.from >= 0 && ids.count > 1 && reorder(source, index(source, gdx)))
      if moved && changed { settleRoom(source.lane) }
      if moved { return reset() }
    }
    if source.from < 0 { return reset() }
    let to = index(source, gdx)
    let ids = self.ids
    settle(source, to: to == source.from ? nil : to) { [weak self] in
      guard let self else { return }
      if source.local { _ = self.drop(source, travelled, ids: ids) } else { _ = self.reorder(source, to, ids: ids) }
    }
  }

  private func settle(_ source: StripDragSource, to: Int?, commit: @escaping () -> Void) {
    if to == nil { makeRoom(-1) }
    var target: CGFloat = 0
    if let to, let g = page.geometry(source.lane) {
      let offsets = StripLayout.reorderOffsets(g, from: source.from, to: to)
      target = source.from < offsets.count ? offsets[source.from] : 0
    }
    landingToken += 1
    let token = landingToken
    landing = { [weak self] in
      guard let self, self.landingToken == token else { return }
      self.landing = nil
      self.dx.set(0)
      self.source = nil
      self.lift.set(0)
      self.fading = nil
      self.lifted = false
      if to != nil {
        self.settleRoom(source.lane)
        commit()
      }
      self.page.dragChanged()
      self.page.dragEnded()
    }
    dx.animate(to: Double(target), .slide, at: StripTicker.now)
    page.dragChanged()
  }

  func tick(_ now: Double) {
    dx.step(now: now)
    lift.step(now: now)
    grow.step(now: now)
    for (lane, springs) in shifts {
      var next = springs
      for (i, var spring) in springs where spring.running {
        spring.step(now: now)
        next[i] = spring
      }
      shifts[lane] = next
    }
    if let trace, now - trace.start < 0.6, let value = shifts[trace.lane]?[trace.index]?.value {
      traced.append([(now - trace.start) * 1000, value])
    }
    if landing != nil, !dx.running { landing?() }
    if fading != nil, source == nil, !lift.running, lift.value == 0 {
      fading = nil
      page.dragChanged()
    }
  }

  private func reset() {
    landingToken += 1
    owns = false
    setCross(false)
    setOnto(nil)
    makeRoom(-1)
    dx.set(0)
    setLifted(false)
    source = nil
    landing = nil
    if !lift.running && lift.value == 0 { fading = nil }
    page.dragChanged()
    page.dragEnded()
  }

  func cancel() {
    guard source != nil else { return }
    if owns, let source, !source.local { page.bridge?.dragEnded(windowId: page.windowId, commit: false) { _ in } }
    for lane in Array(shifts.keys) { settleRoom(lane) }
    grow.set(0)
    reset()
  }

  private func drop(_ source: StripDragSource, _ travelled: CGFloat, ids: [String]? = nil) -> Bool {
    let ids = ids ?? self.ids
    guard let state = page.dragState else { return false }
    switch source.drop {
    case .none:
      return false
    case .leaveGroup(let exit):
      let top = page.pageLayout.top
      guard exit.slot >= 0, exit.slot < top.slots.count,
        let at = StripLayout.leaveIndex(top, slot: exit.slot, chip: exit.chip, expanded: exit.expanded, left: exit.left + travelled, width: source.width)
      else { return false }
      let beforeId = StripDrop.firstStaying(top.slots.map(\.tabIds)[min(at, top.slots.count)...], ids)
      _ = dispatch(ids, SidebarDrop.resolve(state, DragSource(kind: .tab), .list(beforeId: beforeId)))
      return true
    case .moveGroup(let groupId):
      guard let g = page.geometry(source.lane), source.from >= 0 else { return true }
      let to = StripLayout.dropIndex(g, from: source.from, dx: travelled)
      if to == source.from { return true }
      let others = g.slots.enumerated().filter { $0.offset != source.from }.map(\.element)
      let beforeId = to < others.count ? others[to].tabIds.first : nil
      let spot: DropSpot = state.groups[groupId]?.pinned == true ? .pinnedRows(beforeId: beforeId) : .list(beforeId: beforeId)
      _ = dispatch([], SidebarDrop.resolve(state, DragSource(kind: .group, groupId: groupId), spot))
      return true
    case .tileFolder:
      guard let g = page.geometry(source.lane), source.from >= 0 else { return false }
      return reorder(source, StripLayout.dropIndex(g, from: source.from, dx: travelled), ids: ids)
    }
  }

  private func reorder(_ source: StripDragSource, _ to: Int, ids: [String]? = nil) -> Bool {
    let ids = ids ?? self.ids
    guard let state = page.dragState, let g = page.geometry(source.lane) else { return false }
    let drop = StripDrop.slotDrop(state, ids: ids, slots: g.slots.map(\.tabIds), from: source.from, to: to, pinned: source.pinned, groupId: source.groupId)
    return dispatch(ids, drop)
  }

  private func dispatch(_ ids: [String], _ drop: JSONValue) -> Bool {
    guard SidebarDrop.type(drop) != "none", page.bridge?.drop(ids: ids, drop: drop) == true else { return false }
    changed = true
    return true
  }

  private func windowPoint(_ event: NSEvent) -> CGPoint {
    let height = page.window?.contentView?.bounds.height ?? 0
    return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
  }
}
