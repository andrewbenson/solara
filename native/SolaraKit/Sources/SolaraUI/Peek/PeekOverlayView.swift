import AppKit
import QuartzCore
import SolaraModel
import SolaraStore

public struct PeekPoint: Decodable, Equatable, Sendable {
  public var x: Double
  public var y: Double
}

public struct PeekState: Decodable, Equatable, Sendable {
  public var tabId: String
  public var dark: Bool
  public var host: String
  public var title: String
  public var favicon: String?
  public var insecure: Bool
  public var loading: Double?
  public var splitFull: Bool
  public var fullscreen: Bool
  public var from: PeekPoint?
  public var reduceMotion: Bool
  public var palette: ToolbarPaletteState
  public var panel: String
  public var card: String
  public var accent: String
}

extension PeekState {
  public static func native(state: BrowserState, windowId: String, card: CGRect, tokens: [String: String], dark: Bool,
    fullscreen: Bool = false, reduceMotion: Bool = false) -> PeekState? {
    guard state.windows[windowId] != nil, let peek = state.peeks[windowId], let tab = state.tabs[peek.tabId],
      let source = state.tabs[peek.sourceId], source.windowId == windowId, tab.windowId == windowId,
      state.activeTabId(windowId) == peek.sourceId, source.url.components(separatedBy: "#").first == peek.sourcePage else { return nil }
    let text = tokens["textPrimary"] ?? (dark ? "#FFFFFF" : "#000000CC")
    let secondary = tokens["textSecondary"] ?? (dark ? "#FFFFFF80" : "#00000080")
    let icon = tokens["icon"] ?? text
    let hover = tokens["toolbarHover"] ?? (dark ? "#FFFFFF1A" : "#0000000F")
    let pressed = tokens["toolbarPressed"] ?? (dark ? "#FFFFFF2E" : "#0000001A")
    return PeekState(tabId: peek.tabId, dark: dark, host: URL(string: tab.url)?.host ?? "", title: tab.customTitle ?? tab.title,
      favicon: tab.favicon, insecure: tab.url.lowercased().hasPrefix("http:"), loading: state.live[tab.id]?.isLoading == true ? 0.08 : nil,
      splitFull: (Splits.splitOf(state, peek.sourceId)?.tabIds.count ?? 0) >= Splits.maxPanes, fullscreen: fullscreen,
      from: peek.from.map { PeekPoint(x: $0.x - card.minX, y: $0.y - card.minY) }, reduceMotion: reduceMotion,
      palette: ToolbarPaletteState(background: nil, text: text, secondary: secondary, icon: icon, iconDisabled: secondary,
        hover: hover, pressed: pressed, pill: hover, divider: tokens["panelBorder"] ?? pressed, urlHost: nil, urlPath: nil),
      panel: tokens["panel"] ?? (dark ? "#2A2A2A" : "#FFFFFF"), card: tokens["card"] ?? (dark ? "#12121280" : "#FFFFFFB3"),
      accent: tokens["accent"] ?? "#3478F6")
  }
}

public enum PeekEvent: Equatable, Sendable {
  case dismiss
  case openAsTab
  case openInSplit
  case closed(String)
}

@MainActor
public final class PeekOverlayView: FrameLayoutView {
  public var onEvent: (PeekEvent) -> Void = { _ in }
  public let pageSlot = FrameLayoutView()
  public let backdropSlot = FrameLayoutView()
  public private(set) var state: PeekState?

  private let dim = PeekDimView()
  private let card = FlippedView()
  private let surface = CALayer()
  private let clip = FlippedView()
  private let outerRim = CALayer()
  private let bar = PeekBarView()
  private var progress: CGFloat = 0
  private var expand: CGFloat = 0
  private var leaving: Leaving?
  private var shownTab: String?
  private let lifetime = PeekLifetime()
  private var expandReply: ((Bool) -> Void)?

