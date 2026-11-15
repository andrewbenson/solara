import AppKit
import QuartzCore
import SolaraLive

@MainActor
struct SidebarLiveColors {
  let success, failure, pending, merged, draft, conflict, pip, chip: NSColor

  init(dark: Bool) {
    func c(_ text: String) -> NSColor { SidebarPalette.parse(text)! }
    success = c(dark ? "#3FB950" : "#1A7F37")
    failure = c(dark ? "#F85149" : "#CF222E")
    pending = c(dark ? "#D29922" : "#9A6700")
    merged = c(dark ? "#A371F7" : "#8250DF")
    draft = c(dark ? "#8B949E" : "#6E7781")
    conflict = c(dark ? "#DB6D28" : "#BC4C00")
    pip = c(dark ? "#4C8DF6" : "#0969DA")
    chip = c(dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)")
  }

  static func countPill(dark: Bool) -> NSColor { SidebarPalette.parse(dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.15)")! }

  func completion(_ state: CompletionState) -> (symbol: String, color: NSColor, title: String) {
    switch state {
    case .merged: ("checkmark.circle.fill", merged, "Merged")
    case .reviewed: ("checkmark.circle.fill", success, "Reviewed")
    case .closed: ("xmark.circle.fill", draft, "Closed")
    }
  }

  func badge(_ badge: GitHub.Badge) -> (symbol: String?, color: NSColor, tip: String) {
    switch badge {
    case .conflict: ("exclamationmark.triangle.fill", conflict, "Merge conflicts")
    case .failing: ("xmark.circle.fill", failure, "Checks are failing")
    case .changesRequested: ("arrow.uturn.backward.circle.fill", failure, "Changes Requested")
    case .pending: (nil, pending, "Some checks haven't completed yet")
    case .approved: ("checkmark.circle.fill", success, "Approved")
    case .passed: ("checkmark", success, "All checks have passed")
    }
  }
}

struct SidebarLiveRenderKey<T: Equatable>: Hashable {
  let value: T
  let palette: Int
  static func == (a: Self, b: Self) -> Bool { a.palette == b.palette && a.value == b.value }
  func hash(into hasher: inout Hasher) { hasher.combine(palette) }
}

@MainActor
enum SidebarLiveViews {
  static func make(_ key: String) -> NSView {
    if key.hasPrefix("lf:") { return LiveBoxView() }
    if key.hasPrefix("livefolder|") { return LiveHeaderView() }
    if key.hasPrefix("live|") { return LiveItemRowView() }
    let tail = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
    if tail.hasPrefix("k:") { return LiveStackRowView() }
    if tail.hasPrefix("h:") { return LiveSectionView() }
    if tail.hasPrefix("m:") { return LiveMoreRowView() }
    if tail.hasPrefix("c:") { return LiveCompletedRowView() }
    if tail == "done" { return LiveFooterRowView() }
    return LiveNoteRowView()
  }

  static func label(_ size: CGFloat, weight: NSFont.Weight = .regular, lines: Int = 1) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    field.cell?.truncatesLastVisibleLine = true
    return field
  }

