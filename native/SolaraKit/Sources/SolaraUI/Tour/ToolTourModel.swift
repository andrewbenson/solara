import Foundation
import Observation
import SwiftUI

public struct ToolTourStop: Equatable, Sendable {
  public enum Placement: String, Sendable {
    case below, right, inside
  }

  public var id: String
  public var title: String
  public var body: String
  public var anchored: Bool
  public var placement: Placement
  public var radius: Double?
  public var pad: Double?

  public init(id: String, title: String, body: String, anchored: Bool, placement: Placement = .below, radius: Double? = nil, pad: Double? = nil) {
    self.id = id
    self.title = title
    self.body = body
    self.anchored = anchored
    self.placement = placement
    self.radius = radius
    self.pad = pad
  }

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, let title = json["title"] as? String, let body = json["body"] as? String else { return nil }
    self.init(
      id: id, title: title, body: body, anchored: json["anchored"] as? Bool ?? false,
      placement: (json["placement"] as? String).flatMap(Placement.init(rawValue:)) ?? .below,
      radius: (json["radius"] as? NSNumber)?.doubleValue, pad: (json["pad"] as? NSNumber)?.doubleValue)
  }
}

public struct ToolTourHole: Equatable, Sendable {
  public var rect: CGRect
  public var radius: Double

  public init(rect: CGRect, radius: Double) {
    self.rect = rect
    self.radius = radius
  }
}

public enum ToolTourLayout {
  public static let cardWidth = 296.0
  public static let gap = 14.0
  public static let margin = 12.0
  public static let guessedCardHeight = 150.0

  public static func spotlight(_ stop: ToolTourStop?, target: CGRect?, size: CGSize) -> ToolTourHole {
    guard let stop, stop.anchored, let target else {
      return ToolTourHole(rect: CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0), radius: 0)
    }
    let pad = stop.pad ?? 4
    return ToolTourHole(
      rect: CGRect(x: target.minX - pad, y: target.minY - pad, width: target.width + pad * 2, height: target.height + pad * 2),
      radius: (stop.radius ?? 8) + max(0, pad))
  }

  public static func placeCard(_ stop: ToolTourStop?, spot: ToolTourHole, size: CGSize, height: Double) -> CGPoint {
    func clampX(_ x: Double) -> Double { min(max(x, margin), max(margin, size.width - cardWidth - margin)) }
    func clampY(_ y: Double) -> Double { min(max(y, margin), max(margin, size.height - height - margin)) }
    let centre = CGPoint(x: clampX(size.width / 2 - cardWidth / 2), y: clampY(size.height * 0.62 - height / 2))
    let s = spot.rect
    guard let stop, stop.anchored, s.width != 0 else { return centre }
    switch stop.placement {
    case .right:
      let x = s.minX + s.width + gap
      if x + cardWidth > size.width - margin { return CGPoint(x: clampX(s.minX), y: clampY(s.minY + s.height + gap)) }
      return CGPoint(x: x, y: clampY(s.minY + s.height / 2 - 36))
    case .inside:
      return CGPoint(x: clampX(s.minX + s.width / 2 - cardWidth / 2), y: clampY(s.minY + s.height * 0.7 - height / 2))
    case .below:
      let below = s.minY + s.height + gap
      let y = below + height > size.height - margin ? s.minY - gap - height : below
      let x = s.width < cardWidth / 2 ? s.minX - 10 : s.minX + s.width / 2 - cardWidth / 2
      return CGPoint(x: clampX(x), y: clampY(y))
    }
  }
}

#if SOLARA_PROBES
struct ToolTourControlSample: Equatable {
  let frame: CGRect
  let session: Int
  let index: Int
}
#endif

@MainActor
@Observable
public final class ToolTourModel {
  public private(set) var session = 0
  public private(set) var active = false
  public private(set) var index = 0
  public private(set) var stops: [ToolTourStop] = []
  public private(set) var target: CGRect?
  public private(set) var video = false
  public private(set) var theme = PageTheme(dark: false, tokens: [:])
  public var size: CGSize = .zero
  public var cardHeight: Double?
  #if SOLARA_PROBES
  @ObservationIgnored private var controlSamples: [String: ToolTourControlSample] = [:]

  public var controlFrames: [String: CGRect] {
    controlSamples.filter { $0.value.session == session && $0.value.index == index }.mapValues(\.frame)
  }

  public func recordControlFrame(_ label: String, frame: CGRect, session: Int, index: Int) {
    guard session == self.session, index == self.index, !frame.isEmpty else { return }
    controlSamples[label] = ToolTourControlSample(frame: frame, session: session, index: index)
  }
  #endif

  public var send: (String) -> Void = { _ in }

  public init() {}

  public var stop: ToolTourStop? { stops.isEmpty ? nil : stops[min(index, stops.count - 1)] }
  public var visible: Bool { active && stop != nil }
  public var last: Bool { index == stops.count - 1 }

  public var hole: ToolTourHole { ToolTourLayout.spotlight(stop, target: target, size: size) }
  public var cardOrigin: CGPoint { ToolTourLayout.placeCard(stop, spot: hole, size: size, height: cardHeight ?? ToolTourLayout.guessedCardHeight) }

  public func apply(_ json: String) {
    guard let data = json.data(using: .utf8), let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    let incoming = state["session"] as? Int ?? 0
    guard incoming >= session else { return }
    if incoming != session { cardHeight = nil }
    session = incoming
    let stops = (state["stops"] as? [[String: Any]] ?? []).compactMap(ToolTourStop.init(json:))
    active = (state["active"] as? Bool ?? false) && !stops.isEmpty
    self.stops = active ? stops : []
    index = state["index"] as? Int ?? 0
    target = (state["target"] as? [String: Any]).flatMap(Self.rect)
    video = state["video"] as? Bool ?? false
    let dark = state["dark"] as? Bool ?? false
    let tokens = state["theme"] as? [String: String] ?? [:]
    let next = PageTheme(dark: dark, tokens: tokens, panelShadowOpacity: (state["panelShadowOpacity"] as? NSNumber)?.doubleValue)
    if next != theme { theme = next }
  }

  public func passesThrough(_ point: CGPoint) -> Bool {
    guard visible else { return true }
    let card = CGRect(origin: cardOrigin, size: CGSize(width: ToolTourLayout.cardWidth, height: cardHeight ?? ToolTourLayout.guessedCardHeight))
    return !card.contains(point) && hole.rect.contains(point)
  }

  static func rect(_ json: [String: Any]) -> CGRect? {
    guard let x = (json["x"] as? NSNumber)?.doubleValue, let y = (json["y"] as? NSNumber)?.doubleValue,
      let width = (json["width"] as? NSNumber)?.doubleValue, let height = (json["height"] as? NSNumber)?.doubleValue, width > 0, height > 0
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
