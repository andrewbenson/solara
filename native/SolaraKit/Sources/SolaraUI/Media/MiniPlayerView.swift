import AppKit
import QuartzCore

public final class MiniPlayerView: NSView {
  public static let width: CGFloat = 320
  public static let height: CGFloat = 76
  static let border: CGFloat = 0.5
  static let labelPadding: CGFloat = 2
  static let inset: CGFloat = 10
  static let art: CGFloat = 56
  static let textX = inset + art + 12
  static let controlsWidth: CGFloat = 88

  public var onAction: ((MediaAction) -> Void)?

  private let surface = SurfaceLayer()
  private let artView = MediaArtView()
  private let unmute = MediaCircleButton()
  private let group = MarqueeGroup()
  private let title = MarqueeLabel()
  private let artist = MarqueeLabel()
  private let previous = TransportButton()
  private let play = TransportButton()
  private let next = TransportButton()
  private let elapsed = NSTextField(labelWithString: "")
  private let remaining = NSTextField(labelWithString: "")
  private let seek = SeekBarView()
  private var state: MediaPlayerState?
  private var ticker: Timer?
  private var dragProgress: Double?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(surface)
    surface.radius = 12
    surface.border = 0.5
    surface.glowColor = .black
    surface.glowRadius = 16
    surface.glowOffset = CGSize(width: 0, height: 6)
    artView.hoverArrow = true
    artView.onPress = { [weak self] in self?.onAction?(.backToTab) }
    addSubview(artView)
    unmute.onPress = { [weak self] in self?.onAction?(.toggleMute) }
    addSubview(unmute)
    group.add(title)
    group.add(artist)
    addSubview(title)
    addSubview(artist)
    for b in [previous, play, next] { addSubview(b) }
    previous.onPress = { [weak self] in self?.transport(-1) }
    play.onPress = { [weak self] in self?.onAction?(.toggle) }
    next.onPress = { [weak self] in self?.transport(1) }
    for label in [elapsed, remaining] {
      label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
      label.isSelectable = false
      addSubview(label)
    }
    seek.barHeight = 6
    seek.onDrag = { [weak self] p in
      self?.dragProgress = p
      self?.renderTime()
    }
    seek.onSeek = { [weak self] p in
      guard let self, let duration = self.state?.duration else { return }
      self.dragProgress = nil
      self.onAction?(.seek(p * duration))
    }
    addSubview(seek)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func transport(_ direction: Int) {
    guard let state else { return }
    if state.tracks { onAction?(direction < 0 ? .previous : .next) } else { onAction?(.skip(direction * MediaFormat.skipSeconds)) }
  }

  public func update(_ next: MediaPlayerState) {
    let old = state
    state = next
    let palette = MediaPalette(next.theme)
    let tokens = palette.tokens
    surface.fill = tokens.background
    surface.borderTint = tokens.border
    surface.glowOpacity = palette.panelShadowOpacity * 0.8
    artView.set(next, palette: palette)
    unmute.isHidden = !next.muted
    unmute.style(fill: tokens.background, border: nil, borderWidth: 0, shadow: 0, shadowRadius: 0, shadowOffset: 0)
    unmute.set("speaker.slash.fill", size: 10, weight: .regular, color: tokens.label, box: 16, tooltip: "Unmute Site")
    group.reset("\(next.title)|\(next.subtitle)")
    title.set(next.title, font: .systemFont(ofSize: 13, weight: .semibold), color: tokens.label, background: tokens.backgroundRGB)
    artist.set(next.subtitle, font: .systemFont(ofSize: 11), color: tokens.secondary, background: tokens.backgroundRGB)
    let tracks = next.tracks
    let skip = MediaFormat.skipSeconds
    previous.set(tracks ? "backward.end.fill" : "gobackward.\(skip)", size: tracks ? 14 : 15, color: tokens.label, tooltip: tracks ? "Play Previous Track" : "Skip back \(skip) seconds")
    play.set(next.playing ? "pause.fill" : "play.fill", size: 24, color: tokens.label, tooltip: next.playing ? "Pause" : "Play")
    self.next.set(tracks ? "forward.end.fill" : "goforward.\(skip)", size: tracks ? 14 : 15, color: tokens.label, tooltip: tracks ? "Play Next Track" : "Skip ahead \(skip) seconds")
    for label in [elapsed, remaining] { label.textColor = tokens.secondary }
    seek.colors = (tokens.track, tokens.fill, tokens.hoverFill)
    seek.seekable = next.hasDuration
    if old?.playing != next.playing || ticker == nil { retick() }
    needsLayout = true
    renderTime()
  }

