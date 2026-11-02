import XCTest
@testable import SolaraLegacySyncCore

final class RekeyCoreFakeStores: RekeyStoreOperations {
  static let listed: [(String, RekeyStoreKind)] = [
    ("Local State", .prefs), ("Default/Cookies", .sqlite), ("Default/Login Data", .sqlite), ("Default/Preferences", .prefs),
  ]
  var blocking: [String] = []
  var stageError: Error?
  var badStaged: Set<String> = []

  static func contents(_ secret: Data, _ count: Int) -> Data { secret + Data("|\(count)".utf8) }

  static func parse(_ url: URL) -> (Data, Int)? {
    guard let data = try? Data(contentsOf: url), let bar = data.lastIndex(of: UInt8(ascii: "|")),
      let count = Int(String(decoding: data[(bar + 1)...], as: UTF8.self))
    else { return nil }
    return (Data(data[..<bar]), count)
  }

  func preflight(userDataDir: URL, oldSecret: Data) -> RekeyPreflight {
    var values = 0
    for (path, _) in Self.listed {
      if let (secret, count) = Self.parse(userDataDir.appendingPathComponent(path)), secret == oldSecret { values += count }
    }
    return RekeyPreflight(mockKeyed: values > 0, oldKeyedValues: values, blocking: blocking, notes: [])
  }

  func stage(userDataDir: URL, stagingDir: URL, oldSecret: Data, newSecret: Data) throws -> RekeyStageReport {
    if let stageError { throw stageError }
    var stores: [RekeyStagedStore] = []
    for (path, kind) in Self.listed {
      guard let (secret, count) = Self.parse(userDataDir.appendingPathComponent(path)) else { continue }
      guard secret == oldSecret else { throw RekeyFailure("\(path) isn't under the old key") }
      let staged = stagingDir.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.contents(badStaged.contains(path) ? Data("broken".utf8) : newSecret, count).write(to: staged)
      stores.append(RekeyStagedStore(relativePath: path, kind: kind, values: count))
    }
    badStaged = []
    return RekeyStageReport(stores: stores, discard: ["Default/GCM Store"])
  }

  func verify(file: URL, kind: RekeyStoreKind, newSecret: Data, oldSecret: Data, expectedValues: Int) -> Bool {
    guard let (secret, count) = Self.parse(file) else { return false }
    return secret == newSecret && count == expectedValues
  }
}

final class SafeStorageRekeyRunTests: XCTestCase {
  var root: URL!
  var dir: URL!
  var stores: RekeyCoreFakeStores!
  var keychain: RekeyFileKeychain!
  let mock = SafeStorageRekeyRun.mockSecret

