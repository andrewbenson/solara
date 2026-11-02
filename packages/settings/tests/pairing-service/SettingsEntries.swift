import AppKit
import Foundation
import SolaraUI
@testable import SolaraSyncAdapter

@MainActor
final class SettingsJS {
  static let shared = SettingsJS()
  func latestValue(_ topic: String) -> Any? { nil }
  func stream<T>(_ topic: String, _ transform: (Any?) -> T?) -> AsyncStream<T> { AsyncStream { $0.finish() } }
  func fire(_ name: String, _ arguments: Any...) {}
}

@MainActor
enum SettingsAdapters {
  static var onCall: ((String) -> Void)?
  static var pending: CheckedContinuation<Any?, Never>?
  static func js(_ name: String, _ arguments: Any...) async -> Any? {
    onCall?(name)
    return await withCheckedContinuation { pending = $0 }
  }
  static func jsThrowing(_ name: String, _ arguments: Any...) async throws -> Any? {
    onCall?(name)
    return await withCheckedContinuation { pending = $0 }
  }
}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
  func bool(_ key: String) -> Bool? { self[key] as? Bool }
  func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
  func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
  func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
  func list(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
  func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
  func date(_ key: String) -> Date? { double(key).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

func jsonArg(_ value: String?) -> Any { value ?? NSNull() }
func jsonArg(_ value: Bool?) -> Any { value ?? NSNull() }

@main
struct SettingsEntries {
  @MainActor static func main() async throws {
    let action = CommandLine.arguments[1]
    let root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    let folder = root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entropy = Data(repeating: 13, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    let mailbox = try PairingMailbox(folder: folder, cid: cid)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: .init(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: true))
    let keys = FileKeyStore(directory: data)
    let host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: mailbox.folderIdentity, keys: keys, accounting: store)
    let epoch = Data(repeating: 1, count: 16)
    let owner = PairingCoordinator(configuration: .init(cid: cid, environment: .init(folderIdentity: mailbox.folderIdentity, entropyHandle: Data([1]), clockEpoch: epoch), localName: "Fixture Native Mac", entropy: entropy, trustedDevice: Data(repeating: 7, count: 16)), mailbox: mailbox, store: store, authenticator: FreshPairingOwnerAuthenticator(), keyStore: keys, host: host, clock: { 1000 }, wall: { 1 })
    PairingServices.shared.register(owner)
    _ = try owner.armTrusted()
    var failures = 0
    var calls = 0
    SettingsAdapters.onCall = { _ in
      calls += 1
      if owner.snapshot.trusted { failures += 1; print("ASSERTION FAILED: actual Settings entry reached JS before native invalidation") }
    }
    let adapter = SyncAdapter()
    let task = Task { @MainActor in
      switch action {
      case "outer":
        adapter.invalidatePairing("stop")
        _ = await SettingsAdapters.js("fixture")
      case "stop": await adapter.stopSync(deleteData: false)
      case "folder": _ = await adapter.chooseSyncFolder()
      case "rekey": _ = await adapter.enterRecoveryPhrase(folder: folder.path, text: "fixture")
      case "create": _ = await adapter.turnOnSync(folder: folder.path)
      default: failures += 1
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while SettingsAdapters.pending == nil, ContinuousClock.now < deadline { await Task.yield() }
    if SettingsAdapters.pending == nil { failures += 1; print("ASSERTION FAILED: Settings entry never reached held JS") }
    if calls != 1 { failures += 1; print("ASSERTION FAILED: Settings entry dispatched more than once") }
    SettingsAdapters.pending?.resume(returning: nil)
    SettingsAdapters.pending = nil
    await task.value
    print("Completed Settings native entry: 1 test, 3 assertions, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
}
