import AppKit
import QuartzCore
#if SOLARA_PROBES
import SolaraProbes
#endif

final class SidebarIconButton: NSView {
  private let plate = CALayer()
  private let symbol = SymbolView()
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }
  var hoverFill: NSColor = .clear { didSet { paint() } }
  var pressedFill: NSColor = .clear { didSet { paint() } }
  var radius: CGFloat = 6 { didSet { plate.cornerRadius = radius } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    plate.cornerRadius = radius
    layer?.addSublayer(plate)
    addSubview(symbol)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, tooltip: String?) {
    symbol.set(name, size: size, weight: weight, color: color)
    if toolTip != tooltip { toolTip = tooltip }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    symbol.frame = bounds
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovered = false; pressed = false }
  }

  override func viewDidHide() {
    super.viewDidHide()
    hovered = false
    pressed = false
  }

  func syncHover() {
    guard let window, !isHiddenOrHasHiddenAncestor else { return hovered = false }
    hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseDragged(with event: NSEvent) {
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  private func paint() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed ? pressedFill : hovered ? hoverFill : .clear).cgColor
    CATransaction.commit()
  }
}

final class SidebarGlassTile: NSView {
  private let glass = NSGlassEffectView()
  private let selection = GlassSelectionLayer()
  private let outline = CALayer()
  var radius: CGFloat = SidebarMetrics.tileRadius { didSet { if radius != oldValue { needsLayout = true } } }
  var tint: NSColor? { didSet { if tint != oldValue { glass.tintColor = tint } } }
  var dark = true { didSet { if dark != oldValue { glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); needsLayout = true } } }
  var raisedSelection = false { didSet { if raisedSelection != oldValue { needsLayout = true } } }
  var outlineColor: NSColor? { didSet { if outlineColor != oldValue { needsLayout = true } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    glass.cornerRadius = radius
    glass.style = .regular
    glass.appearance = NSAppearance(named: .darkAqua)
    addSubview(glass)
    outline.actions = SurfaceLayer.noActions
    outline.cornerCurve = .continuous
    layer?.addSublayer(selection)
    layer?.addSublayer(outline)
    apply()
    #if SOLARA_PROBES
    ProbeCapture.shared.register(self) { $0.prepareForCapture() }
    #endif
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    apply()
  }

  #if SOLARA_PROBES
  private func prepareForCapture() -> ProbeCapture.Restore {
    guard let layer else { return {} }
    let hidden = glass.isHidden
    let fill = CALayer()
    fill.frame = bounds
    fill.cornerRadius = radius
    fill.cornerCurve = .continuous
    fill.backgroundColor = tint?.cgColor
    fill.isHidden = hidden
    layer.insertSublayer(fill, at: 0)
    glass.isHidden = true
    return { [glass] in
      fill.removeFromSuperlayer()
      glass.isHidden = hidden
    }
  }
  #endif

  private func apply() {
    if glass.frame != bounds { glass.frame = bounds }
    if glass.cornerRadius != radius { glass.cornerRadius = radius }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    selection.frame = bounds
    selection.isHidden = !raisedSelection
    if raisedSelection { selection.apply(radius: radius, dark: dark, scale: window?.backingScaleFactor ?? 2) }
    outline.frame = bounds
    outline.cornerRadius = radius
    outline.borderWidth = outlineColor == nil ? 0 : 1
    outline.borderColor = outlineColor?.cgColor
    outline.isHidden = outlineColor == nil
    CATransaction.commit()
  }
}

final class GlassSelectionLayer: CALayer {
  private let lift = CALayer()
  private let liftMask = CAShapeLayer()
  private let sheen = CAGradientLayer()
  private let rim = CAGradientLayer()
  private let rimMask = CALayer()

  override init() {
    super.init()
    liftMask.fillRule = .evenOdd
    lift.mask = liftMask
    lift.shadowColor = NSColor.black.cgColor
    lift.shadowRadius = 3
    sheen.masksToBounds = true
    rimMask.borderColor = NSColor.white.cgColor
    rim.mask = rimMask
    for layer in [lift, sheen, rim] as [CALayer] { addSublayer(layer) }
    for layer in [self, lift, liftMask, sheen, rim, rimMask] as [CALayer] { layer.actions = SurfaceLayer.noActions }
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(radius: CGFloat, dark: Bool, scale: CGFloat) {
    let rect = bounds
    let top = CGPoint(x: 0.5, y: 0)
    let bottom = CGPoint(x: 0.5, y: 1)
    for shape in [sheen, rim, rimMask] as [CALayer] {
      shape.frame = rect
      shape.cornerRadius = radius
      shape.cornerCurve = .continuous
    }
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    lift.frame = rect
    lift.shadowPath = shape
    lift.shadowOpacity = dark ? 0.5 : 0.2
    lift.shadowOffset = CGSize(width: 0, height: 1)
    let outside = CGMutablePath()
    outside.addRect(rect.insetBy(dx: -12, dy: -12))
    outside.addPath(shape)
    liftMask.frame = rect
    liftMask.path = outside
    sheen.colors = [NSColor.white.withAlphaComponent(dark ? 0.12 : 0.4).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
    sheen.locations = [0, 0.6]
    sheen.startPoint = top
    sheen.endPoint = bottom
    rimMask.borderWidth = (1 * scale).rounded() / scale
    rim.colors = [NSColor.white.withAlphaComponent(dark ? 0.5 : 1).cgColor, NSColor.white.withAlphaComponent(dark ? 0.14 : 0.55).cgColor]
    rim.startPoint = top
    rim.endPoint = bottom
  }
}

@MainActor
enum PressFeedback {
  static let scale: CGFloat = 0.99
  static let opacity: Float = 0.95
  static let inDuration: CFTimeInterval = 0.08
  static let outDuration: CFTimeInterval = 0.18
  static let curve = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)

  @MainActor
  static func apply(_ view: NSView, pressed: Bool) {
    guard let layer = view.layer else { return }
    let bounds = view.bounds
    let target: CATransform3D
    if pressed {
      var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
      t = CATransform3DScale(t, scale, scale, 1)
      target = CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    } else {
      target = CATransform3DIdentity
    }
    let opacity: Float = pressed ? Self.opacity : 1
    let duration = pressed ? inDuration : outDuration
    let fromTransform = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
    let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
    layer.sublayerTransform = target
    layer.opacity = opacity
    let move = CABasicAnimation(keyPath: "sublayerTransform")
    move.fromValue = NSValue(caTransform3D: fromTransform)
    move.toValue = NSValue(caTransform3D: target)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fromOpacity
    fade.toValue = opacity
    for animation in [move, fade] {
      animation.duration = duration
      animation.timingFunction = curve
    }
    layer.add(move, forKey: "pressTransform")
    layer.add(fade, forKey: "pressOpacity")
  }
}
