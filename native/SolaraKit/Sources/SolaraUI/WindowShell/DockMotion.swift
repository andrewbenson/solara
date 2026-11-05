import CoreGraphics
import Foundation

public struct ShellSpring: Equatable, Sendable {
  public var response: Double
  public var damping: Double

  public init(response: Double, damping: Double) {
    self.response = response
    self.damping = damping
  }

  public static let dock = ShellSpring(response: 0.215, damping: 0.79)
  public static let arcPeek = ShellSpring(response: 0.185, damping: 0.77)

  public var stiffness: Double { omega * omega }
  public var dampingCoefficient: Double { 2 * damping * omega }
  var omega: Double { 2 * .pi / response }
}

public enum DockMotion {
  public static let arcPeekOutMs: Double = 150
  public static let arcHideMs: Double = 100
  public static let restDisplacement: Double = 0.001
  public static let restSpeed: Double = 0.01
  public static let maxStep: Double = 0.064
  public static let stalledFrame: Double = 1.5 / 60
  public static let stallCheck: Double = 1.0 / 60

  public static func springAt(_ t: Double, _ spring: ShellSpring = .dock) -> Double {
    if t <= 0 { return 0 }
    let omega = spring.omega
    let zeta = spring.damping
    let wd = omega * (1 - zeta * zeta).squareRoot()
    return 1 - exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
  }

  public static func easeOutCubic(_ u: Double) -> Double { 1 - pow(1 - u, 3) }

  public static func easeInOutCubic(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }

  public static func lightsCenter(offset: CGFloat, down: CGFloat = 0, base: CGPoint = ShellMetrics.lightsCenter) -> CGPoint? {
    let dx = jsRound(offset * 2) / 2
    if dx == 0 && down == 0 && base == ShellMetrics.lightsCenter { return nil }
    return CGPoint(x: base.x - dx, y: base.y + down)
  }

  public static func sidebarLightsCenter(_ input: DockedLayoutInput, base given: CGPoint? = nil) -> CGPoint? {
    guard !input.topTabs else { return nil }
    let base = given ?? (input.addressBarInSidebar ? ShellMetrics.arcLightsCenter : ShellMetrics.lightsCenter)
    let width = input.sidebarWidth
    let offset: CGFloat = input.fullscreen ? 0
      : input.peeking ? (width + 12) * (1 - input.peekSlide) - ShellMetrics.peekOrigin.x : width * (1 - input.dock)
    let full = lightsCenter(offset: offset, down: input.peeking && !input.fullscreen ? ShellMetrics.peekOrigin.y : 0, base: base)
    let progress = input.railFraction
    guard progress > 0 else { return full }
    let start = full ?? ShellMetrics.lightsCenter
    let end = ShellMetrics.railLightsCenter
    return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
  }

  public static func cardLeft(dock: CGFloat, width: CGFloat, inset: CGFloat) -> CGFloat { inset + (width - inset) * dock }

  static func jsRound(_ x: CGFloat) -> CGFloat { (x + 0.5).rounded(.down) }
}

public struct SpringRun: Equatable, Sendable {
  public let from: Double
  public let to: Double
  public let spring: ShellSpring
  public let initialVelocity: Double

  public init(from: Double, to: Double, spring: ShellSpring = .dock, initialVelocity: Double = 0) {
    self.from = from
    self.to = to
    self.spring = spring
    self.initialVelocity = initialVelocity
  }

  public func sample(_ t: Double) -> (value: Double, velocity: Double, done: Bool) {
    let k = spring.stiffness
    let c = spring.dampingCoefficient
    let zeta = c / (2 * k.squareRoot())
    let omega0 = k.squareRoot()
    let v0 = -initialVelocity
    let x0 = to - from
    var position: Double
    var velocity: Double
    if zeta < 1 {
      let omega1 = omega0 * (1 - zeta * zeta).squareRoot()
      let envelope = exp(-zeta * omega0 * t)
      let a = (v0 + zeta * omega0 * x0) / omega1
      position = to - envelope * (a * sin(omega1 * t) + x0 * cos(omega1 * t))
      velocity =
        zeta * omega0 * envelope * (sin(omega1 * t) * (v0 + zeta * omega0 * x0) / omega1 + x0 * cos(omega1 * t))
        - envelope * (cos(omega1 * t) * (v0 + zeta * omega0 * x0) - omega1 * x0 * sin(omega1 * t))
    } else {
      let envelope = exp(-omega0 * t)
      position = to - envelope * (x0 + (v0 + omega0 * x0) * t)
      velocity = envelope * (v0 * (t * omega0 - 1) + t * x0 * omega0 * omega0)
    }
    let done = abs(velocity) <= DockMotion.restSpeed && abs(to - position) <= DockMotion.restDisplacement
    if done { position = to }
    return (position, velocity, done)
  }
}

public struct TimedRun: Equatable, Sendable {
  public let from: Double
  public let to: Double
  public let duration: Double
  public let ease: Ease

  public enum Ease: Equatable, Sendable { case outCubic, inOutCubic, outBack(Double) }

  public init(from: Double, to: Double, duration: Double, ease: Ease) {
    self.from = from
    self.to = to
    self.duration = duration
    self.ease = ease
  }

  public func sample(_ t: Double) -> (value: Double, done: Bool) {
    if t >= duration - 1e-9 { return (to, true) }
    let u = max(0, t / duration)
    let eased: Double
    switch ease {
    case .outCubic: eased = DockMotion.easeOutCubic(u)
    case .inOutCubic: eased = DockMotion.easeInOutCubic(u)
    case .outBack(let overshoot):
      let t = 1 - u
      eased = 1 - t * t * (t + overshoot * (t - 1))
    }
    return (from + (to - from) * eased, false)
  }
}
