import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkPumpTests {
  @Test func partialPushKeepsTheValidSuffixDeletion() throws {
    let initial = BookmarkCoordinatorTests().document(["https://a.test", "https://b.test", "https://c.test"])
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    owner.seed(engine: "", document: initial, ready: true)
    let captured = owner.desiredView(engine: "").revision
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    let remaining = BookmarkReconcile.replay(BookmarkFlat(document: initial, engine: ""), operations: [["op": "remove", "id": "b1"], ["op": "remove", "id": "b0"]], engine: "").tree
    let delta = BookmarkReconcile.operations(from: BookmarkFlat(document: initial, engine: ""), to: BookmarkFlat(document: owner.desiredView(engine: "").document, engine: ""), engine: "")
    let legacy = BookmarkReconcile.replay(remaining, operations: delta, engine: "")
    #expect(legacy.structuralBreak == 0)
    #expect(legacy.tree.children["bar@default"] == ["b2"])
    #expect(owner.completeRead(engine: "", document: remaining.document(profiles: ["p"]), capturedRevision: captured))
    #expect(owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == [])
    #expect(!owner.membership(profile: "p", url: "https://c.test"))
  }
}

@MainActor
extension BookmarkPumpTests {
  @Test func failedPushRetriesWithBackoff() async throws {
    let f = PumpFixture()
    f.engine.reject = true
    try await f.rename("First")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 2)
    try await f.pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Second", "url": "https://second.test"]])])
    #expect(f.owner.membership(profile: "p", url: "https://second.test"))
    #expect(!f.owner.membership(profile: "p", url: "https://a.test"))
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Second")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 2)
    for (time, count) in [(1499.0, 2), (1500, 3), (4500, 4), (10500, 5), (22500, 6), (46500, 7), (94500, 8), (154499, 8), (154500, 9)] {
      f.time.advance(to: time)
      await f.pump.settle(engine: "")
      #expect(f.engine.batches.count == count, "t=\(time)")
    }
    f.engine.reject = false
    f.time.advance(to: 214500)
    await f.pump.settle(engine: "")
    #expect(f.owner.desiredView(engine: "").failedPushes == 0)
    #expect(f.owner.desiredView(engine: "").retryNotBeforeMs == nil)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Second")
    f.engine.reject = true
    try await f.rename("Third")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 12)
    #expect(f.owner.desiredView(engine: "").retryNotBeforeMs == 216000)
  }

  @Test func retryDeadlineSurvivesRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let f = PumpFixture(directory: directory)
    f.engine.reject = true
    try await f.rename("Pending")
    await f.pump.settle(engine: "")
    f.pump.stop()
    let relaunched = PumpFixture(directory: directory, time: 500, seed: false)
    relaunched.pump.requestRead(engine: "")
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.engine.batches.isEmpty)
    #expect(relaunched.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Pending")
    relaunched.time.advance(to: 1499)
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.engine.batches.isEmpty)
    relaunched.time.advance(to: 1500)
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.engine.batches.count == 1)
    #expect(relaunched.engine.document["nodes"]?["b0"]?["title"] == "Pending")
  }

  @Test func partialBatchRereadsBeforeFreshDiff() async throws {
    let f = PumpFixture(urls: ["https://a.test", "https://b.test", "https://c.test"])
    f.engine.loseBeforeApply = "b1"
    try await f.pump.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    await f.pump.settle(engine: "")
    #expect(f.engine.events == ["apply", "read", "apply"])
    #expect(f.engine.batches.map { $0.map(\.id) } == [["b0", "b1", "b2"], ["b2"]])
    #expect(f.engine.document["nodes"]?["bar@default"]?["children"] == [])
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == [])
  }

  @Test func suppressedApplyEventStillReconciles() async throws {
    let f = PumpFixture()
    try await f.rename("Accepted")
    await f.pump.settle(engine: "")
    f.pump.requestPush(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 1)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Accepted")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Accepted")
  }

  @Test func newCommandDuringApplySurvivesOldSuccess() async throws {
    let f = PumpFixture()
    f.engine.hold = true
    try await f.rename("Older")
    await f.engine.entered()
    try await f.rename("Newer")
    f.pump.requestRead(engine: "")
    #expect(f.engine.events == ["apply"])
    f.engine.release()
    await f.pump.settle(engine: "")
    #expect(f.engine.events == ["apply", "read", "apply"])
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Newer")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Newer")
    #expect(f.engine.maximumActive == 1)
  }

  @Test func readErrorKeepsDesired() async throws {
    let f = PumpFixture()
    f.engine.rejectRead = true
    f.owner.seed(engine: "", document: f.engine.document, ready: false)
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending"]])])
    f.pump.requestRead(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Pending")
    #expect(f.engine.batches.isEmpty)
    #expect(f.engine.events == ["read"])
    #expect(!f.owner.desiredView(engine: "").readyForSync)
    f.engine.rejectRead = false
    f.time.advance(to: 1500)
    await f.pump.settle(engine: "")
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Pending")
  }

  @Test func oldEpochTimerAndCompletionIgnored() async throws {
    let f = PumpFixture()
    f.engine.reject = true
    try await f.rename("Pending")
    await f.pump.settle(engine: "")
    f.owner.remap(profiles: ["p": "other"], defaultProfile: "p")
    let before = f.owner.desiredView(engine: "")
    f.time.advance(to: 1500, includingCancelled: true)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 2)
    #expect(f.owner.desiredView(engine: "") == before)
    let g = PumpFixture()
    g.engine.hold = true
    try await g.rename("Held")
    await g.engine.entered()
    g.pump.stop()
    let stopped = g.owner.desiredView(engine: "")
    g.engine.release()
    await g.pump.settle(engine: "")
    #expect(g.owner.desiredView(engine: "") == stopped)
    #expect(g.engine.batches.count == 1)
  }

  @Test func structuralFailureDoesNotDeleteKeptSubtree() async throws {
    let initial = keptSubtreeDocument()
    let f = PumpFixture()
    f.owner.seed(engine: "", document: initial, ready: true)
    try f.owner.submit(profile: "p", mutations: [.init(method: "addBookmarkFolder", args: [["profileId": "p", "title": "Target"]]), .init(method: "moveBookmark", args: ["kept", "new", 0]), .init(method: "removeBookmark", args: ["folder"])])
    var broken = BookmarkFlat(document: initial, engine: "")
    broken.nodes["new"] = ["kind": "url", "parent": "other@default", "title": "External", "url": "https://external.test", "addedAt": 0]
    broken.order.append("new")
    broken.children["other@default"] = ["new"]
    f.engine.document = broken.document(profiles: ["p"])
    f.pump.requestRead(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.flatMap { $0 }.allSatisfy { $0.op != "remove" })
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["kept"]?["parentId"] == "folder")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["folder"] != nil)
    #expect(f.owner.recoveryConflicts.count == 1)
  }


  @Test func replacementOwnerWaitsForOldFlight() async throws {
    let f = PumpFixture()
    f.engine.hold = true
    try await f.rename("Old owner")
    await f.engine.entered()
    let replacement = BookmarkPump(coordinator: f.owner, client: f.engine.client, clock: f.time.clock, scheduler: f.time.scheduler)
    try await replacement.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "New owner"]])])
    replacement.requestRead(engine: "")
    await Task.yield()
    #expect(f.engine.events == ["apply"])
    f.engine.release()
    await f.pump.settle(engine: "")
    await replacement.settle(engine: "")
    #expect(f.engine.maximumActive == 1)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "New owner")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "New owner")
  }

  @Test func newCommandDuringReadSurvivesOldTree() async throws {
    let f = PumpFixture()
    f.engine.holdRead = true
    f.pump.requestRead(engine: "")
    await f.engine.entered()
    try await f.rename("Newer than read")
    f.engine.release()
    await f.pump.settle(engine: "")
    #expect(f.engine.maximumActive == 1)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Newer than read")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Newer than read")
  }

  @Test func restoredDeadlineClampsClockRollback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let f = PumpFixture(directory: directory, time: 100_000)
    f.engine.reject = true
    try await f.rename("Pending")
    await f.pump.settle(engine: "")
    f.pump.stop()
    let relaunched = PumpFixture(directory: directory, time: 0, seed: false)
    relaunched.pump.requestRead(engine: "")
    await relaunched.pump.settle(engine: "")
    relaunched.time.advance(to: 59_999)
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.engine.batches.isEmpty)
    relaunched.time.advance(to: 60_000)
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.engine.batches.count == 1)
  }

  @Test func inSessionWallClockChangeDoesNotMoveRetry() async throws {
    let f = PumpFixture()
    f.engine.reject = true
    try await f.rename("Pending")
    await f.pump.settle(engine: "")
    f.time.now = 100_000
    try await f.rename("Latest")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 2)
    f.time.advance(to: 101_499)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 2)
    f.time.advance(to: 101_500)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 3)
  }


  @Test func stalePumpEpochCannotAcceptInsideCoordinatorTransaction() throws {
    let f = PumpFixture()
    let epoch = f.owner.claimPump()
    f.owner.remap(profiles: ["p": "other"], defaultProfile: "p")
    let before = f.owner.desiredView(engine: "other")
    #expect(throws: BookmarkCoordinatorError.staleRevision) {
      try f.owner.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "url": "https://stale.test", "title": "Stale"]])], expectedPumpEpoch: epoch)
    }
    #expect(f.owner.desiredView(engine: "other") == before)
  }

  @Test func invalidAdditionDoesNotDiscardLaterValidOperation() async throws {
    let f = PumpFixture()
    let desired = BookmarkCoordinatorTests().document(["https://a.test", "invalid", "https://c.test"])
    try f.owner.replaceDocument(engine: "", document: desired, expectedRevision: f.owner.desiredView(engine: "").revision)
    f.pump.requestPush(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.engine.events == ["apply", "read"])
    #expect(f.engine.batches.first?.map(\.id) == ["b1", "b2"])
    #expect(f.engine.document["nodes"]?["b1"] == nil)
    #expect(f.engine.document["nodes"]?["b2"]?["url"] == "https://c.test")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b1"] == nil)
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b2"]?["url"] == "https://c.test")
  }

  @Test func thrownApplyRereadsBeforeRetry() async throws {
    let f = PumpFixture(urls: ["https://a.test", "https://b.test", "https://c.test"])
    f.engine.throwAfterApply = true
    try await f.pump.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    await f.pump.settle(engine: "")
    #expect(f.engine.events == ["apply", "read"])
    #expect(f.engine.batches.count == 1)
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == [])
    #expect(f.owner.desiredView(engine: "").failedPushes == 0)
  }

  @Test func retryStatusAdvancesDesiredRevision() throws {
    let f = PumpFixture()
    let epoch = f.owner.claimPump()
    let accepted = try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending"]])]).view
    #expect(f.owner.completePush(engine: "", captured: accepted, epoch: epoch, succeeded: false, nowMs: 0))
    #expect(f.owner.desiredView(engine: "").revision > accepted.revision)
  }


  @Test func replacementOwnerPreservesNewerRestoredSubtree() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let f = PumpFixture(directory: directory)
    let initial = keptSubtreeDocument()
    f.owner.seed(engine: "", document: initial, ready: true)
    f.engine.document = initial
    f.engine.hold = true
    let removed = try await f.pump.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["folder"]])])
    await f.engine.entered()
    try f.owner.submit(profile: "p", mutations: [.init(method: "restoreBookmarks", args: [removed.results[0]]), .init(method: "moveBookmark", args: ["kept", "bar@default", 0]), .init(method: "removeBookmark", args: ["folder"])])
    let replacement = BookmarkPump(coordinator: f.owner, client: f.engine.client, clock: f.time.clock, scheduler: f.time.scheduler)
    replacement.requestPush(engine: "")
    f.engine.release()
    await f.pump.settle(engine: "")
    await replacement.settle(engine: "")
    #expect(f.engine.events == ["apply", "read", "apply"])
    #expect(f.engine.maximumActive == 1)
    #expect(f.owner.recoveryConflicts.isEmpty)
    #expect(f.engine.document["nodes"]?["kept"]?["parentId"] == "bar@default")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["kept"]?["parentId"] == "bar@default")
    let restored = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    #expect(restored.recoveryConflicts == f.owner.recoveryConflicts)
  }


  @Test func undoDuringPartialApplySurvivesReread() async throws {
    let f = PumpFixture(urls: ["https://a.test", "https://b.test", "https://c.test"])
    f.engine.hold = true
    f.engine.loseBeforeApply = "b1"
    let removal = try await f.pump.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    await f.engine.entered()
    try await f.pump.submit(profile: "p", mutations: [.init(method: "restoreBookmarks", args: [removal.results[0]])])
    f.engine.release()
    await f.pump.settle(engine: "")
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == ["b0", "b1", "b2"])
    #expect(f.engine.document["nodes"]?["bar@default"]?["children"] == ["b0", "b1", "b2"])
    #expect(f.engine.batches.count == 2)
    #expect(f.engine.batches.last?.filter { $0.op == "add" }.map(\.id) == ["b0", "b1"])
  }


  @Test func crashDuringApplyRetainsLaterUndo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let f = PumpFixture(urls: ["https://a.test", "https://b.test", "https://c.test"], directory: directory)
    f.engine.hold = true
    f.engine.loseBeforeApply = "b1"
    let removal = try await f.pump.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b0", "b1", "b2"]])])
    await f.engine.entered()
    try f.owner.submit(profile: "p", mutations: [.init(method: "restoreBookmarks", args: [removal.results[0]])])
    f.pump.stop()
    f.engine.release()
    await f.pump.settle(engine: "")
    let relaunched = PumpFixture(directory: directory, seed: false)
    relaunched.engine.document = f.engine.document
    relaunched.pump.requestRead(engine: "")
    await relaunched.pump.settle(engine: "")
    #expect(relaunched.owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == ["b0", "b1", "b2"])
    #expect(relaunched.engine.document["nodes"]?["bar@default"]?["children"] == ["b0", "b1", "b2"])
    #expect(relaunched.engine.batches.count == 1)
    #expect(relaunched.engine.batches.first?.map(\.id) == ["b0", "b1"])
    #expect(relaunched.owner.desiredView(engine: "").document["nodes"]?["b0"]?["addedAt"] == 10)
  }

  @Test func readerDoesNotWaitForHeldEngineApply() async throws {
    let f = PumpFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let client = BookmarkEngineClient(readTree: { engine in try await f.engine.read(engine) }, apply: { _, ops in
      await Task.detached {
        entered.signal()
        let result = pumpWait(release, seconds: 10)
        return BookmarkApplyResult(applied: result ? ops.count : 0, skipped: result ? 0 : ops.count, invalid: [])
      }.value
    })
    let pump = BookmarkPump(coordinator: f.owner, client: client, clock: f.time.clock, scheduler: f.time.scheduler)
    try await pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Held"]])])
    await Task.detached { #expect(pumpWait(entered, seconds: 10)) }.value
    let owner = f.owner
    Thread.detachNewThread {
      #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Held")
      #expect(owner.membership(profile: "p", url: "https://a.test"))
      finished.signal()
    }
    let read = await Task.detached { pumpWait(finished, seconds: 2) }.value
    release.signal()
    #expect(read)
    await pump.settle(engine: "")
  }
}

