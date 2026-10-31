import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

func persistencePage(_ store: Store) throws -> String {
  let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://before.example/"]])).result?.string)
  let id = try #require(store.state.windows[window]?.tabIds.first)
  let created: JSONValue = ["type": "created", "generation": "persistence-G", "engine": "chromium",
    "navigationSeq": store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
    "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null]
  try store.dispatch(Command("pageReport", [.string(id), created]))
  return id
}

func persistenceNavigation(_ url: String = "https://after.example/") -> JSONValue {
  ["type": "navigation", "generation": "persistence-G", "url": .string(url), "title": "Final title",
    "isLoading": false, "canGoBack": true, "canGoForward": false, "themeColor": "#123456"]
}

func persistenceMedia(_ playing: Bool = true) -> JSONValue {
  ["type": "media", "generation": "persistence-G", "playing": .bool(playing)]
}

@Suite struct LivePersistenceTests {
  @Test func liveOnlyReportsNeverScheduleOrChangePersistentDocuments() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let id = try persistencePage(store)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    let rows = try launch.database.load().workspace
    let session = contents(folder.session)
    let count = writer.flushCount
    let document = store.sessionDocument().json()
    let reports: [JSONValue] = [persistenceMedia(), ["type": "discarded", "generation": "persistence-G", "url": "https://before.example/"],
      ["type": "ready", "generation": "persistence-G", "browserId": 9], persistenceMedia()]
    for report in reports {
      try store.dispatch(Command("pageReport", [.string(id), report]))
    }
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(writer.pending.withLock { !$0.rows && !$0.shadow && !$0.rowsScheduled && !$0.shadowScheduled })
    #expect(store.sessionDocument().json() == document)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try launch.database.load().workspace == rows)
    #expect(contents(folder.session) == session)
    #expect(writer.flushCount == count)
  }

  @Test func reloadedSessionStartsWithIdleLiveFacts() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let id = try persistencePage(store)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    #expect(writer.flush(timeout: 5) == .saved)
    try store.dispatch(Command("pageReport", [.string(id), persistenceMedia()]))
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 5) == .saved)
    writer.freeze()
    try launch.database.close()
    let reopened = try open(folder)
    defer { try? reopened.database.close() }
    let reloaded = Store(state: reopened.state, memory: reopened.memory, checksInvariants: true)
    #expect(reloaded.state.tabs[id]?.url == "https://before.example/")
    #expect(reloaded.state.live[id] == PageLiveFacts())
    #expect(reloaded.pageFacts(id) == nil)
    #expect(reloaded.livePages().isEmpty)
    #expect(reloaded.registerKeepAliveRuntime() == 1)
  }

  @Test func mixedNavigationPersistsURLTitleButNeverLive() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let id = try persistencePage(store)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try store.dispatch(Command("pageReport", [.string(id), persistenceNavigation()]))
    try store.dispatch(Command("pageReport", [.string(id), persistenceMedia()]))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(Command("pageReport", [.string(id), ["type": "latch", "generation": "persistence-G", "eventSeq": 7]]))
    try store.dispatch(Command("pageReport", [.string(id), ["type": "keepAlive", "generation": "persistence-G", "epoch": JSONValue(epoch), "seq": 1, "handled": 7,
      "keep": ["capturing": false, "newTabShown": false, "pip": true, "displayRequest": false, "media": "none"],
      "reveal": ["fullscreen": false, "crashed": false, "unresponsive": false, "scrolledDown": false, "sharing": false]]]))
    #expect(store.pageFacts(id)?.latchedThrough == 7)
    #expect(store.pageFacts(id)?.keepAlive?.seq == 1)
    #expect(epoch > 0)
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    let persisted = try #require(try launch.database.load().sessionJSON())
    let row = try #require(persisted["tabs"]?.array?.first { $0["id"]?.string == id })
    #expect(row["url"] == "https://after.example/")
    #expect(row["title"] == "Final title")
    let session = try JSONValue.parse(Data(contentsOf: folder.session))
    for value in [persisted, session, store.sessionDocument().json()] {
      #expect(value["live"] == nil)
      for key in ["pages", "pageProducerFence", "feedWatermark", "keepAliveEpoch", "keepAlive", "latchedThrough"] { #expect(value[key] == nil) }
    }
    let schema = try launch.database.pool.read { db in try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL").joined(separator: "\n") }
    for name in ["playingAudio", "themeColor", "keepAlive", "pageProducerFence", "feedWatermark", "latchedThrough"] { #expect(!schema.contains(name)) }
    writer.freeze()
    try launch.database.close()
    let reopened = try open(folder)
    defer { try? reopened.database.close() }
    let reloaded = Store(state: reopened.state, memory: reopened.memory, checksInvariants: true)
    #expect(reloaded.state.tabs[id]?.url == "https://after.example/")
    #expect(reloaded.state.tabs[id]?.title == "Final title")
    #expect(reloaded.state.live[id] == PageLiveFacts())
    #expect(reloaded.pageFacts(id) == nil)
    #expect(reloaded.livePages().isEmpty)
    let replayed = Store(state: store.state, memory: StoreMemory(replayJSON: [
      "pages": [id: ["generation": "persistence-G", "ready": ["browserId": 9], "newestEventSeq": 7,
        "latchedThrough": 7, "modelSerial": 99, "keepAlive": ["epoch": 77, "seq": 1, "handled": 7]]],
      "currentEpoch": 77, "nextPageModelSerial": 100,
      "pageProducerFence": [id: ["generation": "persistence-G", "retired": false]],
      "feedWatermark": [id: ["epoch": 77, "generation": "persistence-G", "seq": 1]],
    ]))
    #expect(replayed.livePages().isEmpty)
    #expect(replayed.registerKeepAliveRuntime() == 1)
  }
}
