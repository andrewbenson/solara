import Foundation
import SolaraModel
import Testing
@testable import SolaraEngine

@Suite @MainActor struct BookmarkCatalogLeaseTests {
  @Test func claimSurvivesARemapThroughANewerPump() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    await f.catalog.start(engineProfiles: [""])
    f.owner.remap(profiles: ["p": "", "alias": "", "new": "extra"], defaultProfile: "p")
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.claim() }
    let replacement = f.makePump()
    try f.catalog.claimBookmarks(coordinator: f.owner, pump: replacement)
    for engine in f.owner.catalogEngines { replacement.requestRead(engine: engine) }
    await replacement.settle(engine: "")
    await replacement.settle(engine: "extra")
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "After remap")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "After remap")
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Stream after remap"]])])
    for _ in 0..<2000 where f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title != "Stream after remap" { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Stream after remap")
    #expect(f.catalog.bookmarks(engineProfile: "extra").hasView)
    #expect(f.client.rawBatches.isEmpty)
    await f.transport.releaseApply()
    await replacement.settle(engine: "")
  }

  @Test func reclaimByAnOlderOrForeignPumpIsRefused() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let replacement = f.makePump()
    let otherCatalog = LibraryCatalog(client: f.client, bookmarkSelection: { false })
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try otherCatalog.claimBookmarks(coordinator: f.owner, pump: replacement) }
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.claim() }
    let foreign = CatalogLeaseFixture()
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.catalog.claimBookmarks(coordinator: foreign.owner, pump: foreign.pump) }
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.catalog.claimBookmarks(coordinator: f.owner, pump: foreign.pump) }
    try f.catalog.claimBookmarks(coordinator: f.owner, pump: replacement)
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.claim() }
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.catalog.claimBookmarks(coordinator: f.owner, pump: replacement) }
    let next = f.makePump()
    try f.catalog.claimBookmarks(coordinator: f.owner, pump: next)
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
  }

  @Test func engineAddedAfterClaimGetsAStream() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    f.owner.remap(profiles: ["p": "", "new": "extra"], defaultProfile: "p")
    let replacement = f.makePump()
    try f.catalog.claimBookmarks(coordinator: f.owner, pump: replacement)
    for engine in f.owner.catalogEngines { replacement.requestRead(engine: engine) }
    await replacement.settle(engine: "")
    await replacement.settle(engine: "extra")
    await f.catalog.start(engineProfiles: ["extra"])
    await f.catalog.start(engineProfiles: ["extra"])
    try f.owner.submit(profile: "new", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "New engine stream"]])])
    for _ in 0..<2000 where f.catalog.bookmarks(engineProfile: "extra").nodes["b0"]?.title != "New engine stream" { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(f.catalog.bookmarks(engineProfile: "extra").nodes["b0"]?.title == "New engine stream")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
    #expect(f.client.reads == 0)
    replacement.stop()
  }

  @Test func startOpensAMissingClaimedEngineStream() async throws {
    let f = CatalogLeaseFixture()
    f.catalog.bookmarkClaim = try f.pump.claimCatalog(coordinator: f.owner)
    await f.catalog.start(engineProfiles: [""])
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Started stream"]])])
    for _ in 0..<2000 where f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title != "Started stream" { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Started stream")
  }

  @Test func badOpMidBatchKeepsThePrefixAndSkipsTheRest() async throws {
    for bad: JSONValue in [["op": "unknown", "id": "oops"], ["id": "oops"]] {
      let f = CatalogLeaseFixture()
      try f.claim()
      let receipt = try f.owner.submit(profile: "p", mutations: [.init(method: "applyBookmarkOperations", args: [[
        ["op": "add", "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "k": "u", "u": "", "parent": "bar"],
        ["op": "update", "id": "b0", "t": "Prefix"],
        bad,
        ["op": "update", "id": "b0", "t": "Suffix"]
      ]])])
      #expect(receipt.results == [["applied": 1, "skipped": 2, "invalid": ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"]]])
      #expect(receipt.view.document["nodes"]?["b0"]?["title"] == "Prefix")
      #expect(receipt.view.document["nodes"]?["oops"] == nil)
      for _ in 0..<2000 where f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title != "Prefix" { try await Task.sleep(nanoseconds: 1_000_000) }
      #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Prefix")
    }
  }

  @Test func staleClaimAfterDurableAcceptStillReturnsTheResult() async throws {
    for _ in 0..<10 {
      let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("journal-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let gate = CatalogJournalGate()
      let f = CatalogLeaseFixture(directory: directory, operations: gate.operations)
      try f.claim()
      let stream = f.owner.desiredViews(engine: "")
      var stoppedAfterAccept = false
      let stopAfterAccept = Task(priority: .high) {
        for await view in stream where view.document["nodes"]?["b0"]?["title"] == "Durable" {
          f.pump.stop()
          stoppedAfterAccept = true
          return
        }
      }
      defer { stopAfterAccept.cancel() }
      let command = Task(priority: .low) {
        let result = try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Durable")], engineProfile: "")
        return (result, stoppedAfterAccept)
      }
      for _ in 0..<2000 where !gate.holding { try await Task.sleep(nanoseconds: 1_000_000) }
      #expect(gate.holding)
      gate.release()
      let (result, stoppedBeforeReturn) = try await command.value
      await stopAfterAccept.value
      await f.transport.releaseApply()
      await f.pump.settle(engine: "")
      guard stoppedBeforeReturn else { continue }
      #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
      #expect(throws: BookmarkCoordinatorError.staleRevision) { try f.catalog.bookmarkClaim?.validate(engine: "") }
      #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Durable")
      let restored = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
      #expect(restored.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Durable")
      #expect(f.client.rawBatches.isEmpty)
      return
    }
    Issue.record("The claim did not become stale before the accepted command returned")
  }

  @Test func claimedCatalogPublishesDesiredViewBeforeChromeConfirms() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let stream = f.catalog.observeBookmarks(engineProfile: "")
    var latest: BookmarkSnapshot?
    let observation = Task { for await snapshot in stream { latest = snapshot } }
    defer { observation.cancel() }
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
    let receipt = try await f.pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Desired"]])])
    for _ in 0..<2000 where latest?.nodes["b0"]?.title != "Desired" { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(latest?.nodes["b0"]?.title == "Desired")
    #expect((latest?.revision ?? 0) >= Int(receipt.view.revision))
    #expect(f.transport.tree.bar.children?.first?.title == "Page")
    #expect(f.client.rawBatches.isEmpty)
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func unreadyCachedViewIsDisplayableButNotReadyForSync() async throws {
    let f = CatalogLeaseFixture(ready: false)
    try f.claim()
    let snapshot = f.catalog.bookmarks(engineProfile: "")
    #expect(snapshot.hasView)
    #expect(snapshot.ready)
    #expect(!snapshot.readyForSync)
    #expect(snapshot.nodes["b0"]?.title == "Page")
    #expect(snapshot.roots == BookmarkRoots(bar: "bar@default", other: "other@default"))
    #expect(f.client.reads == 0)
  }

  @Test func unclaimedCatalogKeepsTheCommittedFetcher() async throws {
    let f = CatalogLeaseFixture()
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Desired only"]])])
    await f.catalog.start(engineProfiles: [""])
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
    #expect(f.client.reads == 1)
    f.client.tree.bar.children?[0].title = "External"
    f.client.change?("")
    for _ in 0..<100 where f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title != "External" { await Task.yield() }
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "External")
    #expect(f.client.reads == 2)
    #expect(f.transport.batches.isEmpty)
  }

  @Test func unclaimedCatalogNeverTouchesThePumpOrTheJournal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writes = CatalogJournalWrites()
    let f = CatalogLeaseFixture(directory: directory, operations: writes.operations)
    let journalWritesAfterSetup = writes.count
    await f.catalog.start(engineProfiles: [""])
    f.client.change?("")
    for _ in 0..<100 where f.client.reads < 2 { await Task.yield() }
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Raw")], engineProfile: "")
    await f.catalog.reloadBookmarks(engineProfile: "")
    await f.catalog.reload(engineProfile: "")
    await f.pump.settle(engine: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
    #expect(f.client.rawBatches.count == 1)
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Raw")
    #expect(f.transport.reads == 0)
    #expect(f.transport.batches.isEmpty)
    #expect(writes.count == journalWritesAfterSetup)
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Page")
  }

  @Test func claimedBookmarkCommandSubmitsToThePumpNotRawApply() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Accepted")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Accepted")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Accepted")
    #expect(f.client.rawBatches.isEmpty)
    #expect(f.client.reads == 0)
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
    #expect(f.transport.batches.count == 1)
    #expect(f.transport.batches.first?.first?.title == "Accepted")
  }

  @Test func unclaimedBookmarkCommandStillAppliesRawOps() async throws {
    let f = CatalogLeaseFixture()
    await f.catalog.start(engineProfiles: [""])
    let ops = [BookmarkOperation(op: "update", id: "b0", title: "Committed")]
    f.client.result = .init(applied: 1, skipped: 2, invalid: ["invalid"])
    let result = try await f.catalog.applyBookmarks(ops: ops, engineProfile: "")
    #expect(result == f.client.result)
    #expect(f.client.rawBatches == [ops])
    #expect(f.client.reads == 2)
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Committed")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Page")
  }

  @Test func noMainActorBlockingOnClaimedCommand() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = CatalogJournalGate()
    let f = CatalogLeaseFixture(directory: directory, operations: gate.operations)
    try f.claim()
    var finished = false
    let command = Task {
      let result = try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Durable")], engineProfile: "")
      finished = true
      return result
    }
    var sawHeldWrite = false
    for _ in 0..<2000 where !sawHeldWrite {
      try await Task.sleep(nanoseconds: 1_000_000)
      if gate.holding {
        sawHeldWrite = true
        #expect(!finished)
        #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
      }
    }
    gate.release()
    #expect(sawHeldWrite)
    _ = try await command.value
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Durable")
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func claimsAreColdAndOneTime() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let other = LibraryCatalog(client: f.client, bookmarkSelection: { false })
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try other.claimBookmarks(coordinator: f.owner, pump: f.pump) }
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.claim() }
    let started = CatalogLeaseFixture()
    await started.catalog.start(engineProfiles: [""])
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try started.claim() }
    let admitted = CatalogLeaseFixture()
    _ = try await admitted.catalog.applyBookmarks(ops: [], engineProfile: "")
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try admitted.claim() }
  }

  @Test func stoppedAndRemappedClaimsNeverFallBackToRawApply() async throws {
    for remap in [false, true] {
      let f = CatalogLeaseFixture()
      try f.claim()
      if remap { f.owner.remap(profiles: ["p": "other"], defaultProfile: "p") }
      else { f.pump.stop() }
      await #expect(throws: BookmarkCoordinatorError.staleRevision) {
        try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Rejected")], engineProfile: "")
      }
      await f.catalog.reloadBookmarks(engineProfile: "")
      #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
      #expect(f.client.rawBatches.isEmpty)
      #expect(f.client.reads == 0)
    }
  }

  @Test func claimedApplyPreservesIDsOrderAndIfAbsent() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [
      .init(op: "add", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kind: "f", title: "Folder", addedAt: 123, parent: "bar", index: 0),
      .init(op: "add", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", kind: "u", title: "Given", url: "https://given.test", addedAt: 456, syncKey: "legacy", parent: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", index: 0),
      .init(op: "move", id: "b0", parent: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", index: 0),
      .init(op: "add", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", kind: "u", title: "Ignored", url: "https://ignored.test", parent: "other", ifAbsent: true)
    ], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 4, skipped: 0, invalid: []))
    let view = f.owner.desiredView(engine: "")
    #expect(view.document["nodes"]?["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?["children"] == ["b0", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
    #expect(view.document["nodes"]?["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]?["title"] == "Given")
    #expect(view.document["nodes"]?["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]?["addedAt"] == 456)
    #expect(view.document["nodes"]?["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]?["syncKey"] == "legacy")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]?.parentId == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    #expect(f.client.rawBatches.isEmpty)
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func claimedApplyReportsDesiredPartialAcceptance() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [
      .init(op: "add", id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", kind: "u", url: "", parent: "bar"),
      .init(op: "update", id: "b0", title: "Accepted"),
      .init(op: "remove", id: "missing"),
      .init(op: "update", id: "b0", title: "Not reached")
    ], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 2, invalid: ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"]))
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Accepted")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["cccccccc-cccc-4ccc-8ccc-cccccccccccc"] == nil)
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func claimedUnknownOperationDoesNotBecomeAnAddition() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "unknown", id: "oops", parent: "bar")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 0, skipped: 1, invalid: []))
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["oops"] == nil)
    #expect(f.client.rawBatches.isEmpty)
    #expect(f.transport.batches.isEmpty)
  }


  @Test func mismatchedPumpDoesNotConsumeTheClaim() throws {
    let f = CatalogLeaseFixture()
    let other = CatalogLeaseFixture()
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) { try f.catalog.claimBookmarks(coordinator: f.owner, pump: other.pump) }
    try f.claim()
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
  }

  @Test func claimedReloadAndEventsReadThroughThePump() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    await f.catalog.start(engineProfiles: [""])
    #expect(f.client.reads == 0)
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending"]])])
    f.transport.tree.bar.children?[0].title = "External"
    f.client.change?("")
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
    await f.catalog.reloadBookmarks(engineProfile: "")
    #expect(f.transport.reads == 2)
    #expect(f.client.reads == 0)
    #expect(f.client.rawBatches.isEmpty)
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Pending")
  }

  @Test func failedJournalDoesNotPublishOrFallBackToRawApply() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw BookmarkPendingStoreError.unavailable }
    let f = CatalogLeaseFixture(directory: directory, operations: operations)
    try f.claim()
    await #expect(throws: BookmarkPendingStoreError.unavailable) {
      try await f.catalog.applyBookmarks(ops: [.init(op: "update", id: "b0", title: "Rejected")], engineProfile: "")
    }
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Page")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
    #expect(f.client.rawBatches.isEmpty)
    #expect(f.transport.batches.isEmpty)
  }


  @Test func firstClaimedAddCreatesDisplayRootsBeforeReadiness() async throws {
    let f = CatalogLeaseFixture(seed: false)
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "add", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kind: "u", title: "First", url: "https://first.test", parent: "bar")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.title == "First")
    #expect(f.owner.desiredView(profile: "p").document["roots"]?["p"]?["bar"] == "bar@default")
    #expect(f.owner.desiredView(profile: "alias").document["roots"]?["alias"]?["bar"] == "bar@default")
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func claimedAddDefaultsUnknownKindToURL() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "add", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kind: "unknown", title: "URL", url: "https://kind.test", parent: "bar")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 1, skipped: 0, invalid: []))
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.kind == "url")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.url == "https://kind.test")
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

  @Test func claimedAddStopsAtAnIDChromeCannotCreate() async throws {
    let f = CatalogLeaseFixture()
    try f.claim()
    let result = try await f.catalog.applyBookmarks(ops: [.init(op: "add", id: "not-a-uuid", kind: "f", title: "Invalid", parent: "bar"), .init(op: "update", id: "b0", title: "Not reached")], engineProfile: "")
    #expect(result == BookmarkApplyResult(applied: 0, skipped: 2, invalid: []))
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["not-a-uuid"] == nil)
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Page")
    await f.transport.releaseApply()
    await f.pump.settle(engine: "")
  }

}

