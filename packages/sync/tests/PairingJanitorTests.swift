import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingJanitorTests: XCTestCase {
  private final class Mailbox: PairingCoordinatingMailbox {
    var pairingCID = Base32.encode(Data(repeating: 1, count: 16))
    var pairingFolderIdentity = Data("1:2".utf8)
    var pairingFolder = URL(fileURLWithPath: "/test-mailbox")
    var current: [String: PairingSession.Entry] = [:]
    var attempts: [PairingSession.Entry] = []
    var beforeRemove: (() -> Void)?
    func key(_ entry: PairingSession.Entry) -> String { PairingMailbox.hex(entry.rid) + PairingMailbox.hex(entry.aid ?? Data()) + String(entry.kind.rawValue) }
    func remove(expected: [PairingSession.Entry]) {
      beforeRemove?()
      for entry in expected {
        attempts.append(entry)
        if current[key(entry)] == entry { current.removeValue(forKey: key(entry)) }
      }
    }
    func poll(rids: Set<Data>) throws -> [PairingSession.Entry] { Array(current.values) }
    func publish(_ entry: PairingSession.Entry, admit: () -> Bool) throws -> PairingMailbox.WriteOutcome { throw PairingMailbox.Failure.pending }
  }
  private let day: UInt64 = 24 * 60 * 60 * 1000
  private func entry(_ index: UInt16 = 1, fill: UInt8 = 7) -> PairingSession.Entry {
    let rid = Data([UInt8(index >> 8), UInt8(index & 255)] + Array(repeating: UInt8(1), count: 14))
    return .init(rid: rid, aid: nil, kind: .request, wire: Data(repeating: fill, count: 197))
  }

  func testOnlyLocallyObservedDayCanAuthorizeBoundedCleanup() {
    let janitor = PairingJanitor()
    let mailbox = Mailbox()
    let packet = entry()
    mailbox.current[mailbox.key(packet)] = packet
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: 900), 0)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: 900 + day - 1), 0)
    XCTAssertFalse(mailbox.current.isEmpty)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: 900 + day), 1)
    XCTAssertTrue(mailbox.current.isEmpty)
  }

  func testRestartAndFolderIdentityChangeDelayCleanupAnotherDay() {
    let mailbox = Mailbox()
    let packet = entry()
    let janitor = PairingJanitor()
    _ = janitor.observe(entries: [packet], mailbox: mailbox, now: 0)
    XCTAssertEqual(PairingJanitor().observe(entries: [packet], mailbox: mailbox, now: day), 0)
    mailbox.pairingFolderIdentity = Data("1:3".utf8)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: day), 0)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: day * 2), 1)
    XCTAssertEqual(mailbox.attempts, [packet])
  }

  func testChangedBytesKeepFirstSeenButRemovalCapturesCurrentBytesOnly() {
    let janitor = PairingJanitor()
    let mailbox = Mailbox()
    let original = entry(fill: 1)
    let replaced = entry(fill: 2)
    _ = janitor.observe(entries: [original], mailbox: mailbox, now: 0)
    mailbox.current[mailbox.key(replaced)] = replaced
    XCTAssertEqual(janitor.observe(entries: [replaced], mailbox: mailbox, now: day), 1)
    XCTAssertEqual(mailbox.attempts, [replaced])
    XCTAssertTrue(mailbox.current.isEmpty)
  }

  func testReplacementBetweenObservationAndUnlinkSurvivesExpectedByteGuard() {
    let janitor = PairingJanitor()
    let mailbox = Mailbox()
    let original = entry(fill: 1)
    let replaced = entry(fill: 2)
    mailbox.current[mailbox.key(original)] = original
    _ = janitor.observe(entries: [original], mailbox: mailbox, now: 0)
    mailbox.beforeRemove = { mailbox.current[mailbox.key(replaced)] = replaced }
    XCTAssertEqual(janitor.observe(entries: [original], mailbox: mailbox, now: day), 1)
    XCTAssertEqual(mailbox.current[mailbox.key(replaced)], replaced)
  }

  func testFloodBoundsTrackingAndCleanupAndDoesNotAgeUnobservedPaths() {
    let janitor = PairingJanitor()
    let mailbox = Mailbox()
    let flood = (1...600).map { entry(UInt16($0)) }
    _ = janitor.observe(entries: flood, mailbox: mailbox, now: 0)
    let count = janitor.observe(entries: flood, mailbox: mailbox, now: day)
    XCTAssertEqual(count, PairingMailbox.entriesPerPass)
    XCTAssertEqual(mailbox.attempts.count, PairingMailbox.entriesPerPass)
    XCTAssertEqual(janitor.observe(entries: Array(flood.dropFirst(PairingMailbox.entriesPerPass)), mailbox: mailbox, now: day * 2), 0)
  }

  func testMissingOrRegressedClockCannotAuthorizeDeletion() {
    let janitor = PairingJanitor()
    let mailbox = Mailbox()
    let packet = entry()
    _ = janitor.observe(entries: [packet], mailbox: mailbox, now: 500)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: nil), 0)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: 499), 0)
    XCTAssertEqual(janitor.observe(entries: [packet], mailbox: mailbox, now: 500 + day), 1)
  }
}

extension PairingJanitorTests {
  func testRealMailboxKeepsReplacementAndOrdinaryScopeThenRemovesExactAgedPacket() throws {
    let root = SyncTestDirectory.url.appendingPathComponent("janitor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cid = SyncKeys(entropy: Data(repeating: 31, count: 32)).chainTag
    let rid = Data(repeating: 1, count: 16)
    let directory = root.appendingPathComponent(PairingMailbox.namespace).appendingPathComponent(cid).appendingPathComponent(PairingMailbox.hex(rid))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let header = try PairingFormat.header(.init(type: 1, bodyLength: 137, cid: PairingFormat.cid(cid), rid: rid, aid: Data(count: 16)))
    let original = header + Data(repeating: 1, count: 137)
    let replacement = header + Data(repeating: 2, count: 137)
    let file = directory.appendingPathComponent("request.spj")
    try original.write(to: file)
    let ordinary = root.appendingPathComponent("ordinary-scope.nns")
    try Data("ordinary".utf8).write(to: ordinary)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
    let mailbox = try PairingMailbox(folder: root, cid: cid)
    let janitor = PairingJanitor()
    let before = try mailbox.poll(rids: Set<Data>())
    XCTAssertEqual(before.count, 1)
    XCTAssertEqual(janitor.observe(entries: before, mailbox: mailbox, now: 0), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    try replacement.write(to: file)
    XCTAssertEqual(janitor.observe(entries: before, mailbox: mailbox, now: day), 1)
    XCTAssertEqual(try Data(contentsOf: file), replacement)
    let current = try mailbox.poll(rids: Set<Data>())
    XCTAssertEqual(current.count, 1)
    XCTAssertEqual(janitor.observe(entries: current, mailbox: mailbox, now: day), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(try Data(contentsOf: ordinary), Data("ordinary".utf8))
  }
}
