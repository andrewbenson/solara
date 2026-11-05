import AppKit
import QuartzCore

@MainActor
public final class DockAnimator {
  public enum Curve: Equatable, Sendable {
    case spring(ShellSpring)
    case timed(duration: Double, ease: TimedRun.Ease)
  }

  public private(set) var value: Double
  public private(set) var target: Double
  public var onChange: ((Double) -> Void)?
  public var onSettle: ((Double) -> Void)?
  public var now: () -> CFTimeInterval = CACurrentMediaTime

  private var curve: Curve = .spring(.dock)
  private var start: Double = 0
  private var velocity: Double = 0
  private var launchVelocity: Double = 0
  private var elapsed: Double = 0
  private var last: CFTimeInterval = 0
  private var link: CADisplayLink?
  private var stallTimer: Timer?
  private var run = 0
  private var running = false

  public var moving: Bool { running }
  #if DEBUG
  public var devLinkActive: Bool { link != nil || stallTimer != nil }
  #endif

  public init(value: Double) {
    self.value = value
    target = value
  }

  public func jump(to value: Double) {
    halt()
    self.value = value
    target = value
    velocity = 0
    onChange?(value)
  }

  public func animate(to target: Double, curve: Curve = .spring(.dock), in view: NSView) {
    if !running && target == value {
      self.target = target
      return
    }
    if running && target == self.target && curve == self.curve { return }
    run += 1
    self.target = target
    self.curve = curve
    start = value
    launchVelocity = velocity
    elapsed = 0
    last = now()
    running = true
    if link == nil {
      let made = view.displayLink(target: DisplayLinkTrampoline(self), selector: #selector(DisplayLinkTrampoline.tick(_:)))
      made.add(to: .main, forMode: .common)
      link = made
    }
    if stallTimer == nil {
      let timer = Timer(timeInterval: DockMotion.stallCheck, repeats: true) { [weak self] timer in
        guard let self else { return timer.invalidate() }
        MainActor.assumeIsolated { self.tickIfStalled() }
      }
      RunLoop.main.add(timer, forMode: .common)
      stallTimer = timer
    }
  }

  public func step(by seconds: Double) {
    guard running else { return }
    let mine = run
    let done: Bool
    switch curve {
    case .spring(let spring):
      elapsed += min(seconds, DockMotion.maxStep)
      let sample = SpringRun(from: start, to: target, spring: spring, initialVelocity: launchVelocity).sample(elapsed)
      value = sample.value
      velocity = sample.done ? 0 : sample.velocity
      done = sample.done
    case .timed(let duration, let ease):
      elapsed += seconds
      let sample = TimedRun(from: start, to: target, duration: duration, ease: ease).sample(elapsed)
      value = sample.value
      velocity = 0
      done = sample.done
    }
    onChange?(value)
    guard run == mine, done else { return }
    halt()
    onSettle?(value)
  }

  func tick() {
    let t = now()
    let dt = t - last
    last = t
    step(by: dt)
  }

  func tickIfStalled() {
    guard running, now() - last >= DockMotion.stalledFrame else { return }
    tick()
  }

  private func halt() {
    running = false
    link?.invalidate()
    link = nil
    stallTimer?.invalidate()
    stallTimer = nil
  }

  public func stop() {
    halt()
    velocity = 0
  }
}

@MainActor
private final class DisplayLinkTrampoline: NSObject {
  weak var animator: DockAnimator?

  init(_ animator: DockAnimator) {
    self.animator = animator
  }

  @objc func tick(_ link: CADisplayLink) {
    guard let animator else { return link.invalidate() }
    animator.tick()
  }
}
