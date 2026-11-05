import AppKit
import SolaraModel
import SolaraStore

public enum SidebarRail {
  public static let width: Double = 42
  static let tile: CGFloat = 30
  static let rowHeight: CGFloat = 30
  static let rowGap: CGFloat = 2
  static let radius: CGFloat = 8
  static let icon: CGFloat = 16
  static let closeBadge: CGFloat = 14
  static let cornerBadge: CGFloat = 12

  public static func contains(width given: Double) -> Bool { given <= width + 0.5 }

  public static let listTop: CGFloat = 6

  public static func listLift(addressBar: Bool) -> CGFloat {
    max(0, SidebarMetrics.glowRoom + SidebarMetrics.listTopGap(addressBar: addressBar) - listTop)
  }

  public static func effectiveWidth(_ window: BrowserWindow, _ settings: Settings) -> Double {
    window.effectiveSidebarIconsOnly(settings) ? width : window.effectiveSidebarWidth(settings)
  }

  static func tileFrame(in bounds: CGRect) -> CGRect {
    CGRect(x: ((bounds.width - tile) / 2).rounded() + bounds.minX, y: ((bounds.height - tile) / 2).rounded() + bounds.minY, width: tile, height: tile)
  }

  static func iconFrame(in bounds: CGRect) -> CGRect {
    CGRect(x: ((bounds.width - icon) / 2).rounded() + bounds.minX, y: ((bounds.height - icon) / 2).rounded() + bounds.minY, width: icon, height: icon)
  }

  static func closeFrame(around tile: CGRect) -> CGRect {
    CGRect(x: tile.maxX - closeBadge / 2 - 2, y: tile.minY - closeBadge / 2 + 2, width: closeBadge, height: closeBadge)
  }

  static func trailingBadgeFrame(around tile: CGRect) -> CGRect {
    CGRect(x: tile.maxX - cornerBadge / 2 - 2, y: tile.maxY - cornerBadge / 2 - 2, width: cornerBadge, height: cornerBadge)
  }

  static func leadingBadgeFrame(around tile: CGRect) -> CGRect {
    CGRect(x: tile.minX - cornerBadge / 2 + 2, y: tile.maxY - cornerBadge / 2 - 2, width: cornerBadge, height: cornerBadge)
  }

  @MainActor
  static func make(_ kind: SidebarItemKind) -> NSView? {
    switch kind {
    case .tab, .tile: RailTabView()
    case .folder: RailFolderView()
    case .split: RailSplitView()
    case .groupHeader: RailGroupView()
    case .newTab: RailNewTabView()
    case .divider: RailDividerView()
    case .live(let key) where key.hasPrefix("livefolder|"): RailLiveFolderView()
    default: nil
    }
  }
}

@MainActor
final class RailBadge: NSView {
  private let plate = CALayer()
  private let glyph = SymbolView()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    layer?.addSublayer(plate)
    addSubview(glyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ symbol: String, fill: NSColor, ink: NSColor, rim: NSColor) {
    glyph.set(symbol, size: bounds.width * 0.55, weight: .bold, color: ink)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = fill.cgColor
    plate.borderColor = rim.cgColor
    plate.borderWidth = 1
    CATransaction.commit()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    plate.cornerRadius = bounds.width / 2
    CATransaction.commit()
    let side = (bounds.width * 0.7).rounded()
    glyph.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
  }
}

@MainActor
class RailIconView: SidebarRowView {
  let glass = SidebarGlassTile()
  let icon = TabIconView()
  var active = false
  var selected = false
  var popover: SidebarRailPopover?

