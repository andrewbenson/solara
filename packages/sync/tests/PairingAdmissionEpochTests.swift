import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingAdmissionEpochTests: XCTestCase {
  func testInvalidationCannotReturnBetweenFinalCheckAndLogicalCommit() {
    let epoch = PairingAdmissionEpoch(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), invalidated = DispatchSemaphore(value: 0)
    let expected = epoch.current
    DispatchQueue.global().async {
      XCTAssertTrue(epoch.admit(expected) {
        entered.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        return true
      })
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    DispatchQueue.global().async { epoch.advance(); invalidated.signal() }
    let result = invalidated.wait(timeout: .now() + 0.2)
    XCTAssertEqual(result, .timedOut)
    release.signal()
    if result == .timedOut { XCTAssertEqual(invalidated.wait(timeout: .now() + 3), .success) }
    XCTAssertFalse(epoch.admit(expected) { XCTFail("stale gate body"); return true })
  }
}
