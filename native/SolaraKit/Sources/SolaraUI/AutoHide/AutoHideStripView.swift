import AppKit
import QuartzCore

public enum AutoHideStripEvent: Equatable, Sendable {
  case reveal
  case peek(Bool)
}

public struct AutoHideStripStyle: Equatable, Sendable {
  public var card: CSSColor
  public var band: CSSColor?
  public var divider: CSSColor
  public var secondary: CSSColor
  public var host: String
  public var hasPage: Bool
  public var stripes: String?

  public init(card: CSSColor, band: CSSColor?, divider: CSSColor, secondary: CSSColor, host: String, hasPage: Bool, stripes: String? = nil) {
    self.card = card
    self.band = band
    self.divider = divider
    self.secondary = secondary
    self.host = host
    self.hasPage = hasPage
    self.stripes = stripes
  }
}

public struct AutoHideFrame: Equatable, Sendable {
  public var bar: Double
  public var fade: Double
  public var liveTop: Double
  public var interactive: Bool
  public var controlsOpacity: Double { ToolbarAutoHideCurves.controlsOpacity(fade: fade) }
  public var toolbarScale: Double { ToolbarAutoHideCurves.toolbarScale(bar: bar) }
  public var toolbarLift: Double { ToolbarAutoHideCurves.toolbarLift(bar: bar) }
}

@MainActor
public final class AutoHideStripView: NSView {
  public var onEvent: (AutoHideStripEvent) -> Void = { _ in }
  public var onFrame: (AutoHideFrame) -> Void = { _ in }
  public var onMotion: (Bool) -> Void = { _ in }
  public var frameSurface = false {
    didSet { if frameSurface != oldValue { applySurface(animated: false) } }
  }

