import AppKit
import QuartzCore

public struct SheetStyle: Equatable, Sendable {
  public var dark: Bool
  public var panel: String
  public var panelBorder: String
  public var panelShadowOpacity: Double

  public init(dark: Bool, panel: String, panelBorder: String, panelShadowOpacity: Double) {
    self.dark = dark
    self.panel = panel
    self.panelBorder = panelBorder
    self.panelShadowOpacity = panelShadowOpacity
  }
}

@MainActor
public final class SheetView: NSView {
  public var busy = false
  public var onDismiss: () -> Void = {}
  public var onSubmit: () -> Void = {}
  public private(set) var cardFrame: CGRect = .zero
  private let scrim = CALayer()
  private let card = SheetCardView(frame: .zero)
  private var body: NSView?
  private var bodyHeight: CGFloat = 0
  private var presented = false
  private var keys: Any?
  private var scrimAlpha: CGFloat = 0
  private var scrimPressed = false

  #if DEBUG
  public var devReduceMotion: Bool?
  public var devAppearAnimating: Bool {
    scrim.animation(forKey: "sheet.opacity") != nil || card.layer?.animation(forKey: "sheet.opacity") != nil || card.layer?.animation(forKey: "sheet.transform") != nil
  }
  public var devScrimAlpha: CGFloat { scrimAlpha }
  #endif

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(scrim)
    addSubview(card)
    card.sheet = self
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { stopKeys() }

  public func present(body: NSView, bodyHeight: CGFloat, style: SheetStyle, accessibilityTitle: String, animated: Bool) {
    let first = !presented
    if self.body !== body { scrimPressed = false }
    presented = true
    if self.body !== body {
      self.body?.removeFromSuperview()
      self.body = body
      card.addSubview(body)
    }
    self.bodyHeight = max(0, bodyHeight)
    card.setAccessibilityLabel(accessibilityTitle)
    card.setAccessibilityTitle(accessibilityTitle)
    setStyle(style)
    placeCard()
    if first || !focusIsInCard { window?.makeFirstResponder(card) }
    startKeys()
    guard first, animated, !reduceMotion else { return }
    let timing = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    opacity.duration = 0.17
    opacity.timingFunction = timing
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = CATransform3DMakeScale(0.96, 0.96, 1)
    scale.toValue = CATransform3DIdentity
    scale.duration = 0.17
    scale.timingFunction = timing
    scrim.add(opacity, forKey: "sheet.opacity")
    card.layer?.add(opacity, forKey: "sheet.opacity")
    card.layer?.add(scale, forKey: "sheet.transform")
  }

  public func setBodyHeight(_ h: CGFloat) {
    bodyHeight = max(0, h)
    placeCard()
  }

  public func setStyle(_ style: SheetStyle) {
    scrimAlpha = style.dark ? 0.35 : 0.15
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scrim.backgroundColor = NSColor(white: 0, alpha: scrimAlpha).cgColor
    card.layer?.backgroundColor = CSSColor(style.panel)?.cg
    card.layer?.borderColor = CSSColor(style.panelBorder)?.cg
    card.shadowLayer.shadowOpacity = Float(style.panelShadowOpacity)
    CATransaction.commit()
  }

