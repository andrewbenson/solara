import CryptoKit
import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

func scratchFolder() throws -> DataFolder {
  let url = FileManager.default.temporaryDirectory.appending(path: "solarakit-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return DataFolder(url: url)
}

func write(_ text: String, to url: URL) throws {
  try Data(text.utf8).write(to: url)
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/sessions")

struct FixtureCopyFailed: Error, CustomStringConvertible {
  let description: String
}

func copyFixture(_ name: String, into folder: DataFolder) throws {
  let present = Set(try FileManager.default.contentsOfDirectory(atPath: fixtures.appending(path: name).path))
  guard present.contains("session.json") || name.hasPrefix("no-session") else { throw FixtureCopyFailed(description: "fixture \(name) has no session.json") }
  for file in ["session.json", "downloads.json"] where present.contains(file) {
    let source = fixtures.appending(path: name).appending(path: file)
    let copy = folder.url.appending(path: file)
    try FileManager.default.copyItem(at: source, to: copy)
    guard try Data(contentsOf: copy) == Data(contentsOf: source) else { throw FixtureCopyFailed(description: "\(file) of fixture \(name) didn't copy intact") }
  }
}

let now = Date(timeIntervalSince1970: 1_793_016_000)
func context(_ launch: String = "test") -> LoadContext { LoadContext(memory: StoreMemory(ids: IdSource(launch: launch)), now: now.timeIntervalSince1970 * 1000) }

func open(_ folder: DataFolder) throws -> Launch { try Launcher.open(folder, appVersion: "1.0", now: now, context: context()) }

func store(for launch: Launch) -> Store {
  Store(state: launch.state, memory: launch.memory, checksInvariants: true, clock: { now.timeIntervalSince1970 * 1000 })
}

func document(_ state: BrowserState) -> String { Store(state: state).sessionDocument().json().canonical }

let refusedFixtures: Set<String> = [
  "unparseable-session", "wrong-version", "wrong-shape-window-null", "wrong-shape-profile-string", "refuse-main-window-null", "refuse-main-window-string",
  "refuse-main-window-tabids-string",
]

func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }

func names(in folder: DataFolder) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []).sorted() }

let legacySession = #"{"version":2,"profiles":{},"profileOrder":[],"settings":{"searchEngine":"duckduckgo","batterySaver":false,"futureKey":{"a":1}},"windows":[],"windowOrder":[],"focusedWindowId":null,"tabs":[],"groups":[],"splits":[],"closedTabs":[],"closedWindows":[]}"#

@Suite struct LaunchTests {
  @Test func firstLaunchImportsTheWholeSessionAndRecordsWhatItDid() throws {
    let folder = try scratchFolder()
    try copyFixture("nested-groups-folders-rows", into: folder)
    let launch = try open(folder)
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(launch.state.tabs.count == 10)
    #expect(launch.state.groups.count == 5)
    #expect(try launch.database.meta("workspace") == "1")
    #expect(try launch.database.meta("count_tabs_before") == "10")
    #expect(try launch.database.meta("count_deletedGroups_after") == "1")
    #expect(!FileManager.default.fileExists(atPath: folder.importing.path))
    let source = try Data(contentsOf: folder.session)
    let original = try Data(contentsOf: fixtures.appending(path: "nested-groups-folders-rows/session.json"))
    #expect(source == original)
    #expect(try Data(contentsOf: folder.preNativeSession) == original)
    #expect(!FileManager.default.fileExists(atPath: folder.preNativeDownloads.path))
  }

