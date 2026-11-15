import AppKit
import QuartzCore

final class TransportButton: NSView {
  private let symbol = SymbolView()
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    addSubview(symbol)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  func set(_ name: String, size: CGFloat, color: NSColor, tooltip: String) {
    symbol.set(name, size: size, color: color)
    if toolTip != tooltip {
      toolTip = tooltip
      setAccessibilityLabel(tooltip)
    }
  }

  override func layout() {
    super.layout()
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

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  private func paint() {
    MediaMotion.setInstantly { layer?.opacity = pressed ? 0.45 : hovered ? 1 : 0.6 }
  }
}

final class SeekBarView: NSView {
  static let hoverSegments = 40

  private let track = CALayer()
  private let fill = CALayer()
  private let hoverFill = CALayer()
  private var tracking: NSTrackingArea?
  private var hoverSegment: Int?
  private(set) var drag: Double?
  var barHeight: CGFloat = 6 { didSet { needsLayout = true } }
  var progress: Double = 0 { didSet { if progress != oldValue { needsLayout = true } } }
  var seekable = false
  var colors: (track: NSColor, fill: NSColor, hover: NSColor) = (.clear, .clear, .clear) {
    didSet {
      MediaMotion.setInstantly {
        track.backgroundColor = colors.track.cgColor
        fill.backgroundColor = colors.fill.cgColor
        hoverFill.backgroundColor = colors.hover.cgColor
      }
    }
  }
  var onDrag: ((Double?) -> Void)?
  var onSeek: ((Double) -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    track.masksToBounds = true
    for l in [track, fill, hoverFill] {
      l.actions = SurfaceLayer.noActions
    }
    track.addSublayer(fill)
    track.addSublayer(hoverFill)
    layer?.addSublayer(track)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    guard DevPointer.inside(self, note), let window, let screen = (note.object as? NSValue)?.pointValue else {
      if hoverSegment != nil { hoverSegment = nil; needsLayout = true }
      return
    }
    let x = convert(window.convertPoint(fromScreen: screen), from: nil).x
    let next = min(Self.hoverSegments - 1, Int(x / max(1, bounds.width) * Double(Self.hoverSegments)))
    if next != hoverSegment { hoverSegment = next; needsLayout = true }
  }

  var hoverProgress: Double? { hoverSegment.map { (Double($0) + 0.5) / Double(Self.hoverSegments) } }