  private enum Leaving { case close, expand }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    dim.onPress = { [weak self] in self?.onEvent(.dismiss) }
    addSubview(dim)
    card.wantsLayer = true
    card.layer?.masksToBounds = false
    card.layer?.addSublayer(surface)
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    clip.layer?.cornerRadius = PeekMetrics.windowRadius
    clip.layer?.cornerCurve = .continuous
    clip.layer?.borderWidth = 0.5
    backdropSlot.autoresizingMask = [.width, .height]
    clip.addSubview(backdropSlot)
    clip.addSubview(bar)
    pageSlot.wantsLayer = true
    pageSlot.layer?.masksToBounds = true
    pageSlot.layer?.cornerRadius = PeekMetrics.cardRadius
    pageSlot.layer?.cornerCurve = .continuous
    clip.addSubview(pageSlot)
    card.addSubview(clip)
    outerRim.borderWidth = 0.5
    outerRim.cornerRadius = PeekMetrics.windowRadius + 0.5
    outerRim.cornerCurve = .continuous
    card.layer?.addSublayer(outerRim)
    addSubview(card)
    bar.onPress = { [weak self] id in
      guard let self else { return }
      switch id {
      case "split": self.onEvent(.openInSplit)
      case "tab": self.onEvent(.openAsTab)
      default: self.onEvent(.dismiss)
      }
    }
    let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:)))
    card.addGestureRecognizer(pinch)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard state != nil, !(leaving != nil) else { return nil }
    return super.hitTest(point)
  }

  public func apply(_ next: PeekState) {
    let fresh = shownTab != next.tabId
    lifetime.replace(next.tabId)
    if fresh {
      finishExpand(false)
      card.layer?.removeAllAnimations()
      dim.layer?.removeAllAnimations()
    }
    state = next
    shownTab = next.tabId
    let rim = next.dark ? CSSColor("rgba(255,255,255,0.1)")! : CSSColor("rgba(255,255,255,0)")!
    clip.layer?.borderColor = rim.cg
    outerRim.borderColor = (next.dark ? CSSColor("rgba(0,0,0,0.95)")! : CSSColor("rgba(0,0,0,0.15)")!).cg
    surface.backgroundColor = CSSColor(next.panel)?.cg
    surface.cornerRadius = PeekMetrics.windowRadius
    surface.cornerCurve = .continuous
    surface.shadowColor = CGColor(gray: 0, alpha: 1)
    surface.shadowOpacity = next.dark ? 0.66 : 0.38
    surface.shadowRadius = PeekMetrics.shadowRadius
    surface.shadowOffset = CGSize(width: 0, height: PeekMetrics.shadowOffset)
    pageSlot.layer?.backgroundColor = CSSColor(next.card)?.cg
    dim.color = next.dark ? CSSColor("rgba(0,0,0,0.45)")! : CSSColor("rgba(0,0,0,0.25)")!
    bar.apply(next)
    let chrome = !next.fullscreen
    for v: NSView in [dim, backdropSlot, bar] { v.isHidden = !chrome }
    surface.isHidden = !chrome
    outerRim.isHidden = !chrome
    clip.layer?.cornerRadius = chrome ? PeekMetrics.windowRadius : 0
    clip.layer?.borderWidth = chrome ? 0.5 : 0
    needsLayout = true
    layoutNativeContentIfNeeded()
    if fresh {
      leaving = nil
      progress = 0
      expand = 0
      show()
    } else {
      pose()
    }
  }

  public func layoutNativeContentIfNeeded() {
    layoutFrameIfNeeded()
    bar.layoutSubtreeIfNeeded()
  }

  public override func layout() {
    super.layout()
    guard let state else { return }
    dim.frame = bounds
    let frame = state.fullscreen ? bounds : PeekMetrics.frame(width: bounds.width, height: bounds.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    card.layer?.transform = CATransform3DIdentity
    card.frame = frame
    clip.frame = card.bounds
    surface.frame = card.bounds
    surface.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: PeekMetrics.windowRadius, cornerHeight: PeekMetrics.windowRadius, transform: nil)
    outerRim.frame = card.bounds.insetBy(dx: -0.5, dy: -0.5)
    backdropSlot.frame = clip.bounds
    bar.frame = CGRect(x: 0, y: 0, width: clip.bounds.width, height: PeekMetrics.barHeight)
    pageSlot.frame = state.fullscreen ? clip.bounds : PeekMetrics.pageFrame(in: clip.bounds.size)
    pageSlot.layer?.cornerRadius = state.fullscreen ? 0 : PeekMetrics.cardRadius
    CATransaction.commit()
    pose()
  }

  private var fade: Bool { state?.reduceMotion ?? false }

  private var from: CGPoint? { state?.from.map { CGPoint(x: min(max($0.x, 0), bounds.width), y: min(max($0.y, 0), bounds.height)) } }

  private func poseAt(_ progress: CGFloat, _ expand: CGFloat) -> PeekPose {
    let frame = PeekMetrics.frame(width: bounds.width, height: bounds.height)
    return PeekPose.at(progress: progress, expand: expand, frame: frame, container: bounds.size, from: from, fade: fade)
  }

  private func transform(_ p: PeekPose) -> CATransform3D {
    var t = CATransform3DMakeTranslation(p.translateX, p.translateY, 0)
    t = CATransform3DScale(t, p.scaleX, p.scaleY, 1)
    return t
  }

  private func pose() {
    guard let state, !state.fullscreen else {
      card.layer?.opacity = 1
      return
    }
    let p = poseAt(progress, expand)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    centreAnchor()
    card.layer?.transform = transform(p)
    card.layer?.opacity = Float(p.cardOpacity)
    dim.layer?.opacity = Float(p.dim)
    CATransaction.commit()
  }

  private func centreAnchor() {
    guard let layer = card.layer, layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) else { return }
    let frame = card.frame
    layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    layer.position = CGPoint(x: frame.midX, y: frame.midY)
  }

  private func animate(progress toProgress: CGFloat, expand toExpand: CGFloat, duration: Double, curve: (Double) -> Double, done: (() -> Void)? = nil) {
    let receipt = lifetime.receipt()
    let fromProgress = progress, fromExpand = expand
    progress = toProgress
    expand = toExpand
    guard let state, !state.fullscreen, let layer = card.layer, let dimLayer = dim.layer else {
      pose()
      done?()
      return
    }
    let steps = max(2, Int(duration * 60))
    var transforms: [NSValue] = [], opacities: [Float] = [], dims: [Float] = []
    for i in 0...steps {
      let k = CGFloat(curve(Double(i) / Double(steps)))
      let p = poseAt(fromProgress + (toProgress - fromProgress) * k, fromExpand + (toExpand - fromExpand) * k)
      transforms.append(NSValue(caTransform3D: transform(p)))
      opacities.append(Float(p.cardOpacity))
      dims.append(Float(p.dim))
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.lifetime.accepts(receipt) else { return }
        done?()
      }
    }
    pose()
    func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
      let a = CAKeyframeAnimation(keyPath: keyPath)
      a.values = values
      a.duration = duration
      a.calculationMode = .linear
      return a
    }
    layer.add(keyframes("transform", transforms), forKey: "peek")
    layer.add(keyframes("opacity", opacities), forKey: "peekOpacity")
    dimLayer.add(keyframes("opacity", dims), forKey: "peekDim")
    CATransaction.commit()
  }

  private func show() {
    if fade {
      animate(progress: 1, expand: 0, duration: PeekTiming.fade, curve: { 1 - (1 - $0) * (1 - $0) })
    } else {
      animate(progress: 1, expand: 0, duration: PeekSpring.settle, curve: PeekSpring.value)
    }
  }

  public override func cancelOperation(_ sender: Any?) {
    guard state != nil, leaving == nil else { return }
    onEvent(.dismiss)
  }

  public func close(expectedTabId: String? = nil) {
    guard expectedTabId == nil || expectedTabId == shownTab else { return }
    guard leaving == nil, let tab = shownTab else { return }
    leaving = .close
    animate(progress: 0, expand: 0, duration: PeekTiming.close, curve: { $0 * $0 * $0 }) { [weak self] in
      self?.onEvent(.closed(tab))
    }
  }

  public func expandToTab(expectedTabId: String? = nil, _ done: @escaping (Bool) -> Void) {
    guard expectedTabId == nil || expectedTabId == shownTab else { return done(false) }
    guard state != nil, leaving == nil else { return done(false) }
    expandReply = done
    leaving = .expand
    if fade {
      progress = 1
      pose()
      return finishExpand(true)
    }
    animate(progress: 1, expand: 1, duration: PeekTiming.expand, curve: { 1 - pow(1 - $0, 3) }) { [weak self] in
      self?.finishExpand(true)
    }
  }

  private func finishExpand(_ accepted: Bool) {
    let reply = expandReply
    expandReply = nil
    reply?(accepted)
  }

  public func apply(json: String) {
    guard !json.isEmpty, let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(PeekState.self, from: data) else { return clear() }
    apply(next)
  }

  public static func eventJSON(_ event: PeekEvent) -> [String: String] {
    switch event {
    case .dismiss: return ["kind": "dismiss"]
    case .openAsTab: return ["kind": "openAsTab"]
    case .openInSplit: return ["kind": "openInSplit"]
    case .closed(let tabId): return ["kind": "closed", "tabId": tabId]
    }
  }

  public func clear() {
    lifetime.replace(nil)
    finishExpand(false)
    state = nil
    shownTab = nil
    leaving = nil
    card.layer?.removeAllAnimations()
    dim.layer?.removeAllAnimations()
    card.layer?.opacity = 0
    dim.layer?.opacity = 0
  }

  @objc private func pinched(_ g: NSMagnificationGestureRecognizer) {
    guard leaving == nil, let state, !state.fullscreen else { return }
    switch g.state {
    case .began, .changed:
      if fade { return }
      card.layer?.removeAllAnimations()
      dim.layer?.removeAllAnimations()
      let follow = PeekPinch.follow(g.magnification)
      progress = follow.progress
      expand = follow.expand
      pose()
    case .ended, .cancelled:
      let outcome = g.state == .ended ? PeekPinch.outcome(g.magnification) : .stay
      if outcome == .close { return onEvent(.dismiss) }
      if outcome == .open { return onEvent(.openAsTab) }
      if fade { return }
      animate(progress: 1, expand: 0, duration: PeekSpring.settle, curve: PeekSpring.value)
    default:
      break
    }
  }
}

