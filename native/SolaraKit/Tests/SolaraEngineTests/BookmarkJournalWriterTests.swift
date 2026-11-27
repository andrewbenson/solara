import Dispatch
import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkJournalWriterTests {
  private func directory() throws -> URL {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkWriterScratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func refusedRestoreLeavesTheRemovalAvailableForRetry() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pending = BookmarkPendingStore(directory: directory)
    let setup = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: pending)
    setup.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test", "https://b.test", "https://c.test"]), ready: true)
    let deletion = try await setup.performJournalWrite {
      try $0.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["b2", "b0"]])])
    }
    let removed = try #require(deletion.results.first)
    #expect(removed["places"]?.array?.compactMap { $0["id"]?.string } == ["b2", "b0"])
    var operations = BookmarkPendingFileOperations.live
    operations.syncFile = { _ in throw BookmarkPendingStoreError.io("file", 5) }
    let refusing = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p",
      pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    let restore = BookmarkMutation(method: "restoreBookmarks", args: [removed])
    await #expect(throws: BookmarkPendingStoreError.self) {
      _ = try await refusing.performJournalWrite { try $0.submit(profile: "p", mutations: [restore]) }
    }
    #expect(refusing.desiredView(engine: "").document == deletion.view.document)
    let retrying = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: pending)
    let restored = try await retrying.performJournalWrite { try $0.submit(profile: "p", mutations: [restore]) }
    let bar = BookmarkFlat.roots("").bar
    #expect(restored.view.document["nodes"]?[bar]?["children"]?.array?.compactMap(\.string) == ["b0", "b1", "b2"])
  }

  @MainActor @Test func mainHandoffAndReadsFinishWhileSyncBlocksAndQuitWaits() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let probe = JournalWriterProbe()
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { url in entered.signal(); guard release.wait(timeout: .now() + 5) == .success else { throw BookmarkPendingStoreError.unavailable }; try sync(url) }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let original = coordinator.desiredView(engine: "")
    let done = DispatchSemaphore(value: 0)
    coordinator.enqueueJournalWrite({ staged in
      try staged.submit(profile: "p", mutations: [.init(method: "toggleBookmark", args: ["p", ["url": "https://a.test"]])], requestID: "toggle")
    }, completion: { result in probe.finished("toggle", result); done.signal() })
    #expect(journalWriterWait(entered) == .success)
    #expect(probe.count == 0)
    #expect(coordinator.desiredView(engine: "") == original)
    #expect(coordinator.membership(profile: "p", url: "https://a.test"))
    let quitDone = DispatchSemaphore(value: 0)
    coordinator.beginJournalQuit { result in probe.quit(result); quitDone.signal() }
    coordinator.beginJournalQuit { result in probe.quit(result); quitDone.signal() }
    coordinator.enqueueJournalWrite({ staged in try staged.submit(profile: "p", mutations: [], requestID: "tooLate") }, completion: { result in probe.finished("tooLate", result) })
    #expect(probe.receipt("tooLate") == nil)
    #expect(probe.quitCount == 0)
    release.signal()
    #expect(journalWriterWait(done) == .success)
    for _ in 0..<2 { #expect(journalWriterWait(quitDone) == .success) }
    #expect(probe.quitSuccesses == 2)
    #expect(probe.receipt("toggle")?.results == [false])
    let reopened = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    #expect(!reopened.membership(profile: "p", url: "https://a.test"))
    #expect(try reopened.submit(profile: "p", mutations: [.init(method: "toggleBookmark", args: ["p", ["url": "https://a.test"]])], requestID: "toggle").results == [false])
  }

  @Test(arguments: [false, true]) func failedLaterBatchKeepsAcknowledgedPrefixAndUncertainReceipt(postRename: Bool) async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let setup = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    setup.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let firstMutation = BookmarkMutation(method: "updateBookmark", args: ["b0", ["title": "Saved"]])
    let first = try setup.submit(profile: "p", mutations: [firstMutation], requestID: "saved")
    var operations = BookmarkPendingFileOperations.live
    if postRename { operations.syncDirectory = { _ in throw BookmarkPendingStoreError.io("directory", 5) } }
    else { operations.syncFile = { _ in throw BookmarkPendingStoreError.io("file", 5) } }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    let later = BookmarkMutation(method: "updateBookmark", args: ["b0", ["title": "Unconfirmed"]])
    do { _ = try await coordinator.performJournalWrite { try $0.submit(profile: "p", mutations: [later], requestID: "later") }; Issue.record("Failed persistence acknowledged an edit") } catch {}
    #expect(coordinator.desiredView(engine: "").document == first.view.document)
    #expect(coordinator.bookmarkWritesPaused == postRename)
    if postRename {
      do { try await coordinator.flushJournalForQuit(); Issue.record("Uncertain journal reported a successful quit flush") } catch {}
    } else { try await coordinator.flushJournalForQuit() }
    let reopened = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    #expect(try reopened.submit(profile: "p", mutations: [firstMutation], requestID: "saved").view.document == first.view.document)
    #expect(reopened.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == (postRename ? "Unconfirmed" : "Saved"))
    if postRename {
      #expect(try reopened.submit(profile: "p", mutations: [later], requestID: "later").view.document["nodes"]?["b0"]?["title"] == "Unconfirmed")
    }
  }

  @Test func scheduledWorkSealsBatchesInAdmissionOrder() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = BookmarkJournalWriter()
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let probe = JournalWriterProbe()
    writer.schedule { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    #expect(journalWriterWait(entered) == .success)
    let process: @Sendable ([BookmarkJournalWriter.Operation]) -> Void = { operations in
      for operation in operations { operation(coordinator)(nil) }
    }
    writer.enqueue({ staged in try staged.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "First"]])], requestID: "first") }, process: process) { result in probe.finished("first", result); done.signal() }
    writer.schedule {
      probe.finished("barrier", .success(.init(view: coordinator.desiredView(engine: ""), results: [])))
      done.signal()
    }
    writer.enqueue({ staged in try staged.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Last"]])], requestID: "last") }, process: process) { result in probe.finished("last", result); done.signal() }
    release.signal()
    for _ in 0..<3 { #expect(journalWriterWait(done) == .success) }
    #expect(probe.receipt("barrier")?.view.document["nodes"]?["b0"]?["title"] == "First")
    #expect(probe.receipt("last")?.view.document["nodes"]?["b0"]?["title"] == "Last")
  }

  @Test func deliveryDuringBlockedBatchSurvivesInstallAndQuitPersistsIt() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let setup = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    setup.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    try setup.submit(profile: "p", mutations: [], requestID: "first")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let probe = JournalWriterProbe()
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { url in
      if probe.writes == 0 { entered.signal(); guard release.wait(timeout: .now() + 5) == .success else { throw BookmarkPendingStoreError.unavailable } }
      probe.wrote()
      try sync(url)
    }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    let done = DispatchSemaphore(value: 0)
    coordinator.enqueueJournalWrite({ staged in try staged.submit(profile: "p", mutations: [], requestID: "second") }) { result in probe.finished("second", result); done.signal() }
    #expect(journalWriterWait(entered) == .success)
    #expect(try coordinator.acknowledgeReceipt(requestID: "first", engine: ""))
    release.signal()
    #expect(journalWriterWait(done) == .success)
    try await coordinator.flushJournalForQuit()
    let requests = try #require(BookmarkPendingStore(directory: directory).load().payload?["requests"]?.array)
    #expect(requests.first { $0["id"] == "first" }?["delivered"] == true)
    #expect(requests.first { $0["id"] == "second" }?["delivered"] == false)
  }

  @Test(.timeLimit(.minutes(1))) func cancellingQueuedQuitKeepsDeliveryMaintenanceEnabled() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = JournalWriterProbe()
    var operations = BookmarkPendingFileOperations.live
    let write = operations.writeNew
    let writes = JournalWriterSignal()
    operations.writeNew = { url, data in
      try write(url, data)
      probe.wrote()
      writes.signal()
    }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    try coordinator.submit(profile: "p", mutations: [], requestID: "first")
    try await writes.wait()
    let entered = JournalWriterSignal()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocker = Task {
      await coordinator.offMain {
        entered.signal()
        release.wait()
      }
    }
    try await entered.wait()
    let done = JournalWriterSignal()
    coordinator.beginJournalQuit { _ in done.signal() }
    coordinator.cancelJournalQuit()
    release.signal()
    await blocker.value
    try await done.wait()
    let before = probe.writes
    #expect(try coordinator.acknowledgeReceipt(requestID: "first", engine: ""))
    try await writes.wait()
    #expect(probe.writes > before)
    try await coordinator.flushJournalForQuit()
    let requests = try #require(BookmarkPendingStore(directory: directory).load().payload?["requests"]?.array)
    #expect(requests.first { $0["id"] == "first" }?["delivered"] == true)
  }

  @Test func cancellingCompletedQuitReopensAdmissionWithoutLosingReceipts() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let first = try await coordinator.performJournalWrite { try $0.submit(profile: "p", mutations: [], requestID: "first") }
    try await coordinator.flushJournalForQuit()
    do { _ = try await coordinator.performJournalWrite { try $0.submit(profile: "p", mutations: [], requestID: "closed") }; Issue.record("Quit admitted a write") } catch {}
    coordinator.cancelJournalQuit()
    _ = try await coordinator.performJournalWrite { try $0.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "After cancellation"]])], requestID: "second") }
    try await coordinator.flushJournalForQuit()
    let reopened = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    #expect(reopened.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "After cancellation")
    let replay = try reopened.submit(profile: "p", mutations: [], requestID: "first")
    #expect(replay.results == first.results)
    #expect(replay.view.document == first.view.document)
    #expect(replay.view.revision == first.view.revision)
  }

  @Test(.timeLimit(.minutes(1))) func queuedEditsShareCheckpointAndKeepOriginalReceipts() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkWriterScratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = JournalWriterProbe()
    var operations = BookmarkPendingFileOperations.live
    let sync = operations.syncFile
    operations.syncFile = { fd in probe.wrote(); try sync(fd) }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://a.test"]), ready: true)
    let entered = JournalWriterSignal()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocker = Task {
      await coordinator.offMain {
        entered.signal()
        release.wait()
      }
    }
    try await entered.wait()
    let done = JournalWriterSignal()
    for title in ["First", "Second", "Third"] {
      coordinator.enqueueJournalWrite({ staged in
        try staged.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": .string(title)]])], requestID: title)
      }, completion: { result in probe.finished(title, result); done.signal() })
    }
    coordinator.enqueueJournalWrite({ staged in
      try staged.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "First"]])], requestID: "First")
    }, completion: { result in probe.finished("replay", result); done.signal() })
    coordinator.enqueueJournalWrite({ staged in
      try staged.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Conflict"]])], requestID: "First")
    }, completion: { result in probe.finished("conflict", result); done.signal() })
    #expect(probe.count == 0)
    release.signal()
    await blocker.value
    try await done.wait(for: 5)
    #expect(probe.writes == 1)
    #expect(probe.count == 5)
    #expect(probe.receipt("replay") == probe.receipt("First"))
    #expect(probe.failure("conflict") as? BookmarkCoordinatorError == .conflictingRequest)
    #expect(coordinator.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Third")
    let reopened = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    for title in ["First", "Second", "Third"] {
      let receipt = try reopened.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": .string(title)]])], requestID: title)
      #expect(receipt.results == probe.receipt(title)?.results)
      #expect(receipt.view.document == probe.receipt(title)?.view.document)
      #expect(receipt.view.revision == probe.receipt(title)?.view.revision)
      #expect(receipt.view.document["nodes"]?["b0"]?["title"] == .string(title))
    }
  }
}

