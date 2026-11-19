import AppKit
import QuartzCore

@MainActor
enum SidebarDisplayOptions {
  #if DEBUG
  static var reducesTransparencyOverride: Bool?
  #endif

  static var reducesTransparency: Bool {
    #if DEBUG
    if let reducesTransparencyOverride { return reducesTransparencyOverride }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }
}

@MainActor
enum SelectedTabTint {
  static let lift: CGFloat = 10
  static let aboveHover: CGFloat = 4
  static let lightFloor: CGFloat = 0.7

  static func sidebar(_ tokens: [String: String], dark: Bool) -> NSColor {
    let base = NSColor(white: dark ? 0.1 : 0.92, alpha: 1)
    guard let tint = SidebarPalette.parse(tokens["windowTint"])?.usingColorSpace(.sRGB) else { return base }
    return mix(base, tint, tint.alphaComponent)
  }

  static func whiteAmount(over sidebar: NSColor, hover: NSColor, dark: Bool) -> CGFloat {
    let base = sidebar.usingColorSpace(.sRGB) ?? sidebar
    let hoverColor = hover.usingColorSpace(.sRGB) ?? hover
    let hovered = mix(base, NSColor(srgbRed: hoverColor.redComponent, green: hoverColor.greenComponent, blue: hoverColor.blueComponent, alpha: 1), hoverColor.alphaComponent)
    let floor = dark ? lightness(hovered) + aboveHover : lightness(mix(base, .white, lightFloor))
    let goal = min(100, max(lightness(base) + lift, floor))
    var low: CGFloat = 0
    var high: CGFloat = 1
    for _ in 0..<24 {
      let mid = (low + high) / 2
      if lightness(mix(base, .white, mid)) < goal { low = mid } else { high = mid }
    }
    return high
  }

  static func mix(_ from: NSColor, _ to: NSColor, _ amount: CGFloat) -> NSColor {
    let a = from.usingColorSpace(.sRGB) ?? from
    let b = to.usingColorSpace(.sRGB) ?? to
    func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * amount }
    return NSColor(srgbRed: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent), blue: lerp(a.blueComponent, b.blueComponent), alpha: 1)
  }

  static func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
    let t = top.usingColorSpace(.sRGB) ?? top
    let b = bottom.usingColorSpace(.sRGB) ?? bottom
    let alpha = t.alphaComponent + b.alphaComponent * (1 - t.alphaComponent)
    guard alpha > 0 else { return .clear }
    func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x * t.alphaComponent + y * b.alphaComponent * (1 - t.alphaComponent)) / alpha }
    return NSColor(srgbRed: channel(t.redComponent, b.redComponent), green: channel(t.greenComponent, b.greenComponent), blue: channel(t.blueComponent, b.blueComponent), alpha: alpha)
  }

  static func luminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB) ?? color
    func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
  }

  static func lightness(_ color: NSColor) -> CGFloat {
    let y = luminance(color)
    return y > 216.0 / 24389.0 ? 116 * pow(y, 1.0 / 3.0) - 16 : y * 24389.0 / 27.0
  }
}

@MainActor
final class SidebarSelectionGlassSlot {
  private(set) var existing: SidebarSelectionGlass?

  var glass: SidebarSelectionGlass {
    if let existing { return existing }
    let made = SidebarSelectionGlass()
    existing = made
    return made
  }
}

@MainActor
final class SidebarSelectionGlass: NSView {
  static let tintStrength: CGFloat = 0.4

  private let surface = NewTabGlassSurface(frame: .zero)
  private let rimHost = NSView()
  private let rim = GlassSelectionLayer()
  let wash = CALayer()
  private var look: (radius: CGFloat, tint: NSColor, dark: Bool, wash: NSColor?, washEdge: NSColor?)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    rimHost.wantsLayer = true
    rimHost.layer?.masksToBounds = false
    wash.actions = SurfaceLayer.noActions
    wash.cornerCurve = .continuous
    rimHost.layer?.addSublayer(wash)
    rimHost.layer?.addSublayer(rim)
    addSubview(surface)
    addSubview(rimHost)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(radius: CGFloat, tint: NSColor, dark: Bool, wash: NSColor? = nil, washEdge: NSColor? = nil) {
    if let look, look.radius == radius, look.tint == tint, look.dark == dark, look.wash == wash, look.washEdge == washEdge { return }
    look = (radius, tint, dark, wash, washEdge)
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let look else { return }
    surface.frame = bounds
    surface.apply(frame: bounds, radius: look.radius, tint: look.tint, dark: look.dark, tintStrength: Self.tintStrength)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rimHost.frame = bounds
    rim.frame = bounds
    wash.frame = bounds
    wash.cornerRadius = look.radius
    wash.backgroundColor = look.wash?.cgColor
    wash.borderColor = look.washEdge?.cgColor
    wash.borderWidth = look.washEdge == nil ? 0 : 0.5
    wash.isHidden = look.wash == nil && look.washEdge == nil
    rim.apply(radius: look.radius, dark: look.dark, scale: rimScale, crisp: true, lifted: false)
    CATransaction.commit()
  }

  var rimScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    needsLayout = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
}
