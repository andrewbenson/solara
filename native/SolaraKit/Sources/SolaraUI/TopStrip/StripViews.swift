import AppKit
import QuartzCore
import SolaraModel
import SolaraStore

@MainActor
protocol StripDraggable: AnyObject {
  var dragged: Bool { get set }
}

@MainActor
final class StripOntoRing: CALayer {
  override init() {
    super.init()
    actions = SurfaceLayer.noActions
    cornerRadius = StripMetrics.tabRadius
    cornerCurve = .continuous
    borderWidth = 1.5
    isHidden = true
  }

  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ on: Bool, width: CGFloat, palette: SidebarPalette) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    frame = CGRect(x: 0, y: StripMetrics.itemTop, width: width, height: StripMetrics.itemHeight)
    borderColor = palette.accent.cgColor
    backgroundColor = palette.pressed.cgColor
    CATransaction.commit()
    guard on != !isHidden else { return }
    isHidden = !on
    removeAnimation(forKey: "fade")
    guard on else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = StripMotionTiming.onto
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    add(fade, forKey: "fade")
  }
}

@MainActor
class StripHoverView: NSView {
  var hovered = false { didSet { if hovered != oldValue { repaint() } } }
  var pressed = false { didSet { if pressed != oldValue { repaint() } } }
  var context: StripContext?
  var passive = false

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { passive ? nil : super.hitTest(point) }

  func repaint() {}
  func press(_ mods: SidebarClickMods) {}
  func contextMenu() {}

  var accessibleName: String? { nil }
  var accessibleSelected: Bool? { nil }

  @objc(devToolTipAt:) func devToolTip(at point: NSValue) -> String? { toolTip }

  override func isAccessibilityElement() -> Bool { !passive && accessibleName?.isEmpty == false }
  override func accessibilityRole() -> NSAccessibility.Role? { accessibleSelected == nil ? .button : .radioButton }
  override func accessibilityLabel() -> String? { accessibleName }
  override func accessibilityValue() -> Any? { accessibleSelected.map { NSNumber(value: $0) } }

  override func accessibilityPerformPress() -> Bool {
    press(SidebarClickMods(NSEvent.ModifierFlags()))
    return true
  }

  override func accessibilityPerformShowMenu() -> Bool {
    contextMenu()
    return true
  }

  private var page: StripPageView? {
    var at = superview
    while let v = at {
      if let page = v as? StripPageView { return page }
      at = v.superview
    }
    return nil
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) { return contextMenu() }
    page?.drag.press(self, event)
    pressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    if page?.drag.dragged(self, event) == true {
      pressed = false
      return
    }
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    if page?.drag.released(self, event) == true {
      pressed = false
      return
    }
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    let was = pressed
    pressed = false
    if inside && was { press(SidebarClickMods(event.modifierFlags)) }
  }

  override func rightMouseDown(with event: NSEvent) { contextMenu() }
}

@MainActor
final class StripIconButton: StripHoverView {
  private let plate = CALayer()
  private let symbol = SymbolView()
  var radius: CGFloat = 5 { didSet { plate.cornerRadius = radius } }
  var active = false { didSet { if active != oldValue { repaint() } } }
  var onPress: (() -> Void)?
  var name: String?
  private var fills: (hover: NSColor, pressed: NSColor) = (.clear, .clear)

  override var accessibleName: String? { name ?? toolTip }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    plate.cornerRadius = radius
    layer?.addSublayer(plate)
    addSubview(symbol)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, hover: NSColor, pressed: NSColor, tooltip: String?) {
    symbol.set(name, size: size, weight: weight, color: color)
    fills = (hover, pressed)
    if toolTip != tooltip { toolTip = tooltip }
    repaint()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    symbol.frame = bounds
  }

  override func repaint() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed || active ? fills.pressed : hovered ? fills.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func press(_ mods: SidebarClickMods) { onPress?() }
  override func contextMenu() {}
}

final class SelectedTabLayer: CALayer {
  private var fills: [CAShapeLayer] = []
  private let rim = SurfaceLayer()
  private let floatingCard = SurfaceLayer()

