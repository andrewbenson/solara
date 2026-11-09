import CryptoKit
import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

enum BookmarkWireFixture {
  static func parse(_ source: String, checksum: String? = nil, canonical: String? = nil) throws -> JSONValue {
    let digest = checksum ?? SHA256.hash(data: Data((canonical ?? source).utf8)).map { String(format: "%02x", $0) }.joined()
    let bytes = Data(("{\"version\":2,\"payload\":" + source + ",\"checksum\":\"" + digest + "\"}").utf8)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireFixture")
    let operations = BookmarkPendingFileOperations(read: { _ in bytes }, writeNew: { _, _ in }, syncFile: { _ in }, rename: { _, _ in }, syncDirectory: { _ in }, remove: { _ in }, exists: { $0.lastPathComponent == BookmarkPendingStore.journalName })
    let loaded = BookmarkPendingStore(directory: directory, fileOperations: operations).load()
    #expect(loaded.recoveryNotice == nil)
    return try #require(loaded.payload)
  }

  static func firstAddDocument(syncKey: JSONValue?) -> JSONValue {
    let id = "6510498a-3567-4000-a847-b99ec0908c85"
    var document = BookmarkCoordinatorTests().document([]).object ?? [:]
    var nodes = document["nodes"]?.object ?? [:]
    var bar = nodes["bar@default"]?.object ?? [:]
    bar["children"] = [.string(id)]
    nodes["bar@default"] = .object(bar)
    var node: JSONObject = ["id": .string(id), "kind": "url", "parentId": "bar@default",
      "title": "Page", "url": "https://x.test/", "addedAt": 10, "favicon": nil]
    node["syncKey"] = syncKey
    nodes[id] = .object(node)
    document["nodes"] = .object(nodes)
    return .object(document)
  }

  static func text(_ payload: JSONValue) throws -> String {
    var bytes = Data()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireFixture")
    let operations = BookmarkPendingFileOperations(read: { _ in Data() }, writeNew: { _, data in bytes = data }, syncFile: { _ in }, rename: { _, _ in }, syncDirectory: { _ in }, remove: { _ in }, exists: { _ in false })
    try BookmarkPendingStore(directory: directory, fileOperations: operations).write(payload)
    let envelope = String(decoding: bytes, as: UTF8.self)
    let start = try #require(envelope.range(of: "\"payload\":"))
    let end = try #require(envelope.range(of: ",\"checksum\":", options: .backwards))
    return String(envelope[start.upperBound..<end.lowerBound])
  }
}

struct BookmarkWireTests {
  @Test func journalPreservesExactStringsAndObjectKeys() throws {
    let source = #"{"\ud800":"\ud800","\udfff":"\udfff","�":"�","󰀀":"󰀀󰀁","😀":"😀"}"#
    let canonical = #"{"\ud800":"\ud800","😀":"😀","󰀀":"󰀀󰀁","\udfff":"\udfff","�":"�"}"#
    let value = try BookmarkWireFixture.parse(source, canonical: canonical)
    #expect(value.object?.count == 5)
    #expect(try BookmarkWireFixture.text(value) == source)
    #expect(try BookmarkWireFixture.parse(BookmarkWireFixture.text(value), canonical: canonical) == value)
  }

  @Test func duplicateWireKeysOverwriteOnlyTheSameCodeUnits() throws {
    let source = #"{"\ud800":1,"\ud801":2,"\ud800":3,"�":4}"#
    let canonical = #"{"\ud800":3,"\ud801":2,"�":4}"#
    let value = try BookmarkWireFixture.parse(source, canonical: canonical)
    #expect(value.object?.count == 3)
    #expect(try BookmarkWireFixture.text(value) == canonical)
  }

