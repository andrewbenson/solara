import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingInstallationRecoveryTests: XCTestCase {
  final class Keys: PairingInstallationKeyStoring {
    var result: PairingKeyLookup
    var lookups: [String] = []
    var inserts = 0
    init(_ result: PairingKeyLookup) { self.result = result }
    func pairingLookup(account: String) -> PairingKeyLookup { lookups.append(account); return result }
    func pairingInsert(_ secret: Data, account: String) -> Bool { inserts += 1; return false }
  }

  let root = Data(repeating: 1, count: 32)
  func cid() throws -> Data { try PairingFormat.cid(SyncKeys(entropy: root).chainTag) }

  func testPreparedRequiresAffirmativeAbsenceForUnusedDisposition() throws {
    for stage in PairingInstallationRecovery.Stage.allCases {
      let keys = Keys(.absent)
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: "installation", keys: keys), stage == .prepared ? .unused : .blocked)
      XCTAssertEqual(keys.lookups, ["installation"])
      XCTAssertEqual(keys.inserts, 0)
    }
  }

  func testAccessFailurePreservesEveryRecoveryStage() throws {
    for stage in PairingInstallationRecovery.Stage.allCases {
      let keys = Keys(.failure)
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: "installation", keys: keys), .blocked)
      XCTAssertEqual(keys.lookups, ["installation"])
      XCTAssertEqual(keys.inserts, 0)
    }
  }

  func testMatchingSavedRootWithoutAdmissionIsOrphanAtEveryStage() throws {
    for stage in PairingInstallationRecovery.Stage.allCases {
      let keys = Keys(.found(root))
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: "installation", keys: keys), .orphan)
      XCTAssertEqual(keys.lookups, ["installation"])
      XCTAssertEqual(keys.inserts, 0)
    }
  }

  func testMalformedAndConflictingRootsPreserveEveryRecoveryStage() throws {
    for stage in PairingInstallationRecovery.Stage.allCases {
      for bad in [Data(), Data(count: 31), Data(count: 33), Data(repeating: 2, count: 32)] {
        let keys = Keys(.found(bad))
        XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: "installation", keys: keys), .blocked)
        XCTAssertEqual(keys.lookups, ["installation"])
        XCTAssertEqual(keys.inserts, 0)
      }
    }
  }

  func testUnsupportedDocumentsPreserveAccountsWithoutLookupAtEveryStage() throws {
    for stage in PairingInstallationRecovery.Stage.allCases {
      for status in [PairingKeyLookup.absent, .failure, .found(root)] {
        let keys = Keys(status)
        XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: "installation", keys: keys, localVersion: 3), .blocked)
        XCTAssertEqual(keys.lookups, [])
        XCTAssertEqual(keys.inserts, 0)
      }
    }
  }

  func testInvalidNativeBindingsRefuseWithoutKeychainLookup() throws {
    for cid in [Data(), Data(count: 15), Data(count: 17)] {
      let keys = Keys(.absent)
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: cid, account: "installation", keys: keys), .blocked)
      XCTAssertEqual(keys.lookups, [])
    }
    let keys = Keys(.absent)
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try cid(), account: "", keys: keys), .blocked)
    XCTAssertEqual(keys.lookups, [])
  }
  func testOnlyExactDurablyAdmittedInstallationResumes() throws {
    let installation = PairingInstallation(transaction: Data(repeating: 2, count: 32), cid: SyncKeys(entropy: root).chainTag, device: Base32.encode(Data(repeating: 3, count: 16)), folderIdentity: Data([4]), generation: 1)
    for disposition in [PairingInstallationDecision.Disposition.admitted, .cancelled] {
      let store = PairingCoordinatorTests.Store()
      _ = try store.persistInstallationDecision(.init(installation: installation, disposition: disposition))
      for stage in PairingInstallationRecovery.Stage.allCases {
        XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: installation.device, keys: Keys(.found(root)), installation: installation, store: store), disposition == .admitted ? .saved : .orphan)
        for missing in [PairingKeyLookup.absent, .failure, .found(Data(count: 31)), .found(Data(repeating: 9, count: 32))] {
          XCTAssertNotEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: installation.device, keys: Keys(missing), installation: installation, store: store), .saved)
        }
      }
      let changed = PairingInstallation(transaction: installation.transaction, cid: installation.cid, device: installation.device, folderIdentity: Data([5]), generation: installation.generation)
      XCTAssertNotEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try cid(), account: installation.device, keys: Keys(.found(root)), installation: changed, store: store), .saved)
    }
  }

  func testAdmittedInstallationWithMissingKeyNeverBecomesUnused() throws {
    let installation = PairingInstallation(transaction: Data(repeating: 2, count: 32), cid: SyncKeys(entropy: root).chainTag, device: Base32.encode(Data(repeating: 3, count: 16)), folderIdentity: Data([4]), generation: 1)
    let store = PairingCoordinatorTests.Store()
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    for stage in PairingInstallationRecovery.Stage.allCases {
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: stage, selectedCID: try cid(), account: installation.device, keys: Keys(.absent), installation: installation, store: store), .blocked)
    }
  }

}
