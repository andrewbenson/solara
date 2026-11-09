import Dispatch
import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkDurabilityConcurrencyTests {
  private func directory() throws -> URL {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkConcurrencyScratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  private func document() -> JSONValue { BookmarkCoordinatorTests().document(["https://a.test", "https://b.test"]) }

  private func owner(_ directory: URL, operations: BookmarkPendingFileOperations = .live) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", owningProfiles: ["": "p"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
  }

  private func rename(_ id: String, _ title: String) -> BookmarkMutation {
    .init(method: "updateBookmark", args: [.string(id), ["title": .string(title)]])
  }

  private func factRaceOwner(_ directory: URL, operations: BookmarkPendingFileOperations = .live, moved: Bool = false) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": moved ? "E2" : "E1", "alias": "E1", "q": "E2"], defaultProfile: "p", owningProfiles: ["E1": moved ? "alias" : "p", "E2": "q"], stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
  }

  private func factRaceDocument(_ engine: String) -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    return ["nodes": .object([
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["b0"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
      "b0": ["id": "b0", "kind": "url", "parentId": .string(roots.bar), "title": "Page", "url": "https://a.test", "addedAt": 10]
    ]), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  private func mutateFact(_ mutation: String, coordinator: BookmarkCoordinator, seq: UInt64) throws -> Bool {
    switch mutation {
    case "ack": return try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: seq, mintedHLC: "00000003f.0001.device")])
    case "clear": return try coordinator.clearBookmarkFacts(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", seq: seq)])
    default: return try coordinator.observeRemoteRecords(profileId: "p", expectedEngine: "E1", records: [(key: "bm:b0", hlc: "00000003f.0002.remote")])
    }
  }

  @Test(arguments: ["ack", "clear", "observe"], [false, true])
  func remapAndFactWritesSerializeWithoutCrossingEngines(_ mutation: String, factFirst: Bool) throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let setup = factRaceOwner(directory)
    setup.seed(engine: "E1", document: factRaceDocument("E1"), ready: true)
    setup.seed(engine: "E2", document: factRaceDocument("E2"), ready: true)
    try setup.submit(profile: "q", mutations: [rename("b0", "Pending on E2")])
    try setup.submit(profile: "p", mutations: [rename("b0", "Publishing from E1")])
    let gate = DurabilityWriteGate()
    let coordinator = factRaceOwner(directory, operations: gate.operations)
    let beforeFirst = coordinator.desiredView(engine: "E1")
    let beforeSecond = coordinator.desiredView(engine: "E2")
    let publishing = try #require(beforeFirst.facts["bm:b0"])
    let other = try #require(beforeSecond.facts["bm:b0"])
    #expect(publishing.seq > other.seq)
    let probe = DurabilityWorkProbe()
    let firstDone = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let secondDone = DispatchSemaphore(value: 0)
    let factWrite: @Sendable () -> Void = {
      do { probe.finish("fact", try self.mutateFact(mutation, coordinator: coordinator, seq: publishing.seq)) }
      catch BookmarkWriterError.staleBinding { probe.rejectStale("fact") }
      catch { probe.fail(error) }
    }
    let remapWrite: @Sendable () -> Void = {
      probe.finish("remap", coordinator.remap(profiles: ["p": "E2", "alias": "E1", "q": "E2"], defaultProfile: "p", owningProfiles: ["E1": "alias", "E2": "q"]))
    }
    Thread.detachNewThread {
      defer { firstDone.signal() }
      if factFirst { factWrite() } else { remapWrite() }
    }
    #expect(gate.entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
      secondStarted.signal()
      defer { secondDone.signal() }
      if factFirst { remapWrite() } else { factWrite() }
    }
    #expect(secondStarted.wait(timeout: .now() + 5) == .success)
    let prematureSecond = secondDone.wait(timeout: .now() + 0.1)
    gate.release.signal()
    #expect(prematureSecond == .timedOut)
    #expect(firstDone.wait(timeout: .now() + 5) == .success)
    if prematureSecond != .success { #expect(secondDone.wait(timeout: .now() + 5) == .success) }
    #expect(probe.errors.isEmpty)
    #expect(probe.result("remap") == true)
    #expect(probe.result("fact") == (factFirst ? true : nil))
    #expect(probe.wasStale("fact") == !factFirst)
    var expectedFirst = beforeFirst
    if factFirst {
      switch mutation {
      case "ack":
        expectedFirst.facts.removeValue(forKey: "bm:b0")
        expectedFirst.lastSeen["bm:" + JSONValue.array(["none", "bm:b0"]).canonical] = "00000003f.0001.device"
      case "clear": expectedFirst.facts.removeValue(forKey: "bm:b0")
      default: expectedFirst.lastSeen["bm:" + JSONValue.array(["none", "bm:b0"]).canonical] = "00000003f.0002.remote"
      }
    }
    #expect(coordinator.engine(profile: "p") == "E2")
    #expect(coordinator.engine(profile: "alias") == "E1")
    #expect(coordinator.desiredView(engine: "E1") == expectedFirst)
    #expect(coordinator.desiredView(engine: "E2") == beforeSecond)
    #expect(coordinator.bookmarkFacts(profileId: "p") == beforeSecond.facts)
    #expect(coordinator.bookmarkFacts(profileId: "alias") == expectedFirst.facts)
    let restored = factRaceOwner(directory, moved: true)
    #expect(restored.recoveryNotice == nil)
    for expected in [expectedFirst, beforeSecond] {
      let view = restored.desiredView(engine: expected.engine)
      #expect(view.document == expected.document)
      #expect(view.revision == expected.revision)
      #expect(view.facts == expected.facts)
      #expect(view.lastSeen == expected.lastSeen)
    }
    #expect(restored.bookmarkFacts(profileId: "p") == beforeSecond.facts)
    #expect(restored.bookmarkFacts(profileId: "alias") == expectedFirst.facts)
  }

  @Test func readersCompleteWhileDurableWriteIsHeldOpen() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = DurabilityWriteGate()
    let coordinator = owner(directory, operations: gate.operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let before = coordinator.desiredView(engine: "")
    let probe = DurabilityWorkProbe()
    let writerDone = DispatchSemaphore(value: 0)
    let readerDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      defer { writerDone.signal() }
      do { probe.accept("writer", try coordinator.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])) }
      catch { probe.fail(error) }
    }
    let entered = gate.entered.wait(timeout: .now() + 5)
    #expect(entered == .success)
    Thread.detachNewThread {
      probe.read(view: coordinator.desiredView(engine: ""), member: coordinator.membership(profile: "alias", url: "https://a.test"), fact: coordinator.bookmarkFacts(profileId: "p")["bm:b0"])
      readerDone.signal()
    }
    let readerResult = readerDone.wait(timeout: .now() + 1)
    gate.release.signal()
    #expect(readerResult == .success)
    #expect(writerDone.wait(timeout: .now() + 5) == .success)
    if readerResult != .success { #expect(readerDone.wait(timeout: .now() + 5) == .success) }
    #expect(probe.errors.isEmpty)
    #expect(probe.readView == before)
    #expect(probe.readMember == true)
    #expect(probe.readFact == nil)
    #expect(!coordinator.membership(profile: "p", url: "https://a.test"))
  }

  @Test func concurrentSubmitsInstallInOrderWithoutLosingEitherEdit() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = DurabilityWriteGate()
    let coordinator = owner(directory, operations: gate.operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let revision = coordinator.desiredView(engine: "").revision
    let probe = DurabilityWorkProbe()
    let firstDone = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let secondDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      defer { firstDone.signal() }
      do { probe.accept("first", try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "First"]])])) }
      catch { probe.fail(error) }
    }
    #expect(gate.entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
      secondStarted.signal()
      defer { secondDone.signal() }
      do { probe.accept("second", try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b1", ["title": "Second"]])])) }
      catch { probe.fail(error) }
    }
    #expect(secondStarted.wait(timeout: .now() + 5) == .success)
    let prematureSecond = secondDone.wait(timeout: .now() + 0.1)
    gate.release.signal()
    #expect(prematureSecond == .timedOut)
    #expect(firstDone.wait(timeout: .now() + 5) == .success)
    if prematureSecond != .success { #expect(secondDone.wait(timeout: .now() + 5) == .success) }
    #expect(probe.errors.isEmpty)
    let first = try #require(probe.receipt("first"))
    let second = try #require(probe.receipt("second"))
    #expect(first.view.revision == revision + 1)
    #expect(second.view.revision == revision + 2)
    #expect(first.view.document["nodes"]?["b1"]?["title"] == "Page")
    #expect(second.view.document["nodes"]?["b0"]?["title"] == "First")
    #expect(second.view.document["nodes"]?["b1"]?["title"] == "Second")
    let restored = owner(directory).desiredView(engine: "")
    #expect(restored.document == second.view.document)
    #expect(restored.revision == second.view.revision)
  }

}