  override var pressScales: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    glass.radius = SidebarRail.radius
    glass.layer?.cornerRadius = SidebarRail.radius
    glass.layer?.cornerCurve = .continuous
    glass.layer?.masksToBounds = true
    body.addSubview(glass)
    body.addSubview(icon)
  }

  required init?(coder: NSCoder) { fatalError() }

  var restingFill: NSColor { .clear }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    let fill = pressed ? palette.pressed : active ? palette.pinnedSelectedFill : hovered || selected ? palette.hover : restingFill
    glass.dark = palette.dark
    glass.flat = !active || pressed
    glass.tint = glass.flat ? fill : palette.glassTint(fill, raised: true)
    glass.raisedSelection = active && !pressed
    glass.outlineColor = !active && selected ? palette.dragBorder : nil
  }

  override func layoutBody() {
    glass.frame = SidebarRail.tileFrame(in: bounds)
    icon.frame = SidebarRail.iconFrame(in: glass.frame)
    if popover?.renameKey != nil { popover?.show(on: self) }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { popover?.close() }
    super.viewWillMove(toWindow: newWindow)
  }

  func syncRailRename(kind: String, id: String, initial: String, placeholder: String) {
    guard let context else { return }
    let key = "\(kind):\(id)"
    if context.host.renaming != key {
      if popover?.renameKey != nil {
        popover?.close(commitRename: false)
        popover = nil
      }
      return
    }
    guard popover?.renameKey != key else { return }
    popover?.close(commitRename: false)
    popover = SidebarRailPopover(kind: kind, id: id, initial: initial, placeholder: placeholder, context: context)
    needsLayout = true
  }

  func showContents(title: String, rows: [SidebarRailPopoverRow], groupId: String? = nil, folderId: String? = nil) {
    guard let context else { return }
    if popover?.popover.isShown == true || popover?.dismissedByAnchorClick == true {
      popover?.close()
      popover = nil
      return
    }
    popover = SidebarRailPopover(title: title, rows: rows, context: context, groupId: groupId, folderId: folderId)
    popover?.show(on: self)
  }

  func badgeColors(_ palette: SidebarPalette) -> (fill: NSColor, ink: NSColor, rim: NSColor) {
    let fill = palette.dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.98, alpha: 1)
    return (fill, palette.icon, palette.dark ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 0, alpha: 0.12))
  }
}

@MainActor
final class RailTabView: RailIconView {
  private var close: SidebarIconButton?
  private var audio: RailBadge?
  private var spinner: SpinnerView?
  private var badges: TabBadgesView?
  private var tab: Tab?
  private var loading = false
  private var closeTooltip = "Close Tab"
  private var closeSymbol = "xmark"
  private var closeReveal: CGFloat = 0

  var tabId: String? { tab?.id }

  override var accessibleTitle: String? {
    guard let tab, let context else { return nil }
    return context.title(tab)
  }

  func containsClose(_ point: NSPoint) -> Bool {
    hovered && !retired && close?.isHidden == false && close?.frame.contains(point) == true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if containsClose(local) { return close?.hitTest(local) }
    let hit = super.hitTest(point)
    if !hovered, let close, hit === close { return self }
    return hit
  }

  override func retiredLook() {
    active = false
    selected = false
    repaint()
  }

  override func render() {
    guard let context, let item else { return }
    let id: String
    switch item.kind {
    case .tab(let value), .tile(let value): id = value
    default: return
    }
    guard let tab = context.state.tabs[id] else { return }
    self.tab = tab
    let palette = context.palette
    active = context.activeId == id
    selected = context.flags.selection.contains(id)
    loading = context.flags.loading.contains(id)
    icon.favicons = context.favicons
    icon.set(context.iconSpec(tab), palette: palette)
    TabBadgesView.attach(&badges, to: body, flags: context.flags, tabId: id, host: context.host, palette: palette)
    let colors = badgeColors(palette)
    if context.flags.playing.contains(id) || tab.muted {
      let badge = audio ?? attach(RailBadge(frame: NSRect(x: 0, y: 0, width: SidebarRail.cornerBadge, height: SidebarRail.cornerBadge)))
      audio = badge
      badge.set(tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", fill: colors.fill, ink: colors.ink, rim: colors.rim)
      badge.isHidden = false
    } else {
      audio?.isHidden = true
    }
    let kind = context.query.closeKind(id)
    closeSymbol = kind == .unload ? "minus" : "xmark"
    closeTooltip = kind == .removePin ? "Remove Pinned Tab" : (kind == .unload ? "Unload Tab" : "Close Tab") + (context.host.closeHint.map { "  \($0)" } ?? "")
    toolTip = context.title(tab)
    syncRailRename(kind: "tab", id: id, initial: tab.customTitle ?? tab.title, placeholder: tab.title.isEmpty ? "Tab name" : tab.title)
    repaint()
  }

  private func attach<View: NSView>(_ view: View) -> View {
    addSubview(view)
    needsLayout = true
    return view
  }

  override func repaint() {
    super.repaint()
    guard let context else { return }
    let palette = context.palette
    if hovered && tab != nil {
      let button = close ?? attach(makeClose())
      close = button
      let colors = badgeColors(palette)
      button.set(closeSymbol, size: 7, weight: .bold, color: colors.ink, tooltip: closeTooltip)
      button.hoverFill = palette.dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.9, alpha: 1)
      button.pressedFill = palette.toolbarPressed
      button.layer?.backgroundColor = colors.fill.cgColor
      button.layer?.borderColor = colors.rim.cgColor
      button.layer?.borderWidth = 1
      button.layer?.cornerRadius = SidebarRail.closeBadge / 2
      button.isHidden = false
      button.syncHover()
    }
    let target: CGFloat = hovered && tab != nil ? 1 : 0
    if target != closeReveal {
      closeReveal = target
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = target == 1 ? 0.12 : 0.16
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
        ctx.allowsImplicitAnimation = true
        close?.animator().alphaValue = target
      }
    }
    if loading {
      if spinner == nil { spinner = attach(SpinnerView()) }
      spinner?.isHidden = false
    } else if let spinner {
      spinner.removeFromSuperview()
      self.spinner = nil
    }
  }

  private func makeClose() -> SidebarIconButton {
    let button = SidebarIconButton()
    button.wantsLayer = true
    button.alphaValue = 0
    button.radius = SidebarRail.closeBadge / 2
    button.onPress = { [weak self] in
      guard let self, let id = self.tab?.id else { return }
      self.context?.send(.close(tabId: id))
    }
    return button
  }

  override func layoutBody() {
    super.layoutBody()
    badges?.frame = icon.frame
    let tileInSelf = body.convert(glass.frame, to: self)
    close?.frame = SidebarRail.closeFrame(around: tileInSelf)
    audio?.frame = SidebarRail.trailingBadgeFrame(around: tileInSelf)
    spinner?.frame = SidebarRail.leadingBadgeFrame(around: tileInSelf).insetBy(dx: 1, dy: 1)
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context, let id = tab?.id else { return }
    context.send(.click(tabId: id, mods: mods))
    if count == 2, case .tile? = item?.kind { context.send(.tileDoubleClick(tabId: id)) }
  }

  override func middleClick() {
    guard let id = tab?.id else { return }
    context?.send(.middleClick(tabId: id))
  }

  override var hoverTarget: (kind: String, id: String)? {
    guard let tab, context?.host.renaming != "tab:\(tab.id)" else { return nil }
    return ("tab", tab.id)
  }

  override func contextMenu() {
    guard let id = tab?.id else { return }
    context?.send(.tabMenu(tabId: id))
  }
}

