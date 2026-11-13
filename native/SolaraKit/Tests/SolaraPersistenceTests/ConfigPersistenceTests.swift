import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct ConfigPersistenceTests {
  static let fileLook: JSONValue = ["stops": [], "mode": "dark", "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1]

  static func contents() -> ConfigContents {
    var contents = ConfigContents()
    contents.settings = ["appearance": "dark", "sidebarWidth": 333]
    contents.theme = ConfigTheme(name: "ocean", look: fileLook)
    return contents
  }

  @Test func fileValuesNeverReachTheDatabase() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    try store.applyConfig(Self.contents(), source: "config.json")
    try store.dispatch(Command("updateSettings", [["showFullUrl": true]]))
    #expect(store.state.settings["sidebarWidth"] == 333)
    #expect(writer.flush(timeout: 5) == .saved)
    let saved = try launch.database.load()
    #expect(saved.settings?["appearance"] == "light")
    #expect(saved.settings?["sidebarWidth"] == 190)
    #expect(saved.settings?["showFullUrl"] == true)
    #expect(store.sessionDocument().settings["sidebarWidth"] == 190)
    for profile in store.sessionDocument().profiles.values { #expect(profile["theme"] != Self.fileLook) }
  }

  @Test func theOwnValueWrittenUnderTheFileIsSaved() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.applyConfig(Self.contents(), source: "config.json")
    try store.dispatch(Command("updateSettings", [["appearance": "auto"]]), origin: .sync)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try launch.database.load().settings?["appearance"] == "auto")
    #expect(store.state.settings["appearance"] == "dark")
  }

  @Test func pairingCheckpointsCompareTheUsersOwnValues() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.applyConfig(Self.contents(), source: "config.json")
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]), origin: .sync)
    let value = try? writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "light"], disposition: "applied", links: [:])
    #expect(value == ["v": "light"])
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "dark"], expected: ["v": "dark"], disposition: "applied", links: [:])
    }
  }
}
