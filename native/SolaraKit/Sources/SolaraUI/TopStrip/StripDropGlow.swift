import AppKit
import QuartzCore

public enum StripDropGlowMetrics {
  public static let duration: Double = 0.14
  public static let border: CGFloat = 1.5
  public static let radius: CGFloat = StripMetrics.tabRadius + 1

  public static func frame(width: CGFloat, left: CGFloat, right: CGFloat) -> CGRect {
    CGRect(x: left - 4, y: StripMetrics.itemTop - 1, width: max(0, width - (left - 4) - (right - 4)), height: StripMetrics.itemHeight + 2)
  }
}

@MainActor
public final class StripDropGlow: NSView {
  private let plate = CALayer()
  private var opacity = StripTimedValue(0)
  private lazy var ticker = StripTicker(view: self) { [weak self] now in self?.tick(now) ?? false }
  public private(set) var over = false
  public private(set) var trace: [[Double]]?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    plate.cornerRadius = StripDropGlowMetrics.radius
    plate.borderWidth = StripDropGlowMetrics.border
    plate.opacity = 0
    layer?.addSublayer(plate)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public var value: Double { opacity.value }

  public func set(over next: Bool, accent: String, dark: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.borderColor = (SidebarPalette.parse(accent) ?? .controlAccentColor).cgColor
    plate.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)).cgColor
    CATransaction.commit()
    guard next != over else { return }
    over = next
    let now = StripTicker.now
    opacity.step(now: now)
    trace?.append([now, opacity.value])
    opacity.animate(to: next ? 1 : 0, duration: StripDropGlowMetrics.duration, easing: .quad, at: now)
    ticker.start()
  }

  public func stop() {
    ticker.stop()
    layer?.removeAllAnimations()
  }

  public func startTrace() { trace = [[StripTicker.now, opacity.value]] }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { ticker.stop() } else if opacity.running { ticker.start() }
  }

  private func tick(_ now: Double) -> Bool {
    opacity.step(now: now)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.opacity = Float(opacity.value)
    CATransaction.commit()
    trace?.append([now, opacity.value])
    return opacity.running
  }
}
