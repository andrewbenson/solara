import AppKit
import Foundation

public struct PostcardNotes: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
  }
  public let version: String
  public let date: String
  public let title: String
  public let summary: String
  public let items: [Item]
}

public struct PostcardState: Decodable, Equatable, Sendable {
  public let notes: PostcardNotes
  public let focusContext: String?
  public let profileId: String
  public let dark: Bool
  public let tokens: [String: String]
  public let colors: [String]
  public let iconUri: String
  public let product: String
  public let presentationId: String

  public static func decode(_ json: String) -> PostcardState? {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(Self.self, from: data), state.colors.count == 2, state.colors.allSatisfy({ CSSColor($0) != nil }), !state.notes.version.isEmpty else { return nil }
    return state
  }
}

public enum PostcardLayout {
  public static func card(_ size: CGSize) -> CGRect { CGRect(x: size.width - 280, y: -30, width: 320, height: 200) }
  public static func visible(_ size: CGSize) -> Bool { size.width >= 560 && size.height >= 420 }
  public static func artworkFill(_ colors: [String]) -> CSSColor? {
    guard colors.count == 2, let a = CSSColor(colors[0]), let b = CSSColor(colors[1]) else { return nil }
    func channel(_ x: Double, _ y: Double) -> Double { (((x * 255).rounded() + (y * 255).rounded()) / 2).rounded() / 255 }
    return CSSColor(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue), alpha: 1)
  }
  public static func page(_ size: CGSize) -> CGRect {
    let width = min(860, size.width - 64)
    let height = min(520, size.height - 64, width * 0.62)
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
  }
}

public final class PostcardView: NSView {
  public enum Mode: String { case postcard, page }
  public let mode: Mode
  public private(set) var state: PostcardState?
  public var onAction: (String, PostcardState) -> Void = { _, _ in }
  public var makeBackdrop: ([String]) -> NSView? = { _ in nil }
  public private(set) var hovered = false
  public private(set) var leaving = false
  public private(set) var motion: [String: Double] = [:]
  #if DEBUG
    public private(set) var trace: [[String: Double]] = []
  #endif
  public var cardFrame: CGRect { PostcardLayout.card(bounds.size) }
  public var pageFrame: CGRect { PostcardLayout.page(bounds.size) }
  private let plate = PostcardContainer()
  private let card = PostcardControl()
  private let tooltip = PostcardControl()
  private let dismiss = PostcardControl()
  private let close = PostcardControl()
  private let backdrop = PostcardControl()
  private let pageBlur = PostcardBlur()
  private let tint = PostcardContainer()
  private let paper = BarSurfaceView()
  private let artwork = PostcardArtwork()
  private let tooltipBlur = PostcardBlur()
  private let tooltipTint = PostcardContainer()
  private let tooltipLabel = PostcardText()
  private let stamp = PostcardStamp()
  private let date = PostcardText()
  private let title = PostcardText()
  private let summary = PostcardText()
  private let scroll = NSScrollView()
  private let document = PostcardContainer()
  private var items: [(PostcardText, PostcardText, NSView)] = []
  private var tracking: NSTrackingArea?
  private var timer: Timer?
  private var presentation = UUID()
  private var started = 0.0
  private var leaveStart: Double?
  private var leaveOpacity = 1.0
  private var leaveScale = 1.0
  private var leaveProgress = 1.0
  private var hoverStart = 0.0
  private var hoverScale = 1.0
  private var hoverTooltip = 0.0
  private var tooltipStart = 0.0
  private var hoverValue = 1.0
  private var tooltipValue = 0.0
  private var imageTask: URLSessionDataTask?
  private var iconUri = ""
  private var pointerInside = false
  private var detached = false
  private var completed = false
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { state != nil && mode == .page }