  static func pill(_ layer: CALayer, _ field: NSTextField, right: CGFloat, height: CGFloat, minWidth: CGFloat, padding: CGFloat, midY: CGFloat) -> CGFloat {
    let size = field.fittingSize
    let width = max(minWidth, size.width + padding * 2)
    let frame = CGRect(x: right - width, y: midY - height / 2, width: width, height: height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = frame
    layer.cornerRadius = height / 2
    CATransaction.commit()
    field.frame = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    return width
  }
}

final class LiveSpinGlyph: NSView {
  private let glyph = CALayer()
  private var spec: (name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor)?
  var spinning = false { didSet { if spinning != oldValue { syncSpin() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    glyph.actions = SurfaceLayer.noActions
    glyph.contentsGravity = .center
    layer?.addSublayer(glyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    if let spec, spec.name == name, spec.size == size, spec.weight == weight, spec.color == color { return }
    spec = (name, size, weight, color)
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    glyph.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyph.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
    glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
    glyph.contentsScale = window?.backingScaleFactor ?? 2
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncSpin()
  }

  private func syncSpin() {
    guard spinning, window != nil else { return glyph.removeAnimation(forKey: "spin") }
    guard glyph.animation(forKey: "spin") == nil else { return }
    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = isFlipped ? 2 * Double.pi : -2 * Double.pi
    turn.duration = 0.9
    turn.repeatCount = .infinity
    turn.timingFunction = CAMediaTimingFunction(name: .linear)
    turn.isRemovedOnCompletion = false
    glyph.add(turn, forKey: "spin")
  }
}

class LiveRowView: SidebarRowView {
  let plate = CALayer()
  var plateRadius: CGFloat { 8 }
  var row: SidebarLiveRow?

  override func clearIdentity() { row = nil }

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    body.layer?.addSublayer(plate)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func renderKey(_ item: SidebarItem, _ context: SidebarContext) -> AnyHashable? {
    guard case .live(let key) = item.kind, let row = context.live?.row(key) else { return nil }
    return SidebarLiveRenderKey(value: row, palette: context.paletteGeneration)
  }

  override func render() {
    guard let context, case .live(let key)? = item?.kind else { return }
    row = context.live?.row(key)
    renderRow(context)
    repaint()
    needsLayout = true
  }

  func renderRow(_ context: SidebarContext) {}

  var interactive: Bool { true }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.cornerRadius = plateRadius
    plate.backgroundColor = (interactive && hovered ? context.palette.rowHover : .clear).cgColor
    CATransaction.commit()
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    layoutRow()
  }

  func layoutRow() {}

  func send(_ action: String, _ folderId: String, _ id: String? = nil, meta: Bool = false) {
    context?.send(.live(action: action, folderId: folderId, id: id, meta: meta))
  }
}

final class LiveBoxView: SidebarRowView {
  private let box = CALayer()
  var fill: CALayer { box }

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    box.cornerRadius = SidebarMetrics.groupRadius
    box.cornerCurve = .continuous
    box.borderWidth = SidebarMetrics.groupBorder
    box.actions = SurfaceLayer.noActions
    body.layer?.addSublayer(box)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func renderKey(_ item: SidebarItem, _ context: SidebarContext) -> AnyHashable? { context.paletteGeneration }

  override func render() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.backgroundColor = context.palette.groupFill.cgColor
    box.borderColor = context.palette.groupStroke.cgColor
    CATransaction.commit()
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = bounds
    CATransaction.commit()
  }
}

final class LiveHeaderView: SidebarRowView {
  private let surface = SurfaceLayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: 13, weight: .medium)
  private let warning = SidebarIconButton()
  private let refresh = SidebarIconButton()
  private let spinner = LiveSpinGlyph()
  private let countPlate = CALayer()
  private let count = SidebarLiveViews.label(11, weight: .semibold)
  private let pip = CALayer()
  private var spec: SidebarLiveHeaderSpec?

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    surface.radius = SidebarMetrics.groupRadius - SidebarMetrics.groupBorder
    body.layer?.addSublayer(surface)
    for layer in [countPlate, pip] {
      layer.actions = SurfaceLayer.noActions
      body.layer?.addSublayer(layer)
    }
    pip.cornerRadius = 3.5
    count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    count.alignment = .center
    for view in [icon, label, count, spinner, warning, refresh] as [NSView] { body.addSubview(view) }
    warning.onPress = { [weak self] in self?.send("settings") }
    refresh.onPress = { [weak self] in self?.send("refresh") }
    spinner.spinning = true
  }

  required init?(coder: NSCoder) { fatalError() }

  private var folderId: String { spec?.folder.id ?? "" }

  private func send(_ action: String) { context?.send(.live(action: action, folderId: folderId, id: nil, meta: false)) }

  override func renderKey(_ item: SidebarItem, _ context: SidebarContext) -> AnyHashable? {
    guard case .live(let key) = item.kind, let spec = context.live?.header(key) else { return nil }
    return SidebarLiveRenderKey(value: spec, palette: context.paletteGeneration)
  }

