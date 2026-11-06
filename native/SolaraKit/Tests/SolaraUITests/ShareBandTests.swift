import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func bandState(split: Bool) throws -> BrowserState {
  let splits = split ? #", "splits": {"s1": {"id": "s1", "windowId": "wb", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": [0.5, 0.5]}}"# : ""
  let text = #"""
    {"windows": {"wb": {"id": "wb", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "a"}}},
     "windowOrder": ["wb"],
     "tabs": {"a": {"id": "a", "windowId": "wb", "profileId": "p", "url": "https://a.example/"},
              "b": {"id": "b", "windowId": "wb", "profileId": "p", "url": "https://b.example/"}}\#(splits)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private final class ShareBandClock {
  var now: TimeInterval = 100
}

@MainActor
@Suite(.serialized) struct ShareBandTests {
  @Test func theBandEasesOutCubicAsRNsAnimatedTimingDid() {
    #expect(ShareBand.eased(0) == 0)
    #expect(ShareBand.eased(1) == 1)
    #expect(ShareBand.eased(0.5) == 0.875)
    #expect(ShareBand.eased(2) == 1)
  }

  @Test func openingTakesOneEightyMillisecondsAndClosingRemovesTheTab() {
    let clock = ShareBandClock()
    let band = ShareBand(clock: { clock.now }, ticks: false)
    var seen: [[String: CGFloat]] = []
    band.onChange = { seen.append($0) }
    band.target("a", shown: true)
    clock.now += 0.09
    band.step()
    #expect(abs((band.heights["a"] ?? 0) - 38 * 0.875) < 0.001)
    clock.now += 0.09
    band.step()
    #expect(band.heights["a"] == 38)
    #expect(!band.isMoving)
    band.target("a", shown: true)
    #expect(!band.isMoving)
    band.target("a", shown: false)
    clock.now += 0.2
    band.step()
    #expect(band.heights["a"] == nil)
    #expect(seen.last == [:])
  }

  @Test func releasingTheBandMidAnimationStopsItsTimer() throws {
    var band: ShareBand? = ShareBand()
    band?.target("a", shown: true)
    let timer = try #require(band?.scheduledTimer)
    defer { timer.invalidate() }
    weak var released = band
    band = nil
    #expect(released == nil)
    #expect(timer.isValid)
    timer.fire()
    #expect(!timer.isValid)
  }

  @Test func reversingMidwayStartsFromWhereTheBandIsNow() {
    let clock = ShareBandClock()
    let band = ShareBand(clock: { clock.now }, ticks: false)
    band.target("a", shown: true)
    clock.now += 0.09
    band.step()
    let midway = band.heights["a"] ?? 0
    band.target("a", shown: false)
    band.step()
    #expect(band.heights["a"] == midway)
    clock.now += 0.18
    band.step()
    #expect(band.heights["a"] == nil)
  }

  @Test func theBandPushesTheOverlaySlotDownAndHoldsTheBarAboveIt() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let view = PaneOverlaysView(windowId: "wb")
    view.frame = host.bounds
    host.addSubview(view)
    defer { view.removeFromSuperview() }
    view.update(state: try bandState(split: false))
    view.pageTops = ["a": 41]
    let clip = ShareBandClip()
    view.setBand(clip, tabId: "a")
    view.bandHeights = ["a": 38]
    view.layoutSubtreeIfNeeded()
    let slot = try #require(PaneOverlays.shared.container(windowId: "wb", tabId: "a", layer: .native)?.superview)
    #expect(slot.frame == CGRect(x: 0, y: 79, width: 1000, height: 621))
    #expect(clip.frame == CGRect(x: 0, y: 41, width: 1000, height: 38))
    #expect(!clip.isHidden)
    view.bandHeights = ["a": 19]
    #expect(slot.frame.minY == 60)
    #expect(clip.frame.height == 19)
    view.bandHeights = [:]
    #expect(slot.frame == CGRect(x: 0, y: 41, width: 1000, height: 659))
    #expect(clip.isHidden)
  }

  @Test func fullScreenDropsTheBand() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let view = PaneOverlaysView(windowId: "wb")
    view.frame = host.bounds
    host.addSubview(view)
    defer { view.removeFromSuperview() }
    view.update(state: try bandState(split: false))
    let clip = ShareBandClip()
    view.setBand(clip, tabId: "a")
    view.bandHeights = ["a": 38]
    view.setFullscreenTab("a")
    view.layoutSubtreeIfNeeded()
    let slot = try #require(PaneOverlays.shared.container(windowId: "wb", tabId: "a", layer: .native)?.superview)
    #expect(slot.frame.minY == 0)
    #expect(clip.isHidden)
  }

  @Test func theRailPageStartsBelowTheBandButNeverCoversTheRail() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.update { $0.sidebarWidth = 42 }
    let page = shell.pageArea
    shell.cardPageFrame = CGRect(x: 0, y: page.minY + 38, width: shell.frames.card.width, height: page.height - 38)
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 42, y: 85, width: 1151, height: 708))
    shell.cardPageFrame = CGRect(x: 0, y: page.minY - 10, width: shell.frames.card.width, height: page.height)
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 42, y: 47, width: 1151, height: 746))
  }

  @Test func aSplitPaneMovesItsPageDownByTheBand() throws {
    let leaf = SplitLeafView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
    leaf.toolbarHeight = 41
    leaf.layoutSubtreeIfNeeded()
    #expect(leaf.page.frame == CGRect(x: 0, y: 41, width: 500, height: 659))
    leaf.band = 38
    #expect(leaf.page.frame == CGRect(x: 0, y: 79, width: 500, height: 621))
  }
}
