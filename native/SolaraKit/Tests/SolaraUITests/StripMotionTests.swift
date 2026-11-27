import AppKit
import SolaraStore
import Testing

@testable import SolaraUI

private func run(_ value: inout StripSpringValue, from start: Double, to end: Double) -> [Double] {
  var out: [Double] = []
  var t = start
  while t <= end {
    value.step(now: t)
    out.append(value.value)
    t += 1.0 / 60
  }
  return out
}

private func group(collapsed: Bool, width: CGFloat, shown: Int?) -> StripPlacedGroup {
  let members = ["a", "b"].map { StripMember(kind: .tab, id: $0, tabIds: [$0], group: "g") }
  return StripPlacedGroup(
    entry: StripGroupEntry(id: "g", collapsed: collapsed, members: members), chip: 60, width: width,
    members: members.enumerated().map { StripPlacedMember(member: $1, width: 100, offset: CGFloat($0) * 104, shown: $0 == shown) }, shown: shown)
}

@Suite @MainActor struct StripMotionTests {
  @Test func aSurfaceChangeKeepsTheInFlightPositionForTheSameOrder() {
    #expect(ProfilePagerSelection.retainedPosition(0.6, previous: ["p", "q"], next: ["p", "q"], selectionChanged: true) == 0.6)
    #expect(ProfilePagerSelection.retainedPosition(0.6, previous: ["p", "q"], next: ["q", "p"], selectionChanged: true) == nil)
    #expect(ProfilePagerSelection.retainedPosition(0, previous: ["p", "q"], next: ["p", "q"], selectionChanged: true) == nil)
  }

  @Test func theGroupSpringOvershootsALittleAndSettlesOnItsTarget() {
    var value = StripSpringValue(0)
    value.animate(to: 1, .group)
    let frames = run(&value, from: 0, to: 2)
    #expect(frames.max()! > 1.005)
    #expect(frames.max()! < 1.03)
    #expect(value.value == 1)
    #expect(!value.running)
  }

  @Test func aSpringRetargetedMidFlightKeepsItsVelocity() {
    var value = StripSpringValue(0)
    value.animate(to: 100, .group)
    _ = run(&value, from: 0, to: 0.05)
    let before = value.value
    value.animate(to: 0, .group)
    value.step(now: 0.05)
    #expect(value.value == before)
    value.step(now: 0.05 + 1.0 / 60)
    #expect(value.value > before)
  }

  @Test func aLongFrameAdvancesTheSpringBy64msAtMost() {
    var a = StripSpringValue(0)
    a.animate(to: 1, .group)
    a.step(now: 0)
    a.step(now: 1)
    var b = StripSpringValue(0)
    b.animate(to: 1, .group)
    b.step(now: 0)
    b.step(now: 0.064)
    #expect(a.value == b.value)
  }

  @Test func aGroupSpringsOnlyWhenItOpensClosesOrShowsAnotherMember() {
    let motion = StripGroupMotion(expanded: true, width: 300, state: StripGroupMotion.state(group(collapsed: false, width: 300, shown: nil)))
    motion.retarget(group(collapsed: false, width: 320, shown: nil))
    #expect(motion.size.value == 320)
    #expect(!motion.moving)
    motion.retarget(group(collapsed: true, width: 80, shown: nil))
    #expect(motion.moving)
    #expect(motion.open.target == 0)
    #expect(motion.size.target == 80)
  }

  @Test func aTuckedMemberFadesOutOver120msEasingOut() {
    let motion = StripGroupMotion(expanded: false, width: 180, state: StripGroupMotion.state(group(collapsed: true, width: 180, shown: 0)))
    motion.retarget(group(collapsed: true, width: 180, shown: 0))
    #expect(motion.shown["a"] == 1)
    motion.retarget(group(collapsed: true, width: 180, shown: 1))
    motion.step(now: 0)
    motion.step(now: 0.06)
    #expect(abs(Double(motion.shown["a"]!) - 0.25) < 0.0001)
    motion.step(now: 0.12)
    #expect(motion.shown["a"] == 0)
    #expect(motion.shown["b"] == 1)
  }

  @Test func aBandEasesInFromClearOver180ms() {
    var band = StripEasedColor(nil)
    band.retarget(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), duration: 0.18)
    band.step(now: 0)
    #expect(band.value.alphaComponent == 0)
    band.step(now: 0.09)
    #expect(abs(band.value.alphaComponent - 0.75) < 0.0001)
    band.step(now: 0.18)
    #expect(band.value.alphaComponent == 1)
    #expect(!band.running)
  }
}
