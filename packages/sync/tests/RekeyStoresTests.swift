import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import SolaraLegacySyncCore

final class RekeyStoresTests: XCTestCase {
  typealias R = RekeyStores

  var dir: URL!
  var data: URL { dir.appendingPathComponent("Chromium") }
  var profile: URL { data.appendingPathComponent("Default") }
  let newSecret = Data("q3Jz8mVb1sK0xY7tN2pLwA==".utf8)
  let otherSecret = Data("another-key".utf8)
  lazy var mock = try! R.Key(secret: R.mockSecret)
  lazy var fresh = try! R.Key(secret: newSecret)
  lazy var other = try! R.Key(secret: otherSecret)

  override func setUpWithError() throws {
    dir = SyncTestDirectory.url.appendingPathComponent("rekey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func seal(_ text: String, _ key: R.Key? = nil) -> Data { seal(Data(text.utf8), key) }
  func seal(_ plain: Data, _ key: R.Key? = nil) -> Data { R.encrypt(copying: plain, key: key ?? mock)! }

  func open(_ key: R.Key, _ value: Data?) -> Data? {
    guard let value, let plain = R.decrypt(value, key: key) else { return nil }
    return Data(plain.bytes)
  }

  func database(_ url: URL, _ statements: [String], binds: [[Any?]] = []) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let db = try R.Database(url, mode: .create)
    for (index, sql) in statements.enumerated() {
      let stmt = try db.statement(sql)
      for (position, value) in (index < binds.count ? binds[index] : []).enumerated() {
        let at = Int32(position + 1)
        switch value {
        case let blob as Data: stmt.bind(R.Cell(bytes: blob, isText: false), at: at)
        case let text as TextBytes: stmt.bind(R.Cell(bytes: text.bytes, isText: true), at: at)
        case let text as String: stmt.bind(R.Cell(bytes: Data(text.utf8), isText: true), at: at)
        case let number as Int: stmt.bind(Int64(number), at: at)
        default: sqlite3_bind_null(stmt.stmt, at)
        }
      }
      while try stmt.step() {}
    }
    try db.close()
  }

  struct TextBytes { let bytes: Data }

  func cells(_ url: URL, _ sql: String) throws -> [Data?] {
    let db = try R.Database(url, mode: .immutable)
    defer { try? db.close() }
    let stmt = try db.statement(sql)
    var out: [Data?] = []
    while try stmt.step() { out.append(stmt.value(0)?.bytes) }
    return out
  }

  func hostHash(_ host: String) -> Data { Data(SHA256.hash(data: Data(host.utf8))) }

  func makeCookies(version: Int = 24, values: [(host: String, plain: Data, key: R.Key?)]) throws {
    var statements = [
      "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
      "INSERT INTO meta VALUES('version', '\(version)')",
      "CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL)",
    ]
    var binds: [[Any?]] = [[], [], []]
    for (i, value) in values.enumerated() {
      statements.append("INSERT INTO cookies VALUES(\(i), ?, 'c\(i)', '', ?)")
      binds.append([value.host, seal(value.plain, value.key)])
    }
    try database(profile.appendingPathComponent("Network/Cookies"), statements, binds: binds)
  }

  func cookiePlain(_ host: String, _ value: String) -> Data { hostHash(host) + Data(value.utf8) }

  let proto = Data([0x08, 0x96, 0x01, 0x12, 0x03, 0x61, 0x62, 0x63])
  let keywordHash = Data([0x02]) + Data(repeating: 0xAB, count: 32)

  func makeLogins(extra: [String] = [], extraBinds: [[Any?]] = []) throws {
    try database(profile.appendingPathComponent("Login Data"), [
      "CREATE TABLE logins(origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB, id INTEGER PRIMARY KEY AUTOINCREMENT)",
      "INSERT INTO logins(origin_url, username_value, password_value) VALUES('https://a.example/', 'ann', ?)",
      "INSERT INTO logins(origin_url, username_value, password_value) VALUES('https://b.example/', 'bob', ?)",
      "INSERT INTO logins(origin_url, username_value, password_value) VALUES('https://c.example/', 'cy', ?)",
      "INSERT INTO logins(origin_url, username_value, password_value) VALUES('https://d.example/', 'dee', ?)",
      "CREATE TABLE password_notes(id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL, key VARCHAR NOT NULL, value BLOB, date_created INTEGER NOT NULL, confidential INTEGER)",
      "INSERT INTO password_notes(parent_id, key, value, date_created) VALUES(1, '', ?, 0)",
    ] + extra, binds: [[], [seal("hunter2")], [seal("pässwörd ✓")], [seal("")], [TextBytes(bytes: seal("stored as text"))], [], [seal("note: door code 1234")]] + extraBinds)
  }

  func makeWebData() throws {
    try database(profile.appendingPathComponent("Web Data"), [
      "CREATE TABLE credit_cards(guid VARCHAR PRIMARY KEY, name_on_card VARCHAR, card_number_encrypted BLOB)",
      "INSERT INTO credit_cards VALUES('g1', 'Ann', ?)",
      "CREATE TABLE local_ibans(guid VARCHAR PRIMARY KEY, use_count INTEGER, use_date INTEGER, value_encrypted VARCHAR, nickname VARCHAR)",
      "INSERT INTO local_ibans VALUES('i1', 0, 0, ?, 'main')",
      "CREATE TABLE local_stored_cvc(guid VARCHAR PRIMARY KEY NOT NULL, value_encrypted VARCHAR NOT NULL, last_updated_timestamp INTEGER NOT NULL)",
      "INSERT INTO local_stored_cvc VALUES('g1', ?, 0)",
      "CREATE TABLE server_stored_cvc(instrument_id INTEGER PRIMARY KEY NOT NULL, value_encrypted VARCHAR NOT NULL, last_updated_timestamp INTEGER NOT NULL)",
      "INSERT INTO server_stored_cvc VALUES(7, ?, 0)",
      "CREATE TABLE generic_payment_instruments(instrument_id INTEGER PRIMARY KEY NOT NULL, serialized_value_encrypted VARCHAR NOT NULL)",
      "INSERT INTO generic_payment_instruments VALUES(9, ?)",
      "CREATE TABLE payment_instrument_creation_options(id VARCHAR PRIMARY KEY NOT NULL, serialized_value_encrypted VARCHAR NOT NULL)",
      "INSERT INTO payment_instrument_creation_options VALUES('o1', ?)",
      "CREATE TABLE token_service(service VARCHAR PRIMARY KEY NOT NULL, encrypted_token BLOB, binding_key BLOB, mtls_token_binding INTEGER)",
      "INSERT INTO token_service VALUES('AccountId-1', ?, NULL, 0)",
      "CREATE TABLE keywords(id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL, url VARCHAR NOT NULL, url_hash BLOB)",
      "INSERT INTO keywords VALUES(2, 'Example', 'ex', 'https://example.com/?q={searchTerms}', ?)",
      "CREATE TABLE autofill_ai_attributes(entity_guid VARCHAR, attribute_type VARCHAR, field_type INTEGER, value_encrypted BLOB NOT NULL, verification_status INTEGER)",
      "INSERT INTO autofill_ai_attributes VALUES('e', 'name', 1, ?, 0)",
    ], binds: [[], [seal("4111111111111111")], [], [seal("DE89370400440532013000")], [], [seal("123")], [], [seal("456")],
               [], [seal(proto)], [], [seal(proto)], [], [seal("1//refresh-token")], [], [seal(keywordHash)], [], [seal("Ann Example")]])
  }

  func makeHistory(title: Data) throws {
    try database(profile.appendingPathComponent("History"), [
      "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR)",
      "INSERT INTO urls(url, title) VALUES('https://example.com/', ?)",
    ], binds: [[], [TextBytes(bytes: title)]])
  }

  var staging: URL { data.appendingPathComponent(".rekey-staging") }

  func stage(_ stores: R = R()) throws -> RekeyStageReport {
    try stores.stage(userDataDir: data, stagingDir: staging, oldSecret: R.mockSecret, newSecret: newSecret)
  }

  func preflight() -> RekeyPreflight { R().preflight(userDataDir: data, oldSecret: R.mockSecret) }

  func store(_ report: RekeyStageReport, _ relative: String) -> RekeyStagedStore? { report.stores.first { $0.relativePath == relative } }

  func staged(_ relative: String) -> URL { staging.appendingPathComponent(relative) }
  func live(_ relative: String) -> URL { data.appendingPathComponent(relative) }

  func verify(_ url: URL, _ kind: RekeyStoreKind, _ expected: Int, new: Data? = nil, old: Data? = nil) -> Bool {
    R().verify(file: url, kind: kind, newSecret: new ?? newSecret, oldSecret: old ?? R.mockSecret, expectedValues: expected)
  }

  func journalMode(_ url: URL) throws -> String? {
    try cells(url, "PRAGMA journal_mode").first.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
  }

  func sidecars(_ url: URL) -> [String] {
    ["-wal", "-journal", "-shm"].filter { FileManager.default.fileExists(atPath: url.path + $0) }
  }


  func testMockKeyMatchesChromiumKnownAnswer() throws {
    XCTAssertTrue(mock.matches([0xAF, 0x0F, 0x76, 0x2A, 0xAF, 0x6D, 0x7D, 0x11, 0x58, 0x1B, 0x7A, 0xA8, 0xCE, 0x72, 0x18, 0xDE]))
    XCTAssertFalse(fresh.matches([0xAF, 0x0F, 0x76, 0x2A, 0xAF, 0x6D, 0x7D, 0x11, 0x58, 0x1B, 0x7A, 0xA8, 0xCE, 0x72, 0x18, 0xDE]))
    let sealed = seal("hello")
    XCTAssertEqual(sealed.prefix(3), Data("v10".utf8))
    XCTAssertEqual(sealed.count, 3 + 16)
    XCTAssertEqual(open(mock, sealed), Data("hello".utf8))
    XCTAssertNil(open(fresh, sealed))
    XCTAssertEqual(seal("").count, 3 + 16)
    XCTAssertEqual(seal(Data(repeating: 1, count: 16)).count, 3 + 32)
  }

  func testEveryListedColumnIsRekeyed() throws {
    try makeCookies(values: [("example.com", cookiePlain("example.com", "session=1"), nil), (".example.org", cookiePlain(".example.org", ""), nil)])
    try makeLogins()
    try makeWebData()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: live("Default/Login Data").path)
    let before = preflight()
    XCTAssertTrue(before.mockKeyed)
    XCTAssertEqual(before.blocking, [])
    XCTAssertEqual(before.oldKeyedValues, 2 + 5 + 9)
    var announced: [String] = []
    let report = try stage(R(onStaged: { announced.append($0) }))
    XCTAssertEqual(report.stores, [
      RekeyStagedStore(relativePath: "Default/Login Data", kind: .sqlite, values: 5),
      RekeyStagedStore(relativePath: "Default/Network/Cookies", kind: .sqlite, values: 2),
      RekeyStagedStore(relativePath: "Default/Web Data", kind: .sqlite, values: 9),
    ])
    XCTAssertEqual(announced, report.stores.map(\.relativePath))

    let cookies = try cells(staged("Default/Network/Cookies"), "SELECT encrypted_value FROM cookies ORDER BY creation_utc")
    XCTAssertEqual(open(fresh, cookies[0]), cookiePlain("example.com", "session=1"))
    XCTAssertEqual(open(fresh, cookies[1]), cookiePlain(".example.org", ""))
    XCTAssertEqual(open(mock, try cells(live("Default/Network/Cookies"), "SELECT encrypted_value FROM cookies ORDER BY creation_utc")[0]), cookiePlain("example.com", "session=1"))

    let logins = staged("Default/Login Data")
    let passwords = try cells(logins, "SELECT password_value FROM logins ORDER BY id").map { open(fresh, $0) }
    XCTAssertEqual(passwords, [Data("hunter2".utf8), Data("pässwörd ✓".utf8), Data(), Data("stored as text".utf8)])
    XCTAssertEqual(try cells(logins, "SELECT typeof(password_value) FROM logins ORDER BY id").map { $0.map { String(decoding: $0, as: UTF8.self) } },
                   ["blob", "blob", "blob", "text"])
    XCTAssertEqual(open(fresh, try cells(logins, "SELECT value FROM password_notes")[0]), Data("note: door code 1234".utf8))

    let expected: [(String, Data)] = [
      ("SELECT card_number_encrypted FROM credit_cards", Data("4111111111111111".utf8)),
      ("SELECT value_encrypted FROM local_ibans", Data("DE89370400440532013000".utf8)),
      ("SELECT value_encrypted FROM local_stored_cvc", Data("123".utf8)),
      ("SELECT value_encrypted FROM server_stored_cvc", Data("456".utf8)),
      ("SELECT serialized_value_encrypted FROM generic_payment_instruments", proto),
      ("SELECT serialized_value_encrypted FROM payment_instrument_creation_options", proto),
      ("SELECT encrypted_token FROM token_service", Data("1//refresh-token".utf8)),
      ("SELECT url_hash FROM keywords", keywordHash),
      ("SELECT value_encrypted FROM autofill_ai_attributes", Data("Ann Example".utf8)),
    ]
    for (sql, plain) in expected {
      XCTAssertEqual(open(fresh, try cells(staged("Default/Web Data"), sql)[0]), plain, sql)
      XCTAssertEqual(open(mock, try cells(live("Default/Web Data"), sql)[0]), plain, sql)
    }

    let mode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
    for item in report.stores {
      XCTAssertEqual(sidecars(staged(item.relativePath)), [], item.relativePath)
      XCTAssertEqual(try journalMode(staged(item.relativePath)), "delete")
      XCTAssertEqual(try mode(staged(item.relativePath)), try mode(live(item.relativePath)))
      XCTAssertTrue(verify(staged(item.relativePath), .sqlite, item.values), item.relativePath)
      XCTAssertFalse(verify(staged(item.relativePath), .sqlite, item.values + 1), item.relativePath)
      XCTAssertFalse(verify(live(item.relativePath), .sqlite, item.values), item.relativePath)
      XCTAssertEqual(sidecars(staged(item.relativePath)), [], item.relativePath)
    }
    XCTAssertEqual(preflight().notes, [])
  }

