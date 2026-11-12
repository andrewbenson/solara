import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkLegacyReceiptTests {
  private func coordinator(_ clock: LegacyReceiptClock, directory: URL, operations: BookmarkPendingFileOperations = .live, readOnly: Bool = false) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock.now }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations, readOnly: readOnly))
  }

  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("LegacyReceiptScratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func rename(_ index: Int) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["b0", ["title": .string("Edited \(index)")]])
  }

  private func withTitle(_ document: JSONValue, _ index: Int) throws -> JSONValue {
    var document = try #require(document.object)
    var nodes = try #require(document["nodes"]?.object)
    var node = try #require(nodes["b0"]?.object)
    node["title"] = .string("Edited \(index)")
    nodes["b0"] = .object(node)
    document["nodes"] = .object(nodes)
    return .object(document)
  }

  private func confirm(_ owner: BookmarkCoordinator, document: JSONValue? = nil, epoch: UInt64 = 0, proof: Bool = true) throws {
    let view = owner.desiredView(engine: "")
    var read: BookmarkReceiptRead?
    if proof {
      let started = try #require(owner.beginReceiptRead(engine: "", epoch: epoch))
      read = started
    }
    #expect(owner.completeRead(engine: "", document: document ?? view.document, capturedRevision: view.revision, receiptRead: read))
  }

  private func clearFacts(_ owner: BookmarkCoordinator) throws {
    #expect(try owner.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: owner.bookmarkFacts(profileId: "p").map { (key: $0.key, seq: $0.value.seq) }))
  }

  private func payload(_ directory: URL) throws -> JSONValue {
    try #require(BookmarkPendingStore(directory: directory).load().payload)
  }

  private func facts(_ value: JSONValue, sequence: Int) throws -> JSONValue {
    .object(try #require(value.object).mapValues { value in
      var fact = try #require(value.object)
      fact["seq"] = .string(String(sequence))
      return .object(fact)
    })
  }

  private func writeLegacy(_ directory: URL, count: Int = 1000, hold: String? = nil, tied: Bool = false) throws {
    let clock = LegacyReceiptClock()
    let owner = coordinator(clock, directory: directory)
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    try owner.submit(profile: "p", mutations: [rename(count)], requestID: "template")
    let pendingBase = try #require(payload(directory)["engines"]?.array?.first?["base"])
    try confirm(owner, proof: false)
    if hold != "facts" { try clearFacts(owner) }
    owner.fencePumpAdmissions()
    var saved = try #require(payload(directory).object)
    let template = try #require(saved["requests"]?.array?.first?.object)
    var engine = try #require(saved["engines"]?.array?.first?.object)
    var view = try #require(engine["view"]?.object)
    view["revision"] = .string(String(count + 1))
    view["facts"] = try facts(try #require(view["facts"]), sequence: count)
    engine["view"] = .object(view)
    if hold == "pending" { engine["base"] = pendingBase }
    saved["engines"] = [.object(engine)]
    saved["formatVersion"] = 2
    saved["factSequence"] = .string(String(count))
    saved.removeValue(forKey: "requestSequence")
    saved.removeValue(forKey: "expiredRequests")
    if hold == "conflict" { saved["conflicts"] = [["engine": "", "kind": "recovery-required"]] }
    saved["requests"] = .array(try (1...count).reversed().map { index in
      var request = template
      for key in ["order", "delivered", "confirmed", "settledAtMs", "legacy"] { request.removeValue(forKey: key) }
      request["id"] = .string("legacy-\(index)")
      var accepted = try #require(request["view"]?.object)
      accepted["revision"] = .string(String(tied && index >= 961 ? 961 : index))
      accepted["document"] = try withTitle(try #require(accepted["document"]), index)
      accepted["facts"] = try facts(try #require(accepted["facts"]), sequence: index)
      request["view"] = .object(accepted)
      var input = try #require(request["payload"]?.object)
      let mutation = rename(index)
      input["mutations"] = [["method": .string(mutation.method), "args": .array(mutation.args)]]
      request["payload"] = .object(input)
      return .object(request)
    })
    try BookmarkPendingStore(directory: directory).write(.object(saved))
  }

  @Test func firstLaunchInfersLegacyDeliveryAndPrunesOneThousandReceiptsToNewestThirtyTwo() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir)
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    let old = try JSONValue.parseBookmark(before)
    #expect(old["version"] == 2)
    #expect(old["payload"]?["formatVersion"] == 2)
    #expect(old["payload"]?["requests"]?.array?.count == 1000)
    #expect(old["payload"]?["requests"]?.array?.allSatisfy { entry in
      ["order", "delivered", "confirmed", "settledAtMs", "legacy"].allSatisfy { entry[$0] == nil }
    } == true)
    let clock = LegacyReceiptClock()
    let owner = coordinator(clock, directory: dir)
    #expect(try Data(contentsOf: path) == before)
    try confirm(owner)
    let settled = try payload(dir)
    #expect(settled["requests"]?.array?.allSatisfy { $0["legacy"] == true && $0["delivered"] == true && $0["confirmed"] == true && $0["settledAtMs"] == 0 } == true)
    clock.now = 299_999
    #expect(!(try owner.maintainReceipts()))
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    let current = owner.desiredView(engine: "")
    clock.now = 300_000
    _ = try owner.maintainReceipts()
    let pruned = try payload(dir)
    #expect(pruned["requests"]?.array?.count == 32)
    #expect(Set(pruned["requests"]?.array?.compactMap { $0["id"]?.string } ?? []) == Set((969...1000).map { "legacy-\($0)" }))
    #expect(pruned["expiredRequests"]?.object?.count == 968)
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1") }
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try owner.submit(profile: "p", mutations: [self.rename(2000)], requestID: "legacy-1") }
    #expect(owner.desiredView(engine: "") == current)
    owner.fencePumpAdmissions()
    let restarted = coordinator(clock, directory: dir)
    #expect(throws: BookmarkCoordinatorError.expiredRequest) { try restarted.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1") }
    #expect(restarted.desiredView(engine: "").document == current.document)
  }

  @Test(arguments: ["pending", "facts", "conflict", "unconfirmed"])
  func legacyDeliveryInferencePreservesSettlementHolds(_ hold: String) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir, hold: hold)
    let clock = LegacyReceiptClock()
    let owner = coordinator(clock, directory: dir)
    let chrome = hold == "pending" ? BookmarkCoordinatorTests().document(["https://a.test"]) : nil
    try confirm(owner, document: chrome, proof: hold != "unconfirmed")
    clock.now = 9_000_000
    _ = try owner.maintainReceipts()
    let held = try payload(dir)
    #expect(held["requests"]?.array?.count == 1000)
    #expect(held["requests"]?.array?.allSatisfy { $0["delivered"] == true && $0["settledAtMs"]?.isNull == true } == true)
    #expect(try owner.submit(profile: "p", mutations: [rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    if hold == "facts" {
      try clearFacts(owner)
      clock.now += 299_999
      #expect(!(try owner.maintainReceipts()))
      clock.now += 1
      #expect(try owner.maintainReceipts())
      #expect(try payload(dir)["requests"]?.array?.count == 32)
    }
  }

  @Test(arguments: [false, true])
  func restoredLegacyFlagRequiresNewProofAndFullGrace(_ savedDelivery: Bool) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir)
    let clock = LegacyReceiptClock()
    let first = coordinator(clock, directory: dir)
    try confirm(first)
    #expect(try payload(dir)["requests"]?.array?.allSatisfy { $0["confirmed"] == true && $0["settledAtMs"] == 0 } == true)
    first.fencePumpAdmissions()
    if !savedDelivery {
      var saved = try #require(payload(dir).object)
      saved["requests"] = .array(try (saved["requests"]?.array ?? []).map { value in
        var entry = try #require(value.object)
        entry["delivered"] = false
        entry["confirmed"] = false
        entry["settledAtMs"] = .null
        return .object(entry)
      })
      try BookmarkPendingStore(directory: dir).write(.object(saved))
    }
    clock.now = 600_000
    let restored = coordinator(clock, directory: dir)
    try confirm(restored, proof: false)
    _ = try restored.maintainReceipts()
    #expect(try payload(dir)["requests"]?.array?.count == 1000)
    #expect(try payload(dir)["requests"]?.array?.allSatisfy { $0["delivered"] == true && $0["confirmed"] == false && $0["settledAtMs"]?.isNull == true } == true)
    #expect(try restored.submit(profile: "p", mutations: [rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    try confirm(restored)
    clock.now = 899_999
    #expect(!(try restored.maintainReceipts()))
    clock.now = 900_000
    #expect(try restored.maintainReceipts())
    #expect(try payload(dir)["requests"]?.array?.count == 32)
  }

  @Test(arguments: [false, true])
  func currentUnacknowledgedReceiptsStayExplicitAcrossRestartAndOwnerHandover(_ handover: Bool) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = LegacyReceiptClock()
    let original = coordinator(clock, directory: dir)
    original.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    for index in 1...34 { try original.submit(profile: "p", mutations: [rename(index)], requestID: "bookmarks-\(index)") }
    try confirm(original)
    try clearFacts(original)
    #expect(try payload(dir)["requests"]?.array?.allSatisfy { $0["legacy"] == false && $0["delivered"] == false } == true)
    original.fencePumpAdmissions()
    let restored: BookmarkCoordinator
    if handover {
      original.reloadJournalForOwnerReplacement()
      restored = original
    } else {
      restored = coordinator(clock, directory: dir)
    }
    try confirm(restored, epoch: handover ? 2 : 0)
    clock.now = 9_000_000
    #expect(!(try restored.maintainReceipts()))
    #expect(try restored.submit(profile: "p", mutations: [rename(1)], requestID: "bookmarks-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    #expect(try payload(dir)["requests"]?.array?.count == 34)
    #expect(try payload(dir)["requests"]?.array?.allSatisfy { $0["legacy"] == false && $0["delivered"] == false && $0["settledAtMs"]?.isNull == true } == true)
  }

  @Test func ambiguousLegacyRevisionTiesRemainTogetherAtTheFloor() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir, tied: true)
    let clock = LegacyReceiptClock()
    let owner = coordinator(clock, directory: dir)
    try confirm(owner)
    clock.now = 300_000
    #expect(try owner.maintainReceipts())
    let saved = try payload(dir)
    #expect(saved["requests"]?.array?.count == 40)
    #expect(Set(saved["requests"]?.array?.compactMap { $0["id"]?.string } ?? []) == Set((961...1000).map { "legacy-\($0)" }))
    #expect(saved["expiredRequests"]?.object?.count == 960)
  }

  @Test(arguments: [false, true])
  func firstLegacyPruneSurvivesFailureBeforeOrAfterRename(_ committed: Bool) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir)
    let clock = LegacyReceiptClock()
    let failure = LegacyReceiptFailureSwitch()
    var operations = BookmarkPendingFileOperations.live
    let rename = operations.rename
    let syncDirectory = operations.syncDirectory
    operations.rename = { source, target in
      if failure.enabled && !committed { throw BookmarkPendingStoreError.io("injected before legacy prune rename", EIO) }
      try rename(source, target)
    }
    operations.syncDirectory = { url in
      try syncDirectory(url)
      if failure.enabled && committed { throw BookmarkPendingStoreError.io("injected after legacy prune rename", EIO) }
    }
    let owner = coordinator(clock, directory: dir, operations: operations)
    try confirm(owner)
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    let current = owner.desiredView(engine: "").document
    clock.now = 300_000
    failure.enabled = true
    #expect(throws: (any Error).self) { try owner.maintainReceipts() }
    #expect(owner.desiredView(engine: "").document == current)
    owner.fencePumpAdmissions()
    if committed {
      #expect(owner.bookmarkWritesPaused)
      #expect(try payload(dir)["requests"]?.array?.count == 32)
      #expect(try payload(dir)["expiredRequests"]?.object?.count == 968)
      let restarted = coordinator(clock, directory: dir)
      #expect(throws: BookmarkCoordinatorError.expiredRequest) { try restarted.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1") }
      #expect(restarted.desiredView(engine: "").document == current)
    } else {
      #expect(!owner.bookmarkWritesPaused)
      #expect(try Data(contentsOf: path) == before)
      #expect(try payload(dir)["requests"]?.array?.count == 1000)
      #expect(try payload(dir)["expiredRequests"]?.object?.isEmpty == true)
      failure.enabled = false
      clock.now = 299_999
      #expect(try owner.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
      let restarted = coordinator(clock, directory: dir)
      try confirm(restarted, proof: false)
      clock.now = 9_000_000
      #expect(!(try restarted.maintainReceipts()))
      #expect(try restarted.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    }
  }

  @Test func readOnlyLegacyRestorePreservesBytesTimestampAndRetryHistory() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeLegacy(dir)
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    let stamp = Date(timeIntervalSince1970: 11)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path)
    let clock = LegacyReceiptClock()
    clock.now = 9_000_000
    let readOnly = coordinator(clock, directory: dir, readOnly: true)
    try confirm(readOnly)
    #expect(!(try readOnly.maintainReceipts()))
    #expect(throws: BookmarkPendingStoreError.unavailable) { try readOnly.submit(profile: "p", mutations: [self.rename(1)], requestID: "legacy-1") }
    #expect(try Data(contentsOf: path) == before)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
    #expect(try payload(dir)["requests"]?.array?.count == 1000)
    let writable = coordinator(clock, directory: dir)
    #expect(try writable.submit(profile: "p", mutations: [rename(1)], requestID: "legacy-1").view.document["nodes"]?["b0"]?["title"] == "Edited 1")
    #expect(writable.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 1000")
  }
}

private final class LegacyReceiptClock {
  var now: Double = 0
}

private final class LegacyReceiptFailureSwitch {
  var enabled = false
}
