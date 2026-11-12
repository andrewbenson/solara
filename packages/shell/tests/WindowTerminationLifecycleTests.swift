import XCTest
@testable import SolaraShellCore

final class WindowTerminationLifecycleTests: XCTestCase {
  func testUserCloseDispositionDoesNotDispatchUserCloseDuringTermination() {
    var lifecycle = WindowTerminationLifecycle()
    XCTAssertEqual(lifecycle.userCloseDisposition, .userRequest)
    lifecycle.begin()
    XCTAssertEqual(lifecycle.userCloseDisposition, .deferUntilSaved)
    lifecycle.approve()
    XCTAssertEqual(lifecycle.userCloseDisposition, .physicalTeardown)
    lifecycle.cancel()
    XCTAssertEqual(lifecycle.userCloseDisposition, .userRequest)
  }

  func testApprovedQuitRemainsTerminalThroughWindowTeardown() {
    var lifecycle = WindowTerminationLifecycle()
    var retention = LastWindowRetention()
    XCTAssertTrue(retention.retain("main", browserIds: ["main"], privateIds: [], smallIds: [], terminating: lifecycle.isTerminating))
    lifecycle.begin()
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: false, terminating: lifecycle.isTerminating, background: false))
    lifecycle.approve()
    XCTAssertFalse(lifecycle.awaitingReply)
    XCTAssertTrue(lifecycle.approved)
    XCTAssertTrue(lifecycle.isTerminating)
    XCTAssertFalse(retention.retain("main", browserIds: ["main"], privateIds: [], smallIds: [], terminating: lifecycle.isTerminating))
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: false, terminating: lifecycle.isTerminating, background: false))
    XCTAssertFalse(retention.shouldCreateWindow(hasVisibleBrowser: false, terminating: lifecycle.isTerminating))
    var keptOnClose = true
    XCTAssertTrue(retention.reveal("main"))
    if lifecycle.publishesWindowTeardown { keptOnClose = false }
    XCTAssertTrue(keptOnClose)
    XCTAssertTrue(lifecycle.approved)
  }

  func testImmediateTerminationWithoutAppEventsIsTerminalUntilCancellation() {
    var lifecycle = WindowTerminationLifecycle()
    var retention = LastWindowRetention()
    lifecycle.approve()
    XCTAssertTrue(lifecycle.isTerminating)
    XCTAssertFalse(lifecycle.publishesWindowTeardown)
    XCTAssertFalse(retention.retain("main", browserIds: ["main"], privateIds: [], smallIds: [], terminating: lifecycle.isTerminating))
    XCTAssertFalse(retention.shouldCreateWindow(hasVisibleBrowser: false, terminating: lifecycle.isTerminating))
    lifecycle.cancel()
    XCTAssertTrue(retention.shouldCreateWindow(hasVisibleBrowser: false, terminating: lifecycle.isTerminating))
  }

  func testChromeQuitCancellationRestoresReopenAndPublication() {
    var lifecycle = WindowTerminationLifecycle()
    var retention = LastWindowRetention()
    XCTAssertTrue(retention.retain("main", browserIds: ["main"], privateIds: [], smallIds: [], terminating: false))
    lifecycle.begin()
    lifecycle.approve()
    lifecycle.cancel()
    XCTAssertFalse(lifecycle.isTerminating)
    XCTAssertTrue(lifecycle.publishesWindowTeardown)
    XCTAssertTrue(retention.shouldReopen(hasVisibleBrowser: false, terminating: lifecycle.isTerminating, background: false))
  }

  func testAbortedSaveRestoresWindowLifecycleBeforeApproval() {
    var lifecycle = WindowTerminationLifecycle()
    lifecycle.begin()
    XCTAssertTrue(lifecycle.isTerminating)
    lifecycle.cancel()
    XCTAssertFalse(lifecycle.isTerminating)
    XCTAssertFalse(lifecycle.approved)
    XCTAssertTrue(lifecycle.publishesWindowTeardown)
  }
}
