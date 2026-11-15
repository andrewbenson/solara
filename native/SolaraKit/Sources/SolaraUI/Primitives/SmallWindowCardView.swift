import AppKit
import QuartzCore

public struct SmallWindowCardState: Decodable, Equatable {
  public var tabId: String
  public var fill: String?
  public var radius: Double

  public init(tabId: String, fill: String?, radius: Double) {
    self.tabId = tabId
    self.fill = fill
    self.radius = radius
  }

  public static func decode(_ json: String) -> Self? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

@MainActor
public final class SmallWindowCardView: NSView {
  public private(set) var state: SmallWindowCardState?
  private let fill = CALayer()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    fill.masksToBounds = true
    layer?.addSublayer(fill)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func update(_ next: SmallWindowCardState?) {
    state = next
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = next.flatMap { toolbarColor($0.fill)?.cgColor }
    fill.cornerRadius = CGFloat(max(0, next?.radius ?? 0))
    CATransaction.commit()
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = bounds
    CATransaction.commit()
  }
}
