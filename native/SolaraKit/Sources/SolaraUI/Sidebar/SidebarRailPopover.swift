import AppKit

struct SidebarRailPopoverRow {
  var content: SidebarFolderPeekState.Row
  var action: SidebarAction
  var closeAction: SidebarAction? = nil
  var menuAction: SidebarAction? = nil
  var active = false
  var unread = false
  var groupId: String? = nil
  var directIcon = false

  @MainActor
  static func group(_ id: String, context: SidebarContext) -> [Self] {
    guard let group = context.state.groups[id] else { return [] }
    return context.query.groupEntries(id).flatMap { entry -> [Self] in
      let key = String(entry.dropFirst(2))
      if entry.hasPrefix("g:"), let child = context.state.groups[key] {
        let tab = child.tabIds.compactMap { context.state.tabs[$0] }.first
        return [Self(
          content: SidebarFolderPeekState.Row(id: entry, title: context.query.groupLabel(key), url: tab?.url ?? "", favicon: tab?.favicon, icon: child.icon ?? tab?.customIcon, profileId: context.host.profileId),
          action: .toggleGroup(groupId: key), menuAction: .groupMenu(groupId: key),
          active: child.tabIds.contains(context.activeId ?? ""), groupId: key)]
      }
      let ids = entry.hasPrefix("s:") ? context.query.splitPanes(key).filter { group.tabIds.contains($0) } : [key]
      return ids.compactMap { tabId in
        guard let tab = context.state.tabs[tabId] else { return nil }
        return Self(
          content: SidebarFolderPeekState.Row(id: tabId, title: context.title(tab), url: tab.url, favicon: tab.favicon, icon: tab.customIcon, profileId: tab.profileId),
          action: .click(tabId: tabId, mods: SidebarClickMods([])), closeAction: .close(tabId: tabId),
          menuAction: .tabMenu(tabId: tabId), active: context.activeId == tabId)
      }
    }
  }

  @MainActor
  static func live(_ id: String, context: SidebarContext) -> [Self] {
    guard let live = context.live?.live, let folder = live.state.folders[id] else { return [] }
    let unread = Set(live.state.unread[id] ?? [])
    let tabs = (context.state.windows[context.windowId]?.tabIds ?? []).compactMap { context.state.tabs[$0] }
    return (live.state.items[id] ?? []).map { item in
      let tab = tabs.first { $0.profileId == folder.profileId && SidebarLive.liveRef($0).map { $0.folderId == id && $0.itemId == item.id } == true }
      let remote = item.icon.map { $0.hasPrefix("http:") || $0.hasPrefix("https:") } ?? false
      return Self(
        content: SidebarFolderPeekState.Row(id: item.id, title: item.title, url: item.url, favicon: remote ? item.icon : nil, icon: remote ? nil : item.icon, profileId: folder.profileId),
        action: .live(action: "open", folderId: id, id: item.id, meta: false),
        closeAction: tab.map { .live(action: "close", folderId: id, id: $0.id, meta: false) },
        menuAction: .live(action: "itemMenu", folderId: id, id: item.id, meta: false),
        active: tab?.id != nil && tab?.id == context.activeId, unread: unread.contains(item.id), directIcon: remote)
    }
  }
}

@MainActor
final class SidebarRailPopover: NSObject, NSPopoverDelegate {
  let popover = NSPopover()
  let renameKey: String?
  private let content = SidebarRailPopoverBody()
  private var field: SidebarRenameField?
  private var closed = false
  private var context: SidebarContext?
  private weak var anchor: RailIconView?
  private var anchorDismissedAt: TimeInterval?
  private var pages: [Page] = []

  private struct Page {
    var title: String
    var rows: [SidebarRailPopoverRow]
    var groupId: String?
    var folderId: String?
    var selection: Int
  }