  private func retick() {
    ticker?.invalidate()
    ticker = nil
    guard state?.playing == true, window != nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.renderTime() } }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    retick()
  }

  private func renderTime() {
    guard let state else { return }
    let duration = state.duration ?? 0
    let position = dragProgress.map { duration > 0 ? $0 * duration : state.position(at: MediaClock.nowMs()) } ?? state.position(at: MediaClock.nowMs())
    elapsed.stringValue = MediaFormat.time(position)
    remaining.stringValue = "-" + MediaFormat.time(duration - position)
    seek.progress = duration > 0 ? state.position(at: MediaClock.nowMs()) / duration : 0
    layoutTime()
  }

  public override func layout() {
    super.layout()
    MediaMotion.setInstantly { surface.frame = bounds }
    let inset = Self.inset
    let o = Self.border
    artView.frame = CGRect(x: inset + o, y: inset + o, width: Self.art, height: Self.art)
    unmute.frame = CGRect(x: inset + Self.art + 5 - 20 + o, y: inset + Self.art + 5 - 20 + o, width: 20, height: 20)
    let textWidth = Self.width - Self.textX - Self.controlsWidth - 8 - inset
    title.frame = CGRect(x: Self.textX + o, y: 10, width: textWidth, height: 18)
    artist.frame = CGRect(x: Self.textX + o, y: 30, width: textWidth, height: 16)
    let controlsX = Self.width - inset - Self.controlsWidth + o
    let tracks = state?.tracks ?? false
    place(previous, left: controlsX, width: 16, size: tracks ? 14 : 15)
    place(play, left: controlsX + 32, width: 24, size: 24)
    place(next, left: controlsX + 72, width: 16, size: tracks ? 14 : 15)
    layoutTime()
  }

  private func place(_ button: TransportButton, left: CGFloat, width: CGFloat, size: CGFloat) {
    let box = max(width, size + 4)
    button.frame = CGRect(x: left - (box - width) / 2, y: 9 + Self.border, width: box, height: 38)
  }

  private func layoutTime() {
    let left = Self.textX + Self.border
    let right = Self.width - Self.inset + Self.border
    let top: CGFloat = 50 + Self.border
    let height: CGFloat = 18
    let elapsedSize = elapsed.intrinsicContentSize
    let elapsedWidth = ceil(elapsedSize.width)
    elapsed.frame = CGRect(x: left - Self.labelPadding, y: top + (height - elapsedSize.height) / 2, width: elapsedWidth + Self.labelPadding * 2, height: elapsedSize.height)
    let hasDuration = state?.hasDuration ?? false
    remaining.isHidden = !hasDuration
    seek.isHidden = !hasDuration
    guard hasDuration else { return }
    let remainingSize = remaining.intrinsicContentSize
    let remainingWidth = ceil(remainingSize.width)
    remaining.frame = CGRect(x: right - remainingWidth - Self.labelPadding, y: top + (height - remainingSize.height) / 2, width: remainingWidth + Self.labelPadding * 2, height: remainingSize.height)
    let seekLeft = left + elapsedWidth + 6
    seek.frame = CGRect(x: seekLeft, y: top, width: max(0, right - remainingWidth - 6 - seekLeft), height: height)
  }

#if SOLARA_PROBES
  public var controlLabels: [String: String] {
    ["play": play.toolTip ?? "", "previous": previous.toolTip ?? "", "next": next.toolTip ?? "",
      "art": artView.toolTip ?? "", "unmute": unmute.toolTip ?? ""]
  }
#endif

  public var controlFrames: [String: CGRect] { ["play": play.frame, "art": artView.frame, "seek": seek.frame, "previous": previous.frame] }
  public var marqueeProgress: Double { group.progress() }
  public var titleShift: Double { title.presentedShift }
  public var titleOverflow: Double { title.overflow }
  public var artistOverflow: Double { artist.overflow }
  public var hoverProgress: Double? { seek.hoverProgress }
  public var elapsedText: String { elapsed.stringValue }
  public var showsArtwork: Bool { artView.showsArtwork }
}
