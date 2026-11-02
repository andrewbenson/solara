import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingMailboxTests: XCTestCase {
  typealias Kind = PairingMailbox.Kind
  var root: URL!
  var folder: URL!
  var outside: URL!
  let cid = SyncKeys(entropy: Data(count: 32)).chainTag

  override func setUpWithError() throws {
    root = SyncTestDirectory.url.appendingPathComponent("pairing-mailbox-\(UUID().uuidString)", isDirectory: true)
    folder = root.appendingPathComponent("Solara Sync", isDirectory: true)
    outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
  func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
  var namespaceURL: URL { folder.appendingPathComponent(PairingMailbox.namespace, isDirectory: true) }
  func ridURL(_ rid: Data) -> URL { namespaceURL.appendingPathComponent(cid).appendingPathComponent(hex(rid)) }

  func wire(_ kind: Kind, rid: Data, aid: Data?, fill: UInt8 = 7, cid: String? = nil) throws -> Data {
    let header = try PairingFormat.header(PairingFormat.Header(type: kind.rawValue, bodyLength: kind.size - 60, cid: PairingFormat.cid(cid ?? self.cid), rid: rid, aid: aid ?? Data(count: 16)))
    return header + Data(repeating: fill, count: kind.size - 60)
  }

  func mailbox() throws -> PairingMailbox { try PairingMailbox(folder: folder, cid: cid) }

  func plant(_ data: Data, rid: Data, name: String) throws {
    try FileManager.default.createDirectory(at: ridURL(rid), withIntermediateDirectories: true)
    try data.write(to: ridURL(rid).appendingPathComponent(name))
  }

  func testKindSizesMatchPieceOneBodies() {
    XCTAssertEqual(Kind.allCases.map(\.size), [197, 233, 156, 156, 124, 1160, 156, 125, 125, 376, 376])
    XCTAssertEqual(Kind.allCases.map(\.filename), ["request", "offer", "select", "reveal", "confirm", "approval", "receipt", "j-terminal", "t-terminal", "j-name", "t-name"])
  }

  func testWriteThenReadEveryKind() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    for kind in Kind.allCases {
      XCTAssertEqual(try box.write(wire(kind, rid: rid, aid: kind == .request ? nil : aid), rid: rid, aid: kind == .request ? nil : aid, kind: kind), .written)
    }
    XCTAssertEqual(box.requests(excluding: []), [rid])
    let listing = box.read(rid: rid)
    XCTAssertEqual(Set(listing.entries.map(\.kind)), Set(Kind.allCases))
    XCTAssertEqual(listing.skipped, 0)
    XCTAssertFalse(listing.truncated)
    for entry in listing.entries {
      XCTAssertEqual(entry.rid, rid)
      XCTAssertEqual(entry.aid, entry.kind == .request ? nil : aid)
      XCTAssertEqual(entry.wire, try wire(entry.kind, rid: rid, aid: entry.aid))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: ridURL(rid).appendingPathComponent("request.spj").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: ridURL(rid).appendingPathComponent(hex(aid) + ".j-terminal.spj").path))
  }

  func testRewriteIsIdempotentOnlyForIdenticalBytesAndNeverReplaces() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    let first = try wire(.offer, rid: rid, aid: aid, fill: 1)
    XCTAssertEqual(try box.write(first, rid: rid, aid: aid, kind: .offer), .written)
    XCTAssertEqual(try box.write(first, rid: rid, aid: aid, kind: .offer), .identical)
    XCTAssertThrowsError(try box.write(wire(.offer, rid: rid, aid: aid, fill: 2), rid: rid, aid: aid, kind: .offer)) { XCTAssertEqual($0 as? PairingMailbox.Failure, .conflict) }
    XCTAssertEqual(box.read(rid: rid).entries.map(\.wire), [first])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ridURL(rid).path), [hex(aid) + ".offer.spj"])
  }

  func testWriteRefusesBytesThatDontMatchTheirPathOrSize() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    XCTAssertThrowsError(try box.write(wire(.offer, rid: rid, aid: aid).dropLast(), rid: rid, aid: aid, kind: .offer))
    XCTAssertThrowsError(try box.write(wire(.offer, rid: id(3), aid: aid), rid: rid, aid: aid, kind: .offer))
    XCTAssertThrowsError(try box.write(wire(.select, rid: rid, aid: aid), rid: rid, aid: aid, kind: .offer))
    XCTAssertThrowsError(try box.write(wire(.request, rid: rid, aid: nil), rid: rid, aid: aid, kind: .request))
    XCTAssertThrowsError(try box.write(wire(.offer, rid: rid, aid: aid), rid: rid, aid: nil, kind: .offer))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ridURL(rid).appendingPathComponent(hex(aid) + ".offer.spj").path))
  }

  func testTruncatedOversizeAndMislabelledFilesAreSkipped() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    let offer = try wire(.offer, rid: rid, aid: aid)
    try plant(offer.dropLast(), rid: rid, name: hex(aid) + ".offer.spj")
    try plant(offer + Data(count: 9000), rid: rid, name: hex(id(3)) + ".offer.spj")
    try plant(wire(.offer, rid: rid, aid: id(5)), rid: rid, name: hex(id(4)) + ".offer.spj")
    try plant(wire(.select, rid: rid, aid: id(6)), rid: rid, name: hex(id(6)) + ".offer.spj")
    try plant(wire(.offer, rid: id(9), aid: id(7)), rid: rid, name: hex(id(7)) + ".offer.spj")
    var lying = try wire(.offer, rid: rid, aid: id(8))
    lying[11] = 0xff
    try plant(lying, rid: rid, name: hex(id(8)) + ".offer.spj")
    let listing = box.read(rid: rid)
    XCTAssertEqual(listing.entries, [])
    XCTAssertEqual(listing.skipped, 6)
  }

  func testUnknownNamesCaseVariantsAndExtraComponentsAreIgnored() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(0xab)
    try plant(wire(.request, rid: rid, aid: nil), rid: rid, name: "Request.spj")
    try plant(wire(.offer, rid: rid, aid: aid), rid: rid, name: hex(aid).uppercased() + ".offer.spj")
    try plant(wire(.offer, rid: rid, aid: aid), rid: rid, name: hex(aid) + ".Offer.spj")
    try plant(Data("hello".utf8), rid: rid, name: "notes.txt")
    try FileManager.default.createDirectory(at: ridURL(rid).appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: namespaceURL.appendingPathComponent(cid).appendingPathComponent(hex(id(0xcd)).uppercased()), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: namespaceURL.appendingPathComponent(cid).appendingPathComponent("not-a-rid"), withIntermediateDirectories: true)
    XCTAssertEqual(box.requests(excluding: []), [rid])
    XCTAssertEqual(box.read(rid: rid).entries, [])
    switch Result(catching: { try box.write(wire(.request, rid: rid, aid: nil), rid: rid, aid: nil, kind: .request) }) {
    case .success(let outcome):
      XCTAssertEqual(outcome, .written)
      XCTAssertEqual(box.read(rid: rid).entries.map(\.kind), [.request])
    case .failure:
      XCTAssertEqual(box.read(rid: rid).entries, [])
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ridURL(rid).path).contains("Request.spj"))
    }
  }

  func testSymlinkedDirectoriesAndFilesAreNeverFollowed() throws {
    let rid = id(1), aid = id(2)
    try FileManager.default.createDirectory(at: outside.appendingPathComponent("r"), withIntermediateDirectories: true)
    try wire(.request, rid: id(4), aid: nil).write(to: outside.appendingPathComponent("r/request.spj"))
    try wire(.offer, rid: rid, aid: aid).write(to: outside.appendingPathComponent("offer"))
    try FileManager.default.createDirectory(at: namespaceURL.appendingPathComponent(cid), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: namespaceURL.appendingPathComponent(cid).appendingPathComponent(hex(id(4))), withDestinationURL: outside.appendingPathComponent("r"))
    try FileManager.default.createDirectory(at: ridURL(rid), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ridURL(rid).appendingPathComponent(hex(aid) + ".offer.spj"), withDestinationURL: outside.appendingPathComponent("offer"))
    let box = try mailbox()
    XCTAssertEqual(box.requests(excluding: []), [rid])
    XCTAssertEqual(box.read(rid: id(4)).entries, [])
    XCTAssertEqual(box.read(rid: rid).entries, [])
    XCTAssertEqual(box.read(rid: rid).skipped, 1)
    XCTAssertThrowsError(try box.write(wire(.request, rid: id(4), aid: nil), rid: id(4), aid: nil, kind: .request))
    XCTAssertThrowsError(try box.write(wire(.offer, rid: rid, aid: aid), rid: rid, aid: aid, kind: .offer))
    box.remove(rid: rid, files: [(aid, .offer)])
    box.remove(rid: id(4), files: [(nil, .request)])
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("offer").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("r/request.spj").path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(), ["offer", "r"])
  }

  func testSymlinkedNamespaceOrChainDirectoryRefusesEveryOperation() throws {
    for linked in ["namespace", "cid"] {
      try setUpWithError()
      let target = outside.appendingPathComponent("t", isDirectory: true)
      try FileManager.default.createDirectory(at: target.appendingPathComponent(hex(id(1))), withIntermediateDirectories: true)
      try wire(.request, rid: id(1), aid: nil).write(to: target.appendingPathComponent(hex(id(1))).appendingPathComponent("request.spj"))
      if linked == "namespace" {
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("ns"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target, to: outside.appendingPathComponent("ns").appendingPathComponent(cid))
        try FileManager.default.createSymbolicLink(at: namespaceURL, withDestinationURL: outside.appendingPathComponent("ns"))
      } else {
        try FileManager.default.createDirectory(at: namespaceURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: namespaceURL.appendingPathComponent(cid), withDestinationURL: target)
      }
      let box = try mailbox()
      XCTAssertEqual(box.requests(excluding: []), [], linked)
      XCTAssertEqual(box.read(rid: id(1)).entries, [], linked)
      XCTAssertThrowsError(try box.write(wire(.request, rid: id(2), aid: nil), rid: id(2), aid: nil, kind: .request), linked)
      box.remove(rid: id(1), files: [(nil, .request)])
      let survivor = linked == "namespace" ? outside.appendingPathComponent("ns").appendingPathComponent(cid) : target
      XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.appendingPathComponent(hex(id(1))).appendingPathComponent("request.spj").path), linked)
      XCTAssertFalse(FileManager.default.fileExists(atPath: survivor.appendingPathComponent(hex(id(2))).path), linked)
      try tearDownWithError()
    }
  }

  func testHardLinkedMessageFilesAreSkipped() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    let original = outside.appendingPathComponent("offer")
    try wire(.offer, rid: rid, aid: aid).write(to: original)
    try FileManager.default.createDirectory(at: ridURL(rid), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: original, to: ridURL(rid).appendingPathComponent(hex(aid) + ".offer.spj"))
    XCTAssertEqual(box.read(rid: rid).entries, [])
    XCTAssertEqual(box.read(rid: rid).skipped, 1)
  }

  func testFloodedNamespaceIsReadInBoundedPasses() throws {
    let box = try mailbox()
    for n in 0..<300 {
      var rid = id(0)
      rid[14] = UInt8(n >> 8)
      rid[15] = UInt8(n & 255)
      rid[0] = 1
      try FileManager.default.createDirectory(at: ridURL(rid), withIntermediateDirectories: true)
    }
    let first = box.requests(excluding: [])
    XCTAssertEqual(first.count, 8)
    let second = box.requests(excluding: Set(first))
    XCTAssertEqual(second.count, 8)
    XCTAssertTrue(Set(first).isDisjoint(with: second))
  }

  func testFloodedRequestDirectoryIsCappedByEntriesAndBytes() throws {
    let box = try mailbox()
    let rid = id(1)
    for n in 0..<300 { try plant(Data("x".utf8), rid: rid, name: "junk-\(n)") }
    let junk = box.read(rid: rid)
    XCTAssertTrue(junk.truncated)
    XCTAssertLessThanOrEqual(junk.skipped, PairingMailbox.entriesPerPass)

    let heavy = id(2)
    for n in 0..<60 {
      var aid = id(3)
      aid[15] = UInt8(n)
      try plant(wire(.approval, rid: heavy, aid: aid), rid: heavy, name: hex(aid) + ".approval.spj")
    }
    let listing = box.read(rid: heavy)
    XCTAssertTrue(listing.truncated)
    XCTAssertLessThanOrEqual(listing.entries.reduce(0) { $0 + $1.wire.count }, PairingMailbox.bytesPerPass)
    XCTAssertEqual(listing.entries.count, PairingMailbox.bytesPerPass / Kind.approval.size)
  }

  func testBadHeadersStillSpendTheByteBudget() throws {
    let box = try mailbox()
    let rid = id(1)
    for n in 0..<100 {
      var aid = id(3)
      aid[15] = UInt8(n)
      try plant(Data(count: Kind.approval.size), rid: rid, name: hex(aid) + ".approval.spj")
    }
    let listing = box.read(rid: rid)
    XCTAssertEqual(listing.entries, [])
    XCTAssertTrue(listing.truncated)
    XCTAssertLessThanOrEqual(listing.bytesRead, PairingMailbox.bytesPerPass)
  }

  func testACaseVariantIsNeverTakenForOurFile() throws {
    let box = try mailbox()
    let rid = id(1)
    let request = try wire(.request, rid: rid, aid: nil)
    try plant(request, rid: rid, name: "Request.spj")
    guard FileManager.default.fileExists(atPath: ridURL(rid).appendingPathComponent("request.spj").path) else {
      XCTAssertEqual(try box.write(request, rid: rid, aid: nil, kind: .request), .written)
      return
    }
    XCTAssertThrowsError(try box.write(request, rid: rid, aid: nil, kind: .request))
    box.remove(rid: rid, files: [(nil, .request)])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ridURL(rid).path), ["Request.spj"])
  }

  func testRemoveLeavesFilesThatArentValidProtocolFiles() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    try plant(Data("not ours".utf8), rid: rid, name: hex(aid) + ".offer.spj")
    try plant(Data(count: Kind.select.size), rid: rid, name: hex(aid) + ".select.spj")
    try plant(wire(.reveal, rid: id(9), aid: aid), rid: rid, name: hex(aid) + ".reveal.spj")
    box.remove(rid: rid, files: [(aid, .offer), (aid, .select), (aid, .reveal)])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ridURL(rid).path).sorted(), [hex(aid) + ".offer.spj", hex(aid) + ".reveal.spj", hex(aid) + ".select.spj"])
  }

  func testWriteWontShadowAFileStillInTheCloud() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    try plant(Data(), rid: rid, name: "." + hex(aid) + ".offer.spj.icloud")
    XCTAssertThrowsError(try box.write(wire(.offer, rid: rid, aid: aid), rid: rid, aid: aid, kind: .offer)) { XCTAssertEqual($0 as? PairingMailbox.Failure, .pending) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: ridURL(rid).appendingPathComponent(hex(aid) + ".offer.spj").path))
  }

  func testICloudPlaceholdersAreReportedPending() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    try plant(Data(), rid: rid, name: "." + hex(aid) + ".offer.spj.icloud")
    try plant(Data(), rid: rid, name: ".request.spj.icloud")
    try plant(Data(), rid: rid, name: "." + hex(aid) + ".bogus.spj.icloud")
    let listing = box.read(rid: rid)
    XCTAssertEqual(listing.entries, [])
    XCTAssertEqual(Set(listing.pending.map { "\($0.aid.map(hex) ?? "-")/\($0.kind)" }), ["-/request", "\(hex(aid))/offer"])
  }

  func testRemoveDeletesOnlyTheNamedProtocolFilesAndAnEmptyRequestDirectory() throws {
    let box = try mailbox()
    let rid = id(1), aid = id(2)
    try box.write(wire(.request, rid: rid, aid: nil), rid: rid, aid: nil, kind: .request)
    try box.write(wire(.offer, rid: rid, aid: aid), rid: rid, aid: aid, kind: .offer)
    try plant(Data("keep".utf8), rid: rid, name: "notes.txt")
    let chain = folder.appendingPathComponent(cid).appendingPathComponent("scope")
    try FileManager.default.createDirectory(at: chain, withIntermediateDirectories: true)
    try Data("chain".utf8).write(to: chain.appendingPathComponent("a.nns"))
    box.remove(rid: rid, files: [(aid, .offer), (nil, .request)])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ridURL(rid).path), ["notes.txt"])
    try FileManager.default.removeItem(at: ridURL(rid).appendingPathComponent("notes.txt"))
    try box.write(wire(.request, rid: rid, aid: nil), rid: rid, aid: nil, kind: .request)
    box.remove(rid: rid, files: [(nil, .request)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: ridURL(rid).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: chain.appendingPathComponent("a.nns").path))
  }

  func testFolderAndChainTagAreValidated() throws {
    XCTAssertThrowsError(try PairingMailbox(folder: folder, cid: cid.uppercased()))
    XCTAssertThrowsError(try PairingMailbox(folder: folder, cid: "../" + String(cid.dropFirst(3))))
    XCTAssertThrowsError(try PairingMailbox(folder: root.appendingPathComponent("missing"), cid: cid))
    let linked = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
    XCTAssertThrowsError(try PairingMailbox(folder: linked, cid: cid))
    let file = root.appendingPathComponent("file")
    try Data().write(to: file)
    XCTAssertThrowsError(try PairingMailbox(folder: file, cid: cid))
  }

  func testChainReadsNeverSeeThePairingNamespace() throws {
    let keys = SyncKeys(entropy: Data(count: 32))
    let vault = SyncVault(folder: folder, keys: keys)
    try vault.createChain()
    try vault.write(scope: "s", payload: Data("p".utf8))
    let box = try mailbox()
    try box.write(wire(.request, rid: id(1), aid: nil), rid: id(1), aid: nil, kind: .request)
    XCTAssertEqual(vault.read(scope: "s", skipping: []).files.map(\.payload), [Data("p".utf8)])
    XCTAssertEqual(vault.read(scope: "s", skipping: []).damaged.count, 0)
  }
}