  override func layout() {
    super.layout()
    let radius = barHeight / 2
    let width = bounds.width
    let shown = drag ?? progress
    MediaMotion.setInstantly {
      track.frame = CGRect(x: 0, y: (bounds.height - barHeight) / 2, width: width, height: barHeight)
      track.cornerRadius = radius
      fill.frame = CGRect(x: 0, y: 0, width: width * shown, height: barHeight)
      fill.cornerRadius = radius
      let hover = drag == nil ? hoverProgress : nil
      hoverFill.isHidden = hover == nil
      hoverFill.frame = CGRect(x: 0, y: 0, width: width * (hover ?? 0), height: barHeight)
      hoverFill.cornerRadius = radius
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  private func segment(_ event: NSEvent) -> Int? {
    let x = convert(event.locationInWindow, from: nil).x
    guard bounds.width > 0, x >= 0, x < bounds.width else { return nil }
    return min(Self.hoverSegments - 1, Int(x / bounds.width * Double(Self.hoverSegments)))
  }

  override func mouseEntered(with event: NSEvent) { moveHover(event) }

  override func mouseMoved(with event: NSEvent) { moveHover(event) }

  private func moveHover(_ event: NSEvent) {
    guard let next = segment(event), next != hoverSegment else { return }
    hoverSegment = next
    needsLayout = true
  }

  override func mouseExited(with event: NSEvent) {
    hoverSegment = nil
    needsLayout = true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func at(_ event: NSEvent) -> Double {
    let x = convert(event.locationInWindow, from: nil).x
    return min(1, max(0, x / max(1, bounds.width)))
  }

  private func update(_ p: Double?) {
    drag = p
    onDrag?(p)
    needsLayout = true
  }

  override func mouseDown(with event: NSEvent) {
    guard seekable else { return }
    update(at(event))
  }

  override func mouseDragged(with event: NSEvent) {
    guard drag != nil else { return }
    update(at(event))
  }

  override func mouseUp(with event: NSEvent) {
    guard drag != nil else { return }
    let p = at(event)
    update(nil)
    onSeek?(p)
  }
}

final class MediaArtView: NSView {
  private let plate = CALayer()
  private let art = CALayer()
  private let icon = TabIconView()
  private let overlay = CALayer()
  private let arrow = SymbolView()
  private var tracking: NSTrackingArea?
  private var shownArt: String?
  private var hovered = false { didSet { if hovered != oldValue { needsLayout = true } } }
  private var pressed = false
  var hoverArrow = false
  var iconSize: CGFloat = 24
  var iconOpacity: CGFloat = 0.5
  var fadeIn = true
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    plate.masksToBounds = true
    plate.cornerRadius = 6
    plate.cornerCurve = .continuous
    for l in [plate, art, overlay] { l.actions = SurfaceLayer.noActions }
    art.contentsGravity = .resizeAspectFill
    art.masksToBounds = true
    overlay.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
    layer?.addSublayer(plate)
    addSubview(icon)
    icon.favicons = MediaImages.favicons
    plate.addSublayer(art)
    wantsLayer = true
    plate.addSublayer(overlay)
    addSubview(arrow)
    toolTip = "Back to Tab"
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Back to Tab")
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  func set(_ state: MediaPlayerState, palette: MediaPalette) {
    MediaMotion.setInstantly { plate.backgroundColor = palette.tokens.artPlaceholder.cgColor }
    icon.set(TabIconSpec(url: state.url, favicon: state.favicon, profileId: state.profileId, size: iconSize), palette: MediaImages.sidebarPalette(state.theme))
    arrow.set("arrow.up.left", size: 16, weight: .semibold, color: .white)
    let image = state.artwork.flatMap(MediaImages.image)
    let key = image == nil ? nil : state.artwork
    if key != shownArt {
      shownArt = key
      MediaMotion.setInstantly {
        art.contents = image
        art.isHidden = image == nil
      }
      if image != nil, fadeIn {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        art.add(fade, forKey: "artFade")
      }
    }
    needsLayout = true
  }

  var showsArtwork: Bool { shownArt != nil }

  override func layout() {
    super.layout()
    let showOverlay = hoverArrow && hovered
    MediaMotion.setInstantly {
      plate.frame = bounds
      art.frame = plate.bounds
      overlay.frame = plate.bounds
      overlay.isHidden = !showOverlay
    }
    icon.frame = CGRect(x: ((bounds.width - iconSize) / 2).rounded(), y: ((bounds.height - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
    icon.isHidden = shownArt != nil
    icon.alphaValue = iconOpacity
    arrow.frame = CGRect(x: (bounds.width - 22) / 2, y: (bounds.height - 22) / 2, width: 22, height: 22)
    arrow.isHidden = !showOverlay
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
    if window == nil { hovered = false }
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    defer { pressed = false }
    if pressed && inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}

final class MediaCircleButton: NSView {
  private let surface = SurfaceLayer()
  private let symbol = SymbolView()
  private var symbolBox: CGFloat = 0
  private var tracking: NSTrackingArea?
  private(set) var hovered = false { didSet { if hovered != oldValue { onHover?(hovered) } } }
  var onPress: (() -> Void)?
  var onHover: ((Bool) -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    layer?.addSublayer(surface)
    addSubview(symbol)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  func style(fill: NSColor, border: NSColor?, borderWidth: CGFloat, shadow: Double, shadowRadius: CGFloat, shadowOffset: CGFloat) {
    surface.fill = fill
    surface.borderTint = border
    surface.border = borderWidth
    surface.glowColor = .black
    surface.glowOpacity = shadow
    surface.glowRadius = shadowRadius
    surface.glowOffset = CGSize(width: 0, height: shadowOffset)
  }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, box: CGFloat, tooltip: String) {
    symbol.set(name, size: size, weight: weight, color: color)
    symbolBox = box
    needsLayout = true
    if toolTip != tooltip {
      toolTip = tooltip
      setAccessibilityLabel(tooltip)
    }
  }

  override func layout() {
    super.layout()
    surface.radius = bounds.height / 2
    MediaMotion.setInstantly { surface.frame = bounds }
    symbol.frame = CGRect(x: (bounds.width - symbolBox) / 2, y: (bounds.height - symbolBox) / 2, width: symbolBox, height: symbolBox)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}