@MainActor
final class RailFolderView: RailIconView {
  private let mark = RailBadge(frame: NSRect(x: 0, y: 0, width: SidebarRail.cornerBadge, height: SidebarRail.cornerBadge))
  private var folderId = ""

  override var accessibleTitle: String? {
    guard let context else { return nil }
    let name = context.query.folderMembers(windowId: context.windowId, folderId).lazy.compactMap { context.state.tabs[$0]?.tileFolder?.name }.first
    return name.map { $0.isEmpty ? "Folder" : $0 } ?? "Folder"
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(mark)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context, case .folder(let id)? = item?.kind else { return }
    folderId = id
    let members = context.query.folderMembers(windowId: context.windowId, id)
    let tab = context.activeId.flatMap { members.contains($0) ? context.state.tabs[$0] : nil }
    active = tab != nil
    selected = false
    icon.favicons = context.favicons
    if let tab {
      icon.set(context.iconSpec(tab), palette: context.palette)
    } else {
      icon.set(TabIconSpec(url: "", favicon: nil, customIcon: "symbol:folder.fill", profileId: context.host.profileId), palette: context.palette)
    }
    let colors = badgeColors(context.palette)
    mark.set("folder.fill", fill: colors.fill, ink: colors.ink, rim: colors.rim)
    mark.isHidden = tab == nil
    toolTip = accessibleTitle
    repaint()
  }

  override func layoutBody() {
    super.layoutBody()
    mark.frame = SidebarRail.trailingBadgeFrame(around: body.convert(glass.frame, to: self))
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    context?.send(.folder(folderId: folderId))
  }

  override func contextMenu() { context?.send(.folderMenu(folderId: folderId)) }

  override var hoverTarget: (kind: String, id: String)? { ("folder", folderId) }
}

@MainActor
final class RailSplitView: RailIconView {
  private let mark = RailBadge(frame: NSRect(x: 0, y: 0, width: SidebarRail.cornerBadge, height: SidebarRail.cornerBadge))
  private var panes: [String] = []

