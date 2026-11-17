import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct PageCreatedEnginePersistenceTests {
  @Test func acceptedCreationMakesItsEngineDurableWithoutTheJavaScriptFollowup() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://engine.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    #expect(store.state.tabs[id]?.engine == nil)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    #expect(writer.flush(timeout: 5) == .saved)
    let report: JSONValue = ["type": "created", "generation": "engine-persistence", "engine": "chromium",
      "navigationSeq": store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
      "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null]
    try store.dispatch(Command("pageReport", [.string(id), report]))
    #expect(writer.flush(timeout: 5) == .saved)
    let saved = try #require(try launch.database.load().workspace?.tables["tab"]?.payloads[id])
    #expect(try JSONValue.parse(saved)["engine"] == "chromium")
    let restored = try open(folder)
    defer { try? restored.database.close() }
    #expect(restored.state.tabs[id]?.engine == "chromium")
  }
}
