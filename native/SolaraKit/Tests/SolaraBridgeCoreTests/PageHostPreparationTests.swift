import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct PageHostPreparationTests {
  @Test func preparationDrainsNativeFactsInsideIngressAndEncodingReleasesIt() throws {
    let store = Store(clock: { 0 })
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    let sequence = try #require(store.state.tabs[id]?.navigation?.seq)
    store.enqueuePageReport(id: id, report: ["type": "created", "generation": "G", "engine": "chromium",
      "navigationSeq": JSONValue(sequence), "contextRevision": 0, "wasNewTab": false, "newTabShownUrl": .null])
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    let encoded = Mutex(false)
    let bridge = StoreBridge(store: store, encodeCatchUp: { captured, response in
      let completed = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        _ = try? store.dispatch(Command("setMuted", [.string(id), true]))
        completed.signal()
      }
      #expect(completed.wait(timeout: .now() + 10) == .success)
      encoded.withLock { $0 = true }
      return StoreBridge.encode(captured, into: response)
    })
    let called = Mutex(false)
    let response = bridge.dispatch(json: Command("setMuted", [.string(id), false]).json.text(), sinceRev: 0, prepare: { commands in
      #expect((try? store.withinSequence { store.state.live[id]?.playingAudio == true }) == true)
      called.withLock { $0 = true }
      return commands
    })
    #expect(response["error"] == nil)
    #expect(called.withLock { $0 })
    #expect(encoded.withLock { $0 })
  }

  @Test func pinnedIsolationAndSyncRefusalNeverRunNativePreparation() throws {
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(config: config)
    let bridge = StoreBridge(store: store)
    let called = Mutex(false)
    let commands = [Command("syncPinsApply", [[]]), Command("pageReport", ["missing", ["type": "media", "generation": "G", "playing": true]])]
    let response = bridge.dispatch(json: JSONValue.array(commands.map(\.json)).text(), sinceRev: 0, prepare: { commands in
      called.withLock { $0 = true }
      return commands
    })
    #expect(response["error"] != nil)
    #expect(!called.withLock { $0 })
    _ = try store.dispatch(Command("beginTransaction"))
    let sync: JSONValue = ["fromSync": true, "commands": [Command("updateSettings", [["appearance": "dark"]]).json]]
    let busy = bridge.dispatch(json: sync.text(), sinceRev: store.snapshot.rev, prepare: { commands in
      called.withLock { $0 = true }
      return commands
    })
    #expect(busy["busy"] == true)
    #expect(!called.withLock { $0 })
    _ = try store.dispatch(Command("endTransaction"))
  }
}
