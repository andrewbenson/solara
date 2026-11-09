import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkPendingStoreTests {
  private func directory() throws -> URL {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkScratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  private func document(_ urls: [String] = ["https://a.test", "https://b.test", "https://c.test"]) -> JSONValue {
    BookmarkCoordinatorTests().document(urls)
  }

  private func owner(_ dir: URL, operations: BookmarkPendingFileOperations = .live, input: BookmarkLaunchInput = .init(), makeID: @escaping () -> String = { "new-id" }) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", owningProfiles: ["": "p"], makeID: makeID, now: { 123 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir, fileOperations: operations), launchInput: input)
  }

  @Test func pendingEditsSurviveRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document(), ready: true)
    try first!.submit(profile: "p", mutations: [
      .init(method: "addBookmark", args: [["profileId": "p", "title": "New", "url": "https://new.test", "favicon": "new-icon"]]),
      .init(method: "updateBookmark", args: ["b0", ["title": "Renamed"]]),
      .init(method: "moveBookmark", args: ["b2", "bar@default", 0]),
      .init(method: "removeBookmark", args: ["b1"])
    ], requestID: "all-edits")
    let accepted = first!.desiredView(engine: "")
    #expect(accepted.facts["bm:b1"] != nil)
    first = nil
    let second = owner(dir)
    let replayed = second.desiredView(engine: "")
    #expect(replayed.document == accepted.document)
    #expect(replayed.revision == accepted.revision)
    #expect(replayed.facts == accepted.facts)
    #expect(!replayed.readyForSync)
    #expect(second.membership(profile: "alias", url: "https://new.test"))
    #expect(!second.membership(profile: "p", url: "https://b.test"))
    second.completeRead(engine: "", document: document(), capturedRevision: replayed.revision)
    let fetched = second.desiredView(engine: "")
    #expect(fetched.readyForSync)
    #expect(fetched.document["nodes"]?["bar@default"]?["children"] == ["b2", "b0", "new-id"])
    #expect(fetched.document["nodes"]?["b0"]?["title"] == "Renamed")
    #expect(fetched.document["nodes"]?["new-id"]?["addedAt"] == 123)
    #expect(fetched.document["nodes"]?["new-id"]?["favicon"] == "new-icon")
    #expect(fetched.document["nodes"]?["b1"] == nil)
    #expect(fetched.facts == accepted.facts)
  }

  @Test func journalWriteFailureRejectsWithoutPublication() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw BookmarkDurabilityFailure.injected }
    let coordinator = owner(dir, operations: operations)
    coordinator.seed(engine: "", document: document(), ready: true)
    var events = coordinator.membershipSnapshots().makeAsyncIterator()
    let before = coordinator.desiredView(engine: "")
    _ = await events.next()
    #expect(throws: (any Error).self) {
      try coordinator.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(coordinator.membership(profile: "p", url: "https://a.test"))
    coordinator.seed(engine: "", document: document(), ready: false)
    let next = await events.next()
    #expect(next?.revision == before.revision + 1)
    #expect(next?.contains("https://a.test") == true)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(BookmarkPendingStore.journalName).path))
  }

  @Test func unreadableIntentDoesNotBecomeEmpty() throws {
    for bytes in [Data(), Data("{".utf8), Data("{\"version\":1,\"payload\":{},\"checksum\":\"bad\"}".utf8)] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
      try bytes.write(to: path)
      let log = BookmarkTestLog()
      let store = BookmarkPendingStore(directory: dir, clock: { 456 }, logger: { log.messages.append($0) })
      let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: store, launchInput: .init(documents: ["": document()]))
      #expect(coordinator.membership(profile: "p", url: "https://a.test"))
      #expect(!coordinator.desiredView(engine: "").readyForSync)
      let notice = try #require(coordinator.recoveryNotice)
      #expect(notice.kind == .unreadableJournal)
      let preserved = try #require(notice.preservedPath)
      #expect(preserved.contains("456"))
      #expect(try Data(contentsOf: URL(fileURLWithPath: preserved)) == bytes)
      #expect(log.messages.count == 1)
      coordinator.completeRead(engine: "", document: document(), capturedRevision: 0)
      #expect(coordinator.desiredView(engine: "").readyForSync)
      coordinator.dismissRecoveryNotice()
      #expect(coordinator.recoveryNotice == nil)
    }
  }

  @Test func lostReceiptRequestIsIdempotent() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document([]), ready: true)
    let edit = BookmarkMutation(method: "addBookmark", args: [["profileId": "p", "url": "https://new.test", "title": "New"]])
    let accepted = try first!.submit(profile: "p", mutations: [edit], requestID: "request-1")
    first = nil
    let second = owner(dir, makeID: { Issue.record("Retried durable request allocated a second ID"); return "wrong" })
    let retried = try second.submit(profile: "p", mutations: [edit], requestID: "request-1")
    #expect(retried.results == accepted.results)
    #expect(!retried.view.readyForSync)
    #expect(retried.view.document == accepted.view.document)
    #expect(retried.view.revision == accepted.view.revision)
    #expect(throws: (any Error).self) {
      try second.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["new-id"])], requestID: "request-1")
    }
    #expect(second.membership(profile: "p", url: "https://new.test"))
  }

  @Test func acceptedRemoteReplacementSurvivesCrashBeforePush() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document(), ready: true)
    let replacement = document(["https://remote.test"])
    let accepted = try first!.replaceDocument(engine: "", document: replacement, expectedRevision: first!.desiredView(engine: "").revision, requestID: "remote-1")
    first = nil
    let second = owner(dir)
    #expect(second.desiredView(engine: "").document == replacement)
    #expect(!second.desiredView(engine: "").readyForSync)
    let retried = try second.replaceDocument(engine: "", document: replacement, expectedRevision: accepted.view.revision - 1, requestID: "remote-1")
    #expect(retried.view.document == replacement)
    second.completeRead(engine: "", document: document(), capturedRevision: 0)
    #expect(second.desiredView(engine: "").document["nodes"]?["b0"]?["url"] == "https://remote.test")
    #expect(second.desiredView(engine: "").document["nodes"]?["b1"] == nil)
  }

  @Test func cacheAloneDoesNotResurrectStaleBookmark() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir, input: .init(documents: ["": document()]))
    #expect(coordinator.membership(profile: "p", url: "https://a.test"))
    #expect(!coordinator.desiredView(engine: "").readyForSync)
    coordinator.completeRead(engine: "", document: document([]), capturedRevision: 0)
    #expect(!coordinator.membership(profile: "p", url: "https://a.test"))
    #expect(coordinator.desiredView(engine: "").readyForSync)
  }

  @Test func editAgainstCacheReplaysAfterRead() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir, input: .init(documents: ["": document()]))
    try first!.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "url": "https://new.test", "title": "New"]])])
    first = nil
    let second = owner(dir)
    #expect(!second.desiredView(engine: "").readyForSync)
    second.completeRead(engine: "", document: document([]), capturedRevision: 0)
    #expect(second.membership(profile: "p", url: "https://new.test"))
    #expect(!second.membership(profile: "p", url: "https://a.test"))
    #expect(second.desiredView(engine: "").document["nodes"]?["new-id"]?["addedAt"] == 123)
  }

  @Test func legacyMigrationKeptStaysUnready() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir, input: .init(documents: ["": document()], legacyPendingEngines: [JSKey("")]))
    coordinator.completeRead(engine: "", document: document(), capturedRevision: 0)
    #expect(coordinator.desiredView(engine: "").hasView)
    #expect(!coordinator.desiredView(engine: "").readyForSync)
  }

  @Test func crashBoundariesConstructFreshStoreAndCoordinator() throws {
    for boundary in ["beforeRename", "afterRename", "tornWrite"] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      var first: BookmarkCoordinator? = owner(dir)
      first!.seed(engine: "", document: document(), ready: true)
      try first!.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Durable"]])], requestID: "initial")
      first = nil
      var operations = BookmarkPendingFileOperations.live
      if boundary == "beforeRename" { operations.rename = { _, _ in throw BookmarkDurabilityFailure.injected } }
      if boundary == "afterRename" { operations.syncDirectory = { _ in throw BookmarkDurabilityFailure.injected } }
      if boundary == "tornWrite" {
        let write = operations.writeNew
        operations.writeNew = { url, bytes in try write(url, Data(bytes.prefix(bytes.count / 2))); throw BookmarkDurabilityFailure.injected }
      }
      operations.remove = { _ in }
      var crashing: BookmarkCoordinator? = owner(dir, operations: operations)
      let before = crashing!.desiredView(engine: "")
      #expect(throws: (any Error).self) { try crashing!.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Unacknowledged"]])], requestID: "uncertain") }
      #expect(crashing!.desiredView(engine: "") == before)
      crashing = nil
      let fresh = owner(dir)
      #expect(fresh.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == .string(boundary == "afterRename" ? "Unacknowledged" : "Durable"))
      #expect(!fresh.desiredView(engine: "").readyForSync)
      fresh.completeRead(engine: "", document: document(), capturedRevision: 0)
      #expect(fresh.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == .string(boundary == "afterRename" ? "Unacknowledged" : "Durable"))
    }
  }

  @Test func crashAfterEngineApplyBeforeCheckpointDoesNotDuplicate() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document([]), ready: true)
    try first!.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "url": "https://new.test", "title": "New"]])])
    let engineAlreadyApplied = first!.desiredView(engine: "").document
    first = nil
    let fresh = owner(dir)
    fresh.completeRead(engine: "", document: engineAlreadyApplied, capturedRevision: 0)
    #expect(fresh.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == ["new-id"])
    #expect(fresh.membershipSnapshot.nodeIDsByURL["https://new.test"] == ["new-id"])
    #expect(fresh.desiredView(engine: "").document["nodes"]?["new-id"]?["addedAt"] == 123)
  }

  @Test func failedReplacementDoesNotPublishOrAdvanceRevision() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw BookmarkDurabilityFailure.injected }
    let failing = owner(dir, operations: operations)
    failing.seed(engine: "", document: document(), ready: true)
    let before = failing.desiredView(engine: "")
    #expect(throws: (any Error).self) { try failing.replaceDocument(engine: "", document: document([]), expectedRevision: before.revision) }
    #expect(failing.desiredView(engine: "") == before)
  }

  @Test func malformedEditCannotBeAcknowledgedThenLostOnRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    let before = coordinator.desiredView(engine: "")
    #expect(throws: (any Error).self) { try coordinator.replaceDocument(engine: "", document: ["nodes": [:]], expectedRevision: before.revision) }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(throws: (any Error).self) { try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["id": "different"]])]) }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(BookmarkPendingStore.journalName).path))
  }

  @Test func unsupportedRootsAndInvisibleOrphansRejectBeforeAcceptance() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    let before = coordinator.desiredView(engine: "")
    let custom: JSONValue = ["nodes": ["x": ["id": "x", "kind": "folder", "title": "Bar", "parentId": nil, "children": [], "addedAt": 0], "y": ["id": "y", "kind": "folder", "title": "Other", "parentId": nil, "children": [], "addedAt": 0]], "roots": ["p": ["bar": "x", "other": "y"]]]
    #expect(throws: (any Error).self) { try coordinator.replaceDocument(engine: "", document: custom, expectedRevision: before.revision) }
    #expect(coordinator.desiredView(engine: "") == before)
    var orphaned = document()["nodes"]!.object!
    var bar = orphaned["bar@default"]!.object!
    bar["children"] = []
    orphaned["bar@default"] = .object(bar)
    let orphanDocument: JSONValue = ["nodes": .object(orphaned), "roots": document()["roots"]!]
    #expect(throws: (any Error).self) { try coordinator.replaceDocument(engine: "", document: orphanDocument, expectedRevision: coordinator.desiredView(engine: "").revision) }
    #expect(coordinator.desiredView(engine: "") == before)
  }

  @Test func validChecksumWithUnreadableCheckpointIsPreserved() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    try BookmarkPendingStore(directory: dir).write(["kind": "bookmarkCoordinator", "engines": []])
    let bytes = try Data(contentsOf: path)
    let coordinator = owner(dir, input: .init(documents: ["": document()]))
    let notice = try #require(coordinator.recoveryNotice)
    #expect(notice.kind == .unreadableJournal)
    #expect(try Data(contentsOf: URL(fileURLWithPath: #require(notice.preservedPath))) == bytes)
    #expect(coordinator.membership(profile: "p", url: "https://a.test"))
    #expect(!coordinator.desiredView(engine: "").readyForSync)
  }

  @Test func satisfiedRemovalsKeepDurableSuffixPendingAcrossRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document(), ready: true)
    try first!.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    first = nil
    var second: BookmarkCoordinator? = owner(dir)
    let partiallyApplied = document(["https://a.test", "https://b.test", "https://c.test"])
    var nodes = partiallyApplied["nodes"]!.object!
    nodes.removeValue(forKey: "b0")
    nodes.removeValue(forKey: "b1")
    var root = nodes["bar@default"]!.object!
    root["children"] = ["b2"]
    nodes["bar@default"] = .object(root)
    let fetched: JSONValue = ["nodes": .object(nodes), "roots": partiallyApplied["roots"]!]
    second!.completeRead(engine: "", document: fetched, capturedRevision: 0)
    #expect(second!.desiredView(engine: "").structuralBreak == nil)
    #expect(second!.desiredView(engine: "").document["nodes"]?["b2"] == nil)
    #expect(second!.recoveryConflicts.isEmpty)
    second = nil
    let third = owner(dir)
    #expect(third.desiredView(engine: "").document["nodes"]?["b2"] == nil)
    #expect(third.completeRead(engine: "", document: fetched, capturedRevision: 0))
    #expect(third.desiredView(engine: "").document["nodes"]?["b2"] == nil)
    #expect(third.recoveryConflicts.isEmpty)
  }

  @Test func persistedReadDoesNotReplayAcknowledgedHistoricalEdits() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: BookmarkCoordinator? = owner(dir)
    first!.seed(engine: "", document: document([]), ready: true)
    try first!.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "url": "https://new.test", "title": "New"]])], requestID: "historical")
    let alreadyApplied = first!.desiredView(engine: "").document
    first!.completeRead(engine: "", document: alreadyApplied, capturedRevision: 0)
    first = nil
    let second = owner(dir)
    second.completeRead(engine: "", document: document([]), capturedRevision: 0)
    #expect(!second.membership(profile: "p", url: "https://new.test"))
  }

  @Test func newerJournalIsNotAdoptedMovedOrModified() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = Data("{\"version\":999,\"future\":\"intent\"}".utf8)
    try bytes.write(to: path)
    let date = Date(timeIntervalSince1970: 12)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
    let coordinator = owner(dir, input: .init(documents: ["": document()]))
    #expect(coordinator.recoveryNotice?.kind == .newerJournalVersion)
    coordinator.completeRead(engine: "", document: document(["https://committed.test"]), capturedRevision: 0)
    #expect(coordinator.membership(profile: "p", url: "https://committed.test"))
    #expect(throws: (any Error).self) { try coordinator.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])]) }
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [BookmarkPendingStore.journalName])
  }
}

private final class BookmarkTestLog {
  var messages: [String] = []
}

private enum BookmarkDurabilityFailure: Error {
  case injected
}
