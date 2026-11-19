import AppKit
import QuartzCore

public struct FolderPanelMember: Equatable, Sendable {
  public var tabId: String
  public var title: String
  public var active: Bool

  public init(tabId: String, title: String, active: Bool) {
    self.tabId = tabId
    self.title = title
    self.active = active
  }
}

public struct FolderPanelColors: Equatable, Sendable {
  public var dark: Bool
  public var panel: CSSColor
  public var panelBorder: CSSColor
  public var panelShadowOpacity: Double
  public var textPrimary: CSSColor
  public var textSecondary: CSSColor
  public var textTab: CSSColor
  public var tabHover: CSSColor
  public var tabPressed: CSSColor
  public var pinnedSelectedFill: CSSColor

  public init(dark: Bool, tokens: [String: String], panelShadowOpacity: Double? = nil) {
    func c(_ key: String, _ light: String, _ darkValue: String) -> CSSColor { tokens[key].flatMap { CSSColor($0) } ?? CSSColor(dark ? darkValue : light)! }
    self.dark = dark
    panel = c("panel", "#FFFFFF", "#2A2A2A")
    panelBorder = c("panelBorder", "rgba(0,0,0,0.1)", "rgba(255,255,255,0.1)")
    self.panelShadowOpacity = panelShadowOpacity ?? (dark ? 0.5 : 0.18)
    textPrimary = c("textPrimary", "#000000", "#FFFFFF")
    textSecondary = c("textSecondary", "#00000080", "#FFFFFF80")
    textTab = c("textTab", "#000000AD", "#FFFFFFC7")
    tabHover = c("tabHover", "rgba(255,255,255,0.55)", "rgba(255,255,255,0.16)")
    tabPressed = c("tabPressed", "rgba(255,255,255,0.7)", "rgba(255,255,255,0.31)")
    pinnedSelectedFill = c("pinnedSelectedFill", "rgba(255,255,255,0.7)", "rgba(255,255,255,0.25)")
  }
}

public struct FolderPanelDropZone: Equatable, Sendable {
  public var frame: CGRect
  public var members: [(tabId: String, frame: CGRect)]

  public static func == (a: FolderPanelDropZone, b: FolderPanelDropZone) -> Bool {
    a.frame == b.frame && a.members.elementsEqual(b.members) { $0.tabId == $1.tabId && $0.frame == $1.frame }
  }

  public var dragJSON: [String: Any] {
    func rect(_ r: CGRect) -> [String: Any] { ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)] }
    let rows: [[String: Any]] = members.map { member in
      var row = rect(member.frame)
      row["tabId"] = member.tabId
      return row
    }
    return ["frame": rect(frame), "members": rows]
  }
}

public enum FolderPanelEvent: Equatable, Sendable {
  case open(tabId: String)
  case tabMenu(tabId: String)
  case folderMenu
  case outsidePress
  case drag(phase: String, tabId: String, point: CGPoint)
}

public enum FolderPanelMetrics {
  public static let gap: CGFloat = 6
  public static let padding: CGFloat = 6
  public static let inset: CGFloat = 6
  public static let radius: CGFloat = 12
  public static let border: CGFloat = 0.5
  public static let shadowRadius: CGFloat = 16
  public static let shadowY: CGFloat = 6
  public static let shadowScale = 0.8
  public static let headerSize: CGFloat = 12
  public static let headerTop: CGFloat = 2
  public static let headerBottom: CGFloat = 6
  public static let headerSide: CGFloat = 6
  public static let rowHeight: CGFloat = 34
  public static let rowGap: CGFloat = 3
  public static let rowRadius: CGFloat = 8
  public static let rowPadding: CGFloat = 9
  public static let icon: CGFloat = 16
  public static let labelGap: CGFloat = 8
  public static let labelSize: CGFloat = 13
  public static let labelHeight: CGFloat = 18
  public static let fromScale = 0.92
  public static let spring = SpringParams(stiffness: 8100, damping: 180, mass: 1)
}

@MainActor
public final class SidebarFolderPanelView: NSView {
  public var onEvent: (FolderPanelEvent) -> Void = { _ in }
  public var onDropZone: (FolderPanelDropZone?) -> Void = { _ in }
  public var makeIcon: (String) -> NSView = { _ in NSView() }
  var bindIcon: ((String, NSView) -> Void)?
  #if SOLARA_PROBES
  var probeRowBinding: ((NSView) -> Void)?
  #endif
  public var virtualizesRows = false { didSet { if oldValue != virtualizesRows { needsLayout = true } } }
  public var folderId = ""
  public var hintActions: [String: [String]] = [:]
  public var showsTabNumberHints = true

