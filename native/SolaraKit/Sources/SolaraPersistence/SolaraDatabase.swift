import Foundation
import GRDB
import SolaraModel
import SolaraStore
import SolaraDurability

public enum OpenFailure: Error, Equatable {
  case corrupt(String)
  case newerSchema
}

public final class SolaraDatabase: Sendable {
  public let pool: any DatabaseWriter
  public let url: URL
  let sync: DurableSync

  public struct DurabilityToken: Equatable, Sendable {
    let writes: Int64
    let version: Int64
  }

  static func durabilityToken(_ db: Database, version: Int64? = nil) throws -> DurabilityToken {
    var writes: Int64 = 0
    guard sd_generation(db.sqliteConnection, &writes) == SQLITE_OK else {
      throw DatabaseError(resultCode: .SQLITE_IOERR, message: "durable SQLite generation is unavailable")
    }
    return DurabilityToken(writes: writes, version: try version ?? Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0)
  }

  func durabilityToken() throws -> DurabilityToken {
    try pool.writeWithoutTransaction { try Self.durabilityToken($0) }
  }

  static func configuration() -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA fullfsync = ON")
      try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
    }
    return config
  }

  public convenience init(url: URL) throws {
    try self.init(url: url, sync: DurableSyncHooks())
  }

  init(url: URL, sync hooks: DurableSyncHooks) throws {
    self.url = url
    sync = DurableSync(hooks: hooks)
    pool = try DatabasePool(path: sync.path(url), configuration: Self.configuration())
    let quick = try pool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
    guard quick == ["ok"] else { throw OpenFailure.corrupt(quick.joined(separator: "; ")) }
    let migrator = Schema.migrator
    if try pool.read({ try migrator.hasBeenSuperseded($0) }) { throw OpenFailure.newerSchema }
    try migrator.migrate(pool)
    try pool.write { db in try Rows.setMeta(db, "schema", Schema.migrationNames.last!) }
  }

  init(existing url: URL, sync hooks: DurableSyncHooks = DurableSyncHooks()) throws {
    self.url = url
    sync = DurableSync(hooks: hooks)
    pool = try DatabaseQueue(path: sync.path(url, existing: true), configuration: Self.configuration())
    try pool.read { db in try Self.checkCurrent(db) }
  }

  static func checkCurrent(_ db: Database) throws {
    let quick = try String.fetchAll(db, sql: "PRAGMA quick_check")
    guard quick == ["ok"] else { throw OpenFailure.corrupt(quick.joined(separator: "; ")) }
    guard try Schema.migrator.appliedIdentifiers(db) == Set(Schema.migrationNames) else { throw OpenFailure.newerSchema }
  }

  @discardableResult
  public func write(durable: Bool, _ body: (Database) throws -> Void) throws -> DurabilityToken? {
    try write(durable: durable, onCommit: {}, body)
  }

  @discardableResult
  func write(durable: Bool, onCommit: () -> Void, _ body: (Database) throws -> Void) throws -> DurabilityToken? {
    try pool.writeWithoutTransaction { db in
      guard durable else {
        try db.inTransaction { try body(db); return .commit }
        onCommit()
        return nil
      }
      guard sync.available else {
        try db.inTransaction { try body(db); return .commit }
        onCommit()
        throw sync.unavailable()
      }
      let version = try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0
      try db.execute(sql: "PRAGMA synchronous = FULL")
      var failure: (any Error)?
      do {
        try sync.run(db) {
          try db.inTransaction { try body(db); return .commit }
          onCommit()
          let checkpoint = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(FULL)")
          guard let checkpoint, checkpoint[0] as Int == 0,
            checkpoint[1] as Int == checkpoint[2] as Int else {
            throw DatabaseError(resultCode: .SQLITE_BUSY, message: "durable WAL checkpoint did not complete")
          }
        }
      } catch { failure = error }
      do { try db.execute(sql: "PRAGMA synchronous = NORMAL") }
      catch {
        DurableSync.logger.error("restoring SQLite NORMAL failed: \(String(describing: error), privacy: .public)")
        if let previous = failure {
          throw DatabaseError(resultCode: .SQLITE_IOERR, message: "\(previous); restoring NORMAL: \(error)")
        }
        throw error
      }
      if let failure { throw failure }
      return try Self.durabilityToken(db, version: version)
    }
  }

  public func close() throws {
    try pool.close()
  }

  public func load() throws -> PersistedState {
    try pool.read { db in try Rows.load(db) }
  }

  public func meta(_ key: String) throws -> String? {
    try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
  }

  public func setMeta(_ values: [String: String]) throws {
    try pool.write { db in for (key, value) in values.sorted(by: { $0.key < $1.key }) { try Rows.setMeta(db, key, value) } }
  }

  public static func create(at url: URL, writing persisted: PersistedState, meta: [String: String]) throws {
    let queue = try DatabaseQueue(path: url.path, configuration: configuration())
    try Schema.migrator.migrate(queue)
    try queue.write { db in
      try Rows.setMeta(db, "schema", Schema.migrationNames.last!)
      for (key, value) in meta.sorted(by: { $0.key < $1.key }) { try Rows.setMeta(db, key, value) }
      try Rows.writeSettings(db, persisted.settings)
      try Rows.writeDownloads(db, persisted.downloads)
      try Rows.writeDocuments(db, persisted.documents)
      if let rows = persisted.workspace { try Rows.writeWorkspace(db, rows, previous: nil) }
    }
    try queue.close()
  }
}