private final class JournalWriterProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [String: Result<BookmarkReceipt, Error>] = [:]
  private var syncCount = 0
  private var quits: [Bool] = []
  var writes: Int { lock.lock(); defer { lock.unlock() }; return syncCount }
  var count: Int { lock.lock(); defer { lock.unlock() }; return results.count }
  var quitCount: Int { lock.lock(); defer { lock.unlock() }; return quits.count }
  var quitSuccesses: Int { lock.lock(); defer { lock.unlock() }; return quits.filter { $0 }.count }
  func quit(_ result: Result<Void, Error>) { lock.lock(); defer { lock.unlock() }; quits.append((try? result.get()) != nil) }
  func wrote() { lock.lock(); defer { lock.unlock() }; syncCount += 1 }
  func finished(_ title: String, _ result: Result<BookmarkReceipt, Error>) { lock.lock(); defer { lock.unlock() }; results[title] = result }
  func failure(_ title: String) -> Error? { lock.lock(); defer { lock.unlock() }; if case let .failure(error)? = results[title] { return error }; return nil }
  func receipt(_ title: String) -> BookmarkReceipt? { lock.lock(); defer { lock.unlock() }; return try? results[title]?.get() }
}

private struct JournalWriterSignal: Sendable {
  private let event = AsyncStream<Void>.makeStream()

  func signal() { event.continuation.yield(()) }

  func wait(for count: Int = 1) async throws {
    var iterator = event.stream.makeAsyncIterator()
    for _ in 0..<count {
      try #require(await iterator.next() != nil)
    }
  }
}

private func journalWriterWait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult { semaphore.wait(timeout: .now() + 5) }