  public init(mode: Mode) {
    self.mode = mode
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    plate.wantsLayer = true
    addSubview(plate)
    tooltipLabel.configure("Latest Release Notes", size: 12, weight: 500, color: "#FFFFFFD9", lines: 1)
    tooltip.addSubview(tooltipBlur)
    tooltip.addSubview(tooltipTint)
    tooltip.addSubview(tooltipLabel)
    tooltip.layer?.cornerRadius = 6
    tooltip.layer?.masksToBounds = true
    for control in [card, tooltip, dismiss, close, backdrop] {
      control.containsPointInWindow = { [weak self, weak control] point in
        guard let self, let control else { return false }
        return self.hitTest(self.superview?.convert(point, from: nil) ?? point) === control
      }
    }
    card.acceptsFirstClick = true
    tooltip.acceptsFirstClick = true
    dismiss.acceptsFirstClick = true
    close.acceptsFirstClick = true
    backdrop.acceptsFirstClick = true
    tooltipBlur.material = .contentBackground
    dismiss.glyph = "xmark"
    dismiss.glyphSize = 11
    dismiss.glyphColor = CSSColor("#FFFFFF8C")!.ns
    dismiss.radius = 8
    dismiss.setAccessibilityLabel("Dismiss release notes")
    dismiss.toolTip = "Dismiss release notes"
    dismiss.onHover = { [weak self] _ in self?.refreshControls() }
    dismiss.onPressed = { [weak self] _ in self?.refreshControls() }
    close.glyph = "xmark"
    close.glyphSize = 10
    close.glyphWeight = .semibold
    close.radius = 13
    close.setAccessibilityLabel("Close release notes")
    close.toolTip = "Close release notes"
    close.onHover = { [weak self] _ in self?.refreshControls() }
    close.onPressed = { [weak self] _ in self?.refreshControls() }
    if mode == .postcard {
      plate.addSubview(card)
      card.addSubview(artwork)
      addSubview(tooltip)
      tooltip.addSubview(dismiss)
      tooltip.setAccessibilityLabel("Latest Release Notes")
      card.onHover = { [weak self] inside in
        if inside { self?.setHovered(true) } else { self?.refreshKeyboardHover() }
      }
      card.onFocus = { [weak self] in self?.setHovered(true) }
      tooltip.onFocus = { [weak self] in self?.setHovered(true) }
      dismiss.onFocus = { [weak self] in self?.setHovered(true) }
      for control in [card, tooltip, dismiss] {
        control.onBlur = { [weak self] in
          DispatchQueue.main.async { [weak self] in self?.refreshKeyboardHover() }
        }
      }
      card.layer?.shadowColor = NSColor.black.cgColor
      card.layer?.shadowOpacity = 0.3
      card.layer?.shadowRadius = 20
      card.layer?.shadowOffset = CGSize(width: 0, height: -6)
    } else {
      addSubview(pageBlur, positioned: .below, relativeTo: plate)
      addSubview(tint, positioned: .below, relativeTo: plate)
      addSubview(backdrop, positioned: .below, relativeTo: plate)
      plate.addSubview(paper)
      plate.addSubview(artwork)
      plate.addSubview(date)
      plate.addSubview(title)
      plate.addSubview(summary)
      plate.addSubview(stamp)
      plate.addSubview(scroll)
      plate.addSubview(close)
      backdrop.setAccessibilityLabel("Close release notes")
      backdrop.accessible = false
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = false
      scroll.hasHorizontalScroller = false
      scroll.documentView = document
      paper.fill = CSSColor("#FCFCFA")!.ns
      paper.radius = 6
      paper.borderColor = CSSColor("#00000014")!.ns
      paper.borderWidth = 0.5
      paper.shadowColor = .black
      paper.shadowOpacity = 0.3
      paper.shadowRadius = 40
      paper.shadowOffset = CGSize(width: 0, height: 18)
    }
    isHidden = true
  }

  public required init?(coder: NSCoder) { nil }