  private let cardCorners = CALayer()
  private let backdrop = CALayer()
  private let band = CALayer()
  private let stripes = CALayer()
  private var bandColor: CGColor?
  private var stripesUri: String?
  private var labelInk: CGFloat = 1
  private let divider = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var style: AutoHideStripStyle?
  private var mode = ToolbarAutoHideMode.shown
  private var shownTop: Double = Double(ToolbarAutoHideMetrics.toolbarHeight)
  private var page = RNTween.resting(0)
  private var bar = RNTween.resting(0)
  private var fade = RNTween.resting(0)
  private var laid: Double = 0
  private var moved = false
  private var configured = false
  private var link: CADisplayLink?
  private var stallTimer: Timer?
  private var lastTick: CFTimeInterval = 0
  private var peekTimer: Timer?
  private var tracking: NSTrackingArea?
  private var pinnedReduceMotion: Bool?
  public var reduceMotion: Bool {
    get { pinnedReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    set { pinnedReduceMotion = newValue }
  }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [cardCorners, backdrop, band, stripes, divider] { l.actions = SurfaceLayer.noActions }
    cardCorners.masksToBounds = true
    cardCorners.cornerRadius = ShellMetrics.cardRadius
    backdrop.masksToBounds = true
    backdrop.anchorPoint = .zero
    backdrop.addSublayer(band)
    stripes.anchorPoint = .zero
    stripes.contentsGravity = .topLeft
    stripes.isHidden = true
    backdrop.addSublayer(stripes)
    cardCorners.addSublayer(backdrop)
    layer?.addSublayer(cardCorners)
    layer?.addSublayer(divider)
    label.font = .systemFont(ofSize: ToolbarAutoHideMetrics.labelSize, weight: .medium)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingHead
    label.alphaValue = 0
    label.setAccessibilityRole(.button)
    label.setAccessibilityLabel("Show Toolbar")
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var restingTop: Double {
    ToolbarAutoHideCurves.liveTop(laid: laid, page: page.to, collapsed: mode != .shown, shownTop: shownTop)
  }

  public var bandShown: CGColor? { bandColor }
  public var stripesShown: Bool { !stripes.isHidden }
  public var bandFrame: CGRect { backdrop.frame }

  public func set(style next: AutoHideStripStyle, mode nextMode: ToolbarAutoHideMode, shownTop top: Double) {
    let first = style == nil
    style = next
    shownTop = top
    applySurface(animated: !first)
    label.stringValue = next.host
    label.textColor = next.secondary.ns.withAlphaComponent(1)
    labelInk = next.secondary.ns.alphaComponent
    if !configured {
      configured = true
      jump(to: nextMode)
    } else if nextMode != mode {
      transition(to: nextMode)
    }
    needsLayout = true
  }

  private func applySurface(animated: Bool) {
    guard let style else { return }
    PrimitiveMotion.setInstantly {
      backdrop.backgroundColor = frameSurface ? nil : style.card.cg
      divider.backgroundColor = frameSurface ? nil : style.divider.cg
      divider.isHidden = frameSurface || !style.hasPage
    }
    if frameSurface {
      band.removeAnimation(forKey: "backgroundColor")
      applyBand(nil, animated: false)
      PrimitiveMotion.setInstantly { band.backgroundColor = nil }
      applyStripes(nil)
    } else {
      applyBand(style.band?.cg, animated: animated)
      applyStripes(style.stripes)
    }
  }

  private func applyBand(_ color: CGColor?, animated: Bool) {
    guard color != bandColor else { return }
    let from = bandColor ?? color?.copy(alpha: 0)
    let to = color ?? bandColor?.copy(alpha: 0)
    bandColor = color
    PrimitiveMotion.setInstantly { band.backgroundColor = to }
    guard animated, let from, let to else { return }
    let animation = CABasicAnimation(keyPath: "backgroundColor")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = ToolbarAutoHideMetrics.bandEaseDuration
    animation.timingFunction = ToolbarView.bandEase
    band.add(animation, forKey: "backgroundColor")
  }

  private func applyStripes(_ uri: String?) {
    guard uri != stripesUri else { return }
    stripesUri = uri
    let image = uri.flatMap(ToolbarView.stripesImage)
    PrimitiveMotion.setInstantly {
      stripes.contents = image
      stripes.contentsScale = window?.backingScaleFactor ?? 2
      stripes.isHidden = image == nil
    }
  }

  public var showsToolTip: Bool { label.toolTip != nil }

  private func setMode(_ next: ToolbarAutoHideMode) {
    mode = next
    label.toolTip = next == .collapsed ? "Show Toolbar" : nil
  }

  private func jump(to next: ToolbarAutoHideMode) {
    setMode(next)
    moved = next != .shown
    let collapsed = next != .shown
    page = .resting(collapsed ? 1 : 0)
    bar = .resting(next == .collapsed ? 1 : 0)
    fade = .resting(next == .collapsed ? 1 : 0)
    laid = collapsed ? 1 : 0
    tick()
  }

  private func transition(to next: ToolbarAutoHideMode) {
    let now = CACurrentMediaTime()
    let current = (page: page.value(at: now), bar: bar.value(at: now), fade: fade.value(at: now))
    defer { setMode(next) }
    if next != .shown { moved = true }
    guard let t = ToolbarAutoHideTransition.between(mode, next, current: current, at: now, reduceMotion: reduceMotion) else { return }
    page = t.page
    bar = t.bar
    fade = t.fade
    laid = t.laid
    onMotion(true)
    startLink()
    tick()
  }

  private func startLink() {
    guard link == nil else { return }
    let made = displayLink(target: self, selector: #selector(step))
    made.add(to: .main, forMode: .common)
    link = made
    let timer = Timer(timeInterval: DockMotion.stallCheck, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      MainActor.assumeIsolated { self.tickIfStalled() }
    }
    RunLoop.main.add(timer, forMode: .common)
    stallTimer = timer
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
    stallTimer?.invalidate()
    stallTimer = nil
  }

  @objc private func step() { tick() }

  func tickIfStalled() {
    guard link != nil, CACurrentMediaTime() - lastTick >= DockMotion.stalledFrame else { return }
    tick()
  }

  private func tick() {
    let now = CACurrentMediaTime()
    lastTick = now
    let b = bar.value(at: now)
    let f = fade.value(at: now)
    let p = page.value(at: now)
    let top = ToolbarAutoHideCurves.liveTop(laid: laid, page: p, collapsed: mode != .shown, shownTop: shownTop)
    apply(bar: b, fade: f)
    onFrame(AutoHideFrame(bar: b, fade: f, liveTop: top, interactive: mode != .collapsed))
    if page.finished(at: now), bar.finished(at: now), fade.finished(at: now) {
      stopLink()
      onMotion(false)
    }
  }

  private func apply(bar b: Double, fade f: Double) {
    let h = Double(ToolbarAutoHideMetrics.toolbarHeight)
    PrimitiveMotion.setInstantly {
      cardCorners.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h + ShellMetrics.cardRadius)
      backdrop.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: h)
      backdrop.position = .zero
      band.frame = backdrop.bounds
      stripes.frame = CGRect(x: 0, y: 0, width: 2560, height: 50)
      if moved {
        let scale = ToolbarAutoHideCurves.bandScale(bar: b)
        var t = CATransform3DMakeTranslation(0, ToolbarAutoHideCurves.bandLift(bar: b), 0)
        t = CATransform3DTranslate(t, 0, h / 2, 0)
        t = CATransform3DScale(t, 1, scale, 1)
        backdrop.transform = CATransform3DTranslate(t, 0, -h / 2, 0)
        divider.frame = CGRect(x: 0, y: h - 1 + ToolbarAutoHideCurves.dividerLift(bar: b), width: bounds.width, height: 1)
      } else {
        backdrop.transform = CATransform3DIdentity
        divider.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
      }
    }
    label.alphaValue = moved ? ToolbarAutoHideCurves.labelOpacity(fade: f) * labelInk : 0
  }