  init(title: String, rows: [SidebarRailPopoverRow], context: SidebarContext, groupId: String? = nil, folderId: String? = nil) {
    renameKey = nil
    self.context = context
    pages = [Page(title: title, rows: rows, groupId: groupId, folderId: folderId, selection: rows.firstIndex { $0.active } ?? 0)]
    super.init()
    prepare()
    content.onChoose = { [weak self] in self?.choose($0, flags: $1) }
    content.onDragOut = { [weak self] in self?.dragOut($0, event: $1) }
    content.onBack = { [weak self] in
      guard let self, self.pages.count > 1 else { return }
      self.pages.removeLast()
      self.render()
    }
    content.onSelection = { [weak self] in
      guard let self, !self.pages.isEmpty else { return }
      self.pages[self.pages.count - 1].selection = $0
    }
    content.onRefresh = { [weak self] in
      guard let self, let id = self.pages.last?.folderId else { return }
      self.context?.send(.live(action: "refresh", folderId: id, id: nil, meta: false))
    }
    render()
  }

  init(kind: String, id: String, initial: String, placeholder: String, context: SidebarContext) {
    renameKey = "\(kind):\(id)"
    super.init()
    prepare()
    let field = SidebarRenameField(initial: initial, placeholder: placeholder, font: .systemFont(ofSize: 13), color: context.palette.textPrimary)
    let send = context.send
    field.onDone = { [weak self] text in
      self?.close()
      send(.renamed(kind: kind, id: id, text: text))
    }
    self.field = field
    content.install(field)
    popover.contentSize = content.frame.size
  }

  func update(context: SidebarContext) {
    guard !closed, renameKey == nil else { return }
    self.context = context
    for i in pages.indices {
      let selected = pages[i].rows.indices.contains(pages[i].selection) ? pages[i].rows[pages[i].selection].content.id : nil
      if let id = pages[i].groupId {
        pages[i].title = context.query.groupLabel(id)
        pages[i].rows = SidebarRailPopoverRow.group(id, context: context)
      } else if let id = pages[i].folderId {
        pages[i].title = context.live?.live.state.folders[id]?.name ?? pages[i].title
        pages[i].rows = SidebarRailPopoverRow.live(id, context: context)
      }
      pages[i].selection = pages[i].rows.firstIndex { $0.content.id == selected } ?? min(pages[i].selection, max(0, pages[i].rows.count - 1))
    }
    render()
  }

  private func render() {
    guard let page = pages.last, let context else { return }
    let width = CGFloat(min(320, max(200, context.state.windows[context.windowId]?.effectiveSidebarWidth(context.state.settings) ?? SidebarChromeMetrics.defaultWidth)))
    content.set(title: page.title, rows: page.rows, selection: page.selection, back: pages.count > 1, refresh: page.folderId != nil, width: width, context: context)
    popover.appearance = NSAppearance(named: context.palette.dark ? .darkAqua : .aqua)
    popover.contentSize = content.frame.size
    if popover.isShown { align() }
  }

  private func choose(_ index: Int, flags: NSEvent.ModifierFlags) {
    guard !closed, let context, let page = pages.last, page.rows.indices.contains(index) else { return }
    let row = page.rows[index]
    pages[pages.count - 1].selection = index
    if let id = row.groupId {
      guard !pages.contains(where: { $0.groupId == id }) else { return }
      let rows = SidebarRailPopoverRow.group(id, context: context)
      pages.append(Page(title: context.query.groupLabel(id), rows: rows, groupId: id, selection: rows.firstIndex { $0.active } ?? 0))
      render()
      return
    }
    close()
    switch row.action {
    case .click(let tabId, _): context.send(.click(tabId: tabId, mods: SidebarClickMods(flags)))
    case .live(let action, let folderId, let id, _): context.send(.live(action: action, folderId: folderId, id: id, meta: flags.contains(.command)))
    default: context.send(row.action)
    }
  }

  private func dragOut(_ index: Int, event: NSEvent) {
    guard !closed, let page = pages.last, let groupId = page.groupId, page.rows.indices.contains(index),
      case .click(let tabId, _) = page.rows[index].action, let row = anchor, let sidebar = row.hoverHost else { return }
    let controller = SidebarDragController.of(sidebar)
    let size = controller.windowRect(row)?.size ?? row.bounds.size
    let at = controller.popoverLocation(event)
    close()
    controller.popoverDrag(tabId: tabId, groupId: groupId, size: size, at: at)
  }

