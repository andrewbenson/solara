import Foundation
import Testing
import Synchronization
import SolaraModel
@testable import SolaraEngine

@Suite(.serialized) @MainActor struct BookmarkProjectionTests {
  @Test func sharingAliasesProjectOneEngineRevision() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    f.owner.coordinator.seed(engine: "", document: f.document, ready: true)
    let projection = try f.owner.projection()
    #expect(projection["profiles"]?["p"]?["engine"]?.string == "")
    #expect(projection["profiles"]?["alias"]?["engine"]?.string == "")
    #expect(projection["views"]?.object?.count == 1)
    #expect(projection["views"]?[""]?["revision"]?.string == String(f.owner.coordinator.desiredView(engine: "").revision))
    #expect(projection["views"]?[""]?["document"]?["roots"]?.object?.count == 2)
  }

  @Test func nativeDesiredChangesInvalidateProjectionWithoutUIRequest() async throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    let count = Mutex(0)
    let observer = NotificationCenter.default.addObserver(forName: NativeBookmarkOwner.projectionChanged, object: nil, queue: nil) { _ in
      count.withLock { $0 += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    f.owner.coordinator.seed(engine: "", document: f.document, ready: true)
    for _ in 0..<1000 where count.withLock({ $0 == 0 }) { await Task.yield() }
    #expect(count.withLock { $0 > 0 })
    let first = try f.owner.projection()
    var document = f.document.object ?? [:]
    var nodes = document["nodes"]?.object ?? [:]
    var node = nodes["b0"]?.object ?? [:]
    node["title"] = "From native replacement"
    nodes["b0"] = .object(node)
    document["nodes"] = .object(nodes)
    let previous = count.withLock { $0 }
    _ = try f.owner.coordinator.replaceDocument(engine: "", profile: "p", document: .object(document), expectedRevision: f.owner.coordinator.desiredView(engine: "").revision)
    for _ in 0..<1000 where count.withLock({ $0 == previous }) { await Task.yield() }
    #expect(count.withLock { $0 > previous })
    let current = try f.owner.projection()
    #expect(current["views"]?[""]?["document"]?["nodes"]?["b0"]?["title"]?.string == "From native replacement")
    #expect(current["views"]?[""]?["revision"] != first["views"]?[""]?["revision"])
  }

  @Test func projectionSeparatesDisplayFromSyncReadiness() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    f.owner.coordinator.seed(engine: "", document: f.document, ready: false)
    let view = try f.owner.projection()["views"]?[""]
    #expect(view?["hasView"]?.bool == true)
    #expect(view?["readyForSync"]?.bool == false)
    #expect(view?["document"]?["nodes"]?["b0"]?["title"]?.string == "Page")
  }

  @Test func projectionDoesNotBorrowRemovedAliasesOrRetiredRoots() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    f.owner.coordinator.seed(engine: "", document: f.document, ready: true)
    let original = try f.owner.projection()
    f.owner.remap(profiles: ["p": "next"], defaultProfile: "p")
    let remapped = try f.owner.projection()
    #expect(remapped["profiles"]?["alias"] == nil)
    #expect(remapped["views"]?[""] == nil)
    #expect(remapped["views"]?["next"]?["document"]?["roots"]?.object?.isEmpty == true)
    f.owner.remap(profiles: ["p": ""], defaultProfile: "p")
    let returned = try f.owner.projection()
    #expect(returned["owner"] == original["owner"])
    #expect(returned["profiles"]?["p"]?["generation"] != original["profiles"]?["p"]?["generation"])
    #expect(returned["views"]?[""]?["document"]?["roots"]?["alias"] == nil)
    try f.owner.retireBookmarks(engine: "")
    let retired = try f.owner.projection()
    #expect(retired["profiles"]?.object?.isEmpty == true)
    #expect(retired["views"]?.object?.isEmpty == true)
  }

  @Test func projectionPreservesBookmarkWireCodeUnits() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    let wire = #"{"nodes":{"bar@default":{"id":"bar@default","kind":"folder","parentId":null,"title":"Bar","children":["b0"],"addedAt":0},"other@default":{"id":"other@default","kind":"folder","parentId":null,"title":"Other","children":[],"addedAt":0},"b0":{"id":"b0","kind":"url","parentId":"bar@default","title":"\ud800X\udfff","url":"https://page.test","addedAt":1}},"roots":{"p":{"bar":"bar@default","other":"other@default"}}}"#
    let document = try JSONValue.parseBookmark(wire)
    f.owner.coordinator.seed(engine: "", document: document, ready: true)
    let projected = try f.owner.projection()["views"]?[""]?["document"]?["nodes"]?["b0"]?["title"]
    #expect(projected?.bookmarkText() == #""\ud800X\udfff""#)
  }

  @Test func stoppedOwnerCannotProjectAuthority() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    f.owner.stop()
    #expect(throws: BookmarkWriterError.notOwned) { try f.owner.projection() }
  }

  @Test func selectedCatalogRefusesRawWritesAndReadsWithoutClaim() async throws {
    let client = ProjectionClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { true })
    await catalog.start(engineProfiles: [""])
    await catalog.reloadBookmarks(engineProfile: "")
    await #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) {
      try await catalog.applyBookmarks(ops: [], engineProfile: "")
    }
    #expect(client.reads == 0)
    #expect(client.watches == 0)
    #expect(client.applies == 0)
  }

  @Test func selectedClaimRejectsExternalRawTranslation() async throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    let client = ProjectionClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { true })
    let pump = f.pump()
    try catalog.claimBookmarks(coordinator: f.owner.coordinator, pump: pump)
    await #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) {
      try await catalog.applyBookmarks(ops: [], engineProfile: "")
    }
    #expect(client.applies == 0)
    pump.stop()
  }

  @Test func reclaimPrunesStaleEngineSnapshots() throws {
    let f = try ProjectionFixture()
    defer { f.remove() }
    f.owner.coordinator.seed(engine: "", document: f.document, ready: true)
    let catalog = LibraryCatalog(client: ProjectionClient(), bookmarkSelection: { false })
    let first = f.pump()
    try catalog.claimBookmarks(coordinator: f.owner.coordinator, pump: first)
    #expect(catalog.bookmarks(engineProfile: "").hasView)
    f.owner.remap(profiles: ["p": "next"], defaultProfile: "p")
    first.stop(invalidate: false)
    let second = f.pump()
    try catalog.claimBookmarks(coordinator: f.owner.coordinator, pump: second)
    #expect(!catalog.bookmarks(engineProfile: "").hasView)
    #expect(catalog.bookmarkSnapshots[""] == nil)
    second.stop()
  }

  @Test func heldLegacyCompletionCannotWriteAfterSelection() async throws {
    let client = ProjectionClient()
    var selected = false
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { selected })
    client.hold = true
    let start = Task { await catalog.start(engineProfiles: [""]) }
    for _ in 0..<1000 where client.release == nil { await Task.yield() }
    #expect(client.release != nil)
    selected = true
    client.hold = false
    client.release?.resume()
    client.release = nil
    await start.value
    #expect(!catalog.bookmarks(engineProfile: "").hasView)
    #expect(client.reads == 1)
    await catalog.reloadBookmarks(engineProfile: "")
    #expect(client.reads == 1)
  }
}