@MainActor
private final class PumpTime {
  var now: Double
  var monotonic: Double
  var tasks: [(Double, PumpCancellation, @MainActor @Sendable () -> Void)] = []
  init(_ now: Double = 0) { self.now = now; monotonic = now }
  var clock: BookmarkPumpClock { .init(wallTimeMs: { self.now }, monotonicTimeMs: { self.monotonic }) }
  var scheduler: BookmarkPumpScheduler {
    .init { delay, action in
      let token = PumpCancellation()
      self.tasks.append((self.monotonic + delay, token, action))
      return { token.cancelled = true }
    }
  }
  func advance(to time: Double, includingCancelled: Bool = false) {
    monotonic += time - now
    now = time
    let due = tasks.filter { $0.0 <= monotonic }
    tasks.removeAll { $0.0 <= monotonic }
    for (_, token, action) in due where includingCancelled || !token.cancelled { action() }
  }
}

@MainActor
private final class PumpCancellation { var cancelled = false }

@MainActor
private final class PumpFixture {
  let owner: BookmarkCoordinator
  let time: PumpTime
  let engine: PumpEngine
  let pump: BookmarkPump
  init(urls: [String] = ["https://a.test"], directory: URL? = nil, time: Double = 0, seed: Bool = true, fileOperations: BookmarkPendingFileOperations = .live) {
    owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", makeID: { "new" }, pendingStore: directory.map { BookmarkPendingStore(directory: $0, fileOperations: fileOperations) })
    self.time = PumpTime(time)
    engine = PumpEngine(document: BookmarkCoordinatorTests().document(urls))
    if seed { owner.seed(engine: "", document: engine.document, ready: true) }
    pump = BookmarkPump(coordinator: owner, client: engine.client, clock: self.time.clock, scheduler: self.time.scheduler)
  }
  func rename(_ title: String) async throws { try await pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": .string(title)]])]) }
}

@MainActor
private final class PumpEngine {
  var document: JSONValue
  var batches: [[BookmarkOperation]] = []
  var events: [String] = []
  var throwAfterApply = false
  var reject = false
  var rejectRead = false
  var loseBeforeApply: String?
  var hold = false
  var holdRead = false
  var active = 0
  var maximumActive = 0
  var held: CheckedContinuation<Void, Never>?
  var arrival: CheckedContinuation<Void, Never>?
  init(document: JSONValue) { self.document = document }
  var client: BookmarkEngineClient { .init(readTree: { engine in try await self.read(engine) }, apply: { engine, ops in try await self.apply(engine, ops) }) }
  func entered() async { if held != nil { return }; await withCheckedContinuation { arrival = $0 } }
  func release() { hold = false; holdRead = false; held?.resume(); held = nil }
  func read(_ engine: String) async throws -> EngineBookmarkTree {
    events.append("read")
    #expect(active == 0)
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    if holdRead { await withCheckedContinuation { held = $0; arrival?.resume(); arrival = nil } }
    if rejectRead { throw BookmarkReadUnavailable.unsupported }
    let nodes = document["nodes"]?.object ?? [:]
    func node(_ id: String) -> EngineBookmarkNode {
      let value = nodes[id]!
      return .init(id: id, kind: value["kind"] == "folder" ? "f" : "u", title: value["title"]?.string ?? "", url: value["url"]?.string, addedAt: value["addedAt"]?.number ?? 0, syncKey: value["syncKey"]?.string, children: value["children"]?.array?.compactMap(\.string).map(node))
    }
    let roots = BookmarkFlat.roots(engine)
    return .init(bar: node(roots.bar), other: node(roots.other))
  }
  func apply(_ engine: String, _ ops: [BookmarkOperation]) async throws -> BookmarkApplyResult {
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    events.append("apply")
    batches.append(ops)
    if hold { await withCheckedContinuation { held = $0; arrival?.resume(); arrival = nil } }
    if reject { return .init(applied: 0, skipped: ops.count, invalid: []) }
    var flat = BookmarkFlat(document: document, engine: engine)
    if let id = loseBeforeApply {
      flat = BookmarkReconcile.replay(flat, operations: [["op": "remove", "id": .string(id)]], engine: engine).tree
      loseBeforeApply = nil
    }
    var applied = 0
    var invalid: [String] = []
    for op in ops {
      let value = try JSONValue.parse(JSONEncoder().encode(op))
      if op.op == "add", op.kind == "u", !BookmarkReconcile.keepsURL(op.url ?? "") { invalid.append(op.id); continue }
      let replay = BookmarkReconcile.replay(flat, operations: [value], engine: engine)
      if replay.structuralBreak != nil { break }
      flat = replay.tree
      applied += 1
    }
    document = flat.document(profiles: ["p"])
    if throwAfterApply { throw BookmarkReadUnavailable.unsupported }
    return .init(applied: applied, skipped: ops.count - applied - invalid.count, invalid: invalid)
  }
}

private func pumpWait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
  semaphore.wait(timeout: .now() + seconds) == .success
}

