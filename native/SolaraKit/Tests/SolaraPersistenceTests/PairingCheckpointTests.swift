import Foundation
import GRDB
import Synchronization
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct PairingCheckpointTests {
  @Test func checkpointsActualSavedSettingsAndRefusesEchoedValues() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]), origin: .sync)
    let value = try? writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "dark"], expected: ["v": "dark"], disposition: "applied", links: [:])
    #expect(value == ["v": "dark"])
    #expect(try launch.database.load().settings?["appearance"] == "dark")
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "light"], disposition: "applied", links: [:])
    }
  }

  @Test func checkpointFailureNeverAcknowledgesTheInMemorySettings() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    writer.freeze()
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]), origin: .sync)
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "dark"], expected: ["v": "dark"], disposition: "applied", links: [:])
    }
  }

  @Test func refusesUnknownKeyOrUnprovedLocalChoice() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "password:secret", desired: nil, expected: nil, disposition: "applied", links: [:])
    }
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "dark"], disposition: "local-choice", links: [:])
    }
  }
  @Test func checkpointsProfilesThemesAnglesAndSharingFromTheDatabase() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    var state = launch.state
    let theme: JSONValue = ["color": "blue", "angle": 45, "dark": ["angle": 90]]
    state.profiles["p"] = Profile(id: "p", name: "Work", color: "blue", icon: nil, createdAt: 1, dataId: "owner", theme: theme)
    state.profileOrder = ["p"]
    let store = Store(state: state, memory: launch.memory)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let links: JSONValue = ["p": ["syncId": "remote", "enabled": true]]
    let vectors: [(String, JSONValue)] = [
      ("prof:remote", ["n": "Work", "c": "blue", "i": nil]),
      ("prof:remote", ["n": "Work", "c": "blue", "i": nil, "theme": theme]),
      ("pth:remote", ["theme": theme]),
      ("pth:remote:angle", ["a": 45, "d": 90]),
      ("share:remote", ["owner": "owner"])
    ]
    for (key, value) in vectors {
      #expect((try? writer.pairingCheckpoint(key: key, desired: value, expected: value, disposition: "applied", links: links)) == value)
    }
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "prof:remote", desired: ["n": "Wrong"], expected: ["n": "Wrong"], disposition: "applied", links: links)
    }
  }

  @Test func partialOwnershipCannotProveProfilePersistence() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, scope: .settingsAndDownloads)
    defer { writer.freeze() }
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "prof:remote", desired: nil, expected: nil, disposition: "applied", links: ["p": ["syncId": "remote", "enabled": true]])
    }
  }
  @Test func diskReadbackDisagreementRefusesEvenAfterSuccessfulFlush() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try launch.database.pool.write { db in
      try db.execute(sql: "CREATE TRIGGER alter_pairing_setting AFTER INSERT ON setting WHEN NEW.key = 'appearance' BEGIN UPDATE setting SET value = '\"light\"' WHERE key = 'appearance'; END")
    }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]), origin: .sync)
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "dark"], expected: ["v": "dark"], disposition: "applied", links: [:])
    }
    #expect(try launch.database.load().settings?["appearance"] == "light")
  }

  @Test func localEditDuringDurableBarrierInvalidatesTheCapturedRevision() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]), origin: .sync)
    let edited = Mutex(false)
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        guard event.description.contains("wal_checkpoint(FULL)") else { return }
        let first = edited.withLock { value in let first = !value; value = true; return first }
        if first { _ = try? store.dispatch(Command("updateSettings", [["showFullUrl": true]])) }
      }
    }
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "dark"], expected: ["v": "dark"], disposition: "applied", links: [:])
    }
    #expect(edited.withLock { $0 })
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }

  @Test func preservesDurableLocalChoiceAndRejectsUnsyncedSettings() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect((try? writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "dark"], disposition: "local-choice", links: [:])) == ["v": "dark"])
    let chosen = store.state.settings.values["chosen"] ?? .null
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:chosen", desired: ["v": chosen], expected: ["v": chosen], disposition: "applied", links: [:])
    }
  }
  @Test func settingsOptOutRequiresAuthoritativeDisabledTypeEvidence() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect((try? writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "dark"], disposition: "opt-out", links: [:], settingsOptedOut: true)) == ["v": "dark"])
    #expect(throws: PairingCheckpointFailure.self) {
      try writer.pairingCheckpoint(key: "set:appearance", desired: ["v": "light"], expected: ["v": "dark"], disposition: "opt-out", links: [:])
    }
  }
}
