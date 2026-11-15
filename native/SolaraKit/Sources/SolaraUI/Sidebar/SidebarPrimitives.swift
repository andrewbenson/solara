import AppKit
import QuartzCore

final class SurfaceLayer: CALayer {
  var fill: NSColor? { didSet { if fill != oldValue { setNeedsLayout() } } }
  var radius: CGFloat = 0 { didSet { if radius != oldValue { setNeedsLayout() } } }
  var borderTint: NSColor? { didSet { if borderTint != oldValue { setNeedsLayout() } } }
  var border: CGFloat = 0 { didSet { if border != oldValue { setNeedsLayout() } } }
  var borderColors: [NSColor] = [] { didSet { if borderColors != oldValue { setNeedsLayout() } } }
  var glowColor: NSColor? { didSet { if glowColor != oldValue { setNeedsLayout() } } }
  var glowOpacity: Double = 0 { didSet { if glowOpacity != oldValue { setNeedsLayout() } } }
  var glowRadius: CGFloat = 0 { didSet { if glowRadius != oldValue { setNeedsLayout() } } }
  var glowOffset = CGSize(width: 0, height: 0.5) { didSet { if glowOffset != oldValue { setNeedsLayout() } } }

  private let plate = CALayer()
  private let shadowLayer = CALayer()
  private let shadowMask = CAShapeLayer()
  private let borderGradient = CAGradientLayer()
  private let borderStroke = CAShapeLayer()

  override init() {
    super.init()
    setUp()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func setUp() {
    masksToBounds = false
    shadowMask.fillRule = .evenOdd
    shadowLayer.mask = shadowMask
    borderStroke.fillColor = nil
    borderStroke.strokeColor = NSColor.black.cgColor
    borderGradient.mask = borderStroke
    for layer in [shadowLayer, plate, borderGradient] as [CALayer] { addSublayer(layer) }
    for layer in [self, plate, shadowLayer, shadowMask, borderGradient, borderStroke] as [CALayer] { layer.actions = Self.noActions }
  }

  nonisolated(unsafe) static let noActions: [String: CAAction] = [
    "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(),
    "cornerRadius": NSNull(), "shadowOpacity": NSNull(), "shadowPath": NSNull(), "shadowColor": NSNull(), "shadowRadius": NSNull(), "path": NSNull(),
    "colors": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "sublayers": NSNull(), "mask": NSNull(), "transform": NSNull(),
  ]

  override func layoutSublayers() {
    super.layoutSublayers()
    apply()
  }

  func apply() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let rect = bounds
    plate.frame = rect
    plate.cornerRadius = radius
    plate.cornerCurve = .continuous
    plate.backgroundColor = fill?.cgColor
    if borderColors.count >= 2, border > 0 {
      plate.borderWidth = 0
      borderGradient.isHidden = false
      borderGradient.frame = rect
      borderGradient.colors = borderColors.map(\.cgColor)
      borderGradient.startPoint = CGPoint(x: 0.5, y: 0)
      borderGradient.endPoint = CGPoint(x: 0.5, y: 1)
      let inset = border / 2
      borderStroke.frame = rect
      borderStroke.lineWidth = border
      borderStroke.path = CGPath(
        roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: max(radius - inset, 0), cornerHeight: max(radius - inset, 0), transform: nil)
    } else {
      borderGradient.isHidden = true
      plate.borderColor = borderTint?.cgColor
      plate.borderWidth = border
    }
    if let glowColor, glowOpacity > 0 {
      let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
      shadowLayer.isHidden = false
      shadowLayer.frame = rect
      shadowLayer.shadowColor = glowColor.cgColor
      shadowLayer.shadowOpacity = Float(glowOpacity)
      shadowLayer.shadowRadius = glowRadius
      shadowLayer.shadowOffset = glowOffset
      shadowLayer.shadowPath = shape
      let outset = glowRadius * 3 + abs(glowOffset.height) + abs(glowOffset.width) + 4
      let mask = CGMutablePath()
      mask.addRect(rect.insetBy(dx: -outset, dy: -outset))
      mask.addPath(shape)
      shadowMask.frame = rect
      shadowMask.path = mask
    } else {
      shadowLayer.isHidden = true
    }
  }
}

final class FadeLabel: NSTextField {
  private let fade = CAGradientLayer()
  private var keycapEnd: CGFloat?

  var text = "" { didSet { if text != oldValue { stringValue = text; relayout() } } }
  var color: NSColor = .labelColor { didSet { if color != oldValue { textColor = color } } }
  var fadeWidth: CGFloat = 24 { didSet { relayout() } }

  override var isFlipped: Bool { true }

  init(fontSize: CGFloat = 13, weight: NSFont.Weight = .regular) {
    super.init(frame: .zero)
    cell = CenteredLabelCell(textCell: "")
    isBezeled = false
    isBordered = false
    drawsBackground = false
    isEditable = false
    isSelectable = false
    lineBreakMode = .byClipping
    maximumNumberOfLines = 1
    cell?.truncatesLastVisibleLine = false
    font = .monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    textColor = color
    wantsLayer = true
    fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.actions = SurfaceLayer.noActions
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { relayout() }
  }