private func keptSubtreeDocument() -> JSONValue {
  ["nodes": ["bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["folder"], "addedAt": 0], "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0], "folder": ["id": "folder", "kind": "folder", "parentId": "bar@default", "title": "Folder", "children": ["kept"], "addedAt": 0], "kept": ["id": "kept", "kind": "url", "parentId": "folder", "title": "Kept", "url": "https://kept.test", "addedAt": 0]], "roots": ["p": ["bar": "bar@default", "other": "other@default"]]]
}

@MainActor
extension BookmarkPumpTests {
  @Test func mainActorKeepsRunningWhileAPushJournalWriteIsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = PumpJournalGate(holdingSync: 2)
    let f = PumpFixture(directory: directory, fileOperations: gate.operations)
    try await f.rename("Held")
    var sawHeldWriteFromMain = false
    for _ in 0..<2000 where !sawHeldWriteFromMain {
      try await Task.sleep(nanoseconds: 1_000_000)
      if gate.holding {
        sawHeldWriteFromMain = true
        #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Held")
      }
    }
    gate.release()
    #expect(sawHeldWriteFromMain)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 1)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Held")
  }
}

private final class PumpJournalGate: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let target: Int
  private var count = 0
  private var isHolding = false
  init(holdingSync target: Int) { self.target = target }
  var holding: Bool { lock.lock(); defer { lock.unlock() }; return isHolding }
  func release() { releaseSignal.signal() }
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let liveSync = operations.syncFile
    operations.syncFile = { url in
      self.lock.lock()
      self.count += 1
      let hold = self.count == self.target
      if hold { self.isHolding = true }
      self.lock.unlock()
      if hold {
        _ = self.releaseSignal.wait(timeout: .now() + 5)
        self.lock.lock()
        self.isHolding = false
        self.lock.unlock()
      }
      try liveSync(url)
    }
    return operations
  }
}