  private func prepare() {
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    let controller = NSViewController()
    controller.view = content
    popover.contentViewController = controller
    content.onCancel = { [weak self] in
      if let field = self?.field { field.finish(nil) } else { self?.close() }
    }
  }

  var dismissedByAnchorClick: Bool {
    guard let time = anchorDismissedAt, let event = NSApp.currentEvent else { return false }
    return event.type == .leftMouseUp && event.timestamp >= time && event.timestamp - time < 1
  }

  func show(on row: RailIconView) {
    guard !closed, !popover.isShown, row.window != nil else { return }
    anchor = row
    popover.show(relativeTo: row.body.convert(row.icon.frame, to: row), of: row, preferredEdge: row.windowShell?.input.sidebarSide == .right ? .minX : .maxX)
    if let field { field.begin() } else {
      align()
      content.window?.makeFirstResponder(content)
    }
  }

  private func align() {
    guard let row = anchor, let window = row.window, let panel = content.window else { return }
    content.layoutSubtreeIfNeeded()
    let icon = window.convertToScreen(row.body.convert(row.icon.frame, to: nil))
    let rect = panel.convertToScreen(content.convert(content.bounds, to: nil))
    let right = row.windowShell?.input.sidebarSide == .right
    let x = right ? panel.frame.minX + icon.minX - FolderPanelMetrics.inset - rect.maxX : panel.frame.minX + icon.maxX + FolderPanelMetrics.inset - rect.minX
    let visible = window.screen?.visibleFrame ?? window.frame
    panel.setFrameOrigin(NSPoint(x: max(visible.minX, min(x, visible.maxX - panel.frame.width)), y: max(visible.minY, min(panel.frame.minY + icon.maxY - rect.maxY, visible.maxY - panel.frame.height))))
  }

  func close(commitRename: Bool = true) {
    guard !closed else { return }
    closed = true
    if !commitRename { field?.onDone = nil }
    if !popover.isShown { field?.finish(field?.stringValue) }
    popover.performClose(nil)
    content.stop()
  }

  func popoverWillClose(_ notification: Notification) {
    if let row = anchor, let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === row.window,
      row.bounds.contains(row.convert(event.locationInWindow, from: nil)) {
      anchorDismissedAt = event.timestamp
    }
    closed = true
    field?.finish(field?.stringValue)
    content.stop()
  }
}

