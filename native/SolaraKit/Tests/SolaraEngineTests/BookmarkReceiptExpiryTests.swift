import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkReceiptExpiryTests {
  @Test func settledReceiptsExpireDuringContinuousSubwindowEdits() throws {
    let clock = ReceiptExpiryClock()
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock.now }, stampsEnabled: true)
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let firstMutation = rename(1)
    for edit in 1...34 {
      clock.now = Double(edit - 1) * 10_000
      try owner.submit(profile: "p", mutations: [rename(edit)], requestID: "edit-\(edit)")
      #expect(try owner.acknowledgeReceipt(requestID: "edit-\(edit)", engine: ""))
      let view = owner.desiredView(engine: "")
      let read = owner.beginReceiptRead(engine: "", epoch: 0)
      #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
      let facts = owner.bookmarkFacts(profileId: "p")
      #expect(try owner.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: facts.map { (key: $0.key, seq: $0.value.seq) }))
    }
    let before = owner.desiredView(engine: "")
    var outcome = "replayed"
    do { _ = try owner.submit(profile: "p", mutations: [firstMutation], requestID: "edit-1") }
    catch { outcome = String(describing: error) }
    #expect(outcome == "expiredRequest")
    #expect(owner.desiredView(engine: "") == before)
  }

  private func rename(_ index: Int) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["b0", ["title": .string("Edited \(index)")]])
  }
}

private final class ReceiptExpiryClock {
  var now: Double = 0
}

