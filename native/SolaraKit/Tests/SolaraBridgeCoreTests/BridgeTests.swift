import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Testing

@Suite struct BridgeTests {
  func bridge() -> StoreBridge {
    StoreBridge(store: Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "t")), checksInvariants: true, clock: { 1 }))
  }

  @Test func dispatchReturnsEveryPatchSinceTheCallersRevIncludingItsOwn() throws {
    let bridge = bridge()
    _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"tabLayout":"top"},{"fromSync":true}]}"#, sinceRev: 0)
    let response = try JSONValue.parse(bridge.dispatch(#"{"name":"updateSettings","args":[{"appearance":"light"}]}"#, sinceRev: 0))
    #expect(response["rev"] == 2)
    #expect(response["patches"]?.array?.count == 2)
    #expect(response["patches"]?.array?.last?["settings"]?["set"]?["appearance"] == "light")
  }

  @Test func aBatchIsOneCommitAndEffectsComeBack() throws {
    let bridge = bridge()
    let response = try JSONValue.parse(bridge.dispatch(#"[{"name":"createWindow","args":[{}]},{"name":"upsertDownload","args":[{"id":"a","state":"complete","profile":""}]},{"name":"upsertDownload","args":[{"id":"b","state":"complete"}]}]"#, sinceRev: 0))
    #expect(response["rev"] == 1)
    #expect(response["effects"]?.array?.contains { $0["type"] == "openDownloads" } != true)
    #expect(response["patches"]?.array?.first?["windowUi"]?["upsert"]?.array?.first?["state"]?["downloadsOpen"] == true)
    #expect(response["patches"]?.array?.first?["downloads"]?.array?.count == 2)
    #expect(response["patches"]?.array?.first?["windows"]?["upsert"]?.array?.count == 1)
  }

  @Test func errorsComeBackWithTheCatchUp() throws {
    let bridge = bridge()
    let response = try JSONValue.parse(bridge.dispatch(#"{"name":"nope"}"#, sinceRev: 0))
    #expect(response["error"]?.string?.contains("unknown command") == true)
    #expect(response["rev"] == 0)
    #expect(response["patches"] == [])
  }

  @Test func aCallerTooFarBehindGetsASnapshot() throws {
    let bridge = bridge()
    for i in 0..<(Store.ringSize + 2) {
      _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"sidebarWidth":\#(i)},{"fromSync":true}]}"#, sinceRev: i)
    }
    let response = bridge.catchUp(sinceRev: 0)
    #expect(response["snapshot"]?["settings"]?["sidebarWidth"] == .number(Double(Store.ringSize + 1)))
    #expect(response["patches"] == nil)
  }

  @Test func nativeStripEffectsDoNotNotifyTheReplicaOrAdvanceItsCursor() throws {
    let bridge = bridge()
    let events = Events()
    bridge.observeForeignCommits { events.append($0) }
    let command: JSONValue = ["op": "arrange", "strip": 7, "keys": ["a", "b"], "pinned": 0]
    let commit = try bridge.store.transact(origin: .engine) { session in
      session.emit(.stripCommand(strip: 7, id: 1, command: command))
      session.emit(.stripCommand(strip: 8, id: 2, command: ["op": "activate", "strip": 8, "key": "c"]))
    }
    #expect(commit.effects.count == 2)
    #expect(commit.changes.isEmpty)
    #expect(commit.rev == 0)
    #expect(events.values.isEmpty)
    let caughtUp = bridge.catchUp(sinceRev: 0)
    #expect(caughtUp["rev"] == 0)
    #expect(caughtUp["patches"] == [])
    try bridge.store.dispatch(Command("updateSettings", [["appearance": "light"]]), origin: .native)
    #expect(events.values.count == 1)
    let next = try JSONValue.parse(events.values.last!)
    #expect(next["rev"] == 1)
    #expect(next["patch"]?["settings"]?["set"]?["appearance"] == "light")
  }

  @Test func foreignStateChangesRetainTheirStripEffects() throws {
    let bridge = bridge()
    let events = Events()
    bridge.observeForeignCommits { events.append($0) }
    let commit = try bridge.store.transact(origin: .engine) { session in
      try session.apply(Command("updateSettings", [["appearance": "light"]]))
      session.emit(.stripCommand(strip: 7, id: 1, command: ["op": "arrange", "strip": 7, "keys": [], "pinned": 0]))
    }
    #expect(events.values.count == 1)
    let event = try JSONValue.parse(events.values[0])
    #expect(event["rev"] == 1)
    #expect(event["patch"]?["settings"]?["set"]?["appearance"] == "light")
    #expect(event["effects"] == .array(commit.effects.map(\.json)))
  }

  @Test func foreignJavaScriptEffectsRemainVisibleWithAndWithoutStripEffects() throws {
    for includeStrip in [false, true] {
      let bridge = bridge()
      let events = Events()
      bridge.observeForeignCommits { events.append($0) }
      let commit = try bridge.store.transact(origin: .engine) { session in
        if includeStrip {
          session.emit(.stripCommand(strip: 7, id: 1, command: ["op": "arrange", "strip": 7, "keys": [], "pinned": 0]))
        }
        session.emit(.cancelDownload(id: "download"))
      }
      #expect(commit.changes.isEmpty)
      #expect(events.values.count == 1)
      let event = try JSONValue.parse(events.values[0])
      #expect(event["rev"] == 0)
      #expect(event["effects"] == .array(commit.effects.map(\.json)))
    }
  }

  @Test func foreignCommitsAreReportedAndBridgeOnesAreNot() throws {
    let bridge = bridge()
    let events = Events()
    bridge.observeForeignCommits { events.append($0) }
    _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"appearance":"dark"}]}"#, sinceRev: 0)
    try bridge.store.dispatch(Command("updateSettings", [["appearance": "light"], ["fromSync": true]]), origin: .sync)
    #expect(events.values.count == 1)
    #expect(try JSONValue.parse(events.values[0])["rev"] == 2)
  }
}

final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func append(_ item: String) { lock.withLock { items.append(item) } }
  var values: [String] { lock.withLock { items } }
}
