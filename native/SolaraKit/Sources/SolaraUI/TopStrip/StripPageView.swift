import AppKit
import QuartzCore
import SolaraModel
import SolaraStore

@MainActor
final class StripDocumentView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class StripClipView: NSClipView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class StripScrollView: NSScrollView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
public final class StripPageView: NSView {
  public let windowId: String
  public let profileId: String
  let favicons: SidebarFavicons
  var onAction: (StripAction) -> Void = { _ in }
  public private(set) var pageLayout = StripPageLayout()

  private var context: StripContext?
  var shownKey: String { "\(context?.activeId ?? "")|\(pageLayout.items.map(\.key).joined(separator: ","))" }

  private let scroll = StripScrollView()
  private let document = StripDocumentView()
  private let dock = StripDockView()
  private let newTab = StripNewTabButton()
  private var tabs: [String: StripTabChip] = [:]
  private var splits: [String: StripSplitChip] = [:]
  private var groups: [String: StripGroupView] = [:]
  private var hoveredViews: [StripHoverView] = []
  private var tracking: NSTrackingArea?
  private var revealed: String?
  private var motions: [String: StripGroupMotion] = [:]
  private lazy var ticker = StripTicker(view: self) { [weak self] now in self?.tick(now) ?? false }
  private(set) lazy var drag = StripDrag(page: self)
  private weak var fadedView: NSView?
  private weak var draggedView: NSView?
  private var raisedViews: [(view: NSView, below: NSView?)] = []
  private var crossOverlay: NSView?
  private var incomingRooms: [StripTimedValue] = []
  private(set) var incomingAt: Int?
  private var groupTraced: (id: String, start: Double)?
  private var groupSamples: [[Double]] = []
  weak var dragBridge: StripDragBridge?
  var pageWidth: CGFloat = 0

  public override var isFlipped: Bool { true }