extension BookmarkReceiptExpiryTests {
  private func coordinator(_ clock: ReceiptExpiryClock, directory: URL? = nil, operations: BookmarkPendingFileOperations = .live, readOnly: Bool = false) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock.now }, stampsEnabled: true, pendingStore: directory.map { BookmarkPendingStore(directory: $0, fileOperations: operations, readOnly: readOnly) })
  }

  private func seed(_ owner: BookmarkCoordinator) {
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
  }

  private func settle(_ owner: BookmarkCoordinator, id: String, delivered: Bool = true, facts: Bool = true) throws {
    if delivered { #expect(try owner.acknowledgeReceipt(requestID: id, engine: "")) }
    let view = owner.desiredView(engine: "")
    let read = try #require(owner.beginReceiptRead(engine: "", epoch: 0))
    #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    if facts {
      #expect(try owner.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: owner.bookmarkFacts(profileId: "p").map { (key: $0.key, seq: $0.value.seq) }))
    }
  }

  @discardableResult
  private func history(_ owner: BookmarkCoordinator, delivered: Bool = true, facts: Bool = true) throws -> BookmarkReceipt {
    seed(owner)
    var first: BookmarkReceipt?
    for edit in 1...34 {
      let receipt = try owner.submit(profile: "p", mutations: [rename(edit)], requestID: "edit-\(edit)")
      if edit == 1 { first = receipt }
      try settle(owner, id: "edit-\(edit)", delivered: delivered || edit != 1, facts: facts)
    }
    return try #require(first)
  }

  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ReceiptExpiryScratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  @Test func replayInsideGraceReturnsOriginalReceiptAndLivePayloadConflicts() throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    let original = try history(owner)
    clock.now = 299_999
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "edit-1") == original)
    #expect(throws: BookmarkCoordinatorError.conflictingRequest) { try owner.submit(profile: "p", mutations: [self.rename(99)], requestID: "edit-1") }
    #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 34")
  }

  @Test func expiredIDsRefuseBothPayloadsAndNewestThirtyTwoRemainLive() throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    try history(owner)
    clock.now = 300_000
    let before = owner.desiredView(engine: "")
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [self.rename(1)], requestID: "edit-1") }
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [self.rename(999)], requestID: "edit-1") }
    #expect(owner.desiredView(engine: "") == before)
    clock.now = 9_000_000
    for edit in 3...34 {
      let replay = try owner.submit(profile: "p", mutations: [rename(edit)], requestID: "edit-\(edit)")
      #expect(replay.view.document["nodes"]?["b0"]?["title"] == .string("Edited \(edit)"))
    }
    #expect(try owner.acknowledgeReceipt(requestID: "edit-1", engine: ""))
    #expect(!(try owner.acknowledgeReceipt(requestID: "unknown", engine: "")))
    #expect(owner.desiredView(engine: "") == before)
  }

  @Test(arguments: ["delivery", "facts", "pending", "unconfirmed", "push", "read"])
  func incompleteRequestsAndActiveFlightsNeverExpire(_ hold: String) throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    let original: BookmarkReceipt
    if hold == "pending" || hold == "unconfirmed" {
      seed(owner)
      original = try owner.submit(profile: "p", mutations: [rename(1)], requestID: "edit-1")
      #expect(try owner.acknowledgeReceipt(requestID: "edit-1", engine: ""))
      for edit in 2...34 { try owner.submit(profile: "p", mutations: [rename(edit)], requestID: "edit-\(edit)") }
      #expect(try owner.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: owner.bookmarkFacts(profileId: "p").map { (key: $0.key, seq: $0.value.seq) }))
      if hold == "unconfirmed" {
        #expect(owner.completePush(engine: "", captured: owner.desiredView(engine: ""), epoch: 0, succeeded: true, nowMs: 0))
      }
    } else {
      original = try history(owner, delivered: hold != "delivery", facts: hold != "facts")
    }
    var read: BookmarkReceiptRead?
    if hold == "push" { #expect(owner.beginPush(engine: "", captured: owner.desiredView(engine: ""), epoch: 0)) }
    if hold == "read" { read = try #require(owner.beginReceiptRead(engine: "", epoch: 0)) }
    clock.now = 9_000_000
    _ = try owner.maintainReceipts()
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "edit-1") == original)
    if let read { owner.endReceiptRead(read) }
  }

  @Test func pruningAndRestartKeepTombstonesAndCurrentDocument() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock, directory: dir)
    try history(owner)
    clock.now = 300_000
    #expect(try owner.maintainReceipts())
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: path)
    #expect(try JSONValue.parseBookmark(bytes)["version"] == 3)
    let payload = try #require(BookmarkPendingStore(directory: dir).load().payload)
    #expect(payload["requests"]?.array?.count == 32)
    #expect(payload["expiredRequests"]?["edit-1"] == "")
    let restarted = coordinator(clock, directory: dir)
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try restarted.submit(profile: "p", mutations: [self.rename(1)], requestID: "edit-1") }
    #expect(restarted.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 34")
    #expect(try Data(contentsOf: path) == bytes)
  }

  @Test(arguments: [false, true])
  func pruneFailureBeforeOrAfterDurableRenameNeverReapplies(_ committed: Bool) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock, directory: dir)
    try history(owner)
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    var operations = BookmarkPendingFileOperations.live
    let failure = ReceiptExpiryFailureSwitch()
    let rename = operations.rename
    let sync = operations.syncDirectory
    operations.rename = { from, to in
      if failure.enabled && !committed { throw BookmarkPendingStoreError.io("injected before rename", EIO) }
      try rename(from, to)
    }
    operations.syncDirectory = { url in
      try sync(url)
      if failure.enabled && committed { throw BookmarkPendingStoreError.io("injected after durable prune", EIO) }
    }
    let interrupted = coordinator(clock, directory: dir, operations: operations)
    let view = interrupted.desiredView(engine: "")
    let read = try #require(interrupted.beginReceiptRead(engine: "", epoch: 0))
    #expect(interrupted.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    let beforePrune = try Data(contentsOf: path)
    clock.now = 300_000
    failure.enabled = true
    #expect(throws: (any Error).self) { try interrupted.submit(profile: "p", mutations: [self.rename(100)], requestID: "never-published") }
    #expect(interrupted.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 34")
    if committed {
      #expect(interrupted.bookmarkWritesPaused)
      let restarted = coordinator(clock, directory: dir)
      #expect(throws: BookmarkCoordinatorError.expiredRequest) { try restarted.submit(profile: "p", mutations: [self.rename(1)], requestID: "edit-1") }
      #expect(restarted.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 34")
    } else {
      let payload = try #require(BookmarkPendingStore(directory: dir).load().payload)
      #expect(payload["requests"]?.array?.count == 34)
      #expect(payload["expiredRequests"]?.object?.isEmpty == true)
      #expect(try Data(contentsOf: path) == beforePrune)
    }
  }

  @Test func readOnlyMaintenancePreservesJournalBytesAndTimestamp() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    try history(coordinator(clock, directory: dir))
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    let stamp = Date(timeIntervalSince1970: 11)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path)
    clock.now = 9_000_000
    let readOnly = coordinator(clock, directory: dir, readOnly: true)
    #expect(!(try readOnly.maintainReceipts()))
    #expect(throws: BookmarkPendingStoreError.unavailable) { try readOnly.acknowledgeReceipt(requestID: "edit-1", engine: "") }
    #expect(try Data(contentsOf: path) == before)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
  }

  @Test func legacyMigrationNeedsFreshConfirmationAndGraceWithoutDeliveryAcknowledgment() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    try history(coordinator(clock, directory: dir))
    let store = BookmarkPendingStore(directory: dir)
    var payload = try #require(store.load().payload?.object)
    payload["formatVersion"] = 2
    payload.removeValue(forKey: "requestSequence")
    payload.removeValue(forKey: "expiredRequests")
    payload["requests"] = .array((payload["requests"]?.array ?? []).map { entry in
      var value = entry.object!
      for key in ["order", "delivered", "confirmed", "settledAtMs", "legacy"] { value.removeValue(forKey: key) }
      return .object(value)
    })
    try store.write(.object(payload))
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    clock.now = 9_000_000
    let migrated = coordinator(clock, directory: dir)
    #expect(try Data(contentsOf: path) == before)
    let view = migrated.desiredView(engine: "")
    let read = try #require(migrated.beginReceiptRead(engine: "", epoch: 0))
    #expect(migrated.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    #expect(BookmarkPendingStore(directory: dir).load().payload?["requests"]?.array?.count == 34)
    let replay = try migrated.submit(profile: "p", mutations: [rename(1)], requestID: "edit-1")
    #expect(replay.view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    clock.now += 300_000
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try migrated.submit(profile: "p", mutations: [self.rename(1)], requestID: "edit-1") }
  }

  @Test func retirementEndsTheOldRequestLifetime() throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    try history(owner)
    clock.now = 300_000
    _ = try owner.maintainReceipts()
    try owner.retire(engine: "")
    try owner.reactivate(engine: "")
    seed(owner)
    let receipt = try owner.submit(profile: "p", mutations: [rename(99)], requestID: "edit-1")
    #expect(receipt.view.document["nodes"]?["b0"]?["title"] == "Edited 99")
  }
}

