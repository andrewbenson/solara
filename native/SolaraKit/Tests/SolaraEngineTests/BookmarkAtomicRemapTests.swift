import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkAtomicRemapTests {
  private func document(_ engine: String, title: String = "Page") -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    return ["nodes": .object([
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["b0"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
      "b0": ["id": "b0", "kind": "url", "parentId": .string(roots.bar), "title": .string(title), "url": "https://a.test", "addedAt": 1]
    ]), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  @Test func unconfirmedAtomicReplacementAllowsInMemoryRemapAndFencesDelayedWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkAtomicRemap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var writes = 0
    var failDirectorySync = false
    var operations = BookmarkPendingFileOperations.live
    let writeNew = operations.writeNew
    let syncDirectory = operations.syncDirectory
    operations.writeNew = { url, bytes in writes += 1; try writeNew(url, bytes) }
    operations.syncDirectory = { url in
      if failDirectorySync { throw BookmarkPendingStoreError.io("fsync journal directory", EIO) }
      try syncDirectory(url)
    }
    let coordinator = BookmarkCoordinator(profiles: ["p": "E1", "alias": "E1", "q": "E2"], defaultProfile: "p", owningProfiles: ["E1": "p", "E2": "q"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    coordinator.seed(engine: "E1", document: document("E1"), ready: true)
    coordinator.seed(engine: "E2", document: document("E2"), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "old", "alias": "old", "q": "new"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", hlc: "00000002s.0001.old")], expectedLink: "old"))
    try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending old intent"]])])
    let beforeFirst = coordinator.desiredView(engine: "E1")
    let beforeSecond = coordinator.desiredView(engine: "E2")
    failDirectorySync = true
    #expect(throws: BookmarkPendingStoreError.savedUnconfirmed("fsync journal directory", EIO)) {
      try coordinator.replaceDocument(engine: "E1", profile: "p", document: self.document("E1", title: "Remote winner"), expectedRevision: beforeFirst.revision, expectedEngine: "E1", records: [(key: "bm:b0", hlc: "00000005k.0007.remote")], expectedLink: "old")
    }
    var pausedFirst = beforeFirst
    pausedFirst.readyForSync = false
    pausedFirst.revision += 1
    var pausedSecond = beforeSecond
    pausedSecond.readyForSync = false
    pausedSecond.revision += 1
    #expect(coordinator.recoveryNotice?.kind == .unavailableJournal)
    #expect(coordinator.desiredView(engine: "E1") == pausedFirst)
    let journal = directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    let writesBeforeRemap = writes
    let generation = coordinator.currentOwnerGeneration
    #expect(coordinator.remap(profiles: ["p": "E2", "alias": "E1", "q": "E2"], defaultProfile: "p", owningProfiles: ["E1": "alias", "E2": "q"]))
    #expect(coordinator.engine(profile: "p") == "E2")
    #expect(coordinator.currentOwnerGeneration > generation)
    #expect(coordinator.bookmarkFacts(profileId: "p") == beforeSecond.facts)
    #expect(coordinator.bookmarkFacts(profileId: "alias") == beforeFirst.facts)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: UInt64.max, mintedHLC: "0000003uw.0000.old")], expectedLink: "old")
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", hlc: "0000003uw.0000.old")], expectedLink: "old")
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try coordinator.replaceDocument(engine: "E1", profile: "p", document: self.document("E1", title: "Delayed old work"), expectedRevision: beforeFirst.revision, expectedEngine: "E1", records: [(key: "bm:b0", hlc: "0000003uw.0000.old")], expectedLink: "old")
    }
    #expect(coordinator.desiredView(engine: "E1") == pausedFirst)
    #expect(coordinator.desiredView(engine: "E2") == pausedSecond)
    #expect(writes == writesBeforeRemap)
    #expect(try Data(contentsOf: journal) == bytes)
    let recovered = BookmarkCoordinator(profiles: ["p": "E2", "alias": "E1", "q": "E2"], defaultProfile: "p", now: { 200 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
    #expect(recovered.desiredView(engine: "E1").document == document("E1", title: "Remote winner"))
    #expect(recovered.desiredView(engine: "E1").facts == beforeFirst.facts)
    try recovered.submit(profile: "alias", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "After confirmed recovery"]])])
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:b0"]?.after == "00000005k.0007.remote")
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:b0"]?.link == "old")
    #expect(recovered.bookmarkFacts(profileId: "p").isEmpty)
  }
}
