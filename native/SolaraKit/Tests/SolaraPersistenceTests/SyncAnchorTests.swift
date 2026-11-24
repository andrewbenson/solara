import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SyncAnchorTests {
  @Test func theAnchorIsSavedWithTheRowsAndReturnedAtLaunch() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor(#"{"journalG":3}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.persisted.syncAnchor == #"{"journalG":3}"#)
    #expect(relaunch.state.settings["appearance"] == "dark")
  }

  @Test func anAnchorSetBeforeASettingIsInTheSameOrAnEarlierTransaction() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor(#"{"journalG":4}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let loaded = try launch.database.load()
    #expect(loaded.settings?["appearance"] == "light")
    #expect(loaded.syncAnchor == #"{"journalG":4}"#, "a setting is never on disk without the anchor noted before it")
  }

  @Test func aKillBeforeTheFlushLosesTheAnchorAndTheSettingTogether() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    #expect(writer.flush(timeout: 5) == .saved)
    writer.freeze()
    writer.setSyncAnchor(#"{"journalG":5}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    let loaded = try launch.database.load()
    #expect(loaded.syncAnchor == nil)
    #expect(loaded.settings?["appearance"] != "dark")
  }

  @Test func anUnchangedAnchorWritesNothing() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor("a")
    #expect(writer.flush(timeout: 5) == .saved)
    let flushes = writer.flushCount
    writer.setSyncAnchor("a")
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.flushCount == flushes)
  }
}

extension SyncAnchorTests {
  @Test func seenOnlyChangePersistsTheNativeAnchorWithoutAStoreMutation() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    #expect(writer.flush(timeout: 5) == .saved)
    let revision = store.rev
    let anchor = #"{"journalG":3,"everSeen":{"devices":["dev9"],"scopes":{"app":{"set:fresh":[0,4]}}}}"#
    writer.setSyncAnchor(anchor)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(store.rev == revision)
    #expect(try launch.database.load().syncAnchor == anchor)
    writer.freeze()
    try launch.database.close()
    let next = try open(folder)
    defer { try? next.database.close() }
    let saved = try JSONValue.parse(try #require(next.persisted.syncAnchor))
    #expect(saved["everSeen"]?["devices"] == ["dev9"])
    #expect(saved["everSeen"]?["scopes"]?["app"]?["set:fresh"] == [0, 4])
  }

  @Test func seenOriginSurvivesQuitAndTwoFreshReopens() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    let revision = store.rev
    writer.setSyncAnchor(#"{"journalG":5,"everSeen":{"devices":["B"],"scopes":{"app":{"set:remembered":[0,5]}}}}"#)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(store.rev == revision)
    #expect(try launch.database.load().syncAnchor != nil)
    writer.freeze()
    try launch.database.close()
    for _ in 0..<2 {
      let next = try open(folder)
      let anchor = try JSONValue.parse(try #require(next.persisted.syncAnchor))
      let origin = try #require(anchor["everSeen"]?["scopes"]?["app"]?["set:remembered"]?.array)
      let devices = try #require(anchor["everSeen"]?["devices"]?.array)
      let index = try #require(origin.first?.number)
      #expect(index == 0)
      #expect(devices[Int(index)] == "B")
      #expect(origin[1] == 5)
      try next.database.close()
    }
  }
}
