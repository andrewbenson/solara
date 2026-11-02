import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


SWIFT = r'''import Foundation
import XCTest
@testable import SolaraLegacySyncCore

private final class Promise {
  let completed = DispatchSemaphore(value: 0)
  var resolved = false
  var rejection: String?
  func resolve(_ value: Any?) { resolved = true; completed.signal() }
  func reject(_ code: String, _ message: String) { rejection = code + ":" + message; completed.signal() }
}

private struct StopFunction {
  let action: ([String: Any]?, Double, Promise) -> Void
  func runOnQueue(_ queue: DispatchQueue) -> StopFunction { self }
}

private func AsyncFunction(_ name: String, _ action: @escaping ([String: Any]?, Double, Promise) -> Void) -> StopFunction {
  StopFunction(action: action)
}

private final class StopBridge {
  private static let pairingWork = DispatchQueue(label: "solara.sync.pairing.bridge.regression")
  private static func pairingHost() throws -> PairingInstallationHost {
    guard let host = PairingServices.shared.installationHost else { throw PairingInstallationHost.Failure.unavailable }
    return host
  }
  func definition() -> StopFunction {
    REGISTRATION
  }
}

final class StopBridgeRegressionTests: XCTestCase {
  func testRegisteredJSStopPersistsWithoutRemoteMailbox() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let folder = root.appendingPathComponent("custom")
    let fallback = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, fallback, folder.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: folder, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: folder, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: folder, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    let dto = try XCTUnwrap(host.recoverInstallation())
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("unavailable")
    try FileManager.default.moveItem(at: folder, to: unavailable)
    let service = PairingServices.shared
    defer { service.invalidate("shutdown") }
    service.bootstrap(dataDirectory: data, defaultFolder: fallback, keys: keys, safeMode: { false })
    let deadline = Date().addingTimeInterval(3)
    while service.committedOnboardingJoinToken == nil && Date() < deadline { usleep(1000) }
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    XCTAssertNil(service.installationHost)
    var observed: [PairingJoinState] = []
    XCTAssertTrue(service.committedJoin { observed.append($0) })
    let registration = StopBridge().definition()
    let stop = data.appendingPathComponent("Application Support/sync-pairing/host-stop.json")
    let malformed = Data("malformed".utf8)
    try malformed.write(to: stop)
    let rejected = Promise()
    registration.action(dto, 2, rejected)
    XCTAssertNil(service.committedOnboardingJoinToken)
    XCTAssertFalse(service.committedJoin { observed.append($0) })
    XCTAssertEqual(rejected.completed.wait(timeout: .now() + 5), .success)
    XCTAssertFalse(rejected.resolved, "Malformed local Stop must never count as completed")
    XCTAssertEqual(rejected.rejection, "ERR_PAIRING:unavailable")
    XCTAssertEqual(try Data(contentsOf: stop), malformed)
    try FileManager.default.removeItem(at: stop)
    service.refresh()
    let retryDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: stop.path) && Date() < retryDeadline { usleep(1000) }
    let recoveredStop = try JSONDecoder().decode(UInt64.self, from: Data(contentsOf: stop))
    XCTAssertGreaterThan(recoveredStop, installation.generation, "Failed Stop must remain pending and retry while remote folder is absent")
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    let promise = Promise()
    registration.action(dto, Double(recoveredStop + 1), promise)
    XCTAssertEqual(promise.completed.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(promise.resolved, "Registered DTO Stop rejected: \(promise.rejection ?? "none")")
    let dtoStop = try JSONDecoder().decode(UInt64.self, from: Data(contentsOf: stop))
    XCTAssertGreaterThanOrEqual(dtoStop, recoveredStop + 1)
    let nullPromise = Promise()
    registration.action(nil, Double(dtoStop + 1), nullPromise)
    XCTAssertEqual(nullPromise.completed.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(nullPromise.resolved, "Registered null DTO Stop rejected: \(nullPromise.rejection ?? "none")")
    XCTAssertGreaterThanOrEqual(try JSONDecoder().decode(UInt64.self, from: Data(contentsOf: stop)), dtoStop + 1, "Resolved Stop requires durable local highwater")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(observed.isEmpty, "Stop must retire queued committed callbacks synchronously")
    try FileManager.default.moveItem(at: unavailable, to: folder)
    let restarted = PairingServices()
    defer { restarted.invalidate("shutdown") }
    restarted.bootstrap(dataDirectory: data, defaultFolder: fallback, keys: keys, safeMode: { false })
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    XCTAssertNil(restarted.committedOnboardingJoinToken)
    XCTAssertFalse(restarted.committedJoin { _ in })
    XCTAssertNil(host.committedState())
  }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', required=True)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    root = Path(args.work).resolve()
    root.mkdir(parents=True, exist_ok=True)
    destination = root / 'sync'
    shutil.copytree(package, destination, dirs_exist_ok=True, ignore=shutil.ignore_patterns('.build', 'node_modules'))
    source = (package / 'ios/SyncModule.swift').read_text()
    start = source.index('AsyncFunction("stopPairingInstallation")')
    suffix = '}.runOnQueue(.main)'
    end = source.index(suffix, start) + len(suffix)
    registration = source[start:end]
    (destination / 'tests/StopBridgeRegressionTests.swift').write_text(SWIFT.replace('REGISTRATION', registration))
    environment = dict(os.environ)
    for key, directory in [('TMPDIR', 'tmp'), ('CLANG_MODULE_CACHE_PATH', 'swift-cache'), ('SWIFTPM_MODULECACHE_OVERRIDE', 'swift-cache')]:
        target = root / directory
        target.mkdir(exist_ok=True)
        environment[key] = str(target)
    for directory in ['swift-config', 'swift-cache']:
        (root / directory).mkdir(exist_ok=True)
    command = ['swift', 'test', '--disable-sandbox', '--package-path', str(destination), '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'swift-cache'), '--config-path', str(root / 'swift-config'), '--filter', 'StopBridgeRegressionTests']
    return subprocess.call(command, env=environment)


if __name__ == '__main__':
    sys.exit(main())
