import AppKit
import QuartzCore
import SolaraModel

public struct ToolbarBackdropState: Equatable {
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

  public static func resolve(windowId: String, tabId: String, state: BrowserState, dark: Bool) -> Self? {
    guard let tab = state.tabs[tabId], tab.windowId == windowId else { return nil }
    let hasPage = !tab.url.isEmpty
    let developer = OmniboxCommandSources.isDeveloperURL(tab.url, settings: state.settings, profileId: tab.profileId)
    var background: String?
    var darkDivider = dark
    if hasPage, !developer, state.settings.bool("extendWebsiteColor"),
      let reported = state.live[tabId]?.themeColor,
      let (webColor, color) = siteColor(reported) {
      background = webColor
      let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
      darkDivider = 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05
    }
    return Self(tabId: tabId, background: background, divider: darkDivider ? "rgba(255,255,255,0.025)" : "rgba(0,0,0,0.05)",
      hairline: hasPage, stripes: developer ? (dark ? "#FFFFFF05" : "#00000005") : nil)
  }

  private static func siteColor(_ reported: String) -> (String, CSSColor)? {
    let hex = String(reported.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
    guard hex.count == 7, hex.hasPrefix("#"), let color = CSSColor(hex) else { return nil }
    return (hex, color)
  }

  private static func linear(_ channel: Double) -> Double {
    channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
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
    guard next != state else { return }
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
    stripes.show(color: toolbarColor(next?.stripes)?.cgColor)
    if next == nil { band.removeAllAnimations() }
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.frame = bounds
    let hairlineHeight = 1 / (window?.backingScaleFactor ?? 2)
    hairline.frame = CGRect(x: 0, y: bounds.height - hairlineHeight, width: bounds.width, height: hairlineHeight)
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
