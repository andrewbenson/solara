import Foundation
import SolaraEngine
import SolaraModel
@testable import SolaraStore
import Testing
import Synchronization

private final class ProfileRoutingSignal: Sendable {
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

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ProfileDataRoutingTests {
  @Test func barriersFailImmediatelyWhenTheirProducerEndsOrTheirWaiterIsCancelled() async {
    let start = ContinuousClock.now
    let completed = Task<Void, Never> {}
    #expect(!(await ProfileRoutingSignal().wait(producer: completed)))
    let failed = Task<Void, any Error> { throw CancellationError() }
    #expect(!(await ProfileRoutingSignal().wait(producer: failed)))
    let cancelled = Task<Void, any Error> { try await Task.sleep(for: .seconds(30)) }
    cancelled.cancel()
    #expect(!(await ProfileRoutingSignal().wait(producer: cancelled)))
    let producer = Task<Void, any Error> { try await Task.sleep(for: .seconds(30)) }
    defer { producer.cancel() }
    let signal = ProfileRoutingSignal()
    let waiter = Task { await signal.wait(producer: producer) }
    waiter.cancel()
    #expect(!(await waiter.value))
    #expect(start.duration(to: .now) < .seconds(30))
  }

  @Test func aCancelledProducerHeldOnAContinuationFailsItsBarrierImmediately() async throws {
    let entered = ProfileRoutingSignal()
    let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let producer = Task<Void, Never> {
      await withCheckedContinuation { held in
        continuation.withLock { $0 = held }
        entered.signal()
      }
    }
    defer { continuation.withLock { let held = $0; $0 = nil; held?.resume() } }
    try #require(await entered.wait(producer: producer))
    producer.cancel()
    let start = ContinuousClock.now
    #expect(!(await ProfileRoutingSignal().wait(producer: producer)))
    #expect(start.duration(to: .now) < .seconds(30))
    continuation.withLock { let held = $0; $0 = nil; held?.resume() }
    await producer.value
  }

  @Test func callbackArrivalFailsWhenCleanupExitsBeforeRouting() async throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["orphan"]
    let store = Store(state: state)
    let started = ProfileRoutingSignal()
    let service = ProfileDataCleanup(store: store, delete: { _, done in started.signal(); done([]) }, grace: { throw CancellationError() })
    service.start()
    defer { service.stop() }
    let draining = try #require(service.task)
    #expect(!(await started.wait(producer: draining)))
    #expect(store.state.orphanedProfileData == ["orphan"])
  }

  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func deletingOriginalProfileClearsChromiumDataThroughDefaultRoute() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    try store.dispatch(Command("createProfile", [["name": "Other"]]))
    try store.dispatch(Command("deleteProfile", [.string(Settings.defaultProfileID)]))
    #expect(store.state.orphanedProfileData == [""])
    var chromiumData = ["cookies", "history", "passwords"]
    var namedCalls: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      ChromiumProfileData.delete(engine, profilesDirectory: root, deleteDefault: { complete in
        chromiumData.removeAll()
        complete([])
      }, deleteNamed: { engine, complete in
        namedCalls.append(engine)
        complete(["data"])
      }, completion: done)
    }, grace: {})
    service.start()
    defer { service.stop() }
    let drain = try #require(service.task)
    await drain.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(chromiumData.isEmpty)
    #expect(namedCalls.isEmpty)
  }

  @Test(arguments: [false, true])
  func namedSuccessRequiresCallbackAndConfirmedAbsence(exists: Bool) throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var callback: ChromiumProfileData.Completion?
    var result: [String]?
    var checks = 0
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { engine, done in
      #expect(engine == "orphan")
      callback = done
    }, directoryExists: { path in
      checks += 1
      #expect(path == ChromiumProfileData.target("orphan", profilesDirectory: root))
      return exists
    }, completion: { result = $0 })
    #expect(result == nil)
    #expect(checks == 0)
    callback?([])
    #expect(checks == 1)
    #expect(result == (exists ? ["Chromium profile directory"] : []))
  }

  @Test(arguments: [false, true], [false, true])
  func nativeQueueRequiresSuccessfulCallbackAndAbsentDirectory(callbackSucceeds: Bool, directoryExists: Bool) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["orphan"]
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    var callbacks = 0
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      ChromiumProfileData.delete(engine, profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, complete in
        callbacks += 1
        complete(callbackSucceeds ? [] : ["data"])
      }, directoryExists: { _ in directoryExists }, completion: done)
    }, grace: {})
    service.start()
    defer { service.stop() }
    let drain = try #require(service.task)
    await drain.value
    #expect(callbacks == 1)
    #expect(store.state.orphanedProfileData == (callbackSucceeds && !directoryExists ? [] : ["orphan"]))
  }

  @Test func callbackFailureNeverAcknowledgesEvenWhenDirectoryIsAbsent() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      done(["data"])
    }, directoryExists: { _ in Issue.record("file check after callback failure"); return false }, completion: { result = $0 })
    #expect(result == ["data"])
  }

  @Test(arguments: ["Default", "Profile orphan", "part..name", "é", "e\u{301}"])
  func safeNamedIDsKeepTheirLiteralDirectoryName(id: String) throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = root.resolvingSymlinksInPath().appendingPathComponent("Profile \(id)", isDirectory: true)
    #expect(ChromiumProfileData.target(id, profilesDirectory: root)?.path == expected.path)
    var named: String?
    var result: [String]?
    ChromiumProfileData.delete(id, profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { engine, done in
      named = engine
      done([])
    }, completion: { result = $0 })
    #expect(named?.jsEquals(id) == true)
    #expect(result == [])
  }

  @Test(arguments: [("FOO", "foo"), ("foo", "FOO")], [false, true])
  func filesystemAliasesKeepLiveDataQueuedAcrossBothSpellings(ids: (String, String), diskUsesLiveSpelling: Bool) async throws {
    let (liveID, queuedID) = ids
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = root.appendingPathComponent("Profile \(diskUsesLiveSpelling ? liveID : queuedID)", isDirectory: true)
    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    let sentinel = disk.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    let profile = Profile(id: "live", name: "Live", color: "blue", icon: nil, createdAt: 0, dataId: liveID)
    state.profiles[profile.id] = profile
    state.profileOrder.append(profile.id)
    state.orphanedProfileData = [queuedID]
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    var calls = 0
    var attempts = 0
    let aliases = FileManager.default.fileExists(atPath: root.appendingPathComponent("Profile \(liveID)").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("Profile \(queuedID)").path)
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      attempts += 1
      let target = root.appendingPathComponent("Profile \(engine)", isDirectory: true)
      let live = store.state.profiles.values.map { profile in
        let dataID = profile.dataId ?? profile.id
        return root.appendingPathComponent(dataID == Settings.defaultProfileID ? "Default" : "Profile \(dataID)", isDirectory: true)
      }
      guard ChromiumProfileData.deletionAllowed(targets: [target], liveDirectories: live, resolve: { path in
        if aliases { return try ChromiumProfileData.directoryIdentity(path) }
        return path.lastPathComponent == "Default" ? nil : ChromiumProfileData.DirectoryIdentity(device: 7, inode: 9)
      }) else { return done(["live profile filesystem identity"]) }
      calls += 1
      try? FileManager.default.removeItem(at: disk)
      done([])
    }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    service.retry()
    await service.task?.value
    #expect(attempts == 1)
    #expect(calls == 0)
    #expect(store.state.profiles[profile.id] == profile)
    #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    #expect(store.state.orphanedProfileData == [queuedID])
    let restored = Store(state: store.state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    var relaunchedAttempts = 0
    let relaunched = ProfileDataCleanup(store: restored, delete: { engine, done in
      relaunchedAttempts += 1
      let target = root.appendingPathComponent("Profile \(engine)")
      let live = root.appendingPathComponent("Profile \(liveID)")
      let allowed = ChromiumProfileData.deletionAllowed(targets: [target], liveDirectories: [live], resolve: { path in
        if aliases { return try ChromiumProfileData.directoryIdentity(path) }
        return ChromiumProfileData.DirectoryIdentity(device: 7, inode: 9)
      })
      done(allowed ? [] : ["live profile filesystem identity"])
    }, grace: {})
    relaunched.start()
    await relaunched.task?.value
    relaunched.stop()
    #expect(relaunchedAttempts == 1)
    #expect(restored.state.orphanedProfileData == [queuedID])
    #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    try store.transact { session in session.update {
      $0.profiles[profile.id] = nil
      $0.profileOrder.removeAll { $0 == profile.id }
    } }
    service.retry()
    await service.task?.value
    #expect(calls == 1)
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func directoryIdentityResolvesRealAliasesAndKeepsDistinctDirectoriesSeparate() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Profile FOO", isDirectory: true)
    let separate = root.appendingPathComponent("separate", isDirectory: true)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: separate, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: live)
    let identity = try #require(try ChromiumProfileData.directoryIdentity(live))
    #expect(try ChromiumProfileData.directoryIdentity(link) == identity)
    #expect(try ChromiumProfileData.directoryIdentity(separate) != identity)
    #expect(try ChromiumProfileData.directoryIdentity(root.appendingPathComponent("absent")) == nil)
    #expect(!ChromiumProfileData.deletionAllowed(targets: [link], liveDirectories: [live]))
    #expect(ChromiumProfileData.deletionAllowed(targets: [separate], liveDirectories: [live]))
    let lower = root.appendingPathComponent("Profile foo", isDirectory: true)
    if FileManager.default.fileExists(atPath: lower.path) {
      #expect(try ChromiumProfileData.directoryIdentity(lower) == identity)
      #expect(!ChromiumProfileData.deletionAllowed(targets: [lower], liveDirectories: [live]))
    }
    #expect(!ChromiumProfileData.deletionAllowed(targets: [live], liveDirectories: [separate], resolve: { _ in throw CocoaError(.fileReadNoPermission) }))
  }

  @Test func scheduledNamedDeletionRetainsQueueEvenWhenDirectoryIsAlreadyAbsent() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["orphan"]
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      ChromiumProfileData.delete(engine, profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, complete in
        complete(["Chromium deletion pending restart"])
      }, directoryExists: { _ in Issue.record("absence check after scheduling-only callback"); return false }, completion: done)
    }, grace: {})
    service.start()
    defer { service.stop() }
    let drain = try #require(service.task)
    await drain.value
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Profile orphan").path))
    #expect(store.state.orphanedProfileData == ["orphan"])
  }

  @Test func invalidPathsNeverReachDeletionOrTouchOutsideSentinel() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("Chromium", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("Profile link"), withDestinationURL: outside)
    for id in ["../x", "../outside", "x/../../outside", "link", outside.path, "a\\b", ".", "..", "bad\0id"] {
      #expect(ChromiumProfileData.target(id, profilesDirectory: profiles) == nil)
      var result: [String]?
      ChromiumProfileData.delete(id, profilesDirectory: profiles, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, _ in
        Issue.record("unsafe named route")
      }, completion: { result = $0 })
      #expect(result == ["refused profile path"])
      #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
    }
  }

  @Test func symlinkInstalledAfterSchedulingRefusesAcknowledgement() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try directory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    var callback: ChromiumProfileData.Completion?
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in callback = done }, completion: { result = $0 })
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Profile orphan"), withDestinationURL: outside)
    callback?([])
    #expect(result == ["refused profile path"])
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
  }

  @Test func rootSymlinksAreRefusedAndOutsideDataSurvives() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try directory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    let link = root.appendingPathComponent("Chromium", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(ChromiumProfileData.target("orphan", profilesDirectory: link) == nil)
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: link, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, _ in
      Issue.record("unsafe named route")
    }, completion: { result = $0 })
    #expect(result == ["refused profile path"])
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
  }

  @Test func changedRootCannotAcknowledgeAgainstAnotherAbsentDirectory() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("Chromium", isDirectory: true)
    let original = root.appendingPathComponent("original", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let target = profiles.appendingPathComponent("Profile orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let sentinel = target.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    var callback: ChromiumProfileData.Completion?
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: profiles, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      callback = done
    }, completion: { result = $0 })
    try FileManager.default.moveItem(at: profiles, to: original)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    callback?([])
    #expect(result == ["refused profile path"])
    #expect(try String(contentsOf: original.appendingPathComponent("Profile orphan/sentinel"), encoding: .utf8) == "untouched")
  }

  @Test func rootSymlinkInstalledDuringCallbackCannotRedirectAbsenceCheck() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("Chromium", isDirectory: true)
    let original = root.appendingPathComponent("original", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles.appendingPathComponent("Profile orphan", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("untouched".utf8).write(to: profiles.appendingPathComponent("Profile orphan/sentinel"))
    var callback: ChromiumProfileData.Completion?
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: profiles, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      callback = done
    }, directoryExists: { _ in Issue.record("absence check after root changed"); return false }, completion: { result = $0 })
    try FileManager.default.moveItem(at: profiles, to: original)
    try FileManager.default.createSymbolicLink(at: profiles, withDestinationURL: outside)
    callback?([])
    #expect(result == ["refused profile path"])
    #expect(try String(contentsOf: original.appendingPathComponent("Profile orphan/sentinel"), encoding: .utf8) == "untouched")
  }

  @Test func capturedTargetIsTheOnlyAbsenceCheck() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = try #require(ChromiumProfileData.target("orphan", profilesDirectory: root))
    var callback: ChromiumProfileData.Completion?
    var checked: URL?
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      callback = done
    }, directoryExists: { path in checked = path; return false }, completion: { result = $0 })
    callback?([])
    #expect(checked == expected)
    #expect(result == [])
  }

  @Test func namedDirectoryMustReallyBeGoneAfterCallback() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Profile orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    var callback: ChromiumProfileData.Completion?
    var result: [String]?
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      callback = done
    }, completion: { result = $0 })
    callback?([])
    #expect(result == ["Chromium profile directory"])
    try FileManager.default.removeItem(at: target)
    result = nil
    ChromiumProfileData.delete("orphan", profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, done in
      done([])
    }, completion: { result = $0 })
    #expect(result == [])
  }

  @Test func fullServiceRetainsNamedDeletionWhenSymlinkAppearsDuringCallback() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try directory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.orphanedProfileData = ["orphan"]
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)))
    var started = ProfileRoutingSignal()
    var callback: ChromiumProfileData.Completion?
    let service = ProfileDataCleanup(store: store, delete: { engine, done in
      ChromiumProfileData.delete(engine, profilesDirectory: root, deleteDefault: { _ in Issue.record("default route") }, deleteNamed: { _, complete in
        callback = complete
        started.signal()
      }, completion: done)
    }, grace: {})
    service.start()
    defer { service.stop() }
    let drain = try #require(service.task)
    let reached = await started.wait(producer: drain)
    try #require(reached)
    let complete = try #require(callback)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Profile orphan"), withDestinationURL: outside)
    complete([])
    await drain.value
    #expect(store.state.orphanedProfileData == ["orphan"])
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
    try FileManager.default.removeItem(at: root.appendingPathComponent("Profile orphan"))
    started = ProfileRoutingSignal()
    service.retry()
    let retrying = try #require(service.task)
    let retried = await started.wait(producer: retrying)
    try #require(retried)
    let completeRetry = try #require(callback)
    completeRetry([])
    await retrying.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
  }
}
