import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct PageReportSafeModeTests {
  func narrow(changingSettingsAndDownloads: Bool) throws {
    let checks = SafeWholeFolderTests()
    let folder = try checks.fixture()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let before = try checks.tableBytes(folder)
    let session = contents(folder.session)
    var config = StoreConfig()
    config.safeMode = true
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("page-report-safe"))
    let database = try #require(safe.database)
    let store = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: safe.persisted)
    defer { writer.freeze(); try? database.close() }
    let id = try persistencePage(store)
    store.enqueuePageReport(id: id, report: persistenceNavigation())
    store.enqueuePageReport(id: id, report: persistenceMedia())
    #expect(store.state.tabs[id]?.url == "https://after.example/")
    #expect(store.state.live[id]?.playingAudio == true)
    if changingSettingsAndDownloads {
      try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
      try store.dispatch(Command("upsertDownload", [["id": "safe-report-download", "url": "https://after.example/file", "state": "complete", "profile": ""]]))
    }
    writer.markShadowDirty()
    writer.queue.sync { writer.flushRows(); writer.writeShadow() }
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 5) == .saved)
    let after = try checks.tableBytes(folder)
    #expect(Set(after.keys) == Set(before.keys))
    for table in before.keys where table != "setting" && table != "download" { #expect(after[table] == before[table]) }
    #expect(contents(folder.session) == session)
    if changingSettingsAndDownloads {
      #expect(after["setting"] != before["setting"])
      #expect(after["download"] != before["download"])
      #expect(try database.load().settings?["appearance"] == "dark")
      #expect(try database.load().downloads.contains { $0.id == "safe-report-download" })
    } else {
      #expect(after == before)
    }
  }

  @Test func safeNarrowWriterReportsStayInMemoryAndPreserveSeededWorkspace() throws {
    try narrow(changingSettingsAndDownloads: false)
  }

  @Test func safeNarrowWriterStillPersistsSettingsAndDownloads() throws {
    try narrow(changingSettingsAndDownloads: true)
  }

  @Test func safeNoWriterReportsStayInMemoryAndFlushSkips() throws {
    let checks = SafeWholeFolderTests()
    let folder = try checks.fixture()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let tables = try checks.tableBytes(folder)
    let bytes = contents(folder.session)
    let initial = BrowserState(settings: Settings.hydrated(from: nil))
    var config = StoreConfig()
    config.safeMode = true
    config.persistenceRefusal = "safe writer unavailable"
    let store = Store(state: initial, memory: StoreMemory(ids: IdSource(launch: "safe-no-writer")), config: config)
    let id = try persistencePage(store)
    store.enqueuePageReport(id: id, report: persistenceNavigation())
    store.enqueuePageReport(id: id, report: persistenceMedia())
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 1, writerTimeout: 1) == .safeModeOpenedNoDatabase)
    #expect(store.state.tabs[id]?.url == "https://after.example/")
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(throws: StorePersistenceRefused.self) { try store.dispatch(Command("updateSettings", [["appearance": "dark"]])) }
    #expect(throws: StorePersistenceRefused.self) {
      try store.dispatch(Command("upsertDownload", [["id": "refused-report-download", "url": "https://after.example/file", "state": "complete", "profile": ""]]))
    }
    #expect(try checks.tableBytes(folder) == tables)
    #expect(contents(folder.session) == bytes)
  }
}