  private let motion = FolderPanelFlipped()
  private let card = FolderPanelFlipped()
  private let surface = SurfaceLayer()
  private let header = FadeLabel(fontSize: FolderPanelMetrics.headerSize, weight: .semibold)
  private let rowPool = SidebarAuxiliaryRowPool()
  private let viewportWatch = SidebarAuxiliaryViewportWatch()
  private let scroll = NSScrollView()
  private let list = FolderPanelFlipped()
  private var rowTop: CGFloat = 0
  private var reconciling = false
  private var label = ""
  private var members: [FolderPanelMember] = []
  private var colors = FolderPanelColors(dark: true, tokens: [:])
  private var anchor = CGRect.zero
  private var width: CGFloat = 0
  private var spring = SpringTrack.resting(0)
  private var opened = false
  private var reported: FolderPanelDropZone?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    motion.wantsLayer = true
    motion.layer?.opacity = 0
    addSubview(motion)
    card.wantsLayer = true
    card.layer?.addSublayer(surface)
    surface.radius = FolderPanelMetrics.radius
    surface.border = FolderPanelMetrics.border
    surface.glowRadius = FolderPanelMetrics.shadowRadius
    surface.glowOffset = CGSize(width: 0, height: FolderPanelMetrics.shadowY)
    surface.glowColor = .black
    motion.addSubview(card)
    header.setAccessibilityRole(.staticText)
    card.addSubview(header)
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = list
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    card.addSubview(scroll)
    scroll.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(label: String, members: [FolderPanelMember], colors: FolderPanelColors, anchor: CGRect, width: CGFloat) {
    self.label = label
    self.colors = colors
    self.anchor = anchor
    self.width = width
    surface.fill = colors.panel.ns
    surface.borderTint = colors.panelBorder.ns
    surface.glowOpacity = colors.panelShadowOpacity * FolderPanelMetrics.shadowScale
    header.text = "\(label) · \(members.count) tab\(members.count == 1 ? "" : "s")"
    header.color = colors.textSecondary.ns
    self.members = members
    if !virtualizesRows { syncRows() }
    needsLayout = true
  }

  func updateHintActions(_ actions: [String: [String]], enabled: Bool) {
    hintActions = actions
    showsTabNumberHints = enabled
    for (key, row) in rowPool.views {
      (row as? FolderPanelRow)?.numberHint.configure(actions: actions[key] ?? [], enabled: enabled)
    }
  }

