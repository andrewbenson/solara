import AppKit
import QuartzCore

public final class SidebarPlayerView: NSView {
  public static let height: CGFloat = 74
  static let border: CGFloat = 0.5
  public static let gap: CGFloat = 8

  public var onAction: ((MediaAction) -> Void)?

  private let surface = SurfaceLayer()
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
  private let textHit = NSView()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    layer?.addSublayer(surface)
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
      c.onHover = { [weak self] _ in self?.paintCorners() }
      c.isHidden = true
      addSubview(c)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  @objc private func textClicked() { onAction?(.backToTab) }

  private func transport(_ direction: Int) {
    guard let state else { return }
    if state.tracks { onAction?(direction < 0 ? .previous : .next) } else { onAction?(.skip(direction * MediaFormat.skipSeconds)) }
  }

  public func update(_ next: MediaPlayerState) {
    let old = state
    state = next
    let palette = MediaPalette(next.theme)
    surface.fill = palette.groupFill
    surface.borderTint = palette.groupStroke
    artView.set(next, palette: palette)
    title.text = next.title
    title.color = palette.textPrimary
    subtitle.text = next.subtitle
    subtitle.color = palette.textSecondary
    mutedIcon.set("speaker.slash.fill", size: 9, color: palette.textSecondary)
    mutedIcon.isHidden = !next.muted
    let tracks = next.tracks
    let skip = MediaFormat.skipSeconds
    for b in [previous, play, self.next] {
      b.hoverFill = palette.toolbarHover
      b.pressedFill = palette.toolbarPressed
    }
    previous.set(tracks ? "backward.fill" : "gobackward.\(skip)", size: tracks ? 10 : 12, weight: .regular, color: palette.icon, tooltip: tracks ? "Play Previous Track" : "Skip back \(skip) seconds")
    play.set(next.playing ? "pause.fill" : "play.fill", size: 13, weight: .regular, color: palette.icon, tooltip: next.playing ? "Pause" : "Play")
    self.next.set(tracks ? "forward.fill" : "goforward.\(skip)", size: tracks ? 10 : 12, weight: .regular, color: palette.icon, tooltip: tracks ? "Play Next Track" : "Skip ahead \(skip) seconds")
    seek.colors = (palette.tokens.track, palette.tokens.fill, palette.tokens.hoverFill)
    seek.seekable = next.hasDuration
    seek.isHidden = !next.hasDuration
    for c in [muteCorner, closeCorner] {
      c.style(fill: palette.panel, border: palette.panelBorder, borderWidth: 0.5, shadow: palette.panelShadowOpacity * 0.5, shadowRadius: 3, shadowOffset: 1)
    }
    paintCorners()
    if old?.playing != next.playing || ticker == nil { retick() }
    tick()
    needsLayout = true
  }

  private func paintCorners() {
    guard let state else { return }
    let palette = MediaPalette(state.theme)
    func ink(_ c: MediaCircleButton) -> NSColor { c.hovered ? palette.textPrimary : palette.textSecondary }
    muteCorner.set(state.muted ? "speaker.wave.2.fill" : "speaker.slash.fill", size: 8, weight: .bold, color: ink(muteCorner), box: 12, tooltip: state.muted ? "Unmute Site" : "Mute Site")
    closeCorner.set("xmark", size: 8, weight: .bold, color: ink(closeCorner), box: 12, tooltip: "Close Player")
    muteCorner.isHidden = !hovered
    closeCorner.isHidden = !hovered
  }

  private func retick() {
    ticker?.invalidate()
    ticker = nil
    guard state?.playing == true, window != nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func tick() {
    guard let state, let duration = state.duration, duration > 0 else { return }
    seek.progress = state.position(at: MediaClock.nowMs()) / duration
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    retick()
    if window == nil { hovered = false }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    for c in [closeCorner, muteCorner] where !c.isHidden && c.frame.contains(local) { return c }
    return super.hitTest(point)
  }

  public override func layout() {
    super.layout()
    let width = bounds.width
    MediaMotion.setInstantly { surface.frame = CGRect(x: 0, y: 0, width: width, height: Self.height) }
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
    closeCorner.frame = CGRect(x: width + 6 - 18, y: -6, width: 18, height: 18)
    muteCorner.frame = CGRect(x: width + 6 - 18 - 2 - 18, y: -6, width: 18, height: 18)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { hovered = true }
  public override func mouseExited(with event: NSEvent) { hovered = false }

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
  public var seekProgress: Double { seek.progress }
}
