import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SafeProfileEditsTests {
  @Test(arguments: ["name", "color", "icon", "theme", "order"])
  func safeProfileEditIsRefusedAndLeavesNormalLaunchUnchanged(field: String) throws {
    let checks = SafeWholeFolderTests()
    let folder = try checks.fixture()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let seed = try open(folder)
    let seedStore = store(for: seed)
    let seedWriter = PersistenceWriter(store: seedStore, database: seed.database, folder: folder, persisted: seed.persisted)
    try seedStore.dispatch(Command("createProfile", [["name": "Work"]]))
    #expect(seedWriter.flush(timeout: 5) == .saved)
    seedWriter.freeze()
    try seed.database.close()
    let beforeTables = try checks.tableBytes(folder)
    let beforeFiles = try checks.image(folder)
    var config = StoreConfig()
    config.safeMode = true
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe-profile-edit"))
    let database = try #require(safe.database)
    let safeStore = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let writer = PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted)
    let rev = safeStore.rev
    let original = safeStore.state
    let id = try #require(original.profileOrder.first)
    let value: JSONValue = field == "name" ? "Renamed" : field == "color" ? "green" : field == "icon" ? "star" : ["mode": "dark", "stops": [["color": ["r": 0.1, "g": 0.2, "b": 0.3, "a": 1]]]]
    let command = field == "order"
      ? SettingsWrites.reorderProfiles(Array(original.profileOrder.reversed()))
      : SettingsWrites.updateProfile(id, JSONObject([(field, value)]))
    var refusal: String?
    do {
      try safeStore.dispatch(command, origin: .native)
    } catch let error as CommandError {
      refusal = String(describing: error)
    }
    #expect(try #require(refusal) == "Profile edits can't be saved in safe mode while the saved session and launch appearance are kept unchanged. Open Solara normally to edit profiles.")
    #expect(safeStore.state == original)
    #expect(safeStore.rev == rev)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    writer.freeze()
    try database.close()
    let afterTables = try checks.tableBytes(folder)
    let afterFiles = try checks.image(folder)
    #expect(afterFiles.directories == beforeFiles.directories)
    let sidecars: Set<String> = ["solara.sqlite-wal", "solara.sqlite-shm"]
    #expect(afterFiles.files.filter { !sidecars.contains($0.key) } == beforeFiles.files.filter { !sidecars.contains($0.key) })
    #expect(afterTables == beforeTables)
    let normal = try open(folder)
    defer { try? normal.database.close() }
    #expect(normal.report.source == .database)
    #expect(normal.state.profileOrder == original.profileOrder)
    #expect(normal.state.profiles == original.profiles)
  }
}