  init(windowId: String, profileId: String, favicons: SidebarFavicons) {
    self.windowId = windowId
    self.profileId = profileId
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    let clip = StripClipView()
    clip.drawsBackground = false
    scroll.contentView = clip
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .allowed
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.documentView = document
    document.addSubview(dock)
    document.addSubview(newTab)
    dock.layer?.zPosition = 2
    addSubview(scroll)
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { drag.cancel() }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public var scrolledX: CGFloat { scroll.contentView.bounds.minX }

  func update(state: BrowserState, host: StripHostState, current: Bool) {
    let next = StripContext(state: state, host: host, windowId: windowId, favicons: favicons, previous: context)
    next.send = { [weak self] action in self?.onAction(action) }
    let first = context == nil
    context = next
    reconcile(next)
    if first {
      revealed = next.activeId
    } else if current, revealed != next.activeId {
      revealed = next.activeId
      DispatchQueue.main.async { [weak self] in self?.revealActive(animated: true) }
    }
  }

  private func chipWidth(_ groupId: String, _ context: StripContext) -> CGFloat {
    context.state.groups[groupId].map(StripText.groupChipWidth) ?? 0
  }

  private func reconcile(_ context: StripContext) {
    let entries = context.query.entries(windowId: windowId, profileId: profileId)
    let layout = StripPageLayout(
      entries: entries, activeId: context.activeId, pageWidth: pageWidth, flare: context.host.floating ? 0 : StripMetrics.flare,
      chipWidth: { chipWidth($0, context) },
      folderWidth: { StripText.folderChipWidth(context.query.groupLabel($0)) })
    pageLayout = layout
    var liveTabs = Set<String>()
    var liveSplits = Set<String>()
    var liveGroups = Set<String>()
    dock.isHidden = layout.dockCells.isEmpty
    for item in layout.items {
      switch item.kind {
      case .dock(let cells, let members):
        dock.frame = NSRect(x: item.x, y: StripMetrics.itemTop, width: item.width, height: StripMetrics.itemHeight)
        dock.update(cells: cells, members: members, geometry: layout.dock, context)
      case .tab(let m):
        liveTabs.insert(m.id)
        let view = tabs[m.id] ?? make { StripTabChip() }
        tabs[m.id] = view
        view.frame.size = NSSize(width: StripLayout.pixel(item.width), height: StripMetrics.height)
        view.update(m.id, context)
      case .split(let m):
        liveSplits.insert(m.id)
        let view = splits[m.id] ?? make { StripSplitChip() }
        splits[m.id] = view
        view.frame.size = NSSize(width: StripLayout.pixel(item.width), height: StripMetrics.height)
        view.update(m.tabIds, context)
      case .folder:
        break
      case .group(let g):
        liveGroups.insert(g.entry.id)
        let view = groups[g.entry.id] ?? make { StripGroupView() }
        groups[g.entry.id] = view
        if let motion = motions[g.entry.id] {
          motion.retarget(g)
        } else {
          motions[g.entry.id] = StripGroupMotion(expanded: g.expanded, width: g.width, state: StripGroupMotion.state(g))
          motions[g.entry.id]?.retarget(g)
        }
        view.update(g, chip: layout.chip, context)
      case .newTab:
        newTab.update(context)
      }
    }
    for (id, view) in tabs where !liveTabs.contains(id) {
      view.removeFromSuperview()
      tabs[id] = nil
    }
    for (id, view) in splits where !liveSplits.contains(id) {
      view.removeFromSuperview()
      splits[id] = nil
    }
    for (id, view) in groups where !liveGroups.contains(id) {
      view.removeFromSuperview()
      groups[id] = nil
      motions[id] = nil
    }
    place()
    if motions.values.contains(where: \.running) { ticker.start() }
    syncHover()
  }

  private func place() {
    let h = StripMetrics.height
    let activeId = context?.activeId ?? ""
    var shift: CGFloat = 0
    let collapse = drag.collapse(.top)
    let rooms = incomingRooms.map(\.value)
    let room = { (slot: Int) in StripLayout.incomingShift(rooms, through: slot, chip: self.pageLayout.chip, gap: StripMetrics.gap) }
    for item in pageLayout.items {
      let x = StripLayout.pixel(item.x + shift + (item.slot.map(room) ?? 0))
      let lane = item.slot.map { drag.offset(.top, $0) } ?? 0
      switch item.kind {
      case .dock:
        let tuck = drag.collapse(.dock)
        dock.arrange { [drag] i, cell in
          drag.offset(.dock, i) + drag.translation(cell) - (tuck.map { i > $0.index ? $0.by : 0 } ?? 0)
        }
        dock.raised = { [drag] cell in drag.dragging(cell) }
        dock.grow = CGFloat(drag.grow.value)
      case .folder:
        break
      case .tab(let m):
        guard let view = tabs[m.id] else { break }
        view.frame = NSRect(x: x + lane + drag.translation(view), y: 0, width: StripLayout.pixel(item.width), height: h)
        view.layer?.zPosition = drag.dragging(view) ? 10 : activeId == m.id ? 1 : 0
      case .split(let m):
        guard let view = splits[m.id] else { break }
        view.frame = NSRect(x: x + lane + drag.translation(view), y: 0, width: StripLayout.pixel(item.width), height: h)
        view.layer?.zPosition = drag.dragging(view) ? 10 : m.tabIds.contains(activeId) ? 1 : 0
      case .group(let g):
        guard let view = groups[g.entry.id], let motion = motions[g.entry.id] else { continue }
        let size = CGFloat(motion.size.value)
        let groupLane = StripLane.group(g.entry.id)
        view.memberShift = { [drag] i, member in drag.offset(groupLane, i) + member.chips.reduce(0) { $0 + drag.translation($1) } }
        view.memberRaised = { [drag] member in member.chips.contains { drag.dragging($0) } }
        view.frame = NSRect(x: x + lane + drag.translation(view), y: 0, width: StripLayout.pixel(size), height: h)
        view.layer?.zPosition = drag.dragging(view) ? 10 : 0
        view.shownFade = motion.shown
        view.moving = motion.moving
        view.size = StripLayout.pixel(size)
        view.open = CGFloat(motion.open.value)
        view.arrange()
        shift += size - g.width
      case .newTab:
        newTab.frame = NSRect(
          x: StripLayout.pixel(item.x + shift + room(pageLayout.top.slots.count)) + drag.offset(.top, pageLayout.top.slots.count), y: StripMetrics.itemTop,
          width: StripMetrics.itemHeight, height: StripMetrics.itemHeight)
      }
      if let collapse, item.slot == collapse.index { shift -= collapse.by }
    }
    if let faded = fadedView, faded !== drag.fadingView { faded.alphaValue = 1 }
    fadedView = drag.fadingView
    fadedView?.alphaValue = drag.crossed ? 0 : drag.fadingAlpha
    placeCrossOverlay()
    document.frame = NSRect(x: 0, y: 0, width: max(pageLayout.contentWidth + shift + room(pageLayout.top.slots.count), scroll.frame.width), height: h)
  }

  private func tick(_ now: Double) -> Bool {
    for motion in motions.values { motion.step(now: now) }
    if let (id, start) = groupTraced, let size = motions[id]?.size.value { groupSamples.append([(now - start) * 1000, size]) }
    drag.tick(now)
    for i in incomingRooms.indices { incomingRooms[i].step(now: now) }
    place()
    let running = motions.values.contains(where: \.running) || drag.running || incomingRooms.contains(where: \.running)
    if !running { syncHover() }
    return running
  }

  private func make<V: NSView>(_ build: () -> V) -> V {
    let view = build()
    document.addSubview(view, positioned: .below, relativeTo: newTab)
    return view
  }

  public override func layout() {
    super.layout()
    scroll.frame = bounds
    document.frame.size.height = bounds.height
  }

  func revealActive(animated: Bool) {
    guard let context, !context.activeId.isEmpty, let span = pageLayout.span(of: context.activeId) else { return }
    let viewport = bounds.width
    guard let x = StripLayout.revealOffset(left: span.x, width: span.width, scrolled: scrolledX, viewport: viewport, pad: pageLayout.flare + StripMetrics.gap) else { return }
    let to = min(x, max(0, document.frame.width - viewport))
    if animated {
      NSAnimationContext.runAnimationGroup { motion in
        motion.duration = 0.3
        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: to, y: 0))
      }
    } else {
      scroll.contentView.setBoundsOrigin(NSPoint(x: to, y: 0))
    }
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @objc private func scrolled() { syncHover() }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseExited(with event: NSEvent) { hover(at: nil) }

