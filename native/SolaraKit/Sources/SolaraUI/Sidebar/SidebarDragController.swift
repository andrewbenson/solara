import AppKit
import SolaraModel
import SolaraStore

@MainActor
public protocol SidebarDragBridge: AnyObject {
  func dragBegan(windowId: String, tabId: String?, tabIds: [String])
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint)
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat)
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void)
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?)
  func escapeCapture(_ on: Bool)
  func haptic()
  func closeFolderPanel(windowId: String)
  func changed(windowId: String)
}

@MainActor
public enum SidebarDragHub {
  public static weak var bridge: SidebarDragBridge?
  public static var tabDrag: (outside: Bool, onPage: Bool) = (false, false)
  public static var probing = false
  static let controllers = NSMapTable<SidebarView, SidebarDragController>.weakToStrongObjects()

  public static func tabDragChanged(outside: Bool, onPage: Bool) {
    tabDrag = (outside, onPage)
    for case let controller as SidebarDragController in controllers.objectEnumerator()?.allObjects ?? [] where controller.active {
      controller.tabDragChanged()
    }
  }

  public static func controller(windowId: String) -> SidebarDragController? {
    (controllers.objectEnumerator()?.allObjects as? [SidebarDragController])?.first { $0.windowId == windowId && $0.view?.window != nil && $0.view?.isHiddenOrHasHiddenAncestor == false }
  }

  public static func cancel(windowId: String) -> Bool {
    guard let controller = controller(windowId: windowId), controller.active else { return false }
    controller.end(commit: false)
    return true
  }

  public static func escape() {
    for case let controller as SidebarDragController in controllers.objectEnumerator()?.allObjects ?? [] where controller.active {
      controller.end(commit: false)
    }
  }

  public static func capturesEscape(in window: NSWindow?) -> Bool {
    guard let window else { return true }
    return (controllers.objectEnumerator()?.allObjects ?? []).contains { object in
      guard let controller = object as? SidebarDragController else { return false }
      return (controller.active || controller.external > 0) && controller.view?.window === window
    }
  }

  public static func escapeCaptureSwallows(_ event: NSEvent, cancel: () -> Void) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}", modifiers.isEmpty else { return false }
    cancel()
    return capturesEscape(in: event.window)
  }
}

@MainActor
public final class SidebarDragController {
  weak var view: SidebarView?
  let windowId: String

  static let liveHeaderPrefix = SidebarLiveMetrics.headerKey("")
  static let rowGap = SidebarMetrics.rowGap
  static let rowHeight = SidebarMetrics.rowHeight
  static let pinSlot = PinZone.slot
  static let edge: CGFloat = 28
  static let folderHoldMs = 400
  static let threshold: CGFloat = 4

  private(set) var items: [String: DragItem] = [:]
  private var order: [DragItem] = []
  private var passive: [(view: NSView, frame: CGRect)] = []
  private var regionFrames: [String: CGRect] = [:]
  private var foreignRegions: [String: CGRect] = [:]
  private(set) var marks = DragMarks()
  private var sources: [DragItem] = []
  private var startScrollY: CGFloat = 0
  private var viewport: CGRect?
  private var rootFrame = CGRect.zero
  private var grab = CGPoint.zero
  private var pointer = CGPoint.zero
  private var ghost: SidebarDragGhostView?
  private var ghostSize = CGSize.zero
  private var ghostCount = 1
  private(set) var gapKey: String?
  private(set) var pitch: CGFloat = 0
  private var into: String?
  private var dropKey: JSONValue?
  private var drop: JSONValue = SidebarDrop.none
  private var sequence: [String]?
  private var scrollTimer: Timer?
  private var measured = false
  private var gridBase: CGRect?
  private var gridGrowth: CGFloat = 0
  private var tilesFixed = true
  private var tilesRoom: CGFloat = .infinity
  private(set) var external = 0
  private var escapable = false
  private var holdKey: String?
  private var holdReady: String?
  private var holdTimer: DispatchWorkItem?
  private var token = 0
  private var press: (row: SidebarRowView, at: CGPoint)?
  private(set) var settling = false
  private var landingKey: String?
  private var pinZone: SidebarPinSlotView?
  private var rings: [String: SidebarFolderRing] = [:]
  private var tileHomes: [String: CGRect] = [:]
  private var hidden: [NSView] = []
  private var shifted: Set<ObjectIdentifier> = []
  private var shiftedViews: [NSView] = []
  var landed: (key: String, x: CGFloat, y: CGFloat)?
  private var folderPanelOpen: Bool { panelFrame != nil }

