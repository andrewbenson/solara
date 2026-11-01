import Foundation
import SolaraModel
@testable import SolaraStore
import Testing
import SolaraPersistence
import Synchronization

final class ProfileCleanupSignal: Sendable {
  private struct State {
    var result: Bool?
    var continuation: CheckedContinuation<Bool, Never>?
  }

  private let state = Mutex(State())

  func signal() { resolve(true) }

  func finish() { resolve(false) }

  func wait<Success: Sendable, Failure: Error>(producer: Task<Success, Failure>) async -> Bool {
    let completion = Task<Void, Never> {
      _ = await producer.result
      self.resolve(false)
    }
    let cancellation = Task<Void, Never> {
      while !Task.isCancelled {
        if producer.isCancelled { self.resolve(false); return }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      }
    }
    defer { completion.cancel(); cancellation.cancel() }
    return await wait()
  }

  func wait() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let result = state.withLock { state -> Bool? in
          if let result = state.result { return result }
          precondition(state.continuation == nil)
          state.continuation = continuation
          return nil
        }
        if let result {
          continuation.resume(returning: result)
        } else {
          DispatchQueue.global().asyncAfter(deadline: .now() + 30) { self.resolve(false) }
        }
      }
    } onCancel: {
      self.resolve(false)
    }
  }

  private func resolve(_ result: Bool) {
    let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard state.result == nil else { return nil }
      state.result = result
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }
}

private final class ProfileCleanupThreadGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var released = false

  func wait() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(30)
    while !released {
      if !condition.wait(until: deadline) { return released }
    }
    return true
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}


@MainActor
private final class ProfileCleanupGate {
  private var waiting: [ProfileCleanupSignal] = []
  private var arrival = ProfileCleanupSignal()
  var count: Int { waiting.count }

  func wait() async {
    let release = ProfileCleanupSignal()
    waiting.append(release)
    let entered = arrival
    arrival = ProfileCleanupSignal()
    entered.signal()
    let released = await release.wait()
    waiting.removeAll { $0 === release }
    if !released, !Task.isCancelled { Issue.record("Profile cleanup gate ended before release") }
  }

  func entered(producer: Task<Void, Never>) async -> Bool {
    if !waiting.isEmpty { return true }
    return await arrival.wait(producer: producer)
  }

  func release() { if !waiting.isEmpty { waiting.removeFirst().signal() } }

  func cancel() {
    for release in waiting { release.finish() }
    waiting.removeAll()
    arrival.finish()
  }
}

