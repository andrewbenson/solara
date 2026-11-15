import CoreGraphics
import Foundation

public enum PeekMetrics {
  public static let insetFraction: CGFloat = 0.055
  public static let minInset: CGFloat = 16
  public static let startScale: CGFloat = 0.12
  public static let barHeight: CGFloat = 38
  public static let pageInset: CGFloat = 6
  public static let windowRadius: CGFloat = 16
  public static let cardRadius: CGFloat = 10
  public static let barButton: CGFloat = 28
  public static let barButtonGap: CGFloat = 2
  public static let fieldGap: CGFloat = 6
  public static let fieldHeight: CGFloat = 28
  public static let shadowRadius: CGFloat = 23
  public static let shadowOffset: CGFloat = 21

  public static func frame(width: CGFloat, height: CGFloat) -> CGRect {
    let x = max(minInset, (width * insetFraction).rounded())
    let y = max(minInset, (height * insetFraction).rounded())
    return CGRect(x: x, y: y, width: max(0, width - 2 * x), height: max(0, height - 2 * y))
  }

  public static func pageFrame(in card: CGSize) -> CGRect {
    CGRect(x: pageInset, y: barHeight, width: max(0, card.width - 2 * pageInset), height: max(0, card.height - barHeight - pageInset))
  }
}

public enum PeekTiming {
  public static let growResponse: Double = 0.22
  public static let growDamping: Double = 0.9
  public static let close: Double = 0.15
  public static let expand: Double = 0.17
  public static let fade: Double = 0.15

  public static var growStiffness: Double {
    let omega = 2 * Double.pi / growResponse
    return omega * omega
  }

  public static var growDampingCoefficient: Double { 2 * growDamping * (2 * Double.pi / growResponse) }
}

public enum PeekPinch {
  public static let openAt: CGFloat = 0.3
  public static let closeAt: CGFloat = -0.25
  static let spreadToTab: CGFloat = 0.4

  public enum Outcome: Equatable, Sendable { case open, close, stay }

  public static func outcome(_ magnification: CGFloat) -> Outcome {
    if magnification >= openAt { return .open }
    if magnification <= closeAt { return .close }
    return .stay
  }

  public static func follow(_ magnification: CGFloat, startScale: CGFloat = PeekMetrics.startScale) -> (progress: CGFloat, expand: CGFloat) {
    func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
    if magnification >= 0 { return (1, clamp(magnification / spreadToTab)) }
    return (clamp((1 + magnification - startScale) / (1 - startScale)), 0)
  }
}

public struct PeekPose: Equatable, Sendable {
  public var scaleX: CGFloat
  public var scaleY: CGFloat
  public var translateX: CGFloat
  public var translateY: CGFloat
  public var cardOpacity: CGFloat
  public var dim: CGFloat

  public static func at(progress: CGFloat, expand: CGFloat, frame: CGRect, container: CGSize, from: CGPoint?, fade: Bool) -> PeekPose {
    if fade { return PeekPose(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0, cardOpacity: progress, dim: progress) }
    let base = PeekMetrics.startScale + (1 - PeekMetrics.startScale) * progress
    let toWidth = container.width / max(frame.width, 1), toHeight = container.height / max(frame.height, 1)
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let start = from ?? center
    let opacity = progress >= 0.35 ? 1 : progress / 0.35
    return PeekPose(
      scaleX: base * (1 + (toWidth - 1) * expand), scaleY: base * (1 + (toHeight - 1) * expand),
      translateX: (start.x - center.x) * (1 - progress), translateY: (start.y - center.y) * (1 - progress),
      cardOpacity: opacity, dim: progress * (1 - expand))
  }
}

@MainActor
public final class PeekLifetime {
  private var tabId: String?
  private var generation: UInt64 = 0

  public init() {}

  public func replace(_ next: String?) {
    guard next != tabId else { return }
    generation += 1
    tabId = next
  }

  public func receipt() -> UInt64 { generation }

  public func accepts(_ receipt: UInt64) -> Bool { tabId != nil && receipt == generation }
}

@MainActor
public final class RevealHolds {
  private var tokens = Set<UUID>()
  public var onChange: (Bool) -> Void = { _ in }
  public var held: Bool { !tokens.isEmpty }

  public init() {}

  public func acquire() -> UUID {
    let token = UUID()
    let was = held
    tokens.insert(token)
    if !was { onChange(true) }
    return token
  }

  public func release(_ token: UUID) {
    let was = held
    tokens.remove(token)
    if was && !held { onChange(false) }
  }
}
