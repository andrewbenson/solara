import AppKit
import QuartzCore
import Testing

@testable import SolaraUI

@MainActor
struct SwipeCapsuleTests {
  private let theme = SwipeCapsuleTheme(dark: false, textPrimary: "#000000D9", textSecondary: "#00000080")

  private func view(_ direction: SwipeCapsuleDirection = .back) -> SwipeCapsuleView {
    let v = SwipeCapsuleView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    v.show(direction, theme: theme, profileId: "default", now: 0)
    return v
  }

  private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
  }

  @Test func aNewSwipeStartsOffTheEdgeAtTheMiddle() {
    let s = view().sample(at: 0)
    #expect(near(s.frame, CGRect(x: -72, y: 264, width: 72, height: 72)))
    #expect(s.radius == 36 && s.opacity == 1 && s.iconScale == 1 && abs(s.iconOpacity - 0.5) < 0.001)
  }

  @Test func confirmingGrowsTheCapsuleAndIconOnTheirSprings() {
    let v = view()
    v.move(x: 14, now: 0.01)
    v.setConfirmed(true, now: 0.01)
    let mid = v.sample(at: 0.06)
    #expect(mid.frame.width > 72 && mid.frame.width < 82.5)
    let s = v.sample(at: 2)
    #expect(near(s.frame, CGRect(x: 14, y: 259, width: 82, height: 82)))
    #expect(abs(s.radius - 41) < 0.01 && abs(s.iconScale - 34.0 / 28) < 0.001 && abs(s.iconOpacity - 1) < 0.001)
  }

  @Test func theListReplacesTheCapsuleAndThePillFollowsTheSelection() {
    let v = view()
    v.setConfirmed(true, now: 0)
    v.move(x: 14, now: 0.4)
    v.presentList([SwipeCapsuleItem(title: "Two", url: "https://two.test"), SwipeCapsuleItem(title: "One", url: "https://one.test")], now: 0.4)
    var s = v.sample(at: 2)
    #expect(near(s.frame, CGRect(x: 14, y: 273, width: 200, height: 92)))
    #expect(abs(s.radius - 18) < 0.01 && s.list == 1 && s.iconOpacity == 0)
    v.select(1, now: 2)
    v.move(x: 14, nudge: 3, now: 2)
    s = v.sample(at: 4)
    #expect(abs(s.pill - 38) < 0.01 && abs(s.frame.minY - 276) < 0.01)
  }

  @Test func lateIconRefreshKeepsTheListSelectionAndMotion() {
    let v = view()
    v.setConfirmed(true, now: 0)
    v.presentList([SwipeCapsuleItem(title: "New Tab", url: "", newTab: true), SwipeCapsuleItem(title: "One", url: "https://one.test")], now: 0.4)
    v.select(1, now: 0.45)
    v.move(x: 14, nudge: 3, now: 0.45)
    let before = v.sample(at: 0.5)
    v.rebuildIcons(now: 0.5)
    #expect(v.sample(at: 0.5) == before)
    #expect(v.selected == 1 && v.items?.first?.newTab == true && v.confirmed)
  }

  @Test func aForwardSwipeComesInFromTheRight() {
    let v = view(.forward)
    v.move(x: 20, now: 0)
    #expect(near(v.sample(at: 0).frame, CGRect(x: 800 - 20 - 72, y: 264, width: 72, height: 72)))
  }

  @Test func dismissFadesAndShrinksAfterItsDelay() {
    let v = view()
    v.dismiss(delay: 0.12, now: 1)
    #expect(v.sample(at: 1.1).opacity == 1)
    let mid = v.sample(at: 1.22)
    #expect(mid.opacity < 1 && mid.opacity > 0 && mid.scale < 1)
    let end = v.sample(at: 1.33)
    #expect(end.opacity == 0 && abs(end.scale - 0.01) < 0.0001)
    #expect(!v.active)
  }

  @Test func displayFramesKeepTheirOriginalFadeAndCompletion() throws {
    let v = view()
    var dismissals = 0
    v.onDismissed = { dismissals += 1 }
    v.move(x: 14, now: 1)
    v.dismiss(delay: 0.12, now: 1)
    let box = try #require(v.subviews.first)
    let layer = try #require(box.layer)
    let frames: [(Double, Double, Double)] = [
      (1.1, 1, 1),
      (1.12, 1, 1),
      (1.17, 0.906535349281, 0.907469995788),
      (1.22, 0.684643187427, 0.687796755553),
      (1.27, 0.378138130825, 0.384356749517)
    ]
    for (time, opacity, scale) in frames {
      v.tick(at: time)
      let sample = v.sample(at: time)
      #expect(sample.frame == CGRect(x: 14, y: 264, width: 72, height: 72))
      #expect(sample.radius == 36 && sample.iconScale == 1 && sample.iconOpacity == 0.5 && sample.list == 0 && sample.pill == 0)
      #expect(abs(sample.opacity - opacity) < 0.000000001)
      #expect(abs(sample.scale - scale) < 0.000000001)
      #expect(box.frame == sample.frame && layer.opacity == Float(sample.opacity))
      #expect(CATransform3DEqualToTransform(layer.sublayerTransform, PrimitiveMotion.scale(about: CGPoint(x: 36, y: 36), scale: sample.scale)))
      #expect(v.shown && !v.active && dismissals == 0)
    }
    let deadline = (1.0 + 0.12 + SwipeCapsuleMetrics.dismissDuration).nextUp
    v.tick(at: deadline)
    #expect(!v.shown && dismissals == 1)
    #expect(layer.opacity == 0 && v.sample(at: deadline).scale == 0.01)
    v.tick(at: 2)
    v.finishDismissal(at: 2)
    #expect(dismissals == 1)
  }

  @Test func dismissFinishesWithoutDisplayFrames() async throws {
    let v = view()
    var completions: [CFTimeInterval] = []
    let now = CACurrentMediaTime()
    let deadline = (now + 0.12 + SwipeCapsuleMetrics.dismissDuration).nextUp
    v.onDismissed = { completions.append(CACurrentMediaTime()) }
    v.dismiss(delay: 0.12, now: now)
    v.viewDidMoveToWindow()
    #expect(v.shown && completions.isEmpty)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(!v.shown && !v.active && completions.count == 1)
    #expect(completions.first.map { $0 >= deadline } == true)
    #expect(v.sample().opacity == 0)
  }

  @Test func dismissalCompletionWaitsForTheFadeAndRunsOnce() {
    let v = view()
    var dismissals = 0
    v.onDismissed = { dismissals += 1 }
    v.dismiss(delay: 0.12, now: 1)
    let roundedDeadline = 1.0 + 0.12 + SwipeCapsuleMetrics.dismissDuration
    v.finishDismissal(at: roundedDeadline)
    #expect(v.shown && dismissals == 0)
    v.finishDismissal(at: roundedDeadline.nextUp)
    v.finishDismissal(at: 2)
    #expect(!v.shown && dismissals == 1)
  }

  @Test func aNewSwipeCancelsThePreviousDismissal() async throws {
    let v = view()
    var dismissals = 0
    v.onDismissed = { dismissals += 1 }
    v.dismiss()
    v.show(.forward, theme: theme, profileId: "default")
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(v.shown && v.active && v.direction == .forward && dismissals == 0)
  }

  @Test func aDismissalCallbackCanImmediatelyShowAndDismissANewSwipe() async throws {
    let v = view()
    var dismissals = 0
    v.onDismissed = {
      dismissals += 1
      if dismissals == 1 {
        v.show(.forward, theme: theme, profileId: "default")
        v.dismiss(delay: 0.12)
      }
    }
    v.dismiss(now: 1)
    v.tick(at: 1.21)
    #expect(v.shown && !v.active && v.direction == .forward && dismissals == 1)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(!v.shown && dismissals == 2)
    v.tick(at: CACurrentMediaTime())
    #expect(dismissals == 2)
  }

  @Test func aReplacementDismissalUsesItsOwnDeadline() {
    let v = view()
    var dismissals = 0
    v.onDismissed = { dismissals += 1 }
    v.dismiss(now: 1)
    v.dismiss(delay: 0.4, now: 1.1)
    v.finishDismissal(at: 1.3)
    #expect(v.shown && dismissals == 0)
    v.finishDismissal(at: 1.71)
    #expect(!v.shown && dismissals == 1)
  }
}