  @objc private func devPointer(_ note: Notification) {
    guard let window, let screen = (note.object as? NSValue)?.pointValue else { return hover(at: nil) }
    let point = convert(window.convertPoint(fromScreen: screen), from: nil)
    hover(at: bounds.contains(point) && !isHiddenOrHasHiddenAncestor ? point : nil)
  }

  func syncHover() {
    guard let window, !isHiddenOrHasHiddenAncestor else { return hover(at: nil) }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    hover(at: bounds.contains(point) ? point : nil)
  }

  private func hover(at point: NSPoint?) {
    var next: [StripHoverView] = []
    if let point, !drag.active, let superview, var view = hitTest(convert(point, to: superview)) {
      while true {
        if let hoverable = view as? StripHoverView { next.append(hoverable) }
        guard let up = view.superview, up !== self else { break }
        view = up
      }
    }
    for view in hoveredViews where !next.contains(where: { $0 === view }) { view.hovered = false }
    for view in next { view.hovered = true }
    hoveredViews = next
  }

  public func groupSize(_ groupId: String) -> Double? { motions[groupId]?.size.value }

  public func traceGroup(_ groupId: String) {
    groupTraced = (groupId, StripTicker.now)
    groupSamples = motions[groupId].map { [[0, $0.size.value]] } ?? []
  }

  public var groupTrace: [[Double]] { groupSamples }

  public func incoming(at point: CGPoint?) -> String?? {
    let top = pageLayout.top
    if point == nil, incomingAt == nil { return nil }
    if incomingRooms.count != top.slots.count + 1 { incomingRooms = (0...top.slots.count).map { StripTimedValue($0 == incomingAt ? 1 : 0) } }
    var at: Int?
    if let point, point.y <= StripMetrics.height + 24, let state = context?.state {
      let start = document.convert(NSPoint(x: pageLayout.topStart, y: 0), to: nil).x
      at = StripLayout.incomingIndex(top, x: point.x - start) { id in state.groups.values.contains { $0.pinned && $0.tabIds.contains(id) } }
    }
    if at != incomingAt {
      incomingAt = at
      for i in incomingRooms.indices { incomingRooms[i].animate(to: i == at ? 1 : 0, duration: StripMotionTiming.incoming, easing: .cubic) }
      ticker.start()
    }
    guard let at else { return nil }
    return .some(at < top.slots.count ? top.slots[at].tabIds.first : nil)
  }

  public func endIncoming() {
    guard !incomingRooms.isEmpty else { return }
    incomingRooms = []
    incomingAt = nil
    place()
  }

  func slotKey(_ lane: StripLane, _ index: Int) -> String? {
    guard let g = geometry(lane), index < g.slots.count else { return nil }
    return g.slots[index].tabIds.joined(separator: ",")
  }

  public func traceSlot(_ tabIds: String) { drag.traceSlot(tabIds) }
  public var slotTrace: [[Double]] { drag.traced }

