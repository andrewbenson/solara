import Darwin
import XCTest
@testable import SolaraShellCore

final class StagedUpdatesTests: XCTestCase {
  let bundleId = "com.test.staged"
  var root: URL!
  var installation: URL!
  var outside: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("staged-updates-\(UUID().uuidString)", isDirectory: true)
    installation = root.appendingPathComponent("Installation", isDirectory: true)
    outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  func makeApp(at app: URL, id: String? = nil, version: String = "2", channel: String? = "stable",
               executable: String = "Staged") throws -> URL {
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": id ?? bundleId, "CFBundleVersion": version, "CFBundleExecutable": executable]
    if let channel { info["ACUpdateChannel"] = channel }
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let binary = macOS.appendingPathComponent("Staged")
    try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return app
  }

  func staged(_ relative: String) -> URL {
    installation.appendingPathComponent(relative, isDirectory: true)
  }

  func found() -> [StagedCopy] {
    StagedUpdates.copies(bundleId: bundleId, base: root, folders: ["Installation"])
  }

  func testFindsACopyInSparklesLayout() throws {
    try makeApp(at: staged("a1/b2/Solara.app"), version: "7", channel: "nightly")
    let copies = found()
    XCTAssertEqual(copies.count, 1)
    XCTAssertEqual(copies.first?.version, "7")
    XCTAssertEqual(copies.first?.channel, "nightly")
    XCTAssertEqual(copies.first?.bundleURL.lastPathComponent, "Solara.app")
    XCTAssertEqual(copies.first?.executableURL.path.hasSuffix("Solara.app/Contents/MacOS/Staged"), true)
  }

  func testIgnoresOtherApps() throws {
    try makeApp(at: staged("a1/Other.app"), id: "com.example.other")
    XCTAssertTrue(found().isEmpty)
  }

  func testFindsCopiesDownToTheDeepestLevelAndNoFurther() throws {
    try makeApp(at: staged("1/2/3/Deep.app"), version: "4")
    try makeApp(at: staged("1/2/3/4/TooDeep.app"), version: "5")
    XCTAssertEqual(found().map(\.version), ["4"])
  }

