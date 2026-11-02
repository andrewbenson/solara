import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class SyncCreationAdmissionTests: XCTestCase {
  final class Files: DiscoveryFileSystem {
    var scan: DiscoveryScan = .listing([], dataless: false, truncated: false)
    func scan(_ folder: URL, limit: Int) -> DiscoveryScan { scan }
    func requestDownload(_ url: URL) {}
  }

  let folder = URL(fileURLWithPath: "/private/tmp/piece6-sync-creation")
  var cid: String { SyncKeys(entropy: Data(repeating: 7, count: 32)).chainTag }

  func testC01ExistingRequiresExactExplicitInspectionAndConsumesOnce() throws {
    let files = Files()
    files.scan = .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: false)
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    XCTAssertEqual(inspection.candidates, [cid])
    XCTAssertEqual(inspection.completeness, "complete")
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: nil))
    XCTAssertTrue(gate.consent(inspectionID: inspection.id))
    let commit = try gate.admit(folder: folder, inspectionID: inspection.id)
    XCTAssertFalse(gate.consent(inspectionID: inspection.id))
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
    commit()
  }

  func testC02EmptyThenLateCandidateRequiresWarning() {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    XCTAssertEqual(inspection.completeness, "complete")
    files.scan = .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: false)
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
  }

  func testC03FolderAndCandidateChangesRevokeConsent() {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    XCTAssertThrowsError(try gate.admit(folder: folder.appendingPathComponent("different"), inspectionID: inspection.id))
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
  }

  func testC04AllUnknownAndFoundIncompleteRefuseBeforeEffects() {
    let files = Files()
    for scan: DiscoveryScan in [.unavailable, .denied, .listing([], dataless: true, truncated: false), .listing([], dataless: false, truncated: true), .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: true, truncated: false), .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: true)] {
      files.scan = scan
      let gate = SyncCreationAdmission(fileSystem: files)
      let inspection = gate.inspect(folder: folder)
      XCTAssertNotEqual(inspection.completeness, "complete")
      XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
      XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: nil))
    }
  }

  func testC05MissingForgedReusedAndForeignPermitsFail() throws {
    let files = Files()
    let a = SyncCreationAdmission(fileSystem: files)
    let b = SyncCreationAdmission(fileSystem: files)
    let inspection = a.inspect(folder: folder)
    XCTAssertThrowsError(try b.admit(folder: folder, inspectionID: inspection.id))
    XCTAssertThrowsError(try a.admit(folder: folder, inspectionID: "forged"))
    let done = try a.admit(folder: folder, inspectionID: inspection.id)
    XCTAssertThrowsError(try a.admit(folder: folder, inspectionID: inspection.id))
    done()
  }

  func testC06CompleteEmptyDirectCreationAndExplicitSeparateAreAllowed() throws {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let done = try gate.admit(folder: folder, inspectionID: nil)
    done()
    let again = try gate.admit(folder: folder, inspectionID: nil)
    again()
  }
  func testC03CancelledPermitAndActiveCreationAreRevoked() throws {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    gate.invalidate(inspectionID: inspection.id)
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
    let next = gate.inspect(folder: folder)
    let finish = try gate.admit(folder: folder, inspectionID: next.id)
    gate.invalidate(inspectionID: next.id)
    XCTAssertThrowsError(try gate.recheck(folder: folder, reservation: finish))
    finish()
  }

  func testC02CandidateArrivesDuringKeySaveRecheckRefuses() throws {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let finish = try gate.admit(folder: folder, inspectionID: nil)
    defer { finish() }
    files.scan = .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: false)
    XCTAssertThrowsError(try gate.recheck(folder: folder, reservation: finish))
  }

  func testC03InvalidationBeforeCommitCausesNoChainEffect() throws {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    let finish = try gate.admit(folder: folder, inspectionID: inspection.id)
    defer { finish() }
    gate.invalidate(inspectionID: inspection.id)
    var effects = 0
    XCTAssertThrowsError(try gate.commit(folder: folder, reservation: finish) { effects += 1 })
    XCTAssertEqual(effects, 0)
  }

  func testC06ExplicitNewChainPreservesExistingCIDBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("creation-preservation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = SyncVault(folder: root, keys: SyncKeys(entropy: Data(repeating: 1, count: 32)))
    let new = SyncVault(folder: root, keys: SyncKeys(entropy: Data(repeating: 2, count: 32)))
    try old.createChain()
    let preserved = old.chainURL.appendingPathComponent("preserve.nns")
    let bytes = Data([1, 2, 3, 4, 5])
    try bytes.write(to: preserved)
    let gate = SyncCreationAdmission()
    let inspection = gate.inspect(folder: root)
    XCTAssertEqual(inspection.candidates, [old.keys.chainTag])
    XCTAssertTrue(gate.consent(inspectionID: inspection.id))
    let finish = try gate.admit(folder: root, inspectionID: inspection.id)
    defer { finish() }
    try gate.commit(folder: root, reservation: finish) { try new.createChain() }
    XCTAssertTrue(new.chainExists())
    XCTAssertNotEqual(new.keys.chainTag, old.keys.chainTag)
    XCTAssertEqual(try Data(contentsOf: preserved), bytes)
  }

  func testC04AsyncDiscoveryUsesTheBoundedDiscoveryResult() {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let complete = expectation(description: "bounded creation discovery")
    gate.discover(folder: folder) { inspection in
      XCTAssertEqual(inspection.completeness, "complete")
      XCTAssertFalse(inspection.id.isEmpty)
      complete.fulfill()
    }
    wait(for: [complete], timeout: 2)
  }

  func testC05OldReservationCannotCommitReplacementAfterCancellation() throws {
    let files = Files()
    let gate = SyncCreationAdmission(fileSystem: files)
    let oldInspection = gate.inspect(folder: folder)
    let old = try gate.admit(folder: folder, inspectionID: oldInspection.id)
    gate.invalidate(inspectionID: oldInspection.id)
    let replacementInspection = gate.inspect(folder: folder)
    let replacement = try gate.admit(folder: folder, inspectionID: replacementInspection.id)
    defer { replacement() }
    var effects = 0
    XCTAssertThrowsError(try gate.commit(folder: folder, reservation: old) { effects += 1 })
    XCTAssertThrowsError(try gate.recheck(folder: folder, reservation: old))
    XCTAssertEqual(effects, 0)
    old()
    XCTAssertNoThrow(try gate.recheck(folder: folder, reservation: replacement))
  }

  func testC01InspectedExistingCandidateWithoutNativeConsentCannotCreate() {
    let files = Files()
    files.scan = .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: false)
    let gate = SyncCreationAdmission(fileSystem: files)
    let inspection = gate.inspect(folder: folder)
    XCTAssertEqual(inspection.candidates, [cid])
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: inspection.id))
  }

  func testC03NativeConsentDoesNotSurviveCancellationOrAuthorizeReplacement() {
    let files = Files()
    files.scan = .listing([DiscoveryEntry(name: cid, isRealDirectory: true, activity: nil)], dataless: false, truncated: false)
    let gate = SyncCreationAdmission(fileSystem: files)
    let old = gate.inspect(folder: folder)
    XCTAssertTrue(gate.consent(inspectionID: old.id))
    gate.invalidate(inspectionID: old.id)
    XCTAssertFalse(gate.consent(inspectionID: old.id))
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: old.id))
    let replacement = gate.inspect(folder: folder)
    XCTAssertThrowsError(try gate.admit(folder: folder, inspectionID: replacement.id))
  }

  func testC04UnknownOrForeignInspectionCannotGainNativeConsent() {
    let files = Files()
    files.scan = .unavailable
    let a = SyncCreationAdmission(fileSystem: files)
    let b = SyncCreationAdmission(fileSystem: files)
    let unknown = a.inspect(folder: folder)
    XCTAssertFalse(a.consent(inspectionID: unknown.id))
    XCTAssertFalse(b.consent(inspectionID: unknown.id))
    XCTAssertFalse(a.consent(inspectionID: "forged"))
  }

}
