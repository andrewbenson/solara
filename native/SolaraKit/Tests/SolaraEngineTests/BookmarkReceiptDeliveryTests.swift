import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkReceiptDeliveryTests {
  private func directory() throws -> URL {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ReceiptDeliveryScratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  private func coordinator(_ directory: URL, probe: ReceiptDeliveryProbe) -> BookmarkCoordinator {
    var operations = BookmarkPendingFileOperations.live
    let write = operations.writeNew
    operations.writeNew = { path, data in
      try probe.writing()
      try write(path, data)
    }
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 0 }, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    return owner
  }

  private func rename(_ index: Int) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["b0", ["title": .string("Edited \(index)")]])
  }

  private func delivered(_ id: String, in directory: URL) throws -> Bool {
    let payload = try #require(BookmarkPendingStore(directory: directory).load().payload)
    let value: Bool? = payload["requests"]?.array?.first { $0["id"] == .string(id) }?["delivered"]?.bool
    return try #require(value)
  }

  @Test func deliveryDoesNotWriteAndFailedFlushPreservesAcknowledgment() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    owner.fencePumpAdmissions()
    let writes = probe.count
    probe.fail = true
    #expect(try owner.acknowledgeReceipt(requestID: "first", engine: ""))
    #expect(probe.count == writes)
    #expect(try !delivered("first", in: path))
    #expect(throws: (any Error).self) { try owner.maintainReceipts() }
    probe.fail = false
    #expect(try owner.maintainReceipts())
    #expect(try delivered("first", in: path))
  }

  @Test func deliveryAdmissionAllowsConcurrentCoordinatorReads() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    owner.fencePumpAdmissions()
    let acknowledged = try owner.acknowledgeReceipt(requestID: "first", engine: "", admission: {
      let finished = DispatchSemaphore(value: 0)
      let reader = Thread {
        _ = owner.desiredView(engine: "")
        finished.signal()
      }
      reader.start()
      #expect(finished.wait(timeout: .now() + 5) == .success)
    })
    #expect(acknowledged)
  }

  @Test func nextMutationCoalescesDeliveryIntoItsSingleCheckpoint() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    owner.fencePumpAdmissions()
    let writes = probe.count
    #expect(try owner.acknowledgeReceipt(requestID: "first", engine: ""))
    try owner.submit(profile: "p", mutations: [rename(2)], requestID: "second")
    #expect(probe.count == writes + 1)
    #expect(try delivered("first", in: path))
    #expect(try !delivered("second", in: path))
    #expect(throws: BookmarkWriterError.staleBinding) { try owner.acknowledgeReceipt(requestID: "second", engine: "other") }
    #expect(!(try owner.acknowledgeReceipt(requestID: "unknown", engine: "")))
  }

  @Test func deliveryDuringCheckpointPersistenceSurvivesInstallation() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    owner.fencePumpAdmissions()
    probe.duringNextWrite = {
      let acknowledged = try owner.acknowledgeReceipt(requestID: "first", engine: "")
      #expect(acknowledged)
    }
    try owner.submit(profile: "p", mutations: [rename(2)], requestID: "second")
    #expect(try !delivered("first", in: path))
    #expect(try owner.maintainReceipts())
    #expect(try delivered("first", in: path))
  }

  @Test func restartBeforeDeliveryFlushConservativelyRetainsUndeliveredReceipt() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    let original = try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    owner.fencePumpAdmissions()
    #expect(try owner.acknowledgeReceipt(requestID: "first", engine: ""))
    let restarted = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 9_000_000 }, pendingStore: BookmarkPendingStore(directory: path))
    #expect(try !delivered("first", in: path))
    let before = restarted.desiredView(engine: "")
    let journal = path.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    let replay = try restarted.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    #expect(replay.results == original.results)
    #expect(replay.view.document == original.view.document)
    #expect(replay.view.revision == original.view.revision)
    #expect(!replay.view.readyForSync)
    #expect(restarted.desiredView(engine: "") == before)
    #expect(try Data(contentsOf: journal) == bytes)
  }

  @Test func idleDeliveryFlushesWithoutAnotherMutation() async throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    #expect(try owner.acknowledgeReceipt(requestID: "first", engine: ""))
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, try !delivered("first", in: path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try delivered("first", in: path))
    owner.fencePumpAdmissions()
  }

  @Test func revocationCancelsPendingDeliveryFlush() async throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let probe = ReceiptDeliveryProbe()
    let owner = coordinator(path, probe: probe)
    try owner.submit(profile: "p", mutations: [rename(1)], requestID: "first")
    #expect(try owner.acknowledgeReceipt(requestID: "first", engine: ""))
    owner.fencePumpAdmissions()
    let bytes = try Data(contentsOf: path.appendingPathComponent(BookmarkPendingStore.journalName))
    try await Task.sleep(for: .milliseconds(200))
    #expect(try Data(contentsOf: path.appendingPathComponent(BookmarkPendingStore.journalName)) == bytes)
    #expect(try !delivered("first", in: path))
  }
}

private final class ReceiptDeliveryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  private var fails = false
  private var nextWrite: (() throws -> Void)?
  var count: Int { lock.withLock { writes } }
  var fail: Bool {
    get { lock.withLock { fails } }
    set { lock.withLock { fails = newValue } }
  }
  var duringNextWrite: (() throws -> Void)? {
    get { lock.withLock { nextWrite } }
    set { lock.withLock { nextWrite = newValue } }
  }

  func writing() throws {
    let (fail, callback) = lock.withLock {
      writes += 1
      let callback = nextWrite
      nextWrite = nil
      return (fails, callback)
    }
    if fail { throw BookmarkPendingStoreError.io("injected delivery flush failure", EIO) }
    try callback?()
  }
}

extension BookmarkReceiptDeliveryTests {
  @Test func acknowledgmentDoesNotReadRetentionClock() throws {
    let clock = ReceiptDeliveryClock()
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock.read() })
    owner.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    for index in 1...33 {
      try owner.submit(profile: "p", mutations: [rename(index)], requestID: "id-\(index)")
      try owner.acknowledgeReceipt(requestID: "id-\(index)", engine: "")
    }
    let view = owner.desiredView(engine: "")
    let confirmation = try #require(owner.beginReceiptRead(engine: "", epoch: 0))
    #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: confirmation))
    try owner.submit(profile: "p", mutations: [rename(34)], requestID: "id-34")
    let calls = clock.calls
    #expect(try owner.acknowledgeReceipt(requestID: "id-34", engine: ""))
    #expect(clock.calls == calls)
    #expect(try owner.acknowledgeReceipt(requestID: "id-34", engine: ""))
    #expect(clock.calls == calls)
    owner.fencePumpAdmissions()
  }

}

private final class ReceiptDeliveryClock {
  var now: Double = 0
  var calls = 0
  func read() -> Double { calls += 1; return now }
}