  public override func layout() {
    super.layout()
    let m = FolderPanelMetrics.self
    let x = m.inset
    let y = anchor.maxY + m.gap
    let pad = m.padding + m.border
    var inner = pad + m.headerTop
    header.frame = CGRect(x: pad + m.headerSide, y: inner, width: width - 2 * (pad + m.headerSide), height: ceil(NSFont.systemFont(ofSize: m.headerSize, weight: .semibold).boundingRectForFont.height))
    inner += header.frame.height + m.headerBottom
    rowTop = inner
    let contentHeight = CGFloat(members.count) * (m.rowHeight + m.rowGap)
    inner += contentHeight + pad
    motion.frame = bounds
    let available = SidebarAuxiliaryViewport.clip(self)
    let height = virtualizesRows ? min(inner, max(0, available.maxY - y)) : inner
    card.frame = CGRect(x: x, y: y, width: width, height: height)
    scroll.isHidden = !virtualizesRows
    scroll.frame = CGRect(x: 0, y: rowTop, width: width, height: max(0, height - rowTop - pad))
    list.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
    PrimitiveMotion.setInstantly { surface.frame = card.bounds }
    syncRows()
    viewportWatch.watch(self) { [weak self] in
      guard let self, virtualizesRows else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
    if !opened, window != nil, !members.isEmpty { open() }
    report()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { needsLayout = true }
    else if virtualizesRows { rowPool.clear { ($0 as? FolderPanelRow)?.clearBinding() }; viewportWatch.stop() }
  }

  private func rowFrame(_ index: Int) -> CGRect {
    let m = FolderPanelMetrics.self
    let pad = m.padding + m.border
    return CGRect(x: pad, y: (virtualizesRows ? 0 : rowTop) + CGFloat(index) * (m.rowHeight + m.rowGap), width: max(0, width - 2 * pad), height: m.rowHeight)
  }

  private func syncRows() {
    guard !reconciling else { return }
    reconciling = true
    defer { reconciling = false }
    let parent: NSView = virtualizesRows ? list : card
    rowPool.reconcile(keys: members.map(\.tabId), frames: members.indices.map(rowFrame), container: parent, virtualized: virtualizesRows, make: { _ in FolderPanelRow(member: FolderPanelMember(tabId: "", title: "", active: false), icon: NSView()) }, clear: { ($0 as? FolderPanelRow)?.clearBinding() }) { [weak self] view, index in
      guard let self, let row = view as? FolderPanelRow else { return }
      let member = members[index]
      if let bindIcon, row.hasBoundIcon { bindIcon(member.tabId, row.iconView) }
      else if row.memberId != member.tabId { row.replaceIcon(makeIcon(member.tabId)) }
      row.set(member, colors: colors)
      row.transfersDrag = virtualizesRows
      row.setAccessibilityElement(!virtualizesRows)
      #if SOLARA_PROBES
      probeRowBinding?(row)
      #endif
      row.numberHint.configure(actions: hintActions[member.tabId] ?? [], enabled: showsTabNumberHints)
      row.onEvent = { [weak self] in self?.onEvent($0) }
    }
    rowPool.updateElements(keys: members.map(\.tabId), parent: self, label: { [weak self] key in
      self?.members.first { $0.tabId == key }?.title
    }, frame: { [weak self] key in
      guard let self, let index = members.firstIndex(where: { $0.tabId == key }) else { return .zero }
      return SidebarAuxiliaryViewport.screen(rowFrame(index), in: virtualizesRows ? list : card)
    }, action: { [weak self] key, action in
      guard let self, virtualizesRows, !SidebarAuxiliaryViewport.clip(self).isEmpty, let index = members.firstIndex(where: { $0.tabId == key }) else { return false }
      list.scrollToVisible(rowFrame(index))
      syncRows()
      report()
      if action == "press" { onEvent(.open(tabId: key)) }
      if action == "menu" { onEvent(.tabMenu(tabId: key)) }
      return true
    })
  }

  @objc private func scrolled() {
    guard virtualizesRows else { return }
    syncRows()
    report()
  }

  public override func accessibilityChildren() -> [Any]? {
    guard virtualizesRows else { return super.accessibilityChildren() }
    return [header] as [Any] + rowPool.orderedElements
  }

  public override func viewDidHide() {
    super.viewDidHide()
    if virtualizesRows { rowPool.clear { ($0 as? FolderPanelRow)?.clearBinding() }; viewportWatch.stop(); onDropZone(nil) }
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    needsLayout = true
  }

  private func open() {
    opened = true
    let now = CACurrentMediaTime()
    spring = SpringTrack(FolderPanelMetrics.spring, from: 0, to: 1, start: now)
    guard let layer = motion.layer else { return }
    let center = CGPoint(x: card.frame.midX, y: card.frame.midY)
    let values = spring.samples()
    PrimitiveMotion.setInstantly {
      layer.opacity = 1
      layer.sublayerTransform = CATransform3DIdentity
    }
    layer.add(PrimitiveMotion.keyframes("opacity", values, duration: spring.duration, start: now) { NSNumber(value: $0) }, forKey: "folderOpacity")
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", values, duration: spring.duration, start: now) { p in
      NSValue(caTransform3D: PrimitiveMotion.scale(about: center, scale: FolderPanelMetrics.fromScale + (1 - FolderPanelMetrics.fromScale) * p))
    }, forKey: "folderScale")
  }

  private func report() {
    guard let height = window?.contentView?.bounds.height else { return onDropZone(nil) }
    func top(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
    let frame = top(convert(card.frame, to: nil))
    let parent: NSView = virtualizesRows ? list : card
    let zone = FolderPanelDropZone(frame: frame, members: members.enumerated().map { index, member in
      (member.tabId, top(parent.convert(rowFrame(index), to: nil)))
    })
    guard zone != reported else { return }
    reported = zone
    onDropZone(zone)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return card.frame.contains(local) ? super.hitTest(point) : nil
  }

  func cardContains(_ local: CGPoint) -> Bool { card.frame.contains(local) }

  func tileContains(_ local: CGPoint) -> Bool { anchor.contains(local) }

  public override func rightMouseDown(with event: NSEvent) {
    let local = card.convert(event.locationInWindow, from: nil)
    if header.frame.contains(local) { onEvent(.folderMenu) } else { super.rightMouseDown(with: event) }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { onDropZone(nil) }
  }
}

final class FolderPanelFlipped: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
final class FolderPanelRow: NSView {
  var onEvent: (FolderPanelEvent) -> Void = { _ in }
  private let fill = CALayer()
  private var icon: NSView
  private let title = FadeLabel(fontSize: FolderPanelMetrics.labelSize)
  let numberHint = TabNumberHintView()
  private var member: FolderPanelMember
  private var colors = FolderPanelColors(dark: true, tokens: [:])
  private var hovered = false
  private var pressed = false
  private var downAt: NSPoint?
  private var dragging = false
  private var transferredDrag = false
  var transfersDrag = false
  var hasBoundIcon = false
  var memberId: String { member.tabId }
  var iconView: NSView { icon }

