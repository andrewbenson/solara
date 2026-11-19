import AppKit

struct FullScreenIslandPlacement {
  let frame: CGRect?
  let buttonFrames: [CGRect]
  let slideOffset: CGFloat

  init(fullscreen: Bool, page: Bool, reveal: CGFloat, menuBottom: CGFloat, closeCenter: CGPoint, windowedButtons: [CGRect]) {
    let progress = min(1, max(0, reveal))
    let capsule = CGRect(x: closeCenter.x - 17, y: closeCenter.y - 16.5, width: 80, height: 33)
    slideOffset = -max(0, capsule.maxY) * (1 - progress)
    guard fullscreen, !page, progress > 0, windowedButtons.count == 3 else {
      frame = nil
      buttonFrames = []
      return
    }
    frame = capsule.offsetBy(dx: 0, dy: max(0, menuBottom) * progress + slideOffset)
    buttonFrames = [CGFloat(10), 33, 56].map { CGRect(x: $0, y: 9.5, width: 14, height: 14) }
  }
}

@MainActor
enum FullScreenIslandCoverage {
  private static let islands = NSMapTable<NSWindow, FullScreenIslandView>(keyOptions: .weakMemory, valueOptions: .weakMemory)

  static func contains(_ point: NSPoint, in window: NSWindow?) -> Bool {
    guard let window, let island = islands.object(forKey: window) else { return false }
    return island.blocksHover(at: point)
  }

  static func register(_ island: FullScreenIslandView, in window: NSWindow?) {
    guard let window else { return }
    islands.setObject(island, forKey: window)
  }

  static func remove(_ island: FullScreenIslandView, from window: NSWindow?) {
    guard let window, islands.object(forKey: window) === island else { return }
    islands.removeObject(forKey: window)
  }
}

struct FullScreenIslandBackdropPlacement {
  let corner: CGRect?
  let edge: CGRect?
  let horizontal: CGRect?

  init(topTabs: Bool, profileName: Bool, sidebar: CGRect, header: CGRect, offset: CGFloat) {
    if topTabs {
      corner = nil
      edge = nil
      horizontal = profileName ? nil : CGRect(x: header.minX, y: header.minY + offset, width: min(150, header.width), height: header.height)
    } else if offset > 0, sidebar.width > 56, sidebar.minX == 0 {
      corner = CGRect(x: 0, y: 0, width: sidebar.width + 30, height: header.maxY + offset + 30)
      edge = CGRect(x: sidebar.minX, y: header.maxY + offset, width: sidebar.width, height: 30)
      horizontal = nil
    } else {
      corner = nil
      edge = nil
      horizontal = nil
    }
  }
}

@MainActor
final class FullScreenIslandBackdropSample {
  private(set) var image: CGImage?
  private(set) var bounds = CGRect.zero
  private(set) var signature = ""

  func clear() {
    image = nil
    bounds = .zero
    signature = ""
  }

  func update(_ source: NSView) {
    update([source], in: source)
  }

