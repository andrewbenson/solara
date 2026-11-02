import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingServiceTests: XCTestCase {
  #if DEBUG
  func testBackendReadinessRequiresCoordinatorAndStoreCallbacksInEitherOrder() {
    for coordinatorFirst in [false, true] {
      let service = PairingServices()
      let rig = PairingCoordinatorTests.Rig()
      var sampledCallbacks = 0
      XCTAssertFalse(service.backendReady)
      let registerStore = {
        service.registerStore(healthy: { sampledCallbacks += 1; return false }, revision: { sampledCallbacks += 1; return nil }, projection: { _, _ in sampledCallbacks += 1; return [:] })
      }
      if coordinatorFirst { service.register(rig.coordinator) }
      else { registerStore() }
      XCTAssertFalse(service.backendReady)
      if coordinatorFirst { registerStore() }
      else { service.register(rig.coordinator) }
      XCTAssertTrue(service.backendReady)
      XCTAssertEqual(sampledCallbacks, 0)
    }
  }

  #endif

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