@MainActor private final class CatalogLeaseFixture {
  let owner: BookmarkCoordinator
  let client = CatalogLeaseClient()
  let transport = CatalogLeaseTransport()
  let pump: BookmarkPump
  let catalog: LibraryCatalog

  init(ready: Bool = true, seed: Bool = true, directory: URL? = nil, operations: BookmarkPendingFileOperations = .live) {
    owner = BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", pendingStore: directory.map { BookmarkPendingStore(directory: $0, fileOperations: operations) })
    if seed { owner.seed(engine: "", document: ["nodes": [
      "bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["b0"], "addedAt": 0],
      "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
      "b0": ["id": "b0", "kind": "url", "parentId": "bar@default", "title": "Page", "url": "https://page.test", "addedAt": 1]
    ], "roots": ["p": ["bar": "bar@default", "other": "other@default"], "alias": ["bar": "bar@default", "other": "other@default"]]], ready: ready) }
    let transport = transport
    pump = BookmarkPump(coordinator: owner, client: BookmarkEngineClient(readTree: { _ in await transport.read() }, apply: { _, ops in await transport.apply(ops) }), clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
    catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
  }

  func makePump() -> BookmarkPump {
    let transport = transport
    return BookmarkPump(coordinator: owner, client: BookmarkEngineClient(readTree: { _ in await transport.read() }, apply: { _, ops in await transport.apply(ops) }), clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
  }

  func claim() throws { try catalog.claimBookmarks(coordinator: owner, pump: pump) }
}

@MainActor private class CatalogLeaseClient: EngineClient {
  var tree = EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: [.init(id: "b0", kind: "u", title: "Page", url: "https://page.test", addedAt: 1)]), other: .init(id: "other", kind: "f", title: "Other", children: []))
  var rawBatches: [[BookmarkOperation]] = []
  var reads = 0
  var result = BookmarkApplyResult(applied: 1, skipped: 0, invalid: [])
  var change: (@MainActor @Sendable (String) -> Void)?
  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) { change = handler }
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree { reads += 1; return tree }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    rawBatches.append(ops)
    if let title = ops.first?.title { tree.bar.children?[0].title = title }
    return result
  }
}