  override func setUpWithError() throws {
    root = SyncTestDirectory.url.appendingPathComponent("rekey-\(UUID().uuidString)")
    dir = root.appendingPathComponent("Chromium")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Default/GCM Store"), withIntermediateDirectories: true)
    for (index, (path, _)) in RekeyCoreFakeStores.listed.enumerated() {
      try RekeyCoreFakeStores.contents(mock, index + 2).write(to: dir.appendingPathComponent(path))
    }
    try Data("wal".utf8).write(to: dir.appendingPathComponent("Default/Cookies-wal"))
    try Data("gcm".utf8).write(to: dir.appendingPathComponent("Default/GCM Store/LOG"))
    stores = RekeyCoreFakeStores()
    keychain = RekeyFileKeychain(file: dir.appendingPathComponent("Test Safe Storage Key"), log: dir.appendingPathComponent("Test Safe Storage Log"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func rekey(version: String = "100", point: @escaping (String) -> Void = { _ in }, otherCopy: Bool = false, secret: Data? = Data("bmV3LXNlY3JldC1rZXkxMg==".utf8)) -> SafeStorageRekeyRun {
    SafeStorageRekeyRun(
      userDataDir: dir, keychain: keychain, stores: stores, appVersion: version, point: point,
      otherCopyOwns: { _ in otherCopy }, newSecret: { secret })
  }

  func secretOnDisk() -> Data? {
    guard case .value(let value) = keychain.read() else { return nil }
    return value
  }

  func journalPhase() -> String? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(".safe-storage-rekey.json")),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["phase"] as? String
  }

  func assertAllKeyed(_ secret: Data, counts: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
    for (index, (path, _)) in RekeyCoreFakeStores.listed.enumerated() {
      let parsed = RekeyCoreFakeStores.parse(dir.appendingPathComponent(path))
      XCTAssertEqual(parsed?.0, secret, path, file: file, line: line)
      XCTAssertEqual(parsed?.1, counts ?? index + 2, path, file: file, line: line)
    }
  }

  func keychainLog() -> [String] {
    (try? String(contentsOf: dir.appendingPathComponent("Test Safe Storage Log"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
  }

  func present(_ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }

  func testRekeysEveryStoreAndKeepsOriginalsUntilNextLaunch() {
    XCTAssertEqual(rekey().run(), .proceed)
    let secret = secretOnDisk()!
    XCTAssertNotEqual(secret, mock)
    assertAllKeyed(secret)
    XCTAssertEqual(journalPhase(), "done")
    XCTAssertFalse(present(".rekey-staging"))
    XCTAssertTrue(present(".rekey-old/Default/Cookies-wal"))
    XCTAssertTrue(present(".rekey-old/Default/GCM Store/LOG"))
    XCTAssertFalse(present("Default/GCM Store"))
    XCTAssertFalse(present("Default/Cookies-wal"))
    XCTAssertEqual(keychainLog().filter { $0 == "add created" }.count, 1)
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertTrue(present(".rekey-old/Default/Cookies"))
    XCTAssertEqual(rekey(version: "101").run(), .proceed)
    XCTAssertFalse(present(".rekey-old"))
    XCTAssertFalse(present(".rekey-staging"))
    assertAllKeyed(secret)
  }

  func testAfterDoneALaunchOnlyProbes() {
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(rekey().run(), .proceed)
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("Test Safe Storage Log"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(keychainLog(), ["rekey probe found"])
  }

  func testUpdatesTheOptionAItemInPlace() {
    XCTAssertEqual(keychain.addIfAbsent(mock), errSecSuccess)
    XCTAssertEqual(rekey().run(), .proceed)
    let secret = secretOnDisk()!
    XCTAssertNotEqual(secret, mock)
    assertAllKeyed(secret)
    XCTAssertTrue(keychainLog().contains("rekey update done"))
    XCTAssertEqual(keychainLog().filter { $0 == "add created" }.count, 1)
  }

  func testLeavesAForeignKeyAlone() {
    XCTAssertEqual(keychain.addIfAbsent(Data("someone-else".utf8)), errSecSuccess)
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), Data("someone-else".utf8))
    assertAllKeyed(mock)
    XCTAssertEqual(journalPhase(), "abandoned")
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("Test Safe Storage Log"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(keychainLog(), [])
  }

  func testLeavesAFreshDirAlone() throws {
    try FileManager.default.removeItem(at: dir.appendingPathComponent("Local State"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertNil(secretOnDisk())
    XCTAssertNil(journalPhase())
  }

  func testLeavesDataUnderAnotherKeyAlone() throws {
    for (path, _) in RekeyCoreFakeStores.listed {
      try RekeyCoreFakeStores.contents(Data("other".utf8), 1).write(to: dir.appendingPathComponent(path))
    }
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertNil(secretOnDisk())
    XCTAssertNil(journalPhase())
    assertAllKeyed(Data("other".utf8), counts: 1)
  }

  func testAnUnreadableKeychainMeansNoMigration() {
    keychain = RekeyFileKeychain(file: keychain.file, log: keychain.log, failure: errSecAuthFailed)
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertFalse(present("Test Safe Storage Key"))
    assertAllKeyed(mock)
  }

  func testAnotherCopyQuitsWithoutAKey() {
    let outcome = rekey(otherCopy: true).run()
    XCTAssertEqual(outcome, .quit(code: SafeStorageRekeyRun.otherCopyExitCode, message: "Quit the other copy of Solara, then open it again."))
    XCTAssertNil(secretOnDisk())
    assertAllKeyed(mock)
  }

  func testABlockedPreflightFallsBackToA() {
    stores.blocking = ["unknown column"]
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertEqual(journalPhase(), "abandoned")
    assertAllKeyed(mock)
    stores.blocking = []
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertEqual(rekey(version: "101").run(), .proceed)
    assertAllKeyed(secretOnDisk()!)
  }

  func testAStagingFailureAfterTheKeyUndoesToA() {
    stores.stageError = RekeyFailure("planted")
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertEqual(journalPhase(), "abandoned")
    XCTAssertFalse(present(".rekey-staging"))
    assertAllKeyed(mock)
  }

  func testAPlantedFailureAfterTheKeyUndoesToA() {
    let run = SafeStorageRekeyRun(
      userDataDir: dir, keychain: keychain, stores: stores, appVersion: "100", otherCopyOwns: { _ in false },
      newSecret: { Data("bmV3LXNlY3JldC1rZXkxMg==".utf8) }, plantedFailureAfterKey: true)
    XCTAssertEqual(run.run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertEqual(journalPhase(), "abandoned")
    XCTAssertTrue(keychainLog().contains("rekey update done"))
    assertAllKeyed(mock)
  }

  func testABadStagedFileUndoesToA() {
    stores.badStaged = ["Default/Login Data"]
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(journalPhase(), "abandoned")
    assertAllKeyed(mock)
    XCTAssertEqual(secretOnDisk(), mock)
  }

  func testRecoversFromEveryCrashPoint() throws {
    var reference: [String] = []
    try withFreshDir { XCTAssertEqual(self.rekey(point: { reference.append($0) }).run(), .proceed) }
    XCTAssertTrue(reference.contains("after-keying"))
    XCTAssertTrue(reference.contains("after-swapping"))
    for point in reference where point != "before-cleanup" {
      try withFreshDir {
        XCTAssertEqual(self.crashChild(at: point), SafeStorageRekeyRun.crashExitCode, point)
        XCTAssertEqual(self.rekey().run(), .proceed, point)
        let secret = self.secretOnDisk()
        XCTAssertNotNil(secret, point)
        XCTAssertNotEqual(secret, self.mock, point)
        self.assertAllKeyed(secret ?? Data())
        XCTAssertEqual(self.journalPhase(), "done", point)
      }
    }
  }

  func testRecoversFromEveryCrashPointOfTheUndo() throws {
    var reference: [String] = []
    stores.badStaged = ["Default/Cookies"]
    try withFreshDir {
      self.stores.badStaged = ["Default/Cookies"]
      XCTAssertEqual(self.rekey(point: { reference.append($0) }).run(), .proceed)
    }
    XCTAssertTrue(reference.contains("after-undo-keychain"))
    for point in reference {
      try withFreshDir {
        self.stores.badStaged = ["Default/Cookies"]
        XCTAssertEqual(self.crashChild(at: point), SafeStorageRekeyRun.crashExitCode, point)
        self.stores.badStaged = []
        XCTAssertEqual(self.rekey().run(), .proceed, point)
        XCTAssertEqual(self.journalPhase(), point.hasPrefix("after-undo") || point == "after-undoing" ? "abandoned" : "done", point)
        guard let secret = self.secretOnDisk() else { return XCTFail(point) }
        self.assertAllKeyed(secret)
      }
    }
  }

  func testATruncatedStagedFileIsStagedAgain() throws {
    XCTAssertEqual(crashChild(at: "after-staged"), SafeStorageRekeyRun.crashExitCode)
    try Data().write(to: dir.appendingPathComponent(".rekey-staging/Default/Cookies"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(journalPhase(), "done")
    assertAllKeyed(secretOnDisk()!)
  }

  func testAfterAUpdateCrashesRecover() throws {
    for point in ["after-keying", "after-key-write"] {
      try withFreshDir {
        XCTAssertEqual(self.keychain.addIfAbsent(self.mock), errSecSuccess)
        XCTAssertEqual(self.crashChild(at: point), SafeStorageRekeyRun.crashExitCode, point)
        XCTAssertEqual(self.rekey().run(), .proceed, point)
        XCTAssertEqual(self.journalPhase(), "done", point)
        self.assertAllKeyed(self.secretOnDisk()!)
      }
    }
  }

  func testARemovedKeyAfterDoneMigratesAgain() throws {
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(rekey(version: "101").run(), .proceed)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("Test Safe Storage Key"))
    for (path, _) in RekeyCoreFakeStores.listed {
      try RekeyCoreFakeStores.contents(mock, 1).write(to: dir.appendingPathComponent(path))
    }
    XCTAssertEqual(rekey(version: "101", secret: Data("c2Vjb25kLWtleS0xMjM0NQ==".utf8)).run(), .proceed)
    XCTAssertEqual(secretOnDisk(), Data("c2Vjb25kLWtleS0xMjM0NQ==".utf8))
    assertAllKeyed(secretOnDisk()!, counts: 1)
  }

  func testACrashBetweenDoneAndStagingRemovalClearsStagingOnTheNextLaunch() throws {
    XCTAssertEqual(crashChild(at: "after-done-write"), SafeStorageRekeyRun.crashExitCode)
    XCTAssertTrue(present(".rekey-staging"))
    let secret = secretOnDisk()!
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertFalse(present(".rekey-staging"))
    XCTAssertTrue(present(".rekey-old/Default/Cookies"))
    XCTAssertEqual(journalPhase(), "done")
    assertAllKeyed(secret)
  }

  func testLeftoverStagingIsLeftAloneWhileAnotherCopyOwnsTheDir() throws {
    XCTAssertEqual(crashChild(at: "after-done-write"), SafeStorageRekeyRun.crashExitCode)
    XCTAssertEqual(rekey(otherCopy: true).run(), .proceed)
    XCTAssertTrue(present(".rekey-staging"))
    let log = try String(contentsOf: dir.appendingPathComponent(".safe-storage-rekey.log"), encoding: .utf8)
    XCTAssertTrue(log.contains("staging left for the copy that owns the data dir"))
    XCTAssertFalse(log.contains("quitting"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertFalse(present(".rekey-staging"))
  }

  func testAMissingKeyWhileOriginalsAreKeptChangesNothing() throws {
    XCTAssertEqual(rekey().run(), .proceed)
    let secret = secretOnDisk()!
    try FileManager.default.removeItem(at: dir.appendingPathComponent("Test Safe Storage Key"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertNil(secretOnDisk())
    assertAllKeyed(secret)
    XCTAssertTrue(present(".rekey-old/Default/Cookies"))
  }

  func testAHalfDoneRollbackKeepsTheMockKeyAndTheFolders() throws {
    XCTAssertEqual(rekey().run(), .proceed)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("Test Safe Storage Key"))
    for (path, _) in RekeyCoreFakeStores.listed {
      try RekeyCoreFakeStores.contents(mock, 1).write(to: dir.appendingPathComponent(path))
    }
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    assertAllKeyed(mock, counts: 1)
    XCTAssertTrue(present(".rekey-old/Default/Cookies"))
  }

  func testLeftoversWithNoJournalKeepTheMockKey() throws {
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".rekey-old/Default"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent(".rekey-old/Default/Cookies"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertNil(journalPhase())
    XCTAssertTrue(present(".rekey-old/Default/Cookies"))
    assertAllKeyed(mock)
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
  }

  func testOnlyALiveProcessOfOurBundleHoldsTheSingletonLock() throws {
    let lock = dir.appendingPathComponent("SingletonLock").path
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    XCTAssertGreaterThan(proc_pidpath(getpid(), &path, UInt32(path.count)), 0)
    let ours = SafeStorageRekeyRun.enclosingBundleIdentifiers(of: String(cString: path)).first
    XCTAssertFalse(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: "network.benson.solara"))
    symlink("elsewhere.local-\(getpid())", lock)
    XCTAssertFalse(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: "network.benson.solara"))
    if let ours {
      XCTAssertTrue(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: ours))
    }
    unlink(lock)
    symlink("elsewhere.local-999999", lock)
    XCTAssertFalse(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: ours ?? "network.benson.solara"))
    unlink(lock)
    symlink("elsewhere.local-1", lock)
    XCTAssertFalse(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: "network.benson.solara"))
    unlink(lock)
    try Data("not a link".utf8).write(to: URL(fileURLWithPath: lock))
    XCTAssertFalse(SafeStorageRekeyRun.singletonHeld(dir, bundleIdentifier: ours ?? "network.benson.solara"))
  }

  func testEnclosingBundlesIncludeTheOuterAppOfAHelper() throws {
    let outer = root.appendingPathComponent("Solara.app")
    let helper = outer.appendingPathComponent("Contents/Frameworks/Helper.app")
    for (bundle, id) in [(outer, "network.benson.solara"), (helper, "network.benson.solara.helper")] {
      try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      (["CFBundleIdentifier": id] as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
    }
    XCTAssertEqual(
      SafeStorageRekeyRun.enclosingBundleIdentifiers(of: helper.appendingPathComponent("Contents/MacOS/Helper").path),
      ["network.benson.solara.helper", "network.benson.solara"])
  }

  func testAStrayWalNextToTheStagedFileNeverLands() throws {
    XCTAssertEqual(crashChild(at: "after-staged"), SafeStorageRekeyRun.crashExitCode)
    try Data("stale".utf8).write(to: dir.appendingPathComponent(".rekey-staging/Default/Login Data-wal"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(journalPhase(), "done")
    XCTAssertFalse(present("Default/Login Data-wal"))
    assertAllKeyed(secretOnDisk()!)
  }

  func testTheUndoMovesAStrayWalAwayBeforeTheOriginalLands() throws {
    stores.badStaged = []
    XCTAssertEqual(crashChild(at: "after-done"), SafeStorageRekeyRun.crashExitCode)
    try Data("rekeyed-wal".utf8).write(to: dir.appendingPathComponent("Default/Login Data-wal"))
    try Data("rekeyed-shm".utf8).write(to: dir.appendingPathComponent("Default/Cookies-shm"))
    var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".safe-storage-rekey.json"))) as! [String: Any]
    journal["phase"] = "undoing"
    journal["reason"] = "test"
    try JSONSerialization.data(withJSONObject: journal).write(to: dir.appendingPathComponent(".safe-storage-rekey.json"))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(journalPhase(), "abandoned")
    XCTAssertEqual(secretOnDisk(), mock)
    assertAllKeyed(mock)
    XCTAssertFalse(present("Default/Login Data-wal"))
    XCTAssertFalse(present("Default/Cookies-shm"))
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Default/Cookies-wal")), Data("wal".utf8))
    XCTAssertFalse(present(".rekey-old"))
  }

  func forceUndoing() throws {
    let url = dir.appendingPathComponent(".safe-storage-rekey.json")
    var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    journal["phase"] = "undoing"
    journal["reason"] = "test"
    try JSONSerialization.data(withJSONObject: journal).write(to: url)
  }

  func testEveryCrashPointOfAnUndoAfterTheSwapKeepsTheOriginalWal() throws {
    var reference: [String] = []
    try withFreshDir {
      XCTAssertEqual(self.crashChild(at: "after-done"), SafeStorageRekeyRun.crashExitCode)
      try self.forceUndoing()
      XCTAssertEqual(self.rekey(point: { reference.append($0) }).run(), .proceed)
    }
    let undoPoints = reference.filter { $0.hasPrefix("after-undo-") && $0 != "after-undo-files" && $0 != "after-undo-keychain" }
    XCTAssertGreaterThan(undoPoints.count, 5)
    for point in undoPoints + ["after-undo-files", "after-undo-keychain"] {
      try withFreshDir {
        XCTAssertEqual(self.crashChild(at: "after-done"), SafeStorageRekeyRun.crashExitCode, point)
        try self.forceUndoing()
        XCTAssertEqual(self.crashChild(at: point), SafeStorageRekeyRun.crashExitCode, point)
        XCTAssertEqual(self.rekey().run(), .proceed, point)
        XCTAssertEqual(self.journalPhase(), "abandoned", point)
        XCTAssertEqual(self.secretOnDisk(), self.mock, point)
        self.assertAllKeyed(self.mock)
        XCTAssertEqual(try Data(contentsOf: self.dir.appendingPathComponent("Default/Cookies-wal")), Data("wal".utf8), point)
        XCTAssertTrue(self.present("Default/GCM Store/LOG"), point)
        XCTAssertFalse(self.present(".rekey-old"), point)
      }
    }
  }

  func testRecoveringAKeyOverDataThatIsNoLongerMockKeyedUndoesToMock() throws {
    XCTAssertEqual(crashChild(at: "after-key-write"), SafeStorageRekeyRun.crashExitCode)
    for (path, _) in RekeyCoreFakeStores.listed {
      try RekeyCoreFakeStores.contents(Data("other".utf8), 1).write(to: dir.appendingPathComponent(path))
    }
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(secretOnDisk(), mock)
    XCTAssertEqual(journalPhase(), "abandoned")
  }

  func testAReportWithoutNotesDecodes() throws {
    let report = try JSONDecoder().decode(RekeyStageReport.self, from: Data(#"{"stores":[],"discard":[]}"#.utf8))
    XCTAssertEqual(report, RekeyStageReport(stores: [], discard: []))
  }

  func testAJournalWrittenWithoutNotesStillRecovers() throws {
    XCTAssertEqual(crashChild(at: "after-swapping"), SafeStorageRekeyRun.crashExitCode)
    let url = dir.appendingPathComponent(".safe-storage-rekey.json")
    var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var report = journal["report"] as! [String: Any]
    XCTAssertNotNil(report.removeValue(forKey: "notes"))
    journal["report"] = report
    try JSONSerialization.data(withJSONObject: journal).write(to: url)
    let decoded = try JSONDecoder().decode(RekeyStageReport.self, from: JSONSerialization.data(withJSONObject: report))
    XCTAssertEqual(decoded.notes, [])
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertEqual(journalPhase(), "done")
    assertAllKeyed(secretOnDisk()!)
  }

  func testAnUnfinishedJournalStopsAnOffBuild() throws {
    XCTAssertEqual(crashChild(at: "after-swapping"), SafeStorageRekeyRun.crashExitCode)
    XCTAssertTrue(SafeStorageRekeyRun.unfinished(userDataDir: dir))
    XCTAssertEqual(rekey().run(), .proceed)
    XCTAssertFalse(SafeStorageRekeyRun.unfinished(userDataDir: dir))
  }

  func withFreshDir(_ body: () throws -> Void) throws {
    try tearDownWithError()
    try setUpWithError()
    try body()
  }

  func crashChild(at name: String) -> Int32 {
    let stopped = DispatchSemaphore(value: 0)
    let hit = RekeyCoreCrashFlag()
    let run = rekey(point: {
      guard $0 == name else { return }
      hit.set()
      stopped.signal()
      DispatchSemaphore(value: 0).wait()
    })
    Thread {
      _ = run.run()
      stopped.signal()
    }.start()
    XCTAssertEqual(stopped.wait(timeout: .now() + 20), .success)
    run.releaseLock()
    return hit.value ? SafeStorageRekeyRun.crashExitCode : 0
  }
}

final class RekeyCoreCrashFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  func set() { lock.withLock { raised = true } }
  var value: Bool { lock.withLock { raised } }
}

final class SafeStorageRekeyGateTests: XCTestCase {
  let installed = URL(fileURLWithPath: "/Users/x/Library/Application Support/network.benson.solara/Chromium")
  let testEnv = ["SOLARA_TEST_REKEY": "1", "SOLARA_DATA_DIR": "/tmp/scratch/./a", "SOLARA_TEST_KEYCHAIN": "file"]

  func gate(_ env: [String: String], real: Bool = false, distribution: Bool = false) -> SafeStorageRekeyGate {
    SafeStorageRekeyGate.resolve(environment: env, chromeUsesRealKeychain: real, signedForDistribution: distribution, installedUserDataDir: installed, currentDirectory: "/cwd")
  }

  func testTheRealModeFollowsThePredicate() {
    XCTAssertEqual(gate([:], real: true).mode, .real)
    XCTAssertEqual(gate([:], real: true).userDataDir, installed)
    XCTAssertEqual(gate([:]).mode, .off)
    XCTAssertEqual(gate(["SOLARA_DATA_DIR": "/tmp/s"]).mode, .off)
  }

  func testTheTestModeNeedsEverything() {
    let honoured = gate(testEnv)
    XCTAssertEqual(honoured.mode, .test)
    XCTAssertEqual(honoured.userDataDir.path, "/tmp/scratch/a/Chromium")
    XCTAssertEqual(gate(testEnv.merging(["SOLARA_DATA_DIR": "rel"]) { $1 }).userDataDir.path, "/cwd/rel/Chromium")
    XCTAssertEqual(
      gate(testEnv.merging(["SOLARA_DATA_DIR": "~/scratch"]) { $1 }).userDataDir.path,
      (NSHomeDirectory() as NSString).appendingPathComponent("scratch/Chromium"))
    for broken in [
      testEnv.merging(["SOLARA_TEST_REKEY": "yes"]) { $1 }, testEnv.merging(["SOLARA_DATA_DIR": ""]) { $1 },
      testEnv.filter { $0.key != "SOLARA_DATA_DIR" }, testEnv.filter { $0.key != "SOLARA_TEST_KEYCHAIN" },
      testEnv.merging(["SOLARA_TEST_KEYCHAIN": "login"]) { $1 },
    ] {
      let refused = gate(broken)
      XCTAssertEqual(refused.mode, .off, "\(broken)")
      XCTAssertNotNil(refused.refusal)
    }
    XCTAssertEqual(gate(testEnv, distribution: true).mode, .off)
    XCTAssertEqual(gate(testEnv.filter { $0.key != "SOLARA_DATA_DIR" }, real: true).mode, .off)
  }

  func testOnlyTheRealModeBuildsTheLoginKeychain() {
    XCTAssertTrue(gate(testEnv).keychain(product: "Solara", environment: testEnv) is RekeyFileKeychain)
    XCTAssertNil(gate([:]).keychain(product: "Solara", environment: [:]))
    XCTAssertNil(gate(testEnv, distribution: true).keychain(product: "Solara", environment: testEnv))
    let login = gate([:], real: true).keychain(product: "Solara", environment: [:]) as? RekeyLoginKeychain
    XCTAssertEqual(login?.service, "Solara Safe Storage")
    XCTAssertEqual(login?.account, "Solara")
  }

  func testSyncReadsTheTestKeyWheneverChromeDoes() throws {
    let scratch = SyncTestDirectory.url.appendingPathComponent("rekey-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let chromium = scratch.appendingPathComponent("Chromium")
    try FileManager.default.createDirectory(at: chromium, withIntermediateDirectories: true)
    let env = testEnv.merging(["SOLARA_DATA_DIR": scratch.path]) { $1 }
    func secret(_ env: [String: String], real: Bool = false, distribution: Bool = false) -> Data? {
      SafeStorageRekeyGate.testKeychainSecret(environment: env, chromeUsesRealKeychain: real, signedForDistribution: distribution, currentDirectory: "/cwd")
    }
    XCTAssertNil(secret(env))
    try Data("bmV3LXNlY3JldC1rZXkxMg==".utf8).write(to: chromium.appendingPathComponent("Test Safe Storage Key"))
    XCTAssertEqual(secret(env), Data("bmV3LXNlY3JldC1rZXkxMg==".utf8))
    XCTAssertEqual(secret(env.filter { $0.key != "SOLARA_TEST_REKEY" }), Data("bmV3LXNlY3JldC1rZXkxMg==".utf8))
    XCTAssertNil(secret(env.filter { $0.key != "SOLARA_DATA_DIR" }))
    XCTAssertNil(secret(env.merging(["SOLARA_DATA_DIR": ""]) { $1 }))
    XCTAssertNil(secret(env.filter { $0.key != "SOLARA_TEST_KEYCHAIN" }))
    XCTAssertNil(secret(env, real: true))
    XCTAssertNil(secret(env, distribution: true))
    XCTAssertNil(SafeStorageRekeyGate.testKeychainSecret(environment: env.filter { $0.key != "SOLARA_TEST_KEYCHAIN" }, chromeUsesRealKeychain: false))
    XCTAssertNil(SafeStorageRekeyGate.testKeychainSecret(environment: env, chromeUsesRealKeychain: true))
  }

  func testTheFileKeychainHonoursPlantedFailures() {
    XCTAssertEqual(RekeyFileKeychain.failure(named: "denied"), errSecAuthFailed)
    XCTAssertEqual(RekeyFileKeychain.failure(named: nil), errSecSuccess)
  }
}