@MainActor
extension BookmarkPumpTests {
  @Test func emptyDesiredDocumentNeverPushesDeletes() async throws {
    let f = PumpFixture(urls: ["https://a.test", "https://b.test"])
    let revision = f.owner.desiredView(engine: "").revision
    try f.owner.replaceDocument(engine: "", document: ["nodes": [:], "roots": [:]], expectedRevision: revision)
    f.pump.requestPush(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.isEmpty)
    #expect(f.engine.batches.flatMap { $0 }.allSatisfy { $0.op != "remove" })
    #expect(f.engine.document["nodes"]?["b0"] != nil)
    #expect(f.engine.document["nodes"]?["b1"] != nil)
  }

  @Test func journalWriteFaultBacksOffAndResumesPushingWithoutRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = PumpJournalFault()
    let f = PumpFixture(directory: directory, fileOperations: journal.operations)
    try await f.rename("Held")
    journal.failing = true
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.isEmpty)
    journal.failing = false
    f.time.advance(to: 1499)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.isEmpty)
    f.time.advance(to: 1500)
    await f.pump.settle(engine: "")
    #expect(f.engine.batches.count == 1)
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Held")
    try await f.rename("After")
    await f.pump.settle(engine: "")
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "After")
  }

  @Test func failedReadsBackOffByDoublingUpToAMinuteAndJournalOncePerAttempt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = PumpJournalFault()
    let f = PumpFixture(directory: directory, fileOperations: journal.operations)
    f.engine.rejectRead = true
    let writesBefore = journal.writes
    f.pump.requestRead(engine: "")
    await f.pump.settle(engine: "")
    #expect(f.engine.events.count == 1)
    for (time, reads) in [(1499.0, 1), (1500, 2), (4499, 2), (4500, 3), (10500, 4), (22500, 5), (46500, 6), (60000, 6), (94500, 7), (154499, 7), (154500, 8), (214500, 9)] {
      f.time.advance(to: time)
      await f.pump.settle(engine: "")
      #expect(f.engine.events.count == reads, "at \(time)")
    }
    #expect(journal.writes - writesBefore == f.engine.events.count)
    f.engine.rejectRead = false
    f.time.advance(to: 274500)
    await f.pump.settle(engine: "")
    #expect(f.engine.events.count == 10)
    #expect(f.owner.desiredView(engine: "").retryNotBeforeMs == nil)
    #expect(f.owner.desiredView(engine: "").readyForSync)
  }
}