  init(view: SidebarView) {
    self.view = view
    windowId = view.windowId
    let clipView: NSClipView = view.scroll.contentView
    scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if SidebarDragHub.probing { self?.changed() } }
    }
  }

  private var scrollObserver: NSObjectProtocol?

  public static func of(_ view: SidebarView) -> SidebarDragController {
    if let existing = SidebarDragHub.controllers.object(forKey: view) { return existing }
    let made = SidebarDragController(view: view)
    SidebarDragHub.controllers.setObject(made, forKey: view)
    return made
  }

  public static func existing(_ view: SidebarView) -> SidebarDragController? { SidebarDragHub.controllers.object(forKey: view) }

  public var active: Bool { !sources.isEmpty }
  var suppressesMotion: Bool { settling }

  private var bridge: SidebarDragBridge? { SidebarDragHub.bridge }
  private var context: SidebarContext? { view?.context }
  private var state: BrowserState? { context?.state }

  func press(_ row: SidebarRowView, _ event: NSEvent) {
    press = (row, windowPoint(event))
  }

  func dragged(_ row: SidebarRowView, _ event: NSEvent) -> Bool {
    let at = windowPoint(event)
    if active, external == 0 {
      move(at)
      return true
    }
    if swallowing { return true }
    guard let press, press.row === row else { return false }
    guard hypot(at.x - press.at.x, at.y - press.at.y) > Self.threshold, let key = dragKey(row) else { return false }
    self.press = nil
    begin(key, press.at)
    guard active else { return false }
    swallowing = true
    move(at)
    return true
  }

  func release(_ row: SidebarRowView, _ event: NSEvent) -> Bool {
    press = nil
    let swallowed = swallowing
    swallowing = false
    guard active, external == 0 else { return swallowed }
    move(windowPoint(event))
    end(commit: true)
    return true
  }

  private var swallowing = false

  private func windowPoint(_ event: NSEvent) -> CGPoint {
    let height = view?.window?.contentView?.bounds.height ?? 0
    return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
  }

  private func dragKey(_ row: SidebarRowView) -> String? {
    guard let kind = row.item?.kind else { return nil }
    switch kind {
    case .tile(let id): return "t:\(id)"
    case .folder(let id): return "tf:\(id)"
    case .tab(let id): return "t:\(id)"
    case .split(let id): return "s:\(id)"
    case .groupHeader(let id): return "g:\(id)"
    case .live(let key) where key.hasPrefix(Self.liveHeaderPrefix): return SidebarLive.prefix + key.dropFirst(Self.liveHeaderPrefix.count)
    default: return nil
    }
  }

  func windowRect(_ view: NSView) -> CGRect? {
    guard let window = view.window, let content = window.contentView, view.superview != nil else { return nil }
    let r = view.convert(view.bounds, to: nil)
    return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  private func windowRect(_ rect: CGRect, in view: NSView) -> CGRect? {
    guard let window = view.window, let content = window.contentView else { return nil }
    let r = view.convert(rect, to: nil)
    return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  func collect() {
    guard let view, let context else { return }
    items = [:]
    order = []
    passive = []
    if let floating { items[floating.key] = floating }
    let layout = view.pageLayout
    func add(_ item: DragItem) {
      items[item.key] = item
      order.append(item)
    }
    func section(_ s: SidebarItem.Section, group: Bool) -> DragSection {
      switch s {
      case .tiles: return .tiles
      case .pinned: return group ? .pinnedGroups : .pinnedRows
      default: return .list
      }
    }
    var listTop: CGFloat?
    var pinnedTop: CGFloat?
    var listBottom: CGFloat?
    var pinnedBottom: CGFloat?
    var groupBottoms: [String: CGFloat] = [:]
    var liveBox: DragItem?
    for entry in layout.items {
      guard let shown = view.views[entry.key] else { continue }
      let frame = windowRect(shown)
      let parent = entry.groups.last
      switch entry.kind {
      case .tile(let id):
        let item = DragItem(key: "t:\(id)", kind: .tile, tabIds: [id], section: .tiles)
        item.frame = frame
        item.views = [shown]
        item.fixed = entry.region == .fixed
        add(item)
      case .folder(let id):
        let item = DragItem(key: "tf:\(id)", kind: .tile, tabIds: context.query.folderMembers(windowId: windowId, id), section: .tiles)
        item.folderId = id
        item.frame = frame
        item.views = [shown]
        item.fixed = entry.region == .fixed
        add(item)
      case .tab(let id):
        let item = DragItem(key: "t:\(id)", kind: .row, tabIds: [id], section: section(entry.section, group: false))
        item.parentGroup = parent
        item.frame = frame
        item.views = [shown]
        add(item)
      case .split(let id):
        let item = DragItem(key: "s:\(id)", kind: .split, tabIds: context.query.splitPanes(id), section: section(entry.section, group: false))
        item.parentGroup = parent
        item.frame = frame
        item.views = [shown]
        add(item)
      case .groupBox(let id):
        let item = items["g:\(id)"] ?? DragItem(key: "g:\(id)", kind: .group, tabIds: context.state.groups[id]?.tabIds ?? [], section: section(entry.section, group: true))
        item.groupId = id
        item.parentGroup = entry.groups.dropLast().last
        item.collapsed = context.state.groups[id]?.collapsed == true || SidebarRail.contains(width: Double(view.bounds.width))
        item.frame = frame
        item.box = shown
        if items[item.key] == nil { add(item) }
      case .groupHeader(let id):
        let item = items["g:\(id)"] ?? DragItem(key: "g:\(id)", kind: .group, tabIds: context.state.groups[id]?.tabIds ?? [], section: section(entry.section, group: true))
        item.groupId = id
        item.headerFrame = frame
        item.views.append(shown)
        if items[item.key] == nil { add(item) }
      case .live(let key) where key.hasPrefix(SidebarLive.prefix):
        let item = DragItem(key: key, kind: .live, tabIds: [], section: section(entry.section, group: true))
        item.liveFolderId = String(key.dropFirst(SidebarLive.prefix.count))
        item.frame = frame
        item.box = shown
        add(item)
        liveBox = item
      case .live(let key) where key.hasPrefix(Self.liveHeaderPrefix):
        if SidebarRail.contains(width: Double(view.bounds.width)) {
          let id = String(key.dropFirst(Self.liveHeaderPrefix.count))
          let item = DragItem(key: SidebarLive.prefix + id, kind: .live, tabIds: [], section: section(entry.section, group: true))
          item.liveFolderId = id
          item.parentGroup = parent
          item.collapsed = true
          item.frame = frame
          add(item)
          liveBox = item
        }
        liveBox?.headerFrame = frame
        liveBox?.views.append(shown)
      case .live:
        if let box = liveBox, let frame, box.frame?.contains(frame) == true { box.views.append(shown) }
        else if let frame, entry.region == .scroll { passive.append((shown, frame)) }
      default:
        if let frame, entry.region == .scroll { passive.append((shown, frame)) }
      }
      guard let frame, entry.region == .scroll else { continue }
      let isEntry: Bool = {
        switch entry.kind {
        case .tab, .split, .groupBox, .live: return true
        default: return false
        }
      }()
      if case .newTab = entry.kind, entry.section == .list { listTop = min(listTop ?? frame.minY, frame.minY) }
      guard isEntry else { continue }
      if let parent, entry.kind != .groupBox(parent) {
        groupBottoms[parent] = max(groupBottoms[parent] ?? 0, frame.maxY)
      }
      if entry.groups.count > (entry.kind == .groupBox(entry.groups.last ?? "") ? 1 : 0) { continue }
      if entry.section == .list {
        listTop = min(listTop ?? frame.minY, frame.minY)
        listBottom = max(listBottom ?? frame.maxY, frame.maxY)
      } else if entry.section == .pinned {
        pinnedTop = min(pinnedTop ?? frame.minY, frame.minY)
        pinnedBottom = max(pinnedBottom ?? frame.maxY, frame.maxY)
      }
    }
    for item in order where item.kind == .group {
      guard let id = item.groupId, let box = item.frame else { continue }
      let tail = DragItem(key: "tail:group:\(id)", kind: .tail, tabIds: [], section: item.section == .pinnedGroups ? .pinnedGroups : .list)
      tail.parentGroup = id
      let bottom = groupBottoms[id] ?? (item.headerFrame?.maxY ?? box.minY)
      tail.frame = CGRect(x: box.minX + SidebarMetrics.groupIndent, y: bottom, width: box.width - SidebarMetrics.groupIndent, height: 0)
      add(tail)
    }
    let inner = CGRect(x: 0, y: 0, width: view.bounds.width - SidebarMetrics.inset * 2, height: 0)
    let rowsOrigin = windowRect(inner, in: view.rows)
    let divider = layout.items.first { $0.kind == .divider }.flatMap { view.views[$0.key] }.flatMap(windowRect)
    let x = rowsOrigin?.minX ?? 0
    let width = rowsOrigin?.width ?? 0
    let emptyListY: CGFloat
    if let divider {
      emptyListY = divider.maxY
    } else if let pinnedBottom {
      emptyListY = pinnedBottom + SidebarMetrics.sectionGap
    } else {
      emptyListY = (rowsOrigin?.minY ?? 0) + SidebarMetrics.glowRoom + SidebarMetrics.edgeInset
    }
    let listY: CGFloat = listTop ?? listBottom ?? emptyListY
    let pinnedY = pinnedTop ?? divider?.minY ?? listY
    regionFrames = [:]
    regionFrames["list"] = CGRect(x: x, y: listY, width: width, height: max(0, (listBottom ?? listY) - listY))
    regionFrames["pinnedGroups"] = CGRect(x: x, y: pinnedY, width: width, height: max(0, (pinnedBottom ?? pinnedY) - pinnedY))
    let listTail = DragItem(key: "tail:list", kind: .tail, tabIds: [], section: .list)
    listTail.frame = CGRect(x: x, y: listBottom ?? listY, width: width, height: 0)
    add(listTail)
    let pinnedTail = DragItem(key: "tail:pinnedGroups", kind: .tail, tabIds: [], section: .pinnedGroups)
    pinnedTail.frame = CGRect(x: x, y: pinnedBottom ?? pinnedY, width: width, height: 0)
    add(pinnedTail)
    let tiles = order.filter { $0.kind == .tile }
    if let first = tiles.first?.frame {
      let rows = Int((Double(tiles.count) / Double(max(1, layout.grid.columns))).rounded(.up))
      let height = CGFloat(rows) * SidebarMetrics.tileHeight + CGFloat(max(0, rows - 1)) * SidebarMetrics.tileGap
      let grid = CGRect(x: first.minX, y: first.minY, width: width, height: height)
      regionFrames["tiles"] = grid
      let tail = DragItem(key: "tail:tiles", kind: .tail, tabIds: [], section: .tiles)
      tail.frame = CGRect(x: grid.maxX, y: grid.maxY, width: 0, height: 0)
      add(tail)
    } else {
      add(DragItem(key: "tail:tiles", kind: .tail, tabIds: [], section: .tiles))
    }
    tilesFixed = layout.tilesFixed
    let pageHeight = max(0, view.bounds.height - (context.host.addressBar ? SidebarMetrics.glowRoom : 0))
    let topGap = SidebarMetrics.listTopGap(addressBar: context.host.addressBar)
    tilesRoom = pageHeight > 0 ? pageHeight * SidebarMetrics.dockShare - topGap - SidebarMetrics.edgeGap - SidebarMetrics.edgeLine : .infinity
    for (name, frame) in foreignRegions { regionFrames[name] = frame }
    addPanelItems()
  }

  private var nothingPinned: Bool { !order.contains { $0.kind == .tile } }

  private func zoneFrame() -> CGRect? {
    guard let view, let context, let base = windowRect(view.bounds, in: view) else { return nil }
    let header = context.host.addressBar ? 0 : SidebarMetrics.sidebarHeader - SidebarMetrics.glowRoom
    let x = base.minX + SidebarMetrics.inset
    let width = base.width - SidebarMetrics.inset * 2
    if context.host.addressBar { return CGRect(x: x, y: base.minY - 50, width: width, height: 40) }
    let top = base.minY - header
    return CGRect(x: x, y: top, width: width, height: marks.pins ? SidebarMetrics.pinnedTop + SidebarMetrics.tileHeight : SidebarMetrics.pinnedTop - Self.rowGap)
  }

  func begin(_ key: String, _ at: CGPoint) {
    guard !sourcesEnding, let view, let state else { return }
    collect()
    guard let item = items[key], item.kind != .tail else { return }
    let lead = (item.kind == .row || item.kind == .tile) && item.folderId == nil ? item.tabIds.first : nil
    let moving = floating?.key == key ? [] : lead.map { movingTabIds(state, $0) } ?? []
    sources = moving.count > 1
      ? order.filter { ($0.kind == .row || $0.kind == .tile) && $0.folderId == nil && $0.tabIds.contains { moving.contains($0) } }
      : [item]
    token += 1
    escapable = true
    bridge?.escapeCapture(true)
    if (item.kind == .row || item.kind == .tile) && item.folderId == nil {
      let tabIds = orderedUnique(sources.flatMap(\.tabIds))
      bridge?.dragBegan(windowId: windowId, tabId: sources.count == 1 ? item.tabIds.first : nil, tabIds: tabIds)
    }
    pointer = at
    startScrollY = scrollY
    viewport = windowRect(view.clip)
    rootFrame = windowRect(view) ?? .zero
    let grid = order.contains { $0.kind == .tile }
    gridBase = grid ? regionFrames["tiles"] : nil
    gridGrowth = 0
    let frame = item.frame ?? CGRect(x: at.x, y: at.y, width: 176, height: 33)
    grab = CGPoint(x: at.x - frame.minX, y: at.y - frame.minY)
    ghostCount = Set(sources.flatMap(\.tabIds)).count
    let height = item.boxed ? min(frame.height, item.headerFrame?.height ?? 33) : frame.height
    ghostSize = CGSize(width: frame.width, height: height)
    if (item.kind == .row || item.kind == .tile) && item.folderId == nil {
      bridge?.dragPicture(windowId: windowId, size: ghostSize, grab: grab)
    }
    landed = nil
    landingKey = nil
    marks = DragMarks()
    marks.sources = Set(sources.map(\.key))
    if item.boxed && !item.collapsed { marks.folded = item.key }
    makeGhost(item)
    hideSources()
    if nothingPinned {
      showPinZone()
      if let zone = zoneFrame() { regionFrames["tiles"] = zone }
    }
    measured = true
    move(pointer)
    changed()
  }

  private func orderedUnique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }

  private func movingTabIds(_ state: BrowserState, _ tabId: String) -> [String] {
    guard let context, let window = state.windows[state.tabs[tabId]?.windowId ?? ""] else { return [tabId] }
    let selection = Set(context.flags.selection)
    guard selection.count > 1, selection.contains(tabId) else { return [tabId] }
    return window.tabIds.filter { selection.contains($0) }
  }

  public func beginExternal(count: Int, at: CGPoint) {
    if active && external == 0 { return }
    reset()
    removeGhost()
    collect()
    external = max(1, count)
    let source = DragItem(key: "external", kind: .row, tabIds: [], section: .list)
    sources = [source]
    token += 1
    pointer = at
    startScrollY = scrollY
    if let view {
      viewport = windowRect(view.clip)
      rootFrame = windowRect(view) ?? .zero
    }
    let grid = order.contains { $0.kind == .tile }
    gridBase = grid ? regionFrames["tiles"] : nil
    gridGrowth = 0
    marks = DragMarks()
    measured = true
    move(at)
    changed()
  }

  public func moveExternal(_ at: CGPoint) {
    guard external > 0 else { return }
    move(at)
  }

  public func finishExternal(commit: Bool) -> JSONValue? {
    guard external > 0 else { return nil }
    let drop = measured ? self.drop : SidebarDrop.none
    reset()
    restoreAll()
    changed()
    guard commit, SidebarDrop.isTabs(drop) else { return nil }
    return drop["placement"]
  }

  func move(_ at: CGPoint) {
    guard !sourcesEnding else { return }
    pointer = at
    if external == 0 { bridge?.dragMoved(windowId: windowId, x: at.x, y: at.y) }
    guard measured, ghost != nil || external > 0 else { return }
    positionGhost()
    autoScroll(at.y)
    retarget()
  }

  func tabDragChanged() {
    ghost?.alphaValue = SidebarDragHub.tabDrag.onPage ? 0 : 1
    if measured { retarget() }
  }

  func cancelForModeChange() {
    press = nil
    swallowing = false
    guard active || landingKey != nil else { return }
    let tabsDrag = (sources.first?.kind == .row || sources.first?.kind == .tile) && sources.first?.folderId == nil
    let endBridge = active && external == 0 && !sourcesEnding && tabsDrag
    token += 1
    sourcesEnding = false
    reset()
    restoreAll()
    finishLanding()
    if endBridge { bridge?.dragEnded(windowId: windowId, commit: false) { _ in } }
    changed()
  }

  func end(commit: Bool) {
    if external > 0 {
      _ = finishExternal(commit: false)
      return
    }
    guard !sources.isEmpty, !sourcesEnding else { return }
    stopFollowingPopoverDrag()
    let sources = self.sources
    let drop = self.drop
    let sequence = self.sequence
    let wasMeasured = measured
    let into = self.into
    let leftPanel = sources.first?.section == .folder && marks.folderAway
    let ids = sources.flatMap(\.tabIds)
    let tabsDrag = (sources.first?.kind == .row || sources.first?.kind == .tile) && sources.first?.folderId == nil
    let endingToken = token
    let finish: @MainActor (Bool) -> Void = { [weak self] split in
      guard let self, self.token == endingToken else { return }
      let single = sources.count == 1 ? sources[0] : nil
      let lands = !split && wasMeasured && self.ghost != nil && single != nil && single!.kind != .tile && single!.section != .folder && into == nil
        && SidebarDrop.type(drop) != "onto" && SidebarDrop.type(drop) != "folder" && !(commit && SidebarDrop.pins(drop))
      let commits = commit && !split && wasMeasured && SidebarDrop.type(drop) != "none"
      self.reset()
      if leftPanel { self.bridge?.closeFolderPanel(windowId: self.windowId) }
      self.restoreAll(keepHidden: lands ? single.map { [$0.key] } ?? [] : [])
      if commits {
        self.settling = true
        self.bridge?.drop(windowId: self.windowId, ids: ids, drop: drop, sequence: sequence)
        self.settling = false
      }
      if lands, let single { self.land(single, home: !commits) } else { self.finishLanding() }
      self.changed()
    }
    if tabsDrag, let bridge {
      sourcesEnding = true
      bridge.dragEnded(windowId: windowId, commit: commit) { [weak self] split in
        guard let self, self.token == endingToken else { return }
        self.sourcesEnding = false
        finish(split)
      }
    } else {
      finish(false)
    }
  }

  private var sourcesEnding = false

  private func land(_ item: DragItem, home: Bool) {
    guard let view, let ghost else { return finishLanding() }
    let key = item.key
    let target: CGRect? = {
      collect()
      return items[key]?.frame
    }()
    guard let target else { return finishLanding() }
    landingKey = key
    marks.landing = key
    landed = (key, target.minX, target.minY)
    let from = ghost.frame
    let to = ghostFrame(for: CGPoint(x: target.minX, y: target.minY), in: view)
    ghost.frame = to
    let spring = SidebarSpring.make("position", from: NSValue(point: CGPoint(x: from.minX, y: from.minY)), to: NSValue(point: CGPoint(x: to.minX, y: to.minY)))
    spring.duration = SidebarSpring.restDuration(distance: hypot(to.minX - from.minX, to.minY - from.minY))
    let mine = token
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.token == mine else { return }
        self.finishLanding()
        self.changed()
      }
    }
    ghost.layer?.add(spring, forKey: "landing")
    CATransaction.commit()
    changed()
  }

  private func finishLanding() {
    landingKey = nil
    marks.landing = nil
    for view in hidden { view.alphaValue = 1 }
    hidden = []
    removeGhost()
    hidePinZone()
  }

  private func reset() {
    stopFollowingPopoverDrag()
    floating = nil
    scrollTimer?.invalidate()
    scrollTimer = nil
    clearHold()
    sources = []
    gapKey = nil
    pitch = 0
    dropKey = nil
    drop = SidebarDrop.none
    sequence = nil
    into = nil
    measured = false
    gridBase = nil
    gridGrowth = 0
    external = 0
    if escapable { bridge?.escapeCapture(false) }
    escapable = false
    let landing = marks.landing
    marks = DragMarks()
    marks.landing = landing
    for ring in rings.values { ring.removeFromSuperlayer() }
    rings = [:]
  }

  private func clearHold() {
    holdTimer?.cancel()
    holdTimer = nil
    holdKey = nil
    holdReady = nil
  }

  private func holdOver(_ target: DragItem) {
    if holdKey == target.key { return }
    clearHold()
    holdKey = target.key
    if target.folderId != nil {
      holdReady = target.key
      return
    }
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.holdKey == target.key, !self.sources.isEmpty else { return }
        self.holdReady = target.key
        self.retarget()
      }
    }
    holdTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.folderHoldMs), execute: work)
  }

  private var scrollY: CGFloat {
    guard let scroll: NSScrollView = view?.scroll else { return 0 }
    return scroll.contentView.bounds.minY
  }

  private func still(_ i: DragItem) -> Bool { (tilesFixed && i.section == .tiles) || i.section == .folder || i.fixed }

  private func at(_ f: CGRect?, fixed: Bool = false) -> CGRect? {
    guard let f else { return nil }
    if fixed { return f }
    let below = gridBase.map { tilesFixed || f.minY >= $0.maxY } ?? false
    return f.offsetBy(dx: 0, dy: -(scrollY - startScrollY) + (below ? gridGrowth : 0))
  }

  private func shown(_ i: DragItem) -> CGRect {
    let f = at(i.frame, fixed: still(i))!
    guard dropKey != nil, let base = i.frame else { return f }
    let (dy, dh) = offset(top: base.minY, bottom: base.maxY, item: i)
    return CGRect(x: f.minX, y: f.minY + dy, width: f.width, height: f.height + dh)
  }

  private func offset(top: CGFloat, bottom: CGFloat, item: DragItem?) -> (CGFloat, CGFloat) {
    var dy: CGFloat = 0
    var dh: CGFloat = 0
    if let gap = gapKey.flatMap({ items[$0] }), let g = gap.frame, gap.section != .tiles, item.map({ !gap.apart($0) }) ?? true {
      if g.minY <= top { dy += pitch } else if g.minY < bottom { dh += pitch }
    }
    for s in sources {
      guard s.kind != .tile, let f = s.frame, s !== item, item.map({ !s.apart($0) }) ?? true else { continue }
      let acrossSections = item.map { Self.pinnedArea(s.section) != Self.pinnedArea($0.section) } ?? false
      let closed = f.height + (s.parentGroup != nil || acrossSections ? 0 : Self.rowGap)
      if f.minY < top { dy -= closed } else if f.minY < bottom { dh -= closed }
    }
    return (dy, dh)
  }

  private static func pinnedArea(_ section: DragSection) -> Bool { section == .pinnedRows || section == .pinnedGroups }

  private var pinning: Bool { SidebarDrop.pins(drop) }
  private var rowPinning: Bool { SidebarDrop.rowPins(drop) }

  private func pinFloor(_ live: [DragItem], _ tiles: CGRect) -> CGFloat {
    let list = at(regionFrames["list"])
    let pinnedArea = at(regionFrames["pinnedGroups"])
    let rows = live.filter { $0.kind != .tail && ($0.section == .pinnedRows || $0.section == .pinnedGroups) }.compactMap { at($0.frame)?.minY }
    let top = ([list?.minY ?? tiles.maxY + SidebarMetrics.tileGap, pinnedArea?.minY ?? .infinity] + rows).min()!
    return tilesFixed ? max(top, tiles.maxY + gridGrowth + SidebarMetrics.edgeGap + SidebarMetrics.edgeLine) : top
  }

  private func overPinnedRows(_ y: CGFloat) -> Bool {
    guard let list = at(regionFrames["list"]) else { return false }
    return PinZone.over(y, listTop: list.minY, wasOver: rowPinning)
  }

  private struct Pointed {
    var cell: DragItem?
    var index: Int
    var gap: Int
    var part: String
  }

  private func pointed(_ tiles: CGRect, _ cells: [DragItem], _ count: Int, _ home: Int?, _ x: CGFloat, _ y: CGFloat, folders: Bool) -> Pointed? {
    guard gridBase != nil else { return nil }
    var count = count
    if !marks.pins && home == nil { count = 0 }
    let total = cells.count + count
    guard total > 0 else { return nil }
    let balanced = state?.settings.bool("balancedTopApps") ?? false
    let slot = PinZone.slot(grid: tiles, count: total, x: x, y: y, balanced: balanced)
    let found = !marks.pins ? (home ?? cells.count) : marks.pinBefore == "tail:tiles" ? cells.count : (cells.firstIndex { $0.key == marks.pinBefore } ?? -1)
    let gap = found < 0 ? cells.count : found
    let index = slot < gap ? slot : slot >= gap + count ? slot - count : -1
    guard index >= 0, index < cells.count else { return Pointed(cell: nil, index: gap, gap: gap, part: "gap") }
    let cell = cells[index]
    let grid = PinGrid.of(count: total, innerWidth: tiles.width, balanced: balanced)
    let mid = tiles.minX + CGFloat(slot % grid.columns) * (grid.width + SidebarMetrics.tileGap) + grid.width / 2
    let top = tiles.minY + CGFloat(slot / grid.columns) * Self.pinSlot
    let reach: CGFloat = holdReady == cell.key ? 0.45 : 0.3
    let centre = folders && abs(x - mid) < grid.width * reach && abs(y - (top + SidebarMetrics.tileHeight / 2)) <= (SidebarMetrics.tileHeight + SidebarMetrics.tileGap) / 2
    return Pointed(cell: cell, index: index, gap: gap, part: centre ? "centre" : x < mid ? "before" : "after")
  }

  private func ontoTarget(_ live: [DragItem], _ y: CGFloat, _ section: DragSection) -> String? {
    for i in live where i.kind == .row && i.parentGroup == nil && i.section == section {
      let f = shown(i)
      if y > f.minY + f.height * 0.25 && y < f.minY + f.height * 0.75 { return i.key }
    }
    return nil
  }

  private func retarget() {
    guard let state, let source = sources.first else { return }
    let x = pointer.x
    let y = pointer.y
    let sourceKeys = Set(sources.map(\.key))
    let subtree: Set<String>? = source.kind == .group ? source.groupId.map { Set([$0] + Groups.descendantIds(state.groups, $0)) } : nil
    let live = order.filter { i in
      !sourceKeys.contains(i.key) && i.frame != nil
        && !(subtree.map { t in (i.parentGroup.map(t.contains) ?? false) || (i.groupId.map(t.contains) ?? false) } ?? false)
    }
    func cy(_ i: DragItem) -> CGFloat {
      let f = shown(i)
      return f.minY + min(f.height, i.headerFrame?.height ?? f.height) / 2
    }
    func byY(_ a: DragItem, _ b: DragItem) -> Bool {
      let ay = at(a.frame, fixed: still(a))!.minY
      let by = at(b.frame, fixed: still(b))!.minY
      return ay != by ? ay < by : a.frame!.minX < b.frame!.minX
    }
    let dragged = Set(sources.flatMap(\.tabIds))
    func firstTab(_ i: DragItem?) -> String? { i?.tabIds.first { !dragged.contains($0) } }
    let tabsDrag = source.kind == .row || source.kind == .tile
    let count = external > 0 ? external : (source.folderId != nil ? 1 : dragged.count)
    let rowPitch = (source.boxed ? (SidebarMetrics.groupBorder * 2 + Self.rowHeight) : Self.rowHeight * CGFloat(source.kind == .split ? 1 : max(1, external > 0 ? external : ghostCount))) + Self.rowGap
    let blocks = live.filter(\.pinnedBlock).sorted(by: byY)
    let rest = blocks.map(\.key)
    let moved = sources.filter { $0.frame != nil }.sorted(by: byY).flatMap { s -> [String] in
      s.kind == .group || s.kind == .live || s.kind == .split ? [s.key] : s.tabIds.map { "t:\($0)" }
    }
    var dragSource = DragSource(kind: .tab, groupId: source.groupId, folderId: source.folderId, external: external > 0)
    switch source.kind {
    case .group: dragSource.kind = .group
    case .split: dragSource.kind = .split
    case .live: dragSource.kind = .live
    default: break
    }
    var aim: DropSpot?
    var sequence: [String]?
    var gapKey: String?
    var pitch = rowPitch
    var into: String?
    var onto: String?
    var folderTarget: String?
    var folderAway = false

    let sidebar = viewport ?? rootFrame
    let tiles = at(regionFrames["tiles"], fixed: tilesFixed)
    let balanced = state.settings.bool("balancedTopApps")
    let away = x > sidebar.maxX + 40 || x < sidebar.minX - 40 || (external == 0 && SidebarDragHub.tabDrag.outside)
    let cells = live.filter { $0.kind == .tile }.sorted(by: byY)
    let overTiles = !away && tabsDrag && tiles != nil && (gridBase != nil ? PinZone.over(y, listTop: pinFloor(live, tiles!), wasOver: pinning) : tiles!.holds(x, y, slop: 6))
    if let base = gridBase {
      let height = PinZone.height(cells.count + (overTiles ? count : 0), base.width, balanced)
      gridGrowth = min(height, tilesFixed ? tilesRoom : .infinity) - base.height
    }
    let list = at(regionFrames["list"])
    let inPinned = list.map { y < $0.minY } ?? false
    let panelFrame = folderPanelOpen ? regionFrames["folder"] : nil
    let wasAway = marks.folderAway
    let inPanel = !away && !wasAway && tabsDrag && external == 0 && (panelFrame?.holds(x, y) ?? false)
    if source.section == .folder && !inPanel { folderAway = true }
    let canFolder = tabsDrag && external == 0 && source.folderId == nil
    let home: Int? = source.section == .tiles && source.frame != nil ? cells.filter { byY($0, source) }.count : nil
    let spot = !away && tabsDrag && overTiles && tiles != nil ? pointed(tiles!, cells, count, home, x, y, folders: canFolder) : nil
    let target = spot?.part == "centre" ? spot?.cell : nil
    if let target { holdOver(target) } else { clearHold() }
    if away {
      aim = nil
    } else if inPanel {
      let members = live.filter { $0.section == .folder && $0.kind != .tail }.sorted(by: byY)
      let before = members.first { cy($0) > y }
      let anchor = members.first { firstTab($0) != nil }
      aim = anchor.map { .folder(ontoId: firstTab($0)!, beforeId: firstTab(before)) }
      gapKey = anchor != nil ? (before?.key ?? "tail:folder") : nil
    } else if let target, holdReady == target.key, let id = firstTab(target) {
      aim = .folder(ontoId: id, beforeId: nil)
      gapKey = self.gapKey
      pitch = self.pitch
      folderTarget = target.key
    } else if overTiles, let tiles {
      let index: Int
      if let spot {
        index = spot.part == "after" ? spot.index + 1 : spot.part == "before" ? spot.index : spot.gap
      } else {
        index = min(cells.count, PinZone.slot(grid: tiles, count: cells.count + count, x: x, y: y, balanced: balanced))
      }
      let before = gridBase != nil && index < cells.count ? cells[index] : nil
      aim = .tiles(beforeId: firstTab(before))
      sequence = rest
      gapKey = before?.key ?? "tail:tiles"
      pitch = Self.pinSlot
    } else {
      var hits: [(g: DragItem, into: Bool, h: CGFloat)] = []
      if tabsDrag || source.kind == .group || source.kind == .split {
        for g in live where g.kind == .group {
          let f = shown(g)
          let header = at(g.headerFrame).map { h in h.offsetBy(dx: 0, dy: f.minY - at(g.frame)!.minY) }
          let onHeader = header.map { $0.holds(x, y) && abs(y - $0.midY) < $0.height / 3 } ?? false
          if g.collapsed || (source.kind == .group && onHeader) {
            if onHeader { hits.append((g, true, f.height)) }
          } else if f.holds(x, y) && (header.map { y > $0.midY } ?? true) {
            hits.append((g, false, f.height))
          }
        }
        hits.sort { $0.h < $1.h }
      }
      if let hit = hits.first, hit.into, let groupId = hit.g.groupId {
        aim = .group(groupId: groupId, beforeId: nil)
        sequence = rest
        into = groupId
      } else if let hit = hits.first, let groupId = hit.g.groupId {
        let members = live.filter { ($0.kind == .row || $0.kind == .group || $0.kind == .split) && $0.parentGroup == groupId }.sorted(by: byY)
        let before = members.first { cy($0) > y }
        aim = .group(groupId: groupId, beforeId: firstTab(before))
        sequence = rest
        gapKey = before?.key ?? "tail:group:\(groupId)"
      } else if tabsDrag && external == 0, let found = ontoTarget(live, y, overPinnedRows(y) ? .pinnedRows : .list), let targetId = items[found]?.tabIds.first {
        onto = found
        aim = .onto(targetId: targetId)
        gapKey = self.gapKey
        pitch = self.pitch
      } else if ((tabsDrag || source.kind == .split) && overPinnedRows(y)) || ((source.kind == .group || source.kind == .live) && inPinned) {
        let before = blocks.first { cy($0) > y }
        let atIndex = before.flatMap { b in blocks.firstIndex { $0 === b } } ?? blocks.count
        let next = blocks[atIndex...].first { firstTab($0) != nil }
        aim = .pinnedRows(beforeId: firstTab(next))
        sequence = Array(rest[..<atIndex]) + moved + Array(rest[atIndex...])
        gapKey = before?.key ?? "tail:pinnedGroups"
      } else if source.kind != .live {
        let rows = live.filter { $0.section == .list && $0.parentGroup == nil && $0.kind != .tail && $0.kind != .tile }.sorted(by: byY)
        let before = rows.first { cy($0) > y && firstTab($0) != nil }
        gapKey = before?.key ?? "tail:list"
        aim = .list(beforeId: firstTab(before))
        sequence = rest
      }
    }
    let resolved = SidebarDrop.resolve(state, dragSource, aim)
    if SidebarDrop.type(resolved) == "none" {
      gapKey = nil
      into = nil
    }
    if SidebarDrop.type(resolved) != "onto" { onto = nil }
    marks.folderAway = folderAway
    let key: JSONValue = ["drop": resolved, "sequence": sequence.map { JSONValue($0) } ?? .null]
    if key == dropKey && gapKey == self.gapKey { return render() }
    if dropKey != nil && SidebarDrop.type(resolved) != "none" && state.settings.bool("tabReorderHaptics") { bridge?.haptic() }
    dropKey = key
    drop = resolved
    self.sequence = SidebarDrop.type(resolved) == "none" ? nil : sequence
    self.into = into
    let pins = SidebarDrop.pins(resolved)
    let held = SidebarDrop.type(resolved) == "folder" && !inPanel
    marks.dropInto = into
    marks.onto = onto
    marks.folderTarget = folderTarget
    marks.pins = pins || held
    marks.pinCount = pins || held ? count : 0
    marks.pinBefore = pins || held ? gapKey : nil
    self.gapKey = gapKey
    self.pitch = pitch
    render()
    changed()
  }

  private func makeGhost(_ item: DragItem) {
    guard let view, let context else { return }
    let ghost = SidebarDragGhostView()
    ghost.show(item, count: ghostCount, context: context)
    ghost.frame = NSRect(origin: .zero, size: ghostSize)
    view.addSubview(ghost)
    ghost.alphaValue = SidebarDragHub.tabDrag.onPage ? 0 : 1
    self.ghost = ghost
    positionGhost()
  }

  private func removeGhost() {
    ghost?.removeFromSuperview()
    ghost = nil
  }

  private func ghostFrame(for origin: CGPoint, in view: NSView) -> NSRect {
    guard let base = windowRect(view) else { return NSRect(origin: origin, size: ghostSize) }
    return NSRect(x: origin.x - base.minX, y: origin.y - base.minY, width: ghostSize.width, height: ghostSize.height)
  }

  private func positionGhost() {
    guard let ghost, let view, let source = sources.first else { return }
    var x = pointer.x - grab.x
    if source.boxed, let home = source.frame { x = home.minX }
    ghost.frame = ghostFrame(for: CGPoint(x: x, y: pointer.y - grab.y), in: view)
  }

  private func autoScroll(_ y: CGFloat) {
    let speed: CGFloat
    if let v = viewport {
      speed = y < v.minY + Self.edge ? -((v.minY + Self.edge - y) / 4).rounded(.up) : y > v.maxY - Self.edge ? ((y - (v.maxY - Self.edge)) / 4).rounded(.up) : 0
    } else {
      speed = 0
    }
    scrollTimer?.invalidate()
    scrollTimer = nil
    guard speed != 0 else { return }
    scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let scroll: NSScrollView = self.view?.scroll else { return }
        let limit = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        let next = min(limit, max(0, self.scrollY + speed))
        if next == self.scrollY { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: next))
        scroll.reflectScrolledClipView(scroll.contentView)
        self.retarget()
      }
    }
  }

  private func hideSources() {
    guard let state else { return }
    var keys = Set(sources.map(\.key))
    if let group = sources.first, group.kind == .group, let id = group.groupId {
      let subtree = Set([id] + Groups.descendantIds(state.groups, id))
      for i in order where (i.parentGroup.map(subtree.contains) ?? false) || (i.groupId.map(subtree.contains) ?? false) { keys.insert(i.key) }
    }
    for key in keys {
      guard let item = items[key] else { continue }
      for v in item.views + [item.box].compactMap({ $0 }) {
        v.alphaValue = 0
        hidden.append(v)
      }
    }
  }

  private func render() {
    guard let view else { return }
    let hiddenSet = Set(hidden.map(ObjectIdentifier.init))
    var targets: [(NSView, CGFloat)] = []
    let noGrid = gridBase == nil
    let tilesGap = noGrid && gapKey == "tail:tiles" && view.context?.host.addressBar != true ? pitch : 0
    for item in order where item.kind != .tile && item.kind != .tail {
      guard let f = item.frame else { continue }
      let (dy, dh) = offset(top: f.minY, bottom: f.maxY, item: item)
      for v in item.views where !hiddenSet.contains(ObjectIdentifier(v)) { targets.append((v, dy + tilesGap)) }
      if let box = item.box, !hiddenSet.contains(ObjectIdentifier(box)) {
        targets.append((box, dy + tilesGap))
        setBoxGrowth(box, dh)
      }
    }
    for (v, f) in passive {
      let (dy, _) = offset(top: f.minY, bottom: f.maxY, item: nil)
      targets.append((v, dy + tilesGap))
    }
    for (v, dy) in targets { shift(v, dy) }
    shift(view.clip, tilesFixed && gridBase != nil ? gridGrowth : 0)
    renderTiles()
    pinZone?.alphaValue = noGrid ? min(1, tilesGap / Self.pinSlot) : 0
    if let zone = pinZone, noGrid, let frame = zoneFrame(), let base = windowRect(view) {
      zone.frame = NSRect(x: frame.minX - base.minX, y: frame.minY - base.minY + SidebarMetrics.pinnedTop, width: frame.width, height: SidebarMetrics.tileHeight)
      regionFrames["tiles"] = frame
    }
  }

  private var boxHeights: [ObjectIdentifier: CGFloat] = [:]

  private func setBoxGrowth(_ box: NSView, _ dh: CGFloat) {
    let id = ObjectIdentifier(box)
    let was = boxHeights[id] ?? 0
    guard was != dh else { return }
    boxHeights[id] = dh
    var frame = box.frame
    frame.size.height += dh - was
    box.frame = frame
  }

  private func shift(_ v: NSView, _ dy: CGFloat) {
    guard let layer = v.layer else { return }
    let current = layer.transform.m42
    let id = ObjectIdentifier(v)
    if dy == 0 && !shifted.contains(id) { return }
    if !shifted.contains(id) {
      shifted.insert(id)
      shiftedViews.append(v)
    }
    guard abs(current - dy) > 0.01 else { return }
    let from = layer.presentation()?.transform ?? layer.transform
    let to = CATransform3DMakeTranslation(0, dy, 0)
    layer.transform = to
    layer.add(SidebarSpring.make("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to)), forKey: "dragShift")
  }

  private func renderTiles() {
    guard let state, let base = gridBase, let view else { return }
    let balanced = state.settings.bool("balancedTopApps")
    let cells = order.filter { $0.kind == .tile }.sorted { a, b in
      let ay = a.frame!.minY, by = b.frame!.minY
      return ay != by ? ay < by : a.frame!.minX < b.frame!.minX
    }
    let count = cells.filter { !marks.sources.contains($0.key) }.count + marks.pinCount
    let grid = PinGrid.of(count: count, innerWidth: base.width, balanced: balanced)
    var slot = 0
    for cell in cells {
      if marks.pinBefore == cell.key { slot += marks.pinCount }
      let mine = slot
      if !marks.sources.contains(cell.key) { slot += 1 }
      guard let v = cell.views.first, let parent = v.superview, let home = cell.frame else { continue }
      if tileHomes[cell.key] == nil { tileHomes[cell.key] = v.frame }
      let windowX = base.minX + CGFloat(mine % grid.columns) * (grid.width + SidebarMetrics.tileGap)
      let windowY = base.minY + CGFloat(mine / grid.columns) * Self.pinSlot
      let local = tileHomes[cell.key]!
      let next = NSRect(x: local.minX + (windowX - home.minX), y: local.minY + (windowY - home.minY), width: grid.width, height: local.height)
      _ = parent
      moveTile(v, to: next)
      if let ring = rings[cell.key] ?? (marks.folderTarget == cell.key ? makeRing(cell.key, v) : nil) {
        ring.show(marks.folderTarget == cell.key, palette: view.context!.palette, around: v.bounds)
      }
    }
  }

  private func makeRing(_ key: String, _ v: NSView) -> SidebarFolderRing {
    let ring = SidebarFolderRing()
    v.layer?.insertSublayer(ring, at: 0)
    rings[key] = ring
    return ring
  }

  private func moveTile(_ v: NSView, to next: NSRect) {
    guard v.frame != next else { return }
    let resized = v.frame.size != next.size
    let from = v.layer?.presentation()?.position ?? v.layer?.position ?? .zero
    v.frame = next
    guard !resized, let layer = v.layer else { return }
    layer.add(SidebarSpring.make("position", from: NSValue(point: from), to: NSValue(point: layer.position)), forKey: "dragSlot")
  }

  private func restoreAll(keepHidden: [String] = []) {
    let animated = false
    let keep = Set(keepHidden.flatMap { items[$0].map { $0.views + [$0.box].compactMap { $0 } } ?? [] }.map(ObjectIdentifier.init))
    for v in shiftedViews {
      guard let layer = v.layer else { continue }
      let from = layer.presentation()?.transform ?? layer.transform
      layer.removeAnimation(forKey: "dragShift")
      layer.transform = CATransform3DIdentity
      if animated && !CATransform3DIsIdentity(from) {
        layer.add(SidebarSpring.make("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "dragShift")
      }
    }
    shifted = []
    shiftedViews = []
    for (id, dh) in boxHeights where dh != 0 {
      guard let box = order.compactMap(\.box).first(where: { ObjectIdentifier($0) == id }) else { continue }
      var frame = box.frame
      frame.size.height -= dh
      box.frame = frame
    }
    boxHeights = [:]
    for (key, home) in tileHomes {
      guard let v = items[key]?.views.first else { continue }
      if animated { moveTile(v, to: home) } else { v.frame = home }
    }
    tileHomes = [:]
    var still: [NSView] = []
    for v in hidden {
      if keep.contains(ObjectIdentifier(v)) { still.append(v) } else { v.alphaValue = 1 }
    }
    hidden = still
    if still.isEmpty { hidePinZone() }
  }

  private func showPinZone() {
    guard let view, let context else { return }
    let zone = pinZone ?? SidebarPinSlotView()
    zone.paint(context.palette)
    if zone.superview !== view { view.addSubview(zone) }
    pinZone = zone
  }

  private func hidePinZone() {
    pinZone?.removeFromSuperview()
    pinZone = nil
  }

  static func placed(_ view: SidebarView) {
    if SidebarDragHub.probing { of(view).placed() } else { existing(view)?.placed() }
  }

  func placed() {
    if active, measured, !settling {
      collect()
      render()
    }
    if SidebarDragHub.probing { changed() }
  }

  private var panelMembers: [(tabId: String, frame: CGRect)] = []
  private var panelFrame: CGRect?

  public var foreignFolder: Any { panelFrame.map { $0.dragJSON } ?? NSNull() }

  public func setFolderPanel(_ json: Any?) {
    guard let panel = json as? [String: Any], let frame = Self.rect(panel["frame"]) else {
      panelFrame = nil
      panelMembers = []
      foreignRegions["folder"] = nil
      regionFrames["folder"] = nil
      return changed()
    }
    panelFrame = frame
    foreignRegions["folder"] = frame
    regionFrames["folder"] = frame
    panelMembers = (panel["members"] as? [[String: Any]] ?? []).compactMap { m in
      guard let id = m["tabId"] as? String, let f = Self.rect(m) else { return nil }
      return (id, f)
    }
    changed()
  }

  static func rect(_ any: Any?) -> CGRect? {
    guard let o = any as? [String: Any], let x = o["x"] as? Double, let y = o["y"] as? Double, let w = o["w"] as? Double, let h = o["h"] as? Double else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private func addPanelItems() {
    guard let panelFrame else { return }
    var bottom = panelFrame.minY
    for (id, frame) in panelMembers {
      let item = DragItem(key: "fm:\(id)", kind: .row, tabIds: [id], section: .folder)
      item.frame = frame
      items[item.key] = item
      order.append(item)
      bottom = max(bottom, frame.maxY)
    }
    let tail = DragItem(key: "tail:folder", kind: .tail, tabIds: [], section: .folder)
    tail.frame = CGRect(x: panelFrame.minX, y: bottom, width: panelFrame.width, height: 0)
    items[tail.key] = tail
    order.append(tail)
  }

  private var floating: DragItem?
  private var popoverFollow: PopoverDragFollow?

  var followsPopoverDrag: Bool { popoverFollow != nil }
  var applicationNotifications = NotificationCenter.default

  func popoverDrag(tabId: String, groupId: String, size: CGSize, at: CGPoint) {
    guard !active, !sourcesEnding else { return }
    collect()
    let key = "t:\(tabId)"
    guard items[key] == nil else { return }
    let home = order.first { $0.kind == .group && ($0.groupId == groupId || $0.tabIds.contains(tabId)) }
    let item = DragItem(key: key, kind: .row, tabIds: [tabId], section: home?.section == .pinnedGroups ? .pinnedRows : .list)
    item.parentGroup = groupId
    item.frame = CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height)
    floating = item
    begin(key, at)
    guard active else {
      floating = nil
      return
    }
    let follow = PopoverDragFollow(token: token)
    popoverFollow = follow
    follow.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
      let consumed = MainActor.assumeIsolated { () -> Bool in
        guard let self else {
          follow.stop()
          return false
        }
        return self.handlePopoverEvent(event)
      }
      return consumed ? nil : event
    }
    follow.applicationNotifications = applicationNotifications
    follow.resignObserver = applicationNotifications.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return follow.stop() }
        self.cancelPopoverDrag()
      }
    }
  }

  private func cancelPopoverDrag() {
    guard let follow = popoverFollow, follow.token == token, active, !sourcesEnding else { return stopFollowingPopoverDrag() }
    stopFollowingPopoverDrag()
    end(commit: false)
  }

  func handlePopoverEvent(_ event: NSEvent) -> Bool {
    guard let follow = popoverFollow, follow.token == token, active, external == 0, !sourcesEnding else {
      stopFollowingPopoverDrag()
      return false
    }
    guard let window = view?.window else {
      stopFollowingPopoverDrag()
      cancelForModeChange()
      return false
    }
    switch event.type {
    case .leftMouseDragged:
      move(popoverLocation(event))
    case .leftMouseUp:
      stopFollowingPopoverDrag()
      move(popoverLocation(event))
      end(commit: true)
    case .keyDown where event.keyCode == 53:
      stopFollowingPopoverDrag()
      end(commit: false)
      return event.window == nil || event.window === window
    default:
      return false
    }
    return true
  }

  private func stopFollowingPopoverDrag() {
    popoverFollow?.stop()
    popoverFollow = nil
  }

  func popoverLocation(_ event: NSEvent) -> CGPoint {
    guard let window = view?.window, let content = window.contentView else { return pointer }
    let local: NSPoint
    if event.window === window {
      local = event.locationInWindow
    } else if let source = event.window {
      local = window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
    } else {
      local = window.convertPoint(fromScreen: event.locationInWindow)
    }
    return CGPoint(x: local.x, y: content.bounds.height - local.y)
  }

  public func panelDrag(_ phase: String, tabId: String, at: CGPoint) {
    switch phase {
    case "begin":
      if active { return }
      begin("fm:\(tabId)", at)
    case "move":
      if active && external == 0 { move(at) }
    case "end":
      if active && external == 0 {
        move(at)
        end(commit: true)
      }
    default:
      if active { end(commit: false) }
    }
  }

  private func changed() {
    bridge?.changed(windowId: windowId)
  }

  public func probe() -> [String: Any] {
    if !active && landingKey == nil { collect() }
    var list: [[String: Any]] = []
    for item in order {
      guard var f = item.frame else { continue }
      if item.kind == .tile, let v = item.views.first, let r = windowRect(v) { f = r }
      else if item.kind != .tail, dropKey != nil || !shiftedViews.isEmpty {
        let (dy, dh) = offset(top: f.minY, bottom: f.maxY, item: item)
        f = CGRect(x: f.minX, y: f.minY + dy, width: f.width, height: f.height + dh)
      }
      if active, item.kind != .tile, item.kind != .tail, marks.sources.contains(item.key) { f.size.height = 0 }
      list.append([
        "key": item.key, "kind": item.kind.rawValue, "section": item.section.rawValue, "tabIds": item.tabIds,
        "parentGroup": item.parentGroup ?? NSNull(), "groupId": item.groupId ?? NSNull(), "folderId": item.folderId ?? NSNull(),
        "x": f.minX, "y": f.minY, "w": f.width, "h": f.height,
      ])
    }
    var regions: [String: Any] = [:]
    for (name, frame) in regionFrames where name != "folder" { regions[name] = frame.dragJSON }
    if active, nothingPinned, let zone = zoneFrame() { regions["tiles"] = zone.dragJSON }
    if !active, nothingPinned { regions["tiles"] = nil }
    let viewport: Any = view.flatMap { windowRect($0.clip) }.map { $0.dragJSON } ?? NSNull()
    return [
      "viewport": viewport, "scrollY": scrollY,
      "active": active, "external": external, "gapKey": gapKey ?? NSNull(), "pitch": pitch, "marks": marks.json, "items": list, "regions": regions,
      "landed": landed.map { ["key": $0.key, "x": $0.x, "y": $0.y] } ?? NSNull(),
    ]
  }

  public func clearLanded() { landed = nil }

  public func scroll(to y: CGFloat) {
    guard let scroll: NSScrollView = view?.scroll else { return }
    let limit = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, y))))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  public var marksJSON: [String: Any] { marks.json }

  public var panelOpen: Bool { panelFrame != nil }
}

@MainActor
final class PopoverDragFollow {
  let token: Int
  var monitor: Any?
  var resignObserver: NSObjectProtocol?
  var applicationNotifications = NotificationCenter.default

  init(token: Int) { self.token = token }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    if let resignObserver { applicationNotifications.removeObserver(resignObserver) }
    monitor = nil
    resignObserver = nil
  }
}