  func update(_ sources: [NSView], in owner: NSView) {
    let visible = sources.filter { !$0.isHidden && $0.alphaValue > 0 }
    for source in visible { source.layoutSubtreeIfNeeded() }
    var underfills: [(CGRect, CGColor)] = []
    owner.effectiveAppearance.performAsCurrentDrawingAppearance {
      if let color = owner.window?.backgroundColor.cgColor { underfills.append((owner.bounds, color)) }
    }
    var ancestors: [NSView] = []
    var ancestor: NSView? = visible.contains(where: { $0 === owner }) ? owner.superview : owner
    while let current = ancestor {
      ancestors.append(current)
      ancestor = current.superview
    }
    for view in ancestors.reversed() {
      if let color = view.layer?.backgroundColor { underfills.append((owner.convert(view.bounds, from: view), color)) }
    }
    let fillSignature = underfills.map { "\($0.0):\($0.1.colorSpace?.model.rawValue ?? -1):\($0.1.components ?? [])" }.joined(separator: "|")
    let next = "\(owner.bounds)|\(owner.effectiveAppearance.name)|\(owner.window?.isKeyWindow ?? false)|\(owner.window?.backingScaleFactor ?? 1)|\(owner.window?.colorSpace?.iccProfileData?.hashValue ?? 0)|\(fillSignature)|" + visible.map { fingerprint($0) }.joined(separator: "|")
    guard next != signature else { return }
    signature = next
    bounds = owner.bounds
    image = nil
    guard !bounds.isEmpty, !visible.isEmpty else { return }
    var captures: [(source: NSView, image: CGImage, opacity: CGFloat)] = []
    for source in visible {
      let selector = NSSelectorFromString("fullScreenBackdropImage")
      let capture: NSBitmapImageRep?
      var opacity: CGFloat = 1
      if source.responds(to: selector) {
        capture = source.perform(selector)?.takeUnretainedValue() as? NSBitmapImageRep
        if source.responds(to: NSSelectorFromString("fullScreenBackdropOpacity")),
          let value = source.value(forKey: "fullScreenBackdropOpacity") as? NSNumber {
          opacity = CGFloat(value.doubleValue)
        }
      } else {
        capture = source.bitmapImageRepForCachingDisplay(in: source.bounds)
        if let capture { source.cacheDisplay(in: source.bounds, to: capture) }
      }
      if let captured = capture?.cgImage { captures.append((source, captured, opacity)) }
    }
    guard let first = captures.first, first.source.bounds.width > 0,
      let space = first.image.colorSpace?.model == .rgb ? first.image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
    else { return }
    let scale = CGFloat(first.image.width) / first.source.bounds.width
    guard let context = CGContext(data: nil, width: Int(ceil(bounds.width * scale)),
      height: Int(ceil(bounds.height * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.clear(CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
    context.scaleBy(x: scale, y: scale)
    for (rect, color) in underfills {
      context.setFillColor(color)
      context.fill(CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height))
    }
    for (source, captured, opacity) in captures {
      let rect = owner.convert(source.bounds, from: source)
      context.setAlpha(opacity)
      context.draw(captured, in: CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height))
    }
    image = context.makeImage()
  }

  private func fingerprint(_ view: NSView) -> String {
    let selector = NSSelectorFromString("fullScreenBackdropSignature")
    let drawing = view.responds(to: selector) ? view.value(forKey: "fullScreenBackdropSignature") as? String ?? "" : ""
    return drawing + "\(ObjectIdentifier(view)):\(view.bounds):\(view.frame):\(view.alphaValue):\(view.isHidden):\(view.effectiveAppearance.name):" +
      (view.layer.map { fingerprint($0) } ?? "") + view.subviews.map { fingerprint($0) }.joined(separator: ";")
  }

  private func fingerprint(_ layer: CALayer) -> String {
    var value = "\(layer.bounds):\(layer.position):\(layer.backgroundColor.debugDescription):\(layer.opacity):\(layer.isHidden):\(layer.contents.debugDescription)"
    if let gradient = layer as? CAGradientLayer {
      value += "\(gradient.colors.debugDescription):\(gradient.locations.debugDescription):\(gradient.startPoint):\(gradient.endPoint)"
    }
    return value + (layer.sublayers ?? []).map { fingerprint($0) }.joined(separator: ";")
  }
}

@MainActor
final class FullScreenIslandScrim: NSView {
  enum Shape: Equatable { case corner, edge, horizontal }
  private let fill = CALayer()
  private let horizontalMask = CAGradientLayer()
  private let verticalMask = CAGradientLayer()
  private let shape: Shape

  init(_ shape: Shape = .corner) {
    self.shape = shape
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(fill)
    for mask in [horizontalMask, verticalMask] {
      mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
      mask.locations = [0, 0.45, 1]
    }
    horizontalMask.startPoint = CGPoint(x: 0, y: 0.5)
    horizontalMask.endPoint = CGPoint(x: 1, y: 0.5)
    verticalMask.startPoint = CGPoint(x: 0.5, y: 0)
    verticalMask.endPoint = CGPoint(x: 0.5, y: 1)
    horizontalMask.mask = verticalMask
    layer?.mask = horizontalMask
    layer?.masksToBounds = true
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func place(_ rect: CGRect?, opacity: CGFloat, source: NSView?, sample: FullScreenIslandBackdropSample) {
    isHidden = rect == nil || opacity <= 0 || sample.image == nil
    guard let rect, let source, !isHidden else {
      fill.contents = nil
      return
    }
    frame = rect
    fill.contents = sample.image
    fill.frame = convert(sample.bounds, from: source)
    horizontalMask.frame = bounds
    verticalMask.frame = bounds
    if shape == .horizontal {
      verticalMask.locations = [0, 0.15, 0.65, 1]
      verticalMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    }
    alphaValue = opacity
  }
}

@MainActor
private final class FullScreenIslandGlyphsView: NSView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class FullScreenIslandButtonGlyph {
  weak var button: NSButton?
  let layer = CALayer()
  let glyph = CAShapeLayer()

  init(_ button: NSButton, kind: NSWindow.ButtonType, owner: NSView) {
    self.button = button
    layer.actions = SurfaceLayer.noActions
    glyph.actions = SurfaceLayer.noActions
    glyph.fillColor = nil
    glyph.strokeColor = NSColor.black.withAlphaComponent(0.65).cgColor
    glyph.lineWidth = 1.1
    glyph.lineCap = .round
    glyph.lineJoin = .round
    let path = CGMutablePath()
    switch kind {
    case .closeButton:
      path.move(to: CGPoint(x: 4.5, y: 4.5))
      path.addLine(to: CGPoint(x: 9.5, y: 9.5))
      path.move(to: CGPoint(x: 4.5, y: 9.5))
      path.addLine(to: CGPoint(x: 9.5, y: 4.5))
    case .miniaturizeButton:
      path.move(to: CGPoint(x: 3.5, y: 7))
      path.addLine(to: CGPoint(x: 10.5, y: 7))
    default:
      path.move(to: CGPoint(x: 3.5, y: 3.5))
      path.addLine(to: CGPoint(x: 6, y: 6))
      path.move(to: CGPoint(x: 3.5, y: 6))
      path.addLine(to: CGPoint(x: 6, y: 6))
      path.addLine(to: CGPoint(x: 6, y: 3.5))
      path.move(to: CGPoint(x: 10.5, y: 10.5))
      path.addLine(to: CGPoint(x: 8, y: 8))
      path.move(to: CGPoint(x: 8, y: 10.5))
      path.addLine(to: CGPoint(x: 8, y: 8))
      path.addLine(to: CGPoint(x: 10.5, y: 8))
    }
    glyph.path = path
    layer.addSublayer(glyph)
    owner.layer?.addSublayer(layer)
  }

  func update(hovered: Bool) {
    guard let button else { return }
    layer.frame = button.frame
    glyph.frame = button.bounds
    glyph.contentsScale = max(1, button.window?.backingScaleFactor ?? 2)
    glyph.isHidden = !hovered
  }
}

@MainActor
final class FullScreenIslandButtonsView: NSView {
  private var tracking: NSTrackingArea?
  private var glyphs: [FullScreenIslandButtonGlyph] = []
  private let glyphsView = FullScreenIslandGlyphsView()
  private(set) var groupHovered = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(pointerChanged(_:)))
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { point(event.locationInWindow) }
  override func mouseMoved(with event: NSEvent) { point(event.locationInWindow) }
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  override func viewDidHide() {
    super.viewDidHide()
    clearRollover()
  }

  func mouseInGroup(_ button: NSButton) -> Bool {
    groupHovered && button.isEnabled
  }

  func register(_ button: NSButton, kind: NSWindow.ButtonType) {
    addSubview(glyphsView, positioned: .above, relativeTo: nil)
    glyphs.append(FullScreenIslandButtonGlyph(button, kind: kind, owner: glyphsView))
  }

  func refreshRendering() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyphsView.frame = bounds
    for glyph in glyphs { glyph.update(hovered: groupHovered) }
    CATransaction.commit()
  }

  func refreshRollover() {
    guard let window else { return clearRollover() }
    point(window.convertPoint(fromScreen: DevPointer.screenPoint(in: window)))
  }

  func clearRollover() { setHovered(false) }

  @objc private func pointerChanged(_ note: Notification) {
    guard let window else { return clearRollover() }
    if note.name == DevPointer.fullScreenChanged,
      let source = note.userInfo?["window"] as? NSWindow, source !== window { return }
    guard let screen = (note.object as? NSValue)?.pointValue else { return clearRollover() }
    point(window.convertPoint(fromScreen: screen))
  }

  private func point(_ pointInWindow: NSPoint) {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return clearRollover() }
    let local = convert(pointInWindow, from: nil)
    setHovered(CGPath(roundedRect: bounds, cornerWidth: 16.5, cornerHeight: 16.5, transform: nil).contains(local))
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != groupHovered else { return }
    groupHovered = hovered
    for button in subviews.compactMap({ $0 as? NSButton }) {
      button.needsDisplay = true
      button.displayIfNeeded()
    }
    refreshRendering()
  }
}

