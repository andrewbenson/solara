import Foundation
import SolaraModel
@testable import SolaraStore
@testable import SolaraSync
import Testing

private final class HistoryLifetimeHost: HistoryHost {
  var ready = true
  var entries: [JSONValue]? = []
  var onAdd: (() async throws -> Void)?
  var writes = 0
  var engines: [String] = []
  var added: [[JSONValue]] = []
  var removed: [[String]] = []

  func historyReady(_ profileId: String) -> Bool { ready }
  func history(_ profileId: String) -> [JSONValue]? { entries }
  func historyFloor(_ profileId: String) -> Double? { nil }
  func engineProfile(_ profileId: String) -> String { profileId == "default" ? "" : profileId }
  func setHistory(_ profileId: String, _ entries: [JSONValue]) { writes += 1; self.entries = entries }

  func addHistoryVisits(_ engineProfile: String, _ visits: [JSONValue], _ sameVisitMs: Double) async throws -> JSONValue? {
    engines.append(engineProfile)
    added.append(visits)
    try await onAdd?()
    return nil
  }

  func deleteHistoryUrls(_ engineProfile: String, _ urls: [String]) async throws -> JSONValue? {
    engines.append(engineProfile)
    removed.append(urls)
    return nil
  }
}

private func waited(_ semaphore: DispatchSemaphore) async -> Bool {
  await withCheckedContinuation { continuation in
    Thread.detachNewThread { continuation.resume(returning: semaphore.wait(timeout: .now() + 60) == .success) }
  }
}

@Suite struct HistoryAdapterLifetimeTests {
  private let key = "h:https://remote.example/"
  private let value: JSONValue = ["t": "Remote", "n": 1, "vt": [1000]]
  private let records = ApplyRecords(known: { _ in true }, now: 1000, horizon: 0, joined: true)

  private func apply(_ adapter: HistoryAdapter) async throws -> Bool? {
    try await adapter.apply([(key, value)], [key], { _ in nil }, records)
  }

  @Test(arguments: ["missing", "wrong-id", "queued", "not-ready"])
  func unavailableHistoryNeitherExtractsNorApplies(_ reason: String) async throws {
    let store = Store(checksInvariants: false)
    let host = HistoryLifetimeHost()
    switch reason {
    case "missing": try store.transact { $0.update { $0.profiles["default"] = nil } }
    case "wrong-id": try store.transact { $0.update { $0.profiles["default"]?.id = "other" } }
    case "queued": try store.transact { $0.update { $0.orphanedProfileData = [""] } }
    default: host.ready = false
    }
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
    #expect(try await adapter.extract(ExtractContext(base: { _ in nil }, queued: { _ in false }, now: 1000, known: { _ in false }, remote: { _ in nil }, stamp: { _ in nil })) == nil)
    #expect(try await apply(adapter) == false)
    #expect(host.engines.isEmpty)
    #expect(host.writes == 0)
  }

  @Test(arguments: ["delete", "delete-and-restore", "remap", "remap-and-restore", "recreate", "recreate-and-restore", "queue", "queue-and-drain", "wrong-id-and-restore", "not-ready"])
  func retiredInFlightHistoryRefusesEveryChangedKey(_ transition: String) async throws {
    let store = Store(checksInvariants: false)
    let host = HistoryLifetimeHost()
    let original = store.state.profiles["default"]!
    host.onAdd = {
      try store.transact { session in
        session.update { state in
          switch transition {
          case "delete", "delete-and-restore": state.profiles["default"] = nil
          case "remap", "remap-and-restore": state.profiles["default"]?.dataId = "other"
          case "recreate", "recreate-and-restore": state.profiles["default"]?.createdAt = 2
          case "wrong-id-and-restore": state.profiles["default"]?.id = "other"
          case "queue", "queue-and-drain": state.orphanedProfileData = [""]
          default: host.ready = false
          }
        }
      }
      if transition.hasSuffix("-and-restore") || transition == "queue-and-drain" {
        try store.transact { $0.update { $0.profiles["default"] = original; $0.orphanedProfileData = [] } }
      }
    }
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
    let changed = [key, "h:https://deleted.example/"]
    do {
      _ = try await adapter.apply([(key, value)], changed, { _ in nil }, records)
      Issue.record("retired history apply succeeded")
    } catch let refusal as ApplyRefusal {
      #expect(refusal.refused == changed)
    }
    #expect(host.writes == 0)
    #expect(host.entries?.isEmpty == true)
    #expect(host.engines == ["", ""])
  }

  @Test func aRefusedHistoryKeyStaysUnappliedAndIsAppliedOnTheNextCycle() async throws {
    let store = Store(checksInvariants: false)
    let host = HistoryLifetimeHost()
    let original = store.state.profiles["default"]!
    host.onAdd = {
      try store.transact { $0.update { $0.profiles["default"] = nil } }
      try store.transact { $0.update { $0.profiles["default"] = original } }
    }
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
    let state = ScopeState()
    state.joined = true
    state.records[key] = SyncRecord(h: "1", v: value, o: Origin("remote", 1))
    state.unapplied = await applyAdapter(state, adapter, OrderedSet([key]), 1000, 0, false, nil)
    #expect(state.unapplied == [key])
    #expect(state.base[key] == nil)
    #expect(host.writes == 0)
    #expect(host.engines == ["", ""])
    #expect(host.removed == [[]])
    host.onAdd = nil
    state.unapplied = await applyAdapter(state, adapter, OrderedSet(state.unapplied), 1000, 0, false, nil)
    #expect(state.unapplied.isEmpty)
    #expect(state.base[key] == syncCanonical(value))
    #expect(host.engines == ["", "", "", ""])
    #expect(host.removed == [[], []])
    #expect(host.added.count == 2)
    #expect(host.added[0] == host.added[1])
    #expect(host.writes == 1)
    #expect(host.entries?.count == 1)
  }