  public func update(_ next: PostcardState?) {
    let replaced = state?.profileId != next?.profileId || state?.notes.version != next?.notes.version || state?.presentationId != next?.presentationId
    if replaced || next == nil {
      presentation = UUID()
      imageTask?.cancel()
      imageTask = nil
      iconUri = ""
      timer?.invalidate()
      timer = nil
      leaving = false
      completed = false
      #if DEBUG
        trace.removeAll()
      #endif
      leaveStart = nil
      hovered = false
      pointerInside = false
      hoverValue = 1
      tooltipValue = 0
      hoverScale = 1
      hoverTooltip = 0
      started = ProcessInfo.processInfo.systemUptime
      hoverStart = started
      tooltipStart = started
    }
    state = next
    isHidden = next == nil || (mode == .postcard && !PostcardLayout.visible(bounds.size))
    guard let next else {
      imageTask?.cancel()
      imageTask = nil
      if let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) { window?.makeFirstResponder(nil) }
      for control in [card, tooltip, dismiss, close, backdrop] { control.onPress = nil }
      return
    }
    for control in [card, tooltip, dismiss, close, backdrop] { control.interactionEnabled = !leaving }
    let identity = presentation
    func action(_ name: String) -> () -> Void {
      { [weak self] in
        guard let self, self.presentation == identity, let current = self.state, !self.leaving, !self.detached else { return }
        if name == "open" { self.onAction(name, current) }
        else { self.retire() }
      }
    }
    card.setAccessibilityLabel("What's new in \(next.product)")
    card.onPress = action("open")
    tooltip.onPress = action("open")
    dismiss.onPress = action("dismiss")
    close.onPress = action("close")
    backdrop.onPress = action("close")
    artwork.update(next, makeBackdrop: makeBackdrop, postcard: mode == .postcard)
    if next.notes != stamp.notes {
      stamp.notes = next.notes
      document.subviews.forEach { $0.removeFromSuperview() }
      items = next.notes.items.map { item in
        let heading = PostcardText()
        heading.configure(item.title, size: 13, weight: 600, color: "#1D1B1A")
        let body = PostcardText()
        body.configure(item.body, size: 12.5, color: "#1D1B1A99", lineHeight: 18)
        let rule = PostcardItemBorder()
        [rule, heading, body].forEach { document.addSubview($0) }
        return (heading, body, rule)
      }
    }
    date.configure(next.notes.date.uppercased(), size: 11, weight: 600, color: "#1D1B1A80", kerning: 1.2)
    title.configure(next.notes.title, size: 26, weight: 300, color: "#1D1B1A", kerning: -0.5)
    summary.configure(next.notes.summary, size: 13, color: "#1D1B1AB3", lineHeight: 19)
    tooltipTint.layer?.backgroundColor = CSSColor(next.dark ? "#FFFFFF2E" : "#000000CC")!.cg
    loadIcon(next.iconUri)
    needsLayout = true
    layoutSubtreeIfNeeded()
    refreshControls()
    tick(at: ProcessInfo.processInfo.systemUptime)
    startTimer()
    window?.recalculateKeyViewLoop()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window != nil && newWindow == nil {
      detached = true
      timer?.invalidate()
      timer = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { detached = false; needsLayout = true; startTimer() }
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    isHidden = state == nil || (mode == .postcard && !PostcardLayout.visible(newSize))
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    if mode == .postcard {
      plate.frame = cardFrame
      card.frame = plate.bounds
      artwork.frame = card.bounds
      let width = tooltipLabel.measured(300).width + 8 + 9 + 22 + 3
      tooltip.frame = CGRect(x: cardFrame.midX - width / 2, y: cardFrame.maxY + 4, width: width, height: 28)
      tooltipBlur.frame = tooltip.bounds
      tooltipTint.frame = tooltip.bounds
      tooltipLabel.frame = CGRect(x: 8, y: (28 - 14.5) / 2 - 1, width: width - 42, height: 14.5)
      dismiss.frame = CGRect(x: width - 25.5, y: 3, width: 22, height: 22)
    } else {
      for view in [pageBlur, tint, backdrop] { view.frame = bounds }
      plate.frame = pageFrame
      paper.frame = plate.bounds
      close.frame = CGRect(x: plate.bounds.width - 13, y: -13, width: 26, height: 26)
      let width = plate.bounds.width
      let height = plate.bounds.height
      let split = width >= 640
      let pixelScale = window?.backingScaleFactor ?? 2
      let artWidth = split ? ((width - 32) * 0.46 * pixelScale).rounded() / pixelScale : width - 32
      artwork.frame = CGRect(x: 16, y: 16, width: artWidth, height: split ? height - 32 : 150)
      let x = split ? 16 + artWidth + 22 : 16
      let y: CGFloat = split ? 26 : 198
      let contentWidth = max(0, width - x - 24)
      stamp.frame = CGRect(x: width - 16 - 110, y: y - 10, width: 110, height: 86)
      var top = y
      for (text, gap) in [(date, CGFloat(0)), (title, 6), (summary, 8)] {
        top += gap
        let size = text.measured(max(0, contentWidth - 116))
        text.frame = CGRect(x: x, y: top, width: max(0, contentWidth - 116), height: size.height)
        top += size.height
      }
      top += 14
      scroll.frame = CGRect(x: x, y: top, width: contentWidth, height: max(0, height - 16 - top))
      var itemY: CGFloat = 0
      for (heading, body, rule) in items {
        let headingHeight = heading.measured(contentWidth).height
        let bodyHeight = body.measured(contentWidth).height
        heading.frame = CGRect(x: 0, y: itemY, width: contentWidth, height: headingHeight)
        body.frame = CGRect(x: 0, y: itemY + headingHeight + 2, width: contentWidth, height: bodyHeight)
        rule.frame = CGRect(x: 0, y: itemY, width: contentWidth, height: body.frame.maxY + 11 - itemY)
        itemY = rule.frame.maxY + 12
      }
      document.frame = CGRect(x: 0, y: 0, width: contentWidth, height: max(scroll.bounds.height, itemY - 12 + 8))
    }
    applyMotion()
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    refreshTracking()
  }

