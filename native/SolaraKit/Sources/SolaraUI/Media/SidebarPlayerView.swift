import AppKit
import QuartzCore
#if SOLARA_PROBES
import SolaraProbes
#endif

public final class SidebarPlayerView: NSView, PointerCoverage {
  public static let height: CGFloat = 74
  static let cornerSize: CGFloat = 20
  static let cornerOverhang: CGFloat = 2
  static let cornerGap: CGFloat = 2
  static let border: CGFloat = 0.5
  public static let gap: CGFloat = 8

  public var onAction: ((MediaAction) -> Void)?
  public var onScroll: ((NSEvent) -> Void)?
  public var backdrop: NSColor?

  private let glass = NewTabGlassSurface(frame: .zero)
  private let plateView = MediaCardPlateView()
  private let plate = CALayer()
  private let surface = SurfaceLayer()
  private var accessibilityWatch: NSObjectProtocol?
  private(set) var usesGlass = false
  private var glassDark = true
  private var look: MediaCardLook?
  private var lookInputs: MediaCardLookInputs?
  private var pointerInCard = false
  private var appliedGlass: (bounds: CGRect, tint: NSColor, dark: Bool)?
  private let artView = MediaArtView()
  private let title = FadeLabel(fontSize: 12, weight: .semibold)
  private let mutedIcon = SymbolView()
  private let subtitle = FadeLabel(fontSize: 11)
  private let previous = SidebarIconButton()
  private let play = SidebarIconButton()
  private let next = SidebarIconButton()
  private let seek = SeekBarView()
  private let muteCorner = MediaCircleButton()
  private let closeCorner = MediaCircleButton()
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { needsLayout = true; paintCorners() } } }
  private var state: MediaPlayerState?
  private var ticker: Timer?
  private var occlusionWatch: NSObjectProtocol?
  private let textHit = NSView()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    addSubview(glass)
    plateView.wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = 12
    plate.cornerCurve = .continuous
    plateView.layer?.addSublayer(plate)
    plateView.layer?.addSublayer(surface)
    addSubview(plateView)
    surface.radius = 12
    surface.border = 0.5
    artView.iconSize = 18
    artView.iconOpacity = 1
    artView.fadeIn = false
    artView.onPress = { [weak self] in self?.onAction?(.backToTab) }
    addSubview(artView)
    for v in [title, mutedIcon, subtitle] as [NSView] { addSubview(v) }
    let click = NSClickGestureRecognizer(target: self, action: #selector(textClicked))
    textHit.addGestureRecognizer(click)
    addSubview(textHit)
    for b in [previous, play, next] {
      b.radius = 6
      addSubview(b)
    }
    previous.onPress = { [weak self] in self?.transport(-1) }
    play.onPress = { [weak self] in self?.onAction?(.toggle) }
    next.onPress = { [weak self] in self?.transport(1) }
    seek.barHeight = 3
    seek.onSeek = { [weak self] p in
      guard let self, let duration = self.state?.duration else { return }
      self.onAction?(.seek(p * duration))
    }
    addSubview(seek)
    muteCorner.onPress = { [weak self] in self?.onAction?(.toggleMute) }
    closeCorner.onPress = { [weak self] in self?.onAction?(.dismiss) }
    for c in [muteCorner, closeCorner] {
      c.onHover = { [weak self] _ in
        self?.syncHover()
        self?.paintCorners()
      }
      c.isHidden = true
      addSubview(c)
    }
    #if SOLARA_PROBES
    ProbeCapture.shared.register(self) { $0.prepareForCapture() }
    #endif
  }

  #if DEBUG
  var reduceTransparencyOverride: Bool? { didSet { if let state { update(state) } } }
  private var reduceTransparency: Bool { reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
  #else
  private var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
  #endif

  #if SOLARA_PROBES
  private func prepareForCapture() -> ProbeCapture.Restore {
    let shown = !glass.isHidden
    let opacity = plate.opacity
    glass.isHidden = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.opacity = 1
    CATransaction.commit()
    return { [glass, plate] in
      glass.isHidden = !shown
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      plate.opacity = opacity
      CATransaction.commit()
    }
  }
  #endif

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    pointer(onCard: DevPointer.inside(self, note) || [closeCorner, muteCorner].contains { !$0.isHidden && DevPointer.inside($0, note) })
  }

  @objc private func textClicked() { onAction?(.backToTab) }

  private func transport(_ direction: Int) {
    guard let state else { return }
    if state.tracks { onAction?(direction < 0 ? .previous : .next) } else { onAction?(.skip(direction * MediaFormat.skipSeconds)) }
  }

  public func update(_ next: MediaPlayerState) {
    let old = state
    state = next
    let inputs = MediaCardLookInputs(theme: next.theme, backdrop: backdrop, reduceTransparency: reduceTransparency)
    let card = look.flatMap { inputs == lookInputs ? $0 : nil }
      ?? MediaCardLook(theme: next.theme, backdrop: backdrop, reduceTransparency: reduceTransparency)
    look = card
    lookInputs = inputs
    let palette = card.palette
    usesGlass = card.glass
    glassDark = palette.dark
    glass.isHidden = !card.glass
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = card.plate.cgColor
    plate.opacity = Float(card.plateOpacity)
    CATransaction.commit()
    surface.fill = palette.groupFill
    surface.borderTint = palette.groupStroke
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = palette.dark ? 0.32 : 0.12
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    artView.set(next, palette: palette)
    title.text = next.title
    title.color = card.primary
    subtitle.text = next.subtitle
    subtitle.color = card.secondary
    mutedIcon.set("speaker.slash.fill", size: 9, color: card.secondary)
    mutedIcon.isHidden = !next.muted
    let tracks = next.tracks
    let skip = MediaFormat.skipSeconds
    for b in [previous, play, self.next] {
      b.hoverFill = palette.toolbarHover
      b.pressedFill = palette.toolbarPressed
    }
    previous.set(tracks ? "backward.fill" : "gobackward.\(skip)", size: tracks ? 10 : 12, weight: .regular, color: card.icon, tooltip: tracks ? "Play Previous Track" : "Skip back \(skip) seconds")
    play.set(next.playing ? "pause.fill" : "play.fill", size: 13, weight: .regular, color: card.icon, tooltip: next.playing ? "Pause" : "Play")
    self.next.set(tracks ? "forward.fill" : "goforward.\(skip)", size: tracks ? 10 : 12, weight: .regular, color: card.icon, tooltip: tracks ? "Play Next Track" : "Skip ahead \(skip) seconds")
    seek.colors = (palette.tokens.track, palette.tokens.fill, palette.tokens.hoverFill)
    seek.seekable = next.hasDuration
    seek.isHidden = !next.hasDuration
    for c in [muteCorner, closeCorner] {
      c.style(fill: palette.panel, border: palette.panelBorder, borderWidth: 0.5, shadow: palette.panelShadowOpacity * 0.5, shadowRadius: 3, shadowOffset: 1)
    }
    paintCorners()
    applyGlass()
    if old?.playing != next.playing || ticker == nil { retick() }
    tick()
    needsLayout = true
  }

  private func applyGlass() {
    guard usesGlass else { return }
    let tint = plate.backgroundColor.flatMap { NSColor(cgColor: $0) } ?? .clear
    if let applied = appliedGlass, applied.bounds == bounds, applied.tint == tint, applied.dark == glassDark { return }
    appliedGlass = (bounds, tint, glassDark)
    glass.frame = bounds
    glass.apply(frame: CGRect(x: 0, y: 0, width: bounds.width, height: Self.height), radius: 12, tint: tint, dark: glassDark, tintStrength: MediaCardLook.glassTintStrength)
  }

  private func watchAccessibility() {
    if let accessibilityWatch { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityWatch) }
    accessibilityWatch = nil
    guard window != nil else { return }
    accessibilityWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let state = self.state else { return }
        self.update(state)
      }
    }
  }

  private func paintCorners() {
    guard let state, let palette = look?.palette else { return }
    func ink(_ c: MediaCircleButton) -> NSColor { c.hovered ? palette.textPrimary : palette.textSecondary }
    muteCorner.set(state.muted ? "speaker.wave.2.fill" : "speaker.slash.fill", size: 9, weight: .bold, color: ink(muteCorner), box: 13, tooltip: state.muted ? "Unmute Site" : "Mute Site")
    closeCorner.set("xmark", size: 9, weight: .bold, color: ink(closeCorner), box: 13, tooltip: "Close Player")
    muteCorner.isHidden = !hovered
    closeCorner.isHidden = !hovered
  }

  private func retick() {
    ticker?.invalidate()
    ticker = nil
    guard state?.playing == true, let window, window.occlusionState.contains(.visible), !window.isMiniaturized else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func tick() {
    guard let state, let duration = state.duration, duration > 0 else { return }
    seek.progress = state.position(at: MediaClock.nowMs()) / duration
  }

  private func watchOcclusion() {
    if let occlusionWatch { NotificationCenter.default.removeObserver(occlusionWatch) }
    occlusionWatch = nil
    guard let window else { return }
    occlusionWatch = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.retick()
        if self.ticker != nil { self.tick() }
      }
    }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow {
      FullScreenIslandCoverage.remove(self, from: window)
      FullScreenIslandCoverage.publish(in: window)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    FullScreenIslandCoverage.register(self, in: window)
    FullScreenIslandCoverage.publish(in: window)
    watchOcclusion()
    watchAccessibility()
    retick()
    if window == nil { hovered = false }
  }

  func blocksHover(at point: NSPoint) -> Bool {
    guard let window, !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return false }
    let local = convert(point, from: nil)
    guard cardRect.contains(local) || [closeCorner, muteCorner].contains(where: { !$0.isHidden && $0.frame.contains(local) }) else { return false }
    guard let frame = window.contentView?.superview, let hit = frame.hitTest(point) else { return true }
    return hit === self || hit.isDescendant(of: self)
  }

  private var cardRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: Self.height) }

  static func cardPath(width: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 12, cornerHeight: 12, transform: nil)
  }

  public func coverageChanged() {
    FullScreenIslandCoverage.publish(in: window)
  }

  private var coveragePending = false

  public func coverageMoved() {
    guard !coveragePending, window != nil else { return }
    coveragePending = true
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.coveragePending = false
        self.coverageChanged()
      }
    }
  }

  public override func setFrameOrigin(_ newOrigin: NSPoint) {
    let moved = newOrigin != frame.origin
    super.setFrameOrigin(newOrigin)
    if moved { coverageMoved() }
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let resized = newSize != frame.size
    super.setFrameSize(newSize)
    if resized { coverageMoved() }
  }

  public override func viewDidHide() {
    super.viewDidHide()
    pointerInCard = false
    closeCorner.resetHover()
    muteCorner.resetHover()
    syncHover()
    coverageMoved()
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    coverageMoved()
  }

  public override func mouseDown(with event: NSEvent) {}
  public override func mouseUp(with event: NSEvent) {}
  public override func mouseDragged(with event: NSEvent) {}
  public override func rightMouseDown(with event: NSEvent) {}
  public override func rightMouseUp(with event: NSEvent) {}
  public override func rightMouseDragged(with event: NSEvent) {}
  public override func otherMouseDown(with event: NSEvent) {}
  public override func otherMouseUp(with event: NSEvent) {}
  public override func otherMouseDragged(with event: NSEvent) {}
  public override func scrollWheel(with event: NSEvent) { onScroll?(event) }
  public override func menu(for event: NSEvent) -> NSMenu? { nil }
  public override var mouseDownCanMoveWindow: Bool { false }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }
    let local = convert(point, from: superview)
    for c in [closeCorner, muteCorner] where !c.isHidden && c.frame.contains(local) { return c }
    guard cardRect.contains(local) else { return nil }
    guard Self.cardPath(width: bounds.width).contains(local) else { return self }
    let hit = super.hitTest(point) ?? self
    if hit === glass || hit === plateView || hit.isDescendant(of: glass) { return self }
    return hit
  }

  public override func layout() {
    super.layout()
    let width = bounds.width
    plateView.frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
    applyGlass()
    MediaMotion.setInstantly {
      plate.frame = plateView.bounds
      surface.frame = plateView.bounds
      layer?.shadowPath = CGPath(roundedRect: surface.frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }
    let pad: CGFloat = 7 + Self.border
    artView.frame = CGRect(x: pad, y: pad, width: 32, height: 32)
    let textX = pad + 32 + 8
    let textWidth = max(0, width - pad - textX)
    let textTop = pad + (32 - 16 - 14) / 2
    title.frame = CGRect(x: textX, y: textTop, width: textWidth, height: 16)
    let muted = state?.muted ?? false
    mutedIcon.frame = CGRect(x: textX, y: textTop + 16 + 1, width: 13, height: 12)
    let subX = muted ? textX + 13 : textX
    subtitle.frame = CGRect(x: subX, y: textTop + 16, width: max(0, width - pad - subX), height: 14)
    textHit.frame = CGRect(x: textX, y: pad, width: textWidth, height: 32)
    let row: CGFloat = pad + 32 + 4
    previous.frame = CGRect(x: pad - 4, y: row, width: 24, height: 24)
    play.frame = CGRect(x: pad - 4 + 24, y: row, width: 24, height: 24)
    next.frame = CGRect(x: pad - 4 + 48, y: row, width: 24, height: 24)
    let seekX = pad - 4 + 72 + 6
    seek.frame = CGRect(x: seekX, y: row + 6, width: max(0, width - pad - seekX), height: 12)
    let size = Self.cornerSize, overhang = Self.cornerOverhang
    closeCorner.frame = CGRect(x: width + overhang - size, y: -overhang, width: size, height: size)
    muteCorner.frame = CGRect(x: width + overhang - size - Self.cornerGap - size, y: -overhang, width: size, height: size)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(onCard: pointerOnCard(event)) }
  public override func mouseMoved(with event: NSEvent) { pointer(onCard: pointerOnCard(event)) }
  public override func mouseExited(with event: NSEvent) { pointer(onCard: false) }

  private func pointer(onCard: Bool) {
    pointerInCard = onCard
    syncHover()
  }

  private func syncHover() {
    hovered = pointerInCard || closeCorner.hovered || muteCorner.hovered
  }

  private func pointerOnCard(_ event: NSEvent) -> Bool {
    guard isHitBy(event) else { return false }
    let local = convert(event.locationInWindow, from: nil)
    if Self.cardPath(width: bounds.width).contains(local) { return true }
    return [closeCorner, muteCorner].contains { !$0.isHidden && $0.frame.contains(local) }
  }

#if SOLARA_PROBES
  public var controlLabels: [String: String] {
    ["play": play.toolTip ?? "", "previous": previous.toolTip ?? "", "next": next.toolTip ?? "",
      "art": artView.toolTip ?? "", "close": closeCorner.toolTip ?? "", "mute": muteCorner.toolTip ?? ""]
  }
#endif

  public var controlFrames: [String: CGRect] {
    ["play": play.frame, "art": artView.frame, "seek": seek.frame, "close": closeCorner.frame, "mute": muteCorner.frame, "title": textHit.frame]
  }
  public var cornersShown: Bool { !closeCorner.isHidden }
  #if DEBUG
  var plateColor: NSColor? { plate.backgroundColor.flatMap { NSColor(cgColor: $0) } }
  var plateOpacity: Float { plate.opacity }
  var titleColor: NSColor { title.color }
  var subtitleColor: NSColor { subtitle.color }
  var iconColor: NSColor { look?.icon ?? .clear }
  #endif
  public var seekProgress: Double { seek.progress }
}