  func testSkipsAnAppThatIsASymlinkToACopyElsewhere() throws {
    let real = try makeApp(at: outside.appendingPathComponent("Real.app"))
    try FileManager.default.createDirectory(at: staged("a1"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: staged("a1/Link.app"), withDestinationURL: real)
    XCTAssertTrue(found().isEmpty)
  }

  func testDoesNotWalkIntoASymlinkedFolder() throws {
    try makeApp(at: outside.appendingPathComponent("Real.app"))
    try FileManager.default.createSymbolicLink(at: staged("a1"), withDestinationURL: outside)
    XCTAssertTrue(found().isEmpty)
  }

  func testRefusesAnInstallationFolderThatIsASymlink() throws {
    try makeApp(at: outside.appendingPathComponent("a1/Real.app"))
    try FileManager.default.removeItem(at: installation)
    try FileManager.default.createSymbolicLink(at: installation, withDestinationURL: outside)
    XCTAssertTrue(found().isEmpty)
  }

  func testSkipsACopyWhoseExecutableIsASymlink() throws {
    let app = try makeApp(at: staged("a1/Solara.app"))
    let binary = app.appendingPathComponent("Contents/MacOS/Staged")
    let elsewhere = outside.appendingPathComponent("tool")
    try FileManager.default.moveItem(at: binary, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: elsewhere)
    XCTAssertTrue(found().isEmpty)
  }

  func testSkipsACopyWhoseInfoPlistIsASymlink() throws {
    let app = try makeApp(at: staged("a1/Solara.app"))
    let plist = app.appendingPathComponent("Contents/Info.plist")
    let elsewhere = outside.appendingPathComponent("Info.plist")
    try FileManager.default.moveItem(at: plist, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: elsewhere)
    XCTAssertTrue(found().isEmpty)
  }

  func testSkipsAnExecutableNameThatLeavesTheBundle() throws {
    let app = try makeApp(at: staged("a1/Solara.app"), executable: "../../../../../Outside/tool")
    let escaped = app.appendingPathComponent("Contents/MacOS/../../../../../Outside/tool").standardizedFileURL
    try "#!/bin/sh\n".write(to: escaped, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: escaped.path)
    XCTAssertEqual(escaped.path, outside.appendingPathComponent("tool").standardizedFileURL.path)
    XCTAssertTrue(found().isEmpty)
  }

  func testSkipsACopyWhoseExecutableCannotRun() throws {
    let app = try makeApp(at: staged("a1/Solara.app"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Staged").path)
    XCTAssertTrue(found().isEmpty)
  }

  func testReadsFreshMetadataWhenACopyIsReplacedAtTheSamePath() throws {
    let app = staged("a1/Solara.app")
    try makeApp(at: app, version: "2")
    XCTAssertEqual(found().map(\.version), ["2"])
    try FileManager.default.removeItem(at: app)
    try makeApp(at: app, version: "3", channel: "nightly")
    XCTAssertEqual(found().map(\.version), ["3"])
    XCTAssertEqual(found().first?.channel, "nightly")
  }

  func testTheNewestCopyOfTheVersionWins() throws {
    let older = try makeApp(at: staged("a1/Solara.app"), version: "2")
    try makeApp(at: staged("b1/Solara.app"), version: "2")
    try makeApp(at: staged("c1/Solara.app"), version: "3")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
    let newest = StagedUpdates.newest(of: found(), version: "2")
    XCTAssertEqual(newest?.bundleURL.deletingLastPathComponent().lastPathComponent, "b1")
  }

  func testACopyReplacedAfterItWasFoundIsNoLongerUnchanged() throws {
    let app = try makeApp(at: staged("a1/Solara.app"))
    let copy = try XCTUnwrap(found().first)
    XCTAssertTrue(StagedUpdates.isUnchanged(copy))
    let binary = app.appendingPathComponent("Contents/MacOS/Staged")
    try FileManager.default.removeItem(at: binary)
    try "#!/bin/sh\nexit 1\n".write(to: binary, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    XCTAssertFalse(StagedUpdates.isUnchanged(copy))
  }

  func testAMissingInstallationFolderFindsNothing() throws {
    try FileManager.default.removeItem(at: installation)
    let scan = StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"])
    XCTAssertTrue(scan.copies.isEmpty)
    XCTAssertTrue(scan.complete)
  }

  func testASymlinkedInstallationFolderMakesTheScanIncomplete() throws {
    try FileManager.default.removeItem(at: installation)
    try FileManager.default.createSymbolicLink(at: installation, withDestinationURL: outside)
    XCTAssertFalse(StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"]).complete)
  }

  func testAFolderWithMoreEntriesThanTheLimitMakesTheScanIncomplete() throws {
    for index in 0...StagedUpdates.mostEntriesPerFolder {
      try FileManager.default.createDirectory(at: staged("r\(index)"), withIntermediateDirectories: true)
    }
    try makeApp(at: staged("zz/Solara.app"), channel: "nightly")
    let scan = StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"])
    XCTAssertFalse(scan.complete)
  }

  func testAFolderDeeperThanTheWalkMakesTheScanIncomplete() throws {
    try makeApp(at: staged("1/2/3/4/TooDeep.app"))
    XCTAssertFalse(StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"]).complete)
  }

  func testSparklesLayoutScansCompletely() throws {
    try makeApp(at: staged("a1/b2/Solara.app"))
    XCTAssertTrue(StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"]).complete)
  }

  func testAStagedNightlyCountsEvenWhenItCannotBeLaunched() throws {
    let app = try makeApp(at: staged("a1/Solara.app"), channel: "nightly")
    try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/Staged"))
    let scan = StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"])
    XCTAssertTrue(scan.copies.isEmpty)
    XCTAssertEqual(scan.channels, ["nightly"])
  }

  func testAnAppWhoseContentsIsASymlinkMakesTheScanIncomplete() throws {
    let app = try makeApp(at: staged("a1/Solara.app"), channel: "nightly")
    let contents = app.appendingPathComponent("Contents")
    let moved = outside.appendingPathComponent("Contents")
    try FileManager.default.moveItem(at: contents, to: moved)
    try FileManager.default.createSymbolicLink(at: contents, withDestinationURL: moved)
    let scan = StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"])
    XCTAssertTrue(scan.copies.isEmpty)
    XCTAssertFalse(scan.complete)
  }

  func testAnAppWhoseContentsCannotBeOpenedMakesTheScanIncomplete() throws {
    let app = try makeApp(at: staged("a1/Solara.app"), channel: "nightly")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: contents.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.path) }
    XCTAssertFalse(StagedUpdates.scan(bundleId: bundleId, base: root, folders: ["Installation"]).complete)
  }

  func testACopyWhoseContentsBecomeASymlinkIsNoLongerUnchanged() throws {
    let app = try makeApp(at: staged("a1/Solara.app"))
    let copy = try XCTUnwrap(found().first)
    let contents = app.appendingPathComponent("Contents")
    let moved = outside.appendingPathComponent("Contents")
    try FileManager.default.moveItem(at: contents, to: moved)
    try FileManager.default.createSymbolicLink(at: contents, withDestinationURL: moved)
    XCTAssertFalse(StagedUpdates.isUnchanged(copy))
  }
}
