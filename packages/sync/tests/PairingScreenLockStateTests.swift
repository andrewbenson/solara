import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingScreenLockStateTests: XCTestCase {
  func testMissingSessionIsUnknown() {
    XCTAssertEqual(PairingScreenLockState.from(session: nil), .unknown)
  }

  func testMissingConsoleFlagIsLocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: [:]), .locked)
  }

  func testBackgroundSessionIsLockedEvenWithExplicitUnlockedFlag() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": false, "CGSSessionScreenIsLocked": false]), .locked)
  }

  func testInvalidConsoleFlagIsLocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": "true", "CGSSessionScreenIsLocked": false]), .locked)
  }

  func testNonBooleanNumberConsoleFlagIsLocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: 2), "CGSSessionScreenIsLocked": false]), .locked)
  }

  func testOnConsoleWithTrueLockFlagIsLocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true]), .locked)
  }

  func testOnConsoleWithNumericOneLockFlagIsLocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": NSNumber(value: 1)]), .locked)
  }

  func testOnConsoleWithFalseLockFlagIsUnlocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": false]), .unlocked)
  }

  func testOnConsoleWithNumericZeroLockFlagIsUnlocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": NSNumber(value: 0)]), .unlocked)
  }

  func testOnConsoleWithMissingLockFlagIsUnlocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true]), .unlocked)
  }

  func testNumericOneConsoleFlagWithMissingLockFlagIsUnlocked() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: 1)]), .unlocked)
  }

  func testOnConsoleWithStringLockFlagIsUnknown() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": "false"]), .unknown)
  }

  func testOnConsoleWithNullLockFlagIsUnknown() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": NSNull()]), .unknown)
  }

  func testOnConsoleWithNonBooleanNumberLockFlagIsUnknown() {
    XCTAssertEqual(PairingScreenLockState.from(session: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": NSNumber(value: 2)]), .unknown)
  }
}
