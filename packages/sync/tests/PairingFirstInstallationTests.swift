import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingFirstInstallationTests: XCTestCase {
  private final class Fixture {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    var data: URL { root.appendingPathComponent("data") }
    var folder: URL { root.appendingPathComponent("remote") }
    var directory: URL { data.appendingPathComponent("Application Support/sync-pairing") }
    let entropy = Data(repeating: 47, count: 32)
    let account = Base32.encode(Data(repeating: 48, count: 16))
    var cid: String { SyncKeys(entropy: entropy).chainTag }
    var keys: FileKeyStore { FileKeyStore(directory: data) }
    init() throws {
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: folder.appendingPathComponent(cid), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func enable(version: Int = 1) throws {
      let document: [String: Any] = ["v": version, "enabled": true, "deviceId": account, "folder": folder.path]
      try JSONSerialization.data(withJSONObject: document).write(to: data.appendingPathComponent("sync.json"))
      XCTAssertTrue(keys.pairingInsert(entropy, account: account))
    }
    func disableVersionTwo() throws {
      let document: [String: Any] = ["v": 2, "enabled": false, "joining": false, "stopGeneration": 1, "deviceId": account, "folder": folder.path, "bootstrap": ["phase": "stopped", "transaction": NSNull(), "generation": 0]]
      try JSONSerialization.data(withJSONObject: document).write(to: data.appendingPathComponent("sync.json"))
    }
    func evidence() throws -> PairingFirstInstallationEvidence {
      let url = data.appendingPathComponent("sync.json")
      let state: Result<Data?, Error>
      if FileManager.default.fileExists(atPath: url.path) { state = Result { try PairingPOSIXDurableIO().read(url, limit: 4 * 1024 * 1024) } }
      else { state = .success(nil) }
      let document = (try? state.get()).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      return try PairingServices.firstInstallationEvidence(dataDirectory: data, syncState: state, version: document?["v"] as? Int, keyState: (document?["deviceId"] as? String).map { keys.pairingLookup(account: $0) })
    }
    func store() throws -> PairingDurableStore {
      try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: evidence())
    }
  }

  private func restoration(_ owner: PairingCoordinator) throws -> PairingSession.RestorationDisposition {
    try XCTUnwrap(Mirror(reflecting: owner).children.first { $0.label == "restoration" }?.value as? PairingSession.RestorationDisposition)
  }

  private func waitUntil(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    XCTAssertTrue(predicate())
  }

  private func drainConfigure(_ service: PairingServices) {
    XCTAssertThrowsError(try service.stopInstallation(nil, stopGeneration: 0)) {
      guard case PairingInstallationHost.Failure.invalid = $0 else { return XCTFail("expected rejected stop generation") }
    }
  }

  private func bootstrap(_ f: Fixture, safeMode: @escaping () -> Bool = { false }) -> PairingServices {
    let service = PairingServices(sessionDictionary: { ["kCGSSessionOnConsoleKey": true] })
    service.registerStore(healthy: { true }, revision: { 1 }, projection: { operation, _ in operation })
    service.bootstrap(dataDirectory: f.data, defaultFolder: f.folder, keys: f.keys, safeMode: safeMode)
    drainConfigure(service)
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    drainConfigure(service)
    return service
  }

  private func shutdown(_ service: PairingServices) {
    service.invalidate("shutdown")
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    drainConfigure(service)
  }

  private func service(_ f: Fixture) -> PairingServices {
    let service = bootstrap(f)
    waitUntil { service.coordinator != nil }
    return service
  }

  private func assertFreshArm(_ f: Fixture, _ service: PairingServices, file: StaticString = #filePath, line: UInt = #line) throws {
    waitUntil { service.trustedSnapshot(nil).eligible }
    let owner = try XCTUnwrap(service.coordinator)
    if case .newInstallation = try restoration(owner) {} else { XCTFail("expected newInstallation", file: file, line: line) }
    let arm: PairingTrustedHandle
    do { arm = try owner.armTrusted() }
    catch { return XCTFail("expected successful arm, received \(error)", file: file, line: line) }
    waitUntil { (try? owner.requests(arm)) != nil }
    let accounting = try JSONDecoder().decode(PairingSession.Accounting.self, from: Data(contentsOf: f.directory.appendingPathComponent("accounting.json")))
    XCTAssertEqual(accounting.blockedUntil, 0, file: file, line: line)
    XCTAssertEqual(accounting.uncertainReveals, 0, file: file, line: line)
    XCTAssertGreaterThan(accounting.revision, 0, file: file, line: line)
  }

  func testFreshSessionCanEnableSyncAndArmWithoutAccountingQuarantine() throws {
    let f = try Fixture()
    let service = service(f)
    defer { shutdown(service) }
    let original = try XCTUnwrap(service.coordinator)
    try f.enable()
    service.keyActivated()
    waitUntil { service.trustedSnapshot(nil).eligible }
    XCTAssertTrue(service.coordinator === original)
    try assertFreshArm(f, service)
  }

  func testVersionOneUpgradeWithNoPairingDirectoryCanArm() throws {
    let f = try Fixture()
    try f.enable()
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    let service = service(f)
    defer { shutdown(service) }
    try assertFreshArm(f, service)
  }

  func testVersionOneUpgradeWithEmptyPairingDirectoryCanArm() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let service = service(f)
    defer { shutdown(service) }
    try assertFreshArm(f, service)
  }

  private func assertQuarantined(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
    let store = try f.store()
    let mailbox = try PairingMailbox(folder: f.folder, cid: f.cid)
    let epoch = Data(repeating: 49, count: 16)
    let host = PairingInstallationHost(dataDirectory: f.data, folder: f.folder, folderIdentity: mailbox.folderIdentity, keys: f.keys, accounting: store)
    let owner = PairingCoordinator(configuration: .init(cid: f.cid, environment: .init(folderIdentity: mailbox.folderIdentity, entropyHandle: Data([1]), clockEpoch: epoch), localName: "Fixture Mac", entropy: f.entropy, trustedDevice: try PairingFormat.cid(f.account)), mailbox: mailbox, store: store, authenticator: FreshPairingOwnerAuthenticator(), keyStore: f.keys, host: host, clock: { 1000 }, wall: { 1000 })
    guard case .restored(let accounting) = try restoration(owner) else { return XCTFail("expected restored quarantine", file: file, line: line) }
    XCTAssertEqual(accounting.blockedUntil, 86401000, file: file, line: line)
    XCTAssertEqual(accounting.uncertainReveals, 20, file: file, line: line)
    XCTAssertThrowsError(try owner.armTrusted(), file: file, line: line) { XCTAssertEqual($0 as? PairingSession.Failure, .accounting, file: file, line: line) }
  }

  private func assertProductionQuarantine(_ f: Fixture, _ service: PairingServices, armable: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
    let owner = try XCTUnwrap(service.coordinator, file: file, line: line)
    guard case .restored(let accounting) = try restoration(owner) else { return XCTFail("expected restored quarantine", file: file, line: line) }
    XCTAssertGreaterThan(accounting.blockedUntil, try PairingBootClock.sample().milliseconds, file: file, line: line)
    XCTAssertEqual(accounting.uncertainReveals, 20, file: file, line: line)
    if armable {
      waitUntil { service.trustedSnapshot(nil).eligible }
      XCTAssertThrowsError(try owner.armTrusted(), file: file, line: line) { XCTAssertEqual($0 as? PairingSession.Failure, .accounting, file: file, line: line) }
    }
  }

  func testDisabledVersionTwoWithEmptyDirectoryStaysQuarantinedThroughConfigure() throws {
    let f = try Fixture()
    try f.enable()
    try f.disableVersionTwo()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let service = service(f)
    defer { shutdown(service) }
    try assertProductionQuarantine(f, service, armable: false)
  }

  func testSafeModeBootstrapDefersAccountingUntilNormalBootstrapCanArm() throws {
    let f = try Fixture()
    try f.enable()
    let safe = bootstrap(f, safeMode: { true })
    XCTAssertNil(safe.coordinator)
    XCTAssertFalse(safe.trustedSnapshot(nil).eligible)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("accounting.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("initialized").path))
    shutdown(safe)
    let normal = service(f)
    defer { shutdown(normal) }
    try assertFreshArm(f, normal)
  }

  func testLookupFailureDefersAccountingUntilFoundKeyCanArmThroughConfigure() throws {
    let f = try Fixture()
    try f.enable()
    let key = f.data.appendingPathComponent("sync-key-" + f.account)
    try Data([1]).write(to: key)
    XCTAssertEqual(f.keys.pairingLookup(account: f.account), .failure)
    let service = bootstrap(f)
    defer { shutdown(service) }
    XCTAssertNil(service.coordinator)
    XCTAssertFalse(service.trustedSnapshot(nil).eligible)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("accounting.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("initialized").path))
    try f.entropy.write(to: key)
    XCTAssertEqual(f.keys.pairingLookup(account: f.account), .found(f.entropy))
    service.refresh()
    drainConfigure(service)
    try assertFreshArm(f, service)
  }

  func testNormalBootstrapPreservesExistingQuarantineAfterSafeMode() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let sample = try PairingBootClock.sample()
    let saved = PairingSession.Accounting(clockEpoch: sample.epoch, lastTime: sample.milliseconds, blockedUntil: sample.milliseconds + 86400000, revision: 7, uncertainReveals: 20)
    let bytes = try JSONEncoder().encode(saved)
    let url = f.directory.appendingPathComponent("accounting.json")
    try bytes.write(to: url)
    let safe = bootstrap(f, safeMode: { true })
    XCTAssertNil(safe.coordinator)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    shutdown(safe)
    let normal = service(f)
    defer { shutdown(normal) }
    try assertProductionQuarantine(f, normal)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testDiscardedVersionOneConfigureCannotSupplyFreshEvidenceToVersionTwoConfigure() throws {
    let f = try Fixture()
    try f.enable()
    let service = PairingServices(sessionDictionary: { ["kCGSSessionOnConsoleKey": true] })
    service.registerStore(healthy: { true }, revision: { 1 }, projection: { operation, _ in operation })
    var replaced = false
    service.bootstrap(dataDirectory: f.data, defaultFolder: f.folder, keys: f.keys, safeMode: {
      if !replaced {
        replaced = true
        do { try f.disableVersionTwo() } catch { XCTFail("could not replace sync document: \(error)") }
        service.invalidate("reload")
      }
      return false
    })
    defer { shutdown(service) }
    drainConfigure(service)
    XCTAssertTrue(replaced)
    XCTAssertNil(service.coordinator)
    let originalHost = try XCTUnwrap(service.installationHost)
    service.refresh()
    drainConfigure(service)
    waitUntil { service.coordinator != nil }
    XCTAssertTrue(service.installationHost === originalHost)
    try assertProductionQuarantine(f, service, armable: false)
  }

  func testEvidenceQuarantinesUnreadableSyncDocumentThatConfigureRefusesBeforeAccounting() throws {
    let f = try Fixture()
    try FileManager.default.createDirectory(at: f.data.appendingPathComponent("sync.json"), withIntermediateDirectories: true)
    try assertQuarantined(f)
  }

  func testEvidenceQuarantinesInvalidJSONThatConfigureRefusesBeforeAccounting() throws {
    let f = try Fixture()
    try Data("invalid".utf8).write(to: f.data.appendingPathComponent("sync.json"))
    try assertQuarantined(f)
  }

  func testEvidenceQuarantinesUnknownSyncVersionThatConfigureRefusesBeforeAccounting() throws {
    let f = try Fixture()
    try f.enable(version: 3)
    try assertQuarantined(f)
  }

  func testEveryJoinAndStopMarkerDisqualifiesFreshEvidenceThroughConfigure() throws {
    for name in ["host-installation.json", "host-stop.json", "host-history-abc-1.json", "installation-abc-1.json", "cancelled-abc-1.json"] {
      let f = try Fixture()
      try f.enable()
      try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
      try Data((name == "host-stop.json" ? "0" : "{}").utf8).write(to: f.directory.appendingPathComponent(name))
      XCTAssertFalse(try f.evidence().noJoinOrStopMarker, name)
      let service = bootstrap(f)
      defer { shutdown(service) }
      if name == "host-installation.json" {
        XCTAssertNil(service.coordinator, name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("accounting.json").path), name)
      } else {
        try assertProductionQuarantine(f, service)
      }
    }
  }

  func testNonemptyDirectoryMissingAccountingStaysQuarantined() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    try Data([1]).write(to: f.directory.appendingPathComponent("initialized"))
    let service = service(f)
    defer { shutdown(service) }
    try assertProductionQuarantine(f, service)
  }

  func testUnreadableAccountingInNonemptyDirectoryStaysQuarantined() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let accounting = f.directory.appendingPathComponent("accounting.json")
    let sample = try PairingBootClock.sample()
    let valid = PairingSession.Accounting(clockEpoch: sample.epoch, lastTime: sample.milliseconds)
    try JSONEncoder().encode(valid).write(to: accounting)
    let readable = service(f)
    let owner = try XCTUnwrap(readable.coordinator)
    let arm = try owner.armTrusted()
    waitUntil { (try? owner.requests(arm)) != nil }
    shutdown(readable)
    let armable = try PairingPOSIXDurableIO().read(accounting, limit: 32768)
    XCTAssertEqual(try JSONDecoder().decode(PairingSession.Accounting.self, from: armable).uncertainReveals, 0)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: accounting.path)
    XCTAssertThrowsError(try PairingPOSIXDurableIO().read(accounting, limit: 32768))
    let unreadable = service(f)
    defer { shutdown(unreadable) }
    try assertProductionQuarantine(f, unreadable)
  }

  func testInvalidAccountingInNonemptyDirectoryStaysQuarantined() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: f.directory.appendingPathComponent("accounting.json"))
    let service = service(f)
    defer { shutdown(service) }
    try assertProductionQuarantine(f, service)
  }

  func testRolledBackAccountingInNonemptyDirectoryStaysQuarantined() throws {
    let f = try Fixture()
    try f.enable()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let sample = try PairingBootClock.sample()
    let accounting = PairingSession.Accounting(clockEpoch: sample.epoch, lastTime: sample.milliseconds + 120000)
    try JSONEncoder().encode(accounting).write(to: f.directory.appendingPathComponent("accounting.json"))
    let service = service(f)
    defer { shutdown(service) }
    try assertProductionQuarantine(f, service)
  }

}