  func testNullAndPlainValuesAreLeftAlone() throws {
    try database(live("Default/Web Data"), [
      "CREATE TABLE keywords(id INTEGER PRIMARY KEY, keyword VARCHAR NOT NULL, url VARCHAR NOT NULL, url_hash BLOB)",
      "INSERT INTO keywords VALUES(2, 'ex', 'https://example.com/?q={searchTerms}', NULL)",
      "CREATE TABLE credit_cards(guid VARCHAR PRIMARY KEY, card_number_encrypted BLOB)",
      "INSERT INTO credit_cards VALUES('g', ?)",
    ], binds: [[], [], [], [seal("4111111111111111")]])
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Default/Web Data", kind: .sqlite, values: 1)])
    XCTAssertEqual(try cells(staged("Default/Web Data"), "SELECT url_hash FROM keywords"), [nil])
  }

  func testUnknownMockKeyedColumnInListedStoreBlocksAndFails() throws {
    try makeLogins(extra: ["ALTER TABLE logins ADD COLUMN rekey_unknown BLOB", "UPDATE logins SET rekey_unknown = ? WHERE id = 1"],
                   extraBinds: [[], [seal("an unlisted password")]])
    XCTAssertEqual(preflight().blocking, ["Default/Login Data: logins.rekey_unknown (1)"])
    XCTAssertThrowsError(try stage()) { error in
      XCTAssertEqual(error as? RekeyStoresError, .sweepHit("Default/Login Data: logins.rekey_unknown (1)"))
    }
  }

