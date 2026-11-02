import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class ReviewHostRecoveryTests: XCTestCase {
  func testCommittedCustomFolderSurvivesRestartBeforeFirstSyncDocument() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let service = PairingServices()
    service.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let firstLimit = Date().addingTimeInterval(5)
    while service.installationHost == nil && Date() < firstLimit { usleep(1000) }
    usleep(100000)
    XCTAssertNotNil(service.installationHost)
    XCTAssertEqual(service.installationHost?.committedState(), .approved, "Restart must select the durably admitted custom-folder record before a provisional default host")
    service.selectFolder(custom.path)
    let secondLimit = Date().addingTimeInterval(5)
    while service.installationHost?.committedState() != .approved && Date() < secondLimit { usleep(1000) }
    XCTAssertEqual(service.installationHost?.committedState(), .approved, "Durable admitted join was lost by startup's default-folder host and switching back to its recorded folder")
    XCTAssertEqual(host.committedState(), .approved, "Original committed host now suppressed by an unrequested Stop tombstone")
    service.invalidate("shutdown")
  }
  func testCancelledReplacementCannotLeaveEarlierQueuedJoinAlive() throws {
    let helper = PairingCoordinatorTests()
    let rig = PairingCoordinatorTests.Rig()
    let inserted = expectation(description: "key write held")
    let cancelling = expectation(description: "old join cancellation held")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { inserted.fulfill() }
    let first = try helper.receivedApproval(rig)
    wait(for: [inserted], timeout: 3)
    rig.store.holdCancellation = true
    rig.store.cancellationReached = { cancelling.fulfill() }
    let service = PairingServices()
    service.register(rig.coordinator)
    var replacementStates: [PairingJoinState] = []
    let replacement = service.start(cid: rig.mailbox.pairingCID) { replacementStates.append($0) }
    wait(for: [cancelling], timeout: 3)
    let latest = service.start(cid: rig.mailbox.pairingCID) { _ in }
    XCTAssertEqual(latest.cancel(), .cancelled)
    rig.store.cancellationRelease.signal()
    rig.keys.insertRelease.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertFalse(rig.coordinator.snapshot.joining, "Latest start/cancel reported cancelled but earlier queued join remains live")
    _ = replacement.cancel()
    _ = first.0.cancel()
  }

  func testInaccessibleCommittedFolderStaysPendingWithoutTombstoneAndResumes() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("temporarily-unavailable")
    try FileManager.default.moveItem(at: custom, to: unavailable)
    let service = PairingServices()
    service.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let limit = Date().addingTimeInterval(3)
    while service.committedOnboardingJoinToken == nil && Date() < limit { usleep(1000) }
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    XCTAssertNil(service.installationHost)
    var pending: PairingJoinState?
    XCTAssertTrue(service.committedJoin { pending = $0 })
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(pending, .approved)
    service.selectFolder(defaultFolder.path)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let stop = data.appendingPathComponent("Application Support/sync-pairing/host-stop.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path))
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    try FileManager.default.moveItem(at: unavailable, to: custom)
    service.refresh()
    let resumed = Date().addingTimeInterval(3)
    while service.installationHost == nil && Date() < resumed { usleep(1000) }
    XCTAssertEqual(service.installationHost?.committedState(), .approved)
    XCTAssertEqual(host.committedState(), .approved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path))
    service.invalidate("stop")
    XCTAssertNil(service.committedOnboardingJoinToken)
    service.invalidate("shutdown")
  }


  func testStopRetiresPendingCommittedObserverBeforeFolderReturns() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("temporarily-unavailable")
    try FileManager.default.moveItem(at: custom, to: unavailable)
    let service = PairingServices()
    service.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let limit = Date().addingTimeInterval(3)
    while service.committedOnboardingJoinToken == nil && Date() < limit { usleep(1000) }
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    var states: [PairingJoinState] = []
    XCTAssertTrue(service.committedJoin { states.append($0) })
    service.invalidate("stop")
    XCTAssertNil(service.committedOnboardingJoinToken)
    XCTAssertFalse(service.committedJoin { states.append($0) }, "Stop must retire the pending committed observer even while its folder cannot be opened")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(states.isEmpty, "A committed callback queued before Stop must not be delivered after its synchronous barrier")
    service.invalidate("shutdown")
  }


}
