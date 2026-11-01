import AppKit
import Observation
import SolaraModel
import SolaraOmnibox
import SwiftUI
#if SOLARA_PROBES
import SolaraProbes
#endif

public struct NewTabIdentity: Equatable, Sendable {
  public var windowId: String
  public var tabId: String
  public var profileId: String

  public init(windowId: String, tabId: String, profileId: String) {
    self.windowId = windowId
    self.tabId = tabId
    self.profileId = profileId
  }
}

@MainActor
public final class NewTabHeroView: NSView {
  public var events = HeroBarEvents() { didSet { model?.events = events } }
  public var onBarLayout: (_ barHeight: CGFloat, _ headingHeight: CGFloat) -> Void = { _, _ in }
  public var settings: () -> SolaraModel.Settings = { SolaraModel.Settings(values: [:]) }
  public var fetcher: SuggestFetcher? { didSet { if fetcher !== oldValue { model?.setFetcher(fetcher) } } }
  public var bangStore: BangStore?
  public var favicons: NewTabFavicons? { didSet { refreshEnvironment() } }
  public var theme = NewTabTheme.fallbackLight { didSet { if theme != oldValue { applyTheme() } } }
  public var incognito = false { didSet { model?.incognito = incognito; needsLayout = true } }
  public var onboarding = false {
    didSet {
      guard onboarding != oldValue else { return }
      rebuildContent()
      guard !onboarding else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window != nil else { return }
        self.layoutSubtreeIfNeeded()
        self.model?.focusOnce()
      }
    }
  }
  public var under: CGFloat = 0 { didSet { if under != oldValue { needsLayout = true } } }
  public var panelOpen = false { didSet { model?.panelOpened(panelOpen) } }
  public var playIntro = false {
    didSet {
      guard playIntro != oldValue, intro == nil, !introDecided else { return }
      if playIntro && !NewTabHeroView.reduceMotion { mark.apply(MarkIntroPlayer().offsets) }
    }
  }
  public var markImages: [MarkLayer.Name: NSImage] = [:] { didSet { mark.setImages(markImages) } }

  public private(set) var model: HeroBarModel?
  private var identity: NewTabIdentity?
  private let mark = MarkView(frame: .zero)
  private let shadowNear = BarSurfaceView(frame: .zero)
  private let shadowFar = BarSurfaceView(frame: .zero)
  private let surface = BarSurfaceView(frame: .zero)
  private var content: NSHostingView<AnyView>?
  private var heading: NSHostingView<AnyView>?
  private var barHeight: CGFloat = NewTabLayout.barHeight
  private var headingHeight: CGFloat = 0
  private var reported: (CGFloat, CGFloat)?
  private var intro: MarkIntroPlayer?
  private var introDecided = false
  private var link: CADisplayLink?
  private var watching = false
  private var mountedOnce = false
  public private(set) var introTrace: [(time: Double, offsets: MarkOffsets)] = []
  public var recordsIntro = false

  public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    shadowNear.shadowColor = .black
    shadowNear.shadowOpacity = 0.08
    shadowNear.shadowRadius = 2
    shadowNear.shadowOffset = CGSize(width: 0, height: 0.5)
    shadowFar.shadowColor = .black
    shadowFar.shadowOpacity = 0.04
    shadowFar.shadowRadius = 1
    shadowFar.shadowOffset = CGSize(width: 0, height: 2)
    for s in [shadowNear, shadowFar, surface] {
      s.radius = NewTabLayout.barRadius
      addSubview(s)
    }
    addSubview(mark, positioned: .below, relativeTo: shadowNear)
    surface.borderWidth = NewTabLayout.barBorder
    applyTheme()
    #if SOLARA_PROBES
    ProbeCapture.shared.register(self) { $0.prepareForCapture() }
    #endif
  }

  required init?(coder: NSCoder) { fatalError() }

  public func configure(_ next: NewTabIdentity) {
    guard identity != next else { return }
    model?.save()
    identity = next
    let made = HeroBarModel(
      windowId: next.windowId, tabId: next.tabId, profileId: next.profileId, incognito: incognito, settings: { [weak self] in self?.settings() ?? SolaraModel.Settings(values: [:]) },
      fetcher: fetcher, bangStore: bangStore)
    made.events = events
    made.panelOpened(panelOpen)
    model = made
    rebuildContent()
    watchSources()
  }

  public var barFrame: CGRect { surface.frame }

  public func focusBar() {
    model?.focusSelectingAll()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard surface.frame.contains(local) else { return nil }
    return super.hitTest(point)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      model?.save()
      stopLink()
      return
    }
    mark.setImages(markImages)
    if !mountedOnce {
      mountedOnce = true
      model?.mounted()
    }
    decideIntro()
    needsLayout = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil else { return }
      self.layoutSubtreeIfNeeded()
      self.model?.focusOnce()
    }
  }

  public override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor ?? 2
    let showsHeading = incognito && !onboarding
    let frames = NewTabLayout.frames(size: bounds.size, under: under, headingHeight: showsHeading ? headingHeight : 0, barHeight: barHeight, scale: scale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mark.frame = frames.mark
    for s in [shadowNear, shadowFar, surface] { s.frame = frames.bar }
    content?.frame = surface.bounds.insetBy(dx: NewTabLayout.barBorder, dy: NewTabLayout.barBorder)
    if showsHeading {
      if heading == nil { makeHeading() }
      let size = heading?.fittingSize ?? .zero
      heading?.frame = CGRect(x: frames.bar.minX, y: frames.headingTop, width: frames.bar.width, height: max(size.height, headingHeight))
      heading?.alphaValue = headingHeight > 0 ? 1 : 0
    } else {
      heading?.removeFromSuperview()
      heading = nil
    }
    CATransaction.commit()
    report()
  }

  private func report() {
    let now = (barHeight, incognito && !onboarding ? headingHeight : 0)
    if reported.map({ $0 != now }) ?? true {
      reported = now
      onBarLayout(now.0, now.1)
    }
  }

  private func environment() -> NewTabEnvironment {
    NewTabEnvironment(theme: theme, favicons: favicons, profileId: identity?.profileId ?? "")
  }

  private func applyTheme() {
    surface.fill = theme.ntpBarSolid.ns
    surface.borderColor = theme.ntpBarBorder.ns
    refreshEnvironment()
  }

  private func refreshEnvironment() {
    if model != nil { rebuildContent() }
    if heading != nil {
      heading?.removeFromSuperview()
      heading = nil
      needsLayout = true
    }
  }

  private func rebuildContent() {
    guard let model else { return }
    let env = environment()
    let view: AnyView
    if onboarding {
      view = AnyView(Color.clear.frame(height: NewTabLayout.barHeight - 2 * NewTabLayout.barBorder).onAppear { [weak self] in
        self?.setBarHeight(NewTabLayout.barHeight - 2 * NewTabLayout.barBorder)
      })
    } else {
      view = AnyView(HeroBarContent(model: model) { [weak self] h in self?.setBarHeight(h) }.environment(\.newTab, env))
    }
    if let content {
      content.rootView = view
    } else {
      let hosting = NSHostingView(rootView: view)
      hosting.sizingOptions = []
      hosting.safeAreaRegions = []
      surface.addSubview(hosting)
      content = hosting
    }
    needsLayout = true
  }

  private func makeHeading() {
    let view = AnyView(IncognitoHeadingView { [weak self] h in self?.setHeadingHeight(h) }.environment(\.newTab, environment()))
    let hosting = NSHostingView(rootView: view)
    hosting.sizingOptions = []
    hosting.safeAreaRegions = []
    addSubview(hosting)
    heading = hosting
  }

  private func setBarHeight(_ contentHeight: CGFloat) {
    let h = contentHeight + 2 * NewTabLayout.barBorder
    guard contentHeight > 0, h != barHeight else { return }
    barHeight = h
    needsLayout = true
  }

  private func setHeadingHeight(_ h: CGFloat) {
    guard h != headingHeight else { return }
    headingHeight = h
    needsLayout = true
  }

  private func watchSources() {
    guard !watching else { return }
    watching = true
    observeSources()
  }

  private func observeSources() {
    withObservationTracking {
      _ = NewTabSources.shared.revision
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.watching else { return }
        self.model?.sourcesChanged()
        self.observeSources()
      }
    }
  }

  #if SOLARA_PROBES
  private func prepareForCapture() -> ProbeCapture.Restore {
    let offsets = mark.offsets
    let transforms = (mark.layer?.sublayers ?? []).map { ($0, $0.transform) }
    mark.apply(.rest)
    return { [mark] in
      mark.apply(offsets)
      for (layer, transform) in transforms { layer.transform = transform }
    }
  }
  #endif

  private func decideIntro() {
    guard !introDecided else { return }
    introDecided = true
    guard playIntro, !NewTabHeroView.reduceMotion else {
      mark.apply(.rest)
      return
    }
    intro = MarkIntroPlayer()
    mark.apply(intro!.offsets)
    let made = displayLink(target: self, selector: #selector(tick(_:)))
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard var player = intro else { return stopLink() }
    let now = link.timestamp
    player.start(at: now)
    let offsets = player.step(at: now)
    mark.apply(offsets)
    if recordsIntro { introTrace.append((now, offsets)) }
    intro = player
    if player.finished {
      intro = nil
      stopLink()
    }
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  isolated deinit {
    watching = false
    link?.invalidate()
    model?.save()
  }
}
