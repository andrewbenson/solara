import AppKit

final class ToolbarUrlFieldView: NSView {
  static let height: CGFloat = 30
  static let badgeLeft: CGFloat = 1
  static let badgeGap: CGFloat = 5.5
  static let textLeft: CGFloat = 8
  static let labelInset: CGFloat = 2
  static let labelRaise: CGFloat = 1
  static let diaTextShift = CGPoint(x: 1.5, y: 0.5)
  static let sidebarTextLeft: CGFloat = 10
  static let accessoryGap: CGFloat = 2
  static let fadeWidth: CGFloat = 14

  var onClick: (ToolbarClick) -> Void = { _ in }
  private(set) var state: ToolbarUrlState?
  private var palette: ToolbarPaletteState?
  private let pill = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var lock: NotSecureBadgeView?
  private var hoverButtons: [ToolbarButtonView] = []
  private var trailing: [ToolbarButtonView] = []
  private var hovered = false
  private var tracking: NSTrackingArea?
  private var pressedOnText = false
  private var dividers: [CALayer] = []
  private var editor: DeveloperUrlField?
  private var handledEditRequest = 0
  private(set) var look: SidebarFieldLook?
  private var accessory: [ToolbarButtonView] = []
  private let progress = CALayer()
  private var shownProgress: Double?
  private let fade = CAGradientLayer()

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    pill.cornerRadius = 8
    layer?.addSublayer(pill)
    progress.anchorPoint = .zero
    progress.isHidden = true
    pill.addSublayer(progress)
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    label.isSelectable = false
    addSubview(label)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
    applyHover()
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(
    _ next: ToolbarUrlState, palette nextPalette: ToolbarPaletteState, look nextLook: SidebarFieldLook? = nil, accessory nextAccessory: [ToolbarButtonState] = [],
    progress nextProgress: Double? = nil, accent: String? = nil
  ) {
    let changed = next != state || nextPalette != palette || nextLook != look || nextAccessory != accessory.map(\.state)
    state = next
    palette = nextPalette
    look = nextLook
    applyProgress(nextProgress, color: toolbarColor(accent))
    guard changed else { return }
    accessory = sync(accessory, nextAccessory, nextPalette)
    if next.insecure != nil {
      if lock == nil {
        let made = NotSecureBadgeView()
        made.onClick = { [weak self] click in self?.onClick(click) }
        addSubview(made)
        lock = made
      }
    } else {
      lock?.removeFromSuperview()
      lock = nil
    }
    hoverButtons = sync(hoverButtons, next.hoverButtons, nextPalette)
    trailing = sync(trailing, next.trailing, nextPalette)
    syncEditor(next, nextPalette)
    applyHover()
    needsLayout = true
  }

  private func syncEditor(_ next: ToolbarUrlState, _ palette: ToolbarPaletteState) {
    guard let dev = next.developer, dev.editing else {
      editor?.removeFromSuperview()
      editor = nil
      return
    }
    let field = editor ?? {
      let made = DeveloperUrlField()
      made.onFinish = { [weak self] kind, text in self?.onClick(ToolbarClick(id: "urlEdit", kind: kind, text: text)) }
      made.onFocused = { [weak self] in self?.onClick(ToolbarClick(id: "urlEdit", kind: .focus)) }
      addSubview(made)
      editor = made
      return made
    }()
    field.textColor = toolbarColor(palette.text)
    if dev.request != handledEditRequest {
      handledEditRequest = dev.request
      if let editing = field.currentEditor() as? NSTextView { editing.string = dev.text } else { field.stringValue = dev.text }
      field.finished = false
      DispatchQueue.main.async { [weak self, weak field] in
        guard let self, let field, let window = field.window else { return }
        self.layoutSubtreeIfNeeded()
        if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
        field.onFocused()
      }
    }
  }

  var editorView: NSView? { editor }

