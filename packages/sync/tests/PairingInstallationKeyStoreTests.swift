import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingInstallationKeyStoreTests: XCTestCase {
  func testInsertOnlyAndReadback() throws {
    let directory = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileKeyStore(directory: directory), secret = Data(repeating: 1, count: 32)
    XCTAssertEqual(store.pairingLookup(account: "fresh"), .absent)
    XCTAssertTrue(store.pairingInsert(secret, account: "fresh"))
    XCTAssertEqual(store.pairingLookup(account: "fresh"), .found(secret))
    XCTAssertFalse(store.pairingInsert(Data(repeating: 2, count: 32), account: "fresh"))
    XCTAssertEqual(store.pairingLookup(account: "fresh"), .found(secret))
  }

  func testFailureAndMalformedKeyAreNotAbsence() throws {
    let directory = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileKeyStore(directory: directory)
    try Data([1]).write(to: directory.appendingPathComponent("sync-key-bad"))
    XCTAssertEqual(store.pairingLookup(account: "bad"), .failure)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("sync-key-directory"), withIntermediateDirectories: false)
    XCTAssertEqual(store.pairingLookup(account: "directory"), .failure)
    XCTAssertFalse(store.pairingInsert(Data(count: 32), account: "../escape"))
  }
}