@MainActor
private final class SidebarRailPopoverBody: NSView {
  var onCancel: (() -> Void)?
  var onChoose: ((Int, NSEvent.ModifierFlags) -> Void)?
  var onDragOut: ((Int, NSEvent) -> Void)?
  var onSelection: ((Int) -> Void)?
  var onBack: (() -> Void)?
  var onRefresh: (() -> Void)?
  private let surface = SurfaceLayer()
  private let header = FadeLabel(fontSize: FolderPanelMetrics.headerSize, weight: .semibold)
  private let back = SidebarRailPopoverButton()
  private let refresh = SidebarRailPopoverButton()
  private let scroll = NSScrollView()
  private let list = FolderPanelFlipped()
  private let rowPool = SidebarAuxiliaryRowPool()
  private let viewportWatch = SidebarAuxiliaryViewportWatch()
  private var values: [SidebarRailPopoverRow] = []
  private var context: SidebarContext?
  private var stopped = false
  private var field: SidebarRenameField?
  private var selection = 0
  private var headerHeight: CGFloat { ceil(NSFont.systemFont(ofSize: FolderPanelMetrics.headerSize, weight: .semibold).boundingRectForFont.height) }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(surface)
    surface.radius = FolderPanelMetrics.radius
    surface.border = FolderPanelMetrics.border
    surface.glowRadius = FolderPanelMetrics.shadowRadius
    surface.glowOffset = CGSize(width: 0, height: FolderPanelMetrics.shadowY)
    surface.glowColor = .black
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = false
    scroll.documentView = list
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    for view in [header, back, refresh, scroll] as [NSView] { addSubview(view) }
    back.target = self
    back.action = #selector(goBack)
    refresh.target = self
    refresh.action = #selector(refreshFolder)
  }

  required init?(coder: NSCoder) { fatalError() }

  static func style(_ button: NSButton, symbol: String, label: String, color: NSColor) {
    button.isBordered = false
    button.bezelStyle = .inline
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    button.contentTintColor = color
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }

  func set(title: String, rows values: [SidebarRailPopoverRow], selection: Int, back: Bool, refresh: Bool, width: CGFloat, context: SidebarContext) {
    let m = FolderPanelMetrics.self
    let colors = FolderPanelColors(dark: context.palette.dark, tokens: context.host.theme)
    surface.fill = colors.panel.ns
    surface.borderTint = colors.panelBorder.ns
    surface.glowOpacity = colors.panelShadowOpacity * m.shadowScale
    header.text = title
    header.color = colors.textSecondary.ns
    self.back.isHidden = !back
    self.refresh.isHidden = !refresh
    Self.style(self.back, symbol: "chevron.left", label: "Back", color: context.palette.icon)
    Self.style(self.refresh, symbol: "arrow.clockwise", label: "Refresh", color: context.palette.icon)
    self.values = values
    self.context = context
    self.selection = selection
    let rowsHeight = CGFloat(values.count) * (m.rowHeight + m.rowGap)
    let headerBottom = m.padding + m.border + m.headerTop + headerHeight + m.headerBottom
    setFrameSize(NSSize(width: width, height: min(400, headerBottom + rowsHeight + m.padding + m.border)))
    list.frame = NSRect(x: 0, y: 0, width: width, height: rowsHeight)
    scroll.hasVerticalScroller = headerBottom + rowsHeight + m.padding + m.border > 400
    needsLayout = true
    layoutSubtreeIfNeeded()
    revealSelection()
  }

  func install(_ field: SidebarRenameField) {
    rowPool.clear { ($0 as? SidebarRailPopoverRowView)?.clearBinding() }
    for view in [header, back, refresh, scroll] as [NSView] { view.isHidden = true }
    addSubview(field)
    self.field = field
    setFrameSize(NSSize(width: SidebarFolderPeekMetrics.width, height: 44))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    if let field {
      field.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: 20)
      return
    }
    let m = FolderPanelMetrics.self
    let pad = m.padding + m.border
    PrimitiveMotion.setInstantly { surface.frame = bounds }
    let headerY = pad + m.headerTop
    back.frame = NSRect(x: pad, y: headerY - 3, width: 22, height: 22)
    refresh.frame = NSRect(x: bounds.width - pad - 22, y: headerY - 3, width: 22, height: 22)
    let headerX = pad + m.headerSide + (back.isHidden ? 0 : 22)
    header.frame = NSRect(x: headerX, y: headerY, width: max(0, bounds.width - headerX - pad - m.headerSide - (refresh.isHidden ? 0 : 22)), height: headerHeight)
    let top = headerY + headerHeight + m.headerBottom
    scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - pad))
    list.setFrameSize(NSSize(width: scroll.contentSize.width, height: CGFloat(values.count) * (m.rowHeight + m.rowGap)))
    syncRows()
    viewportWatch.watch(list) { [weak self] in self?.syncRows() }
  }

  private func rowFrame(_ index: Int) -> CGRect {
    let m = FolderPanelMetrics.self
    let pad = m.padding + m.border
    return CGRect(x: pad, y: CGFloat(index) * (m.rowHeight + m.rowGap), width: max(0, list.bounds.width - 2 * pad), height: m.rowHeight)
  }

  private func revealSelection() {
    guard values.indices.contains(selection) else { return }
    list.scrollToVisible(rowFrame(selection))
    syncRows()
  }

  private func syncRows() {
    guard !stopped, field == nil, let context else { return }
    rowPool.reconcile(keys: values.map { $0.content.id }, frames: values.indices.map(rowFrame), container: list, virtualized: context.virtualizesRows, make: { SidebarRailPopoverRowView(values[$0], context: context) }, clear: { ($0 as? SidebarRailPopoverRowView)?.clearBinding() }) { [weak self] view, index in
      guard let self, let row = view as? SidebarRailPopoverRowView else { return }
      let value = values[index]
      row.set(value, context: context)
      row.selected = index == selection
      row.setAccessibilityElement(!context.virtualizesRows)
      #if SOLARA_PROBES
      NativeWorkCounters.bind(row, windowId: context.windowId, profileId: context.host.profileId, kind: "sidebar.railPopover.full")
      #endif
      row.onChoose = { [weak self] flags in
        guard let self, let index = values.firstIndex(where: { $0.content.id == value.content.id }) else { return }
        onChoose?(index, flags)
      }
      row.onDragOut = nil
      if case .click = value.action {
        row.onDragOut = { [weak self] event in
          guard let self, let index = values.firstIndex(where: { $0.content.id == value.content.id }) else { return }
          onDragOut?(index, event)
        }
      }
    }
    rowPool.updateElements(keys: values.map { $0.content.id }, parent: self, label: { [weak self] key in
      self?.values.first { $0.content.id == key }?.content.title
    }, frame: { [weak self] key in
      guard let self, let index = values.firstIndex(where: { $0.content.id == key }) else { return .zero }
      return SidebarAuxiliaryViewport.screen(rowFrame(index), in: list)
    }, action: { [weak self] key, action in
      guard let self, !stopped, !SidebarAuxiliaryViewport.clip(self).isEmpty, let context = self.context, let index = values.firstIndex(where: { $0.content.id == key }) else { return false }
      selection = index
      onSelection?(index)
      revealSelection()
      if action == "press" { onChoose?(index, []) }
      if action == "menu" {
        guard let menu = values[index].menuAction else { return false }
        context.send(menu)
      }
      return true
    })
  }

  @objc private func scrolled() { syncRows() }

  override func accessibilityChildren() -> [Any]? {
    guard context?.virtualizesRows == true, field == nil else { return super.accessibilityChildren() }
    return ([header] + [back, refresh].filter { !$0.isHidden }) as [Any] + rowPool.orderedElements
  }

  override func viewDidHide() {
    super.viewDidHide()
    if context?.virtualizesRows == true { rowPool.clear { ($0 as? SidebarRailPopoverRowView)?.clearBinding() }; viewportWatch.stop() }
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncRows()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil, context?.virtualizesRows == true { rowPool.clear { ($0 as? SidebarRailPopoverRowView)?.clearBinding() }; viewportWatch.stop() }
    else { syncRows() }
  }

  func stop() {
    stopped = true
    viewportWatch.stop()
    rowPool.clear { ($0 as? SidebarRailPopoverRowView)?.clearBinding() }
    context = nil
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 125, 126:
      guard !values.isEmpty else { return }
      selection = min(values.count - 1, max(0, selection + (event.keyCode == 125 ? 1 : -1)))
      for (key, view) in rowPool.views { (view as? SidebarRailPopoverRowView)?.selected = key == values[selection].content.id }
      onSelection?(selection)
      revealSelection()
    case 36, 76:
      if values.indices.contains(selection) { onChoose?(selection, event.modifierFlags) }
    case 53: onCancel?()
    default: super.keyDown(with: event)
    }
  }

  @objc private func goBack() { onBack?() }
  @objc private func refreshFolder() { onRefresh?() }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class SidebarRailPopoverRowView: NSView {
  var onChoose: ((NSEvent.ModifierFlags) -> Void)?
  var onDragOut: ((NSEvent) -> Void)?
  private(set) var tabId: String
  private var value: SidebarRailPopoverRow?
  private var context: SidebarContext?
  private let fill = CALayer()
  private let unread = CALayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: FolderPanelMetrics.labelSize)
  private let close = SidebarRailPopoverButton()
  private let chevron = SymbolView()
  private var hovered = false
  private var pressed = false
  private var downAt: NSPoint?
  var selected = false { didSet { paint() } }

  override var isFlipped: Bool { true }

  init(_ value: SidebarRailPopoverRow, context: SidebarContext) {
    self.value = value
    self.context = context
    tabId = value.content.id
    super.init(frame: .zero)
    wantsLayer = true
    fill.actions = SurfaceLayer.noActions
    fill.cornerRadius = FolderPanelMetrics.rowRadius
    fill.cornerCurve = .continuous
    unread.actions = SurfaceLayer.noActions
    unread.cornerRadius = 2.5
    for layer in [fill, unread] { self.layer?.addSublayer(layer) }
    for view in [icon, label, close, chevron] as [NSView] { addSubview(view) }
    close.target = self
    close.action = #selector(closeTab)
    setAccessibilityRole(.button)
    set(value, context: context)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ value: SidebarRailPopoverRow, context: SidebarContext) {
    self.value = value
    self.context = context
    tabId = value.content.id
    unread.isHidden = !value.unread
    unread.backgroundColor = SidebarLiveColors(dark: context.palette.dark).pip.cgColor
    let row = value.content
    icon.favicons = context.favicons
    icon.set(TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId, size: FolderPanelMetrics.icon, direct: value.directIcon), palette: context.palette)
    label.text = row.title
    label.font = .monospacedDigitSystemFont(ofSize: FolderPanelMetrics.labelSize, weight: value.unread ? .medium : .regular)
    label.color = value.active ? context.palette.textPrimary : context.palette.textTab
    chevron.isHidden = value.groupId == nil
    chevron.set("chevron.right", size: 10, weight: .semibold, color: context.palette.textSecondary)
    SidebarRailPopoverBody.style(close, symbol: "xmark", label: "Close Tab", color: context.palette.icon)
    setAccessibilityElement(true)
    setAccessibilityLabel(row.title)
    paint()
  }

  func clearBinding() {
    hovered = false
    pressed = false
    downAt = nil
    selected = false
    onChoose = nil
    onDragOut = nil
    tabId = ""
    context = nil
    value = nil
    setAccessibilityElement(false)
    setAccessibilityLabel(nil)
    SidebarRowReuse.reset(self)
  }

  private func paint() {
    guard let context, let value else { return }
    let color: NSColor? = pressed ? context.palette.pressed : value.active ? context.palette.pinnedSelectedFill : hovered || selected ? context.palette.hover : nil
    PrimitiveMotion.setInstantly { fill.backgroundColor = color?.cgColor }
    close.isHidden = !hovered || value.closeAction == nil
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let m = FolderPanelMetrics.self
    PrimitiveMotion.setInstantly {
      fill.frame = bounds
      unread.frame = NSRect(x: 2, y: bounds.midY - 2.5, width: 5, height: 5)
    }
    icon.frame = NSRect(x: m.rowPadding, y: (bounds.height - m.icon) / 2, width: m.icon, height: m.icon)
    close.frame = NSRect(x: bounds.width - m.rowPadding - 22, y: bounds.midY - 11, width: 22, height: 22)
    chevron.frame = NSRect(x: bounds.width - m.rowPadding - 12, y: bounds.midY - 6, width: 12, height: 12)
    let x = m.rowPadding + m.icon + m.labelGap
    let control: CGFloat = !close.isHidden ? 26 : !chevron.isHidden ? 16 : 0
    label.frame = NSRect(x: x, y: bounds.midY - m.labelHeight / 2, width: max(0, bounds.width - x - m.rowPadding - control), height: m.labelHeight)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
  override func mouseExited(with event: NSEvent) { hovered = false; paint() }
  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
    pressed = true
    downAt = event.locationInWindow
    paint()
  }
  override func mouseDragged(with event: NSEvent) {
    guard let downAt, let onDragOut else { return }
    let p = event.locationInWindow
    guard hypot(p.x - downAt.x, p.y - downAt.y) > SidebarDragController.threshold else { return }
    self.downAt = nil
    pressed = false
    paint()
    onDragOut(event)
  }
  override func mouseUp(with event: NSEvent) {
    downAt = nil
    let open = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    paint()
    if open { onChoose?(event.modifierFlags) }
  }
  override func rightMouseDown(with event: NSEvent) {
    if let action = value?.menuAction { context?.send(action) }
  }
  @objc private func closeTab() {
    if let action = value?.closeAction { context?.send(action) }
  }
  override func accessibilityPerformPress() -> Bool { onChoose?([]); return true }
  override func accessibilityPerformShowMenu() -> Bool {
    guard let action = value?.menuAction, let context else { return false }
    context.send(action)
    return true
  }
}

@MainActor
private final class SidebarRailPopoverButton: NSButton {
  override var acceptsFirstResponder: Bool { false }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityPerformPress() -> Bool { performClick(nil); return true }
}