  @Test func aHeldDeferredCallbackDelaysHistoryButCannotStarveIt() async throws {
    let store = Store(checksInvariants: false)
    let host = HistoryLifetimeHost()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      store.afterSequence {
        entered.signal()
        _ = release.wait(timeout: .now() + 120)
      }
      drained.signal()
    }
    defer { release.signal() }
    try #require(await waited(entered))
    try store.transact { $0.update { $0.profiles["default"]?.name = "Held" } }
    let held = store.deliveryCursor()
    try #require(held.delivered < held.committed)
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
    let state = ScopeState()
    state.joined = true
    state.records[key] = SyncRecord(h: "1", v: value, o: Origin("remote", 1))
    state.unapplied = await applyAdapter(state, adapter, OrderedSet([key]), 1000, 0, false, nil)
    #expect(state.unapplied == [key])
    #expect(state.base[key] == nil)
    #expect(host.writes == 0)
    release.signal()
    try #require(await waited(drained))
    let caughtUp = store.deliveryCursor()
    try #require(caughtUp.delivered == caughtUp.committed)
    state.unapplied = await applyAdapter(state, adapter, OrderedSet(state.unapplied), 1000, 0, false, nil)
    #expect(state.unapplied.isEmpty)
    #expect(state.base[key] == syncCanonical(value))
    #expect(host.writes == 1)
    #expect(host.entries?.first?["url"] == "https://remote.example/")
  }

  @Test func renameKeepsTheHistoryLifetime() async throws {
    let store = Store(checksInvariants: false)
    let host = HistoryLifetimeHost()
    host.onAdd = { try store.transact { $0.update { $0.profiles["default"]?.name = "Renamed" } } }
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
    #expect(try await apply(adapter) == nil)
    #expect(host.writes == 1)
    #expect(host.entries?.first?["url"] == "https://remote.example/")
  }

  #if DEBUG
    @Test func deletionAndRestoreDeliveredDuringHostCallCannotPublishHistory() async throws {
      let store = Store(checksInvariants: false)
      let host = HistoryLifetimeHost()
      let original = store.state.profiles["default"]!
      try #require(store.pauseDeliveryForTesting())
      defer { store.resumeDeliveryForTesting() }
      try store.transact { $0.update { $0.profiles["default"] = nil } }
      try store.transact { $0.update { $0.profiles["default"] = original } }
      let paused = store.deliveryCursor()
      try #require(paused.delivered == 0)
      try #require(paused.committed == 2)
      host.onAdd = { store.resumeDeliveryForTesting() }
      let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
      let changed = [key, "h:https://deleted.example/"]
      do {
        _ = try await adapter.apply([(key, value)], changed, { _ in nil }, records)
        Issue.record("history published after initially pending lifetime changes were delivered during the host call")
      } catch let refusal as ApplyRefusal {
        #expect(refusal.refused == changed)
      }
      #expect(host.writes == 0)
      #expect(host.entries?.isEmpty == true)
      let resumed = store.deliveryCursor()
      try #require(resumed.delivered == 2)
      try #require(resumed.delivered == resumed.committed)
      #expect(try await adapter.apply([(key, value)], changed, { _ in nil }, records) == nil)
      #expect(host.writes == 1)
      #expect(host.entries?.first?["url"] == "https://remote.example/")
    }

    @Test func undeliveredDeletionAndRestoreCannotPublishHistory() async throws {
      let store = Store(checksInvariants: false)
      let host = HistoryLifetimeHost()
      let original = store.state.profiles["default"]!
      try #require(store.pauseDeliveryForTesting())
      defer { store.resumeDeliveryForTesting() }
      try store.transact { $0.update { $0.profiles["default"] = nil } }
      try store.transact { $0.update { $0.profiles["default"] = original } }
      let paused = store.deliveryCursor()
      try #require(paused.delivered == 0)
      try #require(paused.committed == 2)
      try #require(paused.delivered < paused.committed)
      let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { 1000 })
      do {
        _ = try await apply(adapter)
        Issue.record("history published before committed lifetime changes were delivered")
      } catch let refusal as ApplyRefusal {
        #expect(refusal.refused == [key])
      }
      #expect(host.writes == 0)
      #expect(host.entries?.isEmpty == true)
      store.resumeDeliveryForTesting()
      let resumed = store.deliveryCursor()
      try #require(resumed.delivered == resumed.committed)
      #expect(try await apply(adapter) == nil)
      #expect(host.writes == 1)
      #expect(host.entries?.first?["url"] == "https://remote.example/")
    }
  #endif
}
