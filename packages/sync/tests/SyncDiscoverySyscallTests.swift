import Darwin
import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class SyncDiscoverySyscallTests: XCTestCase {
  func testReaddirErrorCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 1, method: "testReaddirErrorCannotAdmitCreationWithoutConsent")
  }

  func testCanonicalMetadataErrorCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 2, method: "testCanonicalMetadataErrorCannotAdmitCreationWithoutConsent")
  }

  func testSuccessfulReaddirResetsErrnoBeforeEOF() throws {
    try exercise(mode: 3, method: "testSuccessfulReaddirResetsErrnoBeforeEOF")
  }

  func testRootPlaceholderMetadataErrorCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 4, method: "testRootPlaceholderMetadataErrorCannotAdmitCreationWithoutConsent")
  }

  func testRootPlaceholderParentOpenErrorCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 5, method: "testRootPlaceholderParentOpenErrorCannotAdmitCreationWithoutConsent")
  }

  func testRootResourceMetadataErrorCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 6, method: "testRootResourceMetadataErrorCannotAdmitCreationWithoutConsent")
  }

  func testMissingUbiquitousDownloadStatusCannotAdmitCreationWithoutConsent() throws {
    try exercise(mode: 7, method: "testMissingUbiquitousDownloadStatusCannotAdmitCreationWithoutConsent")
  }

  func testMissingLocalUbiquitousFlagStillAllowsConfirmedEmptyFolder() throws {
    try exercise(mode: 8, method: "testMissingLocalUbiquitousFlagStillAllowsConfirmedEmptyFolder")
  }

  private func exercise(mode: Int32, method: String) throws {
    let files = FileManager.default
    if ProcessInfo.processInfo.environment["SOLARA_DISCOVERY_FAULT_CHILD"] != "1" {
      let temporary = files.temporaryDirectory.appendingPathComponent("discovery-syscalls-\(UUID().uuidString)")
      try files.createDirectory(at: temporary, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: temporary) }
      let shim = temporary.appendingPathComponent("syscalls.dylib")
      let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/discovery-syscalls.c")
      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
      compiler.arguments = ["-dynamiclib", source.path, "-framework", "Foundation", "-o", shim.path]
      try run(compiler)
      XCTAssertEqual(compiler.terminationStatus, 0)
      guard compiler.terminationStatus == 0 else { return }
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
      child.arguments = ["-XCTest", "SolaraLegacySyncCoreTests.SyncDiscoverySyscallTests/\(method)", Bundle(for: Self.self).bundleURL.path]
      var environment = ProcessInfo.processInfo.environment
      environment["DYLD_INSERT_LIBRARIES"] = shim.path
      environment["SOLARA_DISCOVERY_FAULT_CHILD"] = "1"
      environment["SOLARA_DISCOVERY_FAULT_ROOT"] = temporary.appendingPathComponent("folder").path
      environment["SOLARA_DISCOVERY_FAULT_PARENT"] = temporary.path
      child.environment = environment
      let output = temporary.appendingPathComponent("child.log")
      XCTAssertTrue(files.createFile(atPath: output.path, contents: nil))
      let handle = try FileHandle(forWritingTo: output)
      child.standardOutput = handle
      child.standardError = handle
      try run(child)
      try handle.close()
      let log = try String(contentsOf: output)
      let report = log.components(separatedBy: "\n").map { "syscall child: \($0)" }.joined(separator: "\n")
      print(report)
      XCTAssertTrue(log.contains("Executed 1 test"), "Child must complete exactly one test")
      XCTAssertEqual(child.terminationStatus, 0, report)
      return
    }
    let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SOLARA_DISCOVERY_FAULT_ROOT"]))
    let cid = SyncKeys(entropy: Data(repeating: 7, count: 32)).chainTag
    let placeholder = root.deletingLastPathComponent().appendingPathComponent(".folder.icloud")
    if mode == 4 || mode == 5 {
      XCTAssertTrue(files.createFile(atPath: placeholder.path, contents: Data()))
    } else if mode >= 6 {
      try files.createDirectory(at: root, withIntermediateDirectories: true)
    } else {
      try files.createDirectory(at: root.appendingPathComponent(cid), withIntermediateDirectories: true)
    }
    setenv("SOLARA_DISCOVERY_FAULT_CID", cid, 1)
    let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "solara_discovery_fault"))
    let fault = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
    let hitsSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "solara_discovery_fault_hits"))
    let hits = unsafeBitCast(hitsSymbol, to: (@convention(c) () -> Int32).self)
    fault(0)
    let gate = SyncCreationAdmission()
    if mode >= 6 {
      try exerciseRootResourceMetadata(root: root, gate: gate, mode: mode, fault: fault, hits: hits)
      return
    }
    if mode >= 4 {
      try exerciseRootPlaceholder(root: root, placeholder: placeholder, gate: gate, mode: mode, fault: fault, hits: hits)
      return
    }
    let control = gate.inspect(folder: root)
    XCTAssertEqual(control.candidates, [cid])
    XCTAssertEqual(control.completeness, "complete")
    fault(mode)
    defer { fault(0) }
    let inspection = gate.inspect(folder: root)
    XCTAssertGreaterThan(hits(), 0, "The real scanner must enter the syscall shim")
    if mode == 3 {
      XCTAssertEqual(inspection.candidates, [cid])
      XCTAssertEqual(inspection.completeness, "complete")
      return
    }
    XCTAssertNotEqual(inspection.completeness, "complete", "A real syscall failure cannot affirm an empty folder")
    XCTAssertFalse(gate.consent(inspectionID: inspection.id))
    var effects = 0
    if let reservation = try? gate.admit(folder: root, inspectionID: nil) {
      try? gate.commit(folder: root, reservation: reservation) { effects += 1 }
      reservation()
      XCTFail("Creation without native consent must refuse an unknown filesystem result")
    }
    if let reservation = try? gate.admit(folder: root, inspectionID: inspection.id) {
      defer { reservation() }
      try? gate.commit(folder: root, reservation: reservation) { effects += 1 }
    }
    XCTAssertEqual(effects, 0)
    fault(0)
    let recovered = gate.inspect(folder: root)
    XCTAssertEqual(recovered.candidates, [cid])
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: nil))
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: recovered.id))
    let consented = gate.inspect(folder: root)
    XCTAssertTrue(gate.consent(inspectionID: consented.id))
    let reservation = try gate.admit(folder: root, inspectionID: consented.id)
    defer { reservation() }
    let beforeConsent = effects
    fault(mode)
    XCTAssertThrowsError(try gate.recheck(folder: root, reservation: reservation))
    XCTAssertThrowsError(try gate.commit(folder: root, reservation: reservation) { effects += 1 })
    XCTAssertEqual(effects, beforeConsent)
    fault(0)
    try gate.commit(folder: root, reservation: reservation) { effects += 1 }
    XCTAssertEqual(effects, beforeConsent + 1)
  }
  private func exerciseRootPlaceholder(root: URL, placeholder: URL, gate: SyncCreationAdmission, mode: Int32, fault: @convention(c) (Int32) -> Void, hits: @convention(c) () -> Int32) throws {
    let files = FileManager.default
    let control = gate.inspect(folder: root)
    XCTAssertEqual(control.candidates, [])
    XCTAssertEqual(control.completeness, "needsHydration")
    fault(mode)
    defer { fault(0) }
    let inspection = gate.inspect(folder: root)
    var effects = 0
    var consentCalls = 0
    for inspectionID in [nil, inspection.id] {
      if let reservation = try? gate.admit(folder: root, inspectionID: inspectionID) {
        try? gate.commit(folder: root, reservation: reservation) { effects += 1 }
        reservation()
      }
    }
    print("PLACEHOLDER_FAULT mode=\(mode) control=\(control.completeness) fault=\(inspection.completeness) candidates=\(inspection.candidates) syscallHits=\(hits()) recordingEffects=\(effects) consentCalls=\(consentCalls)")
    XCTAssertGreaterThan(hits(), 0, "The real scanner must enter the syscall shim")
    XCTAssertNotEqual(inspection.completeness, "complete", "Unknown placeholder state cannot affirm an empty folder")
    XCTAssertEqual(effects, 0, "Unknown placeholder state must prevent both direct and inspected recording actions")
    XCTAssertEqual(consentCalls, 0)
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: nil))
    let rejected = gate.inspect(folder: root)
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: rejected.id))
    consentCalls += 1
    XCTAssertFalse(gate.consent(inspectionID: inspection.id))
    fault(0)
    XCTAssertEqual(gate.inspect(folder: root).completeness, "needsHydration")
    try files.removeItem(at: placeholder)
    XCTAssertEqual(gate.inspect(folder: root).completeness, "complete")
    let reservation = try gate.admit(folder: root, inspectionID: nil)
    defer { reservation() }
    XCTAssertTrue(files.createFile(atPath: placeholder.path, contents: Data()))
    fault(mode)
    let beforeRecheck = effects
    XCTAssertThrowsError(try gate.recheck(folder: root, reservation: reservation))
    XCTAssertThrowsError(try gate.commit(folder: root, reservation: reservation) { effects += 1 })
    XCTAssertEqual(effects, beforeRecheck)
    fault(0)
    XCTAssertThrowsError(try gate.recheck(folder: root, reservation: reservation))
    try files.removeItem(at: placeholder)
    try gate.commit(folder: root, reservation: reservation) { effects += 1 }
    XCTAssertEqual(effects, beforeRecheck + 1)
  }

  private func exerciseRootResourceMetadata(root: URL, gate: SyncCreationAdmission, mode: Int32, fault: @convention(c) (Int32) -> Void, hits: @convention(c) () -> Int32) throws {
    let control = gate.inspect(folder: root)
    XCTAssertEqual(control.candidates, [])
    XCTAssertEqual(control.completeness, "complete")
    fault(mode)
    defer { fault(0) }
    let inspection = gate.inspect(folder: root)
    var effects = 0
    for inspectionID in [nil, inspection.id] {
      if let reservation = try? gate.admit(folder: root, inspectionID: inspectionID) {
        try? gate.commit(folder: root, reservation: reservation) { effects += 1 }
        reservation()
      }
    }
    print("RESOURCE_FAULT mode=\(mode) fault=\(inspection.completeness) candidates=\(inspection.candidates) metadataHits=\(hits()) recordingEffects=\(effects)")
    XCTAssertGreaterThan(hits(), 0, "The live scanner must enter the Foundation metadata shim")
    if mode == 8 {
      XCTAssertEqual(inspection.completeness, "complete")
      XCTAssertEqual(effects, 2)
      return
    }
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: nil))
    let rejected = gate.inspect(folder: root)
    XCTAssertThrowsError(try gate.admit(folder: root, inspectionID: rejected.id))
    XCTAssertNotEqual(inspection.completeness, "complete", "Unknown hydration metadata cannot affirm an empty folder")
    XCTAssertEqual(effects, 0)
    XCTAssertFalse(gate.consent(inspectionID: inspection.id))
    fault(0)
    XCTAssertEqual(gate.inspect(folder: root).completeness, "complete")
    let reservation = try gate.admit(folder: root, inspectionID: nil)
    defer { reservation() }
    fault(mode)
    let beforeRecheck = effects
    XCTAssertThrowsError(try gate.recheck(folder: root, reservation: reservation))
    XCTAssertThrowsError(try gate.commit(folder: root, reservation: reservation) { effects += 1 })
    XCTAssertEqual(effects, beforeRecheck)
    fault(0)
    try gate.commit(folder: root, reservation: reservation) { effects += 1 }
    XCTAssertEqual(effects, beforeRecheck + 1)
  }

  private func run(_ process: Process) throws {
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + 30) == .success else {
      process.terminate()
      _ = finished.wait(timeout: .now() + 2)
      XCTFail("Syscall test subprocess exceeded its deadline")
      throw NSError(domain: "SyncDiscoverySyscallTests", code: 1)
    }
  }
}