  override var accessibleTitle: String? {
    guard let context else { return nil }
    let titles = panes.compactMap { context.state.tabs[$0] }.map(context.title)
    return titles.isEmpty ? nil : titles.joined(separator: " | ")
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(mark)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var shownPane: String? {
    guard let context else { return panes.first }
    return panes.first { $0 == context.activeId } ?? panes.first
  }

  override func render() {
    guard let context, case .split(let id)? = item?.kind else { return }
    panes = context.query.splitPanes(id)
    active = panes.contains(context.activeId ?? "")
    selected = false
    if let shown = shownPane.flatMap({ context.state.tabs[$0] }) {
      icon.favicons = context.favicons
      icon.set(context.iconSpec(shown), palette: context.palette)
    }
    let colors = badgeColors(context.palette)
    mark.set("rectangle.split.2x1.fill", fill: colors.fill, ink: colors.ink, rim: colors.rim)
    toolTip = accessibleTitle
    repaint()
  }

  override func layoutBody() {
    super.layoutBody()
    mark.frame = SidebarRail.trailingBadgeFrame(around: body.convert(glass.frame, to: self))
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let id = shownPane else { return }
    context?.send(.click(tabId: id, mods: mods))
  }

  override func middleClick() {
    guard let id = shownPane else { return }
    context?.send(.middleClick(tabId: id))
  }

  override var hoverTarget: (kind: String, id: String)? { shownPane.map { ("tab", $0) } }

  override func contextMenu() {
    guard let id = shownPane else { return }
    context?.send(.tabMenu(tabId: id))
  }
}

@MainActor
final class RailGroupView: RailIconView {
  private var groupId = ""
  private var tint: NSColor = .clear

  override var accessibleTitle: String? { context?.query.groupLabel(groupId) }

  override var restingFill: NSColor { tint }

  override func render() {
    guard let context, case .groupHeader(let id)? = item?.kind, let group = context.state.groups[id] else { return }
    groupId = id
    let palette = context.palette
    let shownTab = group.tabIds.first { $0 == context.activeId } ?? group.tabIds.first
    let tab = shownTab.flatMap { context.state.tabs[$0] }
    active = shownTab != nil && shownTab == context.activeId
    selected = false
    tint = palette.groupSurface(group.color).fill
    icon.favicons = context.favicons
    icon.set(
      TabIconSpec(url: tab?.url ?? "", favicon: tab?.favicon, customIcon: group.icon ?? tab?.customIcon, profileId: tab?.profileId ?? context.host.profileId),
      palette: palette)
    toolTip = context.query.groupLabel(id)
    popover?.update(context: context)
    syncRailRename(kind: "group", id: id, initial: group.name, placeholder: context.query.groupLabel(id))
    repaint()
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context, context.state.groups[groupId] != nil else { return }
    guard context.host.renaming != "group:\(groupId)" else { return }
    showContents(title: context.query.groupLabel(groupId), rows: SidebarRailPopoverRow.group(groupId, context: context), groupId: groupId)
  }

  override func contextMenu() { context?.send(.groupMenu(groupId: groupId)) }

  override var hoverTarget: (kind: String, id: String)? {
    groupId.isEmpty || context?.host.renaming == "group:\(groupId)" ? nil : ("group", groupId)
  }
}

@MainActor
final class RailLiveFolderView: RailIconView {
  private var folderId = ""

  override var accessibleTitle: String? {
    guard case .live(let key)? = item?.kind else { return nil }
    return context?.live?.header(key)?.folder.name
  }

  override func render() {
    guard let context, case .live(let key)? = item?.kind, let spec = context.live?.header(key) else { return }
    folderId = spec.folder.id
    active = false
    selected = false
    let (site, glyph) = SidebarLive.folderIcon(spec.folder)
    icon.favicons = context.favicons
    icon.set(TabIconSpec(url: site, favicon: nil, customIcon: glyph, profileId: spec.folder.profileId), palette: context.palette)
    toolTip = spec.folder.name
    popover?.update(context: context)
    repaint()
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context, let live = context.live?.live, let folder = live.state.folders[folderId] else { return }
    showContents(title: folder.name, rows: SidebarRailPopoverRow.live(folderId, context: context), folderId: folderId)
  }

  override func contextMenu() { context?.send(.live(action: "folderMenu", folderId: folderId, id: nil, meta: false)) }
}

@MainActor
final class RailNewTabView: SidebarRowView {
  private let plate = CALayer()
  private let plus = SymbolView()

  override var accessibleTitle: String? { "New Tab" }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarRail.radius
    plate.cornerCurve = .continuous
    body.layer?.addSublayer(plate)
    body.addSubview(plus)
    toolTip = "New Tab"
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context else { return }
    plus.set("plus", size: 16, weight: .medium, color: context.palette.newTabIcon)
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed ? context.palette.pressed : hovered ? context.palette.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = SidebarRail.tileFrame(in: bounds)
    CATransaction.commit()
    plus.frame = SidebarRail.iconFrame(in: plate.frame)
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    context?.send(.newTab(split: mods.alt))
  }
}

@MainActor
final class RailDividerView: SidebarRowView {
  private let line = CALayer()

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    line.actions = SurfaceLayer.noActions
    body.layer?.addSublayer(line)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func render() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.backgroundColor = context.palette.divider.cgColor
    CATransaction.commit()
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let width = (bounds.width * 0.5).rounded()
    line.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - 1) / 2).rounded(), width: width, height: 1)
    CATransaction.commit()
  }
}