  override var isFlipped: Bool { true }

  init(member: FolderPanelMember, icon: NSView) {
    self.member = member
    self.icon = icon
    hasBoundIcon = !member.tabId.isEmpty
    super.init(frame: .zero)
    wantsLayer = true
    fill.cornerRadius = FolderPanelMetrics.rowRadius
    fill.cornerCurve = .continuous
    fill.actions = SurfaceLayer.noActions
    layer?.addSublayer(fill)
    addSubview(icon)
    addSubview(title)
    addSubview(numberHint)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ next: FolderPanelMember, colors next2: FolderPanelColors) {
    member = next
    colors = next2
    title.text = next.title
    title.color = (next.active ? next2.textPrimary : next2.textTab).ns
    setAccessibilityLabel(next.title)
    refresh()
  }

  private func refresh() {
    let color: CSSColor? = pressed ? colors.tabPressed : member.active ? colors.pinnedSelectedFill : hovered ? colors.tabHover : nil
    PrimitiveMotion.setInstantly { fill.backgroundColor = color?.cg }
  }

  override func layout() {
    super.layout()
    let m = FolderPanelMetrics.self
    PrimitiveMotion.setInstantly { fill.frame = bounds }
    icon.frame = CGRect(x: m.rowPadding, y: (bounds.height - m.icon) / 2, width: m.icon, height: m.icon)
    let x = m.rowPadding + m.icon + m.labelGap
    title.frame = CGRect(x: x, y: (bounds.height - m.labelHeight) / 2, width: max(0, bounds.width - x - m.rowPadding), height: m.labelHeight)
    numberHint.present(title: title, color: title.color)
  }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
    refresh()
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = isHitBy(event)
    refresh()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    refresh()
  }

  override func mouseDown(with event: NSEvent) {
    pressed = true
    downAt = event.locationInWindow
    dragging = false
    transferredDrag = false
    refresh()
  }

  private func topLeft(_ event: NSEvent) -> CGPoint {
    let p = event.locationInWindow
    return CGPoint(x: p.x, y: (window?.contentView?.bounds.height ?? 0) - p.y)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let downAt else { return }
    let p = event.locationInWindow
    if !dragging, abs(p.y - downAt.y) > 4 || abs(p.x - downAt.x) > 8 {
      dragging = true
      pressed = false
      refresh()
      onEvent(.drag(phase: "begin", tabId: member.tabId, point: topLeft(event)))
      if transfersDrag {
        transferredDrag = true
        dragging = false
        self.downAt = nil
        return
      }
    }
    if dragging { onEvent(.drag(phase: "move", tabId: member.tabId, point: topLeft(event))) }
  }

  override func mouseUp(with event: NSEvent) {
    guard !transferredDrag else { transferredDrag = false; return }
    let wasPressed = downAt != nil
    let wasDragging = dragging
    pressed = false
    dragging = false
    downAt = nil
    refresh()
    if wasDragging { return onEvent(.drag(phase: "end", tabId: member.tabId, point: topLeft(event))) }
    if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onEvent(.open(tabId: member.tabId)) }
  }

  override func rightMouseDown(with event: NSEvent) { onEvent(.tabMenu(tabId: member.tabId)) }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    cancelDrag()
  }

  override func removeFromSuperview() {
    cancelDrag()
    super.removeFromSuperview()
  }

  func cancelDrag() {
    guard dragging else { return }
    dragging = false
    pressed = false
    downAt = nil
    onEvent(.drag(phase: "cancel", tabId: member.tabId, point: .zero))
  }

  func replaceIcon(_ next: NSView) {
    icon.removeFromSuperview()
    icon = next
    addSubview(icon)
    hasBoundIcon = true
  }

  func clearBinding() {
    cancelDrag()
    hovered = false
    pressed = false
    downAt = nil
    transferredDrag = false
    numberHint.configure(actions: [], enabled: false)
    member = FolderPanelMember(tabId: "", title: "", active: false)
    onEvent = { _ in }
    setAccessibilityElement(false)
    setAccessibilityLabel(nil)
    SidebarRowReuse.reset(self)
  }

  override func accessibilityPerformPress() -> Bool {
    onEvent(.open(tabId: member.tabId))
    return true
  }
}