final class MediaCardPlateView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MediaCardLookInputs: Equatable {
  let theme: MediaThemeState
  let backdrop: NSColor?
  let reduceTransparency: Bool
}

@MainActor
struct MediaCardLook {
  static let plateOpacity: CGFloat = 0.76
  static let glassTintStrength: CGFloat = 0.6
  static let minimumContrast: CGFloat = 5.5
  static let plateContrast: CGFloat = 7
  static let controlContrast: CGFloat = 4.5

  let palette: MediaPalette
  let plate: NSColor
  let plateOpacity: CGFloat
  let glass: Bool
  let primary: NSColor
  let secondary: NSColor
  let icon: NSColor
  let bleed: CGFloat

  init(theme: MediaThemeState, backdrop: NSColor?, reduceTransparency: Bool) {
    let themed = MediaPalette(theme)
    let base = (backdrop ?? themed.panel).usingColorSpace(.sRGB) ?? themed.panel
    let raw = base.withAlphaComponent(1)
    let rawBackground = Self.composite(themed.groupFill, over: raw)
    let darkCard = Self.contrast(.white, rawBackground) >= Self.contrast(.black, rawBackground)
    let palette = darkCard == theme.dark ? themed : MediaPalette(MediaThemeState(dark: darkCard, panelShadowOpacity: theme.panelShadowOpacity))
    let away = NSColor(srgbRed: darkCard ? 0 : 1, green: darkCard ? 0 : 1, blue: darkCard ? 0 : 1, alpha: 0.05)
    let bleed = reduceTransparency ? 0 : (1 - Self.plateOpacity) * (1 - Self.glassTintStrength)
    let ink = palette.textPrimary.withAlphaComponent(1)
    var plate = raw
    var steps = 0
    while steps < 40, Self.contrast(ink, Self.worst(Self.composite(palette.groupFill, over: plate), for: ink, bleed: bleed)) < Self.plateContrast {
      plate = Self.composite(away, over: plate)
      steps += 1
    }
    self.palette = palette
    self.plate = plate
    self.bleed = bleed
    glass = !reduceTransparency
    plateOpacity = reduceTransparency ? 1 : Self.plateOpacity
    let background = Self.composite(palette.groupFill, over: plate)
    primary = Self.legible(palette.textPrimary, on: Self.worst(background, for: palette.textPrimary, bleed: bleed), target: Self.plateContrast)
    secondary = Self.legible(palette.textSecondary, on: Self.worst(background, for: palette.textSecondary, bleed: bleed), target: Self.minimumContrast)
    icon = Self.legible(palette.icon, on: Self.worst(background, for: palette.icon, bleed: bleed), target: Self.controlContrast)
  }