  @Test func theDownloadsBackupIsTheBytesThatWereImported() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let original = try Data(contentsOf: folder.downloads)
    let launch = try open(folder)
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(try Data(contentsOf: folder.preNativeDownloads) == original)
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: ".downloads.json.pre-native.copying").path))
  }

  func reads(_ folder: DataFolder) throws -> (Launch, FileReads) {
    let reads = FileReads()
    let launch = try FileReads.$current.withValue(reads) { try open(folder) }
    return (launch, reads)
  }

  @Test func eachLaunchReadsSessionJSONOnceAndDownloadsJSONAtMostOnce() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let (first, firstReads) = try reads(folder)
    guard case .imported = first.report.source else { Issue.record("expected an import"); return }
    #expect(firstReads.count("session.json") == 1)
    #expect(firstReads.count("downloads.json") <= 1)
    let store = store(for: first)
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder, persisted: first.persisted)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try first.database.close()
    let (second, secondReads) = try reads(folder)
    #expect(second.report.source == .database)
    #expect(secondReads.count("session.json") == 1)
    #expect(secondReads.count("downloads.json") <= 1)
    try second.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia","chosen":["searchEngine"],"inferred":[]}}"#, to: folder.session)
    let (third, thirdReads) = try reads(folder)
    guard case .imported = third.report.source else { Issue.record("expected a re-import"); return }
    #expect(thirdReads.count("session.json") == 1)
    #expect(thirdReads.count("downloads.json") <= 1)
  }

  @Test func theDatabaseLoadsTheSameWorkspaceAsTheSessionItCameFrom() throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted() where !name.hasPrefix(".") && !refusedFixtures.contains(name) {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      let first = try open(folder)
      try first.database.close()
      let second = try open(folder)
      #expect(second.report.source == .database, "\(name)")
      #expect(document(second.state) == document(first.state), "\(name)")
      try second.database.close()
    }
  }

  func savedNatively(_ fixture: String) throws -> (folder: DataFolder, tabs: Set<String>) {
    let folder = try scratchFolder()
    try copyFixture(fixture, into: folder)
    let first = try open(folder)
    let firstStore = store(for: first)
    let writer = PersistenceWriter(store: firstStore, database: first.database, folder: folder, persisted: first.persisted, clock: { 42 })
    let window = try #require(firstStore.state.windowOrder.first)
    try firstStore.dispatch(Command("newTab", [.string(window), ["url": "https://kept.example/"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try first.database.close()
    return (folder, Set(firstStore.state.tabs.values.map(\.url)))
  }

  func workspaceRows(_ folder: DataFolder) throws -> WorkspaceRows? {
    let database = try SolaraDatabase(url: folder.database)
    defer { try? database.close() }
    return try database.load().workspace
  }

  func safeLaunch(_ folder: DataFolder) throws {
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    #expect(safe.state.tabs.isEmpty && safe.state.windows.isEmpty)
    let safeStore = Store(state: safe.state, memory: safe.memory, checksInvariants: true, clock: { now.timeIntervalSince1970 * 1000 })
    let writer = (safe.database as SolaraDatabase?).map { database in
      PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted, scope: .settingsAndDownloads, clock: { 43 })
    }
    let window = try safeStore.dispatch(Command("createWindow", [["url": "https://safe.example/"]])).result!.string!
    try safeStore.dispatch(Command("newTab", [.string(window), ["url": "https://safe-two.example/"]]))
    try safeStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(!FlushResult.flushing(writer, timeout: 5).isProblem)
    #expect(writer?.errors.isEmpty ?? true)
    try (safe.database as SolaraDatabase?)?.close()
  }

  @Test func aSafeLaunchKeepsTheSessionAndRowsByteForByteForTheNextNormalLaunch() throws {
    let (folder, tabs) = try savedNatively("broken-splits")
    let session = try Data(contentsOf: folder.session)
    let rows = try workspaceRows(folder)
    #expect(rows != nil)
    let before = names(in: folder)
    try safeLaunch(folder)
    #expect(try Data(contentsOf: folder.session) == session)
    #expect(try workspaceRows(folder) == rows)
    let allowed: Set<String> = [folder.downloads.lastPathComponent, folder.importLog.lastPathComponent]
    #expect(names(in: folder).filter { !before.contains($0) && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !allowed.contains($0) } == [])
    let next = try open(folder)
    #expect(next.report.source == .database)
    #expect(Set(next.state.tabs.values.map(\.url)) == tabs)
    #expect(next.state.settings["appearance"] == "dark")
    try next.database.close()
  }

  struct FileSnapshot: Equatable {
    let size: Int
    let sha256: String
  }

  func folderSnapshot(_ folder: DataFolder) throws -> [String: FileSnapshot] {
    let root = folder.url.resolvingSymlinksInPath()
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var snapshot: [String: FileSnapshot] = [:]
    for case let entry as URL in files {
      let file = entry.resolvingSymlinksInPath()
      guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let data = try Data(contentsOf: file)
      #expect(Array(file.pathComponents.prefix(root.pathComponents.count)) == root.pathComponents)
      let relative = file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
      snapshot[relative] = FileSnapshot(size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    return snapshot
  }

  func databaseSnapshot(_ folder: DataFolder) throws -> [String: [String]] {
    var config = Configuration()
    config.readonly = true
    let database = try DatabaseQueue(path: folder.database.path, configuration: config)
    defer { try? database.close() }
    return try database.read { db in
      var snapshot: [String: [String]] = [:]
      snapshot["sqlite_master"] = try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").map { $0.description }
      let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
      for table in tables {
        let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
        snapshot[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(quoted)\"").map { $0.description }.sorted()
      }
      return snapshot
    }
  }

  @Test func aSafeStoreLaunchAndQuitChangeOnlySettingsAndDownloadsAcrossTheWholeDataFolder() throws {
    let (folder, tabs) = try savedNatively("nested-groups-folders-rows")
    defer { try? FileManager.default.removeItem(at: folder.url) }
    for name in [
      "bookmarks.json", "history.json", "bookmarks-cache.json", "launch-look.json", "launch-layout.json", "release-notes.json", "onboarding.json",
      "profiles/custom/Bookmarks", "profiles/custom/History", "profiles/custom/Preferences", "launch-pictures/saved.png", "sync/ledger.json",
      "solara.sqlite.corrupt-2026-01-01", "session.json.pre-reimport-2026-01-01", ".session.json.writing",
    ] {
      let file = folder.url.appending(path: name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try write("saved bytes for \(name)", to: file)
    }
    let beforeTables = try databaseSnapshot(folder)
    let beforeFiles = try folderSnapshot(folder)
    var config = StoreConfig()
    config.safeMode = true
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe-folder"))
    let database = try #require(safe.database)
    let safeStore = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let writer = PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted, scope: .settingsAndDownloads, clock: { 43 })
    #expect(safeStore.state.windows.isEmpty && safeStore.state.tabs.isEmpty)
    try safeStore.dispatch(Command("createWindow", [["url": "https://safe.example/"]]))
    try safeStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try safeStore.dispatch(Command("upsertDownload", [["id": "safe-download", "url": "https://download.example/safe.zip", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    writer.freeze()
    try database.close()
    let afterTables = try databaseSnapshot(folder)
    let afterFiles = try folderSnapshot(folder)
    let mutableFiles: Set<String> = ["solara.sqlite", "solara.sqlite-wal", "solara.sqlite-shm", "downloads.json"]
    #expect(beforeFiles.filter { !mutableFiles.contains($0.key) } == afterFiles.filter { !mutableFiles.contains($0.key) })
    #expect(beforeTables.filter { $0.key != "setting" && $0.key != "download" } == afterTables.filter { $0.key != "setting" && $0.key != "download" })
    #expect(beforeTables["setting"] != afterTables["setting"])
    #expect(beforeTables["download"] != afterTables["download"])
    let next = try open(folder)
    #expect(Set(next.state.tabs.values.map(\.url)) == tabs)
    #expect(next.state.settings["appearance"] == "dark")
    #expect(next.state.downloads.contains { $0.json["url"] == "https://download.example/safe.zip" })
    try next.database.close()
  }

  @Test func aSafeWriterCannotExportWorkspaceOrAdvanceTheSyncAnchorEvenWithTheDefaultScope() throws {
    let (folder, _) = try savedNatively("broken-splits")
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let before = try databaseSnapshot(folder)
    let session = try Data(contentsOf: folder.session)
    var config = StoreConfig()
    config.safeMode = true
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe-scope"))
    let database = try #require(safe.database)
    let safeStore = Store(state: safe.state, memory: safe.memory, config: config)
    let writer = PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted)
    writer.setSyncAnchor("safe-launch-must-not-advance")
    try safeStore.dispatch(Command("createWindow", [["url": "https://temporary.example/"]]))
    try safeStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    writer.freeze()
    try database.close()
    let after = try databaseSnapshot(folder)
    #expect(before.filter { $0.key != "setting" } == after.filter { $0.key != "setting" })
    #expect(try Data(contentsOf: folder.session) == session)
  }

  @Test func aSafeLaunchLeavesAStaleWorkspaceForTheNextNormalLaunchToReimport() throws {
    let (folder, _) = try savedNatively("broken-splits")
    let text = try String(contentsOf: folder.session, encoding: .utf8)
    #expect(text.contains(#""scope":"everything""#))
    try write(text.replacingOccurrences(of: #""scope":"everything""#, with: #""scope":"settingsAndDownloads""#), to: folder.session)
    let session = try Data(contentsOf: folder.session)
    let rows = try workspaceRows(folder)
    try safeLaunch(folder)
    #expect(try Data(contentsOf: folder.session) == session)
    #expect(try workspaceRows(folder) == rows)
    #expect(!names(in: folder).contains { $0.contains("pre-reimport") })
    let next = try open(folder)
    #expect(next.report.source != .database)
    #expect(names(in: folder).contains { $0.contains("pre-reimport") })
    try next.database.close()
  }

  @Test func aSafeLaunchKeepsProfilesWhenSessionIsUnreadableButOpensNoWindows() throws {
    let (folder, _) = try savedNatively("broken-splits")
    let normal = try open(folder)
    let profiles = normal.state.profileOrder
    try normal.database.close()
    try FileManager.default.removeItem(at: folder.session)
    try FileManager.default.createDirectory(at: folder.session, withIntermediateDirectories: false)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    #expect(safe.state.profileOrder == profiles)
    #expect(safe.state.windows.isEmpty && safe.state.tabs.isEmpty && safe.state.closedTabs.isEmpty)
    try (safe.database as SolaraDatabase?)?.close()
  }

  func safeFiles(_ folder: DataFolder) -> [String: String] {
    Dictionary(uniqueKeysWithValues: names(in: folder).map { name in
      (name, contents(folder.url.appending(path: name))?.base64EncodedString() ?? "unreadable")
    })
  }

  @Test(arguments: ["missing", "corrupt", "newer", "olderSchema", "unreadableWorkspace", "unreadableDatabase"])
  func aSafeLaunchNeverRepairsOrWritesAnUnusableDatabase(_ damage: String) throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    try write(legacySession, to: folder.session)
    if damage != "missing" && damage != "corrupt" && damage != "unreadableDatabase" {
      let normal = try open(folder)
      try normal.database.pool.write { db in
        if damage == "newer" { try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
        if damage == "olderSchema" {
          for table in ["profile", "window", "tab", "tab_group", "split", "pin_table", "archive", "workspace"] {
            try db.execute(sql: "DROP TABLE \"\(table)\"")
          }
          try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
          try db.execute(sql: "DELETE FROM meta WHERE key = 'workspace'")
          try db.execute(sql: "UPDATE meta SET value = 'v1' WHERE key = 'schema'")
        }
        if damage == "unreadableWorkspace" { try db.execute(sql: "DROP TABLE profile") }
      }
      try normal.database.close()
      try write(#"{"version":2,"settings":{"searchEngine":"brave"}}"#, to: folder.session)
    }
    if damage == "corrupt" { try write("not sqlite, padding padding padding padding padding padding padding", to: folder.database) }
    if damage == "unreadableDatabase" { try FileManager.default.createDirectory(at: folder.database, withIntermediateDirectories: false) }
    let before = safeFiles(folder)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    let database = safe.database as SolaraDatabase?
    #expect(database == nil, "\(damage) must disable persistence")
    #expect(safe.state.settings["searchEngine"] == "duckduckgo", "\(damage) must prefer readable database settings")
    #expect(safe.state.downloads.count == 2)
    #expect(safe.state.tabs.isEmpty && safe.state.windows.isEmpty)
    let store = Store(state: safe.state, memory: safe.memory)
    let writer = database.map {
      PersistenceWriter(store: store, database: $0, folder: folder, persisted: safe.persisted, scope: .settingsAndDownloads)
    }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try store.dispatch(Command("upsertDownload", [["id": "safe-only", "state": "complete", "profile": ""]]))
    #expect(!FlushResult.flushing(writer, timeout: 5).isProblem)
    try database?.close()
    let unchanged = safeFiles(folder) == before
    #expect(unchanged, "\(damage) changed the data folder")
  }

  @Test func aSafeLaunchSalvagesTheWALWithoutCreatingSidecars() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    var config = Configuration()
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let writer = try DatabaseQueue(path: folder.database.path, configuration: config)
    try writer.write { db in
      try db.execute(sql: #"UPDATE setting SET value = '"ecosia"' WHERE key = 'searchEngine'"#)
      try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
    }
    let database = try Data(contentsOf: folder.database)
    let walURL = URL(fileURLWithPath: folder.database.path + "-wal")
    let wal = try Data(contentsOf: walURL)
    try writer.close()
    try database.write(to: folder.database)
    try wal.write(to: walURL)
    let shmURL = URL(fileURLWithPath: folder.database.path + "-shm")
    if FileManager.default.fileExists(atPath: shmURL.path) { try FileManager.default.removeItem(at: shmURL) }
    #expect(!FileManager.default.fileExists(atPath: folder.database.path + "-shm"))
    let before = safeFiles(folder)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    #expect((safe.database as SolaraDatabase?) == nil)
    #expect(safe.state.settings["searchEngine"] == "ecosia")
    let unchanged = safeFiles(folder) == before
    #expect(unchanged)
  }

  @Test(arguments: [false, true])
  func aSafeLaunchRecoversAHotJournalOnlyInItsSnapshot(_ linked: Bool) throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    let queue = try DatabaseQueue(path: folder.database.path)
    let journalURL = URL(fileURLWithPath: folder.database.path + "-journal")
    var database = Data()
    var journal = Data()
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA journal_mode = DELETE")
      try db.execute(sql: "PRAGMA synchronous = FULL")
      try db.execute(sql: "PRAGMA cache_size = 1")
      try db.execute(sql: "PRAGMA cache_spill = 1")
      try db.execute(sql: "CREATE TABLE journal_spill (payload BLOB)")
      try db.execute(sql: "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100) INSERT INTO journal_spill SELECT zeroblob(8192) FROM n")
      try db.execute(sql: "BEGIN IMMEDIATE")
      try db.execute(sql: "UPDATE setting SET value = ? WHERE key = 'searchEngine'", arguments: [String(repeating: "x", count: 500_000)])
      try db.execute(sql: "UPDATE journal_spill SET payload = randomblob(8192)")
      database = try Data(contentsOf: folder.database)
      journal = try Data(contentsOf: journalURL)
      try db.execute(sql: "ROLLBACK")
    }
    try queue.close()
    try #require(journal.prefix(8) == Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]), "journal header: \(journal.prefix(28).map { String(format: "%02x", $0) }.joined())")
    try database.write(to: folder.database)
    try journal.write(to: journalURL)
    let backing = try scratchFolder()
    if linked {
      for (source, target) in [(folder.database, backing.database), (journalURL, URL(fileURLWithPath: backing.database.path + "-journal"))] {
        try FileManager.default.moveItem(at: source, to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
      }
    }
    let backingBefore = safeFiles(backing)
    try write(#"{"version":2,"settings":{"searchEngine":"brave"}}"#, to: folder.session)
    let before = safeFiles(folder)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    #expect((safe.database as SolaraDatabase?) == nil)
    #expect(safe.state.settings["searchEngine"] == "duckduckgo")
    try (safe.database as SolaraDatabase?)?.close()
    let unchanged = safeFiles(folder) == before
    #expect(unchanged)
    let backingUnchanged = safeFiles(backing) == backingBefore
    #expect(backingUnchanged)
  }

  @Test(arguments: ["damaged", "unreadable", "olderBuild"])
  func aSafeLaunchReadsProfilesButDisablesWritesWhenLegacySourcesCannotBeTrusted(_ sessionKind: String) throws {
    let (folder, _) = try savedNatively("broken-splits")
    let normal = try open(folder)
    let profiles = normal.state.profileOrder
    let settings = normal.state.settings
    try normal.database.close()
    if sessionKind == "unreadable" {
      try FileManager.default.removeItem(at: folder.session)
      try FileManager.default.createDirectory(at: folder.session, withIntermediateDirectories: false)
    } else {
      try write(sessionKind == "damaged" ? "{" : #"{"version":2,"settings":{"searchEngine":"brave"}}"#, to: folder.session)
    }
    let session = contents(folder.session)
    let rows = try workspaceRows(folder)
    let reads = FileReads()
    let safe = try FileReads.$current.withValue(reads) {
      try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    }
    #expect(reads.count("session.json") == 1)
    #expect((safe.database == nil) == (sessionKind != "damaged"))
    #expect(safe.state.settings == settings)
    #expect(safe.state.profileOrder == profiles)
    try (safe.database as SolaraDatabase?)?.close()
    #expect(contents(folder.session) == session)
    #expect(try workspaceRows(folder) == rows)
  }

  @Test(arguments: [false, true])
  func aSafeLaunchWithoutADatabaseIgnoresADamagedSession(_ unreadable: Bool) throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    if unreadable {
      try FileManager.default.removeItem(at: folder.session)
      try FileManager.default.createDirectory(at: folder.session, withIntermediateDirectories: false)
    } else {
      try write("{", to: folder.session)
    }
    let before = safeFiles(folder)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe"))
    #expect((safe.database as SolaraDatabase?) == nil)
    #expect(safe.state.settings == Settings.hydrated(from: nil))
    #expect(safe.state.downloads.count == 2)
    let unchanged = safeFiles(folder) == before
    #expect(unchanged)
  }

  @Test func theWriterKeepsRowsAndTheShadowSessionCurrent() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
    let previous = try #require(store.state.windows[window]?.tabIds.last)
    let added = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://new.example/"]])).result?.string)
    try store.dispatch(Command("createGroup", [[.string(previous), .string(added)], ["name": "G"]]))
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    #expect(shadow["nativeExport"]?["rev"] == JSONValue(store.rev))
    var withoutMarker = shadow.object!
    withoutMarker.removeValue(forKey: "nativeExport")
    #expect(JSONValue.object(withoutMarker).canonical == store.sessionDocument().json().canonical)
    let expected = document(store.state)
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.report.source == .database)
    #expect(document(relaunch.state).count > 0)
    #expect(relaunch.state.tabs.values.contains { $0.url == "https://new.example/" })
    #expect(relaunch.state.groups.values.contains { $0.name == "G" })
    #expect(relaunch.state.settings["appearance"] == "dark")
    let expectedWindows = try JSONValue.parse(expected)["windows"]?.array?.count
    #expect(relaunch.state.windows.count == expectedWindows)
  }

  @Test func closingAndReopeningRowsKeepsTheirOrder() throws {
    let folder = try scratchFolder()
    try copyFixture("perf-seed", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
    let tabs = store.state.windows[window]!.tabIds
    try store.dispatch(Command("closeTabs", [JSONValue(Array(tabs.prefix(3)))]))
    try store.dispatch(Command("reopenClosed", [.string(window)]))
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://late.example/"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let expected = document(store.state)
    let tabOrder = store.state.tabs.keys
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.state.tabs.keys == tabOrder)
    #expect(document(relaunch.state) == expected)
  }

  @Test func anOlderBuildRewritingSessionJSONTriggersAReimportThatKeepsNewerKeys() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    let store = store(for: first)
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder, persisted: first.persisted)
    try store.dispatch(Command("updateSettings", [["onlyNative": true, "searchEngine": "bing"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia","chosen":["searchEngine"],"inferred":[]}}"#, to: folder.session)
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("session.json"))
    #expect(second.report.movedAside.filter { $0.hasPrefix("solara.sqlite.superseded-") }.count == 1)
    #expect(second.state.settings["searchEngine"] == "ecosia")
    #expect(second.state.settings["onlyNative"] == true)
  }

  @Test(arguments: ["session", "downloads", "workspace"])
  func aSafeLaunchRefusesUserWritesWhileADeferredImportIsPending(_ changedFile: String) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    try write(legacySession, to: folder.session)
    try write(#"{"version":2,"downloads":[]}"#, to: folder.downloads)
    try open(folder).database.close()
    if changedFile == "session" {
      try write(legacySession.replacingOccurrences(of: "duckduckgo", with: "brave"), to: folder.session)
    } else if changedFile == "downloads" {
      try write(#"{"version":2,"downloads":[{"id":"older-build","url":"https://older-build.example/file.zip","state":"complete","profile":""}]}"#, to: folder.downloads)
    } else {
      var session = try #require(JSONValue.parse(Data(legacySession.utf8)).object)
      session[Launcher.markerKey] = ["scope": "settingsAndDownloads", "rev": 1, "at": 1]
      try write(JSONValue.object(session).text(), to: folder.session)
    }
    let before = safeFiles(folder)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe-superseded"))
    #expect(safe.database == nil)
    let refusal = "Safe mode could not open the database. Changes to settings and downloads cannot be saved. Open Solara normally to make these changes."
    var config = StoreConfig()
    config.safeMode = true
    if safe.database == nil { config.persistenceRefusal = refusal }
    let alerts = Mutex<[String]>([])
    let store = Store(state: safe.state, memory: safe.memory, config: config, onPersistenceRefusal: { message in alerts.withLock { $0.append(message) } })
    let writer = safe.database.map { PersistenceWriter(store: store, database: $0, folder: folder, persisted: safe.persisted) }
    let state = store.state
    for command in [
      Command("updateSettings", [["searchEngine": "ecosia"]]),
      Command("upsertDownload", [["id": "safe-edit", "state": "complete", "profile": ""]]),
    ] {
      #expect(throws: StorePersistenceRefused.self) { try store.dispatch(command) }
      #expect(store.state == state)
    }
    #expect(alerts.withLock { $0 } == [refusal, refusal])
    #expect(FlushResult.flushing(writer, timeout: 5) == .safeModeOpenedNoDatabase)
    writer?.freeze()
    try safe.database?.close()
    #expect(safeFiles(folder) == before)
    let normal = try open(folder)
    defer { try? normal.database.close() }
    #expect(normal.state.settings["searchEngine"] == .string(changedFile == "session" ? "brave" : "duckduckgo"))
    #expect(!normal.state.downloads.contains { $0.id == "safe-edit" })
    #expect(normal.state.downloads.contains { $0.json["url"] == "https://older-build.example/file.zip" } == (changedFile == "downloads"))
    #expect(try normal.database.load().settings == normal.state.settings.values)
  }

  @Test func aMarkedSessionJSONDoesNotTriggerAReimport() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"},"nativeExport":{"rev":3,"at":1,"scope":"everything"}}"#, to: folder.session)
    let second = try open(folder)
    #expect(second.report.source == .database)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aCorruptDatabaseMovesAsideAndReimports() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try write("this is not sqlite at all, not even close, padding padding padding padding padding padding", to: folder.database)
    let launch = try open(folder)
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(launch.report.movedAside.first?.contains("corrupt") == true)
    #expect(launch.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aDatabaseFromANewerBuildIsLeftAloneAndTheShadowImported() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
    try first.database.close()
    let second = try open(folder)
    #expect(second.report.movedAside.first?.contains("newer") == true)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aPhaseOneADatabaseGainsTheWorkspaceAndKeepsItsSettings() throws {
    let folder = try scratchFolder()
    try copyFixture("restore-session-off", into: folder)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "DELETE FROM meta WHERE key = 'workspace'")
      try db.execute(sql: "UPDATE setting SET value = '\"top\"' WHERE key = 'tabLayout'")
    }
    try first.database.close()
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected the workspace import"); return }
    #expect(reason.contains("workspace"))
    #expect(second.state.settings["tabLayout"] == "top")
    #expect(try second.database.meta("workspace") == "1")
  }

  @Test func restoreSessionOffParksPinsAndClosesWindowsAtEveryLaunch() throws {
    let folder = try scratchFolder()
    try copyFixture("restore-session-off", into: folder)
    let launch = try open(folder)
    #expect(launch.state.windows.isEmpty)
    #expect(launch.state.parkedPins["default"]?.tabs.isEmpty == false)
    #expect(launch.state.closedWindows.count == 2)
  }

  @Test func theDownloadsShadowCarriesTheMarkerAndNoPrivateDownloads() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let launch = try open(folder)
    #expect(launch.state.downloads.map(\.id) == ["saved-0", "saved-1"])
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    try store.dispatch(Command("upsertDownload", [["id": "fresh", "state": "downloading", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let shadow = try JSONValue.parse(Data(contentsOf: folder.downloads))
    #expect(shadow["downloads"]?.array?.map { $0["id"]?.string ?? "" } == ["fresh", "saved-0", "saved-1"])
    #expect(shadow["downloads"]?.array?.first?["state"] == "failed")
    #expect(shadow["nativeExport"] != nil)
  }

  @Test func settingsCommitsAreDurableAndFlushWithoutTheDelay() async throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try await Task.sleep(for: .milliseconds(150))
    #expect(writer.flushCount == 1)
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }

  @Test func aWrongShapedValueCostsOnlyThatValue() throws {
    let refused: Set<String> = ["wrong-shape-window-null", "wrong-shape-profile-string"]
    let wrong = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasPrefix("wrong-shape-") && !refused.contains($0) }.sorted()
    #expect(wrong.count >= 14)
    for name in wrong {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      let launch = try open(folder)
      #expect(launch.state.windows.count == 1, "\(name)")
      #expect(launch.state.tabs.count == 3, "\(name)")
      #expect(launch.state.profiles.count == 2, "\(name)")
      #expect(launch.state.settings["searchEngine"] == "duckduckgo", "\(name)")
      #expect(launch.state.settings["appearance"] == "dark", "\(name)")
      #expect(launch.state.downloads.count == 1, "\(name)")
      #expect(!launch.report.notes.isEmpty, "\(name)")
      try launch.database.close()
    }
  }

  @Test func anUnreadableNestedValueIsKeptAsWritten() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-tab-tilefolder-string", into: folder)
    let launch = try open(folder)
    #expect(launch.state.tabs["p"]?.extra["tileFolder"] == "legacy")
    #expect(document(launch.state).contains(#""tileFolder":"legacy""#))
    try launch.database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    #expect(again.state.tabs["p"]?.extra["tileFolder"] == "legacy")
  }

  @Test func aLaunchThatChangesNothingWritesNoShadowAndKeepsTheOriginals() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-closed-tabs-null", into: folder)
    let session = contents(folder.session)
    let downloads = contents(folder.downloads)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(contents(folder.session) == session)
    #expect(contents(folder.downloads) == downloads)
    #expect(contents(folder.preNativeSession) == session)
    #expect(contents(folder.preNativeDownloads) == downloads)
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(contents(folder.session) != session)
    try launch.database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    #expect(contents(folder.preNativeSession) == session)
    #expect(contents(folder.preNativeDownloads) == downloads)
  }

  @Test func theOriginalsComeBackWhenSessionJSONIsGone() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let first = try open(folder)
    let tabs = first.state.tabs.count
    try first.database.close()
    try FileManager.default.removeItem(at: folder.database)
    try FileManager.default.removeItem(at: folder.session)
    let second = try open(folder)
    #expect(second.state.tabs.count == tabs)
  }

  @Test func anUnreadableSessionIsRefusedAndNothingIsCreated() throws {
    let folder = try scratchFolder()
    try copyFixture("unparseable-session", into: folder)
    #expect(throws: ImportRefused.self) { try open(folder) }
    #expect(!FileManager.default.fileExists(atPath: folder.database.path))
    #expect(String(decoding: contents(folder.importLog) ?? Data(), as: UTF8.self).contains("refused"))
  }

  func filesIn(_ folder: DataFolder) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.url.path) { files[name] = try Data(contentsOf: folder.url.appending(path: name)) }
    return files
  }

  func expectRefusalLeavesFilesAlone(_ folder: DataFolder, scope: PersistenceScope = .everything) throws {
    let before = try filesIn(folder)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.session.path)
    #expect(throws: ImportRefused.self) { try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: scope) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.session.path)
    var after = try filesIn(folder)
    let log = String(decoding: after.removeValue(forKey: folder.importLog.lastPathComponent).map { $0.dropFirst(before[folder.importLog.lastPathComponent]?.count ?? 0) } ?? Data(), as: UTF8.self)
    #expect(after.keys.sorted() == before.keys.filter { $0 != folder.importLog.lastPathComponent }.sorted())
    for (name, data) in after { #expect(before[name] == data, "\(name) changed") }
    #expect(log.contains("session.json exists but could not be read"))
    #expect(!log.contains("no session.json"))
  }

  @Test func aFirstLaunchWithAnUnreadableSessionIsRefusedAndTouchesNothing() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try expectRefusalLeavesFilesAlone(folder)
    #expect(!FileManager.default.fileExists(atPath: folder.database.path))
    #expect(!FileManager.default.fileExists(atPath: folder.preNativeSession.path))
  }

  @Test func anUnreadableSessionNewerThanTheDatabaseIsRefusedAndTouchesNothing() throws {
    for (first, second) in [(PersistenceScope.everything, PersistenceScope.everything), (.settingsAndDownloads, .everything), (.settingsAndDownloads, .settingsAndDownloads)] {
      let folder = try scratchFolder()
      try copyFixture("broken-splits", into: folder)
      try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: first).database.close()
      try write(#"{"version":2,"windows":[],"tabs":[]}"#, to: folder.session)
      try expectRefusalLeavesFilesAlone(folder, scope: second)
    }
  }

  func expectUnreadableDownloadsLeftAlone(_ folder: DataFolder, scope: PersistenceScope = .everything) throws {
    let before = try Data(contentsOf: folder.downloads)
    let hadOriginal = FileManager.default.fileExists(atPath: folder.preNativeDownloads.path)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.downloads.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.downloads.path) }
    let launch = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: scope)
    #expect(launch.report.notes.contains { $0.hasPrefix("downloads.json exists but could not be read") })
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, scope: scope, clock: { 42 })
    try store.dispatch(Command("upsertDownload", [["id": "late", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    try launch.database.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.downloads.path)
    #expect(try Data(contentsOf: folder.downloads) == before)
    #expect(FileManager.default.fileExists(atPath: folder.preNativeDownloads.path) == hadOriginal)
  }

  @Test func aFirstLaunchWithUnreadableDownloadsGoesAheadAndLeavesThemAlone() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try write(#"{"version":2,"downloads":[{"id":"kept","state":"complete","profile":""}]}"#, to: folder.downloads)
    try expectUnreadableDownloadsLeftAlone(folder)
  }

  @Test func unreadableDownloadsNewerThanTheDatabaseAreLeftAloneInEitherScope() throws {
    for scope in [PersistenceScope.everything, .settingsAndDownloads] {
      let folder = try scratchFolder()
      try copyFixture("broken-splits", into: folder)
      try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: scope).database.close()
      try write(#"{"version":2,"downloads":[{"id":"newer","state":"complete","profile":""}]}"#, to: folder.downloads)
      try expectUnreadableDownloadsLeftAlone(folder, scope: scope)
    }
  }

  @Test func anUnreadableShadowOverAGoodDatabaseIsRefusedAndTheDatabaseStillWinsNextTime() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let first = try open(folder)
    let store = store(for: first)
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder, persisted: first.persisted, clock: { 42 })
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(first.report)")
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://only-in-the-database.example/"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try first.database.close()
    try expectRefusalLeavesFilesAlone(folder)
    let next = try open(folder)
    #expect(next.report.source == .database)
    #expect(next.state.tabs.values.contains { $0.url == "https://only-in-the-database.example/" })
  }

  @Test func losingMostWindowsIsRefused() throws {
    let folder = try scratchFolder()
    let session = #"{"version":2,"windows":[null,null,null,{"id":"w1","profileId":"default","incognito":false,"tabIds":["a"],"activeTabIds":{"default":"a"},"sidebarOpen":true,"createdAt":1}],"tabs":[{"id":"a","windowId":"w1","profileId":"default","url":"https://a/","title":"","pinned":false,"muted":false,"zoom":1,"createdAt":1,"lastActiveAt":1}]}"#
    try write(session, to: folder.session)
    #expect(throws: ImportRefused.self) { try open(folder) }
  }

  @Test func anOrphanedWALIsMovedAsideBeforeTheImportLandsOnItsPath() throws {
    let folder = try scratchFolder()
    var config = Configuration()
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let old = try DatabaseQueue(path: folder.database.path, configuration: config)
    try old.write { db in
      try db.execute(sql: "CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT)")
      for i in 0..<200 { try db.execute(sql: "INSERT INTO setting VALUES (?, ?)", arguments: ["old\(i)", String(repeating: "x", count: 500)]) }
    }
    let wal = try Data(contentsOf: URL(fileURLWithPath: folder.database.path + "-wal"))
    #expect(wal.count > 0)
    try old.close()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: folder.database.path + suffix) }
    try wal.write(to: URL(fileURLWithPath: folder.database.path + "-wal"))
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    #expect(launch.state.settings["searchEngine"] == "duckduckgo")
    #expect(try launch.database.meta("workspace") == "1")
    let oldRows = try launch.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM setting WHERE key LIKE 'old%'") }
    #expect(oldRows == 0)
    #expect(names(in: folder).contains { $0.hasPrefix("solara.sqlite-wal.orphan-") })
  }

  @Test func movingADatabaseAsideTakesItsSidecarsAlong() throws {
    let folder = try scratchFolder()
    try write("main", to: folder.database)
    try write("wal", to: URL(fileURLWithPath: folder.database.path + "-wal"))
    try write("shm", to: URL(fileURLWithPath: folder.database.path + "-shm"))
    let name = try Launcher.moveAside(folder.database, label: "corrupt", now: now)
    #expect(names(in: folder) == [name, name + "-shm", name + "-wal"].sorted())
  }

  @Test func anUnreadableSettingRowIsSkippedNotFatal() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    let broken = try first.database.pool.write { db -> String in
      let key = try String.fetchOne(db, sql: "SELECT key FROM setting WHERE key != 'searchEngine' ORDER BY position LIMIT 1")!
      try db.execute(sql: "UPDATE setting SET value = '{' WHERE key = ?", arguments: [key])
      return key
    }
    try first.database.close()
    let second = try open(folder)
    #expect(second.report.source == .database)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
    #expect(second.report.notes.contains("skipped unreadable setting \(broken)"))
  }

  @Test func aDatabaseThatCannotBeLoadedIsMovedAsideAndReimported() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "DROP TABLE download")
    }
    try first.database.close()
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("could not be read"))
    #expect(second.report.movedAside.first?.contains("unreadable") == true)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func theWriterStartsFromWhatIsOnDiskNotFromTheStore() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try store.dispatch(Command("upsertDownload", [["id": "early", "state": "complete", "profile": ""]]))
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 5) == .saved)
    let stored = try launch.database.load()
    #expect(stored.settings?["appearance"] == "dark")
    #expect(stored.downloads.map(\.id) == ["early"])
  }

  @Test func aSupersededReimportCarriesTheDocuments() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in try db.execute(sql: "INSERT INTO document (name, value) VALUES ('onboarding', '{\"done\":true}')") }
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"}}"#, to: folder.session)
    let second = try open(folder)
    guard case .imported = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(try second.database.load().documents["onboarding"] == #"{"done":true}"#)
  }

  @Test func onlyTheLastFewMovedAsideCopiesAreKept() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    for day in 1...6 {
      let name = "solara.sqlite.superseded-2026-10-0\(day)T000000"
      try write("x", to: folder.url.appending(path: name))
      try write("x", to: folder.url.appending(path: name + "-wal"))
    }
    let launch = try open(folder)
    try launch.database.close()
    let kept = names(in: folder).filter { $0.hasPrefix("solara.sqlite.superseded-") }
    #expect(kept == ["04", "05", "06"].flatMap { ["solara.sqlite.superseded-2026-10-\($0)T000000", "solara.sqlite.superseded-2026-10-\($0)T000000-wal"] }.sorted())
    #expect(FileManager.default.fileExists(atPath: folder.preNativeSession.path))
  }

  @Test func aPhaseOneADatabaseKeepsItsOwnDownloads() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "DELETE FROM meta WHERE key = 'workspace'")
      try db.execute(sql: "DELETE FROM download")
      try db.execute(sql: #"INSERT INTO download (id, position, payload) VALUES ('only-in-db', 0, '{"id":"only-in-db","url":"https://only-in-db/","state":"complete","profile":""}')"#)
    }
    try first.database.close()
    let second = try open(folder)
    #expect(second.state.downloads.map { $0.json["url"] } == ["https://only-in-db/"])
  }

  @Test func unknownFieldsAndAbsentKeysSurviveTheDatabase() throws {
    let folder = try scratchFolder()
    try copyFixture("absent-and-unknown-fields", into: folder)
    try open(folder).database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    let doc = try JSONValue.parse(document(again.state))
    let tab = doc["tabs"]?.array?.first { $0["id"] == "a" }?.object
    #expect(tab?.contains("customIcon") == false)
    #expect(tab?.contains("openerId") == false)
    #expect(doc["windows"]?.array?.first?["extraWindowKey"] == true)
  }

  @Test func theQuitFlushFitsItsDeadlineOnALargeSession() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("createWindow", [[:]]))
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
    for i in 0..<2000 { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://site\(i % 50).example/\(i)"), "background": true]])) }
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 30) == .saved)
    try store.dispatch(Command("updateTab", [.string(store.state.windows[window]!.tabIds[5]), ["title": "changed"]]))
    let started = Date()
    let cpuSeconds = writer.queue.sync {
      let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      writer.writeEverythingDurably()
      return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1_000_000_000
    }
    let seconds = Date().timeIntervalSince(started)
    print("quit flush of \(store.state.tabs.count) tabs took \(Int(seconds * 1000)) ms, \(Int(cpuSeconds * 1000)) ms of CPU")
    #expect(writer.errors.isEmpty)
    #expect(try launch.database.meta("rev") == String(store.rev))
    #expect(cpuSeconds < 0.3)
    #expect(seconds < 5)
  }

  @Test func phaseOneAOwnsOnlySettingsAndDownloadsAndNeverWritesSessionJSON() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let session = contents(folder.session)
    let launch = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    #expect(launch.state.tabs.isEmpty)
    #expect(launch.state.windows.isEmpty)
    #expect(launch.state.downloads.count == 2)
    #expect(try launch.database.meta("workspace") == nil)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, scope: .settingsAndDownloads, clock: { 42 })
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try store.dispatch(Command("upsertDownload", [["id": "fresh", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(contents(folder.session) == session)
    let shadow = try JSONValue.parse(contents(folder.downloads) ?? Data())
    #expect(shadow["nativeExport"] != nil)
    #expect(shadow["downloads"]?.array?.count == 3)
    try launch.database.close()
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    #expect(again.report.source == .database)
    #expect(again.state.settings["appearance"] == "dark")
    #expect(again.state.downloads.count == 3)
    #expect(again.state.tabs.isEmpty)
    try again.database.close()
    let phaseOneB = try open(folder)
    guard case .imported(let reason) = phaseOneB.report.source else { Issue.record("expected the workspace import"); return }
    #expect(reason.contains("workspace"))
    #expect(phaseOneB.state.settings["appearance"] == "dark")
    #expect(!phaseOneB.state.tabs.isEmpty)
  }

  @Test func aRunWithoutTheNativeStoreLooksLikeAnOlderBuildAndKeepsItsSession() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    let fallbackRun = #"{"version":2,"settings":{"searchEngine":"brave","chosen":["searchEngine"],"inferred":[]}}"#
    try write(fallbackRun, to: folder.session)
    let next = try open(folder)
    guard case .imported = next.report.source else { Issue.record("expected a re-import"); return }
    #expect(next.state.settings["searchEngine"] == "brave")
    let copies = names(in: folder).filter { $0.hasPrefix("session.json.pre-reimport-") }
    #expect(copies.count == 1)
    #expect(contents(folder.url.appending(path: copies[0])) == Data(fallbackRun.utf8))
  }

  @Test func aBusyDatabaseFailsTheLaunchWithoutMovingAnythingAside() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    for day in 1...5 { try write("x", to: folder.url.appending(path: "solara.sqlite.unreadable-2026-10-0\(day)T000000")) }
    var unsafe = Configuration()
    unsafe.allowsUnsafeTransactions = true
    let holder = try DatabaseQueue(path: folder.database.path, configuration: unsafe)
    try holder.inDatabase { db in try db.execute(sql: "BEGIN EXCLUSIVE") }
    #expect(throws: DatabaseError.self) { try open(folder) }
    try holder.inDatabase { db in try db.execute(sql: "ROLLBACK") }
    try holder.close()
    #expect(FileManager.default.fileExists(atPath: folder.database.path))
    #expect(names(in: folder).filter { $0.hasPrefix("solara.sqlite.unreadable-") }.count == 5)
    let launch = try open(folder)
    #expect(launch.report.source == .database)
    #expect(names(in: folder).filter { $0.hasPrefix("solara.sqlite.unreadable-") }.count == 3)
  }

  @Test func aWrongTypedScalarIsKeptAsWrittenThroughTheDatabase() throws {
    for (name, expected) in [
      ("scalar-zoom-string", #""zoom":"1.5""#), ("scalar-created-string", #""createdAt":"1700000000000""#),
      ("scalar-title-null", #""title":null"#), ("scalar-frame-strings", #""frame":["0",0,100,100]"#),
    ] {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      try open(folder).database.close()
      let again = try open(folder)
      #expect(again.report.source == .database, "\(name)")
      #expect(document(again.state).contains(expected), "\(name)")
    }
    let folder = try scratchFolder()
    try copyFixture("scalar-title-absent", into: folder)
    try open(folder).database.close()
    let doc = try JSONValue.parse(document(try open(folder).state))
    #expect(doc["tabs"]?.array?.first?.object?.contains("title") == false)
  }

  @Test func childRowsOfAnUnreadableWindowStayInPlace() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let first = try open(folder)
    let window = try #require(first.state.windowOrder.first, "the launch came back with no windows: \(first.report)")
    let tabs = first.state.windows[window]!.tabIds
    try first.database.pool.write { db in try db.execute(sql: #"UPDATE "window" SET payload = 'not json' WHERE id = ?"#, arguments: [window]) }
    try first.database.close()
    let second = try open(folder)
    let store = store(for: second)
    let writer = PersistenceWriter(store: store, database: second.database, folder: folder, persisted: second.persisted, clock: { 42 })
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let kept = try second.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE window_id = ?", arguments: [window]) }
    #expect(kept == tabs.count)
  }

  @Test func theOriginalsAreNotReadOnceADatabaseHasExisted() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try open(folder).database.close()
    try FileManager.default.removeItem(at: folder.session)
    try write("not sqlite, not even close, padding padding padding padding padding padding padding", to: folder.database)
    let launch = try open(folder)
    #expect(launch.state.tabs.isEmpty)
  }

  @Test func archivesAndSettingsCountTowardARefusal() throws {
    let nulls = #"{"version":2,"closedTabs":[null,null,null,{"kind":"tab","id":"c","tab":{"url":"https://c/"},"windowId":"w","index":0,"closedAt":1}]}"#
    let folder = try scratchFolder()
    try write(nulls, to: folder.session)
    #expect(throws: ImportRefused.self) { try open(folder) }
    let other = try scratchFolder()
    try write(#"{"version":2,"settings":"dark"}"#, to: other.session)
    #expect(throws: ImportRefused.self) { try open(other) }
  }

  @Test func aClosedWindowWithAnUnreadableTabIsDroppedWhole() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-closed-window-tab-number", into: folder)
    let launch = try open(folder)
    #expect(launch.state.closedWindows.isEmpty)
  }

  @Test func onlyOneProcessHoldsTheDataFolder() throws {
    let folder = try scratchFolder()
    var first = try FolderLock.acquire(folder)
    #expect(first != nil)
    #expect(FolderLock.holder(folder) == getpid())
    let path = folder.url.appending(path: FolderLock.fileName).path
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    other.arguments = ["-I", "-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept OSError:\n sys.exit(3)\nsys.exit(0)", path]
    try other.run()
    other.waitUntilExit()
    #expect(other.terminationStatus == 3)
    first = nil
    #expect(try FolderLock.acquire(folder) != nil)
  }

  @Test func unreadableWindowsOrProfilesRefuseTheImport() throws {
    for name in ["refuse-main-window-null", "refuse-main-window-string", "refuse-main-window-tabids-string", "wrong-shape-window-null", "wrong-shape-profile-string"] {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      #expect(throws: ImportRefused.self, "\(name)") { try open(folder) }
      #expect(!FileManager.default.fileExists(atPath: folder.database.path), "\(name)")
    }
  }

  @Test func aPermissionErrorFailsTheLaunchAndKeepsTheDatabase() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"brave"}}"#, to: folder.session)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }
    #expect(throws: (any Error).self) { try open(folder) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path)
    #expect(FileManager.default.fileExists(atPath: folder.database.path))
    #expect(!names(in: folder).contains { $0.hasPrefix("solara.sqlite.unreadable-") })
  }

  @Test func aNumericFlagReadsAsJSWouldAndIsWrittenBackAsIs() throws {
    let folder = try scratchFolder()
    try copyFixture("scalar-sidebar-number", into: folder)
    let launch = try open(folder)
    #expect(launch.state.windows.values.first?.sidebarOpen == true)
    #expect(document(launch.state).contains(#""sidebarOpen":1"#))
  }

  @Test func aWindowsOrTabsValueThatIsNoListIsRefused() throws {
    for session in [#"{"version":2,"windows":"w1","tabs":[]}"#, #"{"version":2,"windows":[],"tabs":"a"}"#] {
      let folder = try scratchFolder()
      try write(session, to: folder.session)
      #expect(throws: ImportRefused.self) { try open(folder) }
    }
  }

  @Test func aSettingsAndDownloadsRunBetweenTwoFullRunsKeepsItsWorkspaceChanges() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let full = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    let fullStore = store(for: full)
    let writer = PersistenceWriter(store: fullStore, database: full.database, folder: folder, persisted: full.persisted, scope: .everything, clock: { 42 })
    try fullStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try full.database.close()
    let narrow = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    try narrow.database.close()
    var session = try JSONValue.parse(contents(folder.session) ?? Data()).object!
    var tabs = session["tabs"]!.array!
    var added = tabs[0].object!
    added["id"] = "added-in-1a"
    added["url"] = "https://added-in-1a.example/"
    tabs.append(.object(added))
    session["tabs"] = .array(tabs)
    var windows = session["windows"]!.array!
    var window = windows[0].object!
    window["tabIds"] = .array(window["tabIds"]!.array! + ["added-in-1a"])
    added["windowId"] = window["id"]!
    tabs[tabs.count - 1] = .object(added)
    session["tabs"] = .array(tabs)
    windows[0] = .object(window)
    session["windows"] = .array(windows)
    session["nativeExport"] = ["rev": 3, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    guard case .imported(let reason) = again.report.source else { Issue.record("expected the workspace re-import"); return }
    #expect(reason.contains("settings-and-downloads"))
    #expect(again.state.tabs["added-in-1a"] != nil)
    #expect(again.state.settings["appearance"] == "dark")
    try again.database.close()
    let steady = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    #expect(steady.report.source == .database)
    #expect(steady.state.tabs["added-in-1a"] != nil)
  }

  @Test func aFirstFullImportFromAOneAMarkedSessionIsNotRepeated() throws {
    let folder = try scratchFolder()
    var session = try JSONValue.parse(Data(contentsOf: fixtures.appending(path: "broken-splits/session.json"))).object!
    session["nativeExport"] = ["rev": 2, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything).database.close()
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    #expect(again.report.source == .database)
  }

  @Test func aWorkspaceReimportKeepsACopyOfTheDatabaseFirst() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try open(folder).database.close()
    var session = try JSONValue.parse(contents(folder.session) ?? Data()).object!
    session["nativeExport"] = ["rev": 9, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    let again = try open(folder)
    #expect(names(in: folder).contains { $0.hasPrefix("solara.sqlite.pre-reimport-") })
    try again.database.close()
  }

  @Test func aFrozenWriterWritesNothing() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let session = contents(folder.session)
    writer.freeze()
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .failed("persistence is frozen"))
    #expect(contents(folder.session) == session)
    #expect(try launch.database.load().settings?["appearance"] != "dark")
  }
}
