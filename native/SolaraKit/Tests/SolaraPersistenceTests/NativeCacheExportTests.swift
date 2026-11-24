import Foundation
import SolaraModel
import SolaraStore
@testable import SolaraPersistence
import Testing

@Suite struct NativeCacheExportTests {
  @Test func environmentAndCacheResolveTheRowsAndShadowTogether() throws {
    for cached in [nil, true, false] as [Bool?] {
      for override in [nil, "on", "off"] as [String?] {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let cache = folder.url.appending(path: "switches-cache.json")
        if let cached { try write("{\"switches\":{\"launchTab\":\(cached)}}", to: cache) }
        let environment = override.map { "launchTab=\($0)" }
        var config = StoreConfig()
        config.earlyLaunchTab = EarlyLaunchTabProvider.resolve(environment: environment, cache: try? Data(contentsOf: cache))
        let launch = try open(folder)
        let store = Store(state: launch.state, memory: launch.memory, config: config, checksInvariants: false)
        let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
        let provider = EarlyLaunchTabProvider(store: store, environment: environment, readCache: { try? Data(contentsOf: cache) })
        try store.dispatch(Command("createWindow", [["url": "https://launch.test/"]]))
        try provider.refresh()
        try store.dispatch(Command("setFocusedWindow", [JSONValue(store.state.windowOrder.last!)]))
        let expected = override.map { $0 == "on" } ?? cached ?? true
        #expect(writer.flush(timeout: 5) == .saved)
        let before = try JSONValue.parse(Data(contentsOf: folder.session))
        #expect((before["launchTab"] != .null) == expected)
        #expect(before["launchTab"] == store.sessionDocument().launchTab)
        let rows = try launch.database.load().workspace
        #expect(rows?.document()["launchTab"] == before["launchTab"])
        try write("{\"switches\":{\"launchTab\":false}}", to: cache)
        try provider.refresh()
        #expect(writer.flush(timeout: 5) == .saved)
        let after = try JSONValue.parse(Data(contentsOf: folder.session))
        #expect((after["launchTab"] != .null) == (override == "on"))
        #expect(after["launchTab"] == store.sessionDocument().launchTab)
        let refreshedRows = try launch.database.load().workspace
        #expect(refreshedRows?.document()["launchTab"] == after["launchTab"])
        writer.freeze()
        try launch.database.close()
        let next = try open(folder)
        defer { try? next.database.close() }
        #expect(try next.database.load().workspace?.document()["launchTab"] == after["launchTab"])
        let restored = SolaraStore.Store(state: next.state, memory: next.memory, config: config, checksInvariants: false)
        let restoredProvider = EarlyLaunchTabProvider(store: restored, environment: environment, readCache: { try? Data(contentsOf: cache) })
        try restoredProvider.refresh()
        #expect(restored.sessionDocument().launchTab == after["launchTab"])
        #expect(restored.state.windowOrder == store.state.windowOrder)
        for id in store.state.windowOrder {
          #expect(restored.state.windows[id]?.tabIds == store.state.windows[id]?.tabIds)
          #expect(restored.state.activeTabId(id) == store.state.activeTabId(id))
        }
      }
    }
  }
}
