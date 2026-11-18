import AppKit

final class BarSurfaceView: NSView {
  var fill: NSColor? { didSet { apply() } }
  var radius: CGFloat = 0 { didSet { apply() } }
  var borderColor: NSColor? { didSet { apply() } }
  var borderWidth: CGFloat = 0 { didSet { apply() } }
  var shadowColor: NSColor? { didSet { apply() } }
  var shadowOpacity: Double = 0 { didSet { apply() } }
  var shadowRadius: CGFloat = 0 { didSet { apply() } }
  var shadowOffset: CGSize = .zero { didSet { apply() } }

  private let plate = CALayer()
  private let shadowLayer = CALayer()
  private let shadowMask = CAShapeLayer()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func layout() {
    super.layout()
    apply()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    apply()
  }

  private func apply() {
    guard let layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if plate.superlayer !== layer {
      layer.insertSublayer(plate, at: 0)
      layer.insertSublayer(shadowLayer, below: plate)
      shadowMask.fillRule = .evenOdd
      shadowLayer.mask = shadowMask
    }
    layer.masksToBounds = false
    plate.frame = bounds
    plate.cornerRadius = radius
    plate.cornerCurve = .continuous
    plate.backgroundColor = fill?.cgColor
    plate.borderColor = borderColor?.cgColor
    plate.borderWidth = borderWidth
    let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    shadowLayer.frame = bounds
    if let shadowColor, shadowOpacity > 0 {
      shadowLayer.shadowColor = shadowColor.cgColor
      shadowLayer.shadowOpacity = Float(shadowOpacity)
      shadowLayer.shadowRadius = shadowRadius
      shadowLayer.shadowOffset = CGSize(width: shadowOffset.width, height: layer.isGeometryFlipped || isFlipped ? shadowOffset.height : -shadowOffset.height)
      shadowLayer.shadowPath = shape
      let outset = shadowRadius * 3 + abs(shadowOffset.height) + abs(shadowOffset.width) + 4
      let mask = CGMutablePath()
      mask.addRect(bounds.insetBy(dx: -outset, dy: -outset))
      mask.addPath(shape)
      shadowMask.frame = bounds
      shadowMask.path = mask
      shadowLayer.isHidden = false
    } else {
      shadowLayer.isHidden = true
    }
    CATransaction.commit()
  }
}

final class MarkView: NSView {
  private var layersByName: [MarkLayer.Name: CALayer] = [:]
  private(set) var offsets = MarkOffsets.rest

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    for name in MarkLayer.Name.allCases {
      let l = CALayer()
      l.contentsGravity = .resize
      l.anchorPoint = .zero
      l.frame = CGRect(x: 0, y: 0, width: NewTabLayout.markSize, height: NewTabLayout.markSize)
      layer?.addSublayer(l)
      layersByName[name] = l
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func setImages(_ images: [MarkLayer.Name: NSImage]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (name, l) in layersByName {
      l.contents = images[name]
      l.contentsScale = window?.backingScaleFactor ?? 2
    }
    CATransaction.commit()
  }

  func apply(_ next: MarkOffsets) {
    offsets = next
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (name, l) in layersByName {
      let x = name == .sun ? next.sunX : 0
      l.setAffineTransform(CGAffineTransform(translationX: x, y: next.y[name] ?? 0))
    }
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    for l in layersByName.values { l.contentsScale = window?.backingScaleFactor ?? 2 }
  }
}

final class NewTabGlassSurface: NSGlassEffectContainerView {
  let canvas = NewTabGlassCanvas()
  let glass = NSGlassEffectView()
  let foreground = NewTabGlassCanvas()

  override init(frame: NSRect) {
    super.init(frame: frame)
    spacing = 0
    contentView = canvas
    glass.style = .regular
    glass.contentView = foreground
    canvas.addSubview(glass)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func apply(frame: CGRect, radius: CGFloat, tint: NSColor, dark: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvas.frame = bounds
    glass.frame = frame
    glass.cornerRadius = radius
    glass.tintColor = tint.withAlphaComponent(tint.alphaComponent * 0.12)
    glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    foreground.frame = glass.bounds
    CATransaction.commit()
  }
}

final class NewTabGlassCanvas: NSView {
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { true }
}
