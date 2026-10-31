import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

private final class HostBarrierLifetime: Sendable {
  let finished: DispatchSemaphore
  init(_ finished: DispatchSemaphore) { self.finished = finished }
  deinit { finished.signal() }
}

@Suite struct StoreHostTests {
  @Test func launchLookLoadsBeforeFirstSnapshotAndRNEvent() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = Store(clock: { 0 })
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://launch.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    let look: JSONValue = ["version": 2, "themes": [["tab": .string(id), "page": "https://launch.example/", "color": "blue"]]]
    try Data(look.text().utf8).write(to: folder.appending(path: "launch-look.json"))
    let order = Mutex<[String]>([])
    let events = Mutex<[String]>([])
    let scheduled = Mutex<[TimeInterval]>([])
    let host = StoreHost(
      store: store, ownsWorkspace: true, folder: folder,
      themeSchedule: { delay, _ in scheduled.withLock { $0.append(delay) } },
      makeWriter: { store in
        #expect(store.snapshot.state.live[id]?.themeColor == "blue")
        order.withLock { $0.append("writer") }
        order.withLock { $0.append("rn") }
        store.enqueuePageReport(id: id, report: ["type": "created", "generation": "G", "engine": "chromium",
          "navigationSeq": store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
          "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null])
        store.enqueuePageReport(id: id, report: ["type": "navigation", "generation": "G",
          "url": "https://launch.example/", "title": "Launch", "isLoading": false, "canGoBack": false, "canGoForward": false])
        store.sequence {}
        #expect(scheduled.withLock { $0 } == [1.5])
        return nil
      },
      makeBridge: { store in
        order.withLock { $0.append("bridge") }
        let bridge = StoreBridge(store: store)
        #expect(bridge.snapshot()["data"]?["live"]?[id]?["themeColor"] == "blue")
        _ = bridge.observeForeignCommits { event in
          #expect(order.withLock { $0.contains("rn") })
          #expect(store.snapshot.state.live[id]?.themeColor == "blue")
          events.withLock { $0.append(event) }
        }
        return bridge
      })
    #expect(order.withLock { $0 } == ["writer", "rn", "bridge"])
    #expect(events.withLock { $0.isEmpty })
    #expect(host.bridge.snapshot()["data"]?["live"]?[id]?["themeColor"] == "blue")
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    store.sequence {}
    #expect(scheduled.withLock { $0 } == [1.5])
    #expect(order.withLock { $0 } == ["writer", "rn", "bridge"])
    let event = try #require(events.withLock { $0.first })
    #expect(try JSONValue.parse(event)["patch"]?["live"]?["upsert"]?.array?.first?["themeColor"] == "blue")
    #expect(host.bridge.snapshot()["data"]?["live"]?[id]?["themeColor"] == "blue")
  }

  @Test func bothNativeQuitPathsUseBarrierThenWriter() throws {
    for termination in [true, false] {
      let store = Store()
      let order = Mutex<[String]>([])
      let stages = QuitFlush.Stages(
        drain: { deadline in
          #expect(ContinuousClock.now < deadline)
          order.withLock { $0.append("barrier") }
          return true
        },
        flush: { complete in
          order.withLock { $0.append("writer") }
          complete(.saved)
        })
      let host = StoreHost(store: store, ownsWorkspace: false, folder: FileManager.default.temporaryDirectory,
        makeWriter: { _ in nil }, quitStages: stages)
      let result = termination ? host.termination() : host.flush(timeout: 1)
      #expect(result == .saved)
      #expect(order.withLock { $0 } == ["barrier", "writer"])

      let blockedStore = Store()
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      let lateOrder = Mutex<[String]>([])
      defer { release.signal() }
      do {
        let lifetime = HostBarrierLifetime(finished)
        let blocked = StoreHost(store: blockedStore, ownsWorkspace: false, folder: FileManager.default.temporaryDirectory,
          makeWriter: { _ in nil }, quitStages: QuitFlush.Stages(
            drain: { _ in
              withExtendedLifetime(lifetime) {
                lateOrder.withLock { $0.append("barrier") }
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return true
              }
            },
            flush: { complete in
              lateOrder.withLock { $0.append("writer") }
              complete(.saved)
            }))
        let timedOut = termination ? blocked.termination() : blocked.flush(timeout: 0.01)
        #expect(timedOut == .timedOut)
      }
      try #require(entered.wait(timeout: .now() + 1) == .success)
      release.signal()
      try #require(finished.wait(timeout: .now() + 5) == .success)
      #expect(lateOrder.withLock { $0 } == ["barrier"])
    }
  }
}
