import Foundation

public struct CheckInMotion: Sendable {
  public private(set) var opacity = 0.0
  public private(set) var scale = 1.0
  public private(set) var leaving = false
  public private(set) var finished = false
  private let startedAt: Double
  private var spring = RNSpring(SpringParams(response: 0.2, dampingRatio: 0.5), from: 1, to: 1)
  private var exitAt: Double?
  private var exitOpacity = 0.0
  private var exitScale = 1.0

  public init(at time: Double) { startedAt = time }

  #if DEBUG
    public var devStartedAt: Double { startedAt }
  #endif

  public mutating func target(hovered: Bool, pressed: Bool, at time: Double) {
    guard !leaving else { return }
    step(at: time)
    spring = RNSpring(SpringParams(response: 0.2, dampingRatio: 0.5), from: scale, to: pressed ? 0.98 : hovered ? 1.02 : 1, initialVelocity: spring.velocity)
    _ = spring.step(at: time)
  }

  public mutating func leave(at time: Double) {
    guard !leaving else { return }
    step(at: time)
    leaving = true
    exitAt = time
    exitOpacity = opacity
    exitScale = scale
  }

  public mutating func step(at time: Double) {
    if let exitAt {
      let t = min(1, max(0, (time - exitAt) / 0.22))
      let ease = 1 - (1 - t) * (1 - t)
      opacity = exitOpacity * (1 - ease)
      scale = exitScale + (0.98 - exitScale) * ease
      finished = t >= 1
    } else {
      let t = min(1, max(0, (time - startedAt - 0.3) / 0.3))
      opacity = 1 - (1 - t) * (1 - t)
      scale = spring.step(at: time)
      finished = t >= 1 && spring.finished
    }
  }
}
