import Security
import XCTest
@testable import SolaraShellCore

final class VerifiedStagedLaunchTests: XCTestCase {
  let bundleId = "com.test.staged"
  var root: URL!
  var app: URL!
  var executable: URL!
  var marker: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("verified-staged-\(UUID().uuidString)", isDirectory: true)
    app = root.appendingPathComponent("Installation/a1/b2/Solara.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleVersion": "2", "CFBundleExecutable": "staged",
                               "CFBundlePackageType": "APPL", "ACUpdateChannel": "stable"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    executable = macOS.appendingPathComponent("staged")
    marker = root.appendingPathComponent("ran")
    try compile(writing: "genuine", exit: 7, to: executable)
    try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func run(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
  }

  func compile(writing text: String, exit code: Int, to output: URL) throws {
    let source = root.appendingPathComponent("\(text).c")
    try """
      #include <stdio.h>
      #include <stdlib.h>
      int main(void) {
        FILE *f = fopen(getenv("MARKER"), "w");
        if (f) { fputs("\(text)", f); fclose(f); }
        return \(code);
      }
      """.write(to: source, atomically: true, encoding: .utf8)
    try run("/usr/bin/xcrun", "clang", "-o", output.path, source.path)
  }

  func requirement(_ text: String) throws -> SecRequirement {
    var requirement: SecRequirement?
    XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
    return try XCTUnwrap(requirement)
  }

  func designatedRequirement() throws -> SecRequirement {
    var code: SecStaticCode?
    XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
    var requirement: SecRequirement?
    XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(code), [], &requirement), errSecSuccess)
    return try XCTUnwrap(requirement)
  }

  func stagedCopy() throws -> StagedCopy {
    let copies = StagedUpdates.copies(bundleId: bundleId, base: root, folders: ["Installation"])
    XCTAssertEqual(copies.count, 1)
    return try XCTUnwrap(copies.first)
  }

  func waitForExit(_ pid: pid_t) -> Int? {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let status = VerifiedLaunch.reap(pid) { return status }
      usleep(10_000)
    }
    return nil
  }

  func refuse(_ pid: pid_t) {
    kill(pid, SIGKILL)
    XCTAssertEqual(waitForExit(pid), Int(SIGKILL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testTheStagedCopyItVerifiedRunsOnceResumed() throws {
    let verified = try XCTUnwrap(VerifiedLaunch.verify(try stagedCopy(), requirement: try designatedRequirement()))
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    XCTAssertTrue(VerifiedLaunch.isGenuine(pid: pid, verified: verified, inside: app))
    XCTAssertEqual(kill(pid, SIGCONT), 0)
    XCTAssertEqual(waitForExit(pid), 7)
  }

  func testOtherCodeMeetingTheSameRequirementIsRefused() throws {
    let sameName = try requirement("identifier \"\(bundleId)\"")
    let verified = try XCTUnwrap(VerifiedLaunch.verify(try stagedCopy(), requirement: sameName))
    let impostor = root.appendingPathComponent("impostor/staged")
    try FileManager.default.createDirectory(at: impostor.deletingLastPathComponent(), withIntermediateDirectories: true)
    try compile(writing: "impostor", exit: 2, to: impostor)
    try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundleId, impostor.path)
    _ = try FileManager.default.replaceItemAt(executable, withItemAt: impostor)
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    XCTAssertFalse(VerifiedLaunch.isGenuine(pid: pid, verified: verified, inside: app))
    refuse(pid)
  }

  func testACopyWhoseRecordDisagreesWithItsSignatureIsNotVerified() throws {
    let found = try stagedCopy()
    let misread = StagedCopy(base: found.base, path: found.path, executableName: found.executableName, bundleId: found.bundleId,
                             version: "9", channel: found.channel, modified: found.modified,
                             bundleIdentity: found.bundleIdentity, executableIdentity: found.executableIdentity)
    XCTAssertNil(VerifiedLaunch.verify(misread, requirement: try designatedRequirement()))
  }

  func testACopyChangedAfterItWasFoundIsNotVerified() throws {
    let found = try stagedCopy()
    let rebuilt = root.appendingPathComponent("rebuilt")
    try compile(writing: "rebuilt", exit: 3, to: rebuilt)
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.moveItem(at: rebuilt, to: executable)
    XCTAssertNil(VerifiedLaunch.verify(found, requirement: try designatedRequirement()))
  }

  func testAnUnsignedCopyIsNotVerified() throws {
    try run("/usr/bin/codesign", "--remove-signature", app.path)
    XCTAssertNil(VerifiedLaunch.verify(try stagedCopy(), requirement: try requirement("identifier \"\(bundleId)\"")))
  }
}