private func cleanupStore(_ state: BrowserState = BrowserState(settings: Settings.hydrated(from: nil))) -> Store {
  Store(state: state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)), checksInvariants: true, clock: { 1_000 })
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ProfileDataCleanupTests {
  @Test func barriersFailImmediatelyWhenTheirProducerEndsOrTheirWaiterIsCancelled() async {
    let start = ContinuousClock.now
    let completed = Task<Void, Never> {}
    #expect(!(await ProfileCleanupSignal().wait(producer: completed)))
    let failed = Task<Void, any Error> { throw CancellationError() }
    #expect(!(await ProfileCleanupSignal().wait(producer: failed)))
    let cancelled = Task<Void, any Error> { try await Task.sleep(for: .seconds(30)) }
    cancelled.cancel()
    #expect(!(await ProfileCleanupSignal().wait(producer: cancelled)))
    let producer = Task<Void, any Error> { try await Task.sleep(for: .seconds(30)) }
    defer { producer.cancel() }
    let signal = ProfileCleanupSignal()
    let waiter = Task { await signal.wait(producer: producer) }
    waiter.cancel()
    #expect(!(await waiter.value))
    let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let entered = ProfileCleanupSignal()
    let heldProducer = Task<Void, Never> {
      await withCheckedContinuation { continuation in
        held.withLock { $0 = continuation }
        entered.signal()
      }
    }
    defer { held.withLock { $0?.resume(); $0 = nil } }
    #expect(await entered.wait(producer: heldProducer))
    heldProducer.cancel()
    #expect(!(await ProfileCleanupSignal().wait(producer: heldProducer)))
    held.withLock { $0?.resume(); $0 = nil }
    await heldProducer.value
    #expect(start.duration(to: .now) < .seconds(30))
  }

  @Test func graceArrivalFailsWhenDrainEndsAndGraceWaitResumesOnCancellation() async {
    let start = ContinuousClock.now
    let gate = ProfileCleanupGate()
    let completed = Task<Void, Never> {}
    #expect(!(await gate.entered(producer: completed)))
    let waiting = Task { await gate.wait() }
    waiting.cancel()
    await waiting.value
    #expect(gate.count == 0)
    #expect(start.duration(to: .now) < .seconds(30))
  }

  @Test func graceArrivalFailsWhenCleanupExitsBeforeGrace() async throws {
    let gate = ProfileCleanupGate()
    defer { gate.cancel() }
    let service = ProfileDataCleanup(store: cleanupStore(), delete: { _, _ in Issue.record("unexpected deletion") }, grace: { await gate.wait() })
    service.start()
    defer { service.stop() }
    let draining = try #require(service.task)
    #expect(!(await gate.entered(producer: draining)))
  }

  @Test(arguments: [false, true])
  func existingDefaultAndNamedProfilesAreNeverDeleted(named: Bool) async throws {
    let store = cleanupStore()
    let added = try store.dispatch(Command("createProfile", [["name": "Other"]])).result!.string!
    let engine = named ? added : ""
    try store.transact { $0.update { $0.orphanedProfileData = [engine] } }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(deleted.isEmpty)
  }

  @Test(arguments: [false, true])
  func profileRecreatedOffMainDuringGraceIsNeverDeleted(named: Bool) async throws {
    let store = cleanupStore()
    let added = try store.dispatch(Command("createProfile", [["name": "Other"]])).result!.string!
    let id = named ? added : Settings.defaultProfileID
    let removed = store.state.profiles[id]!
    try store.dispatch(Command("deleteProfile", [.string(id)]))
    #expect(store.state.orphanedProfileData == [named ? added : ""])
    let grace = ProfileCleanupGate()
    defer { grace.cancel() }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: { await grace.wait() })
    service.start()
    let draining = try #require(service.task)
    defer { service.stop() }
    try #require(await grace.entered(producer: try #require(service.task)))
    try await Task.detached {
      try store.transact { session in
        session.update {
          $0.profiles[id] = removed
          $0.profileOrder.append(id)
        }
      }
    }.value
    grace.release()
    await draining.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(deleted.isEmpty)
    #expect(store.state.profiles[id] == removed)
  }

  @Test func startupRequiresWorkspaceApplicationAndEngineThenStopsOnOwnershipLoss() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["kept"]
    let store = cleanupStore(state)
    let grace = ProfileCleanupGate()
    defer { grace.cancel() }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: { await grace.wait() })
    service.updateOwnership(false, applicationReady: true, engineReady: true)
    service.updateOwnership(true, applicationReady: false, engineReady: true)
    service.updateOwnership(true, applicationReady: true, engineReady: false)
    #expect(service.task == nil)
    #expect(grace.count == 0)
    service.updateOwnership(true, applicationReady: true, engineReady: true)
    try #require(await grace.entered(producer: try #require(service.task)))
    service.updateOwnership(false, applicationReady: true, engineReady: true)
    #expect(service.isStopped)
    grace.release()
    service.updateOwnership(true, applicationReady: true, engineReady: true)
    await service.task?.value
    #expect(deleted.isEmpty)
    #expect(store.state.orphanedProfileData == ["kept"])
  }

  @Test func ownershipLossWhileWaitingForEngineIsTerminal() {
    let service = ProfileDataCleanup(store: cleanupStore(), delete: { _, done in done([]) }, grace: {})
    service.updateOwnership(true, applicationReady: true, engineReady: false)
    service.updateOwnership(false, applicationReady: true, engineReady: false)
    #expect(service.isStopped)
  }

  @Test func persistedWorkWaitsForStartAndProcessesSerially() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["old-a", "old-b"]
    let store = cleanupStore(state)
    let grace = ProfileCleanupGate()
    defer { grace.cancel() }
    let deletion = ProfileCleanupGate()
    defer { deletion.cancel() }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      deleted.append(engine)
      Task { @MainActor in await deletion.wait(); done([]) }
    }, grace: { await grace.wait() })
    #expect(deleted.isEmpty)
    service.start()
    service.start()
    defer { service.stop() }
    try #require(await grace.entered(producer: try #require(service.task)))
    #expect(deleted.isEmpty)
    grace.release()
    try #require(await deletion.entered(producer: try #require(service.task)))
    #expect(deleted == ["old-a"])
    #expect(grace.count == 0)
    deletion.release()
    try #require(await grace.entered(producer: try #require(service.task)))
    #expect(store.state.orphanedProfileData == ["old-b"])
    grace.release()
    try #require(await deletion.entered(producer: try #require(service.task)))
    deletion.release()
    await service.task?.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(deleted == ["old-a", "old-b"])
  }

  @Test func removedCandidateIsNotDeleted() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["withdrawn"]
    let store = cleanupStore(state)
    let grace = ProfileCleanupGate()
    defer { grace.cancel() }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: { await grace.wait() })
    service.start()
    defer { service.stop() }
    try #require(await grace.entered(producer: try #require(service.task)))
    try store.dispatch(Command("profileDataDeleted", ["withdrawn"]))
    grace.release()
    await service.task?.value
    #expect(deleted.isEmpty)
  }

  @Test func partialFailureStaysQueuedWithoutBlockingOtherWork() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var regular = state.profiles["default"]!
    regular.dataId = "active-data"
    state.profiles["default"] = regular
    state.orphanedProfileData = ["", "partial", "ok", "incognito:w@p"]
    let store = cleanupStore(state)
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      deleted.append(engine)
      done(engine == "ok" ? [] : ["WebKit data"])
    }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(!store.state.orphanedProfileData.contains("ok"))
    try store.transact { $0.update { $0.orphanedProfileData.append("another") } }
    await service.task?.value
    #expect(deleted.contains("another"))
    #expect(deleted == ["", "partial", "ok", "another"])
    #expect(store.state.orphanedProfileData == ["", "partial", "another"])
  }

  @Test func unknownWebKitLayoutRemainsQueuedWithSessionBackoff() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["unknown-layout"]
    let store = cleanupStore(state)
    var attempts = 0
    var failures: [[String]] = []
    let service = ProfileDataCleanup(store: store, delete: { _, done in
      attempts += 1
      done(["WebKit data"])
    }, grace: {}, trouble: { _, remaining in failures.append(remaining) })
    service.start()
    defer { service.stop() }
    await service.task?.value
    try store.transact { $0.update { $0.orphanedProfileData.append("incognito:ignored") } }
    await service.task?.value
    #expect(attempts == 1)
    #expect(failures == [["WebKit data"]])
    #expect(store.state.orphanedProfileData == ["unknown-layout"])
  }

  @Test func safeModeNeverDeletesPersistedWork() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["kept"]
    var config = StoreConfig()
    config.safeMode = true
    let store = Store(state: state, config: config)
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: {})
    service.start()
    await service.task?.value
    service.stop()
    #expect(deleted.isEmpty)
    #expect(store.state.orphanedProfileData == ["kept"])
  }

  @Test func stopDuringGraceIsTerminalAndUnsubscribes() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["kept"]
    let store = cleanupStore(state)
    let grace = ProfileCleanupGate()
    defer { grace.cancel() }
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: { await grace.wait() })
    service.start()
    try #require(await grace.entered(producer: try #require(service.task)))
    service.stop()
    service.start()
    grace.release()
    try store.transact { $0.update { $0.orphanedProfileData.append("later") } }
    await service.task?.value
    #expect(deleted.isEmpty)
    #expect(grace.count == 0)
    #expect(store.state.orphanedProfileData == ["kept", "later"])
  }

  @Test(arguments: [false, true])
  func removalAndReentryOffMainCannotBeAcknowledgedByTheOldCallback(named: Bool) async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var current = state.profiles[Settings.defaultProfileID]!
    current.dataId = "active-data"
    state.profiles[current.id] = current
    let engine = named ? "retired" : ""
    state.orphanedProfileData = [engine]
    let store = cleanupStore(state)
    let deletion = ProfileCleanupGate()
    defer { deletion.cancel() }
    var attempts = 0
    let service = ProfileDataCleanup(store: store, delete: { _, done in
      attempts += 1
      if attempts == 1 { Task { @MainActor in await deletion.wait(); done([]) } }
      else { done(["retry later"]) }
    }, grace: {})
    service.start()
    let draining = try #require(service.task)
    defer { service.stop() }
    try #require(await deletion.entered(producer: try #require(service.task)))
    try await Task.detached {
      try store.dispatch(Command("profileDataDeleted", [.string(engine)]))
      try store.transact { $0.update { $0.orphanedProfileData = [engine] } }
    }.value
    deletion.release()
    await draining.value
    #expect(attempts == 2)
    #expect(store.state.orphanedProfileData == [engine])
  }

  @Test func rawCaseAndUnicodeAliasesEachReceiveTheirOwnCleanup() async throws {
    let engines = ["orphan", "ORPHAN", "café", "cafe\u{301}"]
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = engines
    let store = cleanupStore(state)
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(deleted.map(JSKey.init) == engines.map(JSKey.init))
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func invalidIDsAreDroppedBeforeCallingTheEngine() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["../x", "/absolute", ".", "..", "x/y", "x\\y", "x\0y", "incognito:w@p", "safe"]
    let store = cleanupStore(state)
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(deleted == ["safe"])
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func stopBeforeQuitDoesNotWaitForHeldIngressAndLateAcknowledgementStaysQueued() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["kept"]
    let store = cleanupStore(state)
    let deletionStarted = ProfileCleanupSignal()
    var completion: ProfileDataCleanup.Completion?
    let service = ProfileDataCleanup(store: store, delete: { _, done in
      completion = done
      deletionStarted.signal()
    }, grace: {})
    service.start()
    let draining = try #require(service.task)
    try #require(await deletionStarted.wait(producer: draining))
    let holderEntered = ProfileCleanupSignal()
    let holderFinished = ProfileCleanupSignal()
    let release = ProfileCleanupThreadGate()
    defer { release.release(); service.stop() }
    Thread.detachNewThread {
      defer { holderEntered.finish(); holderFinished.finish() }
      store.sequence {
        holderEntered.signal()
        #expect(release.wait())
      }
      holderFinished.signal()
    }
    try #require(await holderEntered.wait())
    let quitFinished = ProfileCleanupSignal()
    let quit = Mutex<(result: FlushResult?, elapsed: Duration?)>((nil, nil))
    Thread.detachNewThread {
      defer { quitFinished.finish() }
      let start = ContinuousClock.now
      service.stop()
      let result = QuitFlush.run(store: store, writer: nil, barrierTimeout: 0.1, writerTimeout: 0.1)
      let elapsed = start.duration(to: .now)
      quit.withLock { $0 = (result, elapsed) }
      quitFinished.signal()
    }
    try #require(await quitFinished.wait())
    let result = quit.withLock { $0 }
    #expect(result.result == .timedOut)
    #expect(try #require(result.elapsed) < .seconds(5))
    #expect(service.isStopped)
    release.release()
    try #require(await holderFinished.wait())
    let complete = try #require(completion)
    complete([])
    await draining.value
    #expect(store.state.orphanedProfileData == ["kept"])
    let nextLaunch = cleanupStore(store.state)
    var resumed: [String] = []
    let nextCleanup = ProfileDataCleanup(store: nextLaunch, delete: { engine, done in resumed.append(engine); done([]) }, grace: {})
    nextCleanup.start()
    defer { nextCleanup.stop() }
    await nextCleanup.task?.value
    #expect(resumed == ["kept"])
    #expect(nextLaunch.state.orphanedProfileData.isEmpty)
  }
}