  func testUnknownColumnInListedStoreWithNothingElseEncryptedFails() throws {
    try database(live("Default/Login Data"), [
      "CREATE TABLE logins(id INTEGER PRIMARY KEY, password_value BLOB)",
      "CREATE TABLE stolen(secret BLOB)",
      "INSERT INTO stolen VALUES(?)",
    ], binds: [[], [], [seal("an unlisted password")]])
    XCTAssertEqual(preflight().blocking, ["Default/Login Data: stolen.secret (1)"])
    XCTAssertThrowsError(try stage()) { error in
      XCTAssertEqual(error as? RekeyStoresError, .sweepHit("Default/Login Data: stolen.secret (1)"))
    }
  }

  func testV10LookingTitleInUnlistedDatabaseIsOnlyLogged() throws {
    try makeLogins()
    try makeHistory(title: seal("A page title"))
    let check = preflight()
    XCTAssertEqual(check.notes, ["Default/History: urls.title (1)"])
    XCTAssertEqual(check.blocking, [])
    let report = try stage()
    XCTAssertNil(store(report, "Default/History"))
    XCTAssertNotNil(store(report, "Default/Login Data"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged("Default/History").path))
  }

  func testValuesUnderAnotherKeyAreLeftAsTheyAre() throws {
    try database(live("Default/Login Data"), [
      "CREATE TABLE logins(id INTEGER PRIMARY KEY, password_value BLOB)",
      "INSERT INTO logins VALUES(1, ?)",
      "INSERT INTO logins VALUES(2, ?)",
      "INSERT INTO logins VALUES(3, ?)",
    ], binds: [[], [seal("mine")], [seal("theirs", other)], [Data("plain".utf8)]])
    XCTAssertEqual(preflight().oldKeyedValues, 1)
    let report = try stage()
    XCTAssertEqual(store(report, "Default/Login Data")?.values, 1)
    let rows = try cells(staged("Default/Login Data"), "SELECT password_value FROM logins ORDER BY id")
    XCTAssertEqual(open(fresh, rows[0]), Data("mine".utf8))
    XCTAssertEqual(rows[1], seal("theirs", other))
    XCTAssertEqual(rows[2], Data("plain".utf8))
    XCTAssertTrue(verify(staged("Default/Login Data"), .sqlite, 1))
  }

