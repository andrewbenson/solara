import AppKit
import QuartzCore
#if SOLARA_PROBES
import SolaraProbes
#endif

public struct OmniboxPanelStyle: Equatable, Sendable {
  public var fill: CSSColor
  public var border: CSSColor
  public var shadowOpacity: Double
  public var radius: CGFloat

  public init(fill: CSSColor, border: CSSColor, shadowOpacity: Double, radius: CGFloat) {
    self.fill = fill
    self.border = border
    self.shadowOpacity = shadowOpacity
    self.radius = radius
  }
}

public struct OmniboxPanelPlacement: Equatable, Sendable {
  public var left: CGFloat
  public var top: CGFloat
  public var width: CGFloat
  public var from: CGRect?

  public init(left: CGFloat, top: CGFloat, width: CGFloat, from: CGRect?) {
    self.left = left
    self.top = top
    self.width = width
    self.from = from
  }
}

@MainActor
public final class OmniboxPanelHostView: NSView {
  public static let growDuration: CFTimeInterval = 0.13
  static let growCurve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

  public let bar: OmniboxBarView
  public var onOutside: (NSEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  public private(set) var shown = false
  public private(set) var identity: OmniboxBarIdentity?
  private let surface = CALayer()
  private let mask = CALayer()
  private let glassSurface = NewTabGlassSurface(frame: .zero)
  private var glassLink: CADisplayLink?
  private lazy var glassTarget = GlassFrameTarget(self)
  private var placement: OmniboxPanelPlacement?
  private var height: CGFloat = 107
  private var monitor: Any?
  private var prepared: OmniboxBarIdentity?
  private var preparing = 0

  public override var isFlipped: Bool { true }

  public init(bar: OmniboxBarView) {
    self.bar = bar
    super.init(frame: .zero)
    wantsLayer = true
    isHidden = true
    bar.activatesOnWindow = false
    bar.autoresizingMask = []
    bar.wantsLayer = true
    mask.backgroundColor = NSColor.black.cgColor
    bar.layer?.mask = mask
    layer?.addSublayer(surface)
    addSubview(glassSurface)
    glassSurface.foreground.addSubview(bar)
    bar.onHeight = { [weak self] h in self?.barHeight(h) }
  }

  required init?(coder: NSCoder) { fatalError() }

  public var style = OmniboxPanelStyle(fill: CSSColor("#FFFFFF")!, border: CSSColor("rgba(0,0,0,0.1)")!, shadowOpacity: 0.2, radius: 17) {
    didSet { if style != oldValue { applyStyle() } }
  }

  private func applyStyle() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.cornerRadius = style.radius
    mask.cornerRadius = style.radius
    CATransaction.commit()
    syncGlass()
  }

  public func show(_ next: OmniboxPanelPlacement, identity nextIdentity: OmniboxBarIdentity) {
    if shown, identity == nextIdentity {
      if placement != next {
        placement = next
        layoutPanel(animatedFrom: nil)
      }
      return
    }
    identity = nextIdentity
    placement = next
    applyStyle()
    if prepared != nextIdentity { bar.configure(nextIdentity, fresh: true) }
    prepared = nil
    preparing += 1
    shown = true
    isHidden = false
    layoutPanel(animatedFrom: next.from)
    bar.activate()
    watchOutside()
  }

