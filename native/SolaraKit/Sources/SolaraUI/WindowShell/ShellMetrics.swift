import CoreGraphics

public enum ShellMetrics {
  public static let sidebarWidth: CGFloat = 190
  public static let cardTop: CGFloat = 6
  public static let cardInset: CGFloat = 7
  public static let cardRadius: CGFloat = 10
  public static let toolbarHeight: CGFloat = 41
  public static let toolbarIconCenters: [CGFloat] = [21, 56, 92, 127]
  public static let breadcrumbX: CGFloat = 153
  public static let topStripHeight: CGFloat = 42
  public static let topCardInset: CGFloat = 6
  public static let paneGap: CGFloat = 7
  public static let minPane: CGFloat = 220
  public static let peekOrigin = CGPoint(x: 5, y: 5)
  public static let peekBottom: CGFloat = 5
  public static let peekRadius: CGFloat = 12
  public static let edgeStripWidth: CGFloat = 8
  public static let holdSlack: CGFloat = 24

  public static let lightsCenter = CGPoint(x: 25, y: 27)
  public static let arcLightsCenter = CGPoint(x: 25, y: 24)
  public static let trafficLightSize: CGFloat = 14
  public static let trafficLightPitch: CGFloat = 23
  public static let railLightsCenter = lightsCenter
  public static let chromeCaptionTrailingMargin: CGFloat = 14
  public static let chromeToolbarLeadingMargin: CGFloat = 6
  public static let chromeToolbarButtonSize: CGFloat = 28
  public static let railToolbarLeadingInset = railLightsCenter.x + 2 * trafficLightPitch + trafficLightSize / 2 + chromeCaptionTrailingMargin + chromeToolbarLeadingMargin + chromeToolbarButtonSize / 2 - toolbarIconCenters[0]
  public static let railToolbarTop = cardTop
  public static let railLightsTrailing = railLightsCenter.x + 2 * trafficLightPitch + trafficLightSize / 2
  public static let railBandClearUntil: CGFloat = 40
  public static let railBandFullFrom: CGFloat = 240
  public static let railBandRamp = railBandFullFrom - railBandClearUntil
  public static let railBandRampSteps = 12

  public static func railBandStops(width: CGFloat) -> (clearUntil: CGFloat, fullFrom: CGFloat, fullUntil: CGFloat, clearFrom: CGFloat) {
    let middle = width / 2
    let clearUntil = min(railBandClearUntil, middle)
    let fullFrom = min(railBandFullFrom, middle)
    let clearFrom = max(width - railPageGap, middle)
    let fullUntil = max(clearFrom - railBandRamp, middle)
    return (clearUntil, fullFrom, fullUntil, clearFrom)
  }

  public static func railBandMask(width: CGFloat, edge: CGFloat) -> [(location: CGFloat, alpha: CGFloat)] {
    let stops = railBandStops(width: width)
    let smooth = { (t: CGFloat) in t * t * (3 - 2 * t) }
    let steps = (0...railBandRampSteps).map { CGFloat($0) / CGFloat(railBandRampSteps) }
    let rise = steps.map { t in (stops.clearUntil + (stops.fullFrom - stops.clearUntil) * t, edge + (1 - edge) * smooth(t)) }
    let fall = steps.map { t in (stops.fullUntil + (stops.clearFrom - stops.fullUntil) * t, edge + (1 - edge) * smooth(1 - t)) }
    return [(0, edge)] + rise + fall + [(width, edge)]
  }
  public static let railPageGap = cardInset
  public static let topStripLightsCenter = CGPoint(x: 20.75, y: 20.75)
}

public struct ShellInset: Equatable, Sendable {
  public var top: CGFloat
  public var right: CGFloat
  public var bottom: CGFloat
  public var left: CGFloat

  public init(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
    self.top = top
    self.right = right
    self.bottom = bottom
    self.left = left
  }

  public static let sidebar = ShellInset(top: ShellMetrics.cardTop, right: ShellMetrics.cardInset, bottom: ShellMetrics.cardInset, left: ShellMetrics.cardInset)
  public static let topTabs = ShellInset(top: ShellMetrics.topStripHeight, right: ShellMetrics.topCardInset, bottom: ShellMetrics.topCardInset, left: ShellMetrics.topCardInset)
}
