import Foundation

public enum ChromiumSecrets {
  public struct Outcome<T> {
    public var items: [T]
    public var undecryptable: Int
  }

  public static func logins(profile: URL, key: Data, cancellation: Cancellation = .init()) throws -> Outcome<Credential> {
    let read = try loginsForSync(profile: profile, key: key, cancellation: cancellation)
    return Outcome(items: read.logins.map(\.credential), undecryptable: read.undecryptable)
  }

  public struct SyncLogin: Sendable {
    public var credential: Credential
    public var modified: Int64?
  }

  public struct SyncRead: Sendable {
    public var logins: [SyncLogin]
    public var undecryptable: Int
    public var mark: String?

    public static var empty: Self { Self(logins: [], undecryptable: 0, mark: nil) }
  }

  public static func loginsForSync(profile: URL, key: Data, cancellation: Cancellation = .init()) throws -> SyncRead {
    try loginsForSync(profile: profile, cancellation: cancellation) { ChromiumCrypto.decrypt($0, key: key) }
  }

  public static func loginsForSync(profile: URL, cancellation: Cancellation = .init(), decrypt: (Data) -> String?) throws -> SyncRead {
    let files = ["Login Data", "Login Data For Account"].map { profile.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !files.isEmpty else { throw ImportError.notFound("No saved passwords in this profile") }
    var logins: [SyncLogin] = []
    var seen = Set<String>()
    var bad = 0
    var mark: String?
    for file in files {
      let db = try SQLiteSnapshot(copying: file)
      let r = try rows(db, cancellation: cancellation, decrypt: decrypt)
      bad += r.undecryptable
      for l in r.items where seen.insert("\(l.credential.realm ?? l.credential.url)\u{0}\(l.credential.username)").inserted { logins.append(l) }
      if file.lastPathComponent == "Login Data", db.tableExists("meta") {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text("solara_sync_ledger")]) { row in
          mark = row.text("value")
          return false
        }
      }
    }
    return SyncRead(logins: logins, undecryptable: bad, mark: mark)
  }

  public static func logins(database: URL, key: Data, cancellation: Cancellation = .init()) throws -> Outcome<Credential> {
    let r = try rows(SQLiteSnapshot(copying: database), cancellation: cancellation) { ChromiumCrypto.decrypt($0, key: key) }
    return Outcome(items: r.items.map(\.credential), undecryptable: r.undecryptable)
  }

  static func unixMillis(webKitMicros micros: Int64) -> Int64? {
    guard micros > 0 else { return nil }
    let unix = micros - 11_644_473_600_000_000
    return unix >= 0 ? unix / 1000 : (unix - 999) / 1000
  }

  static func rows(_ db: SQLiteSnapshot, cancellation: Cancellation, decrypt: (Data) -> String?) throws -> Outcome<SyncLogin> {
    guard db.tableExists("logins") else { throw ImportError.unreadable("Login Data has no logins table") }
    var items: [SyncLogin] = []
    var bad = 0
    try db.query("SELECT * FROM logins") { row in
      if items.count % 128 == 0 { try cancellation.check() }
      if row.int("blacklisted_by_user") ?? 0 != 0 { return true }
      guard let blob = row.blob("password_value"), !blob.isEmpty else { return true }
      guard let password = decrypt(blob) else {
        bad += 1
        return true
      }
      guard !password.isEmpty else { return true }
      let origin = row.text("origin_url") ?? ""
      let realm = row.text("signon_realm")
      items.append(SyncLogin(
        credential: Credential(
          url: origin.isEmpty ? (realm ?? "") : origin,
          username: row.text("username_value") ?? "",
          password: password,
          realm: realm,
          created: row.int("date_created").flatMap(Time.fromWebKit),
          lastUsed: row.int("date_last_used").flatMap(Time.fromWebKit),
          timesUsed: row.int("times_used").map(Int.init)
        ),
        modified: row.int("date_password_modified").flatMap { unixMillis(webKitMicros: $0) }
      ))
      return true
    }
    return Outcome(items: items, undecryptable: bad)
  }

  public static func cookies(profile: URL, key: Data, cancellation: Cancellation = .init()) throws -> Outcome<Cookie> {
    let candidates = [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
    guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw ImportError.notFound("No cookies in this profile")
    }
    return try cookies(database: file, key: key, cancellation: cancellation)
  }

  public static func cookies(database: URL, key: Data, cancellation: Cancellation = .init()) throws -> Outcome<Cookie> {
    let db = try SQLiteSnapshot(copying: database)
    guard db.tableExists("cookies") else { throw ImportError.unreadable("Cookies has no cookies table") }
    let version = db.tableExists("meta")
      ? (try? db.scalar("SELECT CAST(value AS INTEGER) FROM meta WHERE key='version'")).flatMap { $0 } ?? 0 : 0
    let hostHashed = version >= 24
    let now = Date().timeIntervalSince1970 * 1000
    var items: [Cookie] = []
    var bad = 0
    var seen = 0
    try db.query("SELECT * FROM cookies") { row in
      seen += 1
      if seen % 256 == 0 { try cancellation.check() }
      guard let host = row.text("host_key"), let name = row.text("name") else { return true }
      func flag(_ names: String...) -> Bool? {
        for n in names { if let v = row.int(n) { return v != 0 } }
        return nil
      }
      let persistent = flag("has_expires", "is_persistent", "persistent") ?? true
      let expires = persistent ? row.int("expires_utc").flatMap(Time.fromWebKit) : nil
      if let expires, expires < now { return true }

      let value: SecretBytes
      let plain = row.index("value").flatMap(row.blobPointer) ?? UnsafeRawBufferPointer(start: nil, count: 0)
      let encrypted = row.blob("encrypted_value") ?? Data()
      if !plain.isEmpty && !encrypted.isEmpty {
        bad += 1
        return true
      } else if !plain.isEmpty {
        value = SecretBytes(copying: plain)
      } else if !encrypted.isEmpty {
        guard let decrypted = ChromiumCrypto.decryptSecret(encrypted, key: key, hostKey: hostHashed ? host : nil) else {
          bad += 1
          return true
        }
        value = decrypted
      } else {
        value = SecretBytes(count: 0)
      }

      let topFrame = row.text("top_frame_site_key") ?? ""
      let port = row.int("source_port").map(Int.init) ?? -1
      items.append(Cookie(
        domain: host,
        name: name,
        value: value,
        path: row.text("path").flatMap { $0.isEmpty ? nil : $0 } ?? "/",
        created: row.int("creation_utc").flatMap(Time.fromWebKit),
        expires: expires,
        lastAccess: row.int("last_access_utc").flatMap(Time.fromWebKit),
        secure: flag("is_secure", "secure") ?? false,
        httpOnly: flag("is_httponly", "httponly") ?? false,
        sameSite: sameSite(row.int("samesite") ?? row.int("firstpartyonly")),
        priority: priority(row.int("priority")),
        partition: topFrame.isEmpty ? nil
          : CookiePartition(topLevelSite: topFrame, crossSite: (row.int("has_cross_site_ancestor") ?? 0) != 0),
        sourceScheme: sourceScheme(row.int("source_scheme")),
        sourcePort: (0...65535).contains(port) ? port : -1
      ))
      return true
    }
    return Outcome(items: items, undecryptable: bad)
  }

  static func priority(_ v: Int64?) -> String {
    switch v {
    case 0: "low"
    case 2: "high"
    default: "medium"
    }
  }

  static func sourceScheme(_ v: Int64?) -> String {
    switch v {
    case 1: "nonSecure"
    case 2: "secure"
    default: "unset"
    }
  }

  static func sameSite(_ v: Int64?) -> String {
    switch v {
    case 0: "none"
    case 1: "lax"
    case 2: "strict"
    default: "unspecified"
    }
  }
}
