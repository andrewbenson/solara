import XCTest
@testable import SolaraShellCore

final class TabNumberHintHoldTests: XCTestCase {
  func testCommandAloneShowsOnlyAfterDelay() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 10)
    let generation = hold.generation
    XCTAssertEqual(hold.deadline, 11)
    XCTAssertFalse(hold.expire(generation: generation, now: 10.999))
    XCTAssertTrue(hold.expire(generation: generation, now: 11))
    XCTAssertTrue(hold.visible)
  }

  func testOtherKeyCancelsTheWholeHold() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 0)
    let generation = hold.generation
    hold.interrupt()
    XCTAssertFalse(hold.expire(generation: generation, now: 2))
    hold.modifiers(command: true, alone: true, now: 3)
    XCTAssertNil(hold.deadline)
    hold.modifiers(command: false, alone: false, now: 4)
    hold.modifiers(command: true, alone: true, now: 5)
    XCTAssertEqual(hold.deadline, 6)
  }

  func testReleaseHidesAndRejectsOldTimer() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 0)
    let generation = hold.generation
    XCTAssertTrue(hold.expire(generation: generation, now: 1))
    hold.modifiers(command: false, alone: false, now: 2)
    XCTAssertFalse(hold.visible)
    hold.modifiers(command: true, alone: true, now: 3)
    XCTAssertFalse(hold.expire(generation: generation, now: 5))
    XCTAssertFalse(hold.visible)
  }

  func testDeactivationHides() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 0)
    XCTAssertTrue(hold.expire(generation: hold.generation, now: 1))
    hold.interrupt()
    XCTAssertFalse(hold.visible)
    XCTAssertNil(hold.deadline)
  }

  func testAnotherModifierDoesNotRearmWhenReleased() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 0)
    hold.modifiers(command: true, alone: false, now: 0.5)
    hold.modifiers(command: true, alone: true, now: 0.8)
    XCTAssertNil(hold.deadline)
    XCTAssertFalse(hold.visible)
  }

  func testCommandPressedWithAnotherKeyHeldDoesNotArm() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: false, now: 0)
    hold.modifiers(command: true, alone: true, now: 2)
    XCTAssertNil(hold.deadline)
  }

  func testCancellationBeforeDeadlineRejectsLateCallback() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: true, now: 0)
    let generation = hold.generation
    hold.interrupt()
    XCTAssertFalse(hold.expire(generation: generation, now: 1))
    XCTAssertNil(hold.deadline)
    XCTAssertFalse(hold.visible)
  }

  func testFocusReconciliationDoesNotRearmAnExistingCommandHold() {
    var hold = TabNumberHintHold()
    hold.modifiers(command: true, alone: false, now: 0)
    hold.modifiers(command: true, alone: true, now: 2)
    XCTAssertNil(hold.deadline)
    hold.modifiers(command: false, alone: false, now: 3)
    hold.modifiers(command: true, alone: true, now: 4)
    XCTAssertEqual(hold.deadline, 5)
  }

  func testTypingBeforeCommandDoesNotBlockNextHold() {
    var hold = TabNumberHintHold()
    hold.interrupt()
    hold.modifiers(command: true, alone: true, now: 0)
    XCTAssertEqual(hold.deadline, 1)
  }
}
