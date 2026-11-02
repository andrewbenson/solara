import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingInstallationHostTests: XCTestCase {
  private final class Fixture {
    let root: URL
    let data: URL
    let folder: URL
    let keys: FileKeyStore
    let store: PairingDurableStore
    let entropy = Data(repeating: 29, count: 32)
    let installation: PairingInstallation
    var host: PairingInstallationHost
    init(root: URL = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)) throws {
      self.root = root
      data = root.appendingPathComponent("data")
      folder = root.appendingPathComponent("remote")
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let cid = SyncKeys(entropy: entropy).chainTag
      try FileManager.default.createDirectory(at: folder.appendingPathComponent(cid), withIntermediateDirectories: false)
      let identity = try PairingMailbox(folder: folder, cid: cid).folderIdentity
      keys = FileKeyStore(directory: data)
      store = try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
      installation = PairingInstallation(transaction: Data(repeating: 11, count: 32), cid: cid, device: Base32.encode(Data(repeating: 9, count: 16)), folderIdentity: identity, generation: 1)
      host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: identity, keys: keys, accounting: store)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func prepare() -> Bool {
      var value = false
      host.prepare(installation) { value = $0 }
      return value
    }
    func admit() throws {
      XCTAssertTrue(prepare())
      XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
      _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
      host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    }
    func dto() throws -> [String: Any] {
      let request = try XCTUnwrap(host.installationRequest())
      let consumed = try host.consumeInstallation(handle: request["handle"] as! String, priorState: PairingInstallationHost.priorState(""))
      XCTAssertEqual(consumed["phase"] as? String, "prepared")
      try host.saveInstallation(consumed)
      return try host.readInstallation(consumed)
    }
    func document(_ installation: [String: Any], phase: String = "awaiting-profile", checkpoint: [String: Any]? = nil) throws {
      var bootstrap: [String: Any] = ["phase": phase, "transaction": installation["transaction"]!, "generation": installation["generation"]!]
      if let checkpoint { bootstrap["checkpoint"] = checkpoint }
      let doc: [String: Any] = ["v": 2, "enabled": true, "joining": phase != "ready", "folder": folder.path, "deviceId": installation["deviceId"]!, "joinTransaction": installation["transaction"]!, "stopGeneration": installation["stopGeneration"]!, "installation": installation, "bootstrap": bootstrap, "profiles": ["default": ["syncId": "synced-default", "enabled": true]] ]
      try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]).write(to: data.appendingPathComponent("sync.json"))
    }
    func recreate() {
      host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: installation.folderIdentity, keys: keys, accounting: store)
    }
  }

  private func pathFixture() throws -> Fixture {
    try Fixture(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".host-path-" + UUID().uuidString))
  }

  func testSymlinkedDataAncestorPersistsAdmissionRecoveryAndStop() throws {
    let f = try pathFixture()
    let ancestor = f.root.appendingPathComponent("ancestor")
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: f.root)
    let data = ancestor.appendingPathComponent("data")
    func recreate() {
      f.host = PairingInstallationHost(dataDirectory: data, folder: f.folder, folderIdentity: f.installation.folderIdentity, keys: f.keys, accounting: f.store)
    }
    recreate()
    let succeeded = f.prepare()
    XCTAssertTrue(succeeded)
    guard succeeded else { return }
    let file = f.data.appendingPathComponent("Application Support/sync-pairing/host-installation.json")
    let prepared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    XCTAssertEqual(prepared["keySaved"] as? Bool, false)
    try f.admit()
    recreate()
    XCTAssertEqual(try f.host.recoverInstallation()?["phase"] as? String, "key-saved")
    let dto = try f.dto()
    try f.document(dto)
    XCTAssertNoThrow(try f.host.acknowledgeInitialization(transaction: dto["transaction"] as! String, generation: 1))
    let target = try XCTUnwrap(PairingInstallationHost.committedTarget(dataDirectory: data, keys: f.keys))
    XCTAssertEqual(target.installation, f.installation)
    XCTAssertEqual(target.folder.path, f.folder.path)
    try PairingInstallationHost.stopInstallation(dataDirectory: data, nil, stopGeneration: 2)
    recreate()
    XCTAssertEqual(f.host.minimumGeneration, 2)
    XCTAssertNil(try f.host.recoverInstallation())
    XCTAssertNil(try PairingInstallationHost.committedTarget(dataDirectory: data, keys: f.keys))
  }

  func testStoreDirectorySymlinksRefusedBeforeAndAfterHostRecreation() throws {
    for component in ["Application Support", "Application Support/sync-pairing"] {
      for recreate in [false, true] {
        let f = try pathFixture()
        try f.admit()
        let directory = f.data.appendingPathComponent(component)
        let displaced = f.root.appendingPathComponent("displaced")
        let file = f.data.appendingPathComponent("Application Support/sync-pairing/host-installation.json")
        let before = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: directory, to: displaced)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: displaced)
        if recreate { f.recreate() }
        XCTAssertFalse(f.prepare())
        XCTAssertThrowsError(try f.host.recoverInstallation())
        XCTAssertThrowsError(try PairingInstallationHost.committedTarget(dataDirectory: f.data, keys: f.keys))
        XCTAssertThrowsError(try PairingInstallationHost.stopInstallation(dataDirectory: f.data, nil, stopGeneration: 2))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("Application Support/sync-pairing/host-stop.json").path))
      }
    }
  }

  func testExistingHostStopRefusesReplacedTrustedDataRoot() throws {
    let f = try pathFixture()
    try f.admit()
    let displaced = f.root.appendingPathComponent("displaced")
    try FileManager.default.moveItem(at: f.data, to: displaced)
    try FileManager.default.createSymbolicLink(at: f.data, withDestinationURL: displaced)
    XCTAssertThrowsError(try f.host.stopCurrentInstallation())
    XCTAssertThrowsError(try f.host.stopInstallation(nil, stopGeneration: 2))
    XCTAssertFalse(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("Application Support/sync-pairing/host-stop.json").path))
  }

  private final class RootSwapIO: PairingDurableIO {
    let base = PairingPOSIXDurableIO()
    let root: URL
    let displaced: URL
    var swapped = false
    init(root: URL, displaced: URL) { self.root = root; self.displaced = displaced }
    func prepare(_ directory: URL) throws { try base.prepare(directory) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func contents(_ directory: URL) throws -> [String] { try base.contents(directory) }
    func read(_ url: URL, limit: Int) throws -> Data {
      let bytes = try base.read(url, limit: limit)
      if !swapped && url.lastPathComponent == "host-installation.json" {
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: displaced)
        swapped = true
      }
      return bytes
    }
    func createExclusive(_ bytes: Data, at url: URL) throws { try base.createExclusive(bytes, at: url) }
    func replace(_ bytes: Data, at url: URL) throws { try base.replace(bytes, at: url) }
  }

  func testCommittedTargetRefusesDataRootReplacedDuringRecordRead() throws {
    let f = try pathFixture()
    try f.admit()
    let io = RootSwapIO(root: f.data, displaced: f.root.appendingPathComponent("displaced"))
    XCTAssertThrowsError(try PairingInstallationHost.committedTarget(dataDirectory: f.data, keys: f.keys, io: io))
    XCTAssertTrue(io.swapped)
  }

  func testHostRecordSymlinksAndHardLinksRefused() throws {
    for hardLink in [false, true] {
      let f = try pathFixture()
      try f.admit()
      let file = f.data.appendingPathComponent("Application Support/sync-pairing/host-installation.json")
      let displaced = f.root.appendingPathComponent("displaced.json")
      let before = try Data(contentsOf: file)
      try FileManager.default.moveItem(at: file, to: displaced)
      if hardLink { try FileManager.default.linkItem(at: displaced, to: file) }
      else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: displaced) }
      f.recreate()
      XCTAssertFalse(f.prepare())
      XCTAssertThrowsError(try f.host.recoverInstallation())
      XCTAssertThrowsError(try PairingInstallationHost.committedTarget(dataDirectory: f.data, keys: f.keys))
      XCTAssertThrowsError(try PairingInstallationHost.stopInstallation(dataDirectory: f.data, nil, stopGeneration: 2))
      XCTAssertEqual(try Data(contentsOf: displaced), before)
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("Application Support/sync-pairing/host-stop.json").path))
    }
  }

  func testDurablePreparedAndAdmittedKeySavedSurviveHostRecreation() throws {
    let f = try Fixture()
    try f.admit()
    let request = f.host.installationRequest()
    XCTAssertNotNil(request)
    f.recreate()
    let recovered = try f.host.recoverInstallation()
    XCTAssertEqual(recovered?["transaction"] as? String, String(repeating: "0b", count: 32))
    XCTAssertEqual(recovered?["phase"] as? String, "key-saved")
    XCTAssertEqual(recovered?["account"] as? String, f.installation.device)
  }

  func testSavedKeyWithoutAdmissionNeverRecoversOrPublishesRequest() throws {
    let f = try Fixture()
    XCTAssertTrue(f.prepare())
    XCTAssertTrue(f.keys.pairingInsert(f.entropy, account: f.installation.device))
    f.recreate()
    var requests = 0, keys = 0
    f.host.onRequest = { requests += 1 }
    f.host.onKeyAvailable = { _, _ in keys += 1 }
    f.host.keySaved(f.installation, initialized: { _ in XCTFail("Unadmitted initialization") }, ready: { _ in XCTFail("Unadmitted ready") })
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(keys, 0)
    XCTAssertNil(f.host.installationRequest())
    XCTAssertNil(try f.host.recoverInstallation())
    XCTAssertNil(f.host.installationRequest())
    XCTAssertEqual(f.keys.pairingLookup(account: f.installation.device), .found(f.entropy))
  }

  func testLostKeySavedCallbackReconcilesOnlyDurableAdmittedDecision() throws {
    let f = try Fixture()
    XCTAssertTrue(f.prepare())
    XCTAssertTrue(f.keys.pairingInsert(f.entropy, account: f.installation.device))
    _ = try f.store.persistInstallationDecision(.init(installation: f.installation, disposition: .admitted))
    f.recreate()
    XCTAssertEqual(try f.host.recoverInstallation()?["phase"] as? String, "key-saved")
  }

  func testNullInstallationStopIsDurableAndPreventsLateKeySaved() throws {
    let f = try Fixture()
    XCTAssertTrue(f.prepare())
    try f.host.stopInstallation(nil, stopGeneration: 2)
    XCTAssertTrue(f.keys.pairingInsert(f.entropy, account: f.installation.device))
    _ = try f.store.persistInstallationDecision(.init(installation: f.installation, disposition: .admitted))
    f.host.keySaved(f.installation, initialized: { _ in XCTFail("Stopped initialization acknowledged") }, ready: { _ in XCTFail("Stopped ready acknowledged") })
    f.recreate()
    XCTAssertNil(try f.host.recoverInstallation())
    XCTAssertGreaterThanOrEqual(f.host.minimumGeneration, 2)
  }

  func testPreparedRejectsCIDDirectorySymlinkAndUnknownDocument() throws {
    let f = try Fixture()
    let cid = f.folder.appendingPathComponent(f.installation.cid)
    try FileManager.default.removeItem(at: cid)
    try FileManager.default.createSymbolicLink(at: cid, withDestinationURL: f.data)
    XCTAssertFalse(f.prepare())
    try FileManager.default.removeItem(at: cid)
    try FileManager.default.createDirectory(at: cid, withIntermediateDirectories: false)
    try Data("{\"v\":99,\"enabled\":false}".utf8).write(to: f.data.appendingPathComponent("sync.json"))
    XCTAssertFalse(f.prepare())
  }

  func testReadInstallationRefusesUnknownActualDocumentPreservingKey() throws {
    let f = try Fixture()
    try f.admit()
    let dto = try f.dto()
    try Data("{\"v\":99,\"enabled\":false}".utf8).write(to: f.data.appendingPathComponent("sync.json"))
    XCTAssertThrowsError(try f.host.readInstallation(dto))
    XCTAssertEqual(f.keys.pairingLookup(account: f.installation.device), .found(f.entropy))
  }

  func testUnknownNativeMarkerFieldRefusesRecovery() throws {
    let f = try Fixture()
    try f.admit()
    let file = f.data.appendingPathComponent("Application Support/sync-pairing/host-installation.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    object["unexpected"] = "not admitted metadata"
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    f.recreate()
    XCTAssertThrowsError(try f.host.recoverInstallation())
  }

  func testInitializationRequiresExactActualDiskTransactionAndReadyStaysPending() throws {
    let f = try Fixture()
    try f.admit()
    let dto = try f.dto()
    var initialized = 0, ready = 0
    f.host.keySaved(f.installation, initialized: { if $0 { initialized += 1 } }, ready: { if $0 { ready += 1 } })
    let transaction = dto["transaction"] as! String
    XCTAssertThrowsError(try f.host.acknowledgeInitialization(transaction: transaction, generation: 1))
    XCTAssertEqual(initialized, 0)
    var foreign = dto
    foreign["account"] = Base32.encode(Data(repeating: 8, count: 16))
    try f.document(foreign)
    XCTAssertThrowsError(try f.host.acknowledgeInitialization(transaction: transaction, generation: 1))
    XCTAssertEqual(initialized, 0)
    try f.document(dto)
    try f.host.acknowledgeInitialization(transaction: transaction, generation: 1)
    XCTAssertEqual(initialized, 1)
    XCTAssertThrowsError(try f.host.acknowledgeReady(transaction: transaction, generation: 1))
    XCTAssertEqual(ready, 0)
    try f.host.stopInstallation(nil, stopGeneration: 1)
    XCTAssertThrowsError(try f.host.acknowledgeInitialization(transaction: transaction, generation: 1))
    XCTAssertEqual(ready, 0)
  }

  func testInstallationDTOAllowlistRejectsEveryMutatedIdentityAndUnsafeNumber() throws {
    let f = try Fixture()
    try f.admit()
    let dto = try f.dto()
    for key in dto.keys {
      var changed = dto
      changed[key] = key == "generation" || key == "stopGeneration" ? 3 : "changed"
      XCTAssertThrowsError(try f.host.readInstallation(changed), key)
    }
    for number: Any in [Double.nan, Double.infinity, -1, 1.5, 9007199254740992.0, true] {
      var changed = dto
      changed["generation"] = number
      XCTAssertThrowsError(try f.host.readInstallation(changed))
    }
    var extended = dto
    extended["unexpected"] = "forbidden"
    XCTAssertThrowsError(try f.host.readInstallation(extended))
    XCTAssertEqual(try f.host.readInstallation(dto)["transaction"] as? String, dto["transaction"] as? String)
  }

  func testReadyRequiresDurableOutcomesAndActualProjectionAndEncryptedReceipts() throws {
    let f = try Fixture()
    try f.admit()
    let dto = try f.dto()
    let transaction = dto["transaction"] as! String
    try f.document(dto)
    try f.host.acknowledgeInitialization(transaction: transaction, generation: 1)
    let value: [String: Any] = ["v": "chosen"]
    let operation: [String: Any] = ["operationId": "\(transaction):1:set:appearance:intent-1", "transaction": transaction, "generation": 1, "key": "set:appearance", "desired": value, "before": ["v": "before"], "localValue": value, "disposition": "applied"]
    let name = "sync-bootstrap-\(transaction)-1.nns"
    let profile: [String: Any] = ["n": "Personal", "c": "blue", "i": NSNull()]
    let profileOperation: [String: Any] = ["operationId": "\(transaction):1:prof:synced-default:intent-1", "transaction": transaction, "generation": 1, "key": "prof:synced-default", "desired": profile, "before": profile, "localValue": profile, "disposition": "applied"]
    let profileRecord: [String: Any] = ["h": "000000001.0000.remote", "o": ["remote", 1], "v": ["n": "Personal", "c": "blue", "i": NSNull(), "d": true]]
    let app: [String: Any] = ["records": ["prof:synced-default": profileRecord], "joined": true]
    var plan: [String: Any] = ["defaultKey": "prof:synced-default", "links": ["default": ["syncId": "synced-default", "enabled": true]], "operations": [profileOperation, operation], "outcomes": [:]]
    func checkpoint(phase: String) throws {
      let replica: [String: Any] = ["transaction": transaction, "generation": 1, "revision": 1, "plan": plan, "app": app]
      let plain = String(decoding: try JSONSerialization.data(withJSONObject: replica, options: [.sortedKeys]), as: UTF8.self)
      let sealed = try LocalDocuments.seal(plain, .state, keys: SyncKeys(entropy: f.entropy)).base64EncodedString()
      try Data(sealed.utf8).write(to: f.data.appendingPathComponent(name))
      try f.document(dto, phase: phase, checkpoint: ["name": name, "digest": PairingInstallationHost.priorState(plain).split(separator: ":").last.map(String.init)!])
    }
    let authoritative = f.data.appendingPathComponent("actual.json")
    try JSONSerialization.data(withJSONObject: ["set:appearance": value, "prof:synced-default": profile]).write(to: authoritative)
    let projection: ([String: Any], [String: Any]) throws -> Any = { op, _ in
      let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: authoritative)) as! [String: Any]
      return actual[op["key"] as! String]!
    }
    f.host.projection = projection
    f.host.revision = { 1 }
    plan["defaultKey"] = "prof:missing"
    try checkpoint(phase: "applying")
    XCTAssertThrowsError(try f.host.checkpointApplied(operation))
    plan["defaultKey"] = "prof:synced-default"
    try checkpoint(phase: "applying")
    XCTAssertNil(try f.host.reconcileApplied(operation))
    let readback = CorruptReadback()
    readback.corruptReceipts = true
    let mismatchedHost = PairingInstallationHost(dataDirectory: f.data, folder: f.folder, folderIdentity: f.installation.folderIdentity, keys: f.keys, accounting: f.store, io: readback)
    mismatchedHost.projection = projection
    mismatchedHost.revision = { 1 }
    XCTAssertThrowsError(try mismatchedHost.checkpointApplied(profileOperation), "Receipt acknowledgment requires exact encrypted write/readback")
    let receiptDirectory = f.data.appendingPathComponent("Application Support/sync-pairing")
    for name in try FileManager.default.contentsOfDirectory(atPath: receiptDirectory.path) where name.hasPrefix("host-receipt-") {
      try FileManager.default.removeItem(at: receiptDirectory.appendingPathComponent(name))
    }
    let profileReceipt = try f.host.checkpointApplied(profileOperation)
    let receipt = try f.host.checkpointApplied(operation)
    var changedBefore = operation
    changedBefore["before"] = ["v": "different-before"]
    plan["operations"] = [profileOperation, changedBefore]
    try checkpoint(phase: "applying")
    XCTAssertThrowsError(try f.host.checkpointApplied(changedBefore), "Same operationId with changed before intent must reject even when receipt value is unchanged")
    plan["operations"] = [profileOperation, operation]
    try checkpoint(phase: "applying")
    var revisedOperation = operation
    let revisedValue: [String: Any] = ["v": "changed-intent"]
    revisedOperation["desired"] = revisedValue
    revisedOperation["localValue"] = revisedValue
    plan["operations"] = [profileOperation, revisedOperation]
    try JSONSerialization.data(withJSONObject: ["set:appearance": revisedValue, "prof:synced-default": profile]).write(to: authoritative)
    try checkpoint(phase: "applying")
    XCTAssertThrowsError(try f.host.checkpointApplied(revisedOperation), "Same operationId with changed durable intent must not replace an existing receipt")
    plan["operations"] = [profileOperation, operation]
    try JSONSerialization.data(withJSONObject: ["set:appearance": value, "prof:synced-default": profile]).write(to: authoritative)
    try checkpoint(phase: "applying")
    _ = try f.host.checkpointApplied(operation)
    XCTAssertNotNil(try f.host.reconcileApplied(operation))
    let receipts = try FileManager.default.contentsOfDirectory(at: f.data.appendingPathComponent("Application Support/sync-pairing"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("host-receipt-") }
    XCTAssertEqual(receipts.count, 2)
    XCTAssertFalse(try Data(contentsOf: receipts[0]).range(of: Data("chosen".utf8)) != nil)
    try checkpoint(phase: "ready")
    XCTAssertThrowsError(try f.host.acknowledgeReady(transaction: transaction, generation: 1))
    plan["outcomes"] = ["set:appearance": receipt, "prof:synced-default": profileReceipt]
    try checkpoint(phase: "ready")
    plan["outcomes"] = ["set:appearance": receipt, "prof:synced-default": profileReceipt, "set:unplanned": receipt]
    try checkpoint(phase: "ready")
    XCTAssertThrowsError(try f.host.acknowledgeReady(transaction: transaction, generation: 1), "Ready must reject extra outcome keys")
    plan["outcomes"] = ["set:appearance": receipt, "prof:synced-default": profileReceipt]
    try checkpoint(phase: "ready")
    var serial = 1, reads = 0, installed = 0
    f.host.revision = { serial }
    f.host.onState = { if $0 == .installed { installed += 1 } }
    f.host.projection = { operation, links in
      reads += 1
      if reads == 2 { serial += 1 }
      return try projection(operation, links)
    }
    XCTAssertThrowsError(try f.host.acknowledgeReady(transaction: transaction, generation: 1))
    XCTAssertEqual(installed, 0)
    f.host.projection = projection
    try f.host.acknowledgeReady(transaction: transaction, generation: 1)
    try JSONSerialization.data(withJSONObject: ["set:appearance": ["v": "edited"], "prof:synced-default": profile]).write(to: authoritative)
    XCTAssertNil(try f.host.reconcileApplied(operation))
    f.recreate()
    XCTAssertNoThrow(try f.host.acknowledgeReady(transaction: transaction, generation: 1))
    XCTAssertEqual(f.host.committedState(), .installed)
  }

  func testCommittedRecoveryStateUsesDurableAdmissionAndStopHighwater() throws {
    let f = try Fixture()
    XCTAssertTrue(f.prepare())
    XCTAssertTrue(f.keys.pairingInsert(f.entropy, account: f.installation.device))
    XCTAssertNil(f.host.committedState())
    _ = try f.store.persistInstallationDecision(.init(installation: f.installation, disposition: .admitted))
    f.recreate()
    XCTAssertEqual(f.host.committedState(), .approved)
    try f.host.stopCurrentInstallation()
    XCTAssertNil(f.host.committedState())
    f.recreate()
    XCTAssertNil(f.host.committedState())
    XCTAssertGreaterThan(f.host.minimumGeneration, f.installation.generation)
  }

  private final class CorruptReadback: PairingDurableIO {
    let base = PairingPOSIXDurableIO()
    var corrupt = false
    var corruptReceipts = false
    var corruptStops = false
    var corruptStopWrites = false
    func prepare(_ directory: URL) throws { try base.prepare(directory) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func contents(_ directory: URL) throws -> [String] { try base.contents(directory) }
    func read(_ url: URL, limit: Int) throws -> Data {
      if corruptStops && url.lastPathComponent == "host-stop.json" { return Data([0]) }
      if corruptReceipts && url.lastPathComponent.hasPrefix("host-receipt-") { return Data([0]) }
      if corrupt && url.lastPathComponent == "host-installation.json" { return Data([0]) }
      return try base.read(url, limit: limit)
    }
    func createExclusive(_ bytes: Data, at url: URL) throws { try base.createExclusive(bytes, at: url) }
    func replace(_ bytes: Data, at url: URL) throws {
      try base.replace(bytes, at: url)
      if url.lastPathComponent == "host-installation.json" { corrupt = true }
      if corruptStopWrites && url.lastPathComponent == "host-stop.json" { corruptStops = true }
    }
  }

  func testStopRequiresActualPOSIXReadbackWithRemoteFolderUnavailable() throws {
    let f = try Fixture()
    try f.admit()
    try FileManager.default.removeItem(at: f.folder)
    let io = CorruptReadback()
    let host = PairingInstallationHost(dataDirectory: f.data, folder: f.folder, folderIdentity: f.installation.folderIdentity, keys: f.keys, accounting: f.store, io: io)
    io.corruptStopWrites = true
    XCTAssertThrowsError(try host.stopInstallation(nil, stopGeneration: 2))
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("Application Support/sync-pairing/host-stop.json").path))
    io.corruptStopWrites = false
    io.corruptStops = false
    try host.stopInstallation(nil, stopGeneration: 2)
    XCTAssertNil(try PairingInstallationHost.committedTarget(dataDirectory: f.data, keys: f.keys))
  }

  func testPreparedRequiresActualPOSIXReadback() throws {
    let f = try Fixture()
    let io = CorruptReadback()
    f.host = PairingInstallationHost(dataDirectory: f.data, folder: f.folder, folderIdentity: f.installation.folderIdentity, keys: f.keys, accounting: f.store, io: io)
    XCTAssertFalse(f.prepare())
    XCTAssertEqual(f.keys.pairingLookup(account: f.installation.device), .absent)
    io.corrupt = false
    XCTAssertTrue(f.prepare())
  }

  func testCancelledPreparedRecordAllowsFreshGenerationWithoutLosingHistory() throws {
    let f = try Fixture()
    XCTAssertTrue(f.prepare())
    try f.store.cancelInstallation(f.installation)
    let replacement = PairingInstallation(transaction: Data(repeating: 12, count: 32), cid: f.installation.cid, device: Base32.encode(Data(repeating: 10, count: 16)), folderIdentity: f.installation.folderIdentity, generation: 2)
    var prepared = false
    f.host.prepare(replacement) { prepared = $0 }
    XCTAssertTrue(prepared)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.data.appendingPathComponent("Application Support/sync-pairing").path)
    XCTAssertEqual(names.filter { $0.hasPrefix("host-history-") }.count, 1)
    XCTAssertEqual(try f.store.installationDecision(for: f.installation)?.disposition, .cancelled)
  }

  func testPrepareRefusesMalformedSupportedVersionBeforeWritingAnyPreparedRecord() throws {
    let documents = ["{\"v\":2,\"enabled\":false,\"stopGeneration\":0}", "{\"v\":1,\"enabled\":\"false\"}", "{\"v\":1,\"enabled\":false,\"stopGeneration\":9007199254740992}", "{\"v\":2,\"enabled\":false,\"joining\":true,\"stopGeneration\":1,\"bootstrap\":{\"phase\":\"stopped\",\"transaction\":null,\"generation\":0}}"]
    for document in documents {
      let f = try Fixture()
      try Data(document.utf8).write(to: f.data.appendingPathComponent("sync.json"))
      XCTAssertFalse(f.prepare(), document)
      XCTAssertEqual(f.keys.pairingLookup(account: f.installation.device), .absent)
    }
  }

  func testStoppedFolderBindingAllowsFreshFolderWithoutReusingPriorAccount() throws {
    let f = try Fixture()
    try f.admit()
    let dto = try f.dto()
    try f.host.stopCurrentInstallation()
    let stopped: [String: Any] = ["v": 2, "enabled": false, "joining": false, "stopGeneration": 2, "folder": f.folder.path, "deviceId": f.installation.device, "joinTransaction": dto["transaction"]!, "installation": dto, "bootstrap": ["phase": "stopped", "transaction": dto["transaction"]!, "generation": 1]]
    try JSONSerialization.data(withJSONObject: stopped).write(to: f.data.appendingPathComponent("sync.json"))
    let folder = f.root.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(f.installation.cid), withIntermediateDirectories: true)
    let identity = try PairingMailbox(folder: folder, cid: f.installation.cid).folderIdentity
    let store = try PairingDurableStore(dataDirectory: f.data, syncFolder: folder, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let host = PairingInstallationHost(dataDirectory: f.data, folder: folder, folderIdentity: identity, keys: f.keys, accounting: store)
    XCTAssertEqual(host.minimumGeneration, 2)
    let installation = PairingInstallation(transaction: Data(repeating: 13, count: 32), cid: f.installation.cid, device: Base32.encode(Data(repeating: 14, count: 16)), folderIdentity: identity, generation: 3)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertEqual(f.keys.pairingLookup(account: f.installation.device), .found(f.entropy))
    XCTAssertEqual(f.keys.pairingLookup(account: installation.device), .absent)
  }

  func testPriorStateUsesLiteralUTF16Vectors() {
    XCTAssertEqual(PairingInstallationHost.priorState(""), "0:ztntfp")
    XCTAssertEqual(PairingInstallationHost.priorState("😀"), "2:1kdnhdk")
  }
}