  func testImplausiblePlaintextInListedColumnBlocksAndFails() throws {
    try database(live("Default/Web Data"), [
      "CREATE TABLE credit_cards(guid VARCHAR PRIMARY KEY, card_number_encrypted BLOB)",
      "INSERT INTO credit_cards VALUES('g', ?)",
    ], binds: [[], [seal("not a card number")]])
    XCTAssertEqual(preflight().blocking, [RekeyStoresError.implausible("Default/Web Data: credit_cards.card_number_encrypted rowid 1").description])
    XCTAssertThrowsError(try stage()) { error in
      XCTAssertEqual(error as? RekeyStoresError, .implausible("Default/Web Data: credit_cards.card_number_encrypted rowid 1"))
    }
  }

  func testCookieHashPrefixIsCheckedAndKept() throws {
    try makeCookies(values: [("good.example", cookiePlain("good.example", "v"), nil)])
    _ = try stage()
    let plain = try XCTUnwrap(open(fresh, try cells(staged("Default/Network/Cookies"), "SELECT encrypted_value FROM cookies")[0]))
    XCTAssertEqual(plain.prefix(32), hostHash("good.example"))
    XCTAssertEqual(plain.dropFirst(32), Data("v".utf8))
  }

  func testCookieWithoutHashPrefixIsDroppedOnVersion24() throws {
    try makeCookies(values: [("bad.example", Data("no prefix".utf8), nil), ("good.example", cookiePlain("good.example", "v"), nil),
                             ("other.example", Data("other key".utf8), other)])
    let check = preflight()
    XCTAssertEqual(check.blocking, [])
    XCTAssertEqual(check.notes, ["Default/Network/Cookies: 1 cookies don't start with their host's hash and will be dropped"])
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Default/Network/Cookies", kind: .sqlite, values: 1)])
    XCTAssertTrue(report.notes.contains("Default/Network/Cookies: dropped 1 cookies that don't start with their host's hash; Chrome discards those at load"))
    XCTAssertEqual(try cells(staged("Default/Network/Cookies"), "SELECT host_key FROM cookies ORDER BY creation_utc").map { $0.map { String(decoding: $0, as: UTF8.self) } },
                   ["good.example", "other.example"])
    XCTAssertTrue(verify(staged("Default/Network/Cookies"), .sqlite, 1))
  }

