import AppKit
import QuartzCore

public enum SwipeCapsuleMetrics {
  public static let size: CGFloat = 72
  public static let sizeConfirmed: CGFloat = 82
  public static let inset: CGFloat = 14
  public static let icon: CGFloat = 28
  public static let iconConfirmed: CGFloat = 34
  public static let listWidth: CGFloat = 200
  public static let row: CGFloat = 38
  public static let listPad: CGFloat = 8
  public static let listRadius: CGFloat = 18
  public static let ease = BezierCurve(0.25, 0.46, 0.45, 0.94)
  public static let easeIn = BezierCurve(0.42, 0, 1, 1)
  public static let confirmDuration = 0.18
  public static let listDuration = 0.22
  public static let dismissDuration = 0.2
  public static let confirmSpring = SpringParams(response: 0.18, dampingRatio: 0.7)
  public static let listSpring = SpringParams(response: 0.22, dampingRatio: 0.77)
  public static let pillSpring = SpringParams(response: 0.27, dampingRatio: 0.9)
}

public enum SwipeCapsuleDirection: String, Decodable, Sendable {
  case back, forward
}

public struct SwipeCapsuleItem: Decodable, Equatable, Sendable {
  public var title: String
  public var url: String
  public var favicon: String?
  public var newTab: Bool

  public init(title: String, url: String, favicon: String? = nil, newTab: Bool = false) {
    self.title = title
    self.url = url
    self.favicon = favicon
    self.newTab = newTab
  }
}

public struct SwipeCapsuleTheme: Decodable, Equatable, Sendable {
  public var dark: Bool
  public var textPrimary: String
  public var textSecondary: String

  public init(dark: Bool, textPrimary: String, textSecondary: String) {
    self.dark = dark
    self.textPrimary = textPrimary
    self.textSecondary = textSecondary
  }
}

struct SwipeCurveTween: Equatable {
  var from: Double
  var to: Double
  var start: CFTimeInterval
  var duration: CFTimeInterval
  var curve: BezierCurve

  static func resting(_ v: Double) -> SwipeCurveTween { SwipeCurveTween(from: v, to: v, start: 0, duration: 0, curve: SwipeCapsuleMetrics.ease) }

  func value(at time: CFTimeInterval) -> Double {
    guard duration > 0 else { return to }
    let t = (time - start) / duration
    if t >= 1 { return to }
    if t <= 0 { return from }
    return from + (to - from) * curve(t)
  }

  func finished(at time: CFTimeInterval) -> Bool { duration <= 0 || time - start >= duration }
}

public struct SwipeCapsuleSample: Equatable, Sendable {
  public var frame: CGRect
  public var radius: CGFloat
  public var opacity: Double
  public var scale: Double
  public var iconScale: Double
  public var iconOpacity: Double
  public var list: Double
  public var pill: Double
}

@MainActor
public final class SwipeCapsuleView: NSView {
  public var onDismissed: (() -> Void)?
  public var favicons: SidebarFavicons?
  public private(set) var direction = SwipeCapsuleDirection.back
  public private(set) var confirmed = false
  public private(set) var items: [SwipeCapsuleItem]?
  public private(set) var selected = 0
  public private(set) var active = false

  private var theme = SwipeCapsuleTheme(dark: false, textPrimary: "#000000D9", textSecondary: "#00000080")
  private var profileId = ""
  private var height: CGFloat = 0
  private var x: CGFloat = -SwipeCapsuleMetrics.size
  private var nudge: CGFloat = 0
  private var w = SpringTrack.resting(SwipeCapsuleMetrics.size)
  private var h = SpringTrack.resting(SwipeCapsuleMetrics.size)
  private var top = SpringTrack.resting(0)
  private var radius = SpringTrack.resting(SwipeCapsuleMetrics.size / 2)
  private var icon = SpringTrack.resting(1)
  private var pill = SpringTrack.resting(0)
  private var confirm = SwipeCurveTween.resting(0)
  private var list = SwipeCurveTween.resting(0)
  private var fade = SwipeCurveTween.resting(1)
  private var scale = SwipeCurveTween.resting(1)
  private var dismissing = false
  private var link: CADisplayLink?
  private var dismissal: DispatchWorkItem?

