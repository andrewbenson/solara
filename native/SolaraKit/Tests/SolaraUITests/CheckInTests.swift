import Foundation
import Testing
@testable import SolaraUI

struct CheckInTests {
  @Test func introAndExitMatchReactNativeCurves() {
    var motion = CheckInMotion(at: 0)
    motion.step(at: 0.3)
    #expect(motion.opacity == 0)
    motion.step(at: 0.45)
    #expect(abs(motion.opacity - 0.75) < 0.00001)
    motion.step(at: 0.6)
    #expect(motion.opacity == 1)
    motion.leave(at: 1)
    motion.step(at: 1.11)
    #expect(abs(motion.opacity - 0.25) < 0.00001)
    #expect(abs(motion.scale - 0.985) < 0.00001)
    #expect(!motion.finished)
    motion.step(at: 1.221)
    #expect(motion.opacity < 0.00001)
    #expect(abs(motion.scale - 0.98) < 0.00001)
    #expect(motion.finished)
  }

  @Test func hoverAndPressUseTheOriginalSpringAndExitRejectsRetargeting() {
    var motion = CheckInMotion(at: 0)
    motion.step(at: 1)
    motion.target(hovered: true, pressed: false, at: 1)
    var expected = RNSpring(SpringParams(response: 0.2, dampingRatio: 0.5), from: 1, to: 1.02)
    _ = expected.step(at: 1)
    for frame in 1...12 {
      let time = 1 + Double(frame) / 60
      motion.step(at: time)
      #expect(abs(motion.scale - expected.step(at: time)) < 0.000001)
    }
    motion.target(hovered: true, pressed: true, at: 1.2)
    for frame in 1...60 { motion.step(at: 1.2 + Double(frame) / 60) }
    #expect(abs(motion.scale - 0.98) < 0.000001)
    motion.leave(at: 2.3)
    motion.target(hovered: true, pressed: false, at: 2.31)
    motion.step(at: 2.6)
    #expect(motion.finished && motion.leaving)
    #expect(abs(motion.scale - 0.98) < 0.000001)
  }

  @Test func invalidStateCannotExposeAProfilelessBanner() {
    #expect(CheckInBannerState.decode("invalid") == nil)
    #expect(CheckInBannerState.decode(##"{"visible":true,"dark":false,"title":"title","action":"action","profileId":"","token":"1","icon":""}"##) == nil)
    let valid = CheckInBannerState.decode(##"{"visible":true,"dark":false,"title":"title","action":"action","profileId":"profile","token":"1","icon":""}"##)
    #expect(valid?.profileId == "profile")
  }
}
