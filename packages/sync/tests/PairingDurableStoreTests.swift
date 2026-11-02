import Foundation
import Darwin
import XCTest
@testable import SolaraLegacySyncCore

final class PairingDurableStoreTests: XCTestCase {
  final class Barriers: PairingPOSIXSyncing {
    var failFullSync = false
    var failFileSync = false
    var failDirectorySync = false
    var failDirectorySyncAtCall: Int?
    var failDirectorySyncPath: String?
    var directoryPaths: [String] = []
    var calls: [String] = []
    func fullSync(_ descriptor: Int32) -> Int32 {
      calls.append("file.fullSync")
      if failFullSync { errno = EIO; return -1 }
      return fcntl(descriptor, F_FULLFSYNC)
    }
    func sync(_ descriptor: Int32) -> Int32 {
      var info = stat()
      guard fstat(descriptor, &info) == 0 else { return -1 }
      let isDirectory = info.st_mode & S_IFMT == S_IFDIR
      calls.append(isDirectory ? "directory.sync" : "file.sync")
      if isDirectory {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return -1 }
        directoryPaths.append(String(cString: path))
        let count = failDirectorySyncPath.map { target in directoryPaths.filter { $0 == target }.count } ?? directoryPaths.count
        if count == failDirectorySyncAtCall { errno = EIO; return -1 }
      }
      if isDirectory ? failDirectorySync : failFileSync { errno = EIO; return -1 }
      return fsync(descriptor)
    }
  }
  final class DirectoryBarriers: PairingPOSIXSyncing {
    struct Event {
      let path: String
      let succeeded: Bool
    }
    let failedParent: String
    private let lock = NSLock()
    private var injected = false
    private var events: [Event] = []
    init(failedParent: URL) { self.failedParent = failedParent.path }
    var parentFailed: Bool { lock.lock(); defer { lock.unlock() }; return injected }
    var parentSucceeded: Bool { lock.lock(); defer { lock.unlock() }; return events.contains { $0.path == failedParent && $0.succeeded } }
    func fullSync(_ descriptor: Int32) -> Int32 { fcntl(descriptor, F_FULLFSYNC) }
    func sync(_ descriptor: Int32) -> Int32 {
      var info = stat()
      guard fstat(descriptor, &info) == 0 else { return -1 }
      guard info.st_mode & S_IFMT == S_IFDIR else { return fsync(descriptor) }
      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return -1 }
      let name = String(cString: path)
      lock.lock()
      defer { lock.unlock() }
      if name == failedParent && !injected {
        injected = true
        events.append(.init(path: name, succeeded: false))
        errno = EIO
        return -1
      }
      let result = fsync(descriptor)
      events.append(.init(path: name, succeeded: result == 0))
      return result
    }
  }
  final class ReadbackFaults: PairingDurableIO {
    let disk = PairingPOSIXDurableIO()
    var corruptReadback = false
    func prepare(_ directory: URL) throws { try disk.prepare(directory) }
    func exists(_ url: URL) -> Bool { disk.exists(url) }
    func contents(_ directory: URL) throws -> [String] { try disk.contents(directory) }
    func read(_ url: URL, limit: Int) throws -> Data { corruptReadback ? Data([0]) : try disk.read(url, limit: limit) }
    func createExclusive(_ bytes: Data, at url: URL) throws { try disk.createExclusive(bytes, at: url) }
    func replace(_ bytes: Data, at url: URL) throws { try disk.replace(bytes, at: url) }
  }
  final class Disk: PairingDurableIO {
    var files: [URL: Data] = [:]
    var failWrite = false
    var failListing = false
    var corruptReadback = false
    func prepare(_ directory: URL) throws {}
    func exists(_ url: URL) -> Bool { files[url] != nil }
    func contents(_ directory: URL) throws -> [String] {
      guard !failListing else { throw PairingDurableStore.Failure.storage }
      return files.keys.filter { $0.deletingLastPathComponent() == directory }.map { $0.lastPathComponent }
    }
    func read(_ url: URL, limit: Int) throws -> Data {
      guard let value = files[url], value.count <= limit else { throw PairingDurableStore.Failure.storage }
      return corruptReadback ? Data([0]) : value
    }
    func createExclusive(_ bytes: Data, at url: URL) throws {
      guard files[url] == nil else { throw PairingDurableStore.Failure.storage }
      try replace(bytes, at: url)
    }
    func replace(_ bytes: Data, at url: URL) throws {
      guard !failWrite else { throw PairingDurableStore.Failure.storage }
      files[url] = bytes
    }
  }
  func temporaryRoot() throws -> URL {
    let path = ProcessInfo.processInfo.environment["TMPDIR"] ?? SyncTestDirectory.url.path
    guard let pointer = realpath(path, nil) else { throw PairingDurableStore.Failure.storage }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true).appendingPathComponent(UUID().uuidString)
  }
  let epoch = Data(repeating: 1, count: 16)
  let empty = PairingFirstInstallationEvidence(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: true)
  func store(_ disk: Disk, verified: Bool = true) throws -> PairingDurableStore {
    try PairingDurableStore(dataDirectory: URL(fileURLWithPath: "/private/tmp/pairing-data"), syncFolder: URL(fileURLWithPath: "/private/tmp/pairing-sync"), firstInstallation: verified ? empty : .init(noPairingEraSyncState: false, noJoinOrStopMarker: true, keyStateKnown: true), io: disk)
  }
  func accounting(_ disposition: PairingSession.RestorationDisposition) -> PairingSession.Accounting? {
    if case .restored(let value) = disposition { return value }
    return nil
  }
  func record(_ id: UInt8 = 1) -> PairingConsumedApproval {
    .init(cid: Data(repeating: id, count: 16), rid: Data(repeating: 2, count: 16), aid: Data(repeating: 3, count: 16), transcript: Data(repeating: 4, count: 32), epoch: epoch, time: 100, sealedApproval: Data(repeating: 5, count: 1160))
  }
  func installation(transaction: UInt8 = 1, cid: UInt8 = 2, device: UInt8 = 3, folder: UInt8 = 4, generation: UInt64 = 1) -> PairingInstallation {
    .init(transaction: Data(repeating: transaction, count: 32), cid: Base32.encode(Data(repeating: cid, count: 16)), device: Base32.encode(Data(repeating: device, count: 16)), folderIdentity: Data(repeating: folder, count: 16), generation: generation)
  }
  func testPOSIXAdmittedRetryAcrossStoreReopenRepeatsFailedAncestorBarrier() throws {
    for suffix in ["data", "data/Application Support"] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let parent = root.appendingPathComponent(suffix, isDirectory: true)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let barriers = DirectoryBarriers(failedParent: parent)
      let io = PairingPOSIXDurableIO(barriers: barriers)
      let original = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: io)
      let value = PairingInstallationDecision(installation: installation(), disposition: .admitted)
      XCTAssertThrowsError(try original.persistInstallationDecision(value))
      XCTAssertTrue(barriers.parentFailed)
      XCTAssertFalse(barriers.parentSucceeded)
      let child = parent.appendingPathComponent(suffix == "data" ? "Application Support" : "sync-pairing")
      XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
      let reopened = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: io)
      XCTAssertEqual(try reopened.persistInstallationDecision(value), value)
      XCTAssertTrue(barriers.parentSucceeded, "admission acknowledged without repeating failed parent barrier at \(parent.path)")
      XCTAssertEqual(try reopened.installationDecision(for: value.installation), value)
    }
  }
  func testPOSIXCancelledRetryRepeatsFailedAncestorBarrier() throws {
    for suffix in ["data", "data/Application Support"] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let parent = root.appendingPathComponent(suffix, isDirectory: true)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let barriers = DirectoryBarriers(failedParent: parent)
      let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: PairingPOSIXDurableIO(barriers: barriers))
      let value = installation()
      XCTAssertThrowsError(try s.cancelInstallation(value))
      XCTAssertTrue(barriers.parentFailed)
      XCTAssertFalse(barriers.parentSucceeded)
      let child = parent.appendingPathComponent(suffix == "data" ? "Application Support" : "sync-pairing")
      XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
      XCTAssertNoThrow(try s.cancelInstallation(value))
      XCTAssertTrue(barriers.parentSucceeded, "cancellation acknowledged without repeating failed parent barrier at \(parent.path)")
      XCTAssertEqual(try s.installationDecision(for: value)?.disposition, .cancelled)
    }
  }
  func testInstallationDecisionsPersistExactlyAcrossStoreReopen() throws {
    for disposition in [PairingInstallationDecision.Disposition.admitted, .cancelled] {
      let disk = Disk(), s = try store(disk)
      let value = PairingInstallationDecision(installation: installation(), disposition: disposition)
      XCTAssertNil(try s.installationDecision(for: value.installation))
      XCTAssertEqual(try s.persistInstallationDecision(value), value)
      XCTAssertEqual(try s.persistInstallationDecision(value), value)
      XCTAssertEqual(try store(disk).installationDecision(for: value.installation), value)
      XCTAssertEqual(disk.files.count, 1)
    }
  }
  func testInstallationDecisionConflictCannotReplaceEitherDisposition() throws {
    for disposition in [PairingInstallationDecision.Disposition.admitted, .cancelled] {
      let disk = Disk(), s = try store(disk)
      let value = PairingInstallationDecision(installation: installation(), disposition: disposition)
      _ = try s.persistInstallationDecision(value)
      let bytes = disk.files
      let conflict = PairingInstallationDecision(installation: value.installation, disposition: disposition == .admitted ? .cancelled : .admitted)
      XCTAssertThrowsError(try s.persistInstallationDecision(conflict))
      XCTAssertEqual(disk.files, bytes)
      XCTAssertEqual(try store(disk).installationDecision(for: value.installation), value)
    }
  }
  func testInstallationDecisionBindsAllMetadataAndSeparatesTransactionsAndGenerations() throws {
    let disk = Disk(), s = try store(disk)
    let value = PairingInstallationDecision(installation: installation(), disposition: .admitted)
    _ = try s.persistInstallationDecision(value)
    for altered in [installation(cid: 5), installation(device: 5), installation(folder: 5)] {
      XCTAssertThrowsError(try store(disk).installationDecision(for: altered))
      XCTAssertThrowsError(try store(disk).persistInstallationDecision(.init(installation: altered, disposition: .admitted)))
    }
    for distinct in [installation(transaction: 5), installation(generation: 2)] {
      XCTAssertNil(try s.installationDecision(for: distinct))
      let next = PairingInstallationDecision(installation: distinct, disposition: .cancelled)
      XCTAssertEqual(try s.persistInstallationDecision(next), next)
    }
    XCTAssertEqual(disk.files.count, 3)
    XCTAssertEqual(try store(disk).installationDecision(for: value.installation), value)
  }
  func testInstallationDecisionFailureLatchesUncertaintyBeforeRetry() throws {
    for corrupt in [false, true] {
      let disk = Disk(), s = try store(disk)
      disk.failWrite = !corrupt
      disk.corruptReadback = corrupt
      let value = PairingInstallationDecision(installation: installation(), disposition: .admitted)
      XCTAssertThrowsError(try s.persistInstallationDecision(value))
      disk.failWrite = false
      disk.corruptReadback = false
      XCTAssertThrowsError(try s.persistInstallationDecision(value))
      XCTAssertThrowsError(try s.installationDecision(for: value.installation))
    }
  }
  func testDurableCancellationVetoSettlesUncertainAdmissionAcrossReopen() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = ReadbackFaults()
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: disk)
    let admitted = PairingInstallationDecision(installation: installation(), disposition: .admitted)
    disk.corruptReadback = true
    XCTAssertThrowsError(try s.persistInstallationDecision(admitted))
    disk.corruptReadback = false
    let reopened = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    XCTAssertEqual(try reopened.installationDecision(for: admitted.installation), admitted)
    XCTAssertThrowsError(try s.installationDecision(for: admitted.installation))
    XCTAssertNoThrow(try s.cancelInstallation(admitted.installation))
    let cancelled = PairingInstallationDecision(installation: admitted.installation, disposition: .cancelled)
    let settled = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    XCTAssertEqual(try settled.installationDecision(for: admitted.installation), cancelled)
    XCTAssertEqual(try? s.installationDecision(for: admitted.installation), cancelled)
    XCTAssertThrowsError(try settled.persistInstallationDecision(admitted))
  }
  func testDurableCancellationVetoReadbackFailureCannotAcknowledge() throws {
    let disk = Disk(), s = try store(disk)
    let value = installation()
    disk.corruptReadback = true
    XCTAssertThrowsError(try s.cancelInstallation(value))
    disk.corruptReadback = false
    XCTAssertNoThrow(try s.cancelInstallation(value))
    let cancelled = PairingInstallationDecision(installation: value, disposition: .cancelled)
    XCTAssertEqual(try store(disk).installationDecision(for: value), cancelled)
    XCTAssertNoThrow(try s.cancelInstallation(value))
  }
  func testPOSIXCancellationRetryRepeatsBarriersAfterUncertainPublication() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: PairingPOSIXDurableIO(barriers: barriers))
    let admitted = PairingInstallationDecision(installation: installation(), disposition: .admitted)
    _ = try s.persistInstallationDecision(admitted)
    barriers.calls = []
    barriers.failDirectorySyncPath = s.directory.path
    barriers.directoryPaths = []
    barriers.failDirectorySyncAtCall = 2
    XCTAssertThrowsError(try s.cancelInstallation(admitted.installation))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).contains(where: { $0.hasPrefix("cancelled-") }))
    barriers.failDirectorySyncAtCall = nil
    barriers.calls = []
    XCTAssertNoThrow(try s.cancelInstallation(admitted.installation))
    XCTAssertEqual(barriers.calls.first, "directory.sync")
    XCTAssertTrue(barriers.calls.contains("file.fullSync"))
    XCTAssertEqual(barriers.calls.last, "directory.sync")
    let reopened = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    XCTAssertEqual(try reopened.installationDecision(for: admitted.installation)?.disposition, .cancelled)
  }
  func testCancellationVetoBindsMetadataAndRejectsMalformedRecords() throws {
    let disk = Disk(), s = try store(disk)
    let value = installation()
    try s.cancelInstallation(value)
    for altered in [installation(cid: 5), installation(device: 5), installation(folder: 5)] {
      XCTAssertThrowsError(try s.installationDecision(for: altered))
      XCTAssertThrowsError(try s.cancelInstallation(altered))
    }
    let name = try XCTUnwrap(disk.files.keys.first)
    let admitted = PairingInstallationDecision(installation: value, disposition: .admitted)
    disk.files[name] = try JSONEncoder().encode(admitted)
    XCTAssertThrowsError(try s.installationDecision(for: value))
    XCTAssertThrowsError(try s.cancelInstallation(value))
    XCTAssertThrowsError(try s.persistInstallationDecision(admitted))
  }
  func testInstallationDecisionMissingListingAndMalformedRecordsFailClosed() throws {
    let disk = Disk(), s = try store(disk)
    disk.failListing = true
    XCTAssertThrowsError(try s.installationDecision(for: installation()))
    disk.failListing = false
    let value = PairingInstallationDecision(installation: installation(), disposition: .admitted)
    _ = try s.persistInstallationDecision(value)
    let file = try XCTUnwrap(disk.files.keys.first)
    for bytes in [Data([0]), Data("{\"disposition\":\"unknown\"}".utf8), Data(count: 16385)] {
      disk.files[file] = bytes
      XCTAssertThrowsError(try store(disk).installationDecision(for: value.installation))
      XCTAssertThrowsError(try store(disk).persistInstallationDecision(value))
    }
    XCTAssertThrowsError(try s.persistInstallationDecision(.init(installation: installation(generation: 0), disposition: .admitted)))
  }
  func testPOSIXInstallationDecisionFileBarrierFailureCannotAdmit() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: PairingPOSIXDurableIO(barriers: barriers))
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initialization refused") }
    barriers.calls = []
    barriers.failFullSync = true
    barriers.failFileSync = true
    let value = PairingInstallationDecision(installation: installation(), disposition: .admitted)
    XCTAssertThrowsError(try s.persistInstallationDecision(value))
    XCTAssertEqual(Array(barriers.calls.suffix(2)), ["file.fullSync", "file.sync"])
    barriers.failFullSync = false
    barriers.failFileSync = false
    XCTAssertThrowsError(try s.persistInstallationDecision(value))
    let reopened = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    XCTAssertNil(try reopened.installationDecision(for: value.installation))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).contains(where: { $0.hasPrefix(".pending-") }))
  }
  func testPOSIXInstallationDecisionReopensAndCannotOverwriteCancellation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    let value = PairingInstallationDecision(installation: installation(), disposition: .cancelled)
    XCTAssertEqual(try s.persistInstallationDecision(value), value)
    let reopened = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    XCTAssertEqual(try reopened.installationDecision(for: value.installation), value)
    XCTAssertThrowsError(try reopened.persistInstallationDecision(.init(installation: value.installation, disposition: .admitted)))
    XCTAssertEqual(try s.installationDecision(for: value.installation), value)
    let io = PairingPOSIXDurableIO()
    let file = try XCTUnwrap(try io.contents(s.directory).first)
    let before = try io.read(s.directory.appendingPathComponent(file), limit: 16384)
    XCTAssertThrowsError(try io.createExclusive(Data([0]), at: s.directory.appendingPathComponent(file)))
    XCTAssertEqual(try io.read(s.directory.appendingPathComponent(file), limit: 16384), before)
  }
  func testVerifiedFirstInstallPersistsBeforeReturningFresh() throws {
    let disk = Disk(), s = try store(disk)
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("fresh initialization refused") }
    XCTAssertNotNil(disk.files[s.directory.appendingPathComponent("accounting.json")])
    XCTAssertNotNil(disk.files[s.directory.appendingPathComponent("initialized")])
  }
  func testEstablishedMissingAccountingQuarantinesAndPersists() throws {
    let disk = Disk(), s = try store(disk, verified: false)
    if case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) { XCTFail("existing installation reset") }
    let restored = try store(disk).restoreAccounting(now: 200, epoch: epoch)
    XCTAssertEqual(accounting(restored)?.blockedUntil, 86400100)
  }
  func testSentinelWithoutLedgerNeverFresh() throws {
    let disk = Disk(), s = try store(disk)
    disk.files[s.directory.appendingPathComponent("initialized")] = Data([1])
    if case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) { XCTFail("partial initialization reset") }
  }
  func testCorruptSentinelQuarantineDoesNotRestartWait() throws {
    let disk = Disk(), s = try store(disk)
    disk.files[s.directory.appendingPathComponent("initialized")] = Data([0])
    let first = accounting(s.restoreAccounting(now: 100, epoch: epoch))
    let second = accounting(try store(disk).restoreAccounting(now: 200, epoch: epoch))
    XCTAssertEqual(first?.blockedUntil, 86400100)
    XCTAssertEqual(second?.blockedUntil, 86400100)
  }
  func testCorruptUnknownAndOversizeLedgerQuarantine() throws {
    for bytes in [Data([0]), Data("{\"version\":99}".utf8), Data(count: 100000)] {
      let disk = Disk(), s = try store(disk)
      disk.files[s.directory.appendingPathComponent("accounting.json")] = bytes
      if case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) { XCTFail("invalid ledger reset") }
      XCTAssertTrue(s.suppressed)
    }
  }
  func testFsyncFailureCannotAcknowledgeReservation() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    disk.failWrite = true
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)))
  }
  func testPOSIXFileBarrierFailureCannotAcknowledgeReservation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: PairingPOSIXDurableIO(barriers: barriers))
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initialization refused") }
    barriers.calls = []
    barriers.failFullSync = true
    barriers.failFileSync = true
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)))
    XCTAssertEqual(barriers.calls, ["file.fullSync", "file.sync"])
    barriers.failFullSync = false
    barriers.failFileSync = false
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, lastTime: 100, revision: 2)))
    let restored = accounting(s.restoreAccounting(now: 200, epoch: epoch))
    XCTAssertEqual(restored?.revision, 0)
    XCTAssertEqual(restored?.reveals, [])
  }
  func testPOSIXFileBarrierFallbackPrecedesDirectoryPublication() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let io = PairingPOSIXDurableIO(barriers: barriers)
    try io.prepare(root)
    barriers.calls = []
    barriers.failFullSync = true
    let target = root.appendingPathComponent("ledger")
    try io.replace(Data([1, 2, 3]), at: target)
    XCTAssertEqual(barriers.calls, ["file.fullSync", "file.sync", "directory.sync"])
    XCTAssertEqual(try io.read(target, limit: 3), Data([1, 2, 3]))
  }
  func testPOSIXDirectoryBarrierFailureCannotAcknowledgeRenamedReservation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty, io: PairingPOSIXDurableIO(barriers: barriers))
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initialization refused") }
    barriers.calls = []
    barriers.failDirectorySync = true
    let reservation = PairingSession.Accounting(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)
    XCTAssertThrowsError(try s.persistAccounting(reservation))
    XCTAssertEqual(barriers.calls.first, "file.fullSync")
    XCTAssertEqual(barriers.calls.last, "directory.sync")
    XCTAssertEqual(try JSONDecoder().decode(PairingSession.Accounting.self, from: Data(contentsOf: s.directory.appendingPathComponent("accounting.json"))), reservation)
    barriers.failDirectorySync = false
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, lastTime: 100, revision: 2)))
    XCTAssertEqual(accounting(s.restoreAccounting(now: 200, epoch: epoch)), reservation)
  }
  func testPOSIXDirectoryCreationBarrierFailureRefusesPreparation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let barriers = Barriers()
    barriers.failDirectorySync = true
    XCTAssertThrowsError(try PairingPOSIXDurableIO(barriers: barriers).prepare(root.appendingPathComponent("private/ledger")))
    XCTAssertEqual(barriers.calls, ["directory.sync"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("private/ledger").path))
  }
  func testPOSIXExclusiveDirectoryBarrierFailureRefusesPublication() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let barriers = Barriers()
    let io = PairingPOSIXDurableIO(barriers: barriers)
    try io.prepare(root)
    barriers.calls = []
    barriers.failDirectorySync = true
    XCTAssertThrowsError(try io.createExclusive(Data([1]), at: root.appendingPathComponent("initialized")))
    XCTAssertEqual(barriers.calls.first, "file.fullSync")
    XCTAssertEqual(barriers.calls.last, "directory.sync")
  }
  func testReadbackMismatchCannotAcknowledgeReservation() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    disk.corruptReadback = true
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)))
  }
  func testUncertainReadbackCannotReplayOlderAccounting() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    disk.corruptReadback = true
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)))
    disk.corruptReadback = false
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, lastTime: 100)))
    XCTAssertEqual(accounting(try store(disk).restoreAccounting(now: 200, epoch: epoch))?.reveals, [120100])
  }
  func testRestartRetainsReservedDeadlineAndRevision() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    let value = PairingSession.Accounting(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 1)
    XCTAssertEqual(try s.persistAccounting(value), value)
    XCTAssertEqual(accounting(try store(disk).restoreAccounting(now: 200, epoch: epoch))?.reveals, [120100])
  }
  func testOlderRevisionCannotOverwriteNewer() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    _ = try s.persistAccounting(.init(clockEpoch: epoch, reveals: [120100], lastTime: 100, revision: 2))
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, lastTime: 100, revision: 1)))
  }
  func testEqualRevisionDifferentValueCannotOverwrite() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [1], lastTime: 100, revision: 0)))
  }
  func testBootChangeAndRollbackPersistOneQuarantineBound() throws {
    for (nextTime, nextEpoch) in [(UInt64(50), epoch), (UInt64(1000), Data(repeating: 2, count: 16))] {
      let disk = Disk(), s = try store(disk)
      _ = s.restoreAccounting(now: 100, epoch: epoch)
      let first = accounting(try store(disk).restoreAccounting(now: nextTime, epoch: nextEpoch))
      XCTAssertEqual(first?.blockedUntil, nextTime + 86400000)
      let second = accounting(try store(disk).restoreAccounting(now: nextTime + 1, epoch: nextEpoch))
      XCTAssertEqual(second?.blockedUntil, first?.blockedUntil)
    }
  }
  func testConsumedApprovalDurableAndCannotConsumeTwiceAfterRestart() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    try s.consumeApproval(record())
    XCTAssertThrowsError(try store(disk).consumeApproval(record()))
    XCTAssertNotNil(disk.files[s.directory.appendingPathComponent("consumed-approvals.json")])
  }
  func testUnavailableConsumedListingCannotBecomeEmptyHistory() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    disk.failListing = true
    XCTAssertThrowsError(try s.consumeApproval(record()))
    XCTAssertNil(disk.files[s.directory.appendingPathComponent("consumed-approvals.json")])
  }
  func testConsumedWriteFailureAndMalformedGrantFailClosed() throws {
    let disk = Disk(), s = try store(disk)
    disk.failWrite = true
    XCTAssertThrowsError(try s.consumeApproval(record()))
    disk.failWrite = false
    var invalid = record(); invalid.sealedApproval = Data()
    XCTAssertThrowsError(try s.consumeApproval(invalid))
  }
  func testSuppressionFailsClosedAndSurvivesRestart() throws {
    let disk = Disk(), s = try store(disk)
    XCTAssertTrue(s.suppressed)
    try s.setSuppressed(false)
    XCTAssertFalse(try store(disk).suppressed)
    disk.failWrite = true
    XCTAssertThrowsError(try s.setSuppressed(true))
    XCTAssertTrue(s.suppressed)
  }
  func testSyncAncestorAndSymlinkPlacementRefused() throws {
    let disk = Disk()
    for sync in ["/private/tmp", "/private/tmp/pairing-data", "/private/tmp/pairing-data/Application Support/sync-pairing/sub"] {
      XCTAssertThrowsError(try PairingDurableStore(dataDirectory: URL(fileURLWithPath: "/private/tmp/pairing-data"), syncFolder: URL(fileURLWithPath: sync), firstInstallation: empty, io: disk), sync)
    }
  }
  func testNewPairingFolderCannotContainExistingPrivateStore() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initialization refused") }
    for folder in [URL(fileURLWithPath: "/"), root, root.appendingPathComponent("data"), s.directory, s.directory.appendingPathComponent("nested")] {
      XCTAssertThrowsError(try s.validatePlacement(pairingFolder: folder), folder.path)
    }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("data"))
    XCTAssertThrowsError(try s.validatePlacement(pairingFolder: alias))
    XCTAssertNoThrow(try s.validatePlacement(pairingFolder: root.appendingPathComponent("replacement")))
    XCTAssertEqual(accounting(s.restoreAccounting(now: 200, epoch: epoch))?.revision, 0)
  }
  func testPlacementRevalidationRefusesRedirectedPrivateDirectory() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    guard case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initialization refused") }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: s.directory)
    try FileManager.default.createSymbolicLink(at: s.directory, withDestinationURL: outside)
    XCTAssertThrowsError(try s.validatePlacement(pairingFolder: root.appendingPathComponent("replacement")))
  }
  func testRealDiskWritesPrivateModesAndReadback() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try PairingDurableStore(dataDirectory: root.appendingPathComponent("data"), syncFolder: root.appendingPathComponent("sync"), firstInstallation: empty)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    XCTAssertNoThrow(try PairingPOSIXDurableIO().prepare(s.directory))
    let file = s.directory.appendingPathComponent("accounting.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    if FileManager.default.fileExists(atPath: file.path) {
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: s.directory.path)[.posixPermissions] as? Int, 0o700)
    }
  }
  func testUncertainAccountAndUnknownHistoryCannotInitializeFresh() throws {
    let disk = Disk()
    let s = try PairingDurableStore(dataDirectory: URL(fileURLWithPath: "/private/tmp/pairing-data"), syncFolder: URL(fileURLWithPath: "/private/tmp/pairing-sync"), firstInstallation: .init(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: false), io: disk)
    if case .newInstallation = s.restoreAccounting(now: 100, epoch: epoch) { XCTFail("keychain failure became absence") }
    let other = Disk(), clean = try store(other)
    other.files[clean.directory.appendingPathComponent("prior-history")] = Data([1])
    if case .newInstallation = clean.restoreAccounting(now: 100, epoch: epoch) { XCTFail("history ignored") }
  }
  func testMalformedFutureRevealCannotBeAcknowledged() throws {
    let disk = Disk(), s = try store(disk)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, reveals: [UInt64.max], lastTime: 100, revision: 1)))
  }
  func testRealPrivatePathSymlinkCannotRedirectLedger() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let s = try PairingDurableStore(dataDirectory: data, syncFolder: root.appendingPathComponent("remote"), firstInstallation: empty)
    _ = s.restoreAccounting(now: 100, epoch: epoch)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: s.directory)
    try FileManager.default.createSymbolicLink(at: s.directory, withDestinationURL: outside)
    XCTAssertThrowsError(try s.persistAccounting(.init(clockEpoch: epoch, lastTime: 100, revision: 1)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("accounting.json").path))
  }
  func testBootClockStrictEpochAndCheckedConversion() throws {
    XCTAssertEqual(try PairingBootClock.epoch("00112233-4455-6677-8899-AABBCCDDEEFF"), Data([0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255]))
    XCTAssertThrowsError(try PairingBootClock.epoch(""))
    XCTAssertThrowsError(try PairingBootClock.epoch("not-a-uuid"))
    XCTAssertEqual(try PairingBootClock.milliseconds(ticks: 24000000, numerator: 125, denominator: 3), 1000)
    XCTAssertThrowsError(try PairingBootClock.milliseconds(ticks: 1, numerator: 1, denominator: 0))
    XCTAssertThrowsError(try PairingBootClock.milliseconds(ticks: UInt64.max, numerator: UInt32.max, denominator: 1))
    do {
      let live = try PairingBootClock.sample()
      XCTAssertEqual(live.epoch.count, 16)
      XCTAssertGreaterThan(live.milliseconds, 0)
    } catch PairingBootClock.Failure.unavailable {
      XCTAssertThrowsError(try PairingBootClock.sample())
    }
  }
}
