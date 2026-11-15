import XCTest
@testable import SolaraShellCore

@MainActor
final class LaunchAdmissionTests: XCTestCase {
  func testLateRegistrationAndCancellation() {
    LaunchAdmission.setAdmitted(false)
    var first: [Bool] = []
    let token = LaunchAdmission.observe { first.append($0) }
    LaunchAdmission.setAdmitted(true)
    LaunchAdmission.setAdmitted(true)
    var late: [Bool] = []
    let other = LaunchAdmission.observe { late.append($0) }
    LaunchAdmission.cancel(token)
    LaunchAdmission.setAdmitted(false)
    LaunchAdmission.cancel(other)
    XCTAssertEqual(first, [false, true])
    XCTAssertEqual(late, [true, false])
  }

  func testCallbackCanCancelAndRegisterWithoutMutatingDelivery() {
    LaunchAdmission.setAdmitted(false)
    var token: UUID?
    var late: UUID?
    var calls = 0
    token = LaunchAdmission.observe { admitted in
      guard admitted else { return }
      calls += 1
      if let token { LaunchAdmission.cancel(token) }
      late = LaunchAdmission.observe { if $0 { calls += 1 } }
    }
    LaunchAdmission.setAdmitted(true)
    LaunchAdmission.setAdmitted(false)
    if let late { LaunchAdmission.cancel(late) }
    XCTAssertEqual(calls, 2)
  }

  func testCancellingNamedWorkCompletesItsPendingAdmission() {
    LaunchAdmission.schedule = nil
    var results: [Bool] = []
    LaunchAdmission.whenIdle("cancelled") { results.append($0) }
    LaunchAdmission.cancelWork("cancelled")
    XCTAssertEqual(results, [false])
  }

  func testWorkRegisteredBeforeSchedulerInstallationIsRetained() {
    LaunchAdmission.schedule = nil
    var results: [Bool] = []
    LaunchAdmission.whenIdle("early") { results.append($0) }
    XCTAssertTrue(results.isEmpty)
    var admitted: [(Bool) -> Void] = []
    LaunchAdmission.schedule = { _, action in admitted.append(action) }
    XCTAssertEqual(admitted.count, 1)
    admitted[0](true)
    XCTAssertEqual(results, [true])
    LaunchAdmission.schedule = nil
  }

  func testChromeEpochIsFirstFiniteActualCommit() {
    XCTAssertNil(LaunchAdmission.chromeCommittedAt)
    LaunchAdmission.recordChromeCommit(.nan)
    XCTAssertNil(LaunchAdmission.chromeCommittedAt)
    LaunchAdmission.recordChromeCommit(1234)
    LaunchAdmission.recordChromeCommit(5678)
    XCTAssertEqual(LaunchAdmission.chromeCommittedAt, 1234)
  }
}
