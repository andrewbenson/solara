import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingCommittedRecoveryTests: XCTestCase {
  func testLostReadyAcknowledgmentKeepsDurablyAdmittedJoinApprovedWithoutStoreRegistration() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data"), folder = root.appendingPathComponent("remote")
    let entropy = Data(repeating: 41, count: 32), keys = SyncKeys(entropy: entropy)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(keys.chainTag), withIntermediateDirectories: true)
    let identity = try PairingMailbox(folder: folder, cid: keys.chainTag).folderIdentity
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: .init(noPairingEraSyncState: false, noJoinOrStopMarker: false, keyStateKnown: false))
    let keyStore = FileKeyStore(directory: data)
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: keys.chainTag, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: identity, keys: keyStore, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keyStore.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    let request = try XCTUnwrap(host.installationRequest())
    let consumed = try host.consumeInstallation(handle: request["handle"] as! String, priorState: PairingInstallationHost.priorState(""))
    let dto = try host.readInstallation(consumed), transaction = dto["transaction"] as! String
    let profile: [String: Any] = ["n": "Personal", "c": "blue", "i": NSNull()]
    let operation: [String: Any] = ["operationId": "\(transaction):1:prof:remote:intent-1", "transaction": transaction, "generation": 1, "key": "prof:remote", "desired": profile, "before": profile, "localValue": profile, "disposition": "applied"]
    let links: [String: Any] = ["default": ["syncId": "remote", "enabled": true]]
    var plan: [String: Any] = ["defaultKey": "prof:remote", "links": links, "operations": [operation], "outcomes": [:]]
    func save(_ phase: String) throws {
      let record: [String: Any] = ["h": "000000001.0000.remote", "o": ["remote", 1], "v": ["n": "Personal", "c": "blue", "i": NSNull(), "d": true]]
      let replica: [String: Any] = ["transaction": transaction, "generation": 1, "revision": 1, "app": ["records": ["prof:remote": record], "joined": true], "plan": plan]
      let plain = String(decoding: try JSONSerialization.data(withJSONObject: replica, options: [.sortedKeys]), as: UTF8.self)
      let name = "sync-bootstrap-\(transaction)-1.nns"
      try Data(LocalDocuments.seal(plain, .state, keys: keys).base64EncodedString().utf8).write(to: data.appendingPathComponent(name))
      let doc: [String: Any] = ["v": 2, "enabled": true, "joining": phase != "ready", "stopGeneration": 0, "folder": folder.path, "deviceId": installation.device, "joinTransaction": transaction, "installation": dto, "profiles": links, "bootstrap": ["phase": phase, "transaction": transaction, "generation": 1, "checkpoint": ["name": name, "digest": PairingInstallationHost.priorState(plain).split(separator: ":").last.map(String.init)!]]]
      try JSONSerialization.data(withJSONObject: doc).write(to: data.appendingPathComponent("sync.json"))
    }
    try save("applying")
    try host.acknowledgeInitialization(transaction: transaction, generation: 1)
    host.projection = { operation, _ in operation["localValue"]! }
    host.revision = { 1 }
    let receipt = try host.checkpointApplied(operation)
    plan["outcomes"] = ["prof:remote": receipt]
    try save("ready")
    let restored = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: identity, keys: keyStore, accounting: store)
    XCTAssertEqual(restored.committedState(), .approved)
    XCTAssertNotNil(try restored.recoverInstallation())
    restored.projection = host.projection
    restored.revision = host.revision
    XCTAssertEqual(restored.committedState(), .installed)
  }
}
