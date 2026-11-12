import XCTest
@testable import SolaraShellCore

final class LastWindowRetentionTests: XCTestCase {
  var retention = LastWindowRetention()

  func retain(_ id: String = "main", ids: Set<String> = ["main"], privateIds: Set<String> = [], smallIds: Set<String> = [], terminating: Bool = false) -> Bool {
    retention.retain(id, browserIds: ids, privateIds: privateIds, smallIds: smallIds, terminating: terminating)
  }

  func testOnlyLastRegularWindowIsRetained() {
    XCTAssertFalse(retain(ids: ["main", "second"]))
    XCTAssertTrue(retain())
    XCTAssertEqual(retention.id, "main")
  }

  func testPrivateAndLittleWindowsAreDestroyed() {
    XCTAssertFalse(retain(privateIds: ["main"]))
    XCTAssertFalse(retain(smallIds: ["main"]))
    XCTAssertNil(retention.id)
  }

  func testPendingRegularWindowsPreventRetention() {
    XCTAssertFalse(retain(ids: ["main", "pending"]))
  }

  func testPrivateAndLittleWindowsDoNotPreventRetainingSoleRegularWindow() {
    XCTAssertTrue(retain(ids: ["main", "private", "little"], privateIds: ["private"], smallIds: ["little"]))
  }

  func testAuxiliaryWindowsDoNotCountAndUnknownWindowsCannotBeRetained() {
    XCTAssertFalse(retain("settings"))
    XCTAssertTrue(retain())
  }

  func testRepeatedCloseKeepsSameWindowAndNewWindowDoesNotReplaceIt() {
    XCTAssertTrue(retain())
    XCTAssertTrue(retain(ids: ["main", "new"]))
    XCTAssertFalse(retain("new", ids: ["main", "new"]))
    XCTAssertEqual(retention.id, "main")
  }

  func testDockAndReactivationRestoreOnlyWhenNoBrowserIsVisible() {
    XCTAssertTrue(retain())
    XCTAssertTrue(retention.shouldReopen(hasVisibleBrowser: false, terminating: false, background: false))
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: true, terminating: false, background: false))
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: false, terminating: false, background: true))
    XCTAssertTrue(retention.reveal("main"))
    XCTAssertNil(retention.id)
    XCTAssertFalse(retention.reveal("main"))
  }

  func testCommittedCloseDoesNotPreventRetainingTheOtherWindow() {
    XCTAssertTrue(retention.retain("second", browserIds: ["first", "second"], privateIds: [], smallIds: [], closingIds: ["first"], terminating: false))
    XCTAssertEqual(retention.id, "second")
  }

  func testRepeatedCommittedCloseCannotBecomeRetained() {
    XCTAssertFalse(retention.retain("first", browserIds: ["first"], privateIds: [], smallIds: [], closingIds: ["first"], terminating: false))
    XCTAssertNil(retention.id)
  }

  func testCancelledCloseCountsAsAnOpenWindowAgain() {
    XCTAssertFalse(retention.retain("second", browserIds: ["first", "second"], privateIds: [], smallIds: [], closingIds: [], terminating: false))
  }

  func testQuitAndSparkleRelaunchCannotRetainOrRevealWindows() {
    XCTAssertFalse(retain(terminating: true))
    XCTAssertTrue(retain())
    XCTAssertFalse(retain(terminating: true))
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: false, terminating: true, background: false))
    XCTAssertEqual(retention.id, "main")
  }

  func assertActivationAndDockOrder(_ callbacks: [String], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(retain(), file: file, line: line)
    var visible = false
    var revealed = 0
    var created = 0
    for callback in callbacks {
      if retention.shouldReopen(hasVisibleBrowser: visible, terminating: false, background: false) {
        XCTAssertTrue(retention.reveal("main"), file: file, line: line)
        visible = true
        revealed += 1
      } else if callback == "dock", retention.shouldCreateWindow(hasVisibleBrowser: visible, terminating: false) {
        created += 1
      }
    }
    XCTAssertEqual(revealed, 1, file: file, line: line)
    XCTAssertEqual(created, 0, file: file, line: line)
  }

  func testActivationBeforeDockWithStaleVisibilityDoesNotCreateAnotherWindow() {
    assertActivationAndDockOrder(["activation", "dock"])
  }

  func testDockBeforeActivationDoesNotCreateAnotherWindow() {
    assertActivationAndDockOrder(["dock", "activation"])
  }

  func testBackgroundDockCannotCreateDuplicateOfHiddenWindow() {
    XCTAssertTrue(retain())
    XCTAssertFalse(retention.shouldReopen(hasVisibleBrowser: false, terminating: false, background: true))
    XCTAssertFalse(retention.shouldCreateWindow(hasVisibleBrowser: false, terminating: false))
  }

  func testDestroyingAnotherWindowDoesNotRevealRetainedWindow() {
    XCTAssertTrue(retain())
    XCTAssertFalse(retention.reveal("other"))
    XCTAssertEqual(retention.id, "main")
  }
}
