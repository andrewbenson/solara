import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingDeferredCancellationTests: XCTestCase {
  func testCancelledQueuedReplacementPreservesUnavailablePredecessorAndBlocksAdmission() throws {
    let helper = PairingCoordinatorTests()
    let rig = PairingCoordinatorTests.Rig()
    let inserted = expectation(description: "predecessor key insertion held")
    let cancelling = expectation(description: "predecessor cancellation held")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { inserted.fulfill() }
    let original = try helper.receivedApproval(rig).0
    wait(for: [inserted], timeout: 3)
    rig.store.holdCancellation = true
    rig.store.failDecision = true
    rig.store.cancellationReached = { cancelling.fulfill() }
    let service = PairingServices()
    service.register(rig.coordinator)
    var priorStates: [PairingJoinState] = []
    let prior = service.start(cid: rig.mailbox.pairingCID) { priorStates.append($0) }
    wait(for: [cancelling], timeout: 3)
    let latest = service.start(cid: rig.mailbox.pairingCID) { _ in }
    XCTAssertEqual(latest.cancel(), .cancelled)
    rig.store.holdCancellation = false
    rig.store.cancellationRelease.signal()
    rig.keys.insertRelease.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(original.cancel(), .unavailable)
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    XCTAssertFalse(priorStates.contains { if case .waiting = $0 { return true }; return false })
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertTrue(rig.store.admitted.isEmpty)
    XCTAssertTrue(rig.host.saved.isEmpty)
    var blockedStates: [PairingJoinState] = []
    let blocked = service.start(cid: rig.mailbox.pairingCID) { blockedStates.append($0) }
    try helper.wait { blockedStates.contains(.failed(.folderUnavailable)) }
    XCTAssertFalse(blockedStates.contains { if case .waiting = $0 { return true }; return false })
    XCTAssertEqual(original.cancel(), .unavailable)
    rig.store.failDecision = false
    XCTAssertEqual(original.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    var resumedStates: [PairingJoinState] = []
    let resumed = service.start(cid: rig.mailbox.pairingCID) { resumedStates.append($0) }
    try helper.wait { resumedStates.contains { if case .waiting = $0 { return true }; return false } }
    XCTAssertEqual(resumed.cancel(), .cancelled)
    _ = prior.cancel()
    _ = blocked.cancel()
  }
  func testReplacementEpochIsRecheckedAfterPredecessorCancellationWait() throws {
    let helper = PairingCoordinatorTests()
    let rig = PairingCoordinatorTests.Rig()
    let inserted = expectation(description: "old key insertion held")
    let cancelling = expectation(description: "replacement cancellation held")
    let completed = expectation(description: "replacement start returned")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { inserted.fulfill() }
    let original = try helper.receivedApproval(rig).0
    wait(for: [inserted], timeout: 3)
    rig.store.holdCancellation = true
    rig.store.cancellationReached = { cancelling.fulfill() }
    let epoch = rig.coordinator.configurationEpoch
    let randomDraws = rig.rng.sizes.count
    var replacementStates: [PairingJoinState] = []
    DispatchQueue.global().async {
      _ = rig.coordinator.start(cid: rig.mailbox.pairingCID, expectedInvalidationEpoch: epoch) { replacementStates.append($0) }
      completed.fulfill()
    }
    wait(for: [cancelling], timeout: 3)
    _ = rig.coordinator.reserveJoiningReplacement()
    rig.store.holdCancellation = false
    rig.store.cancellationRelease.signal()
    rig.keys.insertRelease.signal()
    wait(for: [completed], timeout: 3)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(rig.rng.sizes.count, randomDraws, "An obsolete replacement must not create fresh session material")
    XCTAssertFalse(replacementStates.contains { if case .waiting = $0 { return true }; return false })
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertTrue(rig.store.admitted.isEmpty)
    _ = original.cancel()
  }

}
