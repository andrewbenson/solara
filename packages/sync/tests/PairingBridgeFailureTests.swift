import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingBridgeFailureTests: XCTestCase {
  func testNativeFailuresDiscardRecursiveUnderlyingUserInfo() throws {
    let secret = "Fixture Private Mac ΑBC DEF"
    let original = NSError(domain: secret, code: 71, userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: NSError(domain: "nested", code: 1, userInfo: ["value": ["name": secret]])])
    do {
      try PairingBridgeFailure.perform { throw original }
      XCTFail("expected refusal")
    } catch {
      let value = error as NSError
      XCTAssertEqual(value.domain, "SolaraPairing")
      XCTAssertEqual(value.code, 1)
      XCTAssertTrue(value.userInfo.isEmpty)
      for encoded in [secret, Data(secret.utf8).base64EncodedString(), secret.utf8.map { String(format: "%02x", $0) }.joined(), secret.precomposedStringWithCanonicalMapping] {
        XCTAssertFalse(String(reflecting: error).contains(encoded))
        XCTAssertFalse(String(describing: error).contains(encoded))
      }
    }
  }
}