enum PeekSpring {
  static let settle: Double = 0.5

  static func value(_ t: Double) -> Double {
    let omega = 2 * Double.pi / PeekTiming.growResponse
    let zeta = PeekTiming.growDamping
    let time = t * settle
    let damped = omega * (1 - zeta * zeta).squareRoot()
    let x = 1 - exp(-zeta * omega * time) * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
    return t >= 1 ? 1 : min(x, 1)
  }
}

final class PeekDimView: NSView {
  var onPress: () -> Void = {}
  var color = CSSColor("rgba(0,0,0,0.25)")! { didSet { layer?.backgroundColor = color.cg } }
  private var pressed = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = PeekMetrics.cardRadius
    layer?.backgroundColor = color.cg
    setAccessibilityRole(.button)
    setAccessibilityLabel("Close Peek")
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    defer { pressed = false }
    if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
  }
}

final class PeekBarView: NSView {
  var onPress: (String) -> Void = { _ in }
  private let icon = NSImageView()
  private let host = NSTextField(labelWithString: "")
  private let title = NSTextField(labelWithString: "")
  private let progress = CALayer()
  private var buttons: [ToolbarButtonView] = []
  private var state: PeekState?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    icon.imageScaling = .scaleProportionallyDown
    for f in [host, title] {
      f.lineBreakMode = .byTruncatingTail
      f.maximumNumberOfLines = 1
      addSubview(f)
    }
    host.lineBreakMode = .byTruncatingHead
    host.font = .systemFont(ofSize: 13, weight: .medium)
    title.font = .systemFont(ofSize: 13)
    addSubview(icon)
    progress.cornerRadius = 1
    progress.opacity = 0.85
    layer?.addSublayer(progress)
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(_ next: PeekState) {
    state = next
    let palette = next.palette
    host.stringValue = next.host
    host.textColor = toolbarColor(palette.text)
    title.stringValue = next.title.isEmpty || next.title == next.host ? "" : "  \(next.title)"
    title.textColor = toolbarColor(palette.secondary)
    host.setAccessibilityLabel(next.host.isEmpty ? "Peek" : "Peek: \(next.host)")
    let symbol = next.insecure ? "lock.open.trianglebadge.exclamationmark.fill" : next.favicon == nil ? "globe" : nil
    if let symbol {
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
      icon.contentTintColor = toolbarColor(palette.secondary)
    } else if let uri = next.favicon, let url = URL(string: uri), let data = try? Data(contentsOf: url) {
      icon.image = NSImage(data: data)
      icon.contentTintColor = nil
    }
    progress.backgroundColor = CSSColor(next.accent)?.cg
    progress.isHidden = next.loading == nil
    let specs: [(String, String, Double, String, Bool)] = [
      ("split", "rectangle.split.2x1", 14, "Open in Split View", !next.splitFull),
      ("tab", "arrow.up.left.and.arrow.down.right", 13, "Open as Tab (⌘O)", true),
      ("close", "xmark", 13, "Close (Esc)", true),
    ]
    if buttons.isEmpty {
      for spec in specs {
        let b = ToolbarButtonView(state: Self.button(spec), palette: palette)
        let id = spec.0
        b.onClick = { [weak self] click in if click.kind == .press { self?.onPress(id) } }
        addSubview(b)
        buttons.append(b)
      }
    } else {
      for (b, spec) in zip(buttons, specs) {
        b.state = Self.button(spec)
        b.palette = palette
      }
    }
    needsLayout = true
  }