  private func refreshTracking() {
    guard mode == .postcard else { return }
    let rect = CGRect(x: cardFrame.minX - 24, y: cardFrame.minY - 24 - 280 * (motion["drop"] ?? 0), width: 368, height: 256)
    if tracking?.rect == rect { return }
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
    tracking = area
    addTrackingArea(area)
  }

  public override func mouseEntered(with event: NSEvent) { pointerInside = true; setHovered(true) }
  public override func mouseExited(with event: NSEvent) { pointerInside = false; refreshKeyboardHover() }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, mode == .page, !leaving { retire() }
    else { super.keyDown(with: event) }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, state != nil, !leaving else { return nil }
    let local = convert(point, from: superview)
    if mode == .postcard {
      let tooltipPoint = CGPoint(x: local.x, y: local.y + 280 * (motion["drop"] ?? 0))
      if hovered, tooltip.frame.contains(tooltipPoint) { return tooltip.hitTest(tooltipPoint) ?? tooltip }
      let transform = CGAffineTransform(translationX: cardFrame.midX, y: cardFrame.midY - 280 * (motion["drop"] ?? 0)).rotated(by: 2 * .pi / 180).scaledBy(x: motion["scale"] ?? 1, y: motion["scale"] ?? 1)
      if CGRect(x: -160, y: -100, width: 320, height: 200).contains(local.applying(transform.inverted())) { return card }
      return nil
    }
    let p = motion["progress"] ?? 1
    let scale = 320 / max(1, pageFrame.width) + (1 - 320 / max(1, pageFrame.width)) * p
    let transform = CGAffineTransform(translationX: pageFrame.midX + (cardFrame.midX - bounds.midX) * (1 - p), y: pageFrame.midY + (cardFrame.midY - bounds.midY) * (1 - p)).rotated(by: (2 - 3 * p) * .pi / 180).scaledBy(x: scale, y: scale)
    let centerPoint = local.applying(transform.inverted())
    let inPlate = CGPoint(x: centerPoint.x + pageFrame.width / 2, y: centerPoint.y + pageFrame.height / 2)
    if close.frame.contains(inPlate) { return close }
    if plate.bounds.contains(inPlate) {
      return plate.hitTest(CGPoint(x: inPlate.x + plate.frame.minX, y: inPlate.y + plate.frame.minY)) ?? self
    }
    return bounds.contains(local) ? backdrop : nil
  }

  private func refreshKeyboardHover() {
    guard mode == .postcard, state != nil, !pointerInside else { return }
    let focused = window?.firstResponder
    setHovered([card, tooltip, dismiss].contains { focused === $0 })
  }

  public func setHovered(_ value: Bool) {
    guard mode == .postcard, !leaving, hovered != value else { return }
    let now = ProcessInfo.processInfo.systemUptime
    tick(at: now)
    hovered = value
    hoverStart = now
    tooltipStart = now
    hoverScale = hoverValue
    hoverTooltip = tooltipValue
    if value { tooltip.isHidden = false }
    startTimer()
  }

  private func retire() {
    guard state != nil, !leaving else { return }
    let now = ProcessInfo.processInfo.systemUptime
    tick(at: now)
    leaving = true
    for control in [card, tooltip, dismiss, close, backdrop] { control.interactionEnabled = false }
    leaveStart = now
    leaveOpacity = motion["opacity"] ?? 1
    leaveScale = motion["scale"] ?? 1
    leaveProgress = motion["progress"] ?? 1
    startTimer()
  }

  private func startTimer() {
    guard timer == nil, state != nil, !detached else { return }
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      guard let self else { timer.invalidate(); return }
      MainActor.assumeIsolated {
        guard self.state != nil else { return }
        self.tick(at: ProcessInfo.processInfo.systemUptime)
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func tick(at now: Double) {
    guard state != nil else { return }
    let elapsed = max(0, now - started)
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    func out(_ t: Double) -> Double { let v = min(1, max(0, t)); return 1 - (1 - v) * (1 - v) }
    hoverValue = hoverScale + ((hovered ? 1.05 : 1) - hoverScale) * out((now - hoverStart) / 0.16)
    tooltipValue = hoverTooltip + ((hovered ? 1 : 0) - hoverTooltip) * out((now - tooltipStart) / (hovered ? 0.05 : 0.1))
    var opacity = reduce ? 1 : out(elapsed / 0.3)
    var scale = hoverValue
    var drop = reduce ? 0 : RNSpring.solve(SpringParams(response: 0.65, dampingRatio: 1), from: 1, to: 0, initialVelocity: 0, t: elapsed).0
    var progress = RNSpring.solve(SpringParams(stiffness: 284.5, damping: 28), from: 0, to: 1, initialVelocity: 0, t: elapsed).0
    if let leaveStart {
      let t = min(1, max(0, (now - leaveStart) / (mode == .page ? 0.24 : 0.2)))
      if mode == .page { progress = leaveProgress * (1 - t * t * t) }
      else { opacity = leaveOpacity * (1 - t * t); scale = leaveScale + (0.96 - leaveScale) * t * t }
      if t == 1 {
        let identity = presentation
        let current = state
        timer?.invalidate()
        timer = nil
        apply(opacity: opacity, scale: scale, drop: drop, progress: progress)
        #if DEBUG
          record(at: now)
        #endif
        if let current, presentation == identity, !completed, !detached { completed = true; onAction(mode == .page ? "close" : "dismiss", current) }
        return
      }
    }
    if drop < 0.00001 { drop = 0 }
    apply(opacity: opacity, scale: scale, drop: drop, progress: progress)
    #if DEBUG
      record(at: now)
    #endif
    if leaveStart == nil, elapsed > 2, now - hoverStart > 0.16, now - tooltipStart > 0.1 {
      timer?.invalidate()
      timer = nil
    }
  }

  private func apply(opacity: Double, scale: Double, drop: Double, progress: Double) {
    motion = ["opacity": opacity, "scale": scale, "drop": drop, "progress": progress, "tooltip": tooltipValue]
    applyMotion()
  }

  private func applyMotion() {
    guard let state, !motion.isEmpty else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if mode == .postcard {
      plate.alphaValue = motion["opacity"] ?? 1
      plate.layer?.setAffineTransform(CGAffineTransform(translationX: plate.bounds.midX, y: plate.bounds.midY - 280 * (motion["drop"] ?? 0)).rotated(by: 2 * .pi / 180).scaledBy(x: motion["scale"] ?? 1, y: motion["scale"] ?? 1).translatedBy(x: -plate.bounds.midX, y: -plate.bounds.midY))
      tooltip.alphaValue = (motion["opacity"] ?? 1) * tooltipValue
      tooltip.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -280 * (motion["drop"] ?? 0)))
      tooltip.isHidden = tooltipValue <= 0 && !hovered
    } else {
      let p = motion["progress"] ?? 1
      let shade = min(1, max(0, p))
      pageBlur.alphaValue = shade
      tint.alphaValue = shade
      tint.layer?.backgroundColor = CSSColor(state.dark ? "#0A0A0A59" : "#FFFFFF59")!.cg
      plate.alphaValue = min(1, max(0, p / 0.3))
      let scale = 320 / max(1, pageFrame.width) + (1 - 320 / max(1, pageFrame.width)) * p
      plate.layer?.setAffineTransform(CGAffineTransform(translationX: plate.bounds.midX + (cardFrame.midX - bounds.midX) * (1 - p), y: plate.bounds.midY + (cardFrame.midY - bounds.midY) * (1 - p)).rotated(by: (2 - 3 * p) * .pi / 180).scaledBy(x: scale, y: scale).translatedBy(x: -plate.bounds.midX, y: -plate.bounds.midY))
    }
    CATransaction.commit()
    refreshTracking()
  }

  private func refreshControls() {
    guard let state else { return }
    dismiss.fill = CSSColor(dismiss.pressed ? "#FFFFFF4D" : dismiss.hovered ? "#FFFFFF33" : "#FFFFFF1A")!.ns
    close.fill = state.tokens["panel"].flatMap(CSSColor.init)?.ns ?? CSSColor(state.dark ? "#2A2A2A" : "#FFFFFF")!.ns
    close.border = state.tokens["panelBorder"].flatMap(CSSColor.init)?.ns
    close.borderWidth = 0.5
    close.glyphColor = state.tokens[close.hovered ? "textPrimary" : "textSecondary"].flatMap(CSSColor.init)?.ns ?? CSSColor(state.dark ? "#FFFFFF" : "#333333")!.ns
    close.layer?.shadowColor = NSColor.black.cgColor
    close.layer?.shadowOpacity = 0.2
    close.layer?.shadowRadius = 6
    close.layer?.shadowOffset = CGSize(width: 0, height: 2)
    let closeScale = close.pressed ? 0.94 : 1.0
    close.layer?.setAffineTransform(CGAffineTransform(translationX: close.bounds.midX * (1 - closeScale), y: close.bounds.midY * (1 - closeScale)).scaledBy(x: closeScale, y: closeScale))
    dismiss.needsDisplay = true
    close.needsDisplay = true
  }

  private func loadIcon(_ uri: String) {
    guard iconUri != uri else { return }
    iconUri = uri
    imageTask?.cancel()
    imageTask = nil
    guard !uri.isEmpty, let url = URL(string: uri) else { stamp.image = nil; return }
    if url.isFileURL { stamp.image = NSImage(contentsOf: url); return }
    let identity = presentation
    imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data else { return }
      DispatchQueue.main.async {
        guard let self, self.presentation == identity, self.iconUri == uri, self.state != nil else { return }
        self.stamp.image = NSImage(data: data)
      }
    }
    imageTask?.resume()
  }

  #if DEBUG
    public func inspectMotion(_ elapsed: Double) {
      let now = ProcessInfo.processInfo.systemUptime
      started = now - max(0, elapsed)
      tick(at: now)
    }
    private func record(at time: Double) {
      var sample = motion
      sample["time"] = time
      sample["elapsed"] = time - started
      trace.append(sample)
      if trace.count > 480 { trace.removeFirst(trace.count - 480) }
    }
  #endif
}