  public override func layout() {
    super.layout()
    let strip = ToolbarAutoHideMetrics.stripHeight
    label.frame = CGRect(x: ToolbarAutoHideMetrics.labelPadding, y: (strip - 14) / 2, width: max(0, bounds.width - 2 * ToolbarAutoHideMetrics.labelPadding), height: 14)
    let now = CACurrentMediaTime()
    apply(bar: bar.value(at: now), fade: fade.value(at: now))
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let made = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
    addTrackingArea(made)
    tracking = made
  }

  private func inStrip(_ event: NSEvent) -> Bool {
    convert(event.locationInWindow, from: nil).y < ToolbarAutoHideMetrics.stripHeight
  }

  public override func mouseMoved(with event: NSEvent) {
    if mode == .collapsed {
      if inStrip(event) { peekLater(true, ToolbarAutoHideMetrics.peekDelay) } else { peekTimer?.invalidate() }
    }
  }

  public override func mouseEntered(with event: NSEvent) {
    if mode == .peek { peekTimer?.invalidate() } else { mouseMoved(with: event) }
  }

  public override func mouseExited(with event: NSEvent) {
    if mode == .peek { peekLater(false, ToolbarAutoHideMetrics.unpeekDelay) } else if mode == .collapsed { peekTimer?.invalidate() }
  }

  private func peekLater(_ on: Bool, _ delay: TimeInterval) {
    peekTimer?.invalidate()
    peekTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.onEvent(.peek(on)) }
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard mode == .collapsed else { return nil }
    let local = convert(point, from: superview)
    return local.y < ToolbarAutoHideMetrics.stripHeight && local.y >= 0 ? self : nil
  }

  public override func mouseUp(with event: NSEvent) {
    guard mode == .collapsed, inStrip(event) else { return }
    peekTimer?.invalidate()
    onEvent(.reveal)
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil {
      stopLink()
      peekTimer?.invalidate()
    }
  }
}