  static func button(_ spec: (String, String, Double, String, Bool)) -> ToolbarButtonState {
    ToolbarButtonState(
      id: spec.0, icon: spec.1, image: nil, imageSize: nil, dimmed: nil, badge: nil, anchor: nil, size: spec.2, box: Double(PeekMetrics.barButton),
      radius: 7, weight: nil, color: nil, enabled: spec.4, active: false, tooltip: spec.3, menu: false, longPress: false, middle: false, plain: false)
  }

  override func layout() {
    super.layout()
    let mid = PeekMetrics.barHeight / 2
    let count = CGFloat(buttons.count)
    let buttonsWidth = count * PeekMetrics.barButton + max(0, count - 1) * PeekMetrics.barButtonGap
    var x = bounds.width - PeekMetrics.pageInset - buttonsWidth
    for b in buttons {
      b.frame = CGRect(x: x, y: mid - PeekMetrics.barButton / 2, width: PeekMetrics.barButton, height: PeekMetrics.barButton)
      x += PeekMetrics.barButton + PeekMetrics.barButtonGap
    }
    let fieldLeft = PeekMetrics.pageInset
    let fieldRight = bounds.width - PeekMetrics.pageInset - buttonsWidth - PeekMetrics.fieldGap
    let fieldTop = mid - PeekMetrics.fieldHeight / 2
    icon.frame = CGRect(x: fieldLeft + 8, y: mid - 8, width: 16, height: 16)
    let textLeft = fieldLeft + 8 + 16 + 8
    let room = max(0, fieldRight - 8 - textLeft)
    let hostWidth = min(ceil(host.intrinsicContentSize.width), room * 0.6)
    let h = host.intrinsicContentSize.height
    host.frame = CGRect(x: textLeft, y: mid - h / 2, width: hostWidth, height: h)
    title.frame = CGRect(x: textLeft + hostWidth, y: mid - h / 2, width: max(0, room - hostWidth), height: h)
    if let loading = state?.loading {
      progress.frame = CGRect(x: fieldLeft + 8, y: fieldTop + PeekMetrics.fieldHeight - 1.5, width: (fieldRight - fieldLeft) * 0.96 * CGFloat(max(loading, 0.08)), height: 1.5)
    }
  }
}
