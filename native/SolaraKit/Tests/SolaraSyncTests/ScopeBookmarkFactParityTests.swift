import SolaraModel
@testable import SolaraSync
import Testing

private final class FactAdapter: SyncAdapter {
  let prefix = "bm:"
  var originalEditTime = false
  var extraction = Extraction(values: [])
  var applied: ((ApplyRecords) -> Void)?

  func extract(_ context: ExtractContext) async throws -> Extraction? { extraction }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    applied?(records)
    return nil
  }
}

private struct FactFailure: Error {}

private final class FactTransport: SyncTransport, @unchecked Sendable {
  var failWrite = false
  var writes = 0

  func write(_ scope: String, _ payload: String) async throws -> String {
    if failWrite { throw FactFailure() }
    writes += 1
    return "f\(writes)"
  }

  func read(_ scope: String, _ known: [String]) async throws -> Listing {
    Listing(files: [], pending: [], damaged: [], present: [])
  }

  func remove(_ scope: String, _ ids: [String]) async throws {}
}

struct ScopeBookmarkFactParityTests {
  @Test func rejectedEditsKeepTheAgreedBase() async throws {
    for mode in 0..<3 {
      let state = ScopeState()
      let key = "bm:k"
      let old: JSONValue = ["t": "agreed"]
      let winner: JSONValue = ["t": "remote"]
      let h = formatHLC(200, 0, "remote")
      state.records[key] = SyncRecord(h: h, v: winner, o: Origin("remote", 1))
      state.base[key] = syncCanonical(old)
      let adapter = FactAdapter()
      adapter.extraction = Extraction(
        values: mode == 0 ? [(key: key, value: ["t": "local"] as JSONValue?)] : [],
        ignore: mode == 2 ? { _ in true } : nil,
        stamp: { _ in Stamped(at: 50) }, remove: mode == 2 ? [key] : [])
      let published = try await publishAdapter(state, adapter, Clock(device: "local", now: { 100 }), "local", 100)
      #expect(published.isEmpty)
      #expect(state.base[key] == syncCanonical(old))
      #expect(state.records[key]?.h == h)
      #expect(state.records[key]?.v == winner)
      #expect(state.outbox.isEmpty)
    }
  }

  @Test func equalStampedEditsKeepTheRecordAndDoNotPublish() async throws {
    for mode in 0..<3 {
      let state = ScopeState()
      let key = "bm:k"
      let winner: JSONValue = ["t": "First"]
      let h = formatHLC(100, 0, "local")
      state.records[key] = SyncRecord(h: h, v: winner, o: Origin("local", 1))
      state.base[key] = syncCanonical(winner)
      let adapter = FactAdapter()
      adapter.originalEditTime = true
      var receipts = 0
      adapter.extraction = Extraction(
        values: mode == 0 ? [(key: key, value: ["t": "Second"] as JSONValue?)] : [],
        ignore: mode == 2 ? { _ in true } : nil,
        published: { _, _ in receipts += 1 },
        stamp: { _ in Stamped(at: 100) }, remove: mode == 2 ? [key] : [])
      let published = try await publishAdapter(state, adapter, Clock(device: "local", now: { 1000 }), "local", 1000)
      #expect(published.isEmpty)
      #expect(state.base[key] == syncCanonical(winner))
      #expect(state.records[key]?.h == h)
      #expect(state.records[key]?.v == winner)
      #expect(state.outbox.isEmpty)
      let transport = FactTransport()
      try await flush(state, transport, "p", "local", 1000)
      #expect(receipts == 0)
      #expect(transport.writes == 0)
    }
  }

  @Test func originalEditTimePreservesFutureFactsAndObservesTheirClock() async throws {
    for original in [false, true] {
      let state = ScopeState()
      let adapter = FactAdapter()
      adapter.originalEditTime = original
      adapter.extraction = Extraction(values: [("bm:k", ["t": "local"])], stamp: { _ in Stamped(at: 300) })
      let clock = Clock(device: "local", now: { 100 })
      _ = try await publishAdapter(state, adapter, clock, "local", 100)
      let wall: Double = original ? 300 : 100
      #expect(state.records["bm:k"]?.h == formatHLC(wall, 0, "local"))
      #expect(clock.tick() == formatHLC(wall, 1, "local"))
    }
  }