@MainActor private final class CatalogLeaseTransport {
  var tree = EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: [.init(id: "b0", kind: "u", title: "Page", url: "https://page.test", addedAt: 1)]), other: .init(id: "other", kind: "f", title: "Other", children: []))
  var batches: [[BookmarkOperation]] = []
  var reads = 0
  func read() -> EngineBookmarkTree { reads += 1; return tree }
  var gate: CheckedContinuation<Void, Never>?
  var held = true
  func apply(_ ops: [BookmarkOperation]) async -> BookmarkApplyResult {
    batches.append(ops)
    if held { await withCheckedContinuation { gate = $0 } }
    if let title = ops.first?.title { tree.bar.children?[0].title = title }
    return .init(applied: ops.count, skipped: 0, invalid: [])
  }
  func releaseApply() async { held = false; gate?.resume(); gate = nil }
}

private final class CatalogJournalGate: @unchecked Sendable {
  private let lock = NSLock()
  private let signal = DispatchSemaphore(value: 0)
  private var count = 0
  private var isHolding = false
  var holding: Bool { lock.lock(); defer { lock.unlock() }; return isHolding }
  func release() { signal.signal() }
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { url in
      self.lock.lock()
      self.count += 1
      let hold = self.count == 1
      self.isHolding = hold
      self.lock.unlock()
      if hold { _ = self.signal.wait(timeout: .now() + 5) }
      self.lock.lock()
      self.isHolding = false
      self.lock.unlock()
      try sync(url)
    }
    return operations
  }
}

private final class CatalogJournalWrites: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
  private func record() { lock.lock(); writes += 1; lock.unlock() }
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let writeNew = operations.writeNew
    let syncFile = operations.syncFile
    let rename = operations.rename
    let syncDirectory = operations.syncDirectory
    let remove = operations.remove
    operations.writeNew = { url, data in self.record(); try writeNew(url, data) }
    operations.syncFile = { url in self.record(); try syncFile(url) }
    operations.rename = { from, to in self.record(); try rename(from, to) }
    operations.syncDirectory = { url in self.record(); try syncDirectory(url) }
    operations.remove = { url in self.record(); try remove(url) }
    return operations
  }
}