private final class PumpJournalFault: @unchecked Sendable {
  private let lock = NSLock()
  private var isFailing = false
  private var count = 0
  var failing: Bool {
    get { lock.lock(); defer { lock.unlock() }; return isFailing }
    set { lock.lock(); isFailing = newValue; lock.unlock() }
  }
  var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let liveWrite = operations.writeNew
    operations.writeNew = { url, data in
      self.lock.lock()
      let fail = self.isFailing
      if !fail { self.count += 1 }
      self.lock.unlock()
      if fail { throw BookmarkPendingStoreError.io("write", ENOSPC) }
      try liveWrite(url, data)
    }
    return operations
  }
}

@MainActor
extension BookmarkPumpTests {
  @Test func mainActorKeepsRunningWhileASubmitJournalWriteIsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pump-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = PumpJournalGate(holdingSync: 1)
    let f = PumpFixture(directory: directory, fileOperations: gate.operations)
    let submitted = Task { try await f.rename("Held") }
    var sawHeldWriteFromMain = false
    for _ in 0..<2000 where !sawHeldWriteFromMain {
      try await Task.sleep(nanoseconds: 1_000_000)
      if gate.holding {
        sawHeldWriteFromMain = true
        #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Page")
      }
    }
    gate.release()
    #expect(sawHeldWriteFromMain)
    try await submitted.value
    #expect(f.owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Held")
    await f.pump.settle(engine: "")
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == "Held")
  }

  @Test func concurrentSubmitsSerializeAndTheLaterReceiptWins() async throws {
    let f = PumpFixture(urls: ["https://a.test", "https://b.test"])
    async let first: BookmarkReceipt = f.pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "One"]])])
    async let second: BookmarkReceipt = f.pump.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Two"]])])
    let receipts = try await [first, second]
    #expect(receipts[0].view.revision != receipts[1].view.revision)
    let later = receipts.max { $0.view.revision < $1.view.revision }!
    #expect(f.owner.desiredView(engine: "").document == later.view.document)
    await f.pump.settle(engine: "")
    #expect(f.engine.document["nodes"]?["b0"]?["title"] == later.view.document["nodes"]?["b0"]?["title"])
  }
}


