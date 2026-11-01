import Foundation
import SolaraModel
@testable import SolaraStore
import Testing
import Synchronization

@MainActor
private final class PrivateSessionEndLog {
  var ended: [PrivateSessionEnd] = []
}

private final class PrivateEffectsSignal: Sendable {
  private struct State {
    var result: Bool?
    var continuation: CheckedContinuation<Bool, Never>?
  }
  private let state = Mutex(State())
  func wait() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiting in
        let result = state.withLock { state -> Bool? in
          if let result = state.result { return result }
          state.continuation = waiting
          return nil
        }
        if let result { waiting.resume(returning: result) }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + 60) { self.finish(false) } }
      }
    } onCancel: { self.finish(false) }
  }
  func finish(_ arrived: Bool) {
    let waiting = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard state.result == nil else { return nil }
      state.result = arrived
      let result = state.continuation
      state.continuation = nil
      return result
    }
    waiting?.resume(returning: arrived)
  }
}

private func privateEffectsTurn() async {
  let signal = PrivateEffectsSignal()
  DispatchQueue.main.async { signal.finish(true) }
  #expect(await signal.wait())
}

private func privateEffectsStore(clock: @escaping @Sendable () -> Double = { 1_000 }) -> Store {
  var config = StoreConfig()
  config.nativePrivateSessionEffects = true
  return Store(config: config, clock: clock)
}

private func privateEffectsWindow(_ store: Store, profile: String = "default") throws -> String {
  var options = CreateWindowOptions()
  options.incognito = true
  options.profileId = profile
  var id = ""
  try store.transact { id = $0.createWindow(options) }
  return id
}