  var dragState: BrowserState? { context?.state }
  var selection: [String] { context?.host.selection ?? [] }
  var bridge: StripDragBridge? { dragBridge }

  func geometry(_ lane: StripLane) -> StripDragGeometry? {
    switch lane {
    case .top: return pageLayout.top
    case .dock: return pageLayout.dock
    case .group(let id):
      for item in pageLayout.items {
        if case .group(let g) = item.kind, g.entry.id == id { return g.geometry }
      }
      return nil
    }
  }

  var dropTargets: [StripDropTarget?] {
    var out: [StripDropTarget?] = []
    for item in pageLayout.items where item.slot != nil {
      switch item.kind {
      case .tab(let m): out.append(.tab(m.id))
      case .group(let g): out.append(.group(g.entry.id))
      default: out.append(nil)
      }
    }
    return out
  }

  func windowRect(_ view: NSView) -> CGRect? {
    guard let window = view.window, let content = window.contentView, view.superview != nil else { return nil }
    let r = view.convert(view.bounds, to: nil)
    return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  func dragChanged() {
    let dragged = drag.source?.view
    if draggedView !== dragged {
      (draggedView as? StripDraggable)?.dragged = false
      (dragged as? StripDraggable)?.dragged = true
      draggedView = dragged
      lowerRaised()
      if let dragged { raise(dragged, levels: drag.source.map(\.levels) ?? 0) }
    }
    place()
    if drag.running { ticker.start() }
  }

  private func raise(_ view: NSView, levels: Int) {
    var at: NSView? = view
    for _ in 0...max(0, levels) {
      guard let v = at, v !== document, let parent = v.superview else { return }
      if let i = parent.subviews.firstIndex(where: { $0 === v }), i < parent.subviews.count - 1 {
        raisedViews.append((v, parent.subviews[i + 1]))
        parent.addSubview(v, positioned: .above, relativeTo: nil)
      }
      if parent === document { return }
      at = parent
    }
  }

  private func lowerRaised() {
    for (view, below) in raisedViews.reversed() {
      guard let parent = view.superview, let below, below.superview === parent else { continue }
      parent.addSubview(view, positioned: .below, relativeTo: below)
    }
    raisedViews = []
  }

  var dockLeft: CGFloat { -(StripMetrics.dockWidth(pageLayout.dockCells.count) + StripMetrics.dockGap) }

  func crossChanged() {
    crossOverlay?.removeFromSuperview()
    crossOverlay = nil
    guard drag.crossed, let source = drag.source, let tabId = source.tabId, let context else { return }
    let overlay: StripHoverView
    switch source.cross {
    case .tabIn:
      let cell = StripPinnedCell()
      cell.frame.size = NSSize(width: StripMetrics.pinnedCell, height: StripMetrics.itemHeight - 1)
      cell.update(tabId, members: [tabId], context)
      overlay = cell
    case .pinOut:
      let chip = StripTabChip()
      chip.frame.size = NSSize(width: pageLayout.chip, height: StripMetrics.height)
      chip.update(tabId, context)
      chip.dragged = true
      overlay = chip
    case nil:
      return
    }
    overlay.passive = true
    document.addSubview(overlay)
    crossOverlay = overlay
    placeCrossOverlay()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = StripMotionTiming.onto
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    overlay.layer?.add(fade, forKey: "fade")
  }

  private func placeCrossOverlay() {
    guard let overlay = crossOverlay, let source = drag.source, source.view.superview != nil else { return }
    let f = source.view.convert(source.view.bounds, to: document)
    switch source.cross {
    case .tabIn:
      let top = pageLayout.top
      guard source.from >= 0, source.from < top.lefts.count else { return }
      let cell = StripMetrics.pinnedCell
      let limit = dockLeft + CGFloat(pageLayout.dockCells.count) * StripMetrics.cellStep - top.lefts[source.from] - drag.grabX + cell / 2
      let hold = StripLayout.tileHold(dx: CGFloat(drag.dx.value), limit: limit)
      overlay.frame = NSRect(x: f.minX + drag.grabX - cell / 2 + hold, y: StripMetrics.itemTop + 0.5, width: cell, height: StripMetrics.itemHeight - 1)
    case .pinOut:
      overlay.frame = NSRect(x: f.minX, y: 0, width: pageLayout.chip, height: StripMetrics.height)
    case nil:
      break
    }
  }

  func dragEnded() {
    syncHover()
  }

  func ontoChanged(from old: StripDropTarget?, to new: StripDropTarget?) {
    for (target, on) in [(old, false), (new, true)] {
      switch target {
      case .tab(let id): tabs[id]?.onto = on
      case .group(let id): groups[id]?.onto = on
      case nil: break
      }
    }
  }

  func dragSources(from view: NSView) -> [StripDragSource] {
    guard context != nil else { return [] }
    let gap = StripMetrics.gap
    var out: [StripDragSource] = []
    var at: NSView? = view
    while let v = at, v !== self {
      if let part = v as? StripSplitPart, !part.tabId.isEmpty {
        out.append(StripDragSource(view: part, lane: .top, from: -1, tabId: part.tabId, ids: [part.tabId], width: 0, gap: 0, axis: .y))
      } else if let chip = v as? StripTabChip, let tabId = chip.tabId {
        if let member = chip.superview as? StripMemberView {
          guard member.member?.kind == .tab, let source = memberSource(chip, member, tabId: tabId, ids: nil) else { return out }
          return out + [source]
        }
        guard let slot = slot(of: "tab:\(tabId)") else { return out }
        let cross: StripDragSource.Cross? = pageLayout.dockCells.isEmpty ? nil : .tabIn
        return out + [StripDragSource(view: chip, lane: .top, from: slot.index, tabId: tabId, width: slot.width, gap: gap, aims: true, cross: cross)]
      } else if let chip = v as? StripSplitChip, !chip.tabIds.isEmpty {
        if let member = chip.superview as? StripMemberView {
          guard let source = memberSource(chip, member, tabId: nil, ids: chip.tabIds) else { return out }
          return out + [source]
        }
        guard let item = pageLayout.items.first(where: { if case .split(let m) = $0.kind { m.tabIds == chip.tabIds } else { false } }), let index = item.slot
        else { return out }
        let slot = (index: index, width: item.width)
        return out + [StripDragSource(view: chip, lane: .top, from: slot.index, ids: chip.tabIds, width: slot.width, gap: gap, axis: .x)]
      } else if let header = v as? StripGroupHeader, let group = header.superview as? StripGroupView {
        guard let slot = slot(of: "group:\(header.groupId)") else { return out }
        let ids = context?.state.groups[header.groupId]?.tabIds ?? []
        return out + [StripDragSource(view: group, lane: .top, from: slot.index, ids: ids, width: 0, gap: 0, axis: .x, local: true, drop: .moveGroup(header.groupId))]
      } else if let cell = v as? StripPinnedCell, let i = dock.order.firstIndex(of: cell.cell) {
        let step = StripMetrics.pinnedSpacing
        if cell.folderId != nil {
          let ids = pageLayout.dockMembers[cell.cell] ?? []
          return out + [StripDragSource(view: cell, lane: .dock, from: i, ids: ids, pinned: true, width: StripMetrics.pinnedCell, gap: step, local: true, drop: .tileFolder)]
        }
        return out + [StripDragSource(view: cell, lane: .dock, from: i, tabId: cell.cell, pinned: true, width: StripMetrics.pinnedCell, gap: step, levels: 1, cross: .pinOut)]
      }
      at = v.superview
    }
    return out
  }

  private func slot(of key: String) -> (index: Int, width: CGFloat)? {
    guard let item = pageLayout.items.first(where: { $0.key == key }), let slot = item.slot else { return nil }
    return (slot, item.width)
  }

  private func memberSource(_ chip: NSView, _ member: StripMemberView, tabId: String?, ids: [String]?) -> StripDragSource? {
    guard let groupView = member.superview as? StripGroupView, let groupId = groupView.groupId, let m = member.member,
      let item = pageLayout.items.first(where: { $0.key == "group:\(groupId)" }), case .group(let g) = item.kind, let slot = item.slot,
      let i = g.members.firstIndex(where: { $0.member.id == m.id })
    else { return nil }
    let placed = g.members[i]
    let top = pageLayout.top
    let left = top.lefts[slot] + g.chip + StripMetrics.membersInset + (g.expanded ? placed.offset : 0)
    let from = g.expanded ? i : -1
    guard tabId != nil else {
      return StripDragSource(view: chip, lane: .group(groupId), from: from, ids: ids, groupId: groupId, width: placed.width, gap: StripMetrics.gap, axis: .x, levels: 1)
    }
    let end = (top.lefts.last ?? 0) + (top.slots.last?.width ?? 0)
    let range = (top.lefts[0] - left - placed.width / 2)...max(top.lefts[0] - left - placed.width / 2, end - left - placed.width / 2)
    let exit = StripMemberExit(slot: slot, chip: g.chip, expanded: g.expanded, left: left)
    return StripDragSource(
      view: chip, lane: .group(groupId), from: from, tabId: tabId, groupId: groupId, width: placed.width, gap: StripMetrics.gap, range: range, drop: .leaveGroup(exit),
      levels: 1)
  }

  public func frameOf(_ key: String) -> NSRect? {
    let view: NSView? =
      if key.hasPrefix("t:") { tabs[String(key.dropFirst(2))] ?? groupMemberChip(String(key.dropFirst(2))) ?? dock.cell(String(key.dropFirst(2))) }
      else if key.hasPrefix("s:") { splits[String(key.dropFirst(2))] }
      else if key.hasPrefix("g:") { groups[String(key.dropFirst(2))] }
      else if key == "newTab" { newTab }
      else { nil }
    guard let view, view.superview != nil else { return nil }
    return view.convert(view.bounds, to: self)
  }

  private func groupMemberChip(_ tabId: String) -> NSView? {
    for group in groups.values {
      for member in group.memberViews {
        for chip in member.chips { if let tab = chip as? StripTabChip, tab.tabId == tabId { return tab } }
      }
    }
    return nil
  }

  public func describe() -> [[String: Any]] {
    var out: [[String: Any]] = []
    func add(_ kind: String, _ id: String, _ view: NSView) {
      guard !view.isHidden, view.superview != nil else { return }
      let f = view.convert(view.bounds, to: self)
      out.append(["kind": kind, "id": id, "x": f.minX, "y": f.minY, "width": f.width, "height": f.height, "alpha": view.alphaValue])
    }
    for id in dock.order { if let cell = dock.cell(id) { add("pinned", id, cell) } }
    for (id, view) in tabs { add("tab", id, view) }
    for (id, view) in splits { add("split", id, view) }
    for (id, view) in groups {
      add("group", id, view)
      add("groupChip", id, view.header)
      for member in view.memberViews {
        for chip in member.chips {
          if let tab = chip as? StripTabChip, let tabId = tab.tabId { add("tab", tabId, tab) }
          if let folder = chip as? StripFolderChip { add("folderChip", folder.groupId, folder) }
          if let split = chip as? StripSplitChip { add("split", split.tabIds.joined(separator: ","), split) }
        }
      }
    }
    add("newTab", "", newTab)
    return out.sorted { ($0["x"] as? CGFloat ?? 0) < ($1["x"] as? CGFloat ?? 0) }
  }

  #if SOLARA_PROBES
  public func probeHoverTargets() -> [String] { allHoverViews().indices.map(String.init) }

  public func probeHoverFrames() -> [[String: Any]] {
    describe().enumerated().map { index, item in
      ["id": "\(item["kind"] ?? "")/\(item["id"] ?? "")/\(index)",
        "frame": [item["x"] ?? 0, item["y"] ?? 0, item["width"] ?? 0, item["height"] ?? 0]]
    }
  }

  public func probeHover(_ key: String, on: Bool) -> Bool {
    let targets = allHoverViews()
    guard let index = Int(key), targets.indices.contains(index) else { return false }
    targets[index].hovered = on
    layoutSubtreeIfNeeded()
    if !on { syncHover() }
    return true
  }
  #endif

  public func hoverShifts() -> (hovered: [String], shifts: [String]) {
    var shifts: [String] = []
    var hovered: [String] = []
    let views = allHoverViews()
    for view in views {
      let before = describe()
      view.hovered = true
      layoutSubtreeIfNeeded()
      let during = describe()
      view.hovered = false
      hovered.append(String(describing: type(of: view)))
      if before.count != during.count { shifts.append("\(type(of: view)) changed the item count") }
      for (a, b) in zip(before, during) where !Self.same(a, b) { shifts.append("\(type(of: view)) moved \(a["kind"] ?? "")/\(a["id"] ?? "")") }
    }
    syncHover()
    return (hovered, shifts)
  }

  private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    ["x", "y", "width", "height"].allSatisfy { (a[$0] as? CGFloat) == (b[$0] as? CGFloat) }
  }

  private func allHoverViews() -> [StripHoverView] {
    var out: [StripHoverView] = []
    func walk(_ v: NSView) {
      if let h = v as? StripHoverView, !h.isHiddenOrHasHiddenAncestor { out.append(h) }
      for s in v.subviews { walk(s) }
    }
    walk(document)
    return out
  }
}
