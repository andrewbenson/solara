import AppKit
import QuartzCore

public struct StripSpringValue: Sendable, Equatable {
  public private(set) var value: Double
  public private(set) var target: Double
  public private(set) var running = false
  private var spring: StripSpring = .group
  private var from: Double = 0
  private var initialVelocity: Double = 0
  private var velocity: Double = 0
  private var elapsed: Double = 0
  private var lastTime: Double = 0
  private var starting = false

  public init(_ value: Double) {
    self.value = value
    target = value
  }

  public mutating func set(_ value: Double) {
    self.value = value
    target = value
    running = false
    starting = false
    velocity = 0
  }

  public mutating func animate(to target: Double, _ spring: StripSpring, at now: Double? = nil) {
    initialVelocity = running ? velocity : 0
    self.spring = spring
    from = value
    self.target = target
    elapsed = 0
    running = true
    starting = now == nil
    if let now { lastTime = now }
  }

  public mutating func step(now: Double) {
    guard running else { return }
    if starting {
      starting = false
      lastTime = now
      return
    }
    let time = min(now, lastTime + 0.064)
    elapsed += max(0, time - lastTime)
    lastTime = time
    let (position, speed) = Self.solve(spring, from: from, to: target, initialVelocity: initialVelocity, t: elapsed)
    value = position
    velocity = speed
    let still = abs(speed) <= spring.restSpeed
    let settled = spring.stiffness == 0 || abs(target - position) <= spring.restDisplacement
    if still && settled {
      if spring.stiffness != 0 { value = target }
      velocity = 0
      running = false
    }
  }

  static func solve(_ s: StripSpring, from: Double, to: Double, initialVelocity: Double, t: Double) -> (Double, Double) {
    let c = s.damping, m = s.mass, k = s.stiffness
    let v0 = -initialVelocity
    let zeta = c / (2 * (k * m).squareRoot())
    let omega0 = (k / m).squareRoot()
    let x0 = to - from
    if zeta < 1 {
      let omega1 = omega0 * (1 - zeta * zeta).squareRoot()
      let envelope = exp(-zeta * omega0 * t)
      let a = (v0 + zeta * omega0 * x0) / omega1
      let position = to - envelope * (a * sin(omega1 * t) + x0 * cos(omega1 * t))
      let speed = zeta * omega0 * envelope * (sin(omega1 * t) * a + x0 * cos(omega1 * t)) - envelope * (cos(omega1 * t) * (v0 + zeta * omega0 * x0) - omega1 * x0 * sin(omega1 * t))
      return (position, speed)
    }
    let envelope = exp(-omega0 * t)
    return (to - envelope * (x0 + (v0 + omega0 * x0) * t), envelope * (v0 * (t * omega0 - 1) + t * x0 * omega0 * omega0))
  }
}

public struct StripTimedValue: Sendable, Equatable {
  public enum Easing: Sendable { case quad, cubic }

  public private(set) var value: Double
  public private(set) var target: Double
  private var from: Double = 0
  private var start: Double?
  private var duration: Double = 0
  private var easing = Easing.quad
  public var running: Bool { duration > 0 }

  public init(_ value: Double) {
    self.value = value
    target = value
  }

  public mutating func set(_ value: Double) {
    self.value = value
    target = value
    duration = 0
  }

  public mutating func animate(to target: Double, duration: Double, easing: Easing = .quad, at now: Double? = nil) {
    guard target != self.target else { return }
    from = value
    self.target = target
    start = now
    self.duration = duration
    self.easing = easing
  }

  public mutating func step(now: Double) {
    guard running else { return }
    guard let start else {
      start = now
      return
    }
    let p = min(1, max(0, (now - start) / duration))
    let eased = easing == .cubic ? 1 - pow(1 - p, 3) : 1 - (1 - p) * (1 - p)
    value = from + (target - from) * eased
    if p >= 1 {
      value = target
      duration = 0
    }
  }
}