  private let box = PrimitiveFlippedView()
  private let glow = CALayer()
  private let clip = PrimitiveFlippedView()
  private let effect = NSVisualEffectView()
  private let wash = PrimitiveFlippedView()
  private let iconHolder = PrimitiveFlippedView()
  private let chevron = NSImageView()
  private let border = PrimitiveFlippedView()
  private var listView: PrimitiveFlippedView?
  private var pillLayer: CALayer?
  private var rowTitles: [NSTextField] = []

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    box.wantsLayer = true
    box.isHidden = true
    addSubview(box)
    glow.shadowColor = NSColor.black.cgColor
    glow.shadowRadius = 8
    glow.shadowOffset = CGSize(width: 0, height: 2)
    glow.actions = SurfaceLayer.noActions
    box.layer?.addSublayer(glow)
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    clip.layer?.cornerCurve = .circular
    box.addSubview(clip)
    effect.material = .popover
    effect.blendingMode = .withinWindow
    effect.state = .active
    clip.addSubview(effect)
    effect.wantsLayer = true
    wash.wantsLayer = true
    wash.layer?.backgroundColor = NSColor(white: 1, alpha: 0.4).cgColor
    clip.addSubview(wash)
    iconHolder.wantsLayer = true
    chevron.imageScaling = .scaleNone
    iconHolder.addSubview(chevron)
    clip.addSubview(iconHolder)
    border.wantsLayer = true
    border.layer?.borderWidth = 1
    box.addSubview(border)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func show(_ direction: SwipeCapsuleDirection, theme next: SwipeCapsuleTheme, profileId: String, now: CFTimeInterval = CACurrentMediaTime()) {
    let M = SwipeCapsuleMetrics.self
    dismissal?.cancel()
    dismissal = nil
    self.direction = direction
    theme = next
    self.profileId = profileId
    height = bounds.height
    x = -M.size
    nudge = 0
    w = .resting(M.size)
    h = .resting(M.size)
    top = .resting(height / 2 - M.size / 2)
    radius = .resting(M.size / 2)
    icon = .resting(1)
    pill = .resting(0)
    confirm = .resting(0)
    list = .resting(0)
    fade = .resting(1)
    scale = .resting(1)
    confirmed = false
    items = nil
    selected = 0
    dismissing = false
    active = true
    styleForTheme()
    chevron.image = NSImage(systemSymbolName: direction == .back ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: M.icon, weight: .bold))
    chevron.contentTintColor = CSSColor(theme.dark ? "#FFFFFFD9" : "#000000D9")?.ns
    removeList()
    box.isHidden = false
    apply(at: now)
  }

  public func move(x next: CGFloat? = nil, nudge nextNudge: CGFloat? = nil, now: CFTimeInterval = CACurrentMediaTime()) {
    if let next { x = next }
    if let nextNudge { nudge = nextNudge }
    apply(at: now)
  }

  public func setConfirmed(_ next: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
    guard next != confirmed else { return }
    let M = SwipeCapsuleMetrics.self
    confirmed = next
    if items == nil {
      let s = next ? M.sizeConfirmed : M.size
      layout(to: s, s, height / 2 - s / 2, s / 2, M.confirmSpring, now)
      icon = retarget(icon, next ? Double(M.iconConfirmed / M.icon) : 1, M.confirmSpring, now)
    }
    confirm = SwipeCurveTween(from: confirm.value(at: now), to: next ? 1 : 0, start: now, duration: M.confirmDuration, curve: M.ease)
    run(now)
  }

  public func presentList(_ next: [SwipeCapsuleItem], now: CFTimeInterval = CACurrentMediaTime()) {
    let M = SwipeCapsuleMetrics.self
    items = next
    selected = 0
    layout(to: M.listWidth, CGFloat(next.count) * M.row + M.listPad * 2, height / 2 - M.listPad - M.row / 2, M.listRadius, M.listSpring, now)
    list = SwipeCurveTween(from: list.value(at: now), to: 1, start: now, duration: M.listDuration, curve: M.ease)
    buildList()
    run(now)
  }

  public func select(_ index: Int, now: CFTimeInterval = CACurrentMediaTime()) {
    guard items != nil, index != selected else { return }
    selected = index
    pill = retarget(pill, Double(CGFloat(index) * SwipeCapsuleMetrics.row), SwipeCapsuleMetrics.pillSpring, now)
    for (i, title) in rowTitles.enumerated() { paint(title, i) }
    run(now)
  }

  public func dismiss(delay: Double = 0, now: CFTimeInterval = CACurrentMediaTime()) {
    let M = SwipeCapsuleMetrics.self
    dismissal?.cancel()
    active = false
    dismissing = true
    fade = SwipeCurveTween(from: fade.value(at: now), to: 0, start: now + delay, duration: M.dismissDuration, curve: M.easeIn)
    scale = SwipeCurveTween(from: scale.value(at: now), to: 0.01, start: now + delay, duration: M.dismissDuration, curve: M.easeIn)
    let deadline = (now + delay + M.dismissDuration).nextUp
    let completion = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.finishDismissal(at: CACurrentMediaTime()) }
    }
    dismissal = completion
    let remaining = max(0, deadline - CACurrentMediaTime())
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(ceil(remaining * 1_000_000_000))), execute: completion)
    run(now)
  }

  func finishDismissal(at now: CFTimeInterval) {
    guard dismissing, fade.finished(at: now), scale.finished(at: now) else { return }
    apply(at: now)
    dismissing = false
    box.isHidden = true
    dismissal?.cancel()
    dismissal = nil
    stop()
    onDismissed?()
  }

  public var shown: Bool { !box.isHidden }

  public func sample(at now: CFTimeInterval = CACurrentMediaTime()) -> SwipeCapsuleSample {
    let width = CGFloat(w.value(at: now))
    let left = direction == .back ? x : bounds.width - x - width
    let frame = CGRect(x: left, y: CGFloat(top.value(at: now)) + nudge, width: width, height: CGFloat(h.value(at: now)))
    let iconOpacity = (0.5 + 0.5 * confirm.value(at: now)) * (1 - list.value(at: now))
    return SwipeCapsuleSample(frame: frame, radius: CGFloat(radius.value(at: now)), opacity: fade.value(at: now), scale: scale.value(at: now), iconScale: icon.value(at: now),
      iconOpacity: iconOpacity, list: list.value(at: now), pill: pill.value(at: now))
  }

  private func retarget(_ track: SpringTrack, _ to: Double, _ params: SpringParams, _ now: CFTimeInterval) -> SpringTrack {
    SpringTrack(params, from: track.value(at: now), to: to, velocity: track.velocity(at: now), start: now)
  }

  private func layout(to width: CGFloat, _ height: CGFloat, _ y: CGFloat, _ r: CGFloat, _ params: SpringParams, _ now: CFTimeInterval) {
    w = retarget(w, Double(width), params, now)
    h = retarget(h, Double(height), params, now)
    top = retarget(top, Double(y), params, now)
    radius = retarget(radius, Double(r), params, now)
  }

  private func styleForTheme() {
    let dark = theme.dark
    glow.shadowOpacity = dark ? 0.25 : 0.2
    effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    wash.isHidden = dark
    border.layer?.borderColor = CSSColor(dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.125)")?.cg
  }

  private func paint(_ title: NSTextField, _ i: Int) {
    let color = (CSSColor(i == selected ? theme.textPrimary : theme.textSecondary) ?? CSSColor("#000000")!).ns
    title.textColor = color.withAlphaComponent(1)
    title.alphaValue = color.alphaComponent
  }

  private func removeList() {
    listView?.removeFromSuperview()
    listView = nil
    pillLayer = nil
    rowTitles = []
  }

  private func buildList() {
    removeList()
    guard let items else { return }
    let M = SwipeCapsuleMetrics.self
    let view = PrimitiveFlippedView(frame: CGRect(x: 0, y: 0, width: M.listWidth, height: CGFloat(items.count) * M.row + M.listPad * 2))
    view.wantsLayer = true
    let pill = CALayer()
    pill.cornerRadius = 10
    pill.backgroundColor = (theme.dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    pill.actions = SurfaceLayer.noActions
    pill.frame = CGRect(x: 8, y: M.listPad, width: M.listWidth - 16, height: M.row)
    view.layer?.addSublayer(pill)
    let palette = SidebarPalette(SidebarHostState(profileId: profileId, dark: theme.dark))
    for (i, item) in items.enumerated() {
      let y = M.listPad + CGFloat(i) * M.row
      let slot = TabIconView(frame: CGRect(x: 18, y: y + (M.row - 16) / 2, width: 16, height: 16))
      slot.favicons = favicons
      slot.wantsLayer = true
      slot.layer?.cornerRadius = 4
      slot.layer?.masksToBounds = true
      slot.set(TabIconSpec(url: item.newTab ? "" : item.url, favicon: item.newTab ? nil : item.favicon, customIcon: nil, profileId: profileId), palette: palette)
      view.addSubview(slot)
      let title = NSTextField(labelWithString: item.title)
      title.font = .systemFont(ofSize: 13)
      paint(title, i)
      title.lineBreakMode = .byTruncatingTail
      let th = title.intrinsicContentSize.height
      let left: CGFloat = 18 + 16 + 10
      title.frame = CGRect(x: left - 2, y: y + (M.row - th) / 2, width: M.listWidth - left - 18 + 4, height: th)
      view.addSubview(title)
      rowTitles.append(title)
    }
    clip.addSubview(view)
    listView = view
    pillLayer = pill
  }

  public func rebuildIcons(now: CFTimeInterval = CACurrentMediaTime()) {
    guard items != nil else { return }
    buildList()
    apply(at: now)
  }

  private var settled: Bool {
    let now = CACurrentMediaTime()
    let springs = [w, h, top, radius, icon, pill].allSatisfy { now - $0.start >= $0.duration }
    let tweens = [confirm, list, fade, scale].allSatisfy { $0.finished(at: now) }
    return springs && tweens
  }

  private func run(_ now: CFTimeInterval) {
    apply(at: now)
    guard link == nil else { return }
    let made = displayLink(target: self, selector: #selector(tick(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(made)
    #endif
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func tick(_ link: CADisplayLink) { tick(at: CACurrentMediaTime()) }

  func tick(at now: CFTimeInterval) {
    apply(at: now)
    if dismissing, fade.finished(at: now), scale.finished(at: now) {
      finishDismissal(at: now)
      return
    }
    if settled { stop() }
  }

  private func stop() {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(link)
    #endif
    link?.invalidate()
    link = nil
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { stop() }
  }

  private func apply(at now: CFTimeInterval) {
    let M = SwipeCapsuleMetrics.self
    let s = sample(at: now)
    PrimitiveMotion.setInstantly {
      box.frame = s.frame
      let bounds = CGRect(origin: .zero, size: s.frame.size)
      let centre = CGPoint(x: bounds.midX, y: bounds.midY)
      box.layer?.opacity = Float(s.opacity)
      box.layer?.sublayerTransform = PrimitiveMotion.scale(about: centre, scale: s.scale, translateY: 0)
      let surfaceRadius = items != nil ? M.listRadius : (confirmed ? M.sizeConfirmed : M.size) / 2
      glow.frame = bounds
      glow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: min(surfaceRadius, bounds.width / 2, bounds.height / 2), cornerHeight: min(surfaceRadius, bounds.width / 2, bounds.height / 2), transform: nil)
      clip.frame = bounds
      clip.layer?.cornerRadius = s.radius
      effect.frame = bounds
      wash.frame = bounds
      wash.layer?.opacity = Float(confirm.value(at: now))
      border.frame = bounds
      border.layer?.cornerRadius = s.radius
      iconHolder.frame = bounds
      let box = M.icon + 6
      chevron.frame = CGRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
      iconHolder.layer?.opacity = Float(s.iconOpacity)
      iconHolder.layer?.sublayerTransform = PrimitiveMotion.scale(about: centre, scale: s.iconScale, translateY: 0)
      if let listView {
        let lb = listView.bounds
        listView.layer?.opacity = Float(s.list)
        listView.layer?.sublayerTransform = PrimitiveMotion.scale(about: CGPoint(x: lb.midX, y: lb.midY), scale: 0.9 + 0.1 * s.list, translateY: 0)
        pillLayer?.frame.origin.y = M.listPad + CGFloat(s.pill)
      }
    }
  }
}
