import AppKit
import SolaraModel
import SolaraStore

@MainActor
public final class SidebarView: NSView {
  public let windowId: String
  public let favicons: SidebarFavicons
  public var onAction: (SidebarAction) -> Void = { _ in }
  public private(set) var pageLayout = SidebarPageLayout()

  var context: SidebarContext?
  private let fixed = SidebarLayer()
  private let edgeLine = CALayer()
  let clip = SidebarLayer()
  let scroll = NSScrollView()
  private let document = SidebarDocumentView()
  private let boxes = SidebarLayer()
  let rows = SidebarLayer()
  private let dock = SidebarLayer()
  private let pill = SidebarActivePill()
  private let panels = SidebarLayer()
  private var pillShown = false
  var views: [String: NSView] = [:]
  private var hoveredKey: String?
  private var hoveredGroup: String?
  private var tracking: NSTrackingArea?
  private var edgeShown = false
  private var clipShift: CGFloat = 0
  private var lastSize = NSSize.zero
  private var player: SidebarPlayerView?
  private var railShown = false

  public override var isFlipped: Bool { true }

  public init(windowId: String, favicons: SidebarFavicons = SidebarFavicons()) {
    self.windowId = windowId
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    edgeLine.actions = SurfaceLayer.noActions
    edgeLine.opacity = 0
    fixed.wantsLayer = true
    fixed.layer?.addSublayer(edgeLine)
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.verticalScrollElasticity = .allowed
    scroll.horizontalScrollElasticity = .none
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.drawsBackground = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.documentView = document
    document.owner = self
    document.addSubview(boxes)
    document.addSubview(rows)
    clip.addSubview(scroll)
    addSubview(clip)
    addSubview(fixed)
    addSubview(dock)
    dock.wantsLayer = true
    pill.alphaValue = 0
    pill.onPress = { [weak self] in self?.revealActive() }
    addSubview(pill)
    addSubview(panels)
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    UnreadBadges.start()
    NotificationCenter.default.addObserver(self, selector: #selector(heavyChanged), name: UnreadBadges.changed, object: nil)
    DevPointer.observe(self, #selector(devPointer(_:)))
    NotificationCenter.default.addObserver(self, selector: #selector(coverChanged(_:)), name: WindowShellView.hoverCoverChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(liveChanged), name: SidebarLiveFeed.changed, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(heavyChanged), name: HeavyTabs.changed, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(state: BrowserState, host: SidebarHostState) {
    UnreadBadges.retain(tabIds: Set(state.tabs.keys))
    UnreadBadges.setEnabled(state.settings["showUnreadBadges"]?.bool != false)
    let next = SidebarContext(state: state, host: host, windowId: windowId, favicons: favicons, previous: context)
    next.send = { [weak self] action in self?.onAction(action) }
    let previous = context
    let moved = previous != nil && previous?.activeId != next.activeId
    if moved, let window { TabNumberHintFeed.shared.cancel(in: window) }
    context = next
    SidebarFolderPanelHost.refreshHints(on: self)
    let resting = motion
    if let previous, SidebarMotion.folding(previous.state, next.state, windowId: windowId) { motion = .fold }
    reconcile(animated: previous != nil && canAnimate && SidebarDragController.existing(self)?.suppressesMotion != true)
    motion = resting
    if let previous { revealChanges(from: previous, to: next) }
    if moved && !isHiddenOrHasHiddenAncestor { NotificationCenter.default.post(name: Self.selectionShown, object: self) }
  }

  private func revealChanges(from previous: SidebarContext, to next: SidebarContext) {
    let active = next.activeId
    let before = previous.activeId
    var target: String?
    if let active, active != before, !closedAway(before, previous.state, next.state) { target = active }
    if target == nil, let window = next.state.windows[windowId], let was = previous.state.windows[windowId], window.tabIds != was.tabIds {
      let had = Set(was.tabIds)
      target = window.tabIds.last { !had.contains($0) && next.state.tabs[$0]?.openerId != nil && $0 != active }
    }
    if let target { reveal(target, next) }
  }

  private func closedAway(_ tabId: String?, _ before: BrowserState, _ after: BrowserState) -> Bool {
    guard let tabId else { return false }
    guard let tab = after.tabs[tabId] else { return true }
    return tab.unloaded == true && before.tabs[tabId]?.unloaded != true
  }

  private func scrollItem(_ tabId: String, _ context: SidebarContext) -> SidebarItem? {
    let shown = pageLayout.items.filter { $0.region == .scroll }
    return shown.first { $0.kind == .tab(tabId) }
      ?? shown.first { if case .split(let id) = $0.kind { context.query.holdsTab("s:\(id)", tabId) } else { false } }
      ?? shown.last { if case .groupHeader(let id) = $0.kind { context.query.holdsTab("g:\(id)", tabId) } else { false } }
  }

  private func revealActive() {
    guard let context, let active = context.activeId else { return }
    reveal(active, context)
  }

  private func reveal(_ tabId: String, _ context: SidebarContext) {
    guard let item = scrollItem(tabId, context) else { return }
    let viewport = scroll.frame.height
    let top = scroll.contentView.bounds.minY
    let y = item.frame.minY
    let pad = SidebarMetrics.glowRoom + SidebarMetrics.edgeInset
    var to: CGFloat
    if y - top < SidebarMetrics.glowRoom {
      to = max(0, y - pad)
    } else if item.frame.maxY - top > viewport - 8 {
      to = item.frame.maxY - viewport + 8
    } else {
      return
    }
    to = min(to, max(0, document.frame.height - viewport))
    guard abs(to - top) > 0.5 else { return }
    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: to))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  public static let selectionShown = Notification.Name("SolaraSidebarSelectionShown")

  public func updateHost(_ host: SidebarHostState) {
    guard let context else { return }
    update(state: context.state, host: host)
  }

  public func frameOf(_ key: String) -> NSRect? {
    guard let view = [key, "t:\(key)", "tile:\(key)", "gh:\(key)", "folder:\(key)"].lazy.compactMap({ self.views[$0] }).first else { return nil }
    if view.superview == nil || view.isHidden { return nil }
    return view.convert(view.bounds, to: self)
  }

  public var hoverKey: String? { hoveredKey }

  public func motionSample() -> [[String: Any]] {
    let folds: [[String: Any]] = boxes.subviews.compactMap { view in
      guard let box = view as? SidebarFoldingBox else { return nil }
      let key = (box as? GroupBoxView)?.item?.key ?? (box as? SidebarRowView)?.item?.key ?? ""
      return ["key": key, "y": box.frame.minY, "height": box.shownHeight, "box": true]
    }
    return folds + rows.subviews.compactMap { view in
      guard let row = view as? SidebarRowView, let key = row.item?.key, let layer = row.layer else { return nil }
      let shown = layer.presentation() ?? layer
      return ["key": key, "y": row.frame.minY, "shownY": shown.frame.minY, "alpha": Double(shown.opacity), "retired": row.retired,
              "clip": (shown.mask?.presentation() ?? shown.mask).map { Double($0.frame.minY) } ?? NSNull()]
    }
  }

  #if SOLARA_PROBES
  public func probeUnreadBadges() -> [[String: Any]] {
    func badges(_ view: NSView) -> [UnreadBadgeView] {
      if let badge = view as? UnreadBadgeView { return [badge] }
      return view.subviews.flatMap(badges)
    }
    return views.keys.sorted().flatMap { key -> [[String: Any]] in
      guard let view = views[key] else { return [] }
      return badges(view).map { badge in
        let rect = badge.convert(badge.bounds, to: self)
        return ["key": key, "visible": !badge.isHiddenOrHasHiddenAncestor,
          "status": badge.status?.accessibilityLabel ?? "", "text": badge.label.stringValue,
          "frame": [rect.minX, rect.minY, rect.width, rect.height]]
      }
    }
  }

  public func probeHoverTargets() -> [String] {
    views.values.compactMap { $0 as? SidebarRowView }.filter { $0.window != nil && !$0.isHidden }.compactMap { $0.item?.key }.sorted()
  }

  public func probeHoverFrames() -> [[String: Any]] {
    var frames: [[String: Any]] = []
    for key in probeHoverTargets() {
      guard let row = views[key] as? SidebarRowView else { continue }
      let frame = row.frame
      frames.append(["id": key, "frame": [frame.minX, frame.minY, frame.width, frame.height]])
      for (index, view) in row.body.subviews.enumerated() where !view.isHidden {
        frames.append(["id": "\(key)/\(index)", "origin": [view.frame.minX, view.frame.minY]])
      }
    }
    return frames
  }

  public func probeHover(_ key: String, on: Bool) -> Bool {
    guard probeHoverTargets().contains(key), let row = views[key] as? SidebarRowView else { return false }
    row.hovered = on
    layoutSubtreeIfNeeded()
    return true
  }
  #endif

  public func hoverShifts() -> (hovered: Int, shifts: [String]) {
    let rows = views.values.compactMap { $0 as? SidebarRowView }.filter { $0.window != nil && !$0.isHidden }
    func placed() -> [String: CGRect] {
      var out: [String: CGRect] = [:]
      for row in rows {
        let key = row.item?.key ?? ""
        out[key] = row.frame
        for (i, view) in row.body.subviews.enumerated() where !view.isHidden {
          out["\(key)/\(i)"] = CGRect(origin: view.frame.origin, size: .zero)
        }
      }
      return out
    }
    var shifts: [String] = []
    for row in rows {
      let before = placed()
      row.hovered = true
      layoutSubtreeIfNeeded()
      let after = placed()
      row.hovered = false
      layoutSubtreeIfNeeded()
      for (key, frame) in before {
        guard let moved = after[key], moved != frame else { continue }
        shifts.append("hovering \(row.item?.key ?? ""): \(key) \(frame) -> \(moved)")
      }
    }
    return (rows.count, shifts)
  }

  public var panelLayer: NSView { panels }

  public override func layout() {
    super.layout()
    panels.frame = bounds
    if bounds.size != lastSize {
      lastSize = bounds.size
      reconcile()
    }
  }

  private var canAnimate: Bool {
    window != nil && !isHiddenOrHasHiddenAncestor && !pageLayout.items.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func reconcile(animated: Bool = false) {
    guard let context, bounds.width > 0 else { return }
    var input = SidebarLayoutInput(windowId: windowId, profileId: context.host.profileId, width: bounds.width, height: bounds.height)
    input.rail = SidebarRail.contains(width: Double(bounds.width))
    if input.rail != railShown {
      SidebarDragController.existing(self)?.cancelForModeChange()
      setHover(nil, group: nil)
      sendHoverTarget()
      railShown = input.rail
      for view in views.values { view.removeFromSuperview() }
      views.removeAll()
    }
    input.addressBar = context.host.addressBar
    input.newTabAtTop = context.host.newTabAtTop
    input.balanced = context.state.settings.bool("balancedTopApps")
    var entries = context.query.entries(windowId: windowId, profileId: context.host.profileId)
    if let live = SidebarLiveFeed.shared.live {
      let blocks = SidebarLiveBlocks(live, state: context.state, windowId: windowId, profileId: context.host.profileId)
      input.live = blocks
      context.live = blocks
      entries.pinned = blocks.sequence(entries.pinned)
    }
    context.host.clear = context.showClear && !entries.list.isEmpty
    input.divided = context.host.tidy || context.host.clear
    input.incognitoBadge = context.host.addressBar && context.host.incognito
    input.playerHeight = context.host.player == nil ? 0 : SidebarPlayerView.height + SidebarPlayerView.gap
    if context.host.upsell != nil {
      input.upsellHeight = CleanUpUpsellView.height(width: bounds.width - SidebarMetrics.inset * 2, product: context.host.product ?? "Solara")
    }
    let next = SidebarLayout(query: context.query, input: input).layout(entries)
    pageLayout = next
    place(next, context, animated: animated)
  }

  private func place(_ layout: SidebarPageLayout, _ context: SidebarContext, animated: Bool) {
    let width = bounds.width
    let inset = SidebarMetrics.inset
    fixed.frame = NSRect(x: 0, y: 0, width: width, height: layout.fixedHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edgeLine.frame = CGRect(x: 0, y: layout.lineY, width: width, height: SidebarMetrics.edgeLine)
    edgeLine.backgroundColor = context.palette.scrollEdge.cgColor
    CATransaction.commit()
    let scrollHeight = max(0, layout.scrollBottom - layout.scrollTop)
    clip.frame = NSRect(x: 0, y: layout.scrollTop + clipShift, width: width, height: max(0, scrollHeight - clipShift))
    scroll.frame = NSRect(x: 0, y: -clipShift, width: width, height: scrollHeight)
    let docHeight = max(layout.contentHeight, scrollHeight)
    if document.frame.size != NSSize(width: width, height: docHeight) {
      document.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
    }
    boxes.frame = NSRect(x: inset, y: 0, width: width - inset * 2, height: docHeight)
    rows.frame = boxes.frame
    dock.frame = bounds
    let pillSize = SidebarActivePill.size
    pill.frame = NSRect(
      x: ((width - pillSize.width) / 2).rounded(), y: layout.scrollBottom - SidebarActivePill.gapAboveDock - pillSize.height,
      width: pillSize.width, height: pillSize.height)

    var seen = Set<String>()
    var slides: [(view: NSView, to: NSRect)] = []
    var inserted: [NSRect] = []
    for item in layout.items {
      seen.insert(item.key)
      let parent: NSView
      switch (item.region, item.kind) {
      case (.fixed, _): parent = fixed
      case (.dock, _): parent = dock
      case (_, .groupBox): parent = boxes
      case (_, .live(let key)) where key.hasPrefix(SidebarLive.prefix): parent = boxes
      default: parent = rows
      }
      let known = views[item.key]
      let view = known ?? make(item.kind)
      views[item.key] = view
      let reparented = view.superview !== parent
      if reparented { parent.addSubview(view) }
      let slidesHere = animated && known != nil && !reparented && item.region == .scroll
      if view.frame != item.frame {
        if slidesHere && (view.frame.size == item.frame.size || parent === rows || parent === boxes) {
          slides.append((view, item.frame))
        } else {
          view.frame = item.frame
        }
      }
      if animated && known == nil && item.region == .scroll && parent === rows { inserted.append(item.frame) }
      if let row = view as? SidebarRowView {
        row.update(item, context)
        row.hovered = hoveredKey == item.key
      } else if let box = view as? GroupBoxView {
        box.update(item, context)
        box.show(hoveredGroup == groupId(item.kind), animated: false)
      }
    }
    for (key, view) in views where !seen.contains(key) {
      views[key] = nil
      if animated && (view.superview === rows || view.superview === boxes) { retire(view) } else { view.removeFromSuperview() }
    }
    if let hoveredKey, !seen.contains(hoveredKey) { self.hoveredKey = nil }
    if !slides.isEmpty { slide(slides, under: inserted) }
    syncEdge()
    syncPill()
    if animated { syncPointer() }
    placePlayer(layout, context)
    SidebarDragController.placed(self)
  }

  private func placePlayer(_ layout: SidebarPageLayout, _ context: SidebarContext) {
    guard let frame = layout.playerFrame, let state = context.host.player else {
      player?.isHidden = true
      return
    }
    let view = player ?? {
      let made = SidebarPlayerView()
      made.onAction = { [weak self] action in
        guard let tabId = self?.context?.host.player?.tabId else { return }
        self?.onAction(.media(tabId: tabId, action: action))
      }
      addSubview(made, positioned: .below, relativeTo: pill)
      return made
    }()
    player = view
    view.isHidden = false
    if view.frame != frame { view.frame = frame }
    view.update(state)
  }

  static let slideDuration: TimeInterval = 0.14
  static let slideCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
  static let fadeDuration: TimeInterval = 0.10
  static let fadeCurve = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)

  private var motion = SidebarMotion.standard

  private func slide(_ moves: [(view: NSView, to: NSRect)], under inserted: [NSRect]) {
    let timing = self.motion
    NSAnimationContext.runAnimationGroup { motion in
      motion.duration = timing.slide
      motion.timingFunction = timing.slideCurve
      for (view, to) in moves {
        let from = view.frame
        if let box = view as? SidebarFoldingBox, from.size != to.size {
          box.fold(to: to, motion: timing)
          continue
        }
        view.animator().frame = to
        if to.minY > from.minY, let cover = inserted.first(where: { $0.minY <= from.minY + 0.5 && $0.maxY > from.minY + 0.5 }) {
          clipUnder(view, from: from, to: to, edge: cover.maxY)
        }
      }
    }
  }

  private func clipUnder(_ view: NSView, from: NSRect, to: NSRect, edge: CGFloat) {
    guard let layer = view.layer else { return }
    let mask = CALayer()
    mask.backgroundColor = NSColor.black.cgColor
    mask.actions = SurfaceLayer.noActions
    let hiddenFrom = edge - from.minY
    let hiddenTo = min(0, edge - to.minY)
    let size = CGSize(width: to.width, height: to.height)
    func originY(_ hidden: CGFloat) -> CGFloat { view.isFlipped ? hidden : -hidden }
    mask.frame = CGRect(origin: CGPoint(x: 0, y: originY(hiddenTo)), size: size)
    layer.mask = mask
    let move = CABasicAnimation(keyPath: "position.y")
    move.fromValue = originY(hiddenFrom) + size.height / 2
    move.toValue = originY(hiddenTo) + size.height / 2
    move.duration = motion.slide
    move.timingFunction = motion.slideCurve
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak layer, weak mask] in
      if let layer, layer.mask === mask { layer.mask = nil }
    }
    mask.add(move, forKey: "clip")
    CATransaction.commit()
  }

  private func retire(_ view: NSView) {
    (view as? SidebarRowView)?.retire()
    view.superview?.addSubview(view, positioned: .below, relativeTo: nil)
    let timing = self.motion
    NSAnimationContext.runAnimationGroup { motion in
      motion.duration = timing.fade
      motion.timingFunction = timing.fadeCurve
      view.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated { view.removeFromSuperview() }
    }
  }

  private func groupId(_ kind: SidebarItemKind) -> String? {
    if case .groupBox(let id) = kind { return id }
    return nil
  }

  private func make(_ kind: SidebarItemKind) -> NSView {
    if railShown, let rail = SidebarRail.make(kind) { return rail }
    return switch kind {
    case .tab: TabRowView()
    case .split: SplitRowView()
    case .groupHeader: GroupHeaderView()
    case .groupBox: GroupBoxView()
    case .newTab: NewTabRowView()
    case .divider: DividerRowView()
    case .tile, .folder: TileView()
    case .incognito: IncognitoBadgeView()
    case .upsell: CleanUpUpsellView()
    case .live(let key): SidebarLiveViews.make(key)
    }
  }

  @objc private func heavyChanged() {
    guard let context else { return }
    update(state: context.state, host: context.host)
  }

  @objc private func liveChanged() {
    guard let context else { return }
    motion = SidebarLiveFeed.shared.motion
    update(state: context.state, host: context.host)
    motion = .standard
  }

  private var scrolledTop: CGFloat = 0

  @objc private func scrolled() {
    let top = scroll.contentView.bounds.minY
    if top != scrolledTop {
      scrolledTop = top
      onAction(.scrolled)
    }
    syncEdge()
    syncPill()
    syncPointer()
  }

  private func syncPill() {
    let top = scroll.contentView.bounds.minY
    let viewport = scroll.frame.height
    var shown = false
    if let context, let active = context.activeId, let tab = context.state.tabs[active], let item = scrollItem(active, context),
      viewport > 0, item.frame.maxY <= top || item.frame.minY >= top + viewport
    {
      shown = true
      pill.set(context.iconSpec(tab), title: context.title(tab), up: item.frame.maxY <= top, palette: context.palette, favicons: favicons)
    }
    guard shown != pillShown else { return }
    pillShown = shown
    NSAnimationContext.runAnimationGroup { motion in
      motion.duration = 0.1
      motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
      pill.animator().alphaValue = shown ? 1 : 0
    }
  }

  private func fade(_ line: CALayer, shown: Bool, was: inout Bool) {
    guard shown != was else { return }
    was = shown
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = line.presentation()?.opacity ?? line.opacity
    fade.toValue = shown ? 1 : 0
    fade.duration = 0.1
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    line.opacity = shown ? 1 : 0
    line.add(fade, forKey: "edge")
  }

  private func syncEdge() {
    let y = scroll.contentView.bounds.origin.y
    fade(edgeLine, shown: y > 0, was: &edgeShown)
    let shift = min(max(y, 0), 1) * SidebarMetrics.glowRoom
    if shift != clipShift {
      clipShift = shift
      let scrollHeight = max(0, pageLayout.scrollBottom - pageLayout.scrollTop)
      clip.frame = NSRect(x: 0, y: pageLayout.scrollTop + shift, width: bounds.width, height: max(0, scrollHeight - shift))
      scroll.frame = NSRect(x: 0, y: -shift, width: bounds.width, height: scrollHeight)
    }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { point(event.locationInWindow) }
  public override func mouseMoved(with event: NSEvent) { point(event.locationInWindow) }
  public override func mouseExited(with event: NSEvent) { setHover(nil, group: nil) }

  public override func viewDidHide() {
    super.viewDidHide()
    setHover(nil, group: nil)
  }

  private var devPointerAt: NSPoint?

  private func syncPointer() {
    guard let window, !isHiddenOrHasHiddenAncestor else { return }
    let at = devPointerAt.map { window.convertPoint(fromScreen: $0) } ?? window.mouseLocationOutsideOfEventStream
    if bounds.contains(convert(at, from: nil)) { point(at) } else { setHover(nil, group: nil) }
  }

  @objc private func devPointer(_ note: Notification) {
    devPointerAt = (note.object as? NSValue)?.pointValue
    guard let window, !isHiddenOrHasHiddenAncestor, let screen = devPointerAt else { return }
    let at = window.convertPoint(fromScreen: screen)
    if DevPointer.inside(self, note) { point(at) } else { setHover(nil, group: nil) }
  }

  @objc private func coverChanged(_ note: Notification) {
    guard let shell = note.object as? NSView, isDescendant(of: shell) else { return }
    syncPointer()
  }

  private func covered() -> Bool {
    var up = superview
    while let at = up, !(at is WindowShellView) { up = at.superview }
    guard let shell = up as? WindowShellView, let mine = shell.slot(containing: self) else { return false }
    return shell.pointerSlot != mine
  }

  private func point(_ windowPoint: NSPoint) {
    if covered() { return setHover(nil, group: nil) }
    let row = rowAt(windowPoint)
    let groups = groupsAt(windowPoint)
    setHover(row, group: groups)
    row?.pointerMoved()
  }

  private func rowAt(_ windowPoint: NSPoint) -> SidebarRowView? {
    if pillShown, pill.bounds.contains(pill.convert(windowPoint, from: nil)) { return nil }
    if panels.hitTest(panels.superview?.convert(windowPoint, from: nil) ?? .zero) != nil { return nil }
    if let row = hoveredKey.flatMap({ views[$0] as? RailTabView }), !row.isHidden,
      row.item?.region != .scroll || clip.bounds.contains(clip.convert(windowPoint, from: nil)),
      row.containsClose(row.convert(windowPoint, from: nil)) { return row }
    for container in [dock, fixed, rows] {
      if container === rows, !clip.bounds.contains(clip.convert(windowPoint, from: nil)) { continue }
      for case let row as SidebarRowView in container.subviews.reversed() where !row.isHidden && !row.retired {
        if row.bounds.contains(row.convert(windowPoint, from: nil)) { return row }
      }
    }
    return nil
  }

  private func groupsAt(_ windowPoint: NSPoint) -> String? {
    guard clip.bounds.contains(clip.convert(windowPoint, from: nil)) else { return nil }
    var best: (id: String, depth: Int)?
    for case let box as GroupBoxView in boxes.subviews {
      guard let item = box.item, case .groupBox(let id) = item.kind, box.bounds.contains(box.convert(windowPoint, from: nil)) else { continue }
      if best == nil || item.groups.count > best!.depth { best = (id, item.groups.count) }
    }
    return best?.id
  }

  func pointerEntered(_ row: SidebarRowView) {
    setHover(row, group: row.item?.groups.last)
  }

  func pointerExited(_ row: SidebarRowView) {
    if hoveredKey == row.item?.key { setHover(nil, group: nil) }
  }

  private var sentTarget: String?

  func dismissHover() { sentTarget = nil }

  func hoverTargetMoved() { sendHoverTarget() }

  private func sendHoverTarget() {
    let row = hoveredKey.flatMap { views[$0] as? SidebarRowView }
    let target = row?.hoverTarget
    let key = target.map { "\($0.kind):\($0.id)" }
    guard key != sentTarget else { return }
    sentTarget = key
    onAction(.hover(kind: target?.kind, id: target?.id))
  }

  private func setHover(_ row: SidebarRowView?, group: String?) {
    if SidebarDragController.existing(self)?.active == true { return }
    let key = row?.item?.key
    if key != hoveredKey {
      if let old = hoveredKey, let view = views[old] as? SidebarRowView { view.hovered = false }
      hoveredKey = key
      row?.hovered = true
      sendHoverTarget()
    }
    if group != hoveredGroup {
      if let old = hoveredGroup, let box = views["gb:\(old)"] as? GroupBoxView { box.show(false, animated: true) }
      hoveredGroup = group
      if let group, let box = views["gb:\(group)"] as? GroupBoxView { box.show(true, animated: true) }
    }
  }

  fileprivate func blankMouseDown(_ event: NSEvent) {
    endRename()
    if event.modifierFlags.contains(.control) { return onAction(.sidebarMenu) }
    if event.clickCount == 2 { return onAction(.newTabDoubleClick) }
    window?.performDrag(with: event)
  }

  private func endRename() {
    guard let window, let editor = window.firstResponder as? NSText, let field = editor.delegate as? SidebarRenameField, field.isDescendant(of: self) else { return }
    window.makeFirstResponder(nil)
  }

  public override func mouseDown(with event: NSEvent) { blankMouseDown(event) }
  public override func rightMouseDown(with event: NSEvent) { onAction(.sidebarMenu) }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SidebarLayer: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

final class SidebarDocumentView: NSView {
  weak var owner: SidebarView?
  override var isFlipped: Bool { true }
  override func mouseDown(with event: NSEvent) { owner?.blankMouseDown(event) }
  override func rightMouseDown(with event: NSEvent) { owner?.onAction(.sidebarMenu) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