private final class ReceiptExpiryFailureSwitch {
  var enabled = false
}

extension BookmarkReceiptExpiryTests {
  @Test func invalidNegativeSettlementTimeFailsClosed() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    try history(coordinator(clock, directory: dir))
    let store = BookmarkPendingStore(directory: dir)
    var payload = try #require(store.load().payload?.object)
    var requests = try #require(payload["requests"]?.array)
    var first = try #require(requests[0].object)
    first["settledAtMs"] = -1
    requests[0] = .object(first)
    payload["requests"] = .array(requests)
    try store.write(.object(payload))
    let owner = coordinator(clock, directory: dir)
    #expect(owner.bookmarkWritesPaused)
    #expect(owner.recoveryNotice?.kind == .unreadableJournal)
  }

  @Test func settledReceiptsArePrunedWhileTheCallerIsIdle() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock, directory: dir)
    try history(owner)
    clock.now = 299_990
    let start = Date()
    let advancing = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 299_990 + Date().timeIntervalSince(start) * 1000 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    let view = advancing.desiredView(engine: "")
    let read = try #require(advancing.beginReceiptRead(engine: "", epoch: 0))
    #expect(advancing.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    let deadline = Date().addingTimeInterval(2)
    var count = 34
    while Date() < deadline {
      count = BookmarkPendingStore(directory: dir).load().payload?["requests"]?.array?.count ?? 0
      if count == 32 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(count == 32)
    withExtendedLifetime(advancing) {}
  }
}

