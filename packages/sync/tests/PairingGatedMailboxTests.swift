import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingGatedMailboxTests: XCTestCase {
  var root: URL!
  var folder: URL!
  let cid = SyncKeys(entropy: Data(count: 32)).chainTag

  override func setUpWithError() throws {
    root = SyncTestDirectory.url.appendingPathComponent("pairing-gated-\(UUID().uuidString)")
    folder = root.appendingPathComponent("provider")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func entry(_ kind: PairingSession.Kind = .approval) throws -> PairingSession.Entry {
    let rid = Data(repeating: 1, count: 16)
    let aid: Data? = kind == .request ? nil : Data(repeating: 2, count: 16)
    let mailboxKind = try XCTUnwrap(PairingMailbox.Kind(rawValue: kind.rawValue))
    let header = try PairingFormat.header(.init(type: kind.rawValue, bodyLength: mailboxKind.size - 60, cid: PairingFormat.cid(cid), rid: rid, aid: aid ?? Data(count: 16)))
    return .init(rid: rid, aid: aid, kind: kind, wire: header + Data(repeating: 0xa5, count: mailboxKind.size - 60))
  }

  func providerCopies(of bytes: Data) throws -> Int {
    let paths = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return paths.compactMap { $0 as? URL }.filter { (try? Data(contentsOf: $0)) == bytes }.count
  }

  func testRefusedAdmissionHasNoProviderReadableStagingOrCanonicalBytes() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    for kind in PairingSession.Kind.allCases {
      let value = try entry(kind)
      var inspected = false
      XCTAssertThrowsError(try box.publish(value) {
        inspected = true
        XCTAssertEqual(try? self.providerCopies(of: value.wire), 0)
        return false
      })
      XCTAssertTrue(inspected)
      XCTAssertEqual(try providerCopies(of: value.wire), 0)
    }
  }

  func testAdmittedExactBytesDeliverIdempotentlyAndConflictsRemainImmutable() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let value = try entry()
    XCTAssertEqual(try box.publish(value) {
      XCTAssertEqual(try? self.providerCopies(of: value.wire), 0)
      return true
    }, .written)
    XCTAssertEqual(try providerCopies(of: value.wire), 1)
    XCTAssertEqual(try box.publish(value, admit: { true }), .identical)
    var conflicting = value
    conflicting.wire[conflicting.wire.count - 1] ^= 1
    XCTAssertThrowsError(try box.publish(conflicting, admit: { true }))
    XCTAssertEqual(try providerCopies(of: value.wire), 1)
    XCTAssertEqual(try providerCopies(of: conflicting.wire), 0)
  }

  func testReplacedFolderIsRejectedBeforeAdmission() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let value = try entry()
    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("detached"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var admitted = false
    XCTAssertThrowsError(try box.publish(value) { admitted = true; return true })
    XCTAssertFalse(admitted)
    XCTAssertEqual(try providerCopies(of: value.wire), 0)
  }

  func testSymlinkedTreeIsRejectedWithoutAdmissionOrFallbackBytes() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let value = try entry()
    let target = root.appendingPathComponent("redirected")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(PairingMailbox.namespace), withDestinationURL: target)
    var admitted = false
    XCTAssertThrowsError(try box.publish(value) { admitted = true; return true })
    XCTAssertFalse(admitted)
    XCTAssertEqual(try providerCopies(of: value.wire), 0)
  }
  func testPollSharesByteAndEntryBudgetAcrossAllRequests() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    var requests: [Data] = []
    for requestByte in UInt8(1)...10 {
      let rid = Data(repeating: requestByte, count: 16)
      requests.append(rid)
      let directory = folder.appendingPathComponent(PairingMailbox.namespace).appendingPathComponent(cid).appendingPathComponent(PairingMailbox.hex(rid))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for offerByte in UInt8(1)...60 {
        let aid = Data(repeating: offerByte, count: 16)
        let header = try PairingFormat.header(.init(type: 6, bodyLength: 1100, cid: PairingFormat.cid(cid), rid: rid, aid: aid))
        try (header + Data(count: 1100)).write(to: directory.appendingPathComponent(PairingMailbox.filename(aid: aid, kind: .approval)))
      }
    }
    let result = box.poll(rids: requests)
    XCTAssertLessThanOrEqual(result.bytesRead, PairingMailbox.bytesPerPass)
    XCTAssertLessThanOrEqual(result.entries.count, PairingMailbox.entriesPerPass)
    XCTAssertLessThanOrEqual(Set(result.entries.map(\.rid)).count, PairingMailbox.requestsPerPass)
    XCTAssertTrue(result.truncated)
    XCTAssertFalse(box.poll().entries.isEmpty)
  }

  func testUnavailableAndReplacedFolderCannotMasqueradeAsEmptyPoll() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    XCTAssertFalse(box.poll().unavailable)
    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("detached"))
    XCTAssertTrue(box.poll().unavailable)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    XCTAssertTrue(box.poll().unavailable)
  }

  func testSymlinkedNamespaceCannotMasqueradeAsEmptyPoll() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let target = root.appendingPathComponent("redirected")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(PairingMailbox.namespace), withDestinationURL: target)
    XCTAssertTrue(box.poll().unavailable)
  }

  func testCleanupRefusesAttackerReplacementWithMatchingHeader() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let value = try entry()
    try box.publish(value, admit: { true })
    let path = folder.appendingPathComponent(PairingMailbox.namespace).appendingPathComponent(cid).appendingPathComponent(PairingMailbox.hex(value.rid)).appendingPathComponent(PairingMailbox.filename(aid: value.aid, kind: .approval))
    var replacement = value.wire
    replacement[replacement.count - 1] ^= 1
    try replacement.write(to: path)
    box.remove(expected: [value])
    XCTAssertEqual(try? Data(contentsOf: path), replacement)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.wire.write(to: path)
    box.remove(expected: [value])
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
  }

  func testCleanupCannotDeleteFromReplacementFolder() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let value = try entry()
    try box.publish(value, admit: { true })
    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("detached"))
    let directory = folder.appendingPathComponent(PairingMailbox.namespace).appendingPathComponent(cid).appendingPathComponent(PairingMailbox.hex(value.rid))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(PairingMailbox.filename(aid: value.aid, kind: .approval))
    try value.wire.write(to: path)
    box.remove(expected: [value])
    XCTAssertEqual(try? Data(contentsOf: path), value.wire)
  }

  func testPinnedJoinPollAlsoDiscoversForeignRequestWithinSharedBudget() throws {
    let box = try PairingMailbox(folder: folder, cid: cid)
    let joining = Data(repeating: 8, count: 16)
    let foreign = try entry(.request)
    try box.publish(foreign, admit: { true })
    let result = box.poll(rids: [joining])
    XCTAssertTrue(result.entries.contains { $0.rid == foreign.rid && $0.kind == .request })
    XCTAssertLessThanOrEqual(result.bytesRead, PairingMailbox.bytesPerPass)
  }

}