@MainActor
final class StripTicker {
  private var link: CADisplayLink?
  private var fallback: Timer?
  private var lastFrame: Double = 0
  private weak var view: NSView?
  private let tick: (Double) -> Bool

  init(view: NSView, tick: @escaping (Double) -> Bool) {
    self.view = view
    self.tick = tick
  }

  static var now: Double { CACurrentMediaTime() }

  func start() {
    guard link == nil, let view else { return }
    lastFrame = Self.now
    let made = view.displayLink(target: self, selector: #selector(step(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(made)
    #endif
    made.add(to: .main, forMode: .common)
    link = made
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, Self.now - self.lastFrame > 1.5 / 60 else { return }
        self.frame()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    fallback = timer
  }

  func stop() {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(link)
    #endif
    link?.invalidate()
    link = nil
    fallback?.invalidate()
    fallback = nil
  }

  @objc private func step(_ link: CADisplayLink) { frame() }

  private func frame() {
    lastFrame = Self.now
    if !tick(lastFrame) { stop() }
  }
}

@MainActor
final class StripGroupMotion {
  private(set) var open: StripSpringValue
  private(set) var size: StripSpringValue
  private var settled: String
  private var fades: [String: StripTimedValue] = [:]

  init(expanded: Bool, width: CGFloat, state: String) {
    open = StripSpringValue(expanded ? 1 : 0)
    size = StripSpringValue(Double(width))
    settled = state
  }

  var moving: Bool { open.running || size.running }
  var running: Bool { moving || fades.values.contains { $0.running } }

  func retarget(_ placed: StripPlacedGroup) {
    let state = Self.state(placed)
    let width = Double(placed.width)
    if settled != state {
      settled = state
      open.animate(to: placed.expanded ? 1 : 0, .group)
      size.animate(to: width, .group)
    } else if size.target != width {
      if moving { size.animate(to: width, .group) } else { size.set(width) }
    }
    let ids = Set(placed.members.map(\.member.id))
    fades = fades.filter { ids.contains($0.key) }
    for m in placed.members {
      let target: Double = m.shown ? 1 : 0
      if var fade = fades[m.member.id] {
        fade.animate(to: target, duration: StripMotionTiming.tuckFade)
        fades[m.member.id] = fade
      } else {
        fades[m.member.id] = StripTimedValue(target)
      }
    }
  }

  func step(now: Double) {
    open.step(now: now)
    size.step(now: now)
    for (id, var fade) in fades where fade.running {
      fade.step(now: now)
      fades[id] = fade
    }
  }

  var shown: [String: CGFloat] { fades.mapValues { CGFloat($0.value) } }

  static func state(_ placed: StripPlacedGroup) -> String {
    "\(placed.expanded):\(placed.shown.map { placed.members[$0].member.id } ?? "")"
  }
}

public enum StripMotionTiming {
  public static let tuckFade = 0.12
  public static let band = 0.18
  public static let lift = 0.15
  public static let onto = 0.1
  public static let incoming = 0.12
}

struct StripEasedColor {
  private var from: NSColor
  private var to: NSColor
  private var progress = StripTimedValue(1)

  init(_ color: NSColor?) {
    let start = Self.srgb(color) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    from = start
    to = start
  }

  var running: Bool { progress.running }

  mutating func retarget(_ color: NSColor?, duration: Double) {
    let target = Self.srgb(color)?.withAlphaComponent(1) ?? to.withAlphaComponent(0)
    guard target != to else { return }
    from = to
    to = target
    progress.set(0)
    progress.animate(to: 1, duration: duration)
  }

  mutating func step(now: Double) { progress.step(now: now) }

  var value: NSColor {
    let p = CGFloat(progress.value)
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
    return NSColor(
      srgbRed: mix(from.redComponent, to.redComponent), green: mix(from.greenComponent, to.greenComponent),
      blue: mix(from.blueComponent, to.blueComponent), alpha: mix(from.alphaComponent, to.alphaComponent))
  }

  private static func srgb(_ color: NSColor?) -> NSColor? { color?.usingColorSpace(.sRGB) }
}