private enum DurabilityTestFailure: Error { case injected }

private final class DurabilityWriteGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var held = false
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let liveSync = operations.syncFile
    operations.syncFile = { url in
      self.lock.lock()
      let hold = !self.held
      self.held = true
      self.lock.unlock()
      if hold {
        self.entered.signal()
        guard self.release.wait(timeout: .now() + 10) == .success else { throw DurabilityTestFailure.injected }
      }
      try liveSync(url)
    }
    return operations
  }
}

private final class DurabilityWorkProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedReceipts: [String: BookmarkReceipt] = [:]
  private var storedErrors: [String] = []
  private var storedResults: [String: Bool] = [:]
  private var staleBindings: Set<String> = []
  private var storedReadView: BookmarkDesiredView?
  private var storedReadMember: Bool?
  private var storedReadFact: BookmarkEditFact?
  var errors: [String] { lock.withLock { storedErrors } }
  var readView: BookmarkDesiredView? { lock.withLock { storedReadView } }
  var readMember: Bool? { lock.withLock { storedReadMember } }
  var readFact: BookmarkEditFact? { lock.withLock { storedReadFact } }
  func accept(_ key: String, _ receipt: BookmarkReceipt) { lock.withLock { storedReceipts[key] = receipt } }
  func receipt(_ key: String) -> BookmarkReceipt? { lock.withLock { storedReceipts[key] } }
  func finish(_ key: String, _ result: Bool) { lock.withLock { storedResults[key] = result } }
  func result(_ key: String) -> Bool? { lock.withLock { storedResults[key] } }
  func rejectStale(_ key: String) { lock.withLock { _ = staleBindings.insert(key) } }
  func wasStale(_ key: String) -> Bool { lock.withLock { staleBindings.contains(key) } }
  func fail(_ error: any Error) { lock.withLock { storedErrors.append(String(describing: error)) } }
  func read(view: BookmarkDesiredView, member: Bool, fact: BookmarkEditFact?) {
    lock.withLock { storedReadView = view; storedReadMember = member; storedReadFact = fact }
  }
}

