import AppKit
import Testing

@testable import SolaraUI

@Suite struct PrimitivesCardReachTests {
  let leftTileCard = CGRect(x: 69, y: 48, width: 264, height: 152)

  @Test func pointOnCardIsCovered() {
    #expect(CardReach.of(card: leftTileCard, from: CGPoint(x: 40, y: 96), to: CGPoint(x: 128, y: 74)) == .covered)
    #expect(CardReach.of(card: leftTileCard, from: nil, to: CGPoint(x: 100, y: 140)) == .covered)
  }

  @Test func leavingTowardCardKeepsAiming() {
    let exit = CGPoint(x: 45, y: 96)
    #expect(CardReach.of(card: leftTileCard, from: exit, to: CGPoint(x: 55, y: 104)) == .aiming)
    #expect(CardReach.of(card: leftTileCard, from: exit, to: CGPoint(x: 66, y: 125)) == .aiming)
  }

  @Test func headingAwayIsNotAiming() {
    let exit = CGPoint(x: 45, y: 96)
    #expect(CardReach.of(card: leftTileCard, from: exit, to: CGPoint(x: 30, y: 110)) == .away)
    #expect(CardReach.of(card: leftTileCard, from: exit, to: CGPoint(x: 47, y: 260)) == .away)
    #expect(CardReach.of(card: leftTileCard, from: nil, to: CGPoint(x: 55, y: 104)) == .away)
  }

  @Test func leftSideCardAimedLeftward() {
    let card = CGRect(x: 10, y: 100, width: 100, height: 80)
    #expect(CardReach.of(card: card, from: CGPoint(x: 150, y: 140), to: CGPoint(x: 130, y: 145)) == .aiming)
    #expect(CardReach.of(card: card, from: CGPoint(x: 150, y: 140), to: CGPoint(x: 170, y: 140)) == .away)
  }
}

@Suite struct PrimitivesMotionTests {
  @Test func hoverCardNumbersMatchRN() {
    #expect(HoverIntent.showDelay == 0.5)
    #expect(HoverIntent.hideDelay == 0.16)
    #expect(HoverIntent.aimDelay == 0.2)
    #expect(HoverCardMotion.fromScale == 0.92)
    #expect(HoverCardMotion.fadeDuration == 0.1)
    #expect(HoverCardMotion.origin(anchor: CGRect(x: 10, y: 40, width: 200, height: 30)) == CGPoint(x: 218, y: 34))
    #expect(HoverCardMotion.origin(anchor: CGRect(x: 10, y: 2, width: 200, height: 30), edge: 250) == CGPoint(x: 258, y: 8))
  }

  @Test func bezierMatchesCSSEndpointsAndMidpoint() {
    let curve = HoverCardMotion.fadeCurve
    #expect(abs(curve(0)) < 1e-6)
    #expect(abs(curve(1) - 1) < 1e-6)
    #expect(abs(curve(0.5) - 0.77132) < 0.0005)
  }

  @Test func springTrackSettlesOnTarget() {
    let track = SpringTrack(HoverCardMotion.inSpring, from: 0.92, to: 1, start: 0)
    #expect(track.duration > 0.2 && track.duration < 1)
    #expect(abs(track.value(at: track.duration) - 1) < 0.001)
    #expect(abs(track.value(at: 0) - 0.92) < 1e-9)
  }

  @Test func popoverNumbersMatchRN() {
    #expect(PopoverMetrics.open.duration == 0.15)
    #expect(PopoverMetrics.close.duration == 0.1)
    #expect(PopoverMetrics.fromScale == 0.94)
    #expect(PopoverMetrics.margin == 8)
  }
}

@MainActor @Suite struct PrimitivesHoverIntentTests {
  @Test func firstShowWaitsThenSwitchesAtOnce() throws {
    let intent = HoverIntent()
    var shown: [String] = []
    intent.onShow = { shown.append($0) }
    intent.enter("a")
    #expect(shown.isEmpty)
    try #require(intent.showTimer).fire()
    #expect(shown == ["a"])
    intent.enter("b")
    #expect(shown == ["a", "b"])
  }

  @Test func leaveHidesAfterDelayUnlessCardKeeps() throws {
    let intent = HoverIntent()
    var hidden = 0
    intent.onHide = { hidden += 1 }
    intent.enter("a")
    try #require(intent.showTimer).fire()
    #expect(intent.shown == "a")
    intent.leave(from: "a")
    let canceledHide = try #require(intent.hideTimer)
    #expect(canceledHide.isValid)
    intent.cardEntered()
    #expect(!canceledHide.isValid)
    #expect(hidden == 0)
    intent.cardLeft()
    let nextHide = try #require(intent.hideTimer)
    #expect(nextHide.isValid)
    #expect(hidden == 0)
    nextHide.fire()
    #expect(hidden == 1)
    #expect(intent.shown == nil)
  }
}

@MainActor @Suite struct PrimitivesHoverCardTests {
  @Test func cardSitsAtOriginAndTakesClicksOnlyOnceShown() async throws {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let card = HoverCardView(frame: host.bounds)
    host.addSubview(card)
    card.layoutSubtreeIfNeeded()
    let body = NSView(frame: NSRect(x: 0, y: 0, width: 264, height: 152))
    let button = NSButton(frame: NSRect(x: 10, y: 10, width: 60, height: 24))
    body.addSubview(button)
    let origin = HoverCardMotion.origin(anchor: CGRect(x: 10, y: 54, width: 59, height: 40))
    card.show(body, origin: origin)
    #expect(body.frame.origin == origin)
    #expect(card.phase == .entering)
    #expect(card.hitTest(NSPoint(x: origin.x + 20, y: origin.y + 20)) == nil)
    await LiveSettingsWait.until { card.phase == .shown }
    #expect(card.phase == .shown)
    let inButton = card.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), from: body)
    #expect(card.hitTest(host.convert(inButton, from: card)) === button)
    #expect(card.hitTest(NSPoint(x: 5, y: 5)) == nil)
    var hidden = false
    card.onHidden = { hidden = true }
    card.hide()
    #expect(card.hitTest(host.convert(inButton, from: card)) == nil)
    await LiveSettingsWait.until { hidden && card.content == nil && card.phase == .hidden }
    #expect(hidden && card.content == nil && card.phase == .hidden)
  }
}

@MainActor @Suite struct PrimitivesPopoverTests {
  final class SizingBody: NSView {
    weak var popover: PopoverView?
    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      popover?.set(bodyHeight: 120)
    }
  }

  @Test func heightReportedFromInsideLayoutStillApplies() async throws {
    let body = SizingBody()
    let popover = PopoverView(body: body)
    body.popover = popover
    popover.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    popover.set(placement: PopoverPlacement(width: 300, top: 8, right: 8), dark: false)
    popover.layoutSubtreeIfNeeded()
    await LiveSettingsWait.until {
      popover.layoutSubtreeIfNeeded()
      return popover.cardFrame.height == 121
    }
    #expect(popover.cardFrame.height == 121)
  }
}