  var background: NSColor { Self.composite(palette.groupFill, over: plate) }

  func onScreen(for ink: NSColor) -> NSColor { Self.worst(background, for: ink, bleed: bleed) }

  static func worst(_ background: NSColor, for ink: NSColor, bleed: CGFloat) -> NSColor {
    guard bleed > 0, let ink = ink.usingColorSpace(.sRGB) else { return background }
    return composite(ink.withAlphaComponent(bleed), over: background)
  }

  static func legible(_ ink: NSColor, on background: NSColor, target: CGFloat) -> NSColor {
    guard let ink = ink.usingColorSpace(.sRGB) else { return ink }
    var alpha = ink.alphaComponent
    while alpha < 1, contrast(ink.withAlphaComponent(alpha), background) < target { alpha = min(1, alpha + 0.05) }
    return ink.withAlphaComponent(alpha)
  }

  static func composite(_ ink: NSColor, over background: NSColor) -> NSColor {
    guard let ink = ink.usingColorSpace(.sRGB), let background = background.usingColorSpace(.sRGB) else { return background }
    let a = ink.alphaComponent
    return NSColor(srgbRed: background.redComponent + (ink.redComponent - background.redComponent) * a,
      green: background.greenComponent + (ink.greenComponent - background.greenComponent) * a,
      blue: background.blueComponent + (ink.blueComponent - background.blueComponent) * a, alpha: 1)
  }

  static func luminance(_ color: NSColor) -> CGFloat {
    guard let color = color.usingColorSpace(.sRGB) else { return 0 }
    func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
  }

  static func contrast(_ ink: NSColor, _ background: NSColor) -> CGFloat {
    let a = luminance(composite(ink, over: background)), b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}