  func testDroppedCookieAloneStillStagesTheStore() throws {
    try makeCookies(values: [("bad.example", Data("no prefix".utf8), nil)])
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Default/Network/Cookies", kind: .sqlite, values: 0)])
    XCTAssertEqual(try cells(staged("Default/Network/Cookies"), "SELECT host_key FROM cookies"), [])
    XCTAssertTrue(verify(staged("Default/Network/Cookies"), .sqlite, 0))
  }

  func testCookieWithoutHashPrefixIsFineBeforeVersion24() throws {
    try makeCookies(version: 23, values: [("old.example", Data("no prefix".utf8), nil)])
    XCTAssertFalse(preflight().mockKeyed)
    _ = try stage()
    XCTAssertEqual(open(fresh, try cells(staged("Default/Network/Cookies"), "SELECT encrypted_value FROM cookies")[0]), Data("no prefix".utf8))
  }

  func testCookiesAtTheProfileRoot() throws {
    try database(live("Profile 1/Cookies"), [
      "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
      "INSERT INTO meta VALUES('version', '24')",
      "CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, is_persistent INTEGER, encrypted_value BLOB NOT NULL)",
      "INSERT INTO cookies VALUES(1, 'a.example', 0, ?)",
    ], binds: [[], [], [], [seal(cookiePlain("a.example", "session"))]])
    XCTAssertTrue(preflight().mockKeyed)
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Profile 1/Cookies", kind: .sqlite, values: 1)])
  }

  func prefsText(token: String, super superHash: String, macToken: String) -> String {
    """
    {"browser":{"window_placement":{"left":10}},"device_oauth2_token":"\(token)",
       "escaped":"a \\"quoted\\" djEw value","plain":"djEwAAAA","num":1.50,
     "protection":{"macs":{"browser":{"show_home_button":"ABCDEF","show_home_button_encrypted_hash":"\(macToken)"},"extensions":{"settings":{}}},"super_mac":"0011","super_encrypted_hash":"\(superHash)"},
     "unicode":"caf\\u00e9 \u{00e9}"}

    """
  }