  @Test func editClockKeepsTheDeviceAndRollsOverTheObservedCounter() {
    let after = formatHLC(200, 1_679_615, "remote.with.dots")
    #expect(hlcDevice(after) == "remote.with.dots")
    #expect(editHLC(Stamped(at: 100, after: after), "local") == formatHLC(201, 0, "local"))
    #expect(editHLC(Stamped(at: 300, after: after), "local") == formatHLC(300, 0, "local"))
    #expect(editHLC(Stamped(at: 100, after: ""), "local") == formatHLC(100, 0, "local"))
  }

  @Test func durablePublicationReportsOnlyAcceptedMintedStamps() async throws {
    let state = ScopeState()
    let adapter = FactAdapter()
    let remote = formatHLC(200, 0, "remote")
    state.records["bm:lost"] = SyncRecord(h: remote, v: ["t": "winner"], o: Origin("remote", 1))
    var settledKeys: [String]? = nil
    var settledStamps = JSMap<HLC>()
    var settlements = 0
    adapter.extraction = Extraction(
      values: [("bm:new", ["t": "new"]), ("bm:lost", ["t": "lost"])],
      published: { keys, stamps in
        settledKeys = keys
        settledStamps = stamps
        settlements += 1
      }, stamp: { _ in Stamped(at: 50) })
    _ = try await publishAdapter(state, adapter, Clock(device: "local", now: { 100 }), "local", 100)
    #expect(settledKeys == nil)
    let minted = state.records["bm:new"]?.h
    let transport = FactTransport()
    transport.failWrite = true
    do {
      try await flush(state, transport, "p", "local", 100)
      Issue.record("a failed transport write unexpectedly succeeded")
    } catch is FactFailure {}
    #expect(settledKeys == nil)
    transport.failWrite = false
    try await flush(state, transport, "p", "local", 100)
    #expect(settledKeys == ["bm:new"])
    #expect(settledStamps.keys == ["bm:new"])
    #expect(settledStamps["bm:new"] == minted)
    #expect(settledStamps["bm:lost"] == nil)
    #expect(settlements == 1)
    try await flush(state, transport, "p", "local", 100)
    #expect(settlements == 1)
  }

  @Test func zeroPublicationCommitWaitsForPersistenceAndRetries() async throws {
    let state = ScopeState()
    let adapter = FactAdapter()
    var commits = 0
    var persists = 0
    var refuse = true
    adapter.extraction = Extraction(values: [], committed: { commits += 1 })
    _ = try await publishAdapter(state, adapter, Clock(device: "local", now: { 100 }), "local", 100)
    var options = ScopeOptions()
    options.persist = { journal in
      #expect(journal.isEmpty)
      persists += 1
      if refuse { throw FactFailure() }
    }
    let transport = FactTransport()
    do {
      try await flush(state, transport, "p", "local", 100, options)
      Issue.record("a refused checkpoint unexpectedly succeeded")
    } catch is FactFailure {}
    #expect(commits == 0)
    refuse = false
    try await flush(state, transport, "p", "local", 100, options)
    #expect(commits == 1)
    #expect(persists == 2)
    #expect(transport.writes == 0)
    try await flush(state, transport, "p", "local", 100, options)
    #expect(commits == 1)
    #expect(persists == 2)
  }

  @Test func zeroPublicationCommitWithoutPersistenceSettlesOnce() async throws {
    let state = ScopeState()
    let adapter = FactAdapter()
    var commits = 0
    adapter.extraction = Extraction(values: [], committed: { commits += 1 })
    _ = try await publishAdapter(state, adapter, Clock(device: "local", now: { 100 }), "local", 100)
    let transport = FactTransport()
    try await flush(state, transport, "p", "local", 100)
    try await flush(state, transport, "p", "local", 100)
    #expect(commits == 1)
    #expect(transport.writes == 0)
  }

  @Test func applyReceivesLiveAndTombstoneRecordStamps() async {
    let state = ScopeState()
    let live = formatHLC(100, 1, "remote")
    let deleted = formatHLC(100, 2, "remote")
    state.records["bm:live"] = SyncRecord(h: live, v: ["t": "live"], o: Origin("remote", 1))
    state.records["bm:deleted"] = SyncRecord(h: deleted, v: .null, o: Origin("remote", 1))
    let adapter = FactAdapter()
    var applied = false
    adapter.applied = { records in
      applied = true
      #expect(records.stamp("bm:live") == live)
      #expect(records.stamp("bm:deleted") == deleted)
      #expect(records.stamp("bm:unknown") == nil)
    }
    let left = await applyAdapter(state, adapter, OrderedSet(["bm:live", "bm:deleted"]), 100, 0, false, nil)
    #expect(applied)
    #expect(left.isEmpty)
  }
}