@objc(SolaraFullScreenIsland)
public final class FullScreenIslandView: NSView {
  private let corner = FullScreenIslandScrim(.corner)
  private let edge = FullScreenIslandScrim(.edge)
  private let horizontal = FullScreenIslandScrim(.horizontal)
  private let sample = FullScreenIslandBackdropSample()
  private let glass = NSGlassEffectView()
  private let buttons = FullScreenIslandButtonsView()
  private var minimizeButton: NSButton?
  private weak var shell: WindowShellView?
  private var fullscreen = false
  #if DEBUG
  private var lastUpdate: (page: Bool, closeCenter: CGPoint, windowedButtons: [NSValue])?
  private var slideOffset: CGFloat = 0
  #endif

  public override var isFlipped: Bool { true }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    glass.contentView = buttons
    glass.style = .clear
    glass.appearance = NSAppearance(named: .darkAqua)
    buttons.wantsLayer = true
    buttons.layer?.backgroundColor = NSColor(srgbRed: 34 / 255, green: 52 / 255, blue: 72 / 255, alpha: 0.9).cgColor
    buttons.layer?.borderColor = NSColor(srgbRed: 57 / 255, green: 74 / 255, blue: 93 / 255, alpha: 1).cgColor
    buttons.layer?.cornerRadius = 16.5
    addSubview(edge)
    addSubview(corner)
    addSubview(horizontal)
    addSubview(glass)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
      if kind == .miniaturizeButton { minimizeButton = button }
      button.target = self
      button.action = kind == .closeButton ? #selector(closeWindow(_:))
        : kind == .miniaturizeButton ? #selector(minimizeWindow(_:)) : #selector(toggleFullscreen(_:))
      buttons.addSubview(button)
      buttons.register(button, kind: kind)
    }
    isHidden = true
  }

  public required init?(coder: NSCoder) { nil }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }
    let local = convert(point, from: superview)
    let inside = glass.convert(local, from: self)
    guard CGPath(roundedRect: glass.bounds, cornerWidth: 16.5, cornerHeight: 16.5, transform: nil).contains(inside) else { return nil }
    return glass.hitTest(local) ?? glass
  }

  public override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil {
      isHidden = true
      buttons.clearRollover()
      FullScreenIslandCoverage.remove(self, from: window)
      publishHoverCoverage(in: window)
      shell?.applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
      shell = nil
      clearBackdrop()
    }
    super.viewWillMove(toSuperview: newSuperview)
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow {
      isHidden = true
      buttons.clearRollover()
      FullScreenIslandCoverage.remove(self, from: window)
      publishHoverCoverage(in: window)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    FullScreenIslandCoverage.register(self, in: window)
    publishHoverCoverage(in: window)
  }

  func blocksHover(at point: NSPoint) -> Bool {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0, window != nil else { return false }
    let local = glass.convert(point, from: nil)
    return CGPath(roundedRect: glass.bounds, cornerWidth: 16.5, cornerHeight: 16.5, transform: nil).contains(local)
  }

  private func publishHoverCoverage(in window: NSWindow?) {
    guard let window else { return }
    let screen = NSValue(point: DevPointer.screenPoint(in: window))
    NotificationCenter.default.post(name: Notification.Name("SolaraFullScreenPointerChanged"), object: screen, userInfo: ["window": window])
    shell?.coverChanged()
  }

  private func findShell(in view: NSView) -> WindowShellView? {
    if let shell = view as? WindowShellView { return shell }
    for child in view.subviews {
      if let shell = findShell(in: child) { return shell }
    }
    return nil
  }

  private func leadingProfileNameShown(in view: NSView, header: CGRect) -> Bool {
    guard !view.isHidden else { return false }
    if view is StripProfileIndicator {
      return view.subviews.compactMap { $0 as? StripLabel }.contains {
        !$0.isHidden && !$0.stringValue.isEmpty && convert($0.bounds, from: $0).intersects(header)
      }
    }
    return view.subviews.contains { leadingProfileNameShown(in: $0, header: header) }
  }

  @objc(updateFullscreen:page:reveal:menuBottom:closeCenter:windowedButtons:)
  public func update(fullscreen: Bool, page: Bool, reveal: CGFloat, menuBottom: CGFloat, closeCenter: CGPoint, windowedButtons: [NSValue]) {
    guard let parent = superview else { return }
    self.fullscreen = fullscreen
    #if DEBUG
    lastUpdate = (page, closeCenter, windowedButtons)
    #endif
    FullScreenIslandCoverage.register(self, in: window)
    let previousFrame = glass.frame
    let previouslyHidden = isHidden
    if shell?.window !== window || shell?.superview == nil { shell = findShell(in: window?.contentView ?? parent) }
    shell?.applyFullScreenReveal(fullscreen: fullscreen, page: page, reveal: reveal, menuBottom: menuBottom)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      if glass.frame != previousFrame || isHidden != previouslyHidden { publishHoverCoverage(in: window) }
      for button in buttons.subviews.compactMap({ $0 as? NSButton }) {
        button.isEnabled = !self.fullscreen || button !== minimizeButton
      }
      buttons.refreshRendering()
    }
    frame = parent.bounds
    var center = closeCenter
    if let shell {
      let header = convert(shell.fullScreenHeaderRect, from: shell)
      center.y = header.midY
    }
    let progress = min(1, max(0, reveal))
    let displacement = shell?.fullScreenStripOffset ?? max(0, menuBottom) * progress
    let layout = FullScreenIslandPlacement(fullscreen: fullscreen, page: page, reveal: reveal,
      menuBottom: progress > 0 ? displacement / progress : 0, closeCenter: center,
                                           windowedButtons: windowedButtons.map(\.rectValue))
    #if DEBUG
    slideOffset = layout.slideOffset
    #endif
    guard let placement = layout.frame else {
      isHidden = true
      buttons.clearRollover()
      clearBackdrop()
      return
    }
    glass.frame = placement
    glass.cornerRadius = placement.height / 2
    glass.alphaValue = 1
    buttons.frame = glass.bounds
    buttons.layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
    for (button, rect) in zip(buttons.subviews.compactMap({ $0 as? NSButton }), layout.buttonFrames) { button.frame = rect }
    if let shell {
      let header = convert(shell.fullScreenHeaderRect, from: shell)
      let sidebar = shell.input.dock > 0 && shell.input.sidebarSide == .left
        ? convert(shell.frames.sidebar ?? .zero, from: shell) : .zero
      let leadingSlot = CGRect(x: placement.minX, y: header.minY, width: placement.width, height: header.height)
      let named = shell.fullScreenProfileNameShown || shell.view(in: .topStrip).map { leadingProfileNameShown(in: $0, header: leadingSlot) } == true
      let backdrop = FullScreenIslandBackdropPlacement(topTabs: shell.input.topTabs, profileName: named,
        sidebar: sidebar, header: header, offset: shell.fullScreenStripOffset)
      if backdrop.corner != nil || backdrop.edge != nil || backdrop.horizontal != nil {
        sample.update([shell.view(in: .backdrop), shell.view(in: .tint)].compactMap { $0 }, in: shell)
      } else {
        sample.clear()
      }
      corner.place(backdrop.corner, opacity: progress, source: shell, sample: sample)
      edge.place(backdrop.edge, opacity: progress, source: shell, sample: sample)
      horizontal.place(backdrop.horizontal, opacity: progress, source: shell, sample: sample)
    } else {
      clearBackdrop()
    }
    isHidden = false
    buttons.refreshRollover()
  }

  #if DEBUG
  public func devSnapshot(_ path: String) -> Bool {
    guard !isHidden else { return false }
    glass.layoutSubtreeIfNeeded()
    buttons.displayIfNeeded()
    guard let bitmap = buttons.bitmapImageRepForCachingDisplay(in: buttons.bounds) else { return false }
    buttons.cacheDisplay(in: buttons.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  public func devReveal(_ reveal: CGFloat, menuBottom: CGFloat, fullscreen: Bool) -> [String: Any] {
    guard let lastUpdate else { return ["error": "No caption layout"] }
    update(fullscreen: fullscreen, page: lastUpdate.page, reveal: reveal, menuBottom: menuBottom,
      closeCenter: lastUpdate.closeCenter, windowedButtons: lastUpdate.windowedButtons)
    func rect(_ value: CGRect) -> [String: CGFloat] {
      ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    func components(_ value: CGColor?) -> [CGFloat] {
      guard let value, let color = NSColor(cgColor: value)?.usingColorSpace(.sRGB) else { return [] }
      return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
    return ["frame": rect(glass.frame), "radius": glass.cornerRadius, "alpha": glass.alphaValue,
      "hidden": isHidden, "buttonFrames": buttons.subviews.compactMap { $0 as? NSButton }.map { rect($0.frame) },
      "enabled": buttons.subviews.compactMap { ($0 as? NSButton)?.isEnabled }, "slideOffset": slideOffset,
      "windowFullscreen": fullscreen, "borderWidth": buttons.layer?.borderWidth ?? 0,
      "groupHovered": buttons.groupHovered,
      "rollover": buttons.subviews.compactMap { ($0 as? NSButton).map { buttons.mouseInGroup($0) } },
      "fill": components(buttons.layer?.backgroundColor), "rim": components(buttons.layer?.borderColor)]
  }
  #endif

  private func clearBackdrop() {
    sample.clear()
    for scrim in [corner, edge, horizontal] { scrim.place(nil, opacity: 0, source: nil, sample: sample) }
  }

  @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
  @objc private func minimizeWindow(_ sender: Any?) {
    guard !fullscreen else { return }
    window?.performMiniaturize(sender)
  }
  @objc private func toggleFullscreen(_ sender: Any?) { window?.toggleFullScreen(sender) }
}