extension BookmarkDurabilityConcurrencyTests {
  @Test func readersDoNotWaitWhileALargeCheckpointIsBuilt() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document((0..<20_000).map { "https://site\($0).test/" }), ready: false)
    let stop = DurabilityStopFlag()
    let longest = DurabilityLongestWait()
    let readerDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      while !stop.isSet {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = coordinator.desiredView(engine: "").revision
        longest.record(DispatchTime.now().uptimeNanoseconds - start)
      }
      readerDone.signal()
    }
    var submitTimes: [UInt64] = []
    for index in 0..<2 {
      let start = DispatchTime.now().uptimeNanoseconds
      try coordinator.submit(profile: "p", mutations: [rename("b\(index)", "Renamed \(index)")])
      submitTimes.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    stop.set()
    #expect(readerDone.wait(timeout: .now() + 10) == .success)
    let fastestSubmit = try #require(submitTimes.min())
    #expect(longest.value * 2 < fastestSubmit, "longest read \(longest.value / 1_000_000) ms, fastest submit \(fastestSubmit / 1_000_000) ms")
  }

  @Test func failureAfterRenameReportsSavedUnconfirmedAndRetryAfterRelaunchDedupes() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var operations = BookmarkPendingFileOperations.live
    let directorySyncs = DurabilityCounter()
    let liveSync = operations.syncDirectory
    operations.syncDirectory = { url in
      if directorySyncs.next() == 1 { throw BookmarkPendingStoreError.io("fsync journal directory", EIO) }
      try liveSync(url)
    }
    let coordinator = owner(directory, operations: operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let before = coordinator.desiredView(engine: "")
    let add = BookmarkMutation(method: "addBookmark", args: [["profileId": "p", "url": "https://r1.test", "title": "R1"]])
    #expect(throws: BookmarkPendingStoreError.savedUnconfirmed("fsync journal directory", EIO)) { try coordinator.submit(profile: "p", mutations: [add], requestID: "r1") }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(coordinator.recoveryNotice?.kind == .unavailableJournal)
    #expect(throws: BookmarkPendingStoreError.unavailable) { try coordinator.submit(profile: "p", mutations: [self.rename("b0", "Later")]) }
    let relaunched = owner(directory)
    let urls = { (owner: BookmarkCoordinator) in owner.desiredView(engine: "").document["nodes"]?.object?.values.compactMap { $0["url"]?.string }.filter { $0 == "https://r1.test" }.count ?? 0 }
    #expect(urls(relaunched) == 1)
    let retried = try relaunched.submit(profile: "p", mutations: [add], requestID: "r1")
    #expect(urls(relaunched) == 1)
    #expect(retried.results.count == 1)
  }
}

final class DurabilityStopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set() { lock.lock(); value = true; lock.unlock() }
}

final class DurabilityLongestWait: @unchecked Sendable {
  private let lock = NSLock()
  private var longest: UInt64 = 0
  var value: UInt64 { lock.lock(); defer { lock.unlock() }; return longest }
  func record(_ nanoseconds: UInt64) { lock.lock(); longest = max(longest, nanoseconds); lock.unlock() }
}

final class DurabilityCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