  override func render() {
    guard let context, case .live(let key)? = item?.kind, let spec = context.live?.header(key) else { return }
    self.spec = spec
    let palette = context.palette
    let colors = SidebarLiveColors(dark: palette.dark)
    let (site, glyph) = SidebarLive.folderIcon(spec.folder)
    icon.favicons = context.favicons
    icon.set(TabIconSpec(url: site, favicon: nil, customIcon: glyph, profileId: spec.folder.profileId), palette: palette)
    label.text = spec.folder.name
    label.color = palette.groupTitle
    warning.isHidden = spec.status?.error == nil
    if let error = spec.status?.error {
      warning.set("exclamationmark.triangle.fill", size: 10, weight: .regular, color: colors.pending, tooltip: LiveEngine.errorText(error.kind, source: error.source))
    }
    refresh.set("arrow.clockwise", size: 10, weight: .semibold, color: palette.icon, tooltip: spec.statusText)
    refresh.hoverFill = palette.toolbarHover
    refresh.pressedFill = palette.toolbarPressed
    spinner.set("arrow.clockwise", size: 10, weight: .semibold, color: palette.textSecondary)
    spinner.toolTip = spec.statusText
    count.stringValue = "\(spec.count)"
    count.textColor = palette.textTab
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    countPlate.backgroundColor = SidebarLiveColors.countPill(dark: palette.dark).cgColor
    pip.backgroundColor = colors.pip.cgColor
    CATransaction.commit()
    repaint()
    needsLayout = true
  }

  override func repaint() {
    guard let context, let spec else { return }
    let palette = context.palette
    surface.fill = pressed ? palette.pressed : hovered ? palette.groupHeaderHover : .clear
    let hover = hovered && !spec.updating
    refresh.isHidden = !hover
    if hover { refresh.syncHover() }
    spinner.isHidden = !spec.updating
    let counted = !spec.updating && spec.collapsed
    let alpha: Float = hover ? 0 : 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    countPlate.isHidden = !counted
    countPlate.opacity = alpha
    pip.isHidden = !(counted && spec.unread)
    pip.opacity = alpha
    CATransaction.commit()
    count.isHidden = !counted
    count.alphaValue = CGFloat(alpha)
    spinner.alphaValue = CGFloat(alpha)
  }

  private var idleWidth: CGFloat {
    guard let spec else { return 0 }
    if spec.updating { return 22 }
    guard spec.collapsed else { return 0 }
    let pill = max(20, count.fittingSize.width + 12)
    return pill + (spec.unread ? 7 + 5 : 0) + 2
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    let mid = h / 2
    let x0 = 9 + SidebarMetrics.groupPad
    icon.frame = NSRect(x: x0, y: mid - 8, width: 16, height: 16)
    let right = bounds.width - 6
    let idle = idleWidth
    let slot = max(22, idle)
    refresh.frame = NSRect(x: right - 22, y: mid - 11, width: 22, height: 22)
    spinner.frame = NSRect(x: right - 22, y: mid - 11, width: 22, height: 22)
    if spec?.collapsed == true && spec?.updating == false {
      let pillRight = right - 2
      let width = SidebarLiveViews.pill(countPlate, count, right: pillRight, height: 18, minWidth: 20, padding: 6, midY: mid)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      pip.frame = CGRect(x: pillRight - width - 5 - 7, y: mid - 3.5, width: 7, height: 7)
      CATransaction.commit()
    }
    var labelRight = right - slot
    if !warning.isHidden {
      warning.frame = NSRect(x: labelRight - 2 - 18, y: mid - 9, width: 18, height: 18)
      labelRight -= 20
    }
    let x = x0 + 16 + 5
    label.frame = NSRect(x: x, y: mid - 9, width: max(0, labelRight - x), height: 18)
  }

  override func click(_ mods: SidebarClickMods, count: Int) { send("toggle") }

  override func contextMenu() { send("folderMenu") }
}

final class LiveItemRowView: LiveRowView {
  private let surface = SurfaceLayer()
  private let pipDot = CALayer()
  private let icon = TabIconView()
  private let glyph = SymbolView()
  private let label = FadeLabel(fontSize: 13)
  private let boldLabel = FadeLabel(fontSize: 13, weight: .medium)
  private let chipPlate = CALayer()
  private let chip = SidebarLiveViews.label(10, weight: .semibold)
  private let closeButton = SidebarIconButton()
  private let badge = SymbolView()
  private let badgeDot = CALayer()
  private let badgeHolder = NSView()
  private let done = SidebarLiveViews.label(11, weight: .medium)
  private var spec: SidebarLiveItemSpec?
  private var popped: CompletionState?

