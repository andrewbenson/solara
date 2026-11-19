import AppKit
import QuartzCore

public enum HoverCardMotion {
  public static let gap: CGFloat = 8
  public static let fromScale = 0.92
  public static let fadeDuration = 0.1
  public static let fadeCurve = BezierCurve(0.25, 0.46, 0.45, 0.94)
  public static let inSpring = SpringParams(response: 0.25, dampingRatio: 0.75)
  public static let outSpring = SpringParams(response: 0.2, dampingRatio: 0.6)

  public static func origin(anchor: CGRect, edge: CGFloat? = nil) -> CGPoint {
    CGPoint(x: (edge ?? anchor.maxX) + gap, y: max(8, anchor.minY - 6))
  }
}

@MainActor
public protocol HoverCardRetainedContent: NSView {}

public final class HoverCardView: NSView {
  public enum Phase: String, Sendable { case hidden, entering, shown, leaving }

  public var onHidden: (() -> Void)?
  public private(set) var content: NSView?
  public private(set) var phase: Phase = .hidden
  public var origin: CGPoint = .zero {
    didSet {
      content?.setFrameOrigin(origin)
      if origin != oldValue { applyRest() }
    }
  }

  private let motion = PrimitiveFlippedView()
  private var scale = SpringTrack.resting(HoverCardMotion.fromScale)
  private var fade = RNTween.resting(0)
  private var fadeTimer: Timer?
  private var run = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    motion.wantsLayer = true
    motion.layer?.opacity = 0
    addSubview(motion)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func show(_ view: NSView, origin next: CGPoint) {
    origin = next
    let fresh = content == nil
    let returning = phase == .leaving
    if content !== view {
      if let content { park(content) }
      content = view
      if view.superview !== motion { motion.addSubview(view) }
    }
    view.isHidden = false
    view.setFrameOrigin(origin)
    guard fresh || returning else { return }
    run += 1
    let now = CACurrentMediaTime()
    let fromOpacity = fresh ? 0 : currentOpacity(now)
    let fromScale = fresh ? HoverCardMotion.fromScale : scale.value(at: now)
    let velocity = fresh ? 0 : scale.velocity(at: now)
    phase = .entering
    animate(opacity: fromOpacity, to: 1, scaleFrom: fromScale, to: 1, velocity: velocity, spring: HoverCardMotion.inSpring, at: now) { [weak self] in
      guard let self, self.phase == .entering else { return }
      self.phase = .shown
    }
  }

  public func hide() {
    guard content != nil, phase != .leaving else { return }
    run += 1
    let mine = run
    let now = CACurrentMediaTime()
    phase = .leaving
    animate(opacity: currentOpacity(now), to: 0, scaleFrom: scale.value(at: now), to: HoverCardMotion.fromScale, velocity: scale.velocity(at: now), spring: HoverCardMotion.outSpring, at: now) { [weak self] in
      guard let self, self.run == mine else { return }
      self.motion.layer?.removeAllAnimations()
      if let content = self.content { self.park(content) }
      self.content = nil
      self.phase = .hidden
      self.scale = .resting(HoverCardMotion.fromScale)
      self.applyRest()
      self.onHidden?()
    }
  }

  public func keepHidden(_ view: NSView & HoverCardRetainedContent) {
    guard view.superview !== motion else { return }
    view.isHidden = true
    motion.addSubview(view)
  }

  private func park(_ view: NSView) {
    if view is HoverCardRetainedContent { view.isHidden = true } else { view.removeFromSuperview() }
  }

  private func currentOpacity(_ now: CFTimeInterval) -> Double { opacityValue(at: now) }

  private func animate(opacity from: Double, to: Double, scaleFrom: Double, to scaleTo: Double, velocity: Double, spring: SpringParams, at now: CFTimeInterval, done: @escaping @MainActor () -> Void) {
    fade = RNTween(from: from, to: to, start: now, duration: HoverCardMotion.fadeDuration, easing: .linear)
    scale = SpringTrack(spring, from: scaleFrom, to: scaleTo, velocity: velocity, start: now)
    guard let layer = motion.layer else { return }
    applyRest()
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = from
    opacity.toValue = to
    opacity.duration = HoverCardMotion.fadeDuration
    opacity.timingFunction = HoverCardMotion.fadeCurve.timingFunction
    opacity.beginTime = now
    opacity.fillMode = .backwards
    layer.add(opacity, forKey: "hoverCardOpacity")
    let point = origin
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", scale.samples(), duration: scale.duration, start: now) { NSValue(caTransform3D: PrimitiveMotion.scale(about: point, scale: $0)) }, forKey: "hoverCardScale")
    fadeTimer?.invalidate()
    fadeTimer = Timer.scheduledTimer(withTimeInterval: HoverCardMotion.fadeDuration, repeats: false) { _ in
      MainActor.assumeIsolated { done() }
    }
  }

  private func applyRest() {
    guard let layer = motion.layer else { return }
    let point = origin
    PrimitiveMotion.setInstantly {
      layer.opacity = Float(fade.to)
      layer.sublayerTransform = PrimitiveMotion.scale(about: point, scale: scale.to)
    }
  }

  public var presentedOpacity: Double { Double(motion.layer?.presentation()?.opacity ?? motion.layer?.opacity ?? 0) }
  public func scaleValue(at time: CFTimeInterval = CACurrentMediaTime()) -> Double { scale.value(at: time) }
  public func opacityValue(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
    let raw = fade.duration > 0 ? min(1, max(0, (time - fade.start) / fade.duration)) : 1
    return fade.from + (fade.to - fade.from) * HoverCardMotion.fadeCurve(raw)
  }

  public override func layout() {
    super.layout()
    motion.frame = bounds
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard phase == .shown, let content else { return nil }
    let local = motion.convert(point, from: superview)
    guard content.frame.contains(local) else { return nil }
    return content.hitTest(local)
  }
}
