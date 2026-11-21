import AppKit
import Testing

@testable import SolaraUI

@Suite struct MediaFormatTests {
  @Test func timeMatchesJS() {
    #expect(MediaFormat.time(0) == "0:00")
    #expect(MediaFormat.time(5.9) == "0:05")
    #expect(MediaFormat.time(65) == "1:05")
    #expect(MediaFormat.time(3600) == "1:00:00")
    #expect(MediaFormat.time(3725) == "1:02:05")
    #expect(MediaFormat.time(-4) == "0:00")
  }

  func session(_ playbackState: String, position: Double = 10, timestamp: Double = 1000, rate: Double = 1, duration: Double? = 60) -> MediaPlayerState {
    MediaPlayerState(
      tabId: "t", title: "T", subtitle: "S", muted: false, playbackState: playbackState, position: position, timestamp: timestamp,
      playbackRate: rate, duration: duration, tracks: false, artwork: nil, url: "https://a.test/", favicon: nil, profileId: "p",
      theme: MediaThemeState(dark: true))
  }

  @Test func positionAdvancesOnlyWhilePlaying() {
    #expect(session("playing").position(at: 3000) == 12)
    #expect(session("paused").position(at: 3000) == 10)
    #expect(session("playing", rate: 2).position(at: 3000) == 14)
    #expect(session("playing", rate: 0).position(at: 3000) == 12)
  }

  @Test func positionClampsToDuration() {
    #expect(session("playing", duration: 11).position(at: 9000) == 11)
    #expect(session("playing", position: -5, duration: nil).position(at: 1000) == 0)
    #expect(session("playing", duration: nil).position(at: 101_000) == 110)
  }
}

@Suite struct MediaMotionTests {
  @Test func tweenFollowsRNEasing() {
    let tween = RNTween(from: 0, to: 1, start: 10, duration: 0.16, easing: .outCubic)
    #expect(tween.value(at: 10) == 0)
    #expect(abs(tween.value(at: 10.08) - 0.875) < 1e-9)
    #expect(tween.value(at: 10.2) == 1)
    let hide = RNTween(from: 1, to: 0, start: 0, duration: 0.2, easing: .inQuad)
    #expect(abs(hide.value(at: 0.1) - 0.75) < 1e-9)
    #expect(tween.samples().count == 21)
  }

  @Test func marqueeLoopMatchesRNSequence() {
    let timing = MarqueeTiming(maxOverflow: 60)
    #expect(timing.leg == 2)
    #expect(timing.period == 7)
    #expect(timing.progress(at: 1) == 0)
    #expect(timing.progress(at: 2.5) == 0.5)
    #expect(timing.progress(at: 4) == 1)
    #expect(timing.progress(at: 6) == 0.5)
    #expect(timing.progress(at: 8.5) == 0)
    #expect(MarqueeTiming(maxOverflow: 0.5).progress(at: 2.5) == 0)
    let leading = timing.edgeKeys(leading: true)
    #expect(leading.values == [0, 0, 1, 1, 0])
    #expect(abs(leading.times[2] * 7 - 1.56) < 1e-9)
  }
}

@MainActor
@Suite struct MediaLayoutTests {
  let theme = MediaThemeState(dark: true, colors: ["panel": "#2A2A2A"], panelShadowOpacity: 0.5)

