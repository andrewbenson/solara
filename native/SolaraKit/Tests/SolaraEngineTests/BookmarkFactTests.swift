import CryptoKit
import Dispatch
import Foundation
import Testing
import SolaraModel
import SolaraSync
@testable import SolaraEngine

struct BookmarkFactTests {
  private func directory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkFacts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  private func document(engine: String = "", firstID: String = "b0", syncKey: String? = nil) -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    var first: JSONObject = ["id": .string(firstID), "kind": "url", "parentId": .string(roots.bar), "title": "Page", "url": "https://a.test", "addedAt": 10]
    if let syncKey { first["syncKey"] = .string(syncKey) }
    return ["nodes": .object([
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": [.string(firstID), "b1"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
      firstID: .object(first),
      "b1": ["id": "b1", "kind": "url", "parentId": .string(roots.bar), "title": "Page", "url": "https://b.test", "syncKey": "wrong-key", "addedAt": 10]
    ]), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  private func owner(_ directory: URL, operations: BookmarkPendingFileOperations = .live, enabled: Bool = true) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", owningProfiles: ["": "p"], now: { 123 }, stampsEnabled: enabled, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
  }

  private func rename(_ title: String, id: String = "b0") -> BookmarkMutation {
    .init(method: "updateBookmark", args: [.string(id), ["title": .string(title)]])
  }