public struct PersistedState: Sendable, Equatable {
  public var settings: JSONObject?
  public var downloads: [Download]
  public var workspace: WorkspaceRows?
  public var documents: JSMap<String>
  public var notes: [String]
  public var keepsDownloadsFile = false
  public var syncAnchor: String?

  public init(
    settings: JSONObject?, downloads: [Download], workspace: WorkspaceRows? = nil, documents: JSMap<String> = JSMap(), notes: [String] = [],
    syncAnchor: String? = nil
  ) {
    self.settings = settings
    self.downloads = downloads
    self.workspace = workspace
    self.documents = documents
    self.notes = notes
    self.syncAnchor = syncAnchor
  }

  public func sessionJSON() -> JSONValue? {
    guard let workspace else { return nil }
    var session = workspace.document()
    if let settings { session["settings"] = .object(settings) }
    return .object(session)
  }

  public var downloadsJSON: JSONValue {
    ["version": 2, "downloads": .array(downloads.map { .object($0.json) })]
  }
}

public struct KeyedRows: Sendable, Equatable {
  public var ids: [String] = []
  public var payloads: [String: String] = [:]
  public var columns: [String: [String: DatabaseValueConvertibleBox]] = [:]
}

public struct DatabaseValueConvertibleBox: Sendable, Equatable {
  public let text: String?
  public let int: Int?

  public static func text(_ value: String) -> DatabaseValueConvertibleBox { .init(text: value, int: nil) }
  public static func int(_ value: Int) -> DatabaseValueConvertibleBox { .init(text: nil, int: value) }

  var value: DatabaseValueConvertible? { text ?? int.map { $0 as DatabaseValueConvertible } }
}

public struct ArchiveRow: Sendable, Equatable {
  public var id: String
  public var closedAt: Double
  public var payload: String
}

public struct WorkspaceRows: Sendable, Equatable {
  public var tables: [String: KeyedRows] = [:]
  public var archives: [String: [ArchiveRow]] = [:]
  public var values: [String: String] = [:]

  static let tableNames = ["profile", "window", "tab", "tab_group", "split"]
  static let pinKinds = ["parked", "choices", "sync"]
  static let archiveKinds = ["closedTabs", "closedWindows", "closedGroups", "deletedGroups", "cleanedTabs"]
  static let valueKeys = ["profileOrder", "orphanedProfileData", "windowOrder", "focusedWindowId", "lastProfileId", "launchTab", "launchBackdrop", "linkProfile"]

  public init() {}