final class PostcardContainer: NSView {
  override var isFlipped: Bool { true }
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
}

final class PostcardBlur: NSVisualEffectView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .hudWindow
    blendingMode = .withinWindow
    state = .active
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PostcardText: NSView {
  private let textView = OnboardingTextNSView()
  override var isFlipped: Bool { true }
  override init(frame: NSRect) { super.init(frame: frame); addSubview(textView) }
  required init?(coder: NSCoder) { nil }
  override func layout() { super.layout(); textView.frame = bounds }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func configure(_ value: String, size: CGFloat, weight: Int = 400, color: String, lineHeight: CGFloat? = nil, kerning: CGFloat = 0, lines: Int = 0, italic: Bool = false) {
    textView.apply(OnboardingTextLayout(text: value, size: size, weight: weight, color: CSSColor(color)!.ns, lineHeight: lineHeight, kerning: kerning, lines: lines, alignment: .left, italic: italic))
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(value)
  }
  func measured(_ width: CGFloat) -> CGSize { textView.measure(width: width) }
}

final class PostcardArtwork: NSView {
  private let version = PostcardText()
  private let heading = PostcardText()
  private var backdrop: NSView?
  private var colors: [String] = []
  private var postcard = false
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    addSubview(version)
    addSubview(heading)
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func update(_ state: PostcardState, makeBackdrop: ([String]) -> NSView?, postcard: Bool) {
    self.postcard = postcard
    layer?.cornerRadius = postcard ? 10 : 4
    layer?.backgroundColor = PostcardLayout.artworkFill(state.colors)?.cg
    if colors != state.colors || backdrop == nil {
      colors = state.colors
      backdrop?.removeFromSuperview()
      backdrop = makeBackdrop(colors)
      if let backdrop { addSubview(backdrop, positioned: .below, relativeTo: version) }

    }
    let size: CGFloat = postcard ? 40 : 46
    let k = size / 44
    version.configure("SOLARA \(state.notes.version)", size: 11.5 * k, weight: 700, color: "#FFFFFFCC", kerning: 1.4 * k)
    heading.configure("What's new", size: size, weight: 300, color: "#FFFFFF", kerning: -1.1 * k, italic: true)
    needsLayout = true
  }
  override func layout() {
    super.layout()
    backdrop?.frame = bounds
    let pad: CGFloat = postcard ? 20 : 23
    let width = bounds.width - pad * 2 - (postcard ? 40 : 0)
    version.frame = CGRect(x: pad, y: pad + (postcard ? 30 : 0), width: width, height: version.measured(width).height)
    let h = heading.measured(width).height
    heading.frame = CGRect(x: pad, y: bounds.height - pad - h, width: width, height: h)
  }
}

