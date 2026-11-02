import XCTest
@testable import SolaraShellCore

final class NotificationAdapterModeTests: XCTestCase {
  func testBackgroundUsesMemory() {
    XCTAssertEqual(NotificationAdapterMode.choose(environment: ["SOLARA_BACKGROUND": "1"], debug: true), .memory)
  }

  func testDebugOverrideUsesSystemInBackground() {
    XCTAssertEqual(
      NotificationAdapterMode.choose(environment: ["SOLARA_BACKGROUND": "1", "SOLARA_NOTIFICATIONS_SYSTEM": "1"], debug: true),
      .system)
  }

  func testReleaseIgnoresOverrideInBackground() {
    XCTAssertEqual(
      NotificationAdapterMode.choose(environment: ["SOLARA_BACKGROUND": "1", "SOLARA_NOTIFICATIONS_SYSTEM": "1"], debug: false),
      .memory)
  }

  func testForegroundUsesSystem() {
    XCTAssertEqual(NotificationAdapterMode.choose(environment: [:], debug: true), .system)
    XCTAssertEqual(NotificationAdapterMode.choose(environment: [:], debug: false), .system)
  }
}