  override init() {
    super.init()
    actions = SurfaceLayer.noActions
    addSublayer(floatingCard)
    addSublayer(rim)
  }

  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  static func path(width: CGFloat) -> CGPath {
    let r = StripMetrics.tabRadius
    let f = StripMetrics.flare
    let h = StripMetrics.height
    let top = StripMetrics.tabTop
    let left: CGFloat = 0.5
    let right = 0.5 + width - 1
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left - f, y: h))
    p.addArc(center: CGPoint(x: left - f, y: h - f), radius: f, startAngle: .pi / 2, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: left, y: top + r))
    p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + r, y: top), radius: r)
    p.addLine(to: CGPoint(x: right - r, y: top))
    p.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + r), radius: r)
    p.addLine(to: CGPoint(x: right, y: h - f))
    p.addArc(center: CGPoint(x: right + f, y: h - f), radius: f, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    p.closeSubpath()
    return p
  }

  func render(width: CGFloat, colors: [NSColor], floating: Bool, palette: StripPalette) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    frame = CGRect(x: 0, y: 0, width: width, height: StripMetrics.height)
    if floating {
      for fill in fills { fill.isHidden = true }
      rim.isHidden = true
      floatingCard.isHidden = false
      floatingCard.frame = CGRect(x: 0, y: StripMetrics.itemTop, width: width, height: StripMetrics.itemHeight)
      floatingCard.radius = StripMetrics.tabRadius
      floatingCard.fill = colors.last
      floatingCard.border = 0.5
      floatingCard.borderTint = palette.floatingCardBorder
      return
    }
    floatingCard.isHidden = true
    while fills.count < colors.count {
      let shape = CAShapeLayer()
      shape.actions = SurfaceLayer.noActions
      insertSublayer(shape, below: rim)
      fills.append(shape)
    }
    let path = Self.path(width: width)
    for (i, fill) in fills.enumerated() {
      fill.isHidden = i >= colors.count
      guard i < colors.count else { continue }
      fill.frame = bounds
      fill.path = path
      fill.fillColor = colors[i].cgColor
    }
    rim.isHidden = false
    rim.frame = CGRect(x: 0, y: StripMetrics.tabTop - 0.5, width: width, height: StripMetrics.rimHeight)
    rim.radius = StripMetrics.tabRadius + 0.5
    rim.border = 0.5
    rim.fill = nil
    rim.borderColors = [palette.rimTop, NSColor(white: 1, alpha: 0)]
  }
}

