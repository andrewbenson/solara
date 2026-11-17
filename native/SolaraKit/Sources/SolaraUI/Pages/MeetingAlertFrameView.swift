import AppKit
import SwiftUI

public enum MeetingAlertFrameMetrics {
  public static let width: CGFloat = 300
  public static let lift: Double = -10
  public static let fromScale: Double = 0.97
  public static let spring = SpringParams.rn(speed: 14, bounciness: 6)
}

@MainActor
public final class MeetingAlertFrameView: NSView {
  public let model = LiveCardModel()
  private let motion = FlippedMotionView()
  private let hosting: NSHostingView<LiveCardView>
  private var cardHeight: CGFloat = 1
  private var opened = false
  private var alertId: String?
  public var onEvent: (LiveCardEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    hosting = NSHostingView(rootView: LiveCardView(model: model))
    super.init(frame: frame)
    wantsLayer = true
    motion.wantsLayer = true
    motion.layer?.opacity = 0
    addSubview(motion)
    hosting.safeAreaRegions = []
    hosting.sizingOptions = []
    motion.addSubview(hosting)
    model.onEvent = { [weak self] event in
      guard let self else { return }
      if case .height(let h) = event {
        let next = max(1, ceil(CGFloat(h)))
        guard next != self.cardHeight else { return }
        self.cardHeight = next
        self.onHeight(next)
        self.needsLayout = true
      } else {
        self.onEvent(event)
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  public var height: CGFloat { cardHeight }

  public func apply(json: String) {
    model.apply(json: json)
    let id = model.state?.alert?.id
    if id != alertId {
      alertId = id
      opened = false
      needsLayout = true
    }
  }

  public override func layout() {
    super.layout()
    motion.frame = bounds
    hosting.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(cardHeight, bounds.height))
    if !opened, window != nil, model.state != nil, cardHeight > 1 { open() }
  }

  private func open() {
    opened = true
    guard let layer = motion.layer else { return }
    let now = CACurrentMediaTime()
    let spring = SpringTrack(MeetingAlertFrameMetrics.spring, from: 0, to: 1, start: now)
    let values = spring.samples()
    let center = CGPoint(x: bounds.midX, y: cardHeight / 2)
    PrimitiveMotion.setInstantly {
      layer.opacity = 1
      layer.sublayerTransform = CATransform3DIdentity
    }
    layer.add(PrimitiveMotion.keyframes("opacity", values.map { min(1, max(0, $0)) }, duration: spring.duration, start: now) { NSNumber(value: $0) }, forKey: "alertOpacity")
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", values, duration: spring.duration, start: now) { p in
      NSValue(caTransform3D: PrimitiveMotion.scale(about: center, scale: MeetingAlertFrameMetrics.fromScale + (1 - MeetingAlertFrameMetrics.fromScale) * p, translateY: MeetingAlertFrameMetrics.lift * (1 - p)))
    }, forKey: "alertMotion")
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard local.y >= 0, local.y < cardHeight, local.x >= 0, local.x < bounds.width else { return nil }
    return super.hitTest(point)
  }
}

final class FlippedMotionView: NSView {
  override var isFlipped: Bool { true }
}