  private func reorderDocument() -> JSONValue {
    let roots = BookmarkFlat.roots("")
    var nodes: JSONObject = [
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["A", "B", "C"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": ["folder"], "addedAt": 0],
      "folder": ["id": "folder", "kind": "folder", "parentId": .string(roots.other), "title": "Folder", "children": ["child"], "addedAt": 0],
      "child": ["id": "child", "kind": "url", "parentId": "folder", "title": "Child", "url": "https://child.test", "favicon": nil, "addedAt": 10]
    ]
    for id in ["A", "B", "C"] {
      nodes[id] = ["id": .string(id), "kind": "url", "parentId": .string(roots.bar), "title": .string(id), "url": .string("https://\(id.lowercased()).test"), "favicon": nil, "addedAt": 10]
    }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  @Test func deletedNodeKeepsItsFactUnderTheRecordKey() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = "de8f26f1-cf94-4896-bcf5-f260fa6f106a"
    let first = owner(dir)
    first.seed(engine: "", document: document(firstID: id, syncKey: "bm-1"), ready: true)
    try first.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [[.string(id), "b1"]])])
    let facts = first.bookmarkFacts(profileId: "alias")
    #expect(facts["bm:bm-1"]?.at == 123)
    #expect(facts["bm:b1"] != nil)
    #expect(facts["bm:\(id)"] == nil)
    #expect(first.desiredView(engine: "").document["nodes"]?[id] == nil)
    #expect(owner(dir).bookmarkFacts(profileId: "p") == facts)
  }

  @Test func seqIsOneDurableCounterAcrossRemapAndRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = BookmarkCoordinator(profiles: ["p": "E1", "alias": "E1", "q": "E2"], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    first.seed(engine: "E1", document: document(engine: "E1"), ready: true)
    first.seed(engine: "E2", document: document(engine: "E2"), ready: true)
    try first.submit(profile: "p", mutations: [rename("First")])
    let one = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    first.remap(profiles: ["p": "E2", "alias": "E1"], defaultProfile: "p", owningProfiles: ["E1": "alias", "E2": "p"])
    try first.submit(profile: "p", mutations: [rename("Second")])
    let two = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(two.seq > one.seq)
    #expect(first.bookmarkFacts(profileId: "alias")["bm:b0"] == one)
    #expect(try first.clearBookmarkFacts(profileId: "alias", expectedEngine: "E1", records: [(key: "bm:b0", seq: one.seq)]))
    #expect(try first.clearBookmarkFacts(profileId: "p", expectedEngine: "E2", records: [(key: "bm:b0", seq: two.seq)]))
    let restored = BookmarkCoordinator(profiles: ["p": "E2", "alias": "E1"], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    try restored.submit(profile: "alias", mutations: [rename("Third")])
    #expect(try #require(restored.bookmarkFacts(profileId: "alias")["bm:b0"]).seq > two.seq)
    #expect(restored.bookmarkFacts(profileId: "p").isEmpty)
  }

  @Test func ackClearsOnlyFactsAtOrBelowItsSeqAndRecordsMintedHLC() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = owner(dir)
    first.seed(engine: "", document: document(), ready: true)
    try first.submit(profile: "p", mutations: [rename("Publishing")])
    let publishing = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    let publishingSnapshot = first.writerSnapshot(profile: "p")
    #expect(publishingSnapshot.document["nodes"]?["b0"]?["title"] == "Publishing")
    #expect(publishingSnapshot.facts["bm:b0"] == publishing)
    try first.submit(profile: "p", mutations: [rename("Edited during publish")])
    let newer = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(try first.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: publishing.seq)]))
    #expect(first.bookmarkFacts(profileId: "p")["bm:b0"] == newer)
    #expect(try first.ackBookmarkFacts(profileId: "alias", expectedEngine: "", records: [(key: "bm:b0", seq: publishing.seq, mintedHLC: "00000003f.0001.device")]))
    let raised = BookmarkEditFact(at: newer.at, seq: newer.seq, after: "00000003f.0001.device", link: newer.link)
    #expect(first.bookmarkFacts(profileId: "p")["bm:b0"] == raised)
    let newerSnapshot = first.writerSnapshot(profile: "p")
    #expect(newerSnapshot.document["nodes"]?["b0"]?["title"] == "Edited during publish")
    #expect(newerSnapshot.facts["bm:b0"] == raised)
    let restored = owner(dir)
    try restored.submit(profile: "p", mutations: [rename("After publish")])
    let latest = try #require(restored.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(latest.after == "00000003f.0001.device")
    #expect(try restored.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: latest.seq + 1, mintedHLC: "00000003f.0002.device")]))
    #expect(owner(dir).bookmarkFacts(profileId: "p").isEmpty)
    let acknowledged = owner(dir)
    try acknowledged.submit(profile: "p", mutations: [rename("After ack")])
    #expect(acknowledged.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000003f.0002.device")
  }

  @Test func remoteObservationBecomesTheNextEditsAfter() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = owner(dir)
    first.seed(engine: "", document: document(), ready: true)
    #expect(try first.observeRemoteRecords(profileId: "alias", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0009.remote"), (key: "bm:b0", hlc: "00000003f.0001.remote")]))
    let restored = owner(dir)
    try restored.submit(profile: "p", mutations: [rename("Local")])
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000003f.0009.remote")
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"]?.at == 123)
  }

  @Test func aLateAckNeverRewindsANewerRemoteObservation() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("Published")])
    let fact = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0009.remote")]))
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: fact.seq, mintedHLC: "00000003f.0001.device")]))
    try coordinator.submit(profile: "p", mutations: [rename("Next")])
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000003f.0009.remote")
  }

  @Test func sameMillisecondEditGetsAfterFromLastSeen() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("First")])
    let first = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: first.seq, mintedHLC: "00000003f.0001.device")]))
    try coordinator.submit(profile: "p", mutations: [rename("Second")])
    let second = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(first.at == 123 && second.at == 123)
    #expect(first.after == nil)
    #expect(second.after == "00000003f.0001.device")
    #expect(second.seq > first.seq)
  }

  @Test func linkIsCapturedAtAcceptanceAndSurvivesRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = owner(dir)
    first.seed(engine: "", document: document(), ready: true)
    try first.submit(profile: "p", mutations: [rename("No link")])
    #expect(first.bookmarkFacts(profileId: "p")["bm:b0"]?.link == "none")
    #expect(first.setBookmarkSyncLinks(["p": "old", "alias": "alias-link"]))
    try first.submit(profile: "alias", mutations: [rename("From alias")])
    let accepted = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(accepted.link == "alias-link")
    #expect(first.setBookmarkSyncLinks(["p": "new"]))
    #expect(first.bookmarkFacts(profileId: "p")["bm:b0"] == accepted)
    let restored = owner(dir)
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"] == accepted)
    try restored.submit(profile: "p", mutations: [rename("New chain", id: "b1")])
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b1"]?.link == "new")
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"] == accepted)
  }

  @Test func strandedEngineKeepsItsLastOwnerWhileFactsPending() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = BookmarkCoordinator(profiles: ["p": "E1"], defaultProfile: "p", owningProfiles: ["E1": "p"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    first.seed(engine: "E1", document: document(engine: "E1"), ready: true)
    try first.submit(profile: "p", mutations: [rename("Pending fact")])
    let fact = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(first.completeRead(engine: "E1", document: first.desiredView(engine: "E1").document, capturedRevision: 0))
    first.remap(profiles: ["p": "E2"], defaultProfile: "p", owningProfiles: ["E2": "p"])
    #expect(first.ownerProfileForTesting(engine: "E1") == "p")
    #expect(first.setBookmarkSyncLinks(["p": "new-link"]))
    #expect(first.remap(profiles: ["p": "E2", "q": "E1"], defaultProfile: "p", owningProfiles: ["E1": "q", "E2": "p"]))
    #expect(first.ownerProfileForTesting(engine: "E1") == "q")
    #expect(first.remap(profiles: ["p": "E2", "q": "E2"], defaultProfile: "p", owningProfiles: ["E2": "p"]))
    let restored = BookmarkCoordinator(profiles: ["p": "E2", "q": "E2"], defaultProfile: "p", owningProfiles: ["E2": "p"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    #expect(restored.ownerProfileForTesting(engine: "E1") == "q")
    #expect(restored.bookmarkFacts(profileId: "p").isEmpty)
    #expect(restored.desiredView(engine: "E1").facts["bm:b0"] == fact)
    restored.remap(profiles: ["p": "E1"], defaultProfile: "p", owningProfiles: ["E1": "p"])
    #expect(try restored.clearBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: fact.seq)]))
    restored.remap(profiles: ["p": "E2"], defaultProfile: "p", owningProfiles: ["E2": "p"])
    #expect(restored.ownerProfileForTesting(engine: "E1") == "E1")
  }

  @Test func oldFormatCheckpointLoadsWithoutFactsAndRecordsAConflict() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let document = document()
    let view: JSONValue = ["engine": "", "document": document, "revision": "7", "hasView": true, "failedPushes": 2, "retryNotBeforeMs": 456, "requiresRead": true, "inFlightTarget": nil, "structuralBreak": nil, "stamps": [["id": "b0", "hlc": "old", "origin": "device"]], "unconfirmedEdits": ["b0"]]
    let request: JSONValue = ["kind": "submit", "profile": "p", "engine": "", "fromSync": false, "mutations": []]
    let payload: JSONValue = ["kind": "bookmarkCoordinator", "engines": [["ownerProfile": "p", "view": view, "base": .array(BookmarkFlat(document: document, engine: "").records)]], "requests": [["id": "old-request", "payload": request, "view": view, "results": ["kept"]]], "conflicts": [["kind": "prior"]], "legacyPendingEngines": []]
    let checksum = SHA256.hash(data: Data(payload.canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    let envelope: JSONValue = ["version": 1, "payload": payload, "checksum": .string(checksum)]
    try Data(envelope.text().utf8).write(to: dir.appendingPathComponent(BookmarkPendingStore.journalName))
    let restored = owner(dir)
    #expect(restored.recoveryNotice == nil)
    #expect(restored.bookmarkFacts(profileId: "p").isEmpty)
    #expect(restored.desiredView(engine: "").document == document)
    #expect(restored.desiredView(engine: "").revision == 7)
    #expect(restored.desiredView(engine: "").failedPushes == 2)
    #expect(restored.desiredView(engine: "").retryNotBeforeMs == 456)
    #expect(restored.desiredView(engine: "").requiresRead)
    #expect(restored.recoveryConflicts.contains(["kind": "prior"]))
    #expect(restored.recoveryConflicts.contains { $0["kind"] == "oldBookmarkStampFormat" })
    let receipt = try restored.submit(profile: "p", mutations: [], requestID: "old-request")
    #expect(receipt.results == ["kept"])
    #expect(receipt.view.facts.isEmpty)
    #expect(try restored.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "new")]))
    #expect(owner(dir).recoveryConflicts.contains { $0["kind"] == "oldBookmarkStampFormat" })
  }

  @Test func factCallsNeverRunUnderTheCoordinatorLock() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let probe = FactLockProbe()
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { url in
      try probe.readDuringCallback()
      try sync(url)
    }
    let coordinator = owner(dir, operations: operations)
    probe.owner = coordinator
    coordinator.seed(engine: "", document: document(), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("Pending")])
    let fact = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "remote")]))
    #expect(coordinator.setBookmarkSyncLinks(["p": "link"]))
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: 0, mintedHLC: "minted")]))
    #expect(try coordinator.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: fact.seq)]))
    #expect(probe.checks == 5)
  }

  @Test(arguments: ["ack", "clear", "observe", "links"])
  func failedFactMutationsRetainDurableState(_ call: String) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = owner(dir)
    first.seed(engine: "", document: document(), ready: true)
    #expect(first.setBookmarkSyncLinks(["p": "old-link"]))
    #expect(try first.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "old-record")]))
    try first.submit(profile: "p", mutations: [rename("Pending")])
    let fact = try #require(first.bookmarkFacts(profileId: "p")["bm:b0"])
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: path)
    #expect(try !first.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bad", seq: fact.seq, mintedHLC: "z-new")]))
    #expect(try !first.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bad", seq: fact.seq)]))
    #expect(try !first.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bad", hlc: "z-new")]))
    #expect(try Data(contentsOf: path) == bytes)
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw FactTestFailure.injected }
    let failing = owner(dir, operations: operations)
    let succeeded: Bool
    switch call {
    case "ack": succeeded = try failing.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: fact.seq, mintedHLC: "z-new")])
    case "clear": succeeded = try failing.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: fact.seq)])
    case "observe": succeeded = try failing.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "z-new")])
    default: succeeded = failing.setBookmarkSyncLinks(["p": "new-link"])
    }
    #expect(!succeeded)
    #expect(failing.recoveryNotice?.kind == .unavailableJournal)
    #expect(failing.bookmarkFacts(profileId: "p")["bm:b0"] == fact)
    #expect(try Data(contentsOf: path) == bytes)
    let restored = owner(dir)
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"] == fact)
    try restored.submit(profile: "p", mutations: [rename("After failure")])
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "old-record")
    #expect(restored.bookmarkFacts(profileId: "p")["bm:b0"]?.link == "old-link")
  }

  @Test func inactiveFactContractAndSyncSubmissionsNeverRecordLocalIntent() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let inactive = owner(dir, enabled: false)
    inactive.seed(engine: "", document: document(), ready: true)
    #expect(inactive.setBookmarkSyncLinks(["p": "link"]))
    #expect(try inactive.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "remote")]))
    try inactive.submit(profile: "p", mutations: [rename("Dormant")])
    #expect(try inactive.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: 1, mintedHLC: "minted")]))
    #expect(try inactive.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: 1)]))
    #expect(inactive.bookmarkFacts(profileId: "p").isEmpty)
    #expect(inactive.writerSnapshot(profile: "p").facts.isEmpty)
    let enabled = owner(dir)
    try enabled.submit(profile: "p", mutations: [rename("Remote")], fromSync: true)
    #expect(enabled.bookmarkFacts(profileId: "p").isEmpty)
    try enabled.submit(profile: "p", mutations: [rename("Local")])
    let fact = try #require(enabled.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(fact.link == "none" && fact.after == nil)
    try enabled.submit(profile: "p", mutations: [rename("Another remote")], fromSync: true)
    #expect(enabled.bookmarkFacts(profileId: "p")["bm:b0"] == fact)
  }

  @Test func reorderRecordsMovedNodeAndNeverSyntheticRoots() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    try coordinator.submit(profile: "alias", mutations: [.init(method: "moveBookmark", args: ["b1", "bar@default", 0])])
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b1"] != nil)
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:bar@default"] == nil)
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:bar"] == nil)
    #expect(coordinator.writerSnapshot(profile: "p").facts == coordinator.bookmarkFacts(profileId: "p"))
  }

  @Test(arguments: ["moveBookmark", "applyBookmarkOperations", "restoreBookmarks", "batch"])
  func movingFirstSiblingToEndReplacesItsFact(_ entry: String) async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 17 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    first.seed(engine: "", document: reorderDocument(), ready: true)
    try first.submit(profile: "p", mutations: [rename("Earlier A", id: "A")])
    let old = try #require(first.bookmarkFacts(profileId: "p")["bm:A"])
    let coordinator = owner(dir)
    let after = "00000003f.0009.remote"
    let link = "chain:test/profile:scope"
    #expect(coordinator.setBookmarkSyncLinks(["p": link]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:A", hlc: after)]))
    let host = FactBookmarksHost(coordinator.desiredView(engine: "").document)
    let adapter = BookmarksAdapter(host: host, profileId: "p")
    let positions: JSMap<JSONValue> = [
      "bm:A": ["p": "bar", "pos": "A"],
      "bm:B": ["p": "bar", "pos": "B"],
      "bm:C": ["p": "bar", "pos": "C"]
    ]
    let context = ExtractContext(base: { positions[$0] }, queued: { _ in false }, now: 123, known: { _ in true }, remote: { _ in nil }, stamp: { _ in nil })
    let initial = try #require(try await adapter.extract(context))
    let initialValues = JSMap(initial.values.compactMap { entry in entry.value.map { (entry.key, $0) } })
    #expect(initialValues["bm:A"]?["pos"] == "A")
    #expect(initialValues["bm:B"]?["pos"] == "B")
    #expect(initialValues["bm:C"]?["pos"] == "C")
    let bar = BookmarkFlat.roots("").bar
    let mutations: [BookmarkMutation]
    switch entry {
    case "applyBookmarkOperations":
      mutations = [.init(method: entry, args: [[["op": "move", "id": "A", "parent": "bar", "index": 2]]])]
    case "restoreBookmarks":
      mutations = [.init(method: entry, args: [["nodes": [], "places": [["id": "A", "parentId": .string(bar), "index": 2]]]])]
    case "batch":
      mutations = [.init(method: "moveBookmark", args: ["A", .string(bar), 1]), .init(method: "moveBookmark", args: ["A", .string(bar), 2])]
    default:
      mutations = [.init(method: entry, args: ["A", .string(bar), 2])]
    }
    let receipt = try coordinator.submit(profile: "p", mutations: mutations)
    #expect(receipt.view.document["nodes"]?[bar]?["children"] == ["B", "C", "A"])
    let fact = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:A"])
    #expect(fact.at == 123)
    #expect(fact.seq > old.seq)
    #expect(fact.after == after)
    #expect(fact.link == link)
    host.setBookmarks(receipt.view.document)
    let extracted = try #require(try await adapter.extract(context))
    let values = JSMap(extracted.values.compactMap { entry in entry.value.map { (entry.key, $0) } })
    #expect(values["bm:A"]?["pos"] == "b")
    #expect(values["bm:B"]?["pos"] == "B")
    #expect(values["bm:C"]?["pos"] == "C")
    let changed = extracted.values.filter { initialValues[$0.key] != $0.value }.map(\.key)
    #expect(changed == ["bm:A"])
    for key in changed {
      let current = try #require(receipt.view.facts[key])
      #expect(current.at == 123 && current.seq > old.seq && current.after == after && current.link == link)
    }
    for id in ["A", "B", "C"] {
      let sibling = try #require(receipt.view.facts["bm:\(id)"])
      #expect(sibling.at == 123 && sibling.seq > old.seq && sibling.link == link)
    }
    #expect(receipt.view.facts["bm:\(bar)"] == nil)
    #expect(owner(dir).bookmarkFacts(profileId: "p") == receipt.view.facts)
  }

  @Test func reorderCoveragePreservesOtherSubtreesAndNoOpFacts() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: reorderDocument(), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("Pending folder", id: "folder"), rename("Pending child", id: "child")])
    let before = coordinator.bookmarkFacts(profileId: "p")
    let bar = BookmarkFlat.roots("").bar
    try coordinator.submit(profile: "p", mutations: [.init(method: "moveBookmark", args: ["A", .string(bar), 2])])
    let reordered = coordinator.bookmarkFacts(profileId: "p")
    #expect(reordered["bm:folder"] == before["bm:folder"])
    #expect(reordered["bm:child"] == before["bm:child"])
    #expect(reordered["bm:A"] != nil)
    try coordinator.submit(profile: "p", mutations: [.init(method: "moveBookmark", args: ["A", .string(bar), 2])])
    #expect(coordinator.bookmarkFacts(profileId: "p") == reordered)
    try coordinator.submit(profile: "p", mutations: [.init(method: "moveBookmark", args: ["A", .string(bar), 0]), .init(method: "moveBookmark", args: ["A", .string(bar), 2])])
    #expect(coordinator.bookmarkFacts(profileId: "p") == reordered)
    #expect(owner(dir).bookmarkFacts(profileId: "p") == reordered)
  }

  private func refusedAsStale(_ body: () throws -> Bool) -> Bool {
    do {
      _ = try body()
      return false
    } catch BookmarkWriterError.staleBinding {
      return true
    } catch {
      return false
    }
  }

  @Test func factCallsRefuseAProfileThatMovedToAnotherEngine() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = BookmarkCoordinator(profiles: ["p": "E1", "q": "E2"], defaultProfile: "p", owningProfiles: ["E1": "p", "E2": "q"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    coordinator.seed(engine: "E1", document: document(engine: "E1"), ready: true)
    coordinator.seed(engine: "E2", document: document(engine: "E2"), ready: true)
    try coordinator.submit(profile: "q", mutations: [rename("Pending on E2")])
    let other = try #require(coordinator.bookmarkFacts(profileId: "q")["bm:b0"])
    try coordinator.submit(profile: "p", mutations: [rename("Publishing from E1")])
    let publishing = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(publishing.seq > other.seq)
    #expect(coordinator.remap(profiles: ["p": "E2", "q": "E2"], defaultProfile: "p", owningProfiles: ["E2": "q"]))
    #expect(refusedAsStale { try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: publishing.seq, mintedHLC: "00000003f.0001.device")]) })
    #expect(refusedAsStale { try coordinator.clearBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: publishing.seq)]) })
    #expect(refusedAsStale { try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", hlc: "00000003f.0002.remote")]) })
    #expect(coordinator.bookmarkFacts(profileId: "q")["bm:b0"] == other)
    #expect(coordinator.desiredView(engine: "E2").lastSeen["bm:b0"] == nil)
    #expect(coordinator.desiredView(engine: "E1").facts["bm:b0"] == publishing)
    #expect(try coordinator.clearBookmarkFacts(profileId: "p", expectedEngine: "E2", records: [(key: "bm:b0", seq: other.seq)]))
    #expect(coordinator.bookmarkFacts(profileId: "q").isEmpty)
  }

  @Test func anEditThatSurvivesAnAckMintsAfterTheAckedHLC() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    coordinator.seed(engine: "", document: document(), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("Published")])
    let published = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    try coordinator.submit(profile: "p", mutations: [rename("Same millisecond")])
    let pending = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(pending.at == published.at && pending.after == nil)
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: published.seq, mintedHLC: "00000003f.0001.device")]))
    let surviving = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
    #expect(surviving.seq == pending.seq && surviving.at == pending.at && surviving.link == pending.link)
    #expect(surviving.after == "00000003f.0001.device")
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: published.seq, mintedHLC: "00000003f.0000.device")]))
    #expect(coordinator.bookmarkFacts(profileId: "p")["bm:b0"]?.after == "00000003f.0001.device")
    #expect(owner(dir).bookmarkFacts(profileId: "p")["bm:b0"] == surviving)
  }

  @Test func factsAloneNeverKeepAnUnmappedEnginePumped() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let inactive = owner(dir, enabled: false)
    inactive.seed(engine: "", document: document(), ready: true)
    try inactive.submit(profile: "p", mutations: [rename("Dormant")])
    #expect(inactive.desiredView(engine: "").facts.isEmpty)
    let other = try directory()
    defer { try? FileManager.default.removeItem(at: other) }
    let coordinator = BookmarkCoordinator(profiles: ["p": "E1"], defaultProfile: "p", owningProfiles: ["E1": "p"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: other))
    coordinator.seed(engine: "E1", document: document(engine: "E1"), ready: true)
    try coordinator.submit(profile: "p", mutations: [rename("Pending fact")])
    #expect(coordinator.completeRead(engine: "E1", document: coordinator.desiredView(engine: "E1").document, capturedRevision: 0))
    #expect(coordinator.remap(profiles: ["p": "E2"], defaultProfile: "p", owningProfiles: ["E2": "p"]))
    #expect(!coordinator.desiredView(engine: "E1").facts.isEmpty)
    #expect(coordinator.ownerProfileForTesting(engine: "E1") == "p")
    #expect(!coordinator.catalogEngines.contains("E1"))
    #expect(!coordinator.ownsPump(engine: "E1", epoch: coordinator.claimPump()))
  }

  @Test func unchangedFactCallsWriteNothing() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writes = FactWriteCounter()
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { url in
      writes.count += 1
      try sync(url)
    }
    let coordinator = owner(dir, operations: operations)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "link"]))
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0005.remote")]))
    let settled = writes.count
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0005.remote"), (key: "bm:b0", hlc: "00000003f.0001.remote")]))
    #expect(coordinator.setBookmarkSyncLinks(["p": "link"]))
    #expect(try coordinator.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: 9)]))
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", seq: 9, mintedHLC: "00000003f.0002.device")]))
    #expect(writes.count == settled)
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0006.remote")]))
    #expect(writes.count > settled)
  }

  @Test func observingBeforeTheFirstReadRecordsNoView() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = owner(dir)
    #expect(try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "", records: [(key: "bm:b0", hlc: "00000003f.0005.remote")]))
    #expect(coordinator.desiredView(engine: "").lastSeen.isEmpty)
    #expect(owner(dir).desiredView(engine: "").lastSeen.isEmpty)
  }
}

private final class FactBookmarksHost: BookmarksHost {
  var bookmarks: JSONValue
  init(_ bookmarks: JSONValue) { self.bookmarks = bookmarks }
  func bookmarksReady(_ profileId: String) -> Bool { true }
  func setBookmarks(_ value: JSONValue) { bookmarks = value }
  func engineProfile(_ profileId: String) -> String { "" }
}

private final class FactWriteCounter: @unchecked Sendable {
  var count = 0
}

private enum FactTestFailure: Error { case injected }

private final class FactLockProbe: @unchecked Sendable {
  weak var owner: BookmarkCoordinator?
  private(set) var checks = 0

  func readDuringCallback() throws {
    guard let owner else { throw FactTestFailure.injected }
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      _ = owner.bookmarkFacts(profileId: "p")
      _ = owner.writerSnapshot(profile: "p")
      done.signal()
    }
    guard done.wait(timeout: .now() + 1) == .success else { throw FactTestFailure.injected }
    checks += 1
  }
}