@MainActor
extension BookmarkPumpTests {
  @Test func emptyAliaslessDesiredDoesNotPumpForever() async throws {
    let f = PumpFixture()
    try f.owner.replaceDocument(engine: "", document: ["nodes": [:], "roots": [:]], expectedRevision: f.owner.desiredView(engine: "").revision)
    #expect(f.owner.remap(profiles: ["p": "new-engine"], defaultProfile: "p"))
    #expect(f.owner.catalogEngines.contains(""))
    let pump = BookmarkPump(coordinator: f.owner, client: f.engine.client, clock: f.time.clock, scheduler: f.time.scheduler)
    pump.requestPush(engine: "")
    await pump.settle(engine: "")
    #expect(f.owner.recoveryConflicts.last?["kind"] == "emptyAliaslessBookmarkEngine")
    #expect(!f.owner.catalogEngines.contains(""))
    pump.requestPush(engine: "")
    await pump.settle(engine: "")
    #expect(f.engine.batches.isEmpty)
    #expect(f.engine.events.isEmpty)
  }



  @Test func confirmedGoneReadStopsAliaslessLane() async throws {
    let f = PumpFixture()
    try f.owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Recover me"]])])
    #expect(f.owner.remap(profiles: ["p": "new-engine"], defaultProfile: "p"))
    let client = BookmarkEngineClient(readTree: { _ in throw BookmarkEngineAvailabilityError.permanentlyGone }, apply: f.engine.client.apply)
    let pump = BookmarkPump(coordinator: f.owner, client: client, clock: f.time.clock, scheduler: f.time.scheduler)
    pump.requestRead(engine: "")
    await pump.settle(engine: "")
    #expect(!f.owner.catalogEngines.contains(""))
    #expect(f.owner.recoveryConflicts.last?["desired"]?["nodes"]?["b0"]?["title"] == "Recover me")
    f.time.advance(to: 60_000, includingCancelled: true)
    await pump.settle(engine: "")
    #expect(f.engine.batches.isEmpty)
  }
}


@MainActor
extension BookmarkPumpTests {
  @Test func retirementDrainWaitsForPreviousCoordinatorFlight() async throws {
    let f = PumpFixture()
    f.engine.hold = true
    try await f.rename("Old coordinator")
    await f.engine.entered()
    f.owner.fencePumpAdmissions()
    let replacement = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    try replacement.retire(engine: "")
    var drained = false
    let drain = Task {
      try await replacement.engineQueue.perform(engine: "") {
        #expect(f.engine.active == 0)
        drained = true
      }
    }
    await Task.yield()
    #expect(!drained)
    f.engine.release()
    try await drain.value
    await f.pump.settle(engine: "")
    #expect(drained)
    #expect(!replacement.desiredView(engine: "").hasView)
  }
}