  public init(_ doc: SessionDocument) {
    func keyed(_ map: JSMap<JSONValue>, _ columns: (String, JSONValue) -> [String: DatabaseValueConvertibleBox] = { _, _ in [:] }) -> KeyedRows {
      var rows = KeyedRows()
      for (id, value) in map {
        rows.ids.append(id)
        rows.payloads[id] = value.text()
        rows.columns[id] = columns(id, value)
      }
      return rows
    }
    var tabPosition: [String: Int] = [:]
    for (_, w) in doc.windows {
      for (i, id) in (w["tabIds"]?.array ?? []).enumerated() { if let id = id.string, tabPosition[id] == nil { tabPosition[id] = i } }
    }
    tables["profile"] = keyed(doc.profiles)
    tables["window"] = keyed(doc.windows) { _, w in ["profile_id": .text(w["profileId"]?.string ?? "")] }
    tables["tab"] = keyed(doc.tabs) { id, t in
      ["window_id": .text(t["windowId"]?.string ?? ""), "profile_id": .text(t["profileId"]?.string ?? ""), "position": .int(tabPosition[id] ?? -1)]
    }
    tables["tab_group"] = keyed(doc.groups) { _, g in ["window_id": .text(g["windowId"]?.string ?? "")] }
    tables["split"] = keyed(doc.splits) { _, v in ["window_id": .text(v["windowId"]?.string ?? "")] }
    tables["pin:parked"] = keyed(doc.parkedPins)
    tables["pin:choices"] = keyed(doc.pinChoices)
    tables["pin:sync"] = keyed(doc.pinSync)
    func archive(_ list: [JSONValue]) -> [ArchiveRow] {
      list.map { ArchiveRow(id: $0["id"]?.string ?? "", closedAt: $0["closedAt"]?.number ?? 0, payload: $0.text()) }
    }
    archives["closedTabs"] = archive(doc.closedTabs)
    archives["closedWindows"] = archive(doc.closedWindows)
    archives["closedGroups"] = archive(doc.closedGroups)
    archives["deletedGroups"] = archive(doc.deletedGroups)
    archives["cleanedTabs"] = archive(doc.cleanedTabs)
    values["profileOrder"] = JSONValue(doc.profileOrder).text()
    values["orphanedProfileData"] = JSONValue(doc.orphanedProfileData).text()
    values["windowOrder"] = JSONValue(doc.windowOrder).text()
    values["focusedWindowId"] = JSONValue(doc.focusedWindowId).text()
    values["lastProfileId"] = JSONValue(doc.lastProfileId).text()
    values["launchTab"] = doc.launchTab.text()
    values["launchBackdrop"] = doc.launchBackdrop.text()
    values["linkProfile"] = doc.linkProfile.text()
  }

  func parsed(_ text: String?) -> JSONValue { text.flatMap { try? JSONValue.parse($0) } ?? .null }

  public func readable() -> (rows: WorkspaceRows, unreadable: [String]) {
    var out = self
    var unreadable: [String] = []
    let windows = tables["window"] ?? KeyedRows()
    let badWindows = Set(windows.ids.filter { parsed(windows.payloads[$0]).object == nil })
    for (name, keyed) in tables.sorted(by: { $0.key < $1.key }) {
      let bad = keyed.ids.filter { id in
        if parsed(keyed.payloads[id]).object == nil { return true }
        guard name != "window", let window = keyed.columns[id]?["window_id"]?.text else { return false }
        return badWindows.contains(window)
      }
      if bad.isEmpty { continue }
      var kept = keyed
      kept.ids = keyed.ids.filter { !bad.contains($0) }
      for id in bad {
        kept.payloads.removeValue(forKey: id)
        kept.columns.removeValue(forKey: id)
        unreadable.append("\(name) \(id)")
      }
      out.tables[name] = kept
    }
    return (out, unreadable)
  }

  public func document() -> JSONObject {
    func object(_ name: String) -> JSONValue {
      let rows = tables[name] ?? KeyedRows()
      return .object(JSONObject(rows.ids.map { ($0, parsed(rows.payloads[$0])) }))
    }
    func array(_ name: String) -> JSONValue {
      let rows = tables[name] ?? KeyedRows()
      return .array(rows.ids.map { parsed(rows.payloads[$0]) })
    }
    func archive(_ kind: String) -> JSONValue { .array((archives[kind] ?? []).map { parsed($0.payload) }) }
    return [
      "version": 2, "profiles": object("profile"), "profileOrder": parsed(values["profileOrder"]),
      "orphanedProfileData": parsed(values["orphanedProfileData"]), "windows": array("window"), "windowOrder": parsed(values["windowOrder"]),
      "focusedWindowId": parsed(values["focusedWindowId"]), "lastProfileId": parsed(values["lastProfileId"]), "launchTab": parsed(values["launchTab"]),
      "launchBackdrop": parsed(values["launchBackdrop"]), "linkProfile": parsed(values["linkProfile"]), "tabs": array("tab"),
      "groups": array("tab_group"), "splits": array("split"), "closedTabs": archive("closedTabs"), "closedWindows": archive("closedWindows"),
      "parkedPins": object("pin:parked"), "pinChoices": object("pin:choices"), "pinSync": object("pin:sync"),
      "closedGroups": archive("closedGroups"), "deletedGroups": archive("deletedGroups"), "cleanedTabs": archive("cleanedTabs"),
    ]
  }
}

