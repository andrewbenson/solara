import AppKit
import QuartzCore

public struct ToolbarBackdropState: Decodable, Equatable {
  public var tabId: String
  public var background: String?
  public var divider: String
  public var hairline: Bool
  public var stripes: String?

  public init(tabId: String, background: String?, divider: String, hairline: Bool, stripes: String?) {
    self.tabId = tabId
    self.background = background
    self.divider = divider
    self.hairline = hairline
    self.stripes = stripes
  }

  public static func decode(_ json: String) -> Self? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

@MainActor
public final class ToolbarBackdropView: NSView {
  public private(set) var state: ToolbarBackdropState?
  private let band = CALayer()
  private let stripes = DeveloperStripes()
  private let hairline = CALayer()
  private var bandColor: CGColor?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(band)
    layer?.addSublayer(stripes.layer)
    layer?.addSublayer(hairline)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func update(_ next: ToolbarBackdropState?) {
    let animated = state != nil && next != nil
    state = next
    let color = next.flatMap { toolbarColor($0.background)?.cgColor }
    if color != bandColor {
      let from = bandColor ?? color?.copy(alpha: 0)
      let to = color ?? bandColor?.copy(alpha: 0)
      bandColor = color
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      band.backgroundColor = color
      CATransaction.commit()
      if animated, let from, let to {
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.333333, 0.666667, 0.666667, 1)
        band.add(animation, forKey: "backgroundColor")
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hairline.isHidden = next?.hairline != true
    hairline.backgroundColor = next.flatMap { toolbarColor($0.divider)?.cgColor }
    CATransaction.commit()
    stripes.show(next?.stripes)
    if next == nil { band.removeAllAnimations() }
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.frame = bounds
    hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    stripes.fit(bounds, scale: window?.backingScaleFactor ?? 2)
    CATransaction.commit()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    needsLayout = true
  }
}