  func testPreferencesAreEditedInPlace() throws {
    let token = seal("device-token").base64EncodedString()
    let macToken = seal(Data(repeating: 7, count: 32)).base64EncodedString()
    let draft = prefsText(token: token, super: String(repeating: "A", count: 68), macToken: macToken)
    let superHash = try XCTUnwrap(R.expectedSuperHash(Array(draft.utf8), key: mock))
    XCTAssertEqual(superHash.count, 68)
    let text = prefsText(token: token, super: superHash, macToken: macToken)
    try Data(text.utf8).write(to: live("Default/Secure Preferences"))
    XCTAssertEqual(preflight().oldKeyedValues, 3)
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Default/Secure Preferences", kind: .prefs, values: 3)])
    let before = Array(text.utf8)
    let after = Array(try Data(contentsOf: staged("Default/Secure Preferences")))
    XCTAssertEqual(before.count, after.count)
    let changed = (0..<before.count).filter { before[$0] != after[$0] }
    let ranges = R.stringRanges(before).filter { range in changed.contains { range.contains($0) } }
    XCTAssertEqual(ranges.count, 3)
    XCTAssertTrue(changed.allSatisfy { i in ranges.contains { $0.contains(i) } })
    XCTAssertEqual(open(fresh, try XCTUnwrap(R.base64Token(after[ranges[0]]))), Data("device-token".utf8))
    XCTAssertEqual(open(fresh, try XCTUnwrap(R.base64Token(after[ranges[1]]))), Data(repeating: 7, count: 32))
    XCTAssertEqual(R.superHashValid(after, key: fresh), true)
    XCTAssertTrue(verify(staged("Default/Secure Preferences"), .prefs, 3))
    XCTAssertFalse(verify(live("Default/Secure Preferences"), .prefs, 3))
  }

  func testUnverifiableSuperHashIsStillReEncrypted() throws {
    let text = prefsText(token: seal("device-token").base64EncodedString(), super: seal(Data(repeating: 9, count: 32)).base64EncodedString(),
                         macToken: seal(Data(repeating: 7, count: 32)).base64EncodedString())
    try Data(text.utf8).write(to: live("Default/Preferences"))
    let report = try stage()
    XCTAssertEqual(store(report, "Default/Preferences")?.values, 3)
    XCTAssertEqual(report.notes.count, 1)
    XCTAssertTrue(report.notes[0].contains("may reset"))
    XCTAssertTrue(String(decoding: try Data(contentsOf: staged("Default/Preferences")), as: UTF8.self).contains(seal(Data(repeating: 9, count: 32), fresh).base64EncodedString()))
  }

