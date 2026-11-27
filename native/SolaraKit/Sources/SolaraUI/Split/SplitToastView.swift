import AppKit

@MainActor
final class SplitToastView: NSView {
  static let bottom: CGFloat = 22
  static let noticeLift: CGFloat = 56
  static let maxWidth: CGFloat = 420
  static let hideDuration: CFTimeInterval = 0.22
  static let spring = SpringParams.rn(speed: 18, bounciness: 6)

  var theme = SplitChromeTheme.fallback { didSet { if theme != oldValue { paint() } } }
  var onHidden: ((Int) -> Void)?
  var onAction: ((Int) -> Void)?
  private(set) var spec: SplitToastSpec?
  private var appear: (spring: SpringTrack?, tween: RNTween) = (nil, .resting(0))
  private var hideTimer: Timer?
  private var link: CADisplayLink?
  private var hiding: Bool?
  private let card = NSView()
  private let effect = NSVisualEffectView()
  private let glyph = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let message = NSTextField(labelWithString: "")
  private let button = SplitToastButton()
  private(set) var appearValue: Double = 0

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    card.wantsLayer = true
    card.layer?.cornerRadius = 14
    card.layer?.cornerCurve = .continuous
    card.layer?.borderWidth = 0.5
    card.shadow = NSShadow()
    effect.material = .hudWindow
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 14
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    glyph.imageScaling = .scaleProportionallyDown
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    message.font = .systemFont(ofSize: 12)
    for field in [title, message] {
      field.lineBreakMode = .byTruncatingTail
      field.maximumNumberOfLines = 1
      field.cell?.truncatesLastVisibleLine = true
    }
    button.onPress = { [weak self] in self?.pressAction() }
    for view in [effect, glyph, title, message, button] { card.addSubview(view) }
    addSubview(card)
    card.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard spec?.action != nil, !card.isHidden else { return nil }
    let local = convert(point, from: superview)
    return button.frame.contains(card.convert(local, from: self)) ? button : nil
  }

  func stop() {
    hideTimer?.invalidate()
    hideTimer = nil
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(link)
    #endif
    link?.invalidate()
    link = nil
    spec = nil
    hiding = nil
    appear = (nil, .resting(0))
    appearValue = 0
    card.isHidden = true
    onHidden = nil
    onAction = nil
  }

  func show(_ next: SplitToastSpec?) {
    let now = CACurrentMediaTime()
    guard let next else {
      if spec != nil, hiding == nil { hide(now, report: false) }
      return
    }
    guard next != spec || hiding != nil else { return }
    let fresh = next.id != spec?.id || hiding != nil
    spec = next
    hiding = nil
    fill(next)
    card.isHidden = false
    if fresh {
      appear = (SpringTrack(Self.spring, from: 0, to: 1, start: now), .resting(1))
      hideTimer?.invalidate()
      hideTimer = nil
      if !next.sticky {
        let id = next.id
        let timer = Timer(timeInterval: next.hideAfter, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.spec?.id == id else { return }
            self.hide(CACurrentMediaTime(), report: true)
          }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
      }
    }
    needsLayout = true
    run()
  }

  private func hide(_ now: CFTimeInterval, report: Bool) {
    guard spec != nil else { return }
    hideTimer?.invalidate()
    hideTimer = nil
    hiding = report
    appear = (nil, RNTween(from: value(now), to: 0, start: now, duration: Self.hideDuration, easing: .inQuad))
    run()
  }

  private func pressAction() {
    guard let spec else { return }
    onAction?(spec.id)
    hideTimer?.invalidate()
    hideTimer = nil
    self.spec = nil
    hiding = nil
    card.isHidden = true
    appear = (nil, .resting(0))
  }

  private func value(_ now: CFTimeInterval) -> Double { appear.spring?.value(at: now) ?? appear.tween.value(at: now) }

  private func finished(_ now: CFTimeInterval) -> Bool {
    if let spring = appear.spring { return now - spring.start >= spring.duration }
    return appear.tween.finished(at: now)
  }

  private func run() {
    tick()
    guard link == nil, !finished(CACurrentMediaTime()) else { return }
    let made = displayLink(target: self, selector: #selector(step(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(made)
    #endif
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func step(_ link: CADisplayLink) { tick() }

  private func tick() {
    let now = CACurrentMediaTime()
    appearValue = value(now)
    let a = CGFloat(appearValue)
    let center = CGPoint(x: card.frame.midX, y: card.frame.midY)
    var t = CATransform3DMakeTranslation(center.x, center.y + 10 * (1 - a), 0)
    t = CATransform3DScale(t, 0.96 + 0.04 * a, 0.96 + 0.04 * a, 1)
    t = CATransform3DTranslate(t, -center.x, -center.y, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.sublayerTransform = t
    card.alphaValue = max(0, min(1, a))
    CATransaction.commit()
    guard finished(now) else { return }
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(link)
    #endif
    link?.invalidate()
    link = nil
    if let hiding {
      let id = spec?.id
      self.hiding = nil
      spec = nil
      card.isHidden = true
      if hiding, let id { onHidden?(id) }
    }
  }

  private func fill(_ spec: SplitToastSpec) {
    glyph.image = NSImage(systemSymbolName: spec.icon ?? "rectangle.split.3x1", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    title.stringValue = spec.title
    message.stringValue = spec.message ?? ""
    message.isHidden = spec.message == nil
    button.title = spec.action ?? ""
    button.isHidden = spec.action == nil
    paint()
  }

  private func paint() {
    let dark = theme.dark
    card.layer?.backgroundColor = (dark ? NSColor(srgbRed: 44 / 255, green: 42 / 255, blue: 43 / 255, alpha: 0.9) : NSColor(white: 1, alpha: 0.92)).cgColor
    card.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.1)).cgColor
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.14)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    card.shadow = shadow
    glyph.contentTintColor = theme.icon
    title.textColor = theme.textPrimary
    message.textColor = theme.textSecondary
    button.theme = theme
  }

  override func layout() {
    super.layout()
    guard spec != nil else { return }
    let padX: CGFloat = 16
    let padY: CGFloat = 10
    let gap: CGFloat = 10
    let icon = CGSize(width: 20, height: 20)
    let buttonSize = button.isHidden ? .zero : button.fittingSize
    let fixed = padX * 2 + icon.width + gap + (button.isHidden ? 0 : gap + buttonSize.width)
    let textRoom = max(0, min(Self.maxWidth, bounds.width) - fixed)
    title.sizeToFit()
    message.sizeToFit()
    let textWidth = min(textRoom, max(title.frame.width, message.isHidden ? 0 : message.frame.width))
    let textHeight = title.frame.height + (message.isHidden ? 0 : 1 + message.frame.height)
    let content = max(icon.height, textHeight, buttonSize.height)
    let size = CGSize(width: fixed + textWidth, height: content + padY * 2)
    card.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - Self.bottom - size.height, width: size.width, height: size.height)
    effect.frame = card.bounds
    var x = padX
    glyph.frame = CGRect(x: x, y: (size.height - icon.height) / 2, width: icon.width, height: icon.height)
    x += icon.width + gap
    let textTop = (size.height - textHeight) / 2
    title.frame = CGRect(x: x, y: textTop, width: textWidth, height: title.frame.height)
    message.frame = CGRect(x: x, y: title.frame.maxY + 1, width: textWidth, height: message.frame.height)
    x += textWidth + gap
    button.frame = CGRect(x: x, y: (size.height - buttonSize.height) / 2, width: buttonSize.width, height: buttonSize.height)
    tick()
  }

  var cardFrame: CGRect { card.frame }
}

@MainActor
final class SplitToastButton: NSView {
  var title = "" { didSet { label.stringValue = title; invalidateIntrinsicContentSize() } }
  var theme = SplitChromeTheme.fallback { didSet { paint() } }
  var onPress: (() -> Void)?
  private let label = NSTextField(labelWithString: "")
  private var hovered = false
  private var pressed = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 12, weight: .medium)
    addSubview(label)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize {
    label.sizeToFit()
    return NSSize(width: ceil(label.frame.width) + 20, height: 24)
  }

  override func layout() {
    super.layout()
    label.sizeToFit()
    label.frame.origin = CGPoint(x: 10, y: ((bounds.height - label.frame.height) / 2).rounded())
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
  override func mouseExited(with event: NSEvent) { hovered = false; paint() }

  override func mouseDown(with event: NSEvent) {
    pressed = true
    paint()
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    paint()
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  override func accessibilityLabel() -> String? { title }

  private func paint() {
    layer?.backgroundColor = (pressed ? theme.toolbarPressed : hovered ? theme.toolbarHover : theme.urlPill).cgColor
    label.textColor = theme.textPrimary
  }
}