  private func sync(_ views: [ToolbarButtonView], _ specs: [ToolbarButtonState], _ palette: ToolbarPaletteState) -> [ToolbarButtonView] {
    var out: [ToolbarButtonView] = []
    for (i, spec) in specs.enumerated() {
      if i < views.count, views[i].state.id == spec.id {
        views[i].state = spec
        views[i].palette = palette
        out.append(views[i])
      } else {
        let made = ToolbarButtonView(state: spec, palette: palette)
        made.onClick = { [weak self, weak made] click in
          guard let self else { return }
          if click.kind == .press, let made, let info = made.state.info {
            ToolbarInfoPopover.show(info, relativeTo: made) { [weak self] in self?.onClick(ToolbarClick(id: info.actionId, kind: .press)) }
            return
          }
          self.onClick(click)
        }
        addSubview(made)
        out.append(made)
      }
    }
    for v in views where !out.contains(where: { $0 === v }) { v.removeFromSuperview() }
    return out
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    applyHover()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    applyHover()
  }

  var shownHover: Bool { hovered || state?.pinned == true }

  private func applyHover() {
    guard let state, let palette else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let look {
      pill.backgroundColor = toolbarColor(shownHover ? look.hover : look.resting)?.cgColor
      pill.borderColor = toolbarColor(look.stroke)?.cgColor
      pill.borderWidth = border
      pill.cornerRadius = SidebarHeaderMetrics.fieldRadius
      pill.masksToBounds = true
    } else {
      pill.backgroundColor = shownHover ? toolbarColor(palette.pill)?.cgColor : nil
    }
    CATransaction.commit()
    for b in hoverButtons {
      b.alphaValue = shownHover ? 1 : 0
      b.isHidden = false
    }
    if let dev = state.developer {
      label.isHidden = dev.editing
      label.lineBreakMode = .byTruncatingTail
      label.attributedStringValue = NSAttributedString(
        string: dev.text, attributes: [.font: NSFont(name: ".AppleSystemUIFontMonospaced-Regular", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: toolbarColor(palette.text) ?? .labelColor])
      return
    }
    label.isHidden = false
    label.cell?.truncatesLastVisibleLine = look == nil
    label.cell?.isScrollable = look != nil
    defer { applyFade() }
    if let look, state.host.isEmpty {
      label.lineBreakMode = .byClipping
      label.attributedStringValue = NSAttributedString(string: look.prompt, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: toolbarColor(look.placeholder) ?? .placeholderTextColor])
      return
    }
    let trail = shownHover ? state.hoverTrail : state.restTrail
    let notSecure = state.insecure != nil
    let hostColor = notSecure ? NotSecureBadgeView.red : toolbarColor(palette.urlHost ?? palette.text) ?? .labelColor
    let pathColor = notSecure ? NotSecureBadgeView.red : toolbarColor(palette.urlPath ?? palette.secondary) ?? .secondaryLabelColor
    let hostOnly = hostOverflows
    label.lineBreakMode = hostOnly ? .byTruncatingHead : look != nil ? .byClipping : .byTruncatingTail
    let headFirst = NSMutableParagraphStyle()
    headFirst.lineBreakMode = .byTruncatingHead
    var hostAttributes: [NSAttributedString.Key: Any] = [.font: hostFont, .foregroundColor: hostColor]
    if hostOnly { hostAttributes[.paragraphStyle] = headFirst }
    let text = NSMutableAttributedString(string: state.host, attributes: hostAttributes)
    if !trail.isEmpty && !hostOnly {
      text.append(NSAttributedString(string: trail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: pathColor]))
    }
    label.attributedStringValue = text
  }

  private var hostOverflows: Bool {
    guard let state, state.developer == nil, label.frame.width > 0 else { return false }
    let hostWidth = (state.host as NSString).size(withAttributes: [.font: hostFont]).width
    return ceil(hostWidth) > label.frame.width - 2 * ToolbarUrlFieldView.labelInset
  }

  private var border: CGFloat { look != nil ? 2 / (window?.backingScaleFactor ?? 2) : 0 }

  private var hostFont: NSFont { NSFont.systemFont(ofSize: 13, weight: look != nil ? .medium : .regular) }

  private func applyFade() {
    let width = label.frame.width
    let overflows = look != nil && label.lineBreakMode == .byClipping && ceil(label.attributedStringValue.size().width) > width - 2 * ToolbarUrlFieldView.labelInset
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if overflows, width > 0 {
      label.wantsLayer = true
      let edge = ToolbarUrlFieldView.fadeWidth
      fade.frame = label.bounds
      fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
      fade.locations = [0, NSNumber(value: Double(max(0, (width - ToolbarUrlFieldView.labelInset - edge) / width))), NSNumber(value: Double((width - ToolbarUrlFieldView.labelInset) / width))]
      label.layer?.mask = fade
    } else {
      label.layer?.mask = nil
    }
    CATransaction.commit()
  }

  var accessoryAnchors: [String: CGRect] {
    var out: [String: CGRect] = [:]
    for b in accessory { if let slot = b.state.anchor { out[slot] = b.frame } }
    return out
  }

  private func applyProgress(_ value: Double?, color: NSColor?) {
    guard let value, look != nil else {
      progress.isHidden = true
      shownProgress = nil
      return
    }
    let to = max(value, 0.08)
    let width = bounds.width * to
    let fromWidth = shownProgress.map { bounds.width * max($0, 0.08) } ?? width
    shownProgress = value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progress.isHidden = false
    progress.backgroundColor = color?.cgColor
    progress.opacity = 0.85
    progress.bounds = CGRect(x: 0, y: 0, width: width, height: 1.5)
    progress.position = CGPoint(x: 0, y: bounds.height - 1.5)
    CATransaction.commit()
    guard fromWidth != width else { return }
    let animation = CABasicAnimation(keyPath: "bounds.size.width")
    animation.fromValue = fromWidth
    animation.toValue = width
    animation.duration = 0.2
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    progress.add(animation, forKey: "width")
  }

  func sample() -> [String: Any] {
    let rect = { (r: CGRect) in [r.minX, r.minY, r.width, r.height].map { Double($0) } }
    var out: [String: Any] = ["label": rect(label.frame), "text": label.stringValue, "hover": shownHover, "faded": label.layer?.mask != nil]
    out["buttons"] = (hoverButtons + trailing + accessory).filter { !$0.isHidden && $0.alphaValue > 0 }.map { ["id": $0.state.id, "frame": rect($0.frame)] as [String: Any] }
    if let lock { out["lock"] = rect(lock.frame) }
    if !progress.isHidden { out["progress"] = rect(progress.frame) }
    return out
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    if let editor, editor.frame.contains(local), let hit = editor.hitTest(convert(local, to: editor.superview)) { return hit }
    for b in hoverButtons + trailing + accessory + [lock].compactMap({ $0 }) where b.frame.contains(local) {
      if !shownHover && hoverButtons.contains(where: { $0 === b }) { continue }
      if let hit = b.hitTest(convert(local, to: b.superview)) { return hit }
    }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.mouseDown(with: event) }
    pressedOnText = true
  }

  override func mouseUp(with event: NSEvent) {
    defer { pressedOnText = false }
    guard pressedOnText, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: "url", kind: .press, flags: event.modifierFlags))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.rightMouseDown(with: event) }
    onClick(ToolbarClick(id: "url", kind: .menu))
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pill.frame = bounds
    if let shownProgress {
      progress.bounds.size.width = bounds.width * max(shownProgress, 0.08)
      progress.position = CGPoint(x: 0, y: h - 1.5)
    }
    CATransaction.commit()
    var x: CGFloat = 0
    if let lock {
      let size = NotSecureBadgeView.size
      lock.frame = CGRect(x: ToolbarUrlFieldView.badgeLeft, y: (h - size) / 2, width: size, height: size)
      x = ToolbarUrlFieldView.badgeLeft + size + ToolbarUrlFieldView.badgeGap
    } else {
      x = look != nil ? ToolbarUrlFieldView.sidebarTextLeft + border : ToolbarUrlFieldView.textLeft
    }
    var right = bounds.width - 3 - border
    for (i, b) in accessory.reversed().enumerated() {
      if i > 0 { right -= ToolbarUrlFieldView.accessoryGap }
      right -= b.width
      b.frame = backingAlignedRect(CGRect(x: right, y: (h - b.box) / 2, width: b.width, height: b.box), options: .alignAllEdgesNearest)
    }
    var usedDividers = 0
    let scale = window?.backingScaleFactor ?? 2
    for b in (hoverButtons + trailing).reversed() {
      if b.state.id.hasPrefix("divider") {
        b.isHidden = true
        if usedDividers == dividers.count {
          let l = CALayer()
          layer?.addSublayer(l)
          dividers.append(l)
        }
        let line = dividers[usedDividers]
        usedDividers += 1
        right -= 5
        let lw = 2 / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.isHidden = false
        line.backgroundColor = toolbarColor(palette?.divider)?.cgColor
        line.frame = CGRect(x: right - lw, y: (h - 16) / 2, width: lw, height: 16)
        CATransaction.commit()
        right -= lw + 5
        continue
      }
      let w = b.box
      right -= w
      b.frame = backingAlignedRect(CGRect(x: right, y: (h - w) / 2, width: w, height: w), options: .alignAllEdgesNearest)
    }
    for (i, d) in dividers.enumerated() where i >= usedDividers { d.isHidden = true }
    let size = label.intrinsicContentSize
    let textRight = right
    let developer = state?.developer != nil
    let shift = developer || look != nil ? .zero : ToolbarUrlFieldView.diaTextShift
    let prompt = look != nil && state?.host.isEmpty == true
    let sidebarY = (h - size.height) / 2 - (prompt ? 0 : 0.5)
    label.frame = CGRect(
      x: x - ToolbarUrlFieldView.labelInset + shift.x,
      y: developer ? (((h - size.height) / 2 - 0.5) * 2).rounded() / 2 : look != nil ? sidebarY : ((h - size.height) / 2 - ToolbarUrlFieldView.labelRaise).rounded() + shift.y,
      width: max(0, textRight - x - shift.x + ToolbarUrlFieldView.labelInset),
      height: size.height)
    if let editor { editor.frame = label.frame.offsetBy(dx: 0, dy: 1) }
    if !developer && (label.lineBreakMode == .byTruncatingHead) != hostOverflows { applyHover() } else { applyFade() }
  }
}