@MainActor private struct ProjectionFixture {
  let directory: URL
  let owner: NativeBookmarkOwner
  let document: JSONValue = ["nodes": [
    "bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["b0"], "addedAt": 0],
    "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
    "b0": ["id": "b0", "kind": "url", "parentId": "bar@default", "title": "Page", "url": "https://page.test", "addedAt": 1]
  ], "roots": ["p": ["bar": "bar@default", "other": "other@default"], "alias": ["bar": "bar@default", "other": "other@default"]]]

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("projection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    owner = NativeBookmarkOwner(store: BookmarkPendingStore(directory: directory), profiles: ["p": "", "alias": ""], defaultProfile: "p", wake: { _ in })
  }
  func pump() -> BookmarkPump {
    BookmarkPump(coordinator: owner.coordinator, client: BookmarkEngineClient(readTree: { _ in
      EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: []), other: .init(id: "other", kind: "f", title: "Other", children: []))
    }, apply: { _, _ in .init(applied: 0, skipped: 0, invalid: []) }), clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
  }
  func remove() {
    owner.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor private final class ProjectionClient: EngineClient {
  var reads = 0
  var watches = 0
  var applies = 0
  var hold = false
  var release: CheckedContinuation<Void, Never>?
  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func watchBookmarks(engineProfile: String) async throws { watches += 1 }
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    reads += 1
    if hold { await withCheckedContinuation { release = $0 } }
    return EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: []), other: .init(id: "other", kind: "f", title: "Other", children: []))
  }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    applies += 1
    return .init(applied: ops.count, skipped: 0, invalid: [])
  }
}
