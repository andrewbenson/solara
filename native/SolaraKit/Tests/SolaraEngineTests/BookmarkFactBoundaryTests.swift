import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkFactBoundaryTests {
  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkFactBoundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func document(_ title: String = "Local", present: Bool = true) -> JSONValue {
    let roots = BookmarkFlat.roots("")
    var nodes: JSONObject = [
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": .array(present ? ["b0"] : []), "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0]
    ]
    if present { nodes["b0"] = ["id": "b0", "kind": "url", "parentId": .string(roots.bar), "title": .string(title), "url": "https://a.test", "addedAt": 1] }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)], "alias": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  private func owner(_ directory: URL, operations: BookmarkPendingFileOperations = .live) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", now: { 100 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
  }

  private func rename(_ title: String) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["b0", ["title": .string(title)]])
  }

  @Test(arguments: [false, true])
  func replacementAndRecordObservationAreOneDurableAcceptance(_ deleted: Bool) throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var checkpoints = 0
    let liveSync = BookmarkPendingFileOperations.live.syncFile
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { url in checkpoints += 1; try liveSync(url) }
    let coordinator = owner(directory, operations: operations)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    checkpoints = 0
    let snapshot = coordinator.writerSnapshot(profile: "p")
    let remote = document("Remote", present: !deleted)
    let receipt = try coordinator.replaceDocument(engine: "", profile: "p", document: remote, expectedRevision: snapshot.revision, expectedEngine: "", records: [(key: "bm:b0", hlc: "00000002s.0007.remote")], expectedLink: "chain")
    #expect(receipt.view.document == remote)
    #expect(checkpoints == 1)
    let recovered = owner(directory)
    if deleted {
      try recovered.submit(profile: "p", mutations: [.init(method: "restoreBookmarks", args: [["nodes": [document()["nodes"]?["b0"] ?? .null], "places": [["id": "b0", "parentId": "bar@default", "index": 0]]]])])
    } else {
      try recovered.submit(profile: "p", mutations: [rename("Same millisecond edit")])
    }
    let fact = try #require(recovered.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(fact.at == 100)
    #expect(fact.after == "00000002s.0007.remote")
    #expect(fact.link == "chain")
  }

  @Test func failedAtomicReplacementRetainsBothDocumentAndPredecessor() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000002s.0001.remote")]))
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw BookmarkPendingStoreError.unavailable }
    let failing = owner(directory, operations: operations)
    let snapshot = failing.writerSnapshot(profile: "p")
    let before = failing.desiredView(engine: "")
    var failed = false
    do {
      try failing.replaceDocument(engine: "", profile: "p", document: document("Remote"), expectedRevision: snapshot.revision, expectedEngine: "", records: [(key: "bm:b0", hlc: "00000002s.0007.remote")], expectedLink: "chain")
    } catch { failed = true }
    #expect(failed)
    #expect(failing.writerSnapshot(profile: "p").document == snapshot.document)
    #expect(failing.desiredView(engine: "") == before)
    let recovered = owner(directory)
    try recovered.submit(profile: "p", mutations: [rename("After failed replace")])
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000002s.0001.remote")
  }

  @Test func lastSeenIsScopedByLinkAcrossRelaunchAndAliases() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "old", "alias": "old"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "0000003uw.0000.old")]))
    #expect(coordinator.setBookmarkSyncLinks(["p": "new", "alias": "old"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000005k.0000.new")]))
    let recovered = owner(directory)
    try recovered.submit(profile: "p", mutations: [rename("New chain edit")])
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000005k.0000.new")
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:b0"]?.link == "new")
    try recovered.submit(profile: "alias", mutations: [rename("Old alias edit")])
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:b0"]?.after == "0000003uw.0000.old")
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:b0"]?.link == "old")
  }

  @Test func delayedOldLinkAckCannotClearOrPromoteNewLinkFact() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "old"]))
    try coordinator.submit(profile: "p", mutations: [rename("Old edit")])
    let old = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(coordinator.setBookmarkSyncLinks(["p": "new"]))
    try coordinator.submit(profile: "p", mutations: [rename("New edit")])
    let newer = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    var refused = false
    do {
      _ = try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: old.seq, mintedHLC: "0000003uw.0000.old")], expectedLink: "old")
    } catch BookmarkWriterError.staleBinding { refused = true }
    #expect(refused)
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b0"] == newer)
    #expect(owner(directory).bookmarkFacts(profileId: "p")["bm:b0"] == newer)
  }

  @Test func delayedOldLinkObservationAndReplacementCannotChangeNewLink() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "old"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "0000003uw.0000.old")], expectedLink: "old"))
    #expect(coordinator.setBookmarkSyncLinks(["p": "new"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000005k.0000.new")], expectedLink: "new"))
    try coordinator.submit(profile: "p", mutations: [rename("New link intent")])
    let before = coordinator.desiredView(engine: "")
    let journal = directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "0000003uw.0001.old")], expectedLink: "old")
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try coordinator.replaceDocument(engine: "", profile: "p", document: self.document("Delayed old replacement"), expectedRevision: before.revision, expectedEngine: "", records: [(key: "bm:b0", hlc: "0000003uw.0001.old")], expectedLink: "old")
    }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(try Data(contentsOf: journal) == bytes)
    var durableBefore = before
    durableBefore.readyForSync = false
    #expect(owner(directory).desiredView(engine: "") == durableBefore)
  }

  @Test func atomicObservationDoesNotPromoteTheLosingFactAndOldClearPreservesNextEdit() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    try coordinator.submit(profile: "p", mutations: [rename("Losing intent")])
    let losing = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    let before = coordinator.writerSnapshot(profile: "p")
    try coordinator.replaceDocument(engine: "", profile: "p", document: document("Remote winner"), expectedRevision: before.revision, expectedEngine: "", records: [(key: "bm:b0", hlc: "00000005k.0007.remote")], expectedLink: "chain")
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b0"] == losing)
    let recovered = owner(directory)
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:b0"] == losing)
    try recovered.submit(profile: "p", mutations: [rename("Edit after remote winner")])
    let next = try #require(recovered.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(next.seq > losing.seq && next.after == "00000005k.0007.remote" && next.link == "chain")
    #expect(try recovered.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: losing.seq)]))
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:b0"] == next)
    #expect(owner(directory).bookmarkFacts(profileId: "p")["bm:b0"] == next)
  }

  @Test func staleRevisionCannotInstallAtomicObservation() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    let staleRevision = coordinator.writerSnapshot(profile: "p").revision
    try coordinator.submit(profile: "p", mutations: [rename("Intervening edit")])
    let before = coordinator.desiredView(engine: "")
    #expect(throws: BookmarkCoordinatorError.staleRevision) {
      try coordinator.replaceDocument(engine: "", profile: "p", document: self.document("Stale remote"), expectedRevision: staleRevision, expectedEngine: "", records: [(key: "bm:b0", hlc: "0000003uw.0000.remote")], expectedLink: "chain")
    }
    #expect(coordinator.desiredView(engine: "") == before)
    var durableBefore = before
    durableBefore.readyForSync = false
    #expect(owner(directory).desiredView(engine: "") == durableBefore)
    try coordinator.submit(profile: "p", mutations: [rename("After refusal")])
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b0"]?.after == nil)
  }
}
