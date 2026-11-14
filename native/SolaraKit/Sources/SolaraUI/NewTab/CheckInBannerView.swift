import AppKit
import QuartzCore

public struct CheckInBannerState: Decodable, Equatable, Sendable {
  public var visible: Bool
  public var dark: Bool
  public var title: String
  public var action: String
  public var profileId: String
  public var token: String
  public var icon: String
  public var focusContext: String?

  public static func decode(_ json: String) -> Self? {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(Self.self, from: data), !state.profileId.isEmpty, !state.token.isEmpty else { return nil }
    return state
  }
}

public final class CheckInBannerView: NSView {
  public private(set) var state: CheckInBannerState?
  public var onAction: (String, String, String) -> Void = { _, _, _ in }
  public var appIcon: NSImage? { didSet { icon.image = appIcon } }
  public let card = CheckInControl()
  public let close = CheckInControl()
  public private(set) var hovered = false
  public private(set) var motion: CheckInMotion?
  private let plate = BarSurfaceView()
  private let icon = NSImageView()
  private let title = OnboardingTextNSView()
  private let action = OnboardingTextNSView()
  private let arrow = NSImageView()
  private let closeBlur = NSVisualEffectView()
  private let closeFill = BarSurfaceView()
  private let closeGlyph = NSImageView()
  private var pressed = false
  private var closeHovered = false
  private var timer: Timer?
  private var presentation = UUID()
  private var pending: (String, String, UUID)?
  private var tracking: NSTrackingArea?
  #if DEBUG
    public private(set) var trace: [[String: Double]] = []
  #endif
  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    card.wantsLayer = true
    close.wantsLayer = true
    close.acceptsFirstClick = true
    card.containsPointer = { [weak self] point in
      guard let self else { return false }
      return self.pointerTarget(at: self.convert(point, from: nil)) === self.card
    }
    close.containsPointer = { [weak self] point in
      guard let self else { return false }
      return self.pointerTarget(at: self.convert(point, from: nil)) === self.close
    }
    close.setAccessibilityLabel("Dismiss")
    close.toolTip = "Dismiss"
    card.onHover = { [weak self] value in if value { self?.setHovered(true) } }
    card.onPressed = { [weak self] in self?.setPressed($0) }
    close.onHover = { [weak self] value in self?.closeHovered = value; if value { self?.setHovered(true) }; self?.refreshStyle() }
    close.onPressed = { [weak self] _ in self?.refreshStyle() }
    close.onFocus = { [weak self] in self?.applyMotion() }
    card.addSubview(plate)
    icon.imageScaling = .scaleAxesIndependently
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 6
    icon.layer?.masksToBounds = true
    for view in [icon, title, action, arrow] { view.setAccessibilityElement(false); card.addSubview(view) }
    arrow.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
    arrow.imageScaling = .scaleNone
    closeBlur.material = .hudWindow
    closeBlur.blendingMode = .withinWindow
    closeBlur.state = .active
    closeBlur.wantsLayer = true
    closeBlur.layer?.cornerRadius = 11.5
    closeBlur.layer?.masksToBounds = true
    close.addSubview(closeBlur)
    close.addSubview(closeFill)
    closeGlyph.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    closeGlyph.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    closeGlyph.imageScaling = .scaleNone
    close.addSubview(closeGlyph)
    for view in [closeBlur, closeFill, closeGlyph] { view.setAccessibilityElement(false) }
    addSubview(card)
    addSubview(close)
    isHidden = true
  }

  public required init?(coder: NSCoder) { nil }

  public func update(_ next: CheckInBannerState?) {
    let changed = state?.profileId != next?.profileId || state?.visible != next?.visible || state?.token != next?.token
    let shown = state?.visible == true
    if changed {
      presentation = UUID()
      pending = nil
      card.cancelPress()
      close.cancelPress()
    }
    state = next
    isHidden = next?.visible != true
    guard let next, next.visible else {
      stop()
      motion = nil
      hovered = false
      pressed = false
      card.onPress = nil
      close.onPress = nil
      if let focused = window?.firstResponder as? NSView, focused === self || focused.isDescendant(of: self) { window?.makeFirstResponder(nil) }
      return
    }
    if !shown || motion == nil || changed && motion?.leaving == true {
      motion = CheckInMotion(at: ProcessInfo.processInfo.systemUptime)
      #if DEBUG
        trace.removeAll()
      #endif
      start()
    }
    let current = presentation
    card.onPress = { [weak self] in self?.leave("feedback", presentation: current) }
    close.onPress = { [weak self] in self?.leave("dismiss", presentation: current) }
    card.setAccessibilityLabel("\(next.title) \(next.action)")
    refreshStyle()
    needsLayout = true
    layoutSubtreeIfNeeded()
    applyMotion()
    window?.recalculateKeyViewLoop()
  }

  public override func layout() {
    super.layout()
    card.frame = CGRect(x: 8, y: 8, width: 266, height: 53)
    plate.frame = card.bounds
    icon.frame = CGRect(x: 10, y: 8, width: 37, height: 37)
    let titleSize = title.measure(width: 195)
    let actionSize = action.measure(width: 195)
    let top = (53 - titleSize.height - actionSize.height - 2) / 2
    title.frame = CGRect(x: 61, y: top, width: 195, height: titleSize.height)
    action.frame = CGRect(x: 61, y: top + titleSize.height + 2, width: actionSize.width, height: actionSize.height)
    arrow.frame = CGRect(x: action.frame.maxX + 3, y: action.frame.midY - 5.5, width: 11, height: 11)
    close.frame = CGRect(x: 259, y: 0, width: 23, height: 23)
    for view in [closeBlur, closeFill, closeGlyph] { view.frame = close.bounds }
    applyMotion()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    pointerTarget(at: convert(point, from: superview))
  }

  private func pointerTarget(at local: NSPoint) -> NSView? {
    guard state?.visible == true, motion?.leaving != true, !isHidden else { return nil }
    let scale = motion?.scale ?? 1
    let unscaled = CGPoint(x: card.frame.midX + (local.x - card.frame.midX) / scale, y: card.frame.midY + (local.y - card.frame.midY) / scale)
    if hovered, close.frame.contains(unscaled) { return close }
    return card.frame.contains(unscaled) ? card : nil
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, window != nil { update(nil) }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: CGRect(x: 8, y: 0, width: 274, height: 61), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
    tracking = area
    addTrackingArea(area)
  }

  public override func mouseEntered(with event: NSEvent) { setHovered(true) }
  public override func mouseExited(with event: NSEvent) { setHovered(false) }

  private func refreshStyle() {
    guard let state else { return }
    let dark = state.dark
    plate.fill = CSSColor(dark ? "#FFFFFF17" : "#FFFFFF80")!.ns
    plate.radius = 10
    plate.borderColor = CSSColor(dark ? "#FFFFFF0A" : "#00000014")!.ns
    plate.borderWidth = 1
    plate.shadowColor = .black
    plate.shadowOpacity = dark ? 0.3 : 0.1
    plate.shadowRadius = 24
    plate.shadowOffset = CGSize(width: 0, height: 8)
    let titleColor = (dark ? NSColor.white : .black).withAlphaComponent(0.8)
    let actionColor = (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.6 : 0.53)
    title.apply(OnboardingTextLayout(text: state.title, size: 13, weight: 500, color: titleColor, lineHeight: nil, kerning: 0, lines: 1, alignment: .left))
    action.apply(OnboardingTextLayout(text: state.action, size: 12, weight: 400, color: actionColor, lineHeight: nil, kerning: 0, lines: 1, alignment: .left))
    arrow.contentTintColor = actionColor
    closeFill.fill = CSSColor(dark ? (closeHovered ? "#FFFFFF4D" : "#FFFFFF14") : (closeHovered ? "#0000004D" : "#00000033"))!.ns
    closeFill.radius = 11.5
    closeFill.borderColor = CSSColor(dark ? "#FFFFFF1F" : "#00000014")!.ns
    closeFill.borderWidth = 1
  }

  private func setHovered(_ value: Bool) {
    hovered = value
    motion?.target(hovered: hovered, pressed: pressed, at: ProcessInfo.processInfo.systemUptime)
    applyMotion()
    start()
  }

  private func setPressed(_ value: Bool) {
    pressed = value
    motion?.target(hovered: hovered, pressed: pressed, at: ProcessInfo.processInfo.systemUptime)
    start()
  }

  private func leave(_ action: String, presentation: UUID) {
    guard self.presentation == presentation, let state, state.visible, motion?.leaving == false else { return }
    pending = (action, state.profileId, presentation)
    motion?.leave(at: ProcessInfo.processInfo.systemUptime)
    card.interactionEnabled = false
    close.interactionEnabled = false
    start()
  }

  private func start() {
    guard timer == nil, motion != nil else { return }
    let made = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(made, forMode: .common)
    timer = made
  }

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    motion?.step(at: now)
    applyMotion()
    #if DEBUG
      if let motion { trace.append(["time": now, "elapsed": now - motion.devStartedAt, "opacity": motion.opacity, "scale": motion.scale, "leaving": motion.leaving ? 1 : 0]); if trace.count > 360 { trace.removeFirst() } }
    #endif
    guard motion?.finished == true else { return }
    stop()
    if let pending, pending.2 == presentation, state?.profileId == pending.1 {
      self.pending = nil
      onAction(pending.0, pending.1, state!.token)
    }
  }

  private func applyMotion() {
    guard let motion else { return }
    card.interactionEnabled = !motion.leaving
    close.interactionEnabled = !motion.leaving
    card.alphaValue = motion.opacity
    close.alphaValue = hovered || close.focused ? motion.opacity : 0
    card.layer?.setAffineTransform(CGAffineTransform(translationX: card.bounds.midX * (1 - motion.scale), y: card.bounds.midY * (1 - motion.scale)).scaledBy(x: motion.scale, y: motion.scale))
    let dx = (close.frame.minX - card.frame.midX) * (motion.scale - 1)
    let dy = (close.frame.minY - card.frame.midY) * (motion.scale - 1)
    close.layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: motion.scale, y: motion.scale))
  }

  private func stop() { timer?.invalidate(); timer = nil }

  isolated deinit { timer?.invalidate() }

  #if DEBUG
    public func devHover(_ value: Bool) { setHovered(value) }
  #endif
}
