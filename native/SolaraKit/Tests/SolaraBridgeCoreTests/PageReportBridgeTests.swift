import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct PageReportBridgeTests {
  func fixture(encoder: @escaping StoreBridge.CatchUpEncoder = { StoreBridge.encode($0, into: $1) }) throws -> (StoreBridge, String) {
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "bridge")), config: config, checksInvariants: false, clock: { 1 })
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://seed.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    try store.dispatch(Command("pageReport", [.string(id), ["type": "created", "generation": "G", "engine": "chromium",
      "navigationSeq": store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
      "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null]]))
    return (StoreBridge(store: store, encodeCatchUp: encoder), id)
  }

  func traffic(_ store: Store, _ id: String, _ range: Range<Int>) throws {
    for index in range {
      switch index % 3 {
      case 0:
        try store.dispatch(Command("pageReport", [.string(id), ["type": "navigation", "generation": "G",
          "url": .string("https://page.example/\(index)"), "title": .string("Page \(index)"),
          "isLoading": .bool(index % 2 == 0), "canGoBack": true, "canGoForward": false]]))
      case 1:
        try store.dispatch(Command("pageReport", [.string(id), ["type": "media", "generation": "G", "playing": .bool((index / 3) % 2 == 0)]]))
      default:
        try store.dispatch(Command("updateTab", [.string(id), ["customTitle": .string("Custom \(index)")]]))
      }
    }
  }

  func revisions(_ response: JSONObject) -> [Int] {
    response["patches"]?.array?.compactMap { $0["rev"]?.int } ?? []
  }

  func apply(_ response: JSONObject, to replica: inout JSONObject, cursor: inout Int) throws {
    if let snapshot = response["snapshot"]?.object { replica = snapshot }
    for patch in response["patches"]?.array ?? [] {
      let rev = try #require(patch["rev"]?.int)
      #expect(rev == cursor + 1)
      for key in ["tabs", "live"] {
        guard let change = patch[key] else { continue }
        var table = replica[key]?.object ?? [:]
        for id in change["remove"]?.array?.compactMap(\.string) ?? [] { table[id] = nil }
        for value in change["upsert"]?.array ?? [] {
          let id = try #require(value["id"]?.string)
          if key == "live" {
            var facts = try #require(value.object)
            facts["id"] = nil
            table[id] = .object(facts)
          } else { table[id] = value }
        }
        replica[key] = .object(table)
      }
      cursor = rev
    }
    cursor = try #require(response["rev"]?.int)
  }

  @Test func mixedReportArrayReturnsEarlierEffectsAndResult() throws {
    let (bridge, id) = try fixture()
    let commands: JSONValue = [
      ["name": "nextId", "args": ["earlier"]],
      ["name": "pageReport", "args": [.string(id), ["type": "issued", "generation": "G",
        "navigationSeq": bridge.store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
        "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null,
        "navigation": bridge.store.state.tabs[id]?.navigation?.jsonValue ?? .null, "startedEarly": false]]],
      ["name": "pageReport", "args": [.string(id), ["type": "media", "generation": "G", "playing": true]]],
    ]
    let response = bridge.dispatch(json: commands.text(), sinceRev: bridge.store.rev)
    #expect(response["error"] == nil)
    #expect(response["result"]?["guard"]?["sessionGeneration"] == "G")
    #expect(response["result"]?["actions"]?.array?.last?["type"] == "load")
    #expect(response["patches"]?.array?.last?["live"]?["upsert"]?.array?.first?["playingAudio"] == true)
    let effectCommands: JSONValue = [
      ["name": "createProfile", "args": [["name": "Earlier"]]],
      ["name": "nextId", "args": ["earlier"]],
      ["name": "pageReport", "args": [.string(id), ["type": "media", "generation": "G", "playing": false]]],
    ]
    let effects = bridge.dispatch(json: effectCommands.text(), sinceRev: bridge.store.rev)
    #expect(effects["error"] == nil)
    #expect(effects["result"]?.string?.hasPrefix("earlier") == true)
    #expect(effects["effects"]?.array?.contains { $0["type"] == "profileCreated" } == true)
  }

  @Test func aWholeSliceWriteCannotForgeLiveFacts() throws {
    let (bridge, id) = try fixture()
    let baseline = bridge.store.snapshot
    let command: JSONValue = ["name": "applyState", "args": [["live": .object([id: ["playingAudio": true]])]]]
    let response = bridge.dispatch(json: command.text(), sinceRev: baseline.rev)
    #expect(response["error"]?.string?.contains("live") == true)
    #expect(bridge.store.state == baseline.state)
    #expect(bridge.store.rev == baseline.rev)
  }

  @Test func catchUpRetainsMixedTrafficPastTheOldRing() throws {
    let (bridge, id) = try fixture()
    let baseline = bridge.store.rev
    try traffic(bridge.store, id, 0..<2_048)
    let response = bridge.catchUp(sinceRev: baseline)
    #expect(response["snapshot"] == nil)
    #expect(revisions(response) == Array((baseline + 1)...(baseline + 2_048)))
    #expect(response["rev"] == JSONValue(baseline + 2_048))
  }

  @Test func catchUpAtFullCapacityReturnsAll65536ExactRevisions() throws {
    let (bridge, id) = try fixture()
    let baseline = bridge.store.rev
    try traffic(bridge.store, id, 0..<Store.ringSize)
    let response = bridge.catchUp(sinceRev: baseline)
    #expect(response["snapshot"] == nil)
    #expect(revisions(response) == Array((baseline + 1)...(baseline + Store.ringSize)))
    #expect(response["rev"] == JSONValue(baseline + Store.ringSize))
    #expect(response["patches"]?.array?.contains { $0["tabs"] != nil && $0["live"] != nil } == true)
  }

  @Test func ringWrapKeepsNewest65536AndRejectsOneOlderCursor() throws {
    let (bridge, id) = try fixture()
    let baseline = bridge.store.rev
    try traffic(bridge.store, id, 0..<(Store.ringSize + 7))
    let response = bridge.catchUp(sinceRev: baseline + 7)
    #expect(revisions(response) == Array((baseline + 8)...(baseline + Store.ringSize + 7)))
    #expect(response["snapshot"] == nil)
    #expect(response["rev"] == JSONValue(baseline + Store.ringSize + 7))
    let stale = bridge.catchUp(sinceRev: baseline + 6)
    #expect(stale["patches"] == nil)
    #expect(stale["snapshot"] == .object(bridge.store.state.stateJSON))
    #expect(stale["rev"] == response["rev"])
  }

  @Test func snapshotFallbackThenConcurrentCatchUpRecoversExactly() throws {
    let captured = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let pause = Mutex(false)
    let (bridge, id) = try fixture { value, response in
      if pause.withLock({ armed in let previous = armed; armed = false; return previous }) {
        captured.signal()
        _ = release.wait(timeout: .now() + 10)
      }
      return StoreBridge.encode(value, into: response)
    }
    var nextIndex = 0
    for _ in 0..<2 {
      try traffic(bridge.store, id, nextIndex..<(nextIndex + Store.ringSize + 12))
      nextIndex += Store.ringSize + 12
      let expected = bridge.store.snapshot
      let result = Mutex<JSONObject?>(nil)
      let finished = DispatchSemaphore(value: 0)
      pause.withLock { $0 = true }
      Thread.detachNewThread {
        result.withLock { $0 = bridge.catchUp(sinceRev: 0) }
        finished.signal()
      }
      #expect(captured.wait(timeout: .now() + 10) == .success)
      try traffic(bridge.store, id, nextIndex..<(nextIndex + 9))
      nextIndex += 9
      release.signal()
      #expect(finished.wait(timeout: .now() + 10) == .success)
      let fallback = try #require(result.withLock { $0 })
      #expect(fallback["snapshot"] == .object(expected.state.stateJSON))
      #expect(fallback["rev"] == JSONValue(expected.rev))
      var replica = JSONObject()
      var cursor = 0
      try apply(fallback, to: &replica, cursor: &cursor)
      let later = bridge.catchUp(sinceRev: cursor)
      #expect(revisions(later) == Array((expected.rev + 1)...(expected.rev + 9)))
      try apply(later, to: &replica, cursor: &cursor)
      #expect(replica == bridge.store.state.stateJSON)
      #expect(cursor == bridge.store.rev)
      #expect(bridge.catchUp(sinceRev: cursor)["patches"] == [])
    }
  }

  @Test func encoderDoesNotHoldIngressAndCursorDoesNotDrift() throws {
    for operation in ["catchUp", "dispatch", "error", "busy", "snapshot"] {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let armed = Mutex(true)
      let (bridge, id) = try fixture { capture, response in
        if armed.withLock({ value in let previous = value; value = false; return previous }) {
          entered.signal()
          _ = release.wait(timeout: .now() + 10)
        }
        return StoreBridge.encode(capture, into: response)
      }
      defer { release.signal() }
      try traffic(bridge.store, id, 0..<3)
      if operation == "busy" { try bridge.store.dispatch(Command("beginTransaction")) }
      let expected = bridge.store.snapshot
      let result = Mutex<JSONValue?>(nil)
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        let response: JSONValue
        switch operation {
        case "dispatch": response = bridge.dispatch(json: #"{"name":"nextId","args":["test"]}"#, sinceRev: expected.rev)
        case "error": response = bridge.dispatch(json: #"{"name":"unknown"}"#, sinceRev: expected.rev)
        case "busy": response = bridge.dispatch(json: #"{"fromSync":true,"commands":[{"name":"applyState","args":[{"tabs":{}}]}]}"#, sinceRev: expected.rev)
        case "snapshot": response = bridge.snapshot()
        default: response = .object(bridge.catchUp(sinceRev: expected.rev - 1))
        }
        result.withLock { $0 = response }
        finished.signal()
      }
      #expect(entered.wait(timeout: .now() + 10) == .success)
      let progressed = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        bridge.store.enqueuePageReport(id: id, report: ["type": "navigation", "generation": "G", "url": "https://concurrent.example/", "title": "Concurrent", "isLoading": false, "canGoBack": true, "canGoForward": false])
        _ = try? bridge.store.dispatch(Command("nextId", ["concurrent"]))
        _ = bridge.store.pageFacts(id)
        progressed.signal()
      }
      let completedBeforeRelease = progressed.wait(timeout: .now() + 2)
      release.signal()
      #expect(completedBeforeRelease == .success)
      #expect(finished.wait(timeout: .now() + 10) == .success)
      let response = try #require(result.withLock { $0 })
      #expect(response["rev"] == JSONValue(expected.rev))
      if operation == "snapshot" { #expect(response["data"] == .object(expected.state.stateJSON)) }
      else if operation == "catchUp" { #expect(response["patches"]?.array?.last?["rev"] == JSONValue(expected.rev)) }
      else { #expect(response["patches"] == []) }
      if operation == "error" { #expect(response["error"] != nil) }
      if operation == "busy" { #expect(response["busy"] == true) }
      #expect(bridge.store.state.tabs[id]?.url == "https://concurrent.example/")
    }
  }

  @Test func emptyCatchUpReturnsCapturedCurrentCursor() throws {
    let (bridge, id) = try fixture()
    try traffic(bridge.store, id, 0..<3)
    let current = bridge.store.rev
    for requested in [current, current + 99, Int.max] {
      let response = bridge.catchUp(sinceRev: requested)
      #expect(response["patches"] == [])
      #expect(response["rev"] == JSONValue(current))
    }
    let negative = bridge.catchUp(sinceRev: -1)
    #expect(negative["snapshot"] == .object(bridge.store.state.stateJSON))
    #expect(negative["rev"] == JSONValue(current))
    let empty = StoreBridge(store: Store(checksInvariants: false))
    for requested in [-1, 0, 99] {
      let response = empty.catchUp(sinceRev: requested)
      #expect(response["rev"] == 0)
      #expect(response["patches"] == [] || response["snapshot"] != nil)
    }
  }
}