  public func prepare(_ next: OmniboxPanelPlacement, identity nextIdentity: OmniboxBarIdentity) {
    guard !shown else { return }
    placement = next
    guard prepared != nextIdentity else { return }
    preparing += 1
    let generation = preparing
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.shown, self.preparing == generation else { return }
        self.prepared = nextIdentity
        self.bar.configure(nextIdentity, fresh: true)
        self.layoutPanel(animatedFrom: nil)
        self.bar.layoutSubtreeIfNeeded()
      }
    }
  }

  public func hide() {
    guard shown else { return }
    shown = false
    finishGlassAnimation()
    identity = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if bar.model?.field?.hasFocus == true, let window {
      NotificationCenter.default.post(name: Notification.Name("SolaraBarRemovedWithFocus"), object: window)
      window.makeFirstResponder(nil)
    }
    isHidden = true
  }

  private var panelFrame: CGRect {
    guard let placement else { return .zero }
    return CGRect(x: placement.left, y: placement.top, width: placement.width, height: height)
  }

  private func barHeight(_ h: CGFloat) {
    onHeight(h)
    guard h > 0, h != height else { return }
    height = h
    if shown { layoutPanel(animatedFrom: nil) }
  }

  private func layoutPanel(animatedFrom from: CGRect?) {
    let target = panelFrame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = target
    bar.frame = target
    mask.frame = bar.bounds
    CATransaction.commit()
    syncGlass()
    guard let from, window != nil else { return }
    let start = from.offsetBy(dx: -target.minX, dy: -target.minY)
    grow(surface, from: CGRect(origin: from.origin, size: from.size), to: target)
    grow(mask, from: start, to: CGRect(origin: .zero, size: target.size))
    let radius = CABasicAnimation(keyPath: "cornerRadius")
    radius.fromValue = NewTabLayout.barRadius
    radius.toValue = style.radius
    radius.duration = Self.growDuration
    radius.timingFunction = Self.growCurve
    surface.add(radius, forKey: "glassRadius")
    stopGlassLink()
    let link = displayLink(target: glassTarget, selector: #selector(GlassFrameTarget.tick(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(link)
    #endif
    link.add(to: .main, forMode: .common)
    glassLink = link
    updateGlass(frame: from, radius: NewTabLayout.barRadius)
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncGlass()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { finishGlassAnimation() }
    super.viewWillMove(toWindow: newWindow)
  }

  private func updateGlass(frame: CGRect? = nil, radius: CGFloat? = nil) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let displayedFrame = frame ?? panelFrame
    glassSurface.frame = bounds
    glassSurface.apply(frame: displayedFrame, radius: radius ?? style.radius, tint: style.fill.ns, dark: bar.theme.dark)
    bar.frame = CGRect(x: panelFrame.minX - displayedFrame.minX, y: panelFrame.minY - displayedFrame.minY, width: panelFrame.width, height: panelFrame.height)
    CATransaction.commit()
  }

  private func syncGlass() {
    if surface.animation(forKey: "grow") != nil, let presentation = surface.presentation() {
      updateGlass(frame: presentation.frame, radius: presentation.cornerRadius)
    } else {
      updateGlass()
    }
  }

  private func tickGlass() {
    guard shown, surface.animation(forKey: "grow") != nil else {
      stopGlassLink()
      updateGlass()
      return
    }
    syncGlass()
  }

  private func stopGlassLink() {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(glassLink)
    #endif
    glassLink?.invalidate()
    glassLink = nil
  }

  private func finishGlassAnimation() {
    stopGlassLink()
    surface.removeAnimation(forKey: "grow")
    surface.removeAnimation(forKey: "glassRadius")
    mask.removeAnimation(forKey: "grow")
    updateGlass()
  }

  @MainActor
  private final class GlassFrameTarget: NSObject {
    weak var host: OmniboxPanelHostView?

    init(_ host: OmniboxPanelHostView) {
      self.host = host
    }

    @objc func tick(_ link: CADisplayLink) {
      guard let host else {
        #if SOLARA_PROBES
        NativeWorkCounters.unlink(link)
        #endif
        link.invalidate()
        return
      }
      host.tickGlass()
    }
  }

  isolated deinit {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(glassLink)
    #endif
    glassLink?.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  private func grow(_ layer: CALayer, from: CGRect, to: CGRect) {
    let bounds = CABasicAnimation(keyPath: "bounds")
    bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
    bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: to.size))
    let position = CABasicAnimation(keyPath: "position")
    position.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
    position.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
    let group = CAAnimationGroup()
    group.animations = [bounds, position]
    group.duration = Self.growDuration
    group.timingFunction = Self.growCurve
    layer.add(group, forKey: "grow")
  }

  private func watchOutside() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.shown, event.window === self.window else { return }
        let point = self.convert(event.locationInWindow, from: nil)
        if !self.panelFrame.contains(point) { self.onOutside(event) }
      }
      return event
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard shown else { return nil }
    let local = convert(point, from: superview)
    guard panelFrame.contains(local) else { return nil }
    return super.hitTest(point)
  }
}
