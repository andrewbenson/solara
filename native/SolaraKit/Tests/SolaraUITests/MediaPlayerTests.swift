import AppKit
import QuartzCore
import Testing

@testable import SolaraUI

@MainActor
@Suite struct MediaPlayerTests {
  private func state(muted: Bool = false, playing: Bool = false, duration: Double? = 120, tracks: Bool = false, artwork: String? = nil) -> MediaPlayerState {
    MediaPlayerState(
      tabId: "media-tab", title: "A title", subtitle: "example.test", muted: muted, playbackState: playing ? "playing" : "paused",
      position: 30, timestamp: MediaClock.nowMs(), playbackRate: 1, duration: duration, tracks: tracks, artwork: artwork,
      url: "https://example.test/", favicon: nil, profileId: "profile", theme: MediaThemeState(dark: true))
  }

  private func sidebar(_ state: MediaPlayerState) -> SidebarPlayerView {
    let view = SidebarPlayerView(frame: CGRect(x: 0, y: 0, width: 220, height: 74))
    view.update(state)
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func mini(_ state: MediaPlayerState) -> MiniPlayerView {
    let view = MiniPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 76))
    view.update(state)
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func event(_ type: NSEvent.EventType, in view: NSView, fraction: CGFloat = 0.5) throws -> NSEvent {
    let point = view.convert(CGPoint(x: view.bounds.width * fraction, y: view.bounds.midY), to: nil)
    return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  private func click(_ view: NSView) throws {
    view.mouseDown(with: try event(.leftMouseDown, in: view))
    view.mouseUp(with: try event(.leftMouseUp, in: view))
  }

  @Test func sidebarTransportUsesCurrentPlaybackAndTrackState() throws {
    let view = sidebar(state())
    let buttons = view.subviews.compactMap { $0 as? SidebarIconButton }
    #expect(buttons.map(\.toolTip) == ["Skip back 15 seconds", "Play", "Skip ahead 15 seconds"])
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    for button in buttons { try click(button) }
    #expect(actions == [.skip(-15), .toggle, .skip(15)])

    view.update(state(playing: true, tracks: true))
    #expect(buttons.map(\.toolTip) == ["Play Previous Track", "Pause", "Play Next Track"])
    actions.removeAll()
    for button in buttons { try click(button) }
    #expect(actions == [.previous, .toggle, .next])
  }

  @Test func sidebarHoverControlsPreservePlaybackAndTrackGeometry() throws {
    let view = sidebar(state())
    let before = view.controlFrames
    #expect(!view.cornersShown)
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    let onCard = view.convert(CGPoint(x: view.bounds.midX, y: 30), to: nil)
    view.mouseEntered(with: try #require(NSEvent.mouseEvent(with: .mouseMoved, location: onCard, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
    view.layoutSubtreeIfNeeded()
    #expect(view.cornersShown)
    #expect(view.controlFrames == before)
    let corners = view.subviews.compactMap { $0 as? MediaCircleButton }
    #expect(corners.map(\.toolTip) == ["Mute Site", "Close Player"])
    for corner in corners { #expect(corner.accessibilityPerformPress()) }
    #expect(actions == [.toggleMute, .dismiss])
    view.update(state(muted: true))
    #expect(corners.first?.toolTip == "Unmute Site")
    #expect(view.controlFrames == before)
    view.mouseExited(with: NSEvent())
    #expect(!view.cornersShown)
    #expect(actions == [.toggleMute, .dismiss])
  }

  @Test func sidebarSeeksOnlyWithAKnownDurationAndArtworkReturnsToTab() throws {
    let view = sidebar(state())
    let seek = try #require(view.subviews.compactMap { $0 as? SeekBarView }.first)
    let art = try #require(view.subviews.compactMap { $0 as? MediaArtView }.first)
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    #expect(view.seekProgress == 0.25)
    seek.mouseDown(with: try event(.leftMouseDown, in: seek, fraction: 0.75))
    #expect(actions.isEmpty)
    seek.mouseUp(with: try event(.leftMouseUp, in: seek, fraction: 0.75))
    #expect(actions == [.seek(90)])
    #expect(art.accessibilityPerformPress())
    #expect(actions == [.seek(90), .backToTab])

    view.update(state(duration: nil))
    #expect(seek.isHidden && !seek.seekable)
    seek.mouseDown(with: try event(.leftMouseDown, in: seek))
    seek.mouseUp(with: try event(.leftMouseUp, in: seek))
    #expect(actions == [.seek(90), .backToTab])
  }

  @Test func miniPlayerKeepsArtworkLabelsAndTransportInTheirMeasuredFrames() throws {
    let view = mini(state())
    let f = view.controlFrames
    #expect(f["art"] == CGRect(x: 10.5, y: 10.5, width: 56, height: 56))
    #expect(f["play"] == CGRect(x: 252.5, y: 9.5, width: 28, height: 38))
    #expect(f["previous"] == CGRect(x: 221, y: 9.5, width: 19, height: 38))
    let labels = view.subviews.compactMap { $0 as? MarqueeLabel }
    #expect(labels.map(\.frame) == [CGRect(x: 78.5, y: 10, width: 136, height: 18), CGRect(x: 78.5, y: 30, width: 136, height: 16)])
    let seek = try #require(view.subviews.compactMap { $0 as? SeekBarView }.first)
    #expect(seek.frame.minY == 50.5 && seek.frame.height == 18)
    #expect(seek.progress == 0.25)
    #expect(view.elapsedText == "0:30")
    #expect(!view.showsArtwork)
    let unmute = try #require(view.subviews.compactMap { $0 as? MediaCircleButton }.first)
    #expect(unmute.isHidden)
    view.update(state(muted: true))
    view.layoutSubtreeIfNeeded()
    #expect(!unmute.isHidden)
    #expect(view.controlFrames == f)
    #expect(unmute.frame == CGRect(x: 51.5, y: 51.5, width: 20, height: 20))
  }

  @Test func miniTransportArtworkAndUnmuteSendOnlyTheirOwnAction() throws {
    let view = mini(state(muted: true, playing: true, tracks: true))
    let buttons = view.subviews.compactMap { $0 as? TransportButton }
    #expect(buttons.map(\.toolTip) == ["Play Previous Track", "Pause", "Play Next Track"])
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    for button in buttons { #expect(button.accessibilityPerformPress()) }
    let art = try #require(view.subviews.compactMap { $0 as? MediaArtView }.first)
    let unmute = try #require(view.subviews.compactMap { $0 as? MediaCircleButton }.first)
    #expect(art.accessibilityPerformPress())
    #expect(unmute.accessibilityPerformPress())
    #expect(actions == [.previous, .toggle, .next, .backToTab, .toggleMute])
    view.update(state())
    #expect(buttons.map(\.toolTip) == ["Skip back 15 seconds", "Play", "Skip ahead 15 seconds"])
    actions.removeAll()
    for button in buttons { #expect(button.accessibilityPerformPress()) }
    #expect(actions == [.skip(-15), .toggle, .skip(15)])
  }

  @Test func miniHoverRevealsTheArtworkArrowAndBrightensOnlyTheHoveredControl() throws {
    let view = mini(state())
    let art = try #require(view.subviews.compactMap { $0 as? MediaArtView }.first)
    let arrow = try #require(art.subviews.last)
    let buttons = view.subviews.compactMap { $0 as? TransportButton }
    try #require(buttons.count == 3)
    let before = view.controlFrames
    #expect(arrow.isHidden)
    #expect(buttons.allSatisfy { $0.layer?.opacity == 0.6 })
    art.mouseEntered(with: NSEvent())
    buttons[1].mouseEntered(with: NSEvent())
    view.layoutSubtreeIfNeeded()
    #expect(!arrow.isHidden)
    #expect(buttons[1].layer?.opacity == 1)
    #expect(buttons[0].layer?.opacity == 0.6 && buttons[2].layer?.opacity == 0.6)
    #expect(view.controlFrames == before)
    art.mouseExited(with: NSEvent())
    buttons[1].mouseExited(with: NSEvent())
    view.layoutSubtreeIfNeeded()
    #expect(arrow.isHidden)
    #expect(buttons[1].layer?.opacity == 0.6)
  }

  @Test func miniSeekPreviewsTimeAndCommitsOnceOnRelease() throws {
    let view = mini(state())
    let seek = try #require(view.subviews.compactMap { $0 as? SeekBarView }.first)
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    seek.mouseDown(with: try event(.leftMouseDown, in: seek, fraction: 0.5))
    #expect(view.elapsedText == "1:00")
    seek.mouseDragged(with: try event(.leftMouseDragged, in: seek, fraction: 0.75))
    #expect(view.elapsedText == "1:30")
    #expect(actions.isEmpty)
    seek.mouseUp(with: try event(.leftMouseUp, in: seek, fraction: 0.75))
    #expect(actions == [.seek(90)])
    #expect(seek.drag == nil)
    view.update(state(duration: nil))
    #expect(seek.isHidden && !seek.seekable)
    #expect(view.elapsedText == "0:30")
    seek.mouseDown(with: try event(.leftMouseDown, in: seek))
    seek.mouseUp(with: try event(.leftMouseUp, in: seek))
    #expect(actions == [.seek(90)])
  }

  @Test func artworkReplacementAndFallbackKeepTheExpectedFadePolicy() throws {
    let oldLoad = MediaImages.load
    let uri = "media-player-test-\(UUID().uuidString)"
    MediaImages.load = { $0 == uri ? NSImage(size: CGSize(width: 8, height: 8)) : nil }
    defer { MediaImages.load = oldLoad }
    let sidebar = sidebar(state(artwork: uri))
    let mini = mini(state(artwork: uri))
    let sidebarArt = try #require(sidebar.subviews.compactMap { $0 as? MediaArtView }.first)
    let miniArt = try #require(mini.subviews.compactMap { $0 as? MediaArtView }.first)
    #expect(sidebarArt.showsArtwork && mini.showsArtwork)
    let sidebarLayer = try #require(sidebarArt.layer?.sublayers?.first?.sublayers?.first)
    let miniLayer = try #require(miniArt.layer?.sublayers?.first?.sublayers?.first)
    #expect(sidebarLayer.animation(forKey: "artFade") == nil)
    let fade = try #require(miniLayer.animation(forKey: "artFade") as? CABasicAnimation)
    #expect(fade.duration == 0.2)
    #expect(fade.fromValue as? Double == 0 && fade.toValue as? Double == 1)
    sidebar.update(state())
    mini.update(state(artwork: "unavailable-\(uri)"))
    sidebar.layoutSubtreeIfNeeded()
    mini.layoutSubtreeIfNeeded()
    #expect(!sidebarArt.showsArtwork && !mini.showsArtwork)
    #expect(sidebarLayer.isHidden && miniLayer.isHidden)
    #expect(sidebarArt.subviews.compactMap { $0 as? TabIconView }.first?.isHidden == false)
    #expect(miniArt.subviews.compactMap { $0 as? TabIconView }.first?.isHidden == false)
  }

  @Test func circleSymbolsCenterOnTheFirstLayoutAndAfterResizing() throws {
    let view = mini(state(muted: true))
    let button = try #require(view.subviews.compactMap { $0 as? MediaCircleButton }.first)
    let symbol = try #require(button.subviews.first)
    #expect(symbol.frame == CGRect(x: 2, y: 2, width: 16, height: 16))
    button.setFrameSize(CGSize(width: 24, height: 24))
    button.layoutSubtreeIfNeeded()
    #expect(symbol.frame == CGRect(x: 4, y: 4, width: 16, height: 16))
    let sidebar = sidebar(state())
    sidebar.mouseEntered(with: NSEvent())
    sidebar.layoutSubtreeIfNeeded()
    let corners = sidebar.subviews.compactMap { $0 as? MediaCircleButton }
    #expect(corners.allSatisfy { $0.subviews.first?.frame == CGRect(x: 3.5, y: 3.5, width: 13, height: 13) })
  }

  @Test func hoverCardForwardsTheCurrentStateAndCoalescesPointerEvents() {
    let view = HoverPlayerCardView()
    let state = state(muted: true, tracks: true)
    view.set(state)
    view.layoutSubtreeIfNeeded()
    #expect(view.frame.size == CGSize(width: 320, height: 76))
    #expect(view.player.frame == view.bounds)
    #expect(view.state == state)
    var pointers: [Bool] = []
    var actions: [MediaAction] = []
    view.onPointer = { pointers.append($0) }
    view.player.onAction = { actions.append($0) }
    view.mouseEntered(with: NSEvent())
    view.mouseEntered(with: NSEvent())
    view.mouseExited(with: NSEvent())
    view.mouseExited(with: NSEvent())
    #expect(pointers == [true, false])
    #expect(actions.isEmpty)
  }

  nonisolated static let cardBackdrops: [(name: String, dark: Bool, backdrop: String?)] = [
    ("default dark", true, nil), ("default light", false, nil),
    ("purple dark", true, "#2F2130"), ("purple light", false, "#E0CFE7"),
    ("light colour in dark mode", true, "#E8E2C8"), ("dark colour in light mode", false, "#3A3550"),
    ("photo dark", true, "#4A5A3C"), ("photo light", false, "#9FB4C8"), ("mid grey", false, "#808080"),
    ("mid green", true, "#5B8A4C"), ("mid orange", false, "#C87A3C"),
  ]

  @Test(arguments: cardBackdrops.indices)
  func sidebarCardTextReadsAtLeastAA(index: Int) throws {
    let entry = Self.cardBackdrops[index]
    var value = state()
    value.theme = MediaThemeState(dark: entry.dark)
    let view = SidebarPlayerView(frame: CGRect(x: 0, y: 0, width: 220, height: 74))
    view.backdrop = entry.backdrop.flatMap { MediaPalette.parse($0) }
    view.update(value)
    view.layoutSubtreeIfNeeded()
    let look = MediaCardLook(theme: value.theme, backdrop: view.backdrop, reduceTransparency: false)
    #expect(MediaCardLook.contrast(view.titleColor, look.background) >= MediaCardLook.plateContrast, "\(entry.name) title")
    #expect(MediaCardLook.contrast(view.subtitleColor, look.background) >= MediaCardLook.minimumContrast, "\(entry.name) subtitle")
    #expect(MediaCardLook.contrast(view.iconColor, look.background) >= MediaCardLook.controlContrast, "\(entry.name) controls")
    #expect(MediaCardLook.contrast(view.titleColor, look.onScreen(for: view.titleColor)) >= MediaCardLook.plateContrast, "\(entry.name) title through the glass")
    #expect(MediaCardLook.contrast(view.subtitleColor, look.onScreen(for: view.subtitleColor)) >= MediaCardLook.minimumContrast, "\(entry.name) subtitle through the glass")
    #expect(MediaCardLook.contrast(view.iconColor, look.onScreen(for: view.iconColor)) >= MediaCardLook.controlContrast, "\(entry.name) controls through the glass")
    let plate = try #require(view.plateColor?.usingColorSpace(.sRGB))
    #expect(plate.alphaComponent == 1)
    #expect(view.plateOpacity >= 0.7)
  }

  @Test func sidebarCardIsTintedGlassAndOpaqueUnderReduceTransparency() throws {
    let view = SidebarPlayerView(frame: CGRect(x: 0, y: 0, width: 220, height: 74))
    view.backdrop = MediaPalette.parse("#2F2130")
    view.reduceTransparencyOverride = false
    view.update(state())
    view.layoutSubtreeIfNeeded()
    #expect(view.usesGlass)
    let glass = try #require(view.subviews.first as? NewTabGlassSurface)
    #expect(!glass.isHidden)
    #expect(glass.glass.style == .regular)
    let tint = try #require(glass.glass.tintColor?.usingColorSpace(.sRGB))
    #expect(abs(tint.alphaComponent - MediaCardLook.glassTintStrength) < 0.01)
    view.reduceTransparencyOverride = true
    #expect(!view.usesGlass)
    #expect(glass.isHidden)
    #expect(view.plateOpacity == 1)
  }

  @Test func hostedSidebarCardWithoutBackdropStillHasAPlate() throws {
    let view = sidebar(state())
    let plate = try #require(view.plateColor?.usingColorSpace(.sRGB))
    #expect(plate.alphaComponent == 1)
    #expect(view.plateOpacity >= 0.7)
  }

  @Test func sidebarCardBackgroundClicksStayOnTheCard() throws {
    let view = sidebar(state())
    let hit = view.hitTest(CGPoint(x: 200, y: 30))
    #expect(hit === view)
  }
}