  func testChromeJSONMatchesBaseJSONWriter() {
    let value: [String: Any] = ["b": ["z_encrypted_hash": "x/y+z=", "a": "<\u{2028}\"\\\n\u{01}é"], "a": [String: Any](), "c": ["d": [String: Any]()]]
    XCTAssertEqual(R.chromeJSON(value), #"{"b":{"a":"\u003C\u2028\"\\\n\u0001é","z_encrypted_hash":"x/y+z="}}"#)
  }

  func testWholeFilesAndDiscards() throws {
    try FileManager.default.createDirectory(at: live("Default/Sync Data"), withIntermediateDirectories: true)
    try seal(proto).write(to: live("Default/Sync Data/Nigori.bin"))
    try seal(proto).write(to: live("Default/passkey_enclave_state"))
    try FileManager.default.createDirectory(at: live("Default/GCM Store/Encryption"), withIntermediateDirectories: true)
    XCTAssertEqual(preflight().oldKeyedValues, 2)
    let report = try stage()
    XCTAssertEqual(report.stores, [
      RekeyStagedStore(relativePath: "Default/Sync Data/Nigori.bin", kind: .nigori, values: 1),
      RekeyStagedStore(relativePath: "Default/passkey_enclave_state", kind: .blob, values: 1),
    ])
    XCTAssertEqual(open(fresh, try Data(contentsOf: staged("Default/Sync Data/Nigori.bin"))), proto)
    XCTAssertTrue(verify(staged("Default/passkey_enclave_state"), .blob, 1))
    XCTAssertFalse(verify(live("Default/passkey_enclave_state"), .blob, 1))
    XCTAssertEqual(report.discard, ["Default/GCM Store"])
  }

  func testLocalStateAtTheRoot() throws {
    try Data(#"{"os_crypt":{"audit_enabled":true},"app_shims_cdhash_hmac_key":"\#(seal(Data(repeating: 3, count: 32)).base64EncodedString())"}"#.utf8)
      .write(to: live("Local State"))
    XCTAssertEqual(try stage().stores, [RekeyStagedStore(relativePath: "Local State", kind: .prefs, values: 1)])
  }

  func testWalDatabaseIsCheckpointedAndStagedInDeleteMode() throws {
    try makeLogins(extra: ["PRAGMA journal_mode=WAL"])
    let report = try stage()
    XCTAssertEqual(store(report, "Default/Login Data")?.values, 5)
    XCTAssertEqual(sidecars(staged("Default/Login Data")), [])
    XCTAssertEqual(try journalMode(staged("Default/Login Data")), "delete")
    XCTAssertTrue(verify(staged("Default/Login Data"), .sqlite, 5))
    XCTAssertEqual(sidecars(staged("Default/Login Data")), [])
  }

  func testEmptyJournalIsQuiescentAndHotOneIsNot() throws {
    try makeLogins()
    FileManager.default.createFile(atPath: live("Default/Login Data").path + "-journal", contents: Data())
    XCTAssertNoThrow(try stage())
    try R.removeWithSidecars(staged("Default/Login Data"))
  }

  func testRestageReplacesStaleStagedFiles() throws {
    try makeLogins()
    try FileManager.default.createDirectory(at: staged("Default"), withIntermediateDirectories: true)
    try Data("junk".utf8).write(to: staged("Default/Login Data"))
    try Data("junk".utf8).write(to: URL(fileURLWithPath: staged("Default/Login Data").path + "-journal"))
    _ = try stage()
    XCTAssertTrue(verify(staged("Default/Login Data"), .sqlite, 5))
    XCTAssertEqual(sidecars(staged("Default/Login Data")), [])
  }

  func testRefusals() throws {
    try makeLogins()
    XCTAssertThrowsError(try R().stage(userDataDir: data, stagingDir: staging, oldSecret: R.mockSecret, newSecret: R.mockSecret)) {
      XCTAssertEqual($0 as? RekeyStoresError, .sameKey)
    }
    XCTAssertThrowsError(try R().stage(userDataDir: data, stagingDir: staging, oldSecret: R.mockSecret, newSecret: Data())) {
      XCTAssertEqual($0 as? RekeyStoresError, .badSecret)
    }
    XCTAssertFalse(verify(live("Default/Login Data"), .sqlite, 0, new: R.mockSecret))
  }

  func testTamperedStagedCopyFailsVerification() throws {
    try makeLogins()
    _ = try stage()
    try database(staged("Default/Login Data"), ["UPDATE logins SET password_value = ? WHERE id = 2"], binds: [[seal("swapped", mock)]])
    XCTAssertFalse(verify(staged("Default/Login Data"), .sqlite, 5))
    XCTAssertFalse(verify(staged("Default/Login Data"), .sqlite, 4))
  }

  func testPreflightIsReadOnly() throws {
    try makeLogins(extra: ["PRAGMA journal_mode=WAL"])
    let before = try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted()
    XCTAssertTrue(preflight().mockKeyed)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted(), before)
  }

  func testMockKeyedProof() throws {
    XCTAssertFalse(preflight().mockKeyed)
    try makeLogins()
    XCTAssertTrue(preflight().mockKeyed)
    XCTAssertFalse(R().preflight(userDataDir: data, oldSecret: newSecret).mockKeyed)
  }

  func testVacuumLeavesNoOldCiphertext() throws {
    let gone = seal(String(repeating: "deleted secret ", count: 40))
    try database(live("Default/Web Data"), [
      "PRAGMA secure_delete=OFF",
      "CREATE TABLE token_service(service VARCHAR PRIMARY KEY NOT NULL, encrypted_token BLOB)",
      "INSERT INTO token_service VALUES('a', ?)",
      "INSERT INTO token_service VALUES('b', ?)",
      "INSERT INTO token_service VALUES('c', ?)",
      "DELETE FROM token_service WHERE service = 'b'",
    ], binds: [[], [], [seal("token a")], [gone], [seal("token c")]])
    XCTAssertNotNil(try Data(contentsOf: live("Default/Web Data")).range(of: gone.prefix(64)))
    let report = try stage()
    XCTAssertEqual(store(report, "Default/Web Data")?.values, 2)
    XCTAssertNil(try Data(contentsOf: staged("Default/Web Data")).range(of: gone.prefix(64)))
    XCTAssertEqual(try cells(staged("Default/Web Data"), "SELECT CAST(freelist_count AS TEXT) FROM pragma_freelist_count").first.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }, "0")
    XCTAssertTrue(verify(staged("Default/Web Data"), .sqlite, 2))
  }

  func testUnlistedColumnChangeInStagedCopyIsCaught() throws {
    try makeLogins()
    _ = try stage()
    try database(staged("Default/Login Data"), ["UPDATE logins SET username_value = 'mallory' WHERE id = 1"])
    XCTAssertThrowsError(try R.compareDatabases(original: live("Default/Login Data"), candidate: staged("Default/Login Data"), kind: .logins,
                                                from: mock, to: fresh, label: "Default/Login Data")) { error in
      XCTAssertEqual(error as? RekeyStoresError, .mismatch("Default/Login Data: logins"))
    }
  }