final class DeveloperUrlField: NSTextField, NSTextFieldDelegate {
  var onFinish: (ToolbarClick.Kind, String) -> Void = { _, _ in }
  var onFocused: () -> Void = {}
  var finished = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    isBezeled = false
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    usesSingleLineMode = true
    cell?.wraps = false
    cell?.isScrollable = true
    font = NSFont(name: ".AppleSystemUIFontMonospaced-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    delegate = self
    isAutomaticTextCompletionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { finished = false }
    return became
  }

  private var resizing = false

  override func setFrameSize(_ newSize: NSSize) {
    guard newSize != frame.size, let editor = currentEditor() as? NSTextView else { return super.setFrameSize(newSize) }
    let selection = editor.selectedRanges
    resizing = true
    super.setFrameSize(newSize)
    resizing = false
    if let resumed = currentEditor() as? NSTextView { resumed.selectedRanges = selection }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if textView.hasMarkedText() { return false }
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      finish(.cancel)
      return true
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      finish(.submit)
      return true
    default:
      return false
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    if !finished && !resizing {
      finished = true
      onFinish(.blur, stringValue)
    }
  }

  private func finish(_ kind: ToolbarClick.Kind) {
    guard !finished else { return }
    finished = true
    onFinish(kind, stringValue)
  }
}

final class NotSecureBadgeView: NSView {
  static let size: CGFloat = 28
  static let radius: CGFloat = 7
  static let glyphSize: CGFloat = 13
  static let red = NSColor(srgbRed: 235 / 255, green: 89 / 255, blue: 84 / 255, alpha: 1)

  var onClick: (ToolbarClick) -> Void = { _ in }
  private let glyph = NSImageView()
  private var pressed = false

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NotSecureBadgeView.red.cgColor
    layer?.cornerRadius = NotSecureBadgeView.radius
    layer?.cornerCurve = .continuous
    toolTip = "Connection is not secure"
    let config = NSImage.SymbolConfiguration(pointSize: NotSecureBadgeView.glyphSize, weight: .semibold)
    glyph.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Not secure")?.withSymbolConfiguration(config)
    glyph.contentTintColor = .white
    glyph.imageScaling = .scaleNone
    addSubview(glyph)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Connection is not secure")
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    glyph.frame = bounds
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.mouseDown(with: event) }
    pressed = true
    alphaValue = 0.8
  }

  override func mouseUp(with event: NSEvent) {
    let wasPressed = pressed
    pressed = false
    alphaValue = 1
    guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: "lock", kind: .press, flags: event.modifierFlags))
  }
}
