import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingServiceTests: XCTestCase {
  func testOneOwnerSurvivesRegistrationOrderAndModuleRecreation() throws {
    let first = PairingCoordinatorTests.Rig()
    let replacement = PairingCoordinatorTests.Rig()
    let service = PairingServices()
    service.moduleAttached()
    service.register(first.coordinator)
    XCTAssertTrue(service.coordinator === first.coordinator)
    let handle = try first.coordinator.armTrusted()
    service.register(replacement.coordinator)
    XCTAssertTrue(service.coordinator === first.coordinator)
    service.moduleAttached()
    XCTAssertFalse(first.coordinator.snapshot.trusted)
    XCTAssertThrowsError(try first.coordinator.allow(handle))
    XCTAssertFalse(replacement.coordinator.snapshot.trusted)
  }

  func testEveryEntryReasonInvalidatesTheRegisteredOwnerSynchronously() throws {
    for reason in ["stop", "folder", "forget", "rekey"] {
      let rig = PairingCoordinatorTests.Rig()
      let service = PairingServices()
      service.register(rig.coordinator)
      _ = try rig.coordinator.armTrusted()
      service.invalidate(reason)
      XCTAssertFalse(rig.coordinator.snapshot.trusted, reason)
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    }
  }
}