@Suite @MainActor
struct PrivateSessionEffectsTests {
  @Test(arguments: [false, true])
  func callbacksFollowCommittedEndOrderWhenConfirmationArrivesInReverse(separateCommits: Bool) async throws {
    let store = privateEffectsStore()
    var profile = ""
    try store.transact { profile = try $0.createProfile(name: "Other", color: nil, icon: nil, shareWith: nil) }
    let a = try privateEffectsWindow(store)
    let b = try privateEffectsWindow(store, profile: profile)
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    let commits: [Commit]
    if separateCommits {
      commits = [
        try store.dispatch(Command("closeWindow", [.string(a)])),
        try store.dispatch(Command("closeWindow", [.string(b)])),
      ]
    } else {
      commits = [try store.dispatch([
        Command("closeWindow", [.string(a)]), Command("closeWindow", [.string(b)]),
      ])]
    }
    let committed = commits.flatMap(\.effects).compactMap { effect -> String? in
      if case .endPrivateSession(let session) = effect { return session }
      return nil
    }
    try #require(committed.count == 2)
    let windows = [JSKey(""): a, JSKey(profile): b]
    await privateEffectsTurn()
    effects.confirmWindowClosed(try #require(windows[JSKey(committed[1])]))
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
    effects.confirmWindowClosed(try #require(windows[JSKey(committed[0])]))
    await privateEffectsTurn()
    #expect(log.ended.map { JSKey($0.session) } == committed.map(JSKey.init))
  }

  @Test func reopenBeforeQueuedCloseDeliveryPreservesGenerationAndDoesNotBlockOtherEnds() async throws {
    let store = privateEffectsStore()
    var profile = ""
    try store.transact { profile = try $0.createProfile(name: "Other", color: nil, icon: nil, shareWith: nil) }
    let a = try privateEffectsWindow(store)
    let b = try privateEffectsWindow(store, profile: profile)
    let log = PrivateSessionEndLog()
    var begun: [(String, String)] = []
    let effects = PrivateSessionEffects(store: store, begin: { begun.append(($0, $1)) }) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    let originalGeneration = try #require(begun.first { $0.0.isEmpty }?.1)
    try store.dispatch(Command("closeWindow", [.string(a)]))
    let replacement = try privateEffectsWindow(store)
    try store.dispatch(Command("closeWindow", [.string(b)]))
    effects.confirmWindowClosed(a)
    effects.confirmWindowClosed(b)
    await privateEffectsTurn()
    #expect(log.ended.map { JSKey($0.session) } == [JSKey(profile)])
    #expect(begun.filter { $0.0.isEmpty }.count == 1)
    try store.dispatch(Command("closeWindow", [.string(replacement)]))
    await privateEffectsTurn()
    #expect(log.ended.count == 1)
    effects.confirmWindowClosed(replacement)
    await privateEffectsTurn()
    try #require(log.ended.count == 2)
    #expect(log.ended[1].session.isEmpty)
    #expect(log.ended[1].generation == originalGeneration)
  }

  @Test func endEffectsKeepByteExactSessionIdentitiesAndOrder() throws {
    let store = privateEffectsStore()
    let commit = try store.transact {
      $0.emit(.endPrivateSession(session: "caf\u{e9}"))
      $0.emit(.endPrivateSession(session: "cafe\u{301}"))
      $0.emit(.endPrivateSession(session: "caf\u{e9}"))
    }
    let sessions = commit.effects.compactMap { effect -> String? in
      if case .endPrivateSession(let session) = effect { return session }
      return nil
    }
    #expect(sessions.map(JSKey.init) == [JSKey("caf\u{e9}"), JSKey("cafe\u{301}")])
  }

  @Test func committedEndWaitsForNativeConfirmationAndRunsOnce() async throws {
    let store = privateEffectsStore()
    let window = try privateEffectsWindow(store)
    let profile = try #require(store.state.windows[window]?.profileId)
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    try store.dispatch(Command("closeWindow", [.string(window)]))
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
    effects.confirmWindowClosed(window)
    effects.confirmWindowClosed(window)
    await privateEffectsTurn()
    #expect(log.ended.count == 1)
    #expect(log.ended.first?.session == "")
    #expect(log.ended.first?.profiles == [profile])
  }

  @Test func sharedOwnerSurvivesOriginalProfileDeletion() async throws {
    let store = privateEffectsStore()
    var original = ""
    var alias = ""
    try store.transact {
      original = try $0.createProfile(name: "A", color: nil, icon: nil, shareWith: nil)
      alias = try $0.createProfile(name: "B", color: nil, icon: nil, shareWith: original)
    }
    let a = try privateEffectsWindow(store, profile: original)
    let b = try privateEffectsWindow(store, profile: alias)
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    let deleted = try store.dispatch(Command("deleteProfile", [.string(original)]))
    #expect(!deleted.effects.contains(.endPrivateSession(session: original)))
    effects.confirmWindowClosed(a)
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
    try store.dispatch(Command("closeWindow", [.string(b)]))
    effects.confirmWindowClosed(b)
    await privateEffectsTurn()
    #expect(log.ended.map(\.session) == [original])
  }

  @Test(arguments: [(30_000.0, true), (30_001.0, false)])
  func aClosedPrivateWindowCanBeRestoredForThirtySecondsAndNoLonger(elapsed: Double, restorable: Bool) throws {
    let now = Mutex(1_000.0)
    let store = privateEffectsStore(clock: { now.withLock { $0 } })
    let a = try privateEffectsWindow(store)
    let b = try privateEffectsWindow(store)
    let before = store.state
    try store.dispatch(Command("closeWindow", [.string(a)]))
    try store.dispatch(Command("closeWindow", [.string(b)]))
    now.withLock { $0 += elapsed }
    try store.transact {
      let window = before.windows[b]!
      let tabs = window.tabIds.compactMap { before.tabs[$0] }
      #expect(($0.restoreClosingWindow(window, tabs, [], [], chromeWindow: "restored", liveTabIds: window.tabIds) != nil) == restorable)
    }
  }

  @Test func canceledCloseAndAnotherPendingCloseKeepSessionAlive() async throws {
    let store = privateEffectsStore()
    let a = try privateEffectsWindow(store)
    let b = try privateEffectsWindow(store)
    let before = store.state
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    try store.dispatch(Command("closeWindow", [.string(a)]))
    try store.dispatch(Command("closeWindow", [.string(b)]))
    effects.confirmWindowClosed(a)
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
    try store.transact {
      let window = before.windows[b]!
      let tabs = window.tabIds.compactMap { before.tabs[$0] }
      #expect($0.restoreClosingWindow(window, tabs, [], [], chromeWindow: "restored", liveTabIds: window.tabIds) != nil)
    }
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
    let restored = try #require(store.state.windows.values.first)
    try store.dispatch(Command("closeWindow", [.string(restored.id)]))
    effects.confirmWindowClosed(restored.id)
    await privateEffectsTurn()
    #expect(log.ended.count == 1)
  }

  @Test func confirmationBeforeRemovalAndReopenUseDifferentGenerations() async throws {
    let store = privateEffectsStore()
    let a = try privateEffectsWindow(store)
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    defer { effects.stop() }
    effects.confirmWindowClosed(a)
    try store.dispatch(Command("closeWindow", [.string(a)]))
    await privateEffectsTurn()
    let b = try privateEffectsWindow(store)
    try store.dispatch(Command("closeWindow", [.string(b)]))
    effects.confirmWindowClosed(a)
    await privateEffectsTurn()
    #expect(log.ended.count == 1)
    effects.confirmWindowClosed(b)
    await privateEffectsTurn()
    try #require(log.ended.count == 2)
    #expect(log.ended[0].generation != log.ended[1].generation)
  }

  #if DEBUG
    @Test func subscriptionDoesNotReplayCommitsOlderThanItsBaseline() async throws {
      let store = privateEffectsStore()
      let window = try privateEffectsWindow(store)
      try #require(store.pauseDeliveryForTesting())
      defer { store.resumeDeliveryForTesting() }
      try store.dispatch(Command("updateSettings", [["showBookmarksBar": true]]))
      try store.dispatch(Command("closeWindow", [.string(window)]))
      let held = store.deliveryCursor()
      try #require(held.delivered < held.committed)
      let log = PrivateSessionEndLog()
      let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
      effects.start()
      defer { effects.stop() }
      store.resumeDeliveryForTesting()
      let delivered = store.deliveryCursor()
      try #require(delivered.delivered == delivered.committed)
      await privateEffectsTurn()
      let replacement = try privateEffectsWindow(store)
      try store.dispatch(Command("closeWindow", [.string(replacement)]))
      effects.confirmWindowClosed(replacement)
      await privateEffectsTurn()
      #expect(log.ended.count == 1)
    }

    @Test func nativeConfirmationCanArriveBeforeCommittedOpenDelivery() async throws {
      let store = privateEffectsStore()
      let log = PrivateSessionEndLog()
      let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
      effects.start()
      defer { effects.stop() }
      try #require(store.pauseDeliveryForTesting())
      defer { store.resumeDeliveryForTesting() }
      let window = try privateEffectsWindow(store)
      try store.dispatch(Command("closeWindow", [.string(window)]))
      let held = store.deliveryCursor()
      try #require(held.delivered < held.committed)
      effects.confirmWindowClosed(window)
      await privateEffectsTurn()
      #expect(log.ended.isEmpty)
      store.resumeDeliveryForTesting()
      await privateEffectsTurn()
      #expect(log.ended.count == 1)
    }
  #endif

  @Test func stopFencesAlreadyQueuedCommittedEffects() async throws {
    let store = privateEffectsStore()
    let a = try privateEffectsWindow(store)
    let log = PrivateSessionEndLog()
    let effects = PrivateSessionEffects(store: store) { log.ended.append($0) }
    effects.start()
    try store.dispatch(Command("closeWindow", [.string(a)]))
    effects.confirmWindowClosed(a)
    effects.stop()
    await privateEffectsTurn()
    #expect(log.ended.isEmpty)
  }
}
