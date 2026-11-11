import AppKit
import QuartzCore

@MainActor
public final class ToolbarView: NSView {
  static let buttonTop: CGFloat = 21.2 - 15
  static let bandEase = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)

  public var onClick: (ToolbarClick) -> Void = { _ in }
  public var onAnchors: ([String: CGRect]) -> Void = { _ in }
  public var onHiddenOrDetached: () -> Void = {}
  public var onGeometryChange: () -> Void = {}
  public private(set) var state: ToolbarState?

  private let surface = CALayer()
  private let under = CALayer()
  private let band = CALayer()
  private let stripes = CALayer()
  private let surfaceFade = CAGradientLayer()
  private var stripesUri: String?
  private var stripesTask: Task<Void, Never>?
  private let content = ToolbarContentView()
  private let hairline = CALayer()
  private let progress = CALayer()
  private var left: [ToolbarButtonView] = []
  private var right: [ToolbarButtonView] = []
  private var extensions: [ToolbarButtonView] = []
  private var reportedAnchors: [String: CGRect]?
  private let url = ToolbarUrlFieldView()
  private let updatePill = SidebarUpdatePill()
  static let updatePillHeight: CGFloat = 24
  static let updatePillPadding: CGFloat = 12
  static let updatePillGap: CGFloat = 6
  static let urlRoomBesideUpdate: CGFloat = 300
  static let urlRoomBesideShortUpdate: CGFloat = 120
  private var bandColor: CGColor?
  private var shownProgress: Double?
  private var interactive = true
  private var autoHideScale: CGFloat = 1
  private var autoHideLift: CGFloat = 0

  public override var isFlipped: Bool { true }

  public var sitsOnWindowFrame: Bool {
    guard let state else { return false }
    let promotedSplit = superview is SplitPanesView && (windowShell?.railFraction ?? 0) > 0
    return state.windowToolbar == true || (state.bare && state.inSplit != true) || promotedSplit || windowShell?.toolbarSitsOnFrame(self) == true
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(surface)
    surface.addSublayer(under)
    surface.addSublayer(band)
    stripes.anchorPoint = .zero
    stripes.contentsGravity = .topLeft
    surfaceFade.startPoint = CGPoint(x: 0, y: 0.5)
    surfaceFade.endPoint = CGPoint(x: 1, y: 0.5)
    surface.addSublayer(stripes)
    addSubview(content)
    content.addSubview(url)
    url.onClick = { [weak self] click in self?.onClick(click) }
    updatePill.isHidden = true
    updatePill.onPress = { [weak self] in self?.onClick(ToolbarClick(id: "update", kind: .press)) }
    content.addSubview(updatePill)
    layer?.addSublayer(hairline)
    progress.anchorPoint = .zero
    layer?.addSublayer(progress)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func setAutoHide(opacity: CGFloat, scale: CGFloat, lift: CGFloat, interactive: Bool) {
    self.interactive = interactive
    alphaValue = opacity
    autoHideScale = scale
    autoHideLift = lift
    applyAutoHideTransform()
  }

  private func applyAutoHideTransform() {
    guard let layer else { return }
    let cx = bounds.midX, cy = bounds.midY
    var t = CATransform3DMakeTranslation(cx, cy - autoHideLift, 0)
    t = CATransform3DScale(t, autoHideScale, autoHideScale, 1)
    t = CATransform3DTranslate(t, -cx, -cy, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.sublayerTransform = autoHideScale == 1 && autoHideLift == 0 ? CATransform3DIdentity : t
    CATransaction.commit()
  }

  public func placeBackdrop(_ backdrop: NSView) {
    if let strip = backdrop as? AutoHideStripView { strip.frameSurface = sitsOnWindowFrame }
    guard let parent = superview else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let height = min(frame.height, ShellMetrics.toolbarHeight)
    backdrop.frame = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    backdrop.autoresizingMask = autoresizingMask.contains(.width) ? [.width] : []
    let index = parent.subviews.firstIndex(of: self)
    let belowToolbar = index.flatMap { $0 > 0 ? parent.subviews[$0 - 1] : nil }
    if backdrop.superview !== parent || belowToolbar !== backdrop {
      parent.addSubview(backdrop, positioned: .below, relativeTo: self)
    }
    backdrop.needsLayout = true
    backdrop.layoutSubtreeIfNeeded()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard interactive else { return nil }
    let hit = super.hitTest(point)
    return hit === self || hit === content ? nil : hit
  }

  public func update(_ next: ToolbarState) {
    let previous = state
    state = next
    left = sync(left, next.left, next.palette)
    right = sync(right, next.right, next.palette)
    extensions = sync(extensions, next.extensions ?? [], next.palette)
    if let u = next.url {
      url.isHidden = false
      url.update(u, palette: next.palette)
    } else {
      url.isHidden = true
    }
    applySurface(animated: previous != nil)
    if previous?.focused != next.focused {
      let to: CGFloat = next.focused ? 1 : 0.5
      if previous == nil {
        content.alphaValue = to
      } else {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.16
          ctx.timingFunction = ToolbarView.bandEase
          content.animator().alphaValue = to
        }
      }
    }
    applyProgress(next.progress, color: toolbarColor(next.palette.background != nil ? next.palette.icon : next.accent))
    needsLayout = true
  }

  private func sync(_ views: [ToolbarButtonView], _ specs: [ToolbarButtonState], _ palette: ToolbarPaletteState) -> [ToolbarButtonView] {
    var out: [ToolbarButtonView] = []
    for (i, spec) in specs.enumerated() {
      if i < views.count, views[i].state.id == spec.id {
        views[i].state = spec
        views[i].palette = palette
        out.append(views[i])
      } else {
        let made = ToolbarButtonView(state: spec, palette: palette)
        made.onClick = { [weak self, weak made] click in
          guard let self else { return }
          if click.kind == .press, let made, let info = made.state.info {
            ToolbarInfoPopover.show(info, relativeTo: made) { [weak self] in self?.onClick(ToolbarClick(id: info.actionId, kind: .press)) }
            return
          }
          self.onClick(click)
        }
        content.addSubview(made)
        out.append(made)
      }
    }
    for v in views where !out.contains(where: { $0 === v }) { v.removeFromSuperview() }
    return out
  }

  private func applySurface(animated: Bool) {
    guard let state else { return }
    let frame = sitsOnWindowFrame
    let shown = !state.bare && !frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    under.backgroundColor = frame ? nil : underColor
    hairline.isHidden = frame || !state.hairline
    hairline.backgroundColor = frame ? nil : toolbarColor(state.palette.divider)?.cgColor
    if frame { band.removeAnimation(forKey: "backgroundColor") }
    CATransaction.commit()
    applyBand(shown ? toolbarColor(state.palette.background)?.cgColor : nil, animated: animated && !frame)
    applyStripes(shown ? state.stripes : nil)
  }

  private func applyBand(_ color: CGColor?, animated: Bool) {
    guard color != bandColor else { return }
    let from = bandColor ?? color?.copy(alpha: 0)
    let to = color ?? bandColor?.copy(alpha: 0)
    bandColor = color
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.backgroundColor = color
    CATransaction.commit()
    guard animated, let from, let to else { return }
    let animation = CABasicAnimation(keyPath: "backgroundColor")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = 0.18
    animation.timingFunction = ToolbarView.bandEase
    band.add(animation, forKey: "backgroundColor")
  }

  private func applyStripes(_ uri: String?) {
    guard uri != stripesUri else { return }
    stripesTask?.cancel()
    stripesUri = uri
    let image = uri.flatMap(ToolbarView.localStripesImage)
    setStripes(image)
    guard let uri, image == nil else { return }
    stripesTask = Task { [weak self] in
      let image = await ToolbarView.stripesImage(uri)
      guard let self, !Task.isCancelled, self.stripesUri == uri else { return }
      self.setStripes(image)
    }
  }

  private func setStripes(_ image: NSImage?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    stripes.contents = image
    stripes.contentsScale = window?.backingScaleFactor ?? 2
    stripes.isHidden = image == nil
    CATransaction.commit()
  }

  public var underColor: CGColor? {
    didSet {
      guard underColor != oldValue else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      under.backgroundColor = sitsOnWindowFrame ? nil : underColor
      CATransaction.commit()
    }
  }

  private func fadeSurface(rail: CGFloat) {
    let width = bounds.width
    guard rail > 0, width > 0 else {
      if surface.mask != nil { surface.mask = nil }
      return
    }
    let mask = ShellMetrics.railBandMask(width: width, edge: 1 - rail)
    surfaceFade.frame = surface.bounds
    surfaceFade.colors = mask.map { NSColor(white: 0, alpha: $0.alpha).cgColor }
    surfaceFade.locations = mask.map { NSNumber(value: Double($0.location / width)) }
    if surface.mask !== surfaceFade { surface.mask = surfaceFade }
  }

  private static let stripesSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    return URLSession(configuration: configuration)
  }()

  static func localStripesImage(_ uri: String) -> NSImage? {
    let url = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : URL(string: uri)
    guard let url, url.isFileURL, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: 2560, height: 50)
    return image
  }

  static func stripesImage(_ uri: String) async -> NSImage? {
    if let image = localStripesImage(uri) { return image }
    guard let url = URL(string: uri), url.scheme == "http" || url.scheme == "https" else { return nil }
    let request = URLRequest(url: url, timeoutInterval: 10)
    guard let (data, _) = try? await stripesSession.data(for: request), !Task.isCancelled, let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: 2560, height: 50)
    return image
  }

  public var urlEditView: NSView? { url.editorView }

  private func applyProgress(_ value: Double?, color: NSColor?) {
    guard let value else {
      progress.isHidden = true
      shownProgress = nil
      return
    }
    let to = max(value, 0.08)
    let width = bounds.width * to
    progress.isHidden = false
    progress.backgroundColor = color?.cgColor
    progress.opacity = 0.85
    let fromWidth = shownProgress.map { bounds.width * max($0, 0.08) } ?? width
    shownProgress = value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progress.bounds = CGRect(x: 0, y: 0, width: width, height: 1.5)
    CATransaction.commit()
    guard fromWidth != width else { return }
    let animation = CABasicAnimation(keyPath: "bounds.size.width")
    animation.fromValue = fromWidth
    animation.toValue = width
    animation.duration = 0.2
    animation.timingFunction = ToolbarView.bandEase
    progress.add(animation, forKey: "width")
  }

  public override func layout() {
    super.layout()
    guard let state else { return }
    applyAutoHideTransform()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    under.frame = surface.bounds
    band.frame = surface.bounds
    stripes.frame = CGRect(x: 0, y: 0, width: 2560, height: 50)
    layer?.masksToBounds = true
    let scale = window?.backingScaleFactor ?? 2
    let rail = windowShell?.railFraction ?? 0
    applySurface(animated: false)
    hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    hairline.opacity = Float(1 - rail)
    progress.position = CGPoint(x: 0, y: bounds.height - 1.5)
    if let shownProgress { progress.bounds.size.width = bounds.width * max(shownProgress, 0.08) }
    CATransaction.commit()
    let contentTop = max(0, bounds.height - ShellMetrics.toolbarHeight)
    content.frame = CGRect(x: 0, y: contentTop, width: bounds.width, height: bounds.height - contentTop)
    let px = { (v: CGFloat) in (v * scale).rounded() / scale }
    let top = px(ToolbarView.buttonTop)
    let inset = CGFloat(state.leadingInset ?? 0) + rail * ShellMetrics.railToolbarLeadingInset
    let g = state.geometry
    let centers = [g.sidebarButton, g.back, g.forward, g.reload]
    let ids = ["sidebar", "back", "forward", "reload"]
    for b in left {
      let center = ids.firstIndex(of: b.state.id).flatMap { centers[$0] } ?? nil
      guard let center else { continue }
      b.frame = CGRect(x: px(CGFloat(center) + inset - 15), y: top, width: 30, height: 30)
    }
    var x = bounds.width - CGFloat(state.rightInset)
    for b in right.reversed() {
      x -= b.box
      b.frame = CGRect(x: px(x), y: top, width: b.box, height: b.box)
      x += 2
    }
    url.frame = CGRect(x: CGFloat(g.urlLeft) + inset, y: ToolbarView.buttonTop, width: max(0, content.bounds.width - CGFloat(g.urlLeft) - inset - CGFloat(g.urlRight)), height: ToolbarUrlFieldView.height)
    for b in left + right + extensions { b.recheckHover() }
    var anchors: [String: CGRect] = [:]
    var trailingEdge = x
    if let extensionsRight = state.extensionsRight {
      var ex = bounds.width - CGFloat(extensionsRight)
      for b in extensions.reversed() {
        ex -= b.width
        b.frame = CGRect(x: px(ex), y: px(21.2 - b.box / 2), width: b.width, height: b.box)
        if let slot = b.state.anchor { anchors[slot] = windowRect(b.frame) }
        ex -= 2
      }
      if extensions.isEmpty {
        anchors["*"] = windowRect(CGRect(x: px(ex - 28), y: px(21.2 - 14), width: 28, height: 28))
      }
      trailingEdge = min(trailingEdge, ex + 2)
      if extensions.contains(where: { $0.state.label != nil }), url.frame.maxX > trailingEdge - ToolbarView.updatePillGap {
        url.frame.size.width = max(0, trailingEdge - ToolbarView.updatePillGap - url.frame.minX)
      }
    }
    layoutUpdatePill(state, trailingEdge: trailingEdge, px: px)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeSurface(rail: rail)
    CATransaction.commit()
    if window != nil, anchors != reportedAnchors {
      reportedAnchors = anchors
      onAnchors(anchors)
    }
  }

  private func layoutUpdatePill(_ state: ToolbarState, trailingEdge: CGFloat, px: (CGFloat) -> CGFloat) {
    guard let update = state.update else {
      updatePill.isHidden = true
      return
    }
    let font = NSFont.systemFont(ofSize: SidebarUpdatePillMetrics.fontSize, weight: .medium)
    let measure = { (text: String) in ceil((text as NSString).size(withAttributes: [.font: font]).width) + ToolbarView.updatePillPadding * 2 }
    let right = trailingEdge - ToolbarView.updatePillGap
    let room = right - CGFloat(state.geometry.urlLeft) - ToolbarView.urlRoomBesideUpdate
    let long = measure(update.text)
    let short = measure(update.short)
    let fitsShort = short <= room + ToolbarView.urlRoomBesideUpdate - ToolbarView.urlRoomBesideShortUpdate
    guard long <= room || fitsShort else {
      updatePill.isHidden = true
      return
    }
    let text = long <= room ? update.text : update.short
    let width = text == update.text ? long : short
    let height = ToolbarView.updatePillHeight
    updatePill.set(SidebarUpdatePillState(text: text, tooltip: update.tooltip), color: toolbarColor(state.palette.text) ?? .labelColor, dark: ToolbarView.isLightInk(state.palette.text))
    updatePill.frame = CGRect(x: px(right - width), y: px(21.2 - height / 2), width: width, height: height)
    updatePill.isHidden = false
    updatePill.recheckHover()
    let urlRight = updatePill.frame.minX - ToolbarView.updatePillGap
    if url.frame.maxX > urlRight { url.frame.size.width = max(0, urlRight - url.frame.minX) }
  }

  static func isLightInk(_ text: String) -> Bool {
    guard let color = toolbarColor(text)?.usingColorSpace(.sRGB) else { return true }
    return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent > 0.5
  }

  public func describeExtensions() -> [[String: Any]] {
    extensions.map { b in
      let r = windowRect(b.frame)
      return ["id": b.state.id, "label": b.state.label as Any? ?? NSNull(), "frame": [r.minX, r.minY, r.width, r.height]]
    }
  }

  private func windowRect(_ local: CGRect) -> CGRect {
    guard let root = window?.contentView else { return local }
    let r = content.convert(local, to: root)
    return root.isFlipped ? r : CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  public override func viewDidHide() {
    super.viewDidHide()
    onHiddenOrDetached()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { onHiddenOrDetached() }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reportedAnchors = nil
    needsLayout = true
  }
}

final class ToolbarContentView: NSView {
  override var isFlipped: Bool { true }
}
