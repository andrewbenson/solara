import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class SyncDiscoveryTests: XCTestCase {
  var root: URL!
  var folder: URL!

  override func setUpWithError() throws {
    root = SyncTestDirectory.url.appendingPathComponent("sync-discovery-\(UUID().uuidString)", isDirectory: true)
    folder = root.appendingPathComponent("Solara Sync", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: root)
    }
  }

  func tag(_ byte: UInt8) -> String { SyncKeys(entropy: Data(repeating: byte, count: 32)).chainTag }

  func discover(_ folder: URL, fileSystem: DiscoveryFileSystem = LiveDiscoveryFileSystem(), timeout: Duration = .seconds(5), sleep: @escaping SyncDiscovery.Sleep = SyncDiscovery.continuousSleep) -> SyncDiscovery.Result {
    let done = expectation(description: "discovery")
    var result: SyncDiscovery.Result?
    SyncDiscovery(folder: folder, timeout: timeout, fileSystem: fileSystem, sleep: sleep).run {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return result ?? .found([])
  }

  func testAnEmptyFolderIsEmptyNotAnError() {
    XCTAssertEqual(discover(folder), .empty)
  }

  func testAMissingFolderIsEmptyAndIsNotCreated() {
    let missing = root.appendingPathComponent("Nope", isDirectory: true)
    XCTAssertEqual(discover(missing), .empty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testAFolderStillInTheCloudAsAPlaceholderNeedsHydration() throws {
    let missing = root.appendingPathComponent("Later", isDirectory: true)
    try Data().write(to: root.appendingPathComponent(".Later.icloud"))
    let live = RecordingFileSystem(wrapping: LiveDiscoveryFileSystem())
    XCTAssertEqual(discover(missing, fileSystem: live), .needsHydration)
    XCTAssertEqual(live.downloads, [missing])
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testANonregularRootPlaceholderCannotAffirmAnEmptyFolder() throws {
    let missing = root.appendingPathComponent("Later", isDirectory: true)
    let placeholder = root.appendingPathComponent(".Later.icloud")
    try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
    XCTAssertEqual(discover(missing), .unavailable)
    try FileManager.default.removeItem(at: placeholder)
    try FileManager.default.createSymbolicLink(at: placeholder, withDestinationURL: folder)
    XCTAssertEqual(discover(missing), .unavailable)
  }

  func testCanonicalChainDirectoriesAreCandidatesWithTheirNewestActivity() throws {
    let a = tag(1), b = tag(2)
    let old = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_700_000_500)
    for (name, date) in [(a, old), (b, old)] {
      let chain = folder.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: chain.appendingPathComponent("scope"), withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: chain.appendingPathComponent("scope").path)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: chain.path)
    }
    try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: folder.appendingPathComponent(b).appendingPathComponent("scope").path)
    guard case .found(let candidates) = discover(folder) else { return XCTFail("no candidates") }
    XCTAssertEqual(candidates.map(\.cid), [a, b].sorted())
    XCTAssertEqual(candidates.first { $0.cid == a }?.lastActivity, old)
    XCTAssertEqual(candidates.first { $0.cid == b }?.lastActivity, newer)
  }

  func testNonCanonicalLinkedAndFileShapedTagsAreNotCandidates() throws {
    let real = tag(1)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(real), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(tag(3).uppercased()), withIntermediateDirectories: true)
    var trailing = Array(tag(4))
    trailing[25] = trailing[25] == "b" ? "c" : "b"
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(String(trailing)), withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(tag(5)))
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(tag(6)), withDestinationURL: elsewhere)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(PairingMailbox.namespace), withIntermediateDirectories: true)
    guard case .found(let candidates) = discover(folder) else { return XCTFail("no candidates") }
    XCTAssertEqual(candidates.map(\.cid), [real])
  }

  func testALinkedFolderIsNotFollowed() throws {
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(tag(1)), withIntermediateDirectories: true)
    let linked = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
    XCTAssertEqual(discover(linked), .permissionDenied)
  }

  func testAnUnreadableFolderIsPermissionDenied() throws {
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(tag(1)), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    XCTAssertEqual(discover(folder), .permissionDenied)
  }

  func testCandidatesAreCappedByTheEntryBudget() throws {
    for n in 0..<(SyncDiscovery.entriesPerPass + 40) {
      try FileManager.default.createDirectory(at: folder.appendingPathComponent("junk-\(n)"), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(tag(1)), withIntermediateDirectories: true)
    let fake = RecordingFileSystem(wrapping: LiveDiscoveryFileSystem())
    _ = discover(folder, fileSystem: fake)
    XCTAssertLessThanOrEqual(fake.largestListing, SyncDiscovery.entriesPerPass)
  }

  func testUnavailableAndDatalessListingsAreDistinctResults() {
    XCTAssertEqual(discover(folder, fileSystem: ScriptedFileSystem(.unavailable)), .unavailable)
    XCTAssertEqual(discover(folder, fileSystem: ScriptedFileSystem(.denied)), .permissionDenied)
    let dataless = ScriptedFileSystem(.listing([], dataless: true, truncated: false))
    XCTAssertEqual(discover(folder, fileSystem: dataless), .needsHydration)
    XCTAssertEqual(dataless.downloads, [folder])
    let partial = ScriptedFileSystem(.listing([DiscoveryEntry(name: tag(1), isRealDirectory: true, activity: nil)], dataless: true, truncated: false))
    XCTAssertEqual(discover(folder, fileSystem: partial), .foundIncomplete([SyncDiscovery.Candidate(cid: tag(1), lastActivity: nil)]))
    XCTAssertEqual(partial.downloads, [folder])
  }

  func testTheDeadlineRunsOnTheContinuousSleepItIsGiven() {
    let hung = ScriptedFileSystem(.listing([], dataless: false, truncated: false), blocked: true)
    defer { hung.release() }
    let start = ContinuousClock.now
    XCTAssertEqual(discover(folder, fileSystem: hung, timeout: .seconds(3600), sleep: { _ in }), .timedOut)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
  }

  func testEveryCallerWaitingOnTheWorkerGetsItsAnswer() {
    let hung = ScriptedFileSystem(.listing([DiscoveryEntry(name: tag(1), isRealDirectory: true, activity: nil)], dataless: false, truncated: false), blocked: true)
    let lock = NSLock()
    var results: [String: SyncDiscovery.Result] = [:]
    let all = expectation(description: "three answers")
    all.expectedFulfillmentCount = 3
    for name in ["a", "b", "c"] {
      SyncDiscovery(folder: folder, timeout: .seconds(4), fileSystem: hung).run { result in
        lock.withLock { results[name] = result }
        all.fulfill()
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { hung.release() }
    wait(for: [all], timeout: 8)
    let found = SyncDiscovery.Result.found([SyncDiscovery.Candidate(cid: tag(1), lastActivity: nil)])
    XCTAssertEqual(lock.withLock { results }, ["a": found, "b": found, "c": found])
  }

  func testAnIncompleteListingWithNoChainIsUnavailableNotEmpty() throws {
    XCTAssertEqual(discover(folder, fileSystem: ScriptedFileSystem(.listing([], dataless: false, truncated: true))), .unavailable)
    for n in 0..<50 {
      let junk = folder.appendingPathComponent(String(format: "zz%024d", n))
      for c in 0..<40 { try FileManager.default.createDirectory(at: junk.appendingPathComponent("c\(c)"), withIntermediateDirectories: true) }
    }
    for n in 0..<300 { try Data().write(to: folder.appendingPathComponent("junk-\(n)")) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(tag(1)), withIntermediateDirectories: true)
    let result = discover(folder)
    XCTAssertTrue(result == .unavailable || result == .found([SyncDiscovery.Candidate(cid: tag(1), lastActivity: result.firstActivity)]), "\(result)")
  }

  func testAChainStillInTheCloudNeedsHydration() throws {
    try Data().write(to: folder.appendingPathComponent(".\(tag(1)).icloud"))
    let live = RecordingFileSystem(wrapping: LiveDiscoveryFileSystem())
    XCTAssertEqual(discover(folder, fileSystem: live), .needsHydration)
    XCTAssertEqual(live.downloads, [folder.appendingPathComponent(tag(1), isDirectory: true)])
  }

  func testAHungProviderTimesOutAndNeverStartsASecondWorker() {
    let hung = ScriptedFileSystem(.listing([DiscoveryEntry(name: tag(1), isRealDirectory: true, activity: nil)], dataless: false, truncated: false), blocked: true)
    let start = ContinuousClock.now
    XCTAssertEqual(discover(folder, fileSystem: hung, timeout: .milliseconds(200)), .timedOut)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    XCTAssertEqual(discover(folder, fileSystem: hung, timeout: .milliseconds(200)), .timedOut)
    XCTAssertEqual(hung.scans, 1)
    hung.release()
    XCTAssertEqual(discover(folder, fileSystem: hung, timeout: .seconds(2)), .found([SyncDiscovery.Candidate(cid: tag(1), lastActivity: nil)]))
    XCTAssertEqual(hung.scans, 2)
  }

  func testALateResultFromAnAbandonedWorkerIsDropped() {
    let hung = ScriptedFileSystem(.listing([DiscoveryEntry(name: tag(1), isRealDirectory: true, activity: nil)], dataless: false, truncated: false), blocked: true)
    var results: [SyncDiscovery.Result] = []
    let done = expectation(description: "first")
    SyncDiscovery(folder: folder, timeout: .milliseconds(100), fileSystem: hung).run {
      results.append($0)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    hung.release()
    let settle = expectation(description: "settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
    wait(for: [settle], timeout: 5)
    XCTAssertEqual(results, [.timedOut])
  }
}

extension SyncDiscovery.Result {
  var firstActivity: Date? {
    if case .found(let candidates) = self { return candidates.first?.lastActivity }
    return nil
  }
}

final class RecordingFileSystem: DiscoveryFileSystem {
  let wrapped: DiscoveryFileSystem
  private(set) var largestListing = 0
  init(wrapping wrapped: DiscoveryFileSystem) { self.wrapped = wrapped }
  func scan(_ folder: URL, limit: Int) -> DiscoveryScan {
    let scan = wrapped.scan(folder, limit: limit)
    if case .listing(let entries, _, _) = scan { largestListing = max(largestListing, entries.count) }
    return scan
  }
  private(set) var downloads: [URL] = []
  func requestDownload(_ url: URL) {
    downloads.append(url)
    wrapped.requestDownload(url)
  }
}

final class ScriptedFileSystem: DiscoveryFileSystem {
  let answer: DiscoveryScan
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var blocked: Bool
  private var scanCount = 0
  private var requested: [URL] = []

  init(_ answer: DiscoveryScan, blocked: Bool = false) {
    self.answer = answer
    self.blocked = blocked
  }

  var scans: Int { lock.withLock { scanCount } }
  var downloads: [URL] { lock.withLock { requested } }

  func release() {
    lock.withLock { blocked = false }
    gate.signal()
  }

  func scan(_ folder: URL, limit: Int) -> DiscoveryScan {
    let wait = lock.withLock { () -> Bool in
      scanCount += 1
      return blocked
    }
    if wait { gate.wait() }
    return answer
  }

  func requestDownload(_ url: URL) { lock.withLock { requested.append(url) } }
}