  func testUnlistedBinaryHitIsLogged() throws {
    try makeLogins()
    try database(live("Default/page_content.db"), [
      "CREATE TABLE content(id INTEGER PRIMARY KEY, blob BLOB)",
      "INSERT INTO content(blob) VALUES(?)",
    ], binds: [[], [seal(Data((0..<64).map { UInt8($0 * 7 % 256) | 0x80 }))]])
    XCTAssertEqual(preflight().notes, ["Default/page_content.db: content.blob (1)"])
  }

  func testSuperHashWrittenByChromiumIsReproduced() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/rekey-secure-preferences.json")
    let original = try Data(contentsOf: fixture)
    XCTAssertEqual(R.superHashValid(Array(original), key: mock), true)
    try original.write(to: live("Default/Secure Preferences"))
    let report = try stage()
    XCTAssertEqual(report.stores, [RekeyStagedStore(relativePath: "Default/Secure Preferences", kind: .prefs, values: 25)])
    XCTAssertEqual(report.notes, [])
    let after = try Data(contentsOf: staged("Default/Secure Preferences"))
    XCTAssertEqual(after.count, original.count)
    XCTAssertEqual(R.superHashValid(Array(after), key: fresh), true)
    XCTAssertTrue(verify(staged("Default/Secure Preferences"), .prefs, 25))
  }

  func valuePaddingUnderOldKey(_ prefix: String, hostKey: Data? = nil) -> (plain: Data, sealed: Data) {
    var i = 0
    while true {
      let plain = (hostKey ?? Data()) + Data("\(prefix)\(i)".utf8)
      let sealed = seal(plain, fresh)
      if let garbage = R.decrypt(sealed, key: mock) {
        garbage.wipe()
        return (plain, sealed)
      }
      i += 1
    }
  }

  func testNewKeyValuesThatPadUnderTheOldKeyAreNotStale() throws {
    let password = valuePaddingUnderOldKey("pw")
    let host = hostHash("pad.example")
    let cookie = valuePaddingUnderOldKey("c", hostKey: host)
    let token = valuePaddingUnderOldKey("tok")
    try database(live("Default/Login Data"), [
      "CREATE TABLE logins(id INTEGER PRIMARY KEY, password_value BLOB)",
      "INSERT INTO logins VALUES(1, ?)",
    ], binds: [[], [seal(password.plain)]])
    try database(live("Default/Cookies"), [
      "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
      "INSERT INTO meta VALUES('version', '24')",
      "CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, encrypted_value BLOB NOT NULL)",
      "INSERT INTO cookies VALUES(1, 'pad.example', ?)",
    ], binds: [[], [], [], [seal(cookie.plain)]])
    try Data(#"{"a":"\#(seal(token.plain).base64EncodedString())"}"#.utf8).write(to: live("Default/Preferences"))
    let report = try stage()
    XCTAssertEqual(report.stores.map(\.values), [1, 1, 1])
    XCTAssertEqual(try cells(staged("Default/Login Data"), "SELECT password_value FROM logins"), [password.sealed])
    XCTAssertEqual(try cells(staged("Default/Cookies"), "SELECT encrypted_value FROM cookies"), [cookie.sealed])
    XCTAssertTrue(String(decoding: try Data(contentsOf: staged("Default/Preferences")), as: UTF8.self).contains(token.sealed.base64EncodedString()))
    for item in report.stores {
      XCTAssertTrue(verify(staged(item.relativePath), item.kind, 1), item.relativePath)
    }
  }

  func testThousandsOfRekeyedValuesVerify() throws {
    let count = 6000
    var statements = [
      "BEGIN",
      "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
      "INSERT INTO meta VALUES('version', '24')",
      "CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, encrypted_value BLOB NOT NULL)",
    ]
    var binds: [[Any?]] = [[], [], [], []]
    for i in 0..<count {
      let host = "h\(i).example"
      statements.append("INSERT INTO cookies VALUES(\(i), '\(host)', ?)")
      binds.append([seal(cookiePlain(host, "value-\(i)"))])
    }
    try database(live("Default/Cookies"), statements + ["COMMIT"], binds: binds)
    var logins = ["BEGIN", "CREATE TABLE logins(id INTEGER PRIMARY KEY, password_value BLOB)"]
    var loginBinds: [[Any?]] = [[], []]
    for i in 0..<count {
      logins.append("INSERT INTO logins VALUES(\(i), ?)")
      loginBinds.append([seal("password \(i)")])
    }
    try database(live("Default/Login Data"), logins + ["COMMIT"], binds: loginBinds)
    let report = try stage()
    XCTAssertEqual(report.stores.map(\.values), [count, count])
    for item in report.stores {
      XCTAssertTrue(verify(staged(item.relativePath), .sqlite, count), item.relativePath)
    }
  }
}