  static let cellPadding: CGFloat = 4

  var textWidth: CGFloat { cell?.cellSize.width ?? 0 }

  func keycapFade(end: CGFloat?, transition: TabNumberHintTransition? = nil) {
    guard keycapEnd != end else {
      if let transition, !transition.animated {
        fade.removeAnimation(forKey: "tabNumberHintTitle")
        relayout()
      }
      return
    }
    keycapEnd = end
    relayout(transition: transition)
  }

  private func relayout(transition: TabNumberHintTransition? = nil) {
    let width = max(0, min(bounds.width, keycapEnd ?? bounds.width))
    guard bounds.width > 0, keycapEnd != nil || textWidth > bounds.width + 0.5 || transition?.animated == true else {
      layer?.mask = nil
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if layer?.mask == nil {
      fade.frame = bounds
      fade.locations = [0, NSNumber(value: Double(max(0, 1 - fadeWidth / max(1, bounds.width)))), 1]
    }
    let previousBounds = (fade.presentation() ?? fade).bounds
    let previousPosition = (fade.presentation() ?? fade).position
    let previousLocations = (fade.presentation() ?? fade).locations
    fade.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    let start = keycapEnd == nil && textWidth <= width + 0.5 ? 1 : max(0, 1 - fadeWidth / max(1, width))
    fade.locations = [0, NSNumber(value: Double(start)), 1]
    layer?.mask = fade
    CATransaction.commit()
    fade.removeAnimation(forKey: "tabNumberHintTitle")
    if let transition, transition.animated {
      let resize = CABasicAnimation(keyPath: "bounds")
      resize.fromValue = previousBounds
      resize.toValue = fade.bounds
      let move = CABasicAnimation(keyPath: "position")
      move.fromValue = previousPosition
      move.toValue = fade.position
      let stops = CABasicAnimation(keyPath: "locations")
      stops.fromValue = previousLocations
      stops.toValue = fade.locations
      let group = CAAnimationGroup()
      for animation in [resize, move, stops] { animation.duration = transition.duration }
      group.animations = [resize, move, stops]
      group.beginTime = fade.convertTime(transition.start, from: nil)
      group.duration = transition.duration
      group.timingFunction = transition.curve
      fade.add(group, forKey: "tabNumberHintTitle")
    }
  }
}

final class CenteredLabelCell: NSTextFieldCell {
  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    let base = super.drawingRect(forBounds: rect)
    let height = cellSize.height
    let offset = (rect.height - height) / 2
    return NSRect(x: base.minX, y: rect.minY + offset + (base.minY - rect.minY), width: max(base.width, cellSize.width), height: height)
  }
}

final class SpinnerView: NSView {
  private let track = CAShapeLayer()
  private let ring = CAShapeLayer()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for shape in [track, ring] {
      shape.fillColor = nil
      shape.lineWidth = 1.5
      shape.actions = SurfaceLayer.noActions
      layer?.addSublayer(shape)
    }
    ring.lineCap = .round
    ring.strokeStart = 0
    ring.strokeEnd = 0.72
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGPath(ellipseIn: bounds.insetBy(dx: 1.25, dy: 1.25), transform: nil)
    for shape in [track, ring] {
      shape.frame = bounds
      shape.path = path
    }
    CATransaction.commit()
    recolor()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    recolor()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    spin()
  }

  override func viewDidHide() {
    super.viewDidHide()
    spin()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    spin()
  }

  private func recolor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
      ring.strokeColor = NSColor.secondaryLabelColor.cgColor
    }
  }

  private func spin() {
    guard window != nil, !isHiddenOrHasHiddenAncestor else { return ring.removeAnimation(forKey: "activityRotation") }
    guard ring.animation(forKey: "activityRotation") == nil else { return }
    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = 2 * Double.pi
    turn.duration = 1.88
    turn.repeatCount = .infinity
    turn.timingFunction = CAMediaTimingFunction(name: .linear)
    turn.isRemovedOnCompletion = false
    ring.add(turn, forKey: "activityRotation")
  }
}

final class SymbolView: NSView {
  private let imageView = NSImageView()
  private var shown: (name: String, size: CGFloat, weight: NSFont.Weight)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    imageView.imageScaling = .scaleNone
    imageView.autoresizingMask = [.width, .height]
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    imageView.frame = bounds
  }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    if shown?.name != name || shown?.size != size || shown?.weight != weight {
      shown = (name, size, weight)
      imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
    if imageView.contentTintColor != color { imageView.contentTintColor = color }
  }
}

enum SidebarSymbol {
  static func weight(_ name: String) -> NSFont.Weight {
    switch name {
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "light": .light
    default: .regular
    }
  }
}
