import Foundation
import GRDB
import SolaraDurability
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct CommittedBaselineTests {
  @Test(arguments: [SQLITE_NOTFOUND, SQLITE_ERROR]) func unavailableDurabilityPreservesRevertedSettingsAfterReload(registration: Int32) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    let setup = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try #require(setup.flush(timeout: 5) == .saved)
    setup.freeze()
    let database = try SolaraDatabase(url: folder.database, sync: DurableSyncHooks(registration: { registration }))
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: try database.load())
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    #expect(writer.flush(timeout: 5).description.contains("unavailable"))
    #expect(try database.load().settings?["appearance"] == "light")
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5).description.contains("unavailable"))
    #expect(try database.load().settings?["appearance"] == "dark")
    writer.freeze()
    writer.queue.sync {}
    try database.close()
    try launch.database.close()
    let reloaded = try open(folder)
    defer { try? reloaded.database.close() }
    #expect(reloaded.state.settings["appearance"] == "dark")
  }

  @Test(arguments: [SQLITE_NOTFOUND, SQLITE_ERROR]) func unavailableDurabilityPreservesRevertedDownloadsAfterReload(registration: Int32) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let original: JSONValue = ["id": "reverted-download", "url": "https://original.example/file.zip", "state": "complete", "profile": ""]
    try store.dispatch(Command("upsertDownload", [original]))
    let setup = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try #require(setup.flush(timeout: 5) == .saved)
    setup.freeze()
    let database = try SolaraDatabase(url: folder.database, sync: DurableSyncHooks(registration: { registration }))
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: try database.load())
    defer { writer.freeze() }
    try store.dispatch(Command("upsertDownload", [["id": "reverted-download", "url": "https://changed.example/file.zip"]]))
    #expect(writer.flush(timeout: 5).description.contains("unavailable"))
    #expect(try database.load().downloads.first?.json["url"] == "https://changed.example/file.zip")
    try store.dispatch(Command("upsertDownload", [original]))
    #expect(writer.flush(timeout: 5).description.contains("unavailable"))
    #expect(try database.load().downloads.first?.json["url"] == original["url"])
    writer.freeze()
    writer.queue.sync {}
    try database.close()
    try launch.database.close()
    let reloaded = try open(folder)
    defer { try? reloaded.database.close() }
    #expect(reloaded.state.downloads.first?.json["url"] == original["url"])
  }

  @Test func checkpointFailureAfterCommitPreservesRevertedWorkspaceAfterReload() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://revert.example/"]])).result?.string)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    try store.dispatch(Command("updateTab", [.string(tab), ["title": "Original"]]))
    let setup = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try #require(setup.flush(timeout: 5) == .saved)
    setup.freeze()
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: try database.load())
    defer { writer.freeze() }
    recorder.state.withLock { $0.failFull = true; $0.failKind = "db" }
    recorder.reset()
    try store.dispatch(Command("updateTab", [.string(tab), ["title": "Changed"]]))
    #expect(writer.flush(timeout: 5).description.contains("fully durable"))
    #expect(recorder.events.contains("full:wal"))
    #expect(recorder.events.suffix(2) == ["full:db", "fsync"])
    let committed = try #require(try database.load().workspace?.tables["tab"]?.payloads[tab])
    #expect(try JSONValue.parse(committed)["title"] == "Changed")
    try store.dispatch(Command("updateTab", [.string(tab), ["title": "Original"]]))
    recorder.state.withLock { $0.failFull = false }
    #expect(writer.flush(timeout: 5) == .saved)
    writer.freeze()
    writer.queue.sync {}
    try database.close()
    try launch.database.close()
    let reloaded = try open(folder)
    defer { try? reloaded.database.close() }
    #expect(reloaded.state.tabs[tab]?.title == "Original")
  }

  @Test func commitErrorAfterWALWritePreservesRevertedSettingsAfterReload() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try #require(writer.flush(timeout: 5) == .saved)
    launch.database.pool.writeWithoutTransaction { db in
      _ = sqlite3_wal_hook(db.sqliteConnection, { _, _, _, _ in SQLITE_IOERR }, nil)
    }
    defer {
      launch.database.pool.writeWithoutTransaction { db in
        _ = sqlite3_wal_autocheckpoint(db.sqliteConnection, 1000)
      }
    }
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    writer.queue.sync {}
    #expect(!writer.errors.isEmpty)
    #expect(try launch.database.load().settings?["appearance"] == "light")
    launch.database.pool.writeWithoutTransaction { db in
      _ = sqlite3_wal_autocheckpoint(db.sqliteConnection, 1000)
    }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    writer.freeze()
    writer.queue.sync {}
    let reloaded = try open(folder)
    defer { try? reloaded.database.close() }
    #expect(reloaded.state.settings["appearance"] == "dark")
  }
}