enum Rows {
  static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
    try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
  }

  static func writeSettings(_ db: Database, _ settings: JSONObject?) throws {
    try db.execute(sql: "DELETE FROM setting")
    guard let settings else { return }
    let statement = try db.makeStatement(sql: "INSERT INTO setting (key, position, value) VALUES (?, ?, ?)")
    for (position, key) in settings.keys.enumerated() {
      try statement.execute(arguments: [key, position, settings[key]!.text()])
    }
  }

  static func clearWorkspace(_ db: Database) throws {
    for table in ["tab", "tab_group", "split", "\"window\"", "profile", "pin_table", "archive", "workspace"] {
      try db.execute(sql: "DELETE FROM \(table)")
    }
  }

  static func writeDocuments(_ db: Database, _ documents: JSMap<String>) throws {
    for (name, value) in documents {
      try db.execute(
        sql: "INSERT INTO document (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", arguments: [name, value])
    }
  }

  static func writeDownloads(_ db: Database, _ downloads: [Download]) throws {
    try db.execute(sql: "DELETE FROM download")
    let statement = try db.makeStatement(sql: "INSERT INTO download (id, position, payload) VALUES (?, ?, ?)")
    for (position, download) in downloads.enumerated() {
      try statement.execute(arguments: [download.id, position, JSONValue.object(download.json).text()])
    }
  }

  static func tableSQL(_ name: String) -> (table: String, key: String, kind: String?) {
    if name.hasPrefix("pin:") { return ("pin_table", "profile_id", String(name.dropFirst(4))) }
    return (name == "window" ? "\"window\"" : name, "id", nil)
  }

  static func writeWorkspace(_ db: Database, _ rows: WorkspaceRows, previous: WorkspaceRows?) throws {
    for name in WorkspaceRows.tableNames + WorkspaceRows.pinKinds.map({ "pin:\($0)" }) {
      try writeKeyed(db, name, rows.tables[name] ?? KeyedRows(), previous: previous?.tables[name])
    }
    for kind in WorkspaceRows.archiveKinds {
      let now = rows.archives[kind] ?? []
      if let before = previous?.archives[kind], before == now { continue }
      try db.execute(sql: "DELETE FROM archive WHERE kind = ?", arguments: [kind])
      let statement = try db.makeStatement(sql: "INSERT INTO archive (kind, position, id, closed_at, payload) VALUES (?, ?, ?, ?, ?)")
      for (position, row) in now.enumerated() { try statement.execute(arguments: [kind, position, row.id, row.closedAt, row.payload]) }
    }
    for key in WorkspaceRows.valueKeys {
      let value = rows.values[key] ?? "null"
      if previous?.values[key] == value { continue }
      try db.execute(
        sql: "INSERT INTO workspace (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
    }
    if previous == nil { try setMeta(db, "workspace", "1") }
  }

  static func writeKeyed(_ db: Database, _ name: String, _ rows: KeyedRows, previous: KeyedRows?) throws {
    let (table, key, kind) = tableSQL(name)
    let scope = kind.map { " AND kind = '\($0)'" } ?? ""
    let before = previous ?? KeyedRows()
    let now = Set(rows.ids)
    let gone = before.ids.filter { !now.contains($0) }
    for id in gone { try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?\(scope)", arguments: [id]) }
    let fresh = Set(rows.ids.filter { before.payloads[$0] == nil })
    let reordered = rows.ids != before.ids
    let columnNames = rows.columns.values.first.map { $0.keys.sorted() } ?? []
    let allColumns = [key] + (kind != nil ? ["kind"] : []) + ["seq"] + columnNames + ["payload"]
    let placeholders = Array(repeating: "?", count: allColumns.count).joined(separator: ", ")
    let updates = (["seq"] + columnNames + ["payload"]).map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let conflict = kind != nil ? "kind, profile_id" : key
    let upsert = try db.makeStatement(
      sql: "INSERT INTO \(table) (\(allColumns.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(\(conflict)) DO UPDATE SET \(updates)")
    let reseq = try db.makeStatement(sql: "UPDATE \(table) SET seq = ? WHERE \(key) = ?\(scope)")
    for (seq, id) in rows.ids.enumerated() {
      if fresh.contains(id) || before.payloads[id] != rows.payloads[id] || before.columns[id] != rows.columns[id] {
        var arguments: [DatabaseValueConvertible?] = [id]
        if let kind { arguments.append(kind) }
        arguments.append(seq)
        for column in columnNames { arguments.append(rows.columns[id]?[column]?.value) }
        arguments.append(rows.payloads[id])
        try upsert.execute(arguments: StatementArguments(arguments))
      } else if reordered {
        try reseq.execute(arguments: [seq, id])
      }
    }
  }

  static func loadSettings(_ db: Database, notes: inout [String]) throws -> JSONObject? {
    var settings = JSONObject()
    let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM setting ORDER BY position")
    for row in rows {
      let key: String = row["key"]
      let text: String = row["value"]
      if let value = try? JSONValue.parse(text) { settings[key] = value } else { notes.append("skipped unreadable setting \(key)") }
    }
    return rows.isEmpty ? nil : settings
  }

  static func loadDownloads(_ db: Database, notes: inout [String]) throws -> [Download] {
    let rows = try String.fetchAll(db, sql: "SELECT payload FROM download ORDER BY position")
    var downloads: [Download] = []
    for (position, text) in rows.enumerated() {
      if let object = (try? JSONValue.parse(text))?.object { downloads.append(Download(json: object)) } else { notes.append("skipped unreadable download \(position)") }
    }
    return downloads
  }

  static func load(_ db: Database) throws -> PersistedState {
    var notes: [String] = []
    let settings = try loadSettings(db, notes: &notes)
    let downloads = try loadDownloads(db, notes: &notes)
    var documents = JSMap<String>()
    for row in try Row.fetchAll(db, sql: "SELECT name, value FROM document ORDER BY name") {
      let name: String = row["name"]
      documents[name] = row["value"]
    }
    let imported = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'workspace'") == "1"
    var workspace: WorkspaceRows? = nil
    if imported {
      var rows = WorkspaceRows()
      for name in WorkspaceRows.tableNames + WorkspaceRows.pinKinds.map({ "pin:\($0)" }) {
        let (table, key, kind) = tableSQL(name)
        let scope = kind.map { " WHERE kind = '\($0)'" } ?? ""
        var keyed = KeyedRows()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)\(scope) ORDER BY seq") {
          let id: String = row[key]
          keyed.ids.append(id)
          keyed.payloads[id] = row["payload"]
          var columns: [String: DatabaseValueConvertibleBox]
          if name == "tab" {
            columns = [
              "window_id": .text(row["window_id"]), "profile_id": .text(row["profile_id"]), "position": .int(row["position"]),
            ]
          } else if name == "window" {
            columns = ["profile_id": .text(row["profile_id"])]
          } else if name == "tab_group" || name == "split" {
            columns = ["window_id": .text(row["window_id"])]
          } else {
            columns = [:]
          }
          keyed.columns[id] = columns
        }
        rows.tables[name] = keyed
      }
      for kind in WorkspaceRows.archiveKinds {
        rows.archives[kind] = try Row.fetchAll(db, sql: "SELECT id, closed_at, payload FROM archive WHERE kind = ? ORDER BY position", arguments: [kind]).map {
          ArchiveRow(id: $0["id"], closedAt: $0["closed_at"], payload: $0["payload"])
        }
      }
      for row in try Row.fetchAll(db, sql: "SELECT key, value FROM workspace") {
        let key: String = row["key"]
        rows.values[key] = row["value"]
      }
      workspace = rows
    }
    let syncAnchor = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'sync_anchor'")
    return PersistedState(
      settings: settings, downloads: downloads, workspace: workspace, documents: documents, notes: notes, syncAnchor: syncAnchor)
  }
}