  @Test func cliPillSitsCentredAboveTheBottom() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.layoutSubtreeIfNeeded()
    let pill = view.pillFrame
    #expect(pill.height == 33)
    #expect(abs(pill.maxY - 588) < 0.01)
    #expect(abs(pill.midX - 400) <= 0.5)
    #expect(view.progress == 1)
  }

  @Test func cliPillStopTitleIsNotTruncated() {
    let view = CliControlPillView(frame: .zero)
    view.update(CliPillState(shown: false, command: "solara", product: "Solara", theme: theme))
    view.frame = NSRect(x: 0, y: 0, width: 1083, height: 746)
    view.layoutSubtreeIfNeeded()
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.layoutSubtreeIfNeeded()
    #expect(view.pillFrame.width == 1 + 6 + 20 + 8 + 151 + 8 + view.stopWidth + 4)
    #expect(view.pillFrame.height == 33)
    #expect(!view.stopTitleClipped)
  }

  @Test func cliPillStopGoesToTheNativeIndicatorOnlyWhileItIsShown() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let indicator = CliPillIndicator()
    view.indicator = indicator
    var stops: [String] = []
    view.onStop = { stops.append("js") }
    indicator.onStop = { stops.append("native") }
    indicator.stop(fallback: view.onStop)
    indicator.set(shown: true, product: "Solara", command: "solara")
    indicator.stop(fallback: view.onStop)
    indicator.set(shown: false, product: "Solara", command: "solara")
    indicator.stop(fallback: view.onStop)
    #expect(stops == ["js", "native", "js"])
  }

  @Test func cliPillNeverOverflowsANarrowPane() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.layoutSubtreeIfNeeded()
    #expect(view.pillFrame.width <= 96)
  }

  @Test func cliPillHidesWithRNTiming() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.update(CliPillState(shown: false, command: "solara", product: "Solara", theme: theme))
    #expect(view.progress > 0.99)
    #expect(!view.shown)
  }

  @Test func smallBarFieldMatchesSmallChrome() {
    #expect(SmallBarMetrics.fieldFrame(width: 600, buttons: 3) == CGRect(x: 84, y: 5, width: 416, height: 28))
    #expect(SmallBarMetrics.fieldFrame(width: 600, buttons: 2) == CGRect(x: 84, y: 5, width: 446, height: 28))
  }

  @Test func shareBarButtonsSitRightOfTheText() {
    let bar = ShareBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 38))
    bar.update(ShareBarState(capturer: "c", tabId: "t", shared: false, host: "meet.test", theme: theme))
    bar.layoutSubtreeIfNeeded()
    let f = bar.controlFrames
    #expect(f["dismiss"]!.maxX == 892)
    #expect(f["primary"]!.maxX == f["dismiss"]!.minX - 10)
    #expect(f["dismiss"]!.height == 28 && f["dismiss"]!.minY == 5)
    #expect(bar.primaryTitle == "Share This Tab Instead")
    #expect(f["text"]!.minX == 42)
  }

  @Test func sidebarPlayerMatchesRNGeometry() {
    let player = SidebarPlayerView(frame: NSRect(x: 0, y: 0, width: 220, height: 74))
    player.update(MediaPlayerState(
      tabId: "t", title: "T", subtitle: "S", muted: false, playbackState: "playing", position: 30, timestamp: MediaClock.nowMs(),
      playbackRate: 1, duration: 60, tracks: false, artwork: nil, url: "https://a.test/", favicon: nil, profileId: "p", theme: theme))
    player.layoutSubtreeIfNeeded()
    let f = player.controlFrames
    #expect(f["art"] == CGRect(x: 7.5, y: 7.5, width: 32, height: 32))
    #expect(f["play"] == CGRect(x: 27.5, y: 43.5, width: 24, height: 24))
    #expect(f["seek"] == CGRect(x: 81.5, y: 49.5, width: 131, height: 12))
    let size = SidebarPlayerView.cornerSize, overhang = SidebarPlayerView.cornerOverhang
    #expect(f["close"] == CGRect(x: 220 + overhang - size, y: -overhang, width: size, height: size))
    #expect(f["close"] == CGRect(x: 202, y: -2, width: 20, height: 20))
    #expect(abs(player.seekProgress - 0.5) < 0.01)
  }

  @Test func castPickerListsRowsAndReportsItsHeight() {
    var heights: [Double] = []
    let picker = CastPickerView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
    picker.onAction = { if case .height(let h) = $0 { heights.append(h) } }
    let sink = { (i: Int, active: Bool) in CastSinkState(id: "s\(i)", name: "Speaker \(i)", icon: "hifispeaker", detail: active ? "Casting" : nil, issue: false, active: active, busy: false) }
    picker.update(CastPickerState(dialogId: "d", tabId: "t", title: "Cast tab", canScreen: false, rejected: false, rejectedText: "", sinks: [sink(0, false), sink(1, true)], theme: theme))
    picker.layoutSubtreeIfNeeded()
    let f = picker.controlFrames
    #expect(f["sink0"] == CGRect(x: 6, y: 44, width: 328, height: 42))
    #expect(abs(f["sink1"]!.minY - 88) < 0.01)
    #expect(f["stop1"] != nil && f["stop0"] == nil)
    #expect(f["done"]!.maxX == 340 - 16 && f["done"]!.minY == 44 + 86 + 10)
    #expect(heights.last == Double(44 + 86 + 10 + 28 + 16))
    #expect(f["source"] == nil)
  }

  @Test func castPickerCapsTheListAndShowsSources() {
    let picker = CastPickerView(frame: NSRect(x: 0, y: 0, width: 340, height: 600))
    let sinks = (0..<10).map { CastSinkState(id: "s\($0)", name: "TV \($0)", icon: "tv", detail: nil, issue: false, active: false, busy: false) }
    picker.update(CastPickerState(dialogId: "d", tabId: "t", title: "Cast tab", canScreen: true, rejected: false, rejectedText: "", sinks: sinks, theme: theme))
    picker.layoutSubtreeIfNeeded()
    let f = picker.controlFrames
    #expect(f["header"]!.height == 46)
    #expect(f["source"]!.height == 22 && f["source"]!.maxX == 340 - 16 + 6)
    #expect(abs(picker.contentHeight - 380) < 0.01)
  }

  @Test func sharePickerTilesScreensTwoAcross() {
    let picker = SharePickerView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
    picker.update(SharePickerState(
      requestId: "r", tabId: "t", title: "Share your screen with meet.test", subtitle: "The site will see what you choose.",
      tabs: [ShareTabSource(id: "t", title: "Meet", url: "https://meet.test/", favicon: nil, profileId: "p", current: true)],
      screens: [ShareScreenSource(id: "s1", name: "Built-in", size: "1512 × 982", aspect: 982 / 1512), ShareScreenSource(id: "s2", name: "Studio", size: nil, aspect: 0.5625)],
      windows: [], selected: "s2", valid: true, audio: nil, tileWidth: 220, theme: theme))
    picker.layoutSubtreeIfNeeded()
    let f = picker.controlFrames
    let tile: CGFloat = 220
    #expect(f["tab:t"]!.width == 448 && f["tab:t"]!.height == 34)
    #expect(f["s1"]!.width == tile && f["s2"]!.minX == f["s1"]!.maxX + 8 && f["s1"]!.minY == f["s2"]!.minY)
    #expect(f["share"]!.maxX == 460 - 16 && f["cancel"]!.maxX == f["share"]!.minX - 8)
    #expect(SharePickerMetrics.previewHeight(tileWidth: tile, aspect: 982 / 1512) == 80)
    #expect(picker.selectedId == "s2")
  }

  @Test func popoverPlacesItsCardAsRNDoes() {
    let body = CastPickerView()
    let popover = PopoverView(body: body)
    popover.frame = NSRect(x: 0, y: 0, width: 1083, height: 746)
    let window = MediaLayoutWindow(contentRect: popover.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = popover
    defer {
      window.contentView = nil
      window.close()
    }
    popover.onDismiss = {}
    popover.set(placement: PopoverPlacement(width: 340, top: 8, right: 8), dark: true)
    popover.set(bodyHeight: 184)
    popover.layoutSubtreeIfNeeded()
    #expect(popover.cardFrame == CGRect(x: 735, y: 8, width: 340, height: 185))
    #expect(body.convert(body.bounds, to: popover) == CGRect(x: 735.5, y: 8.5, width: 339, height: 184))
    #expect(popover.hitTest(NSPoint(x: 100, y: 100)) === popover)
    popover.set(placement: PopoverPlacement(width: 460, top: 8, left: 311.5), dark: false)
    popover.layoutSubtreeIfNeeded()
    #expect(popover.cardFrame.minX == 311.5)
  }
}

@MainActor
private final class MediaLayoutWindow: NSWindow {
  override var backingScaleFactor: CGFloat { 2 }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
