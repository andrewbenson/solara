import AppKit

struct FullScreenIslandPlacement {
  let frame: CGRect?
  let buttonFrames: [CGRect]

  init(fullscreen: Bool, page: Bool, reveal: CGFloat, menuBottom: CGFloat, closeCenter: CGPoint, windowedButtons: [CGRect]) {
    let progress = min(1, max(0, reveal))
    guard fullscreen, !page, progress > 0, let close = windowedButtons.first else {
      frame = nil
      buttonFrames = []
      return
    }
    let anchored = windowedButtons.map { rect in
      rect.offsetBy(dx: closeCenter.x - close.midX, dy: closeCenter.y - close.midY)
    }
    let group = anchored.reduce(CGRect.null) { $0.union($1) }
    guard !group.isNull, !group.isEmpty else {
      frame = nil
      buttonFrames = []
      return
    }
    let capsule = group.insetBy(dx: -4, dy: -4)
    frame = capsule.offsetBy(dx: 0, dy: max(0, menuBottom) * progress)
    buttonFrames = anchored.map {
      CGRect(x: $0.minX - capsule.minX, y: capsule.maxY - $0.maxY, width: $0.width, height: $0.height)
    }
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

@objc(SolaraFullScreenIsland)
public final class FullScreenIslandView: NSView {
  private let corner = FullScreenIslandScrim(.corner)
  private let edge = FullScreenIslandScrim(.edge)
  private let horizontal = FullScreenIslandScrim(.horizontal)
  private let sample = FullScreenIslandBackdropSample()
  private let glass = NSGlassEffectView()
  private let buttons = NSView()
  private weak var shell: WindowShellView?

  public override var isFlipped: Bool { true }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    glass.contentView = buttons
    addSubview(edge)
    addSubview(corner)
    addSubview(horizontal)
    addSubview(glass)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
      button.target = self
      button.action = kind == .closeButton ? #selector(closeWindow(_:))
        : kind == .miniaturizeButton ? #selector(minimizeWindow(_:)) : #selector(toggleFullscreen(_:))
      buttons.addSubview(button)
    }
    isHidden = true
  }

  public required init?(coder: NSCoder) { nil }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }
    return glass.hitTest(convert(point, from: superview))
  }

  public override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil {
      shell?.applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
      shell = nil
      clearBackdrop()
    }
    super.viewWillMove(toSuperview: newSuperview)
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
    if shell?.window !== window || shell?.superview == nil { shell = findShell(in: window?.contentView ?? parent) }
    shell?.applyFullScreenReveal(fullscreen: fullscreen, page: page, reveal: reveal, menuBottom: menuBottom)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
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
    guard let placement = layout.frame else {
      isHidden = true
      clearBackdrop()
      return
    }
    glass.frame = placement
    glass.cornerRadius = placement.height / 2
    glass.alphaValue = progress
    buttons.frame = glass.bounds
    for (button, rect) in zip(buttons.subviews, layout.buttonFrames) { button.frame = rect }
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
  }

  private func clearBackdrop() {
    sample.clear()
    for scrim in [corner, edge, horizontal] { scrim.place(nil, opacity: 0, source: nil, sample: sample) }
  }

  @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
  @objc private func minimizeWindow(_ sender: Any?) { window?.performMiniaturize(sender) }
  @objc private func toggleFullscreen(_ sender: Any?) { window?.toggleFullScreen(sender) }
}