  public override func layout() {
    super.layout()
    placeCard()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    placeCard()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    placeCard()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    stopKeys()
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    placeCard()
    if presented {
      window?.makeFirstResponder(card)
      startKeys()
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0, frame.contains(point) else { return nil }
    return super.hitTest(point) ?? self
  }

  public override func mouseDown(with event: NSEvent) {
    scrimPressed = !cardFrame.contains(convert(event.locationInWindow, from: nil))
  }

  public override func mouseUp(with event: NSEvent) {
    let dismiss = scrimPressed && !cardFrame.contains(convert(event.locationInWindow, from: nil))
    scrimPressed = false
    if dismiss { cancelOperation(nil) }
  }

  public override func rightMouseDown(with event: NSEvent) {}
  public override func rightMouseUp(with event: NSEvent) {}
  public override func otherMouseDown(with event: NSEvent) {}
  public override func otherMouseUp(with event: NSEvent) {}
  public override func scrollWheel(with event: NSEvent) {}

  public override func cancelOperation(_ sender: Any?) {
    if !busy { onDismiss() }
  }

  public override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: cancelOperation(nil)
    case 36, 76: if window?.firstResponder === card { onSubmit() }
    case 48: moveFocus(backward: event.modifierFlags.contains(.shift))
    default: break
    }
  }

  public override func keyUp(with event: NSEvent) {}

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
    if !focusIsInCard { window?.makeFirstResponder(card) }
    if event.keyCode == 53 || event.keyCode == 48 || ((event.keyCode == 36 || event.keyCode == 76) && window?.firstResponder === card) {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  private var reduceMotion: Bool {
    #if DEBUG
    if let devReduceMotion { return devReduceMotion }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private var focusIsInCard: Bool {
    guard let focused = window?.firstResponder as? NSView else { return false }
    if focused.isDescendant(of: card) { return true }
    if let editor = focused as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
      return control.isDescendant(of: card)
    }
    return false
  }

  private func placeCard() {
    let scale = window?.backingScaleFactor ?? 2
    let height = bodyHeight + 40
    cardFrame = CGRect(
      x: ((bounds.midX - 190) * scale).rounded() / scale,
      y: ((bounds.midY - height / 2) * scale).rounded() / scale,
      width: 380, height: height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scrim.frame = bounds
    scrim.contentsScale = scale
    card.frame = cardFrame
    card.layer?.contentsScale = scale
    card.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    card.layer?.position = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
    body?.frame = CGRect(x: 20, y: 20, width: 340, height: bodyHeight)
    card.placeShadow()
    CATransaction.commit()
    linkKeyViews()
  }

  private func keyViews(in view: NSView) -> [NSView] {
    guard !view.isHiddenOrHasHiddenAncestor else { return [] }
    if let editor = view as? NSTextView, editor.isFieldEditor { return [] }
    if view is NSControl { return view.acceptsFirstResponder ? [view] : [] }
    return (view.acceptsFirstResponder ? [view] : []) + view.subviews.flatMap { keyViews(in: $0) }
  }

  private func linkKeyViews() {
    let candidates = body.map { keyViews(in: $0) } ?? []
    var views: [NSView] = [card]
    for candidate in candidates {
      var cursor: NSView? = candidate
      while let view = cursor, candidates.contains(where: { $0 === view }), !views.contains(where: { $0 === view }) {
        views.append(view)
        cursor = view.nextKeyView
      }
    }
    for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
  }

  private func moveFocus(backward: Bool) {
    linkKeyViews()
    guard let window else { return }
    let focused = window.firstResponder
    let control = (focused as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
    let view = (control ?? focused as? NSView) ?? card
    if backward { window.selectKeyView(preceding: view) } else { window.selectKeyView(following: view) }
    if !focusIsInCard { window.makeFirstResponder(card) }
  }

  private func startKeys() {
    guard keys == nil, presented, window != nil else { return }
    keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor, !event.modifierFlags.contains(.command) else { return }
        if !self.focusIsInCard { self.window?.makeFirstResponder(self.card) }
      }
      return event
    }
  }

  private func stopKeys() {
    if let keys { NSEvent.removeMonitor(keys) }
    keys = nil
  }
}

@MainActor
private final class SheetCardView: NSView {
  weak var sheet: SheetView?
  let shadowLayer = CALayer()
  private let shadowMask = CAShapeLayer()

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    layer?.masksToBounds = false
    layer?.addSublayer(shadowLayer)
    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.shadowRadius = 30
    shadowLayer.mask = shadowMask
    shadowMask.fillRule = .evenOdd
    setAccessibilityElement(true)
    setAccessibilityRole(.sheet)
    setAccessibilityModal(true)
  }

  required init?(coder: NSCoder) { fatalError() }

  func placeShadow() {
    let shape = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    shadowLayer.frame = bounds
    shadowLayer.shadowOffset = CGSize(width: 0, height: layer?.isGeometryFlipped == true || isFlipped ? 12 : -12)
    shadowLayer.shadowPath = shape
    let mask = CGMutablePath()
    mask.addRect(bounds.insetBy(dx: -106, dy: -106))
    mask.addPath(shape)
    shadowMask.frame = bounds
    shadowMask.path = mask
  }

  override func keyDown(with event: NSEvent) { sheet?.keyDown(with: event) }
  override func keyUp(with event: NSEvent) {}
  override func cancelOperation(_ sender: Any?) { sheet?.cancelOperation(sender) }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  override func mouseUp(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}