public struct FolderPanelRequest: Decodable, Equatable, Sendable {
  public struct Member: Decodable, Equatable, Sendable {
    public var tabId: String
    public var title: String
    public var active: Bool
  }

  public var folderId: String
  public var label: String
  public var members: [Member]
  public var dark: Bool
  public var theme: [String: String]
  public var panelShadowOpacity: Double?
}

@MainActor
public enum SidebarFolderPanelHost {
  private static let panels = NSMapTable<SidebarView, SidebarFolderPanelView>.weakToStrongObjects()
  private static var monitors: [ObjectIdentifier: Any] = [:]

  public static func show(on page: SidebarView, windowId: String, request: FolderPanelRequest, send: @escaping (FolderPanelEvent) -> Void) {
    guard let anchor = page.frameOf("folder:\(request.folderId)") ?? page.frameOf(request.folderId) else { return hide(on: page) }
    let layer = page.panelLayer
    let panel = panels.object(forKey: page) ?? {
      let made = SidebarFolderPanelView(frame: layer.bounds)
      made.autoresizingMask = [.width, .height]
      layer.addSubview(made)
      panels.setObject(made, forKey: page)
      return made
    }()
    panel.virtualizesRows = page.virtualizesRows
    #if SOLARA_PROBES
    panel.probeRowBinding = { [weak page] view in
      guard let context = page?.context else { return }
      NativeWorkCounters.bind(view, windowId: windowId, profileId: context.host.profileId, kind: "sidebar.folderPanel.full")
    }
    #endif
    refreshHints(on: page)
    panel.folderId = request.folderId
    panel.onEvent = { [weak page] event in
      if case .drag(let phase, let tabId, let point) = event {
        guard let page else { return }
        return SidebarDragController.of(page).panelDrag(phase, tabId: tabId, at: point)
      }
      send(event)
    }
    panel.onDropZone = { [weak page] zone in
      guard let page else { return }
      SidebarDragController.of(page).setFolderPanel(zone?.dragJSON)
    }
    panel.makeIcon = { [weak page] tabId in
      let icon = TabIconView(frame: CGRect(x: 0, y: 0, width: FolderPanelMetrics.icon, height: FolderPanelMetrics.icon))
      if let page, let context = page.context, let tab = context.state.tabs[tabId] {
        icon.favicons = page.favicons
        icon.set(context.iconSpec(tab, size: FolderPanelMetrics.icon), palette: context.palette)
      }
      return icon
    }
    panel.bindIcon = { [weak page] tabId, view in
      guard let icon = view as? TabIconView, let page, let context = page.context, let tab = context.state.tabs[tabId] else { return }
      icon.favicons = page.favicons
      icon.set(context.iconSpec(tab, size: FolderPanelMetrics.icon), palette: context.palette)
    }
    let colors = FolderPanelColors(dark: request.dark, tokens: request.theme, panelShadowOpacity: request.panelShadowOpacity)
    let width = max(0, page.bounds.width - 2 * FolderPanelMetrics.inset)
    panel.update(
      label: request.label,
      members: request.members.map { FolderPanelMember(tabId: $0.tabId, title: $0.title, active: $0.active) },
      colors: colors, anchor: anchor, width: width)
    watchOutside(page, panel: panel, send: send)
  }

  static func refreshHints(on page: SidebarView) {
    guard let panel = panels.object(forKey: page), let context = page.context else { return }
    let actions = Dictionary(uniqueKeysWithValues: context.tabNumberActions.compactMap { key, actions in
      key.hasPrefix("t:") ? (String(key.dropFirst(2)), actions) : nil
    })
    panel.updateHintActions(actions, enabled: context.showsTabNumberHints)
  }

  public static func hide(on page: SidebarView) {
    guard let panel = panels.object(forKey: page) else { return }
    panels.removeObject(forKey: page)
    if let monitor = monitors.removeValue(forKey: ObjectIdentifier(page)) { NSEvent.removeMonitor(monitor) }
    panel.onDropZone(nil)
    panel.removeFromSuperview()
  }

  public static func panel(on page: SidebarView) -> SidebarFolderPanelView? { panels.object(forKey: page) }

  private static func watchOutside(_ page: SidebarView, panel: SidebarFolderPanelView, send: @escaping (FolderPanelEvent) -> Void) {
    let key = ObjectIdentifier(page)
    guard monitors[key] == nil else { return }
    monitors[key] = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak page, weak panel] event in
      guard let page, let panel, event.window === page.window, panel.window != nil else { return event }
      let local = panel.convert(event.locationInWindow, from: nil)
      if panel.cardContains(local) { return event }
      send(.outsidePress)
      return panel.tileContains(local) ? nil : event
    }
  }
}