@MainActor
final class StripTabChip: StripHoverView, StripDraggable {
  private let selected = SelectedTabLayer()
  private let lifted = CALayer()
  private let ring = StripOntoRing()
  private let row = CALayer()
  private let icon = TabIconView()
  private var badges: TabMediaBadgesView?
  private let audio = StripIconButton()
  private let label = FadeLabel(fontSize: 12)
  private let close = StripIconButton()
  private var tab: Tab?
  private var active = false
  private var showsAudio = false
  private var band: StripEasedColor?
  private lazy var bandTicker = StripTicker(view: self) { [weak self] now in self?.stepBand(now) ?? false }
  var tuck: (() -> Void)?
  var dragged = false {
    didSet {
      guard dragged != oldValue else { return }
      renderSelected()
      repaint()
    }
  }
  var onto = false {
    didSet {
      guard onto != oldValue else { return }
      renderOnto()
      repaint()
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    selected.isHidden = true
    layer?.addSublayer(selected)
    lifted.actions = SurfaceLayer.noActions
    lifted.cornerRadius = StripMetrics.tabRadius
    lifted.cornerCurve = .continuous
    lifted.isHidden = true
    layer?.addSublayer(lifted)
    layer?.addSublayer(ring)
    row.actions = SurfaceLayer.noActions
    row.cornerRadius = StripMetrics.tabRadius
    row.cornerCurve = .continuous
    layer?.addSublayer(row)
    for v in [icon, audio, label, close] as [NSView] { addSubview(v) }
    audio.radius = 0
    audio.onPress = { [weak self] in
      guard let self, let id = self.tab?.id else { return }
      self.context?.send(.toggleMute(tabId: id))
    }
    close.radius = 5
    close.onPress = { [weak self] in
      guard let self, let id = self.tab?.id else { return }
      if let tuck = self.tuck { tuck() } else { self.context?.send(.close(tabId: id)) }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  var tabId: String? { tab?.id }

  override var accessibleName: String? { tab == nil ? nil : label.text }
  override var accessibleSelected: Bool? { active }

  func update(_ tabId: String, _ context: StripContext) {
    self.context = context
    guard let tab = context.state.tabs[tabId] else { return }
    if self.tab?.id != tabId { self.band = nil }
    self.tab = tab
    active = context.activeId == tabId
    showsAudio = context.playing.contains(tabId) || tab.muted
    let website = context.band(tabId)
    if band == nil { band = StripEasedColor(website?.background) }
    band?.retarget(website?.background, duration: StripMotionTiming.band)
    if band?.running == true { bandTicker.start() }
    let band = active ? website : nil
    let base = context.base
    icon.favicons = context.sidebar.favicons
    icon.set(context.sidebar.iconSpec(tab), palette: base)
    TabMediaBadgesView.attach(&badges, to: self, flags: context.sidebar.flags, tabId: tabId, host: context.sidebar.host, palette: base)
    label.text = context.title(tab)
    label.color = band?.text ?? (active ? base.selectedText : base.textTab)
    toolTip = context.tooltip(tab)
    audio.set(
      tab.muted ? "speaker.slash" : "speaker.wave.2", size: 11, weight: .regular, color: band?.icon ?? base.textTab, hover: .clear, pressed: .clear,
      tooltip: tab.muted ? "Unmute" : "Mute")
    audio.isHidden = !showsAudio
    let control = context.closeControl(tabId)
    close.set(
      tuck != nil ? "minus" : control.icon, size: 9, weight: .semibold, color: band?.icon ?? base.icon, hover: base.toolbarHover, pressed: base.toolbarPressed,
      tooltip: tuck != nil ? "Hide in Group" : control.tooltip)
    renderSelected()
    repaint()
    needsLayout = true
  }

  private func renderOnto() {
    guard let context else { return }
    ring.show(onto, width: bounds.width, palette: context.base)
  }

  private func renderSelected() {
    selected.isHidden = !active
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lifted.isHidden = !(dragged && !active)
    if let context { lifted.backgroundColor = context.palette.windowTint.cgColor }
    CATransaction.commit()
    guard active, let context else { return }
    var colors = [context.palette.card]
    if dragged { colors.insert(context.palette.windowTint, at: 0) }
    if let eased = band?.value, eased.alphaComponent > 0 { colors.append(eased) }
    selected.render(width: bounds.width, colors: colors, floating: context.host.floating, palette: context.palette)
  }

  private func stepBand(_ now: Double) -> Bool {
    band?.step(now: now)
    renderSelected()
    return band?.running ?? false
  }

  override func repaint() {
    guard let context else { return }
    let base = context.base
    let fill: NSColor = pressed && !active ? base.pressed : (hovered || dragged) && !active && !onto ? base.hover : .clear
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    row.backgroundColor = fill.cgColor
    CATransaction.commit()
    close.isHidden = !hovered
    if hovered { close.hovered = close.bounds.contains(close.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed, let context, let id = tab?.id { update(id, context) }
  }

  override func layout() {
    super.layout()
    let w = bounds.width
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    row.frame = CGRect(x: 0, y: StripMetrics.itemTop, width: w, height: StripMetrics.itemHeight)
    lifted.frame = row.frame
    CATransaction.commit()
    if onto { renderOnto() }
    var x: CGFloat = 9.5
    icon.frame = NSRect(x: x, y: StripMetrics.mid - 8, width: 16, height: 16)
    badges?.frame = icon.frame
    x += 16
    if showsAudio {
      x += 5
      audio.frame = NSRect(x: x, y: StripMetrics.mid - 8, width: 16, height: 16)
      x += 16
    }
    x += 5
    let right = w - 6 - StripMetrics.closeSlot
    label.frame = NSRect(x: x, y: StripMetrics.mid - 8, width: max(0, right - x), height: 16)
    close.frame = NSRect(x: right, y: StripMetrics.mid - 10, width: 20, height: 20)
  }

  override func press(_ mods: SidebarClickMods) {
    guard let id = tab?.id else { return }
    context?.send(.click(tabId: id, mods: mods))
  }

  override func contextMenu() {
    guard let id = tab?.id else { return }
    context?.send(.tabMenu(tabId: id))
  }
}

@MainActor
final class StripPinnedCell: StripHoverView {
  private let face = CALayer()
  private var ring: IconRingView?
  private var ringRequest: SidebarFaviconRequest?
  private let icon = TabIconView()
  private var badges: TabMediaBadgesView?
  private let mosaic = FolderMosaicView()
  private(set) var cell = ""
  private var active = false
  private var title: String?

  override var accessibleName: String? { title }
  override var accessibleSelected: Bool? { folderId == nil ? active : nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    face.actions = SurfaceLayer.noActions
    face.cornerRadius = StripMetrics.pinnedFaceRadius
    face.cornerCurve = .continuous
    layer?.addSublayer(face)
    addSubview(icon)
    addSubview(mosaic)
  }

  required init?(coder: NSCoder) { fatalError() }

  var folderId: String? { SidebarQuery.folderId(ofCell: cell) }

  func update(_ cell: String, members: [String], _ context: StripContext) {
    self.context = context
    self.cell = cell
    if let folderId {
      icon.isHidden = true
      mosaic.isHidden = false
      mosaic.render(members: members, context: context.sidebar)
      badges?.isHidden = true
      active = false
      ring?.isHidden = true
      title = context.query.folderLabel(windowId: context.windowId, folderId: folderId)
      toolTip = "\(title ?? "")\nShow Folder"
    } else if let tab = context.state.tabs[cell] {
      icon.isHidden = false
      mosaic.isHidden = true
      icon.favicons = context.sidebar.favicons
      icon.set(context.sidebar.iconSpec(tab), palette: context.base)
      TabMediaBadgesView.attach(&badges, to: self, flags: context.sidebar.flags, tabId: cell, host: context.sidebar.host, palette: context.base)
      active = context.activeId == cell
      renderRing(tab, context)
      let title = (tab.customTitle?.isEmpty == false ? tab.customTitle! : !tab.title.isEmpty ? tab.title : tab.url)
      self.title = title
      toolTip = tab.url.isEmpty ? title : "\(title)\n\(tab.url)"
    }
    repaint()
    needsLayout = true
  }

  private var standsOut: Bool { active && folderId == nil && context?.sidebar.host.iconRing == true }

  private func renderRing(_ tab: Tab, _ context: StripContext) {
    var source: IconRingSource?
    if active, context.sidebar.host.iconRing {
      switch TileView.cachedRingSource(tab, context.sidebar) {
      case .known(let known): source = known
      case .loading(let request): loadRing(request, tabId: tab.id, context)
      }
    }
    guard let source, let theme = IconRingView.theme(of: source) else {
      ring?.isHidden = true
      return
    }
    let view = ring ?? IconRingView()
    if ring == nil {
      ring = view
      addSubview(view, positioned: .below, relativeTo: icon)
    }
    view.cornerRadius = StripMetrics.pinnedFaceRadius
    view.strokeWidth = 1.5
    view.glass = true
    view.tintedRim = true
    view.dark = context.base.dark
    view.source = source
    view.theme = theme
    view.isHidden = false
    needsLayout = true
  }

  private func loadRing(_ request: SidebarFaviconRequest, tabId: String, _ context: StripContext) {
    guard ringRequest != request else { return }
    ringRequest = request
    context.sidebar.favicons.load(request) { [weak self] picture in
      guard let self, self.ringRequest == request else { return }
      self.ringRequest = nil
      guard picture != nil, self.cell == tabId, let current = self.context, let tab = current.state.tabs[tabId] else { return }
      self.renderRing(tab, current)
    }
  }

  override func repaint() {
    guard let context else { return }
    let base = context.base
    let folder = folderId != nil
    let fill: NSColor? = pressed ? base.pressed : active && !folder ? base.pinnedSelectedFill : hovered ? base.hover : nil
    let raised = standsOut && !pressed
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    face.backgroundColor = fill.map { raised ? base.glassTint($0, raised: true, solid: true) : $0 }?.cgColor
    face.borderWidth = raised ? 1 / (window?.backingScaleFactor ?? 2) : 0
    face.borderColor = NSColor.black.withAlphaComponent(base.dark ? 0.35 : 0.1).cgColor
    face.shadowOpacity = raised ? (base.dark ? 0.5 : 0.18) : 0
    face.shadowRadius = 2
    face.shadowOffset = CGSize(width: 0, height: 1)
    face.shadowColor = NSColor.black.cgColor
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    let inset = StripMetrics.pinnedFaceInset
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    face.frame = bounds.insetBy(dx: inset, dy: inset)
    face.shadowPath = CGPath(roundedRect: face.bounds, cornerWidth: StripMetrics.pinnedFaceRadius, cornerHeight: StripMetrics.pinnedFaceRadius, transform: nil)
    CATransaction.commit()
    ring?.frame = bounds.insetBy(dx: inset, dy: inset)
    icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    badges?.frame = icon.frame
    let side = FolderMosaicView.side
    mosaic.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
  }

  override func press(_ mods: SidebarClickMods) {
    if let folderId { return (context?.send(.tileFolder(folderId: folderId))) ?? () }
    context?.send(.click(tabId: cell, mods: mods))
  }

  override func contextMenu() {
    if let folderId { return (context?.send(.tileFolderMenu(folderId: folderId))) ?? () }
    context?.send(.tabMenu(tabId: cell))
  }
}

@MainActor
final class StripDockView: NSView {
  private let box = CALayer()
  private var cells: [String: StripPinnedCell] = [:]
  private(set) var order: [String] = []
  private var lefts: [CGFloat] = []
  private var shift: (Int, StripPinnedCell) -> CGFloat = { _, _ in 0 }
  var raised: (StripPinnedCell) -> Bool = { _ in false }
  var grow: CGFloat = 0 { didSet { if grow != oldValue { sizeBox() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    box.actions = SurfaceLayer.noActions
    box.cornerRadius = StripMetrics.tabRadius
    box.cornerCurve = .continuous
    box.borderWidth = 0.5
    layer?.addSublayer(box)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func update(cells ids: [String], members: [String: [String]], geometry: StripDragGeometry, _ context: StripContext) {
    order = ids
    let flat = context.sidebar.host.iconRing
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.backgroundColor = (flat ? context.base.flatTile(context.base.pinnedResting) : context.base.pinnedResting).cgColor
    box.borderWidth = flat ? 0 : 0.5
    box.borderColor = context.base.pinnedRestingStroke.cgColor
    CATransaction.commit()
    for (id, view) in cells where !ids.contains(id) {
      view.removeFromSuperview()
      cells[id] = nil
    }
    for (i, id) in ids.enumerated() {
      let view = cells[id] ?? StripPinnedCell()
      if view.superview == nil {
        addSubview(view)
        cells[id] = view
      }
      view.update(id, members: members[id] ?? [id], context)
    }
    lefts = geometry.lefts
    sizeBox()
    arrange(shift)
  }

  private func sizeBox() {
    let width = max(0, StripMetrics.dockWidth(order.count) + grow)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = CGRect(x: 0, y: 0, width: width, height: StripMetrics.itemHeight)
    box.opacity = Float(min(1, width / (StripMetrics.pinnedCell / 2)))
    CATransaction.commit()
  }

  func arrange(_ shift: @escaping (Int, StripPinnedCell) -> CGFloat) {
    self.shift = shift
    for (i, id) in order.enumerated() {
      guard let view = cells[id], i < lefts.count else { continue }
      view.frame = NSRect(x: lefts[i] + shift(i, view), y: 0.5, width: StripMetrics.pinnedCell, height: StripMetrics.itemHeight - 1)
      view.layer?.zPosition = raised(view) ? 10 : 0
    }
  }

  func cell(_ id: String) -> StripPinnedCell? { cells[id] }
}

@MainActor
final class StripGroupGlyph: NSView {
  private let bars = [CALayer(), CALayer(), CALayer()]
  private let symbol = SymbolView()
  private let emoji = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for bar in bars {
      bar.actions = SurfaceLayer.noActions
      layer?.addSublayer(bar)
    }
    emoji.alignment = .center
    emoji.font = .systemFont(ofSize: 12)
    addSubview(symbol)
    addSubview(emoji)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(icon: String?, tint: NSColor?, palette: StripPalette) {
    let own = icon.map { !$0.isEmpty && $0 != "symbol:square.stack.fill" } ?? false
    let isSymbol = own && icon!.hasPrefix("symbol:")
    for bar in bars { bar.isHidden = own }
    symbol.isHidden = !isSymbol
    emoji.isHidden = !own || isSymbol
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if !own {
      let color = (tint ?? palette.neutralSwatch).cgColor
      let mid: CGFloat = 13 / 2
      let specs: [(x: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, a: Float)] = [(0, 1.25, 7, 0.625, 0.5), (1.85, 1.25, 9, 0.625, 0.75), (3.6, 9.4, 10.6, 2.5, 1)]
      for (bar, s) in zip(bars, specs) {
        bar.frame = CGRect(x: s.x, y: mid - s.h / 2, width: s.w, height: s.h)
        bar.cornerRadius = s.r
        bar.backgroundColor = color
        bar.opacity = s.a
      }
    } else if isSymbol {
      symbol.frame = bounds
      symbol.set(String(icon!.dropFirst("symbol:".count)), size: 11, weight: .medium, color: tint ?? palette.base.icon)
    } else {
      emoji.stringValue = icon ?? ""
      let fitting = emoji.fittingSize
      emoji.frame = NSRect(x: (13 - fitting.width) / 2, y: (13 - fitting.height) / 2, width: fitting.width, height: fitting.height)
    }
  }
}

enum StripText {
  static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, max: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let measured = (text as NSString).size(withAttributes: [.font: font]).width
    return Swift.min(max, StripLayout.halfPointCeil(measured))
  }

  @MainActor
  static func groupName(_ group: TabGroup) -> String {
    group.name.isEmpty ? "\(group.tabIds.count) \(group.tabIds.count == 1 ? "Tab" : "Tabs")" : group.name
  }

  @MainActor
  static func groupChipWidth(_ group: TabGroup) -> CGFloat {
    StripLayout.halfPointCeil(8.5 + 13 + 12.5 + width(groupName(group), size: 12, weight: .semibold, max: 120) + 7)
  }

  @MainActor
  static func folderChipWidth(_ label: String) -> CGFloat {
    StripLayout.halfPointCeil(0.5 + 7 + 13 + 7 + width(label, size: 12, weight: .semibold, max: 110) + 5 + 9 + 6 + 0.5)
  }
}

@MainActor
final class StripLabel: NSView {
  var stringValue = "" { didSet { if stringValue != oldValue { needsDisplay = true } } }
  var textColor: NSColor = .labelColor { didSet { if textColor != oldValue { needsDisplay = true } } }
  var font: NSFont = .systemFont(ofSize: 12, weight: .semibold) { didSet { needsDisplay = true } }

  override var isFlipped: Bool { true }

  var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let text = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: style])
    let scale = window?.backingScaleFactor ?? 2
    let origin = convert(NSPoint.zero, to: nil)
    let snap = (origin.x * scale).rounded() / scale - origin.x
    text.draw(with: NSRect(x: snap, y: (bounds.height - lineHeight) / 2 - 0.5, width: bounds.width, height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }
}

@MainActor
final class StripGroupHeader: StripHoverView {
  private let glyph = StripGroupGlyph()
  private let name = StripLabel()
  var groupId = ""
  var expanded = false
  var onHover: ((Bool) -> Void)?

  override var accessibleName: String? { name.stringValue }
  override func isAccessibilityExpanded() -> Bool { expanded }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(glyph)
    addSubview(name)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }

  func update(_ group: TabGroup, shown: Bool, _ context: StripContext) {
    self.context = context
    groupId = group.id
    expanded = !group.collapsed
    let tint = StripPalette.tint(group.color)?.ns
    glyph.set(icon: group.icon, tint: tint, palette: context.palette)
    name.stringValue = StripText.groupName(group)
    name.textColor = tint ?? (shown ? context.base.selectedText : context.base.textTab)
    toolTip = expanded ? "Collapse Group" : "Expand Group"
    needsLayout = true
  }

  override func repaint() { onHover?(hovered) }

  override func layout() {
    super.layout()
    glyph.frame = NSRect(x: 8.5, y: (bounds.height - 13) / 2, width: 13, height: 13)
    let x: CGFloat = 8.5 + 13 + 12.5
    name.frame = NSRect(x: x, y: 0, width: max(0, min(120, bounds.width - x - 7)), height: bounds.height)
  }

  override func press(_ mods: SidebarClickMods) { context?.send(.toggleGroup(groupId: groupId, collapse: expanded)) }
  override func contextMenu() { context?.send(.groupMenu(groupId: groupId)) }
}

@MainActor
final class StripFolderChip: StripHoverView {
  private let plate = CALayer()
  private let glyph = StripGroupGlyph()
  private let name = StripLabel()
  private let chevron = SymbolView()
  private var tint: CSSColor?
  private var bare = false
  var groupId = ""

  override var accessibleName: String? { name.stringValue }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = StripMetrics.folderRadius
    plate.cornerCurve = .continuous
    plate.borderWidth = 0.5
    layer?.addSublayer(plate)
    for v in [glyph, name, chevron] as [NSView] { addSubview(v) }
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ group: TabGroup, label: String, holding: Bool, _ context: StripContext) {
    self.context = context
    groupId = group.id
    tint = StripPalette.tint(group.color)
    bare = group.color == "none"
    let ink = tint?.ns ?? (holding ? context.base.selectedText : context.base.textTab)
    glyph.set(icon: group.icon, tint: tint?.ns, palette: context.palette)
    name.stringValue = label
    name.textColor = ink
    chevron.set("chevron.down", size: 8, weight: .semibold, color: ink.withAlphaComponent(ink.alphaComponent * 0.6))
    toolTip = "\(label)\nShow Folder"
    repaint()
    needsLayout = true
  }

  override func repaint() {
    guard let context else { return }
    let base = context.base
    let fill: NSColor = pressed ? base.pressed : tint.map { $0.withAlpha(hovered ? 0.3 : 0.22).ns } ?? (hovered ? base.groupHeaderHover : bare ? .clear : base.groupFill)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = fill.cgColor
    plate.borderColor = (bare ? NSColor.clear : base.pinnedRestingStroke).cgColor
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    glyph.frame = NSRect(x: 7.5, y: (h - 13) / 2, width: 13, height: 13)
    let x: CGFloat = 7.5 + 13 + 7
    let nameWidth = max(0, bounds.width - x - 5 - 9 - 6.5)
    name.frame = NSRect(x: x, y: 0, width: nameWidth, height: h)
    chevron.frame = NSRect(x: x + nameWidth + 5, y: (h - 9) / 2, width: 9, height: 9)
  }

  override func press(_ mods: SidebarClickMods) { context?.send(.folderMenu(groupId: groupId)) }
  override func contextMenu() { context?.send(.groupMenu(groupId: groupId)) }
}

@MainActor
final class StripSplitPart: StripHoverView, NSViewToolTipOwner {
  private let divider = CALayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: 12)
  var first = true
  private(set) var tabId = ""
  private var focused = false
  private var tip = ""
  private var pressStart: CGFloat { first ? 0 : 12.5 }

  override var accessibleName: String? { tabId.isEmpty ? nil : label.text }
  override var accessibleSelected: Bool? { focused }

  override init(frame: NSRect) {
    super.init(frame: frame)
    divider.actions = SurfaceLayer.noActions
    layer?.addSublayer(divider)
    addSubview(icon)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ tabId: String, first: Bool, ink: StripBandPalette?, _ context: StripContext) {
    self.context = context
    self.tabId = tabId
    self.first = first
    guard let tab = context.state.tabs[tabId] else { return }
    focused = context.activeId == tabId
    let base = context.base
    icon.favicons = context.sidebar.favicons
    var spec = context.sidebar.iconSpec(tab, size: 14)
    spec.engineSymbol = nil
    icon.set(spec, palette: base)
    label.text = context.title(tab)
    label.color = ink.map { focused ? $0.text : $0.secondary } ?? (focused ? base.selectedText : base.textTab)
    divider.isHidden = first
    divider.backgroundColor = (ink?.divider ?? base.textTertiary).cgColor
    tip = tab.title.isEmpty ? tab.url : tab.title
    needsLayout = true
  }

  func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { tip }

  override func devToolTip(at point: NSValue) -> String? { convert(point.pointValue, from: nil).x >= pressStart ? tip : nil }

  override func layout() {
    super.layout()
    let h = bounds.height
    var x: CGFloat = 0
    if !first {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      divider.frame = CGRect(x: 6, y: (h - 16) / 2, width: 0.5, height: 16)
      CATransaction.commit()
      x = 12.5
    }
    icon.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
    x += 14 + 5
    label.frame = NSRect(x: x, y: (h - 16) / 2, width: max(0, bounds.width - x), height: 16)
    removeAllToolTips()
    addToolTip(NSRect(x: pressStart, y: 0, width: max(0, bounds.width - pressStart), height: h), owner: self, userData: nil)
  }

  override func press(_ mods: SidebarClickMods) { context?.send(.activate(tabId: tabId)) }
  override func contextMenu() { context?.send(.tabMenu(tabId: tabId)) }
}

@MainActor
final class StripSplitChip: StripHoverView, StripDraggable {
  private let selected = SelectedTabLayer()
  private let row = CALayer()
  private let symbol = SymbolView()
  private var parts: [StripSplitPart] = []
  private var active = false
  private(set) var tabIds: [String] = []
  var dragged = false {
    didSet { if dragged != oldValue, let context { update(tabIds, context) } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    selected.isHidden = true
    layer?.addSublayer(selected)
    row.actions = SurfaceLayer.noActions
    row.cornerRadius = StripMetrics.tabRadius
    row.cornerCurve = .continuous
    layer?.addSublayer(row)
    addSubview(symbol)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ tabIds: [String], _ context: StripContext) {
    self.context = context
    self.tabIds = tabIds
    active = tabIds.contains(context.activeId)
    let band = context.band(active ? context.activeId : tabIds.first ?? "")
    let ink = active ? band : nil
    symbol.set("rectangle.split.2x1", size: 11, color: ink?.secondary ?? context.base.textSecondary)
    while parts.count < tabIds.count {
      let part = StripSplitPart()
      addSubview(part)
      parts.append(part)
    }
    while parts.count > tabIds.count { parts.removeLast().removeFromSuperview() }
    for (i, id) in tabIds.enumerated() { parts[i].update(id, first: i == 0, ink: ink, context) }
    selected.isHidden = !active
    if active {
      var colors = [context.palette.card]
      if dragged { colors.insert(context.palette.windowTint, at: 0) }
      if let band { colors.append(band.background) }
      selected.render(width: bounds.width, colors: colors, floating: context.host.floating, palette: context.palette)
    }
    repaint()
    needsLayout = true
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    row.backgroundColor = (hovered && !active ? context.base.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed, let context { update(tabIds, context) }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    row.frame = CGRect(x: 0, y: StripMetrics.itemTop, width: bounds.width, height: StripMetrics.itemHeight)
    CATransaction.commit()
    symbol.frame = NSRect(x: 9.5, y: StripMetrics.mid - 8, width: 14, height: 16)
    let start: CGFloat = 9.5 + 14 + 4
    let inner = max(0, bounds.width - 6 - start)
    let each = parts.isEmpty ? 0 : inner / CGFloat(parts.count)
    for (i, part) in parts.enumerated() {
      let left = StripLayout.pixel(start + CGFloat(i) * each)
      part.frame = NSRect(x: left, y: StripMetrics.itemTop, width: StripLayout.pixel(start + CGFloat(i + 1) * each) - left, height: StripMetrics.itemHeight)
    }
  }

}

@MainActor
final class StripNewTabButton: StripHoverView {
  private let plate = CALayer()
  private let symbol = SymbolView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = StripMetrics.tabRadius
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    addSubview(symbol)
    toolTip = "New Tab (⌘T) — ⌥-click to open in Split View"
  }

  override var accessibleName: String? { "New Tab" }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ context: StripContext) {
    self.context = context
    symbol.set("plus", size: 13, color: context.base.textSecondary)
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed ? context.base.pressed : hovered ? context.base.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    symbol.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
  }

  override func press(_ mods: SidebarClickMods) { context?.send(.newTab(split: mods.alt)) }
}
