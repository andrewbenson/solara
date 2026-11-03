import AppKit

extension NSView {
  func isHitBy(_ event: NSEvent) -> Bool {
    guard let frame = window?.contentView?.superview, let hit = frame.hitTest(event.locationInWindow) else { return true }
    return hit.isDescendant(of: self)
  }
}

final class ToolbarButtonView: NSView {
  var state: ToolbarButtonState { didSet { if state != oldValue { apply() } } }
  var palette: ToolbarPaletteState { didSet { if palette != oldValue { apply() } } }
  var onClick: (ToolbarClick) -> Void = { _ in }
  var forcedHover = false { didSet { apply() } }

  private let plate = CALayer()
  private let image = NSImageView()
  private let title = NSTextField(labelWithString: "")
  static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
  static let labelPadding: CGFloat = 10
  static let labelGap: CGFloat = 4
  private var badge: NSView?
  private var decoded: (uri: String, image: NSImage?)?
  private var hovered = false
  private var pressed = false
  private var longPressTimer: Timer?
  private var longPressFired = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  var box: CGFloat { CGFloat(state.box ?? 30) }

  var width: CGFloat {
    guard let label = state.label else { return box }
    let text = ceil((label as NSString).size(withAttributes: [.font: ToolbarButtonView.labelFont]).width)
    let glyph = state.icon.isEmpty ? 0 : CGFloat(state.size ?? 15) + ToolbarButtonView.labelGap
    return text + glyph + 2 * ToolbarButtonView.labelPadding
  }

  init(state: ToolbarButtonState, palette: ToolbarPaletteState) {
    self.state = state
    self.palette = palette
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(plate)
    image.imageScaling = .scaleNone
    addSubview(image)
    title.font = ToolbarButtonView.labelFont
    title.isHidden = true
    addSubview(title)
    apply()
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
    apply()
  }

  var enabled: Bool { state.enabled ?? true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    apply()
  }

  func recheckHover() {
    guard hovered, let window else { return }
    let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    if !inside {
      hovered = false
      apply()
    }
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard enabled || state.menu == true else { return nil }
    return super.hitTest(point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.mouseDown(with: event) }
    guard enabled else { return }
    pressed = true
    longPressFired = false
    apply()
    if state.longPress == true {
      longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.pressed else { return }
          self.longPressFired = true
          self.pressed = false
          self.apply()
          self.onClick(ToolbarClick(id: self.state.id, kind: .menu))
        }
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    longPressTimer?.invalidate()
    longPressTimer = nil
    let wasPressed = pressed
    pressed = false
    apply()
    guard wasPressed, !longPressFired, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: state.id, kind: .press, flags: event.modifierFlags))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard state.menu == true, enabled, isHitBy(event) else { return super.rightMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .menu))
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2, state.middle == true, enabled, isHitBy(event) else { return super.otherMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .middle, flags: event.modifierFlags))
  }

  override func layout() {
    super.layout()
    apply()
  }

  func apply() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let b = box
    let labeled = state.label != nil
    plate.frame = labeled ? bounds : CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    plate.cornerRadius = labeled ? bounds.height / 2 : CGFloat(state.radius ?? 7)
    let plain = state.plain == true
    let background: String? =
      plain || !enabled ? nil : pressed || state.active == true ? palette.pressed : (hovered || forcedHover) ? palette.hover : labeled ? palette.pill : nil
    plate.backgroundColor = toolbarColor(background)?.cgColor
    CATransaction.commit()
    let tint = toolbarColor(state.color) ?? toolbarColor(enabled ? palette.icon : palette.iconDisabled) ?? .labelColor
    title.isHidden = !labeled
    if let label = state.label {
      title.stringValue = label
      title.textColor = toolbarColor(palette.text) ?? .labelColor
      let size = title.fittingSize
      let glyph = state.icon.isEmpty ? 0 : CGFloat(state.size ?? 15)
      let config = NSImage.SymbolConfiguration(pointSize: glyph, weight: ToolbarButtonView.weight(state.weight))
      image.image = state.icon.isEmpty ? nil : NSImage(systemSymbolName: state.icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
      image.imageScaling = .scaleNone
      image.contentTintColor = tint
      image.alphaValue = 1
      image.frame = CGRect(x: ToolbarButtonView.labelPadding, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
      let left = ToolbarButtonView.labelPadding + (glyph > 0 ? glyph + ToolbarButtonView.labelGap : 0)
      title.frame = CGRect(x: left, y: ((bounds.height - size.height) / 2 * 2).rounded() / 2, width: max(0, bounds.width - left - ToolbarButtonView.labelPadding + 2), height: size.height)
      applyBadge()
      toolTip = state.tooltip
      setAccessibilityLabel(state.tooltip ?? label)
      setAccessibilityRole(.button)
      return
    }
    if let picture = picture() {
      let side = CGFloat(state.imageSize ?? 16)
      image.image = picture
      image.imageScaling = .scaleProportionallyUpOrDown
      image.contentTintColor = nil
      image.alphaValue = state.dimmed == true ? 0.45 : 1
      image.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    } else {
      let config = NSImage.SymbolConfiguration(pointSize: CGFloat(state.size ?? 15), weight: ToolbarButtonView.weight(state.weight))
      image.image = NSImage(systemSymbolName: state.icon, accessibilityDescription: state.tooltip)?.withSymbolConfiguration(config)
      image.imageScaling = .scaleNone
      image.contentTintColor = tint
      image.alphaValue = 1
      image.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    }
    applyBadge()
    toolTip = state.tooltip
    setAccessibilityLabel(state.tooltip)
    setAccessibilityRole(.button)
  }

  private func picture() -> NSImage? {
    guard let uri = state.image, !uri.isEmpty else { return nil }
    if let decoded, decoded.uri == uri { return decoded.image }
    let made = PromptBodyView.image(uri)
    decoded = (uri, made)
    return made
  }

  private func applyBadge() {
    guard let spec = state.badge, !spec.text.isEmpty else {
      badge?.removeFromSuperview()
      badge = nil
      return
    }
    let chip = badge ?? {
      let v = NSView()
      v.wantsLayer = true
      v.layer?.cornerRadius = 3
      let label = NSTextField(labelWithString: "")
      label.isSelectable = false
      v.addSubview(label)
      addSubview(v)
      badge = v
      return v
    }()
    guard let label = chip.subviews.first as? NSTextField else { return }
    let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    label.attributedStringValue = NSAttributedString(string: String(spec.text.prefix(4)), attributes: [.font: font, .foregroundColor: toolbarColor(spec.textColor) ?? .white])
    chip.layer?.backgroundColor = toolbarColor(spec.color)?.cgColor
    let scale = window?.backingScaleFactor ?? 2
    let textWidth = label.attributedStringValue.size().width
    let w = max(13, ceil((textWidth + 5) * scale) / scale)
    chip.frame = CGRect(x: bounds.width - 1 - w, y: bounds.height - 3 - 11, width: w, height: 11)
    let h = ceil(label.intrinsicContentSize.height)
    label.frame = CGRect(x: (w - textWidth) / 2 - 2, y: (11 - h) / 2, width: ceil(textWidth) + 5, height: h)
  }

  static func weight(_ name: String?) -> NSFont.Weight {
    switch name {
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "light": .light
    default: .regular
    }
  }
}
