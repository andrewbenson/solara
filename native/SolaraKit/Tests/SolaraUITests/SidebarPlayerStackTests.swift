import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarPlayerStackTests {
  static func state(_ tabId: String) -> MediaPlayerState {
    MediaPlayerState(
      tabId: tabId, title: "Title \(tabId)", subtitle: "Artist", muted: false, playbackState: "playing", position: 10,
      timestamp: MediaClock.nowMs(), playbackRate: 1, duration: 120, tracks: false, artwork: nil, url: "https://example.test/",
      favicon: nil, profileId: "p", theme: MediaThemeState(dark: true))
  }

  func stack(_ ids: [String]) -> SidebarPlayerStack {
    let view = SidebarPlayerStack(frame: .zero)
    view.place(resting: CGRect(x: 10, y: 300, width: 200, height: MediaStackGeometry.collapsedHeight(count: ids.count)))
    view.update(ids.map(Self.state))
    return view
  }

  @Test func heightsFollowTheMock() {
    #expect(MediaStackGeometry.collapsedHeight(count: 0) == 0)
    #expect(MediaStackGeometry.collapsedHeight(count: 1) == 74)
    #expect(MediaStackGeometry.collapsedHeight(count: 3) == 88)
    #expect(MediaStackGeometry.collapsedHeight(count: 5) == 88)
    #expect(MediaStackGeometry.openHeight(count: 3) == CGFloat(3 * 74 + 2 * 8))
  }

  @Test func restingCardsPeekSevenPointsAndShrinkFourPercent() {
    let frames = MediaStackGeometry.frames(count: 3, width: 200, open: false)
    let bottom = MediaStackGeometry.openHeight(count: 3)
    #expect(frames.map(\.maxY) == [bottom, bottom - 7, bottom - 14])
    #expect(frames.map(\.width) == [200, 192, 184])
    #expect(frames.map(\.midX) == [100, 100, 100])
    let open = MediaStackGeometry.frames(count: 3, width: 200, open: true)
    #expect(open.map(\.minY) == [bottom - 74, bottom - 156, 0])
    #expect(open.allSatisfy { $0.width == 200 })
  }

  @Test func newestCardIsInFrontAndOlderOnesPeek() {
    let view = stack(["a", "b", "c"])
    #expect(view.tabIds == ["a", "b", "c"])
    #expect(view.moreText == "+2")
    #expect(view.cardViews.map(\.peeking) == [false, true, true])
    let order = view.subviews.compactMap { $0 as? SidebarPlayerView }
    #expect(order.last === view.cardViews.first)
    #expect(view.frame.maxY == CGFloat(300 + 88))
    #expect(view.cardFrames.first?.maxY == view.bounds.height)
  }

  @Test func openingFansCardsAndShowsTheirContents() {
    let view = stack(["a", "b"])
    view.setOpen(true, animated: false)
    #expect(view.isOpen)
    #expect(view.cardViews.map(\.peeking) == [false, false])
    #expect(view.cardFrames.map(\.minY) == [164, 82])
    view.setOpen(false, animated: false)
    #expect(view.cardViews.map(\.peeking) == [false, true])
  }

  @Test func aSingleCardNeverOpens() {
    let view = stack(["a"])
    view.setOpen(true, animated: false)
    #expect(!view.isOpen)
    #expect(view.moreText == "")
  }

  @Test func reorderAndRemovalKeepCardViews() {
    let view = stack(["a", "b", "c"])
    let b = view.cardViews[1]
    view.update(["b", "a"].map(Self.state))
    #expect(view.tabIds == ["b", "a"])
    #expect(view.cardViews.first === b)
    #expect(view.moreText == "+1")
    #expect(view.cardViews.map(\.peeking) == [false, true])
  }

  @Test func actionsCarryTheirCardsTab() {
    let view = stack(["a", "b"])
    var got: [String] = []
    view.onAction = { tabId, _ in got.append(tabId) }
    view.setOpen(true, animated: false)
    view.cardViews[1].onAction?(.toggle)
    view.cardViews[0].onAction?(.dismiss)
    #expect(got == ["b", "a"])
  }

  @Test func restingClicksReachTheFrontCardAndOnlyTheStripReachesAPeekingOne() throws {
    let host = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 500))
    let view = stack(["a", "b", "c"])
    host.addSubview(view)
    let front = view.cardViews[0]
    let play = try #require(front.controlFrames["play"])
    let onPlay = host.convert(CGPoint(x: play.midX, y: play.midY), from: front)
    let hit = try #require(view.hitTest(onPlay))
    #expect(hit === front || hit.isDescendant(of: front))
    let title = try #require(front.controlFrames["title"])
    let onTitle = host.convert(CGPoint(x: title.midX, y: title.midY), from: front)
    let titleHit = try #require(view.hitTest(onTitle))
    #expect(titleHit === front || titleHit.isDescendant(of: front))
    let strip = host.convert(CGPoint(x: front.bounds.midX, y: -3), from: front)
    #expect(view.hitTest(strip) === view.cardViews[1])
    let back = host.convert(CGPoint(x: front.bounds.midX, y: -10), from: front)
    #expect(view.hitTest(back) === view.cardViews[2])
    let above = host.convert(CGPoint(x: front.bounds.midX, y: -40), from: front)
    #expect(view.hitTest(above) == nil)
  }

  @Test func survivingCardsKeepTheirPlaceWhenTheCountChanges() {
    let host = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 500))
    let view = stack(["a", "b", "c"])
    host.addSubview(view)
    let front = view.cardViews[0]
    let before = host.convert(front.bounds, from: front)
    view.update(["a", "b"].map(Self.state))
    #expect(host.convert(front.bounds, from: front) == before)
    view.update(["a"].map(Self.state))
    #expect(host.convert(front.bounds, from: front) == before)
    view.update(["d", "a"].map(Self.state))
    #expect(host.convert(front.bounds, from: front).maxY == before.maxY - 7)
  }

  @Test func theSubtitleShowsTheProfileAndEnded() {
    var state = Self.state("a")
    #expect(SidebarPlayerView.subtitleText(state) == "Artist")
    state.profileName = "Work"
    state.profileColor = "#E5484D"
    #expect(SidebarPlayerView.subtitleText(state) == "Work")
    state.playbackState = "paused"
    state.position = 120
    #expect(state.ended)
    #expect(SidebarPlayerView.subtitleText(state) == "Work · Ended")
    let view = SidebarPlayerView(frame: CGRect(x: 0, y: 0, width: 220, height: 74))
    view.update(state)
    #expect(view.profileDotShown)
    #expect(view.subtitleShown == "Work · Ended")
    state.profileColor = nil
    view.update(state)
    #expect(!view.profileDotShown)
  }

  @Test func thePictureInPictureButtonFollowsTheHolder() throws {
    let view = SidebarPlayerView(frame: CGRect(x: 0, y: 0, width: 220, height: 74))
    var actions: [MediaAction] = []
    view.onAction = { actions.append($0) }
    var state = Self.state("a")
    view.update(state)
    view.layoutSubtreeIfNeeded()
    #expect(view.controlFrames["pip"] == nil)
    let narrow = try #require(view.controlFrames["seek"])
    state.hasVideo = true
    view.update(state)
    view.layoutSubtreeIfNeeded()
    let pip = try #require(view.controlFrames["pip"])
    let seek = try #require(view.controlFrames["seek"])
    let close = try #require(view.controlFrames["close"])
    #expect(pip.size == CGSize(width: 20, height: 20))
    #expect(pip.minY == close.minY && close.minX - pip.maxX == 2)
    #expect(seek.width == narrow.width)
    let button = try #require(view.subviews.compactMap { $0 as? MediaCircleButton }.first { $0.frame == pip })
    #expect(button.toolTip == "Open in Picture in Picture")
    #expect(button.accessibilityPerformPress())
    state.holdsPictureInPicture = true
    view.update(state)
    #expect(button.toolTip == "Minimize Picture in Picture")
    #expect(SidebarPlayerView.subtitleText(state) == "Artist")
    #expect(button.accessibilityPerformPress())
    #expect(actions == [.enterPictureInPicture, .minimizePictureInPicture])
    #expect(MediaAction.enterPictureInPicture.name == "enterPictureInPicture")
    #expect(MediaAction.minimizePictureInPicture.name == "minimizePictureInPicture")
  }

  @Test func clickingAPeekingCardOpensTheStack() {
    let view = stack(["a", "b"])
    view.cardViews[1].onPeekPress?()
    #expect(view.isOpen)
  }
}