  @Test func wireRecordKeysKeepOriginalUnitsInsideScopedPredecessors() throws {
    let strings = try BookmarkWireFixture.parse(#"["bm:\ud800","bm:󰀀󰀁"]"#).array ?? []
    let keys = strings.compactMap(\.string)
    try #require(keys.count == 2)
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true)
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document([]), ready: true)
    _ = owner.setBookmarkSyncLinks(["p": "chain"])
    try owner.observeRemoteRecords(profileId: "p", expectedEngine: "", records: keys.map { (key: $0, hlc: "001") }, expectedLink: "chain")
    let seen = JSONValue.object(owner.desiredView(engine: "").lastSeen.mapValues(JSONValue.string))
    #expect(try BookmarkWireFixture.text(seen) == #"{"bm:[\"chain\",\"bm:\\ud800\"]":"001","bm:[\"chain\",\"bm:󰀀󰀁\"]":"001"}"#)
  }

  @Test func bookmarkUUIDHashesOriginalUTF16Units() throws {
    let high = try #require(BookmarkWireFixture.parse(#""\ud800""#).string)
    let low = try #require(BookmarkWireFixture.parse(#""\udfff""#).string)
    #expect(BookmarkRecordIdentity.bookmarkUuidFor(high) == "6510498a-3567-4000-a847-b99ec0908c85")
    #expect(BookmarkRecordIdentity.bookmarkUuidFor(low) == "0f0dfed0-8fae-4577-895e-38d39c335997")
    #expect(BookmarkRecordIdentity.bookmarkUuidFor(high) != BookmarkRecordIdentity.bookmarkUuidFor("�"))
  }

  @Test func desiredIDsFactsAndReceiptsSurviveRestartWithoutNormalization() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWire-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let strings = try BookmarkWireFixture.parse(#"["\ud800","\udfff","�","󰀀󰀁"]"#).array ?? []
    let ids = strings.compactMap(\.string)
    try #require(ids.count == 4)
    var document = BookmarkCoordinatorTests().document([]).object ?? [:]
    var nodes = document["nodes"]?.object ?? [:]
    var bar = nodes["bar@default"]?.object ?? [:]
    bar["children"] = .array(strings)
    nodes["bar@default"] = .object(bar)
    for (index, id) in ids.enumerated() {
      nodes[id] = ["id": .string(id), "kind": "url", "parentId": "bar@default", "title": strings[index], "url": .string("https://x.test/" + id), "addedAt": 0]
    }
    document["nodes"] = .object(nodes)
    func owner() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 123 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
    }
    let first = owner()
    first.seed(engine: "", document: .object(document), ready: true)
    let mutations = [BookmarkMutation(method: "updateBookmark", args: [strings[0], ["title": strings[1]]])]
    let accepted = try first.submit(profile: "p", mutations: mutations, requestID: "wire-request")
    let second = owner()
    #expect(second.recoveryNotice == nil)
    #expect(second.desiredView(engine: "").document == accepted.view.document)
    #expect(try second.submit(profile: "p", mutations: mutations, requestID: "wire-request").results == accepted.results)
    #expect(second.bookmarkFacts(profileId: "p")["bm:" + ids[0]] != nil)
    let before = BookmarkFlat(document: .object(document), engine: "")
    let after = BookmarkFlat(document: second.desiredView(engine: "").document, engine: "")
    #expect(try BookmarkWireFixture.text(.array(BookmarkReconcile.operations(from: before, to: after, engine: ""))) == #"[{"op":"update","id":"\ud800","t":"\udfff","u":"https://x.test/\ud800"}]"#)
    try second.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: [strings[0]])])
    #expect(second.desiredView(engine: "").document["nodes"]?[ids[0]] == nil)
    #expect(second.desiredView(engine: "").document["nodes"]?[ids[1]] != nil)
    #expect(second.desiredView(engine: "").document["nodes"]?[ids[2]] != nil)
  }

  @Test func launchCachePreservesTitlesAndLegacyIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireCache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = BookmarkCoordinatorTests().document(["https://x.test/"])
    let records = document["nodes"]?.object?.values ?? []
    let cache: JSONValue = ["version": 1, "trees": ["": .array(records)]]
    let cacheSource = cache.text().replacingOccurrences(of: #""title":"Page""#, with: #""title":"\ud800""#)
    let cacheURL = directory.appendingPathComponent("bookmarks-cache.json")
    try Data(cacheSource.utf8).write(to: cacheURL)
    let cached = BookmarkLaunchCache(directory: directory).load(profiles: ["p": ""], defaultProfile: "p")
    #expect(try BookmarkWireFixture.text(cached.documents[""]?["nodes"]?["b0"]?["title"] ?? .null) == #""\ud800""#)
    try FileManager.default.removeItem(at: cacheURL)
    let legacy: JSONValue = ["bookmarks": document]
    let legacySource = legacy.text().replacingOccurrences(of: #""b0""#, with: #""\ud800""#)
    try Data(legacySource.utf8).write(to: directory.appendingPathComponent("bookmarks.json"))
    let migrated = BookmarkLaunchCache(directory: directory).load(profiles: ["p": ""], defaultProfile: "p")
    #expect(migrated.documents[""]?["nodes"]?["bar@default"]?["children"] == ["6510498a-3567-4000-a847-b99ec0908c85"])
  }

  @Test func chromeDisplayReadKeepsOriginalTitleAndSyncKey() throws {
    let strings = try BookmarkWireFixture.parse(#"["\ud800","\udfff"]"#).array ?? []
    try #require(strings.count == 2)
    let id = "0f0dfed0-8fae-4577-895e-38d39c335997"
    var document = BookmarkCoordinatorTests().document(["https://x.test/"]).object ?? [:]
    var nodes = document["nodes"]?.object ?? [:]
    var original = nodes["b0"]?.object ?? [:]
    original["id"] = .string(id)
    original["title"] = strings[0]
    original["syncKey"] = strings[1]
    nodes.removeValue(forKey: "b0")
    nodes[id] = .object(original)
    var bar = nodes["bar@default"]?.object ?? [:]
    bar["children"] = [.string(id)]
    nodes["bar@default"] = .object(bar)
    document["nodes"] = .object(nodes)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireRead-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func reopened() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
    }
    let first = reopened()
    first.seed(engine: "", document: BookmarkCoordinatorTests().document([]), ready: true)
    try first.replaceDocument(engine: "", document: .object(document), expectedRevision: first.desiredView(engine: "").revision)
    let captured = first.desiredView(engine: "")
    let delta = BookmarkReconcile.operations(from: BookmarkFlat(document: BookmarkCoordinatorTests().document([]), engine: ""), to: BookmarkFlat(document: captured.document, engine: ""), engine: "")
    #expect(delta.first?["op"] == "add")
    #expect(delta.first?["key"] == strings[1])
    let epoch = first.claimPump()
    #expect(first.beginPush(engine: "", captured: captured, epoch: epoch))
    #expect(first.completePush(engine: "", captured: captured, epoch: epoch, succeeded: true, nowMs: 0))
    let owner = reopened()
    #expect(owner.recoveryNotice == nil)
    var fetched = original
    fetched["title"] = "�"
    fetched["syncKey"] = "�"
    nodes[id] = .object(fetched)
    document["nodes"] = .object(nodes)
    owner.completeRead(engine: "", document: .object(document), capturedRevision: owner.desiredView(engine: "").revision)
    let view = owner.desiredView(engine: "")
    #expect(view.document["nodes"]?[id]?["title"] == strings[0])
    #expect(view.document["nodes"]?[id]?["syncKey"] == strings[1])
    #expect(owner.bookmarkFacts(profileId: "p").isEmpty)
    #expect(reopened().desiredView(engine: "").document == view.document)
    fetched["title"] = "Changed in Chrome"
    nodes[id] = .object(fetched)
    document["nodes"] = .object(nodes)
    owner.completeRead(engine: "", document: .object(document), capturedRevision: view.revision)
    #expect(owner.desiredView(engine: "").document["nodes"]?[id]?["title"] == "Changed in Chrome")
  }

  @Test(arguments: [false, true], [false, true])
  func firstChromeAddRecoveryKeepsOriginalSyncKey(afterCrash: Bool, newerDesiredKey: Bool) throws {
    let rawKey = try #require(BookmarkWireFixture.parse(#""\ud800""#).string)
    let id = "6510498a-3567-4000-a847-b99ec0908c85"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireFirstAdd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func reopen() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true,
        pendingStore: BookmarkPendingStore(directory: directory))
    }
    let first = reopen()
    first.seed(engine: "", document: BookmarkCoordinatorTests().document([]), ready: true)
    #expect(first.setBookmarkSyncLinks(["p": "chain"]))
    #expect(try first.observeRemoteRecords(profileId: "p", expectedEngine: "",
      records: [(key: "bm:" + rawKey, hlc: "001")], expectedLink: "chain"))
    try first.replaceDocument(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: .string(rawKey)),
      expectedRevision: first.desiredView(engine: "").revision)
    let captured = first.desiredView(engine: "")
    let epoch = first.claimPump()
    #expect(first.beginPush(engine: "", captured: captured, epoch: epoch))
    if newerDesiredKey {
      let laterKey = try BookmarkWireFixture.parse(#""\udfff""#)
      try first.replaceDocument(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: laterKey),
        expectedRevision: first.desiredView(engine: "").revision)
    }
    if !afterCrash {
      #expect(first.completePush(engine: "", captured: captured, epoch: epoch, succeeded: false, nowMs: 0))
      #expect(first.desiredView(engine: "").requiresRead)
    }
    let recovered = afterCrash ? reopen() : first
    #expect(recovered.recoveryNotice == nil)
    #expect(recovered.desiredView(engine: "").inFlightTarget != nil)
    let fetched = BookmarkWireFixture.firstAddDocument(syncKey: "�")
    #expect(recovered.completeRead(engine: "", document: fetched,
      capturedRevision: recovered.desiredView(engine: "").revision))
    let key = try #require(recovered.desiredView(engine: "").document["nodes"]?[id]?["syncKey"])
    #expect(try BookmarkWireFixture.text(key) == #""\ud800""#)
    #expect(recovered.desiredView(engine: "").inFlightTarget == nil)

    let again = reopen()
    #expect(again.recoveryNotice == nil)
    #expect(again.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == .string(rawKey))
    #expect(again.completeRead(engine: "", document: fetched,
      capturedRevision: again.desiredView(engine: "").revision))
    #expect(again.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == .string(rawKey))
    #expect(again.bookmarkFacts(profileId: "p").isEmpty)
    try again.submit(profile: "p", mutations: [
      .init(method: "updateBookmark", args: [.string(id), ["title": "Renamed"]])
    ])
    let fact = try #require(again.bookmarkFacts(profileId: "p")["bm:" + rawKey])
    #expect(fact.after == "001")
    #expect(fact.link == "chain")
    #expect(again.bookmarkFacts(profileId: "p")["bm:" + id] == nil)
  }

  @Test(arguments: ["changed-in-chrome", ""])
  func attemptedFirstAddDoesNotOverwriteChangedExternalSyncKey(externalKey: String) throws {
    let rawKey = try BookmarkWireFixture.parse(#""\ud800""#)
    let id = "6510498a-3567-4000-a847-b99ec0908c85"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireChangedKey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func reopen() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p",
        pendingStore: BookmarkPendingStore(directory: directory))
    }
    let first = reopen()
    first.seed(engine: "", document: BookmarkCoordinatorTests().document([]), ready: true)
    try first.replaceDocument(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: rawKey),
      expectedRevision: first.desiredView(engine: "").revision)
    let captured = first.desiredView(engine: "")
    #expect(first.beginPush(engine: "", captured: captured, epoch: first.claimPump()))
    let recovered = reopen()
    #expect(recovered.recoveryNotice == nil)
    #expect(recovered.completeRead(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: .string(externalKey)),
      capturedRevision: recovered.desiredView(engine: "").revision))
    let expected: JSONValue? = externalKey.isEmpty ? nil : .string(externalKey)
    #expect(recovered.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == expected)
    let again = reopen()
    #expect(again.recoveryNotice == nil)
    #expect(again.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == expected)
  }

  @Test func unattemptedFirstAddDoesNotRestoreSyncKeyFromDesired() throws {
    let rawKey = try BookmarkWireFixture.parse(#""\ud800""#)
    let id = "6510498a-3567-4000-a847-b99ec0908c85"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkWireUnattempted-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func reopen() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p",
        pendingStore: BookmarkPendingStore(directory: directory))
    }
    let first = reopen()
    first.seed(engine: "", document: BookmarkCoordinatorTests().document([]), ready: true)
    try first.replaceDocument(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: rawKey),
      expectedRevision: first.desiredView(engine: "").revision)
    let recovered = reopen()
    #expect(recovered.recoveryNotice == nil)
    #expect(recovered.desiredView(engine: "").inFlightTarget == nil)
    #expect(recovered.completeRead(engine: "", document: BookmarkWireFixture.firstAddDocument(syncKey: "�"),
      capturedRevision: recovered.desiredView(engine: "").revision))
    #expect(recovered.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == "�")
    let again = reopen()
    #expect(again.recoveryNotice == nil)
    #expect(again.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == "�")
  }

  @Test func nativeDisplayEditDoesNotRewriteOriginalWireURL() throws {
    let raw = try BookmarkWireFixture.parse(#""https://x.test/\ud800""#)
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    var document = BookmarkCoordinatorTests().document(["https://x.test/"]).object ?? [:]
    var nodes = document["nodes"]?.object ?? [:]
    var node = nodes["b0"]?.object ?? [:]
    node["url"] = raw
    nodes["b0"] = .object(node)
    document["nodes"] = .object(nodes)
    owner.seed(engine: "", document: .object(document), ready: true)
    let operations: JSONValue = [["op": "update", "id": "b0", "t": "Renamed", "u": "https://x.test/�"]]
    let receipt = try owner.submit(profile: "p", mutations: [.init(method: "applyBookmarkOperations", args: [operations, true])])
    #expect(receipt.view.document["nodes"]?["b0"]?["title"] == "Renamed")
    #expect(try BookmarkWireFixture.text(receipt.view.document["nodes"]?["b0"]?["url"] ?? .null) == #""https://x.test/\ud800""#)
  }

  @Test func malformedSyncedPositionsKeepJSCodeUnitOrderInJournal() throws {
    let source = #"{"\ud83d":"first","\ud83d0V":"second","":"third","�":"fourth"}"#
    let value = try BookmarkWireFixture.parse(source)
    #expect(value.object?.count == 4)
    #expect(try BookmarkWireFixture.text(value) == source)
  }
}