extension BookmarkReceiptExpiryTests {
  @Test func recoveryConflictHoldsCompletedReceipts() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    try history(coordinator(clock, directory: dir))
    let store = BookmarkPendingStore(directory: dir)
    var payload = try #require(store.load().payload?.object)
    payload["conflicts"] = [["engine": "", "kind": "recovery-required"]]
    try store.write(.object(payload))
    let owner = coordinator(clock, directory: dir)
    let view = owner.desiredView(engine: "")
    let read = try #require(owner.beginReceiptRead(engine: "", epoch: 0))
    #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    clock.now = 9_000_000
    _ = try owner.maintainReceipts()
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "edit-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    #expect(!owner.needsReceiptConfirmation(engine: ""))
    #expect(BookmarkPendingStore(directory: dir).load().payload?["requests"]?.array?.count == 34)
  }

  @Test func expiredIDsKeepExactUTF16Identity() throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    seed(owner)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "e\u{301}")
    try settle(owner, id: "e\u{301}")
    for edit in 2...34 {
      try owner.submit(profile: "p", mutations: [rename(edit)], requestID: "edit-\(edit)")
      try settle(owner, id: "edit-\(edit)")
    }
    clock.now = 300_000
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [self.rename(1)], requestID: "e\u{301}") }
    let receipt = try owner.submit(profile: "p", mutations: [rename(99)], requestID: "\u{e9}")
    #expect(receipt.view.document["nodes"]?["b0"]?["title"] == "Edited 99")
  }
}

extension BookmarkReceiptExpiryTests {
  @Test func revokedCoordinatorCannotRearmMaintenanceFromALatePumpClaim() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ReceiptExpiryClock()
    try history(coordinator(clock, directory: dir))
    let start = Date()
    let revoked = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 299_500 + Date().timeIntervalSince(start) * 1000 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir))
    let view = revoked.desiredView(engine: "")
    let read = try #require(revoked.beginReceiptRead(engine: "", epoch: 0))
    #expect(revoked.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
    revoked.fencePumpAdmissions()
    _ = revoked.claimPump()
    let replacement = coordinator(clock, directory: dir)
    try replacement.submit(profile: "p", mutations: [rename(777)], requestID: "replacement-write")
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let committed = try Data(contentsOf: path)
    try await Task.sleep(for: .milliseconds(750))
    #expect(try Data(contentsOf: path) == committed)
    #expect(coordinator(clock, directory: dir).desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 777")
    withExtendedLifetime(revoked) {}
  }

  @Test func expiredReplacementIDPrecedesDecodedPayloadValidation() throws {
    let clock = ReceiptExpiryClock()
    let owner = coordinator(clock)
    try history(owner)
    clock.now = 300_000
    _ = try owner.maintainReceipts()
    let view = owner.desiredView(engine: "")
    #expect(throws: BookmarkCoordinatorError.expiredRequest) {
      try owner.replaceDocument(engine: "", profile: "p", document: view.document, expectedRevision: view.revision, requestID: "edit-1", expectedEngine: "", records: [(key: "invalid", hlc: "1")])
    }
    #expect(owner.desiredView(engine: "") == view)
  }
}

extension BookmarkReceiptExpiryTests {
  @Test func remapPreservesReceiptsDuringActiveReceiptRead() throws {
    let clock = ReceiptExpiryClock()
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock.now })
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    for index in 1...34 {
      try owner.submit(profile: "p", mutations: [rename(index)], requestID: "id-\(index)")
      try owner.acknowledgeReceipt(requestID: "id-\(index)", engine: "")
    }
    let view = owner.desiredView(engine: "")
    let confirmation = try #require(owner.beginReceiptRead(engine: "", epoch: 0))
    #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: confirmation))
    clock.now = 300_000
    let active = try #require(owner.beginReceiptRead(engine: "", epoch: 0))
    #expect(!(try owner.maintainReceipts()))
    #expect(owner.remap(profiles: ["p": ""], defaultProfile: "p"))
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "id-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    owner.endReceiptRead(active)
    #expect(try owner.maintainReceipts())
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [rename(1)], requestID: "id-1") }
    owner.fencePumpAdmissions()
  }

}
