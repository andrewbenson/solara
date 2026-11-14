import AppKit
import QuartzCore

public enum StripPeekMetrics {
  public static let left: CGFloat = 6
  public static let top: CGFloat = 4
  public static let pad: CGFloat = 7
  public static let height: CGFloat = StripMetrics.itemHeight + pad * 2
  public static let border: CGFloat = 0.5
  public static let radius: CGFloat = 12
  public static let hoverHeight: CGFloat = 6
  public static let shadowRadius: CGFloat = 20
  public static let shadowOffset: CGFloat = 6
  public static let travel: CGFloat = height + 8

  public static func panel(windowWidth: CGFloat) -> CGRect {
    CGRect(x: left, y: top, width: max(0, windowWidth - left * 2), height: height)
  }

  public static func row(in panel: CGSize) -> CGRect {
    CGRect(x: border, y: border + pad - StripMetrics.itemTop, width: max(0, panel.width - border * 2), height: StripMetrics.height)
  }

  public static func holds(_ point: CGPoint, windowWidth: CGFloat, bandLeft: CGFloat) -> Bool {
    let panel = panel(windowWidth: windowWidth)
    let band = point.y >= 0 && point.y < hoverHeight && point.x >= bandLeft && point.x < panel.maxX
    return panel.contains(point) || band
  }

  public static func offset(_ slide: Double) -> CGFloat { -travel * CGFloat(1 - slide) }
}

public struct StripPeekLook: Decodable, Equatable, Sendable {
  public var fill: String
  public var border: String
  public var shadowOpacity: Double

  public init(fill: String, border: String, shadowOpacity: Double) {
    self.fill = fill
    self.border = border
    self.shadowOpacity = shadowOpacity
  }
}

@MainActor
public final class StripPeekView: NSView {
  public let peek = EdgePeek(enabled: false, arc: false)
  public let panel = StripPeekPanel()
  public var bandLeft: CGFloat = 0
  public var onLive: (Bool) -> Void = { _ in }
  public var content: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let content { panel.addSubview(content) }
      needsLayout = true
    }
  }
  public var look = StripPeekLook(fill: "#202020", border: "#FFFFFF1A", shadowOpacity: 0.3) {
    didSet { if look != oldValue { panel.apply(look) } }
  }

  private var stopped = false
  private let slide = DockAnimator(value: 0)
  private var settled: (() -> Void)?
  private var monitor: Any? {
    didSet { Self.monitors += (monitor != nil ? 1 : 0) - (oldValue != nil ? 1 : 0) }
  }
  public private(set) static var monitors = 0
  private var inside = false
  public private(set) var slideTrace: [[Double]]?
  private var tickedAt: CFTimeInterval = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    panel.apply(look)
    panel.isHidden = true
    addSubview(panel)
    slide.now = { [weak self] in
      let now = CACurrentMediaTime()
      self?.tickedAt = now
      return now
    }
    slide.onChange = { [weak self] value in
      guard let self else { return }
      self.slideTrace?.append([self.tickedAt * 1000, value])
      self.place()
    }
    slide.onSettle = { [weak self] _ in
      let done = self?.settled
      self?.settled = nil
      done?()
    }
    peek.animate = { [weak self] to, curve, done in
      guard let self else { return done() }
      if !self.slide.moving && self.slide.value == to { return done() }
      self.settled = done
      self.slide.animate(to: to, curve: curve, in: self)
    }
    peek.onLive = { [weak self] live in
      self?.panel.isHidden = !live
      self?.place()
      self?.onLive(live)
    }
    #if DEBUG
    DevPointer.observe(self, #selector(devPointer(_:)))
    #endif
  }

  required init?(coder: NSCoder) { fatalError() }

  public var live: Bool { peek.live }
  public var slideValue: Double { slide.value }
  public var watching: Bool { monitor != nil }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    peek.setEnabled(false)
    peek.stop()
    slide.stop()
    settled = nil
    unwatch()
    onLive = { _ in }
    panel.isHidden = true
  }

  public func setEnabled(_ enabled: Bool) {
    guard !stopped else { return }
    peek.setEnabled(enabled)
    watch()
  }

  public func step(by seconds: Double) { slide.step(by: seconds) }

  public func pin(_ value: Double) { slide.jump(to: value) }

  public func traceSlide() { slideTrace = [[CACurrentMediaTime() * 1000, slide.value]] }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard live, let superview else { return nil }
    let local = convert(point, from: superview)
    guard panel.frame.contains(local) else { return nil }
    let hit = super.hitTest(point)
    return hit === self || hit === panel ? nil : hit
  }

  public override func layout() {
    super.layout()
    place()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    watch()
  }

  public func pointer(at point: CGPoint?) {
    guard !stopped else { return }
    let next = point.map { StripPeekMetrics.holds($0, windowWidth: bounds.width, bandLeft: bandLeft) } ?? false
    if next == inside { return }
    inside = next
    if next { peek.show() } else if live { peek.hide() }
  }

  private func place() {
    let frame = StripPeekMetrics.panel(windowWidth: bounds.width)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.frame = frame.offsetBy(dx: 0, dy: StripPeekMetrics.offset(slide.value))
    panel.alphaValue = CGFloat(slide.value)
    content?.frame = StripPeekMetrics.row(in: frame.size)
    CATransaction.commit()
  }

  private func watch() {
    guard !stopped, window != nil, peek.enabled else { return unwatch() }
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .leftMouseDragged]) { [weak self] event in
      MainActor.assumeIsolated { self?.observe(event) }
      return event
    }
  }

  private func unwatch() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    inside = false
  }

  private func observe(_ event: NSEvent) {
    guard let window, event.window === window else { return }
    pointer(at: convert(event.locationInWindow, from: nil))
  }

  #if DEBUG
  @objc private func devPointer(_ note: Notification) {
    guard peek.enabled, let window else { return }
    guard let screen = (note.object as? NSValue)?.pointValue else { return pointer(at: nil) }
    pointer(at: convert(window.convertPoint(fromScreen: screen), from: nil))
  }
  #endif
}

@MainActor
public final class StripPeekPanel: NSView {
  private let plate = CALayer()
  private let shade = CALayer()
  private let shadowMask = CAShapeLayer()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    shadowMask.fillRule = .evenOdd
    shade.mask = shadowMask
    shade.shadowColor = NSColor.black.cgColor
    shade.shadowRadius = StripPeekMetrics.shadowRadius
    shade.shadowOffset = CGSize(width: 0, height: StripPeekMetrics.shadowOffset)
    plate.cornerRadius = StripPeekMetrics.radius
    plate.cornerCurve = .continuous
    plate.borderWidth = StripPeekMetrics.border
    layer?.addSublayer(shade)
    layer?.addSublayer(plate)
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(_ look: StripPeekLook) {
    plate.backgroundColor = SidebarPalette.parse(look.fill)?.cgColor
    plate.borderColor = SidebarPalette.parse(look.border)?.cgColor
    shade.shadowOpacity = Float(look.shadowOpacity)
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    let shape = CGPath(roundedRect: bounds, cornerWidth: StripPeekMetrics.radius, cornerHeight: StripPeekMetrics.radius, transform: nil)
    shade.frame = bounds
    shade.shadowPath = shape
    let outset = StripPeekMetrics.shadowRadius * 3 + StripPeekMetrics.shadowOffset + 4
    let mask = CGMutablePath()
    mask.addRect(bounds.insetBy(dx: -outset, dy: -outset))
    mask.addPath(shape)
    shadowMask.frame = bounds
    shadowMask.path = mask
    CATransaction.commit()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }
}