  override var interactive: Bool { false }

  override func clearIdentity() {
    super.clearIdentity()
    spec = nil
    popped = nil
    laidOutClosing = false
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    surface.radius = SidebarMetrics.rowRadius
    body.layer?.addSublayer(surface)
    for layer in [pipDot, chipPlate] {
      layer.actions = SurfaceLayer.noActions
      body.layer?.addSublayer(layer)
    }
    pipDot.cornerRadius = 2.5
    chipPlate.cornerRadius = 5
    chip.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    badgeHolder.wantsLayer = true
    badgeDot.actions = SurfaceLayer.noActions
    badgeDot.cornerRadius = 3.5
    badgeDot.borderWidth = 0.5
    badgeHolder.layer?.addSublayer(badgeDot)
    badgeHolder.addSubview(badge)
    glyph.wantsLayer = true
    for view in [icon, glyph, label, boldLabel, chip, badgeHolder, done, closeButton] as [NSView] { body.addSubview(view) }
    closeButton.radius = 6
    closeButton.onPress = { [weak self] in
      guard let self, let spec = self.spec else { return }
      self.send("close", spec.folderId, spec.tabId)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func retiredLook() {
    spec?.active = false
    repaint()
  }

  override func renderRow(_ context: SidebarContext) {
    guard case .item(let spec)? = row?.kind else { return }
    let was = self.spec
    self.spec = spec
    if spec.folded != (was?.folded ?? false) || was == nil { fold(spec.folded, animated: was != nil) }
    let palette = context.palette
    let colors = SidebarLiveColors(dark: palette.dark)
    let item = spec.item
    icon.favicons = context.favicons
    icon.isHidden = true
    glyph.isHidden = true
    if let completion = spec.completion {
      let look = colors.completion(completion)
      glyph.set(look.symbol, size: 14, weight: .semibold, color: look.color)
      glyph.isHidden = false
      if popped != completion, was != nil {
        popped = completion
        pop()
      }
    } else if let pr = item.pr {
      glyph.set("arrow.triangle.pull", size: 12, weight: .semibold, color: pr.draft ? colors.draft : colors.success)
      glyph.isHidden = false
    } else if let raw = item.icon, raw.hasPrefix("http:") || raw.hasPrefix("https:") {
      icon.set(TabIconSpec(url: item.url, favicon: raw, customIcon: nil, profileId: context.host.profileId, direct: true), palette: palette)
      icon.isHidden = false
    } else {
      icon.set(TabIconSpec(url: item.url, favicon: nil, customIcon: item.icon, profileId: context.host.profileId), palette: palette)
      icon.isHidden = false
    }
    label.text = item.title
    boldLabel.text = item.title
    label.isHidden = spec.unread
    boldLabel.isHidden = !spec.unread
    if let stack = item.pr?.stack, spec.inStack {
      chip.stringValue = "\(stack.position)"
      chip.textColor = palette.textSecondary
      chip.isHidden = false
    } else {
      chip.isHidden = true
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    chipPlate.isHidden = chip.isHidden
    chipPlate.backgroundColor = colors.chip.cgColor
    pipDot.isHidden = !spec.unread
    pipDot.backgroundColor = colors.pip.cgColor
    CATransaction.commit()
    closeButton.set("xmark", size: 10, weight: .semibold, color: palette.icon, tooltip: "Close Tab" + (context.host.closeHint.map { "  \($0)" } ?? ""))
    closeButton.hoverFill = palette.toolbarHover
    closeButton.pressedFill = palette.toolbarPressed
    badgeHolder.isHidden = true
    done.isHidden = true
    if let completion = spec.completion {
      let look = colors.completion(completion)
      done.stringValue = look.title
      done.textColor = look.color
      done.isHidden = false
    } else if let pr = item.pr, let kind = GitHub.prBadge(pr) {
      let look = colors.badge(kind)
      badgeHolder.toolTip = look.tip
      badgeHolder.isHidden = false
      if let symbol = look.symbol {
        badge.set(symbol, size: 11, weight: .semibold, color: look.color)
        badge.isHidden = false
        badgeDot.isHidden = true
      } else {
        badge.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeDot.isHidden = false
        badgeDot.backgroundColor = look.color.cgColor
        badgeDot.borderColor = (palette.dark ? NSColor(white: 0, alpha: 0.3) : NSColor(white: 0, alpha: 0.1)).cgColor
        CATransaction.commit()
      }
    }
  }

  private func fold(_ folded: Bool, animated: Bool) {
    layer?.masksToBounds = folded
    let target: CGFloat = folded ? 0 : 1
    guard animated else { return body.alphaValue = target }
    NSAnimationContext.runAnimationGroup { motion in
      motion.duration = SidebarLiveMetrics.completionFoldDuration
      motion.timingFunction = SidebarMotion.foldCurve
      body.animator().alphaValue = target
    }
  }

  private func pop() {
    guard let layer = glyph.layer else { return }
    let size = CGSize(width: 16, height: 16)
    func scaled(_ s: CGFloat) -> CATransform3D {
      var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
      t = CATransform3DScale(t, s, s, 1)
      return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    }
    let spring = CASpringAnimation(keyPath: "sublayerTransform")
    spring.fromValue = NSValue(caTransform3D: scaled(0.3))
    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    spring.mass = 1
    spring.stiffness = 384.58
    spring.damping = 18.2
    spring.duration = spring.settlingDuration
    layer.add(spring, forKey: "pop")
  }

  override func repaint() {
    guard let context, let spec else { return }
    let palette = context.palette
    let active = spec.active
    let fill: NSColor = !active && pressed ? palette.pressed : active ? palette.selected : hovered ? palette.hover : .clear
    surface.fill = fill
    surface.border = active ? 1 : 0
    surface.borderColors = active ? palette.selectedBorder : []
    surface.glowColor = active ? palette.glowColor : nil
    surface.glowOpacity = active ? palette.glowOpacity : 0
    surface.glowRadius = palette.glowRadius
    let color = active ? palette.selectedText : spec.completion != nil ? palette.textSecondary : palette.textTab
    label.color = color
    boldLabel.color = color
    let closing = hovered && spec.tabId != nil && spec.completion == nil
    closeButton.isHidden = !closing
    if closing { closeButton.syncHover() }
    badgeHolder.alphaValue = closing ? 0 : 1
    done.alphaValue = closing ? 0 : 1
    if closing != laidOutClosing {
      laidOutClosing = closing
      needsLayout = true
    }
  }

  private var laidOutClosing = false

  private var trailingWidth: CGFloat {
    if !done.isHidden { return done.fittingSize.width + 4 }
    return badgeHolder.isHidden ? 0 : 22
  }

  override func layoutRow() {
    guard let spec else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    let mid = h / 2
    let indent: CGFloat = spec.inStack ? SidebarLiveMetrics.stackIndent : 0
    let x0 = 9 + indent
    icon.frame = NSRect(x: x0, y: mid - 8, width: 16, height: 16)
    glyph.frame = icon.frame
    let right = bounds.width - 6
    let trailing = trailingWidth
    let slot = closeButton.isHidden ? trailing : max(22, trailing)
    closeButton.frame = NSRect(x: right - 22, y: mid - 11, width: 22, height: 22)
    badgeHolder.frame = NSRect(x: right - 22, y: mid - 11, width: 22, height: 22)
    badge.frame = NSRect(x: 3, y: 3, width: 16, height: 16)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    badgeDot.frame = CGRect(x: 7.5, y: 7.5, width: 7, height: 7)
    pipDot.frame = CGRect(x: 2 + indent, y: mid - 2.5, width: 5, height: 5)
    CATransaction.commit()
    let doneSize = done.fittingSize
    done.frame = NSRect(x: right - 4 - doneSize.width, y: mid - doneSize.height / 2, width: doneSize.width, height: doneSize.height)
    var labelRight = right - slot
    if !chip.isHidden {
      let width = SidebarLiveViews.pill(chipPlate, chip, right: labelRight, height: 16, minWidth: 16, padding: 4, midY: mid)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      chipPlate.cornerRadius = 5
      CATransaction.commit()
      labelRight -= width + 4
    }
    let x = x0 + 16 + 5
    let frame = NSRect(x: x, y: mid - 9, width: max(0, labelRight - x), height: 18)
    label.frame = frame
    boldLabel.frame = frame
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let spec else { return }
    send("open", spec.folderId, spec.item.id, meta: mods.meta)
  }

  override func contextMenu() {
    guard let spec else { return }
    send("itemMenu", spec.folderId, spec.item.id)
  }

  override var hoverTarget: (kind: String, id: String)? {
    guard let spec, spec.completion == nil else { return nil }
    return ("live", SidebarLiveMetrics.itemKey(spec.folderId, spec.item.id))
  }
}

final class LiveStackRowView: LiveRowView {
  private let icon = SymbolView()
  private let label = SidebarLiveViews.label(12, weight: .medium)
  private let countPlate = CALayer()
  private let count = SidebarLiveViews.label(10, weight: .semibold)
  private let chevron = SymbolView()
  private var folderId = ""
  private var stackId = ""
  private var collapsed = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    countPlate.actions = SurfaceLayer.noActions
    body.layer?.addSublayer(countPlate)
    count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    for view in [icon, label, count, chevron] as [NSView] { body.addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func renderRow(_ context: SidebarContext) {
    guard case .stack(let folderId, let id, let repo, let total, let collapsed)? = row?.kind else { return }
    self.folderId = folderId
    stackId = id
    self.collapsed = collapsed
    let palette = context.palette
    icon.set("square.stack.3d.up", size: 11, color: palette.textSecondary)
    label.stringValue = "\(repo.split(separator: "/").dropFirst().first.map(String.init) ?? repo) stack"
    label.textColor = palette.textSecondary
    count.stringValue = "\(total)"
    count.textColor = palette.textTab
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    countPlate.backgroundColor = SidebarLiveColors.countPill(dark: palette.dark).cgColor
    CATransaction.commit()
    chevron.set(collapsed ? "chevron.right" : "chevron.down", size: 9, weight: .semibold, color: palette.textSecondary)
    setAccessibilityLabel(collapsed ? "Expand pull request stack" : "Collapse pull request stack")
  }

  override func layoutRow() {
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    let right = bounds.width - 8
    chevron.frame = NSRect(x: right - 12, y: mid - 6, width: 12, height: 12)
    let width = SidebarLiveViews.pill(countPlate, count, right: right - 12 - 4, height: 16, minWidth: 18, padding: 5, midY: mid)
    let x: CGFloat = 9 + 16 + 5
    let size = label.fittingSize
    label.frame = NSRect(x: x, y: mid - size.height / 2, width: max(0, right - 12 - 4 - width - x), height: size.height)
  }

  override func click(_ mods: SidebarClickMods, count: Int) { send("stack", folderId, stackId) }

  override func contextMenu() { send("stackMenu", folderId, stackId) }
}

final class LiveSectionView: LiveRowView {
  private let label = SidebarLiveViews.label(11, weight: .semibold)

  override var interactive: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func renderRow(_ context: SidebarContext) {
    guard case .section(let title)? = row?.kind else { return }
    label.stringValue = title
    label.textColor = context.palette.textSecondary
  }

  override func layoutRow() {
    let size = label.fittingSize
    label.frame = NSRect(x: 9, y: bounds.height - 2 - size.height, width: max(0, bounds.width - 9), height: size.height)
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) { contextMenu() }
  }

  override func mouseUp(with event: NSEvent) {}
}

final class LiveMoreRowView: LiveRowView {
  private let icon = SymbolView()
  private let label = SidebarLiveViews.label(12)
  private var folderId = ""
  private var section = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    for view in [icon, label] as [NSView] { body.addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func renderRow(_ context: SidebarContext) {
    guard case .more(let folderId, let section, let count)? = row?.kind else { return }
    self.folderId = folderId
    self.section = section
    icon.set("ellipsis", size: 11, color: context.palette.textSecondary)
    label.stringValue = "Show \(count) More"
    label.textColor = context.palette.textSecondary
  }

  override func layoutRow() {
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    let size = label.fittingSize
    label.frame = NSRect(x: 30, y: mid - size.height / 2, width: size.width, height: size.height)
  }

  override func click(_ mods: SidebarClickMods, count: Int) { send("more", folderId, section) }
}

final class LiveNoteRowView: LiveRowView {
  private let spinner = LiveSpinGlyph()
  private let icon = SymbolView()
  private let label = SidebarLiveViews.label(12, lines: 2)
  private var note: SidebarLiveNote?
  private var folderId = ""

  override var interactive: Bool { note?.action != nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    for view in [spinner, icon, label] as [NSView] { body.addSubview(view) }
    spinner.spinning = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func renderRow(_ context: SidebarContext) {
    guard case .note(let note)? = row?.kind, case .live(let key)? = item?.kind else { return }
    self.note = note
    folderId = String(key.dropFirst(3).prefix { $0 != "|" })
    let palette = context.palette
    spinner.isHidden = note.style != .loading
    spinner.set("arrow.triangle.2.circlepath", size: 10, weight: .regular, color: palette.textSecondary)
    icon.isHidden = note.style != .warning
    icon.set("exclamationmark.triangle.fill", size: 10, color: SidebarLiveColors(dark: palette.dark).pending)
    label.stringValue = note.text
    label.textColor = palette.textSecondary
  }

  override func layoutRow() {
    let mid = bounds.height / 2
    spinner.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    icon.frame = spinner.frame
    let x: CGFloat = spinner.isHidden && icon.isHidden ? 9 : 9 + 16 + 6
    let width = max(0, bounds.width - 6 - x)
    let height = min(label.sizeThatFits(NSSize(width: width, height: 100)).height, bounds.height)
    label.frame = NSRect(x: x, y: mid - height / 2, width: width, height: height)
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let action = note?.action else { return }
    send(action, folderId)
  }
}

final class LiveFooterRowView: LiveRowView {
  private let icon = SymbolView()
  private let label = SidebarLiveViews.label(12)
  private var folderId = ""
  private var open = false

  override var interactive: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    for view in [icon, label] as [NSView] { body.addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var hovered: Bool { didSet { if hovered != oldValue, !retired { SidebarLiveFeed.shared.setFooter(folderId, open: hovered) } } }

  override func renderRow(_ context: SidebarContext) {
    guard case .footer(let folderId, let count, let open)? = row?.kind else { return }
    self.folderId = folderId
    self.open = open
    icon.set("checkmark.circle", size: 11, color: context.palette.textSecondary)
    label.stringValue = "\(count) Completed"
    label.textColor = context.palette.textSecondary
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.cornerRadius = 8
    plate.backgroundColor = (open ? context.palette.rowHover : .clear).cgColor
    CATransaction.commit()
  }

  override func layoutRow() {
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    let size = label.fittingSize
    label.frame = NSRect(x: 30, y: mid - size.height / 2, width: size.width, height: size.height)
  }

  override func mouseUp(with event: NSEvent) { pressed = false }
}

final class LiveCompletedRowView: LiveRowView {
  private let glyph = SymbolView()
  private let label = FadeLabel(fontSize: 12.5)
  private var folderId = ""
  private var itemId = ""

  override var interactive: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    for view in [glyph, label] as [NSView] { body.addSubview(view) }
    body.alphaValue = 0.75
  }

  required init?(coder: NSCoder) { fatalError() }

  override var hovered: Bool { didSet { if hovered != oldValue, !retired { SidebarLiveFeed.shared.setFooter(folderId, open: hovered) } } }

  override func renderRow(_ context: SidebarContext) {
    guard case .completed(let folderId, let done)? = row?.kind else { return }
    body.alphaValue = 0.75
    self.folderId = folderId
    itemId = done.item.id
    let look = SidebarLiveColors(dark: context.palette.dark).completion(done.state)
    glyph.set(look.symbol, size: 12, color: look.color)
    label.text = done.item.title
    label.color = context.palette.textSecondary
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.cornerRadius = 8
    plate.backgroundColor = (pressed ? context.palette.pressed : .clear).cgColor
    CATransaction.commit()
  }

  override func layoutRow() {
    let mid = bounds.height / 2
    glyph.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    label.frame = NSRect(x: 30, y: mid - 8.5, width: max(0, bounds.width - 8 - 30), height: 17)
  }

  override func click(_ mods: SidebarClickMods, count: Int) { send("openCompleted", folderId, itemId) }
}
