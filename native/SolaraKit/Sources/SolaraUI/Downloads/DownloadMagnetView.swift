import AppKit
import QuartzCore

public struct DownloadFlight: Equatable, Sendable {
  public let id: String
  public let path: String
  public let start: CGPoint
  public let target: CGPoint

  public init(id: String, path: String, start: CGPoint, target: CGPoint) {
    self.id = id
    self.path = path
    self.start = start
    self.target = target
  }
}

public enum DownloadMagnetMotion {
  public static let icon: CGFloat = 44
  public static let duration: CFTimeInterval = 0.7
  public static let arc: CGFloat = 90
  public static let steps: [Double] = [0, 0.25, 0.5, 0.75, 1]
  public static let opacityTimes: [Double] = [0, 0.1, 0.8, 1]
  public static let opacities: [Double] = [0, 1, 1, 0]
  public static let scaleTimes: [Double] = [0, 0.15, 1]
  public static let scales: [Double] = [0.6, 1.1, 0.3]
  public static let timing: [Float] = [0.45, 0, 0.2, 1]

  public static func centers(_ flight: DownloadFlight) -> [CGPoint] {
    steps.map { p in
      CGPoint(
        x: flight.start.x + (flight.target.x - flight.start.x) * p,
        y: flight.start.y + (flight.target.y - flight.start.y) * p - sin(.pi * p) * arc)
    }
  }
}

public final class DownloadMagnetView: NSView {
  public override var isFlipped: Bool { true }
  public var iconFor: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
  public private(set) var flying: String?
  public private(set) var flights = 0
  public private(set) var flight: DownloadFlight?
  private let iconLayer = CALayer()

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    iconLayer.bounds = CGRect(x: 0, y: 0, width: DownloadMagnetMotion.icon, height: DownloadMagnetMotion.icon)
    iconLayer.opacity = 0
    iconLayer.contentsGravity = .resizeAspect
    layer?.addSublayer(iconLayer)
  }

  required init?(coder: NSCoder) { nil }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    iconLayer.contentsScale = window?.backingScaleFactor ?? 2
  }

  public func fly(_ flight: DownloadFlight) {
    guard self.flight?.id != flight.id else { return }
    self.flight = flight
    flying = flight.id
    flights += 1
    iconLayer.contents = iconFor(flight.path)
    iconLayer.contentsScale = window?.backingScaleFactor ?? 2
    let centers = DownloadMagnetMotion.centers(flight)
    let position = CAKeyframeAnimation(keyPath: "position")
    position.values = centers.map { NSValue(point: $0) }
    position.keyTimes = DownloadMagnetMotion.steps.map { NSNumber(value: $0) }
    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = DownloadMagnetMotion.opacities
    opacity.keyTimes = DownloadMagnetMotion.opacityTimes.map { NSNumber(value: $0) }
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = DownloadMagnetMotion.scales
    scale.keyTimes = DownloadMagnetMotion.scaleTimes.map { NSNumber(value: $0) }
    let group = CAAnimationGroup()
    group.animations = [position, opacity, scale]
    group.duration = DownloadMagnetMotion.duration
    let c = DownloadMagnetMotion.timing
    group.timingFunction = CAMediaTimingFunction(controlPoints: c[0], c[1], c[2], c[3])
    group.delegate = FlightEnd { [weak self, id = flight.id] in
      if self?.flying == id { self?.flying = nil }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    iconLayer.position = centers.last ?? flight.target
    iconLayer.opacity = 0
    iconLayer.removeAnimation(forKey: "flight")
    iconLayer.add(group, forKey: "flight")
    CATransaction.commit()
  }

  public func reset() {
    iconLayer.removeAnimation(forKey: "flight")
    iconLayer.contents = nil
    flying = nil
    flight = nil
  }

  var flightAnimation: CAAnimationGroup? { iconLayer.animation(forKey: "flight") as? CAAnimationGroup }
}

private final class FlightEnd: NSObject, CAAnimationDelegate {
  let done: () -> Void
  init(_ done: @escaping () -> Void) { self.done = done }
  func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { done() }
}