final class PostcardStamp: NSView {
  var image: NSImage? { didSet { needsDisplay = true } }
  var notes: PostcardNotes?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let stamp = NSBezierPath(roundedRect: CGRect(x: 45.75, y: 0.75, width: 63.5, height: 63.5), xRadius: 3, yRadius: 3)
    NSColor.white.setFill()
    stamp.fill()
    CSSColor("#1D1B1A33")!.ns.setStroke()
    stamp.lineWidth = 1.5
    stamp.setLineDash([4.5, 4.5], count: 2, phase: 0)
    stamp.stroke()
    image?.draw(in: CGRect(x: 50.5, y: 5.5, width: 54, height: 54), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let ring = NSBezierPath(ovalIn: CGRect(x: 0.6, y: 18.6, width: 56.8, height: 56.8))
    ring.lineWidth = 1.2
    CSSColor("#1D1B1A59")!.ns.setStroke()
    ring.stroke()
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: 29, byY: 47)
    var rotated = transform
    rotated.rotate(byDegrees: -14)
    (rotated as NSAffineTransform).concat()
    let text = OnboardingTextLayout(text: "WHAT'S NEW", size: 6.5, weight: 700, color: CSSColor("#1D1B1A80")!.ns, lineHeight: nil, kerning: 0.6, lines: 1, alignment: .center).attributed
    let size = text.size()
    text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
  }
}

final class PostcardItemBorder: NSView {
  private let border = CALayer()
  private static let image: NSImage = {
    let image = NSImage(size: CGSize(width: 1, height: 2), flipped: true) { _ in
      CSSColor("#1D1B1A14")!.ns.setFill()
      CGRect(x: 0, y: 1, width: 1, height: 1).fill()
      return true
    }
    image.lockFocus()
    image.unlockFocus()
    image.capInsets = NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
    return image
  }()

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    setAccessibilityElement(false)
    layer?.addSublayer(border)
    updateLayer()
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() { super.layout(); placeBorder() }
  override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); placeBorder() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
  override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
  override func updateLayer() {
    let scale = window?.backingScaleFactor ?? 2
    border.isGeometryFlipped = true
    border.contents = Self.image.layerContents(forContentsScale: scale)
    border.contentsScale = scale
    border.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 0.5)
    border.magnificationFilter = .nearest
    border.needsDisplayOnBoundsChange = false
    placeBorder()
  }
  private func placeBorder() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.isGeometryFlipped = true
    border.frame = bounds
    CATransaction.commit()
  }
}
