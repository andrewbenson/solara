import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingTimerAdmissionTests: XCTestCase {
  final class Timers {
    final class Entry {
      let fire: () -> Void
      var cancelled = false
      init(_ fire: @escaping () -> Void) { self.fire = fire }
    }
    let lock = NSLock()
    private var stored: [Entry] = []
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return stored }
    func schedule(_ queue: DispatchQueue, _ delay: TimeInterval, _ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
      let entry = Entry(fire)
      lock.lock(); stored.append(entry); lock.unlock()
      return { entry.cancelled = true }
    }
  }

  func testModuleBeforeWindowDoesNotArmOptionalTimerAndLateAdmissionArmsOnce() {
    let timers = Timers()
    let service = PairingServices(scheduleTimer: timers.schedule)
    service.moduleAttached()
    XCTAssertTrue(timers.entries.isEmpty)
    service.setPeriodicAdmitted(true)
    service.setPeriodicAdmitted(true)
    XCTAssertEqual(timers.entries.count, 1)
    service.invalidate("shutdown")
  }

  func testDemandBeforeChromeArmsAndWithdrawalCancels() {
    let timers = Timers()
    let service = PairingServices(scheduleTimer: timers.schedule)
    service.setDemanded(true)
    XCTAssertEqual(timers.entries.count, 1)
    service.setDemanded(false)
    XCTAssertTrue(timers.entries.first?.cancelled == true)
    service.invalidate("shutdown")
  }

  func testCloseReopenRearmsOnceAndQuitRefusesStaleAdmission() {
    let timers = Timers()
    let service = PairingServices(scheduleTimer: timers.schedule)
    service.setPeriodicAdmitted(true)
    service.setPeriodicAdmitted(false)
    XCTAssertTrue(timers.entries.first?.cancelled == true)
    service.setPeriodicAdmitted(true)
    service.setPeriodicAdmitted(true)
    XCTAssertEqual(timers.entries.count, 2)
    service.invalidate("shutdown")
    service.setPeriodicAdmitted(true)
    XCTAssertTrue(timers.entries.allSatisfy(\.cancelled))
    XCTAssertEqual(timers.entries.count, 2)
  }

  func testStaleDeferredTimerCannotFireAfterCancellationOrRearm() {
    let timers = Timers()
    var calls = 0
    let timer = PairingPeriodicTimer(queue: .main, delay: 1, interval: 5, schedule: timers.schedule) { calls += 1 }
    timer.setEnabled(true)
    let old = timers.entries[0]
    timer.setEnabled(false)
    old.fire()
    timer.setEnabled(true)
    old.fire()
    XCTAssertEqual(calls, 0)
    timers.entries[1].fire()
    XCTAssertEqual(calls, 1)
  }

  func testNoWindowBootstrapCompletesAndStopsRequiredRetry() throws {
    let timers = Timers()
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data"), folder = root.appendingPathComponent("folder")
    for url in [data, folder] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let service = PairingServices(scheduleTimer: timers.schedule)
    defer { service.invalidate("shutdown") }
    service.bootstrap(dataDirectory: data, defaultFolder: folder, keys: FileKeyStore(directory: data), safeMode: { false })
    try PairingCoordinatorTests().wait { service.installationHost != nil && service.coordinator != nil }
    try PairingCoordinatorTests().wait { timers.entries.allSatisfy(\.cancelled) }
    XCTAssertNotNil(service.installationHost)
  }

  func testFreshUnconfiguredMissingFolderDoesNotCreateRecoveryTimer() throws {
    let timers = Timers()
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let service = PairingServices(scheduleTimer: timers.schedule)
    defer { service.invalidate("shutdown") }
    service.bootstrap(dataDirectory: data, defaultFolder: root.appendingPathComponent("missing"), keys: FileKeyStore(directory: data), safeMode: { false })
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(timers.entries.isEmpty)
  }

  private func coordinator(_ rig: PairingCoordinatorTests.Rig, timers: Timers) -> PairingCoordinator {
    PairingCoordinator(configuration: .init(cid: rig.mailbox.pairingCID, environment: .init(folderIdentity: Data([9]), entropyHandle: Data([8]), clockEpoch: rig.clockEpoch), localName: "Fixture", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)), mailbox: rig.mailbox, store: rig.store, authenticator: rig.auth, keyStore: rig.keys, host: rig.host, clock: rig.time.read, wall: { 1793552400000 }, random: rig.rng.take, periodicAdmitted: false, scheduleTimer: timers.schedule)
  }

  func testCoordinatorDefersDiscoveryAndRequiredSessionStillExpiresBeforeChrome() throws {
    let rig = PairingCoordinatorTests.Rig(), timers = Timers()
    let owner = coordinator(rig, timers: timers)
    defer { owner.invalidate(reason: .shutdown) }
    XCTAssertTrue(timers.entries.isEmpty)
    var states: [PairingJoinState] = []
    let control = owner.start(cid: rig.mailbox.pairingCID) { states.append($0) }
    XCTAssertEqual(timers.entries.count, 1)
    rig.time.now += 300001
    timers.entries[0].fire()
    try PairingCoordinatorTests().wait { !owner.snapshot.joining }
    XCTAssertTrue(timers.entries[0].cancelled)
    XCTAssertEqual(control.cancel(), .cancelled)
  }

  func testCoordinatorStaleTimerDoesNotDiscoverAfterClose() throws {
    let rig = PairingCoordinatorTests.Rig(), timers = Timers()
    let owner = coordinator(rig, timers: timers)
    defer { owner.invalidate(reason: .shutdown) }
    owner.setPeriodicAdmitted(true)
    _ = owner.snapshot
    XCTAssertEqual(timers.entries.count, 1)
    owner.setPeriodicAdmitted(false)
    _ = owner.snapshot
    timers.entries[0].fire()
    _ = owner.snapshot
    XCTAssertEqual(rig.mailbox.polls, 0)
    owner.setPeriodicAdmitted(true)
    _ = owner.snapshot
    timers.entries[1].fire()
    try PairingCoordinatorTests().wait { rig.mailbox.polls == 1 }
  }

  func testInvalidationDropsQueuedDirtyPoll() throws {
    let rig = PairingCoordinatorTests.Rig(), timers = Timers()
    let owner = coordinator(rig, timers: timers)
    owner.setPeriodicAdmitted(true)
    _ = owner.snapshot
    rig.mailbox.holdPoll = true
    let reached = expectation(description: "mailbox poll held")
    rig.mailbox.pollReached = { reached.fulfill() }
    owner.poll()
    wait(for: [reached], timeout: 3)
    owner.poll()
    _ = owner.snapshot
    owner.invalidate(reason: .shutdown)
    _ = owner.snapshot
    rig.mailbox.holdPoll = false
    rig.mailbox.pollRelease.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(rig.mailbox.polls, 1)
    XCTAssertTrue(timers.entries.allSatisfy(\.cancelled))
  }

  func testCommittedPendingInstallationRecoversWithoutWindowAndKeepsRequiredRetry() throws {
    try committedRecovery(temporarilyMissing: false)
  }

  func testDurablePendingInstallationRetriesTransientMissingFolderWithoutWindow() throws {
    try committedRecovery(temporarilyMissing: true)
  }

  private func committedRecovery(temporarilyMissing: Bool) throws {
    let timers = Timers()
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data"), folder = root.appendingPathComponent("folder")
    let entropy = Data(repeating: 41, count: 32), keys = SyncKeys(entropy: entropy)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(keys.chainTag), withIntermediateDirectories: true)
    let identity = try PairingMailbox(folder: folder, cid: keys.chainTag).folderIdentity
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: .init(noPairingEraSyncState: false, noJoinOrStopMarker: false, keyStateKnown: false))
    let keyStore = FileKeyStore(directory: data)
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: keys.chainTag, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: identity, keys: keyStore, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keyStore.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    let service = PairingServices(scheduleTimer: timers.schedule)
    defer { service.invalidate("shutdown") }
    let heldFolder = root.appendingPathComponent("held-folder")
    if temporarilyMissing { try FileManager.default.moveItem(at: folder, to: heldFolder) }
    service.bootstrap(dataDirectory: data, defaultFolder: folder, keys: keyStore, safeMode: { false })
    if temporarilyMissing {
      try PairingCoordinatorTests().wait { timers.entries.contains { !$0.cancelled } }
      XCTAssertNil(service.installationHost)
      try FileManager.default.moveItem(at: heldFolder, to: folder)
      timers.entries.last?.fire()
    }
    try PairingCoordinatorTests().wait { service.installationHost != nil && service.committedOnboardingJoinToken != nil }
    XCTAssertNotNil(service.installationHost?.installationRequest())
    try PairingCoordinatorTests().wait { timers.entries.contains { !$0.cancelled } }
    XCTAssertEqual(service.installationHost?.committedState(), .approved)
  }

  func testNativeTrustedArmExpiresAtItsOriginalDeadlineBeforeChrome() throws {
    let rig = PairingCoordinatorTests.Rig(), timers = Timers()
    let owner = coordinator(rig, timers: timers)
    defer { owner.invalidate(reason: .shutdown) }
    _ = try owner.armTrusted()
    XCTAssertEqual(timers.entries.count, 1)
    rig.time.now += 120001
    timers.entries[0].fire()
    try PairingCoordinatorTests().wait { !owner.snapshot.trusted }
    XCTAssertTrue(timers.entries[0].cancelled)
  }

  func testTerminalGraceKeepsRequiredTimerAfterBothSurfacesEndWithoutChrome() throws {
    let rig = PairingCoordinatorTests.Rig(), timers = Timers()
    rig.coordinator = coordinator(rig, timers: timers)
    defer { rig.coordinator.invalidate(reason: .shutdown) }
    let fixture = PairingCoordinatorTests()
    let pair = try fixture.comparing(rig)
    try rig.coordinator.deny(pair.1)
    try fixture.wait { rig.mailbox.externallyVisible.contains { $0.kind == .trustedTerminal } }
    rig.coordinator.poll()
    try fixture.wait { !rig.coordinator.snapshot.joining && !rig.coordinator.snapshot.trusted }
    XCTAssertTrue(timers.entries.contains { !$0.cancelled })
    rig.time.now += 59999
    timers.entries.last?.fire()
    _ = rig.coordinator.snapshot
    XCTAssertTrue(rig.mailbox.externallyVisible.contains { $0.kind == .trustedTerminal })
    rig.time.now += 1
    timers.entries.last?.fire()
    try fixture.wait { !rig.mailbox.externallyVisible.contains { $0.kind == .trustedTerminal } }
    try fixture.wait { timers.entries.allSatisfy(\.cancelled) }
  }

  func testPendingDurableStopRetriesWithoutOptionalFolderOrChrome() throws {
    let timers = Timers()
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let stop = data.appendingPathComponent("Application Support/sync-pairing/host-stop.json")
    try FileManager.default.createDirectory(at: stop, withIntermediateDirectories: true)
    let service = PairingServices(scheduleTimer: timers.schedule)
    defer { service.invalidate("shutdown") }
    service.bootstrap(dataDirectory: data, defaultFolder: root.appendingPathComponent("missing"), keys: FileKeyStore(directory: data), safeMode: { false })
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    service.invalidate("stop")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(timers.entries.contains { !$0.cancelled })
    try FileManager.default.removeItem(at: stop)
    timers.entries.last?.fire()
    try PairingCoordinatorTests().wait { (try? Data(contentsOf: stop)) != nil }
    try PairingCoordinatorTests().wait { timers.entries.allSatisfy(\.cancelled) }
  }

}
