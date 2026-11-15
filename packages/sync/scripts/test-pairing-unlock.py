import argparse
import hashlib
import os
from pathlib import Path
import signal
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True)
parser.add_argument('--products')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
scratch = Path(args.scratch).resolve()
scratch.mkdir(parents=True, exist_ok=True)
products = Path(args.products).resolve() if args.products else repo / 'packages/sync/.build/out/Products/Debug'
source = (repo / 'packages/sync/ios/SyncModule.swift').read_text()
registration = source[source.index('    AsyncFunction("unlock")'):source.index('    AsyncFunction("forget")')].strip()
key_state = source[source.index('private final class KeyState {'):]
swift = r'''import AppKit
import Foundation
@testable import SolaraLegacySyncCore

private enum Fixture {
  static var timers = 0
  static let service = PairingServices(sessionDictionary: { ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": false] }, scheduleTimer: { _, _, _, _ in timers += 1; return {} })
}

private final class Promise {
  let completed = DispatchSemaphore(value: 0)
  var resolved: Bool?
  func resolve(_ value: Bool) { resolved = value; completed.signal() }
}

private struct UnlockFunction {
  let action: (String, Promise) -> Void
  func runOnQueue(_ queue: DispatchQueue) -> UnlockFunction { self }
}

private func AsyncFunction(_ name: String, _ action: @escaping (String, Promise) -> Void) -> UnlockFunction {
  UnlockFunction(action: action)
}

private final class UnlockBridge {
  let state = KeyState()
  static let work = DispatchQueue(label: "solara.sync.unlock.regression")
  static var keyStore: FileKeyStore!
  func definition() -> UnlockFunction {
    REGISTRATION
  }
}

KEY_STATE

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let folder = root.appendingPathComponent("sync")
let entropy = Data(repeating: 31, count: 32)
let account = Base32.encode(Data(repeating: 7, count: 16))
let keys = FileKeyStore(directory: root)
try FileManager.default.createDirectory(at: folder.appendingPathComponent(SyncKeys(entropy: entropy).chainTag), withIntermediateDirectories: true)
guard keys.save(entropy, account: account) else { exit(2) }
try JSONSerialization.data(withJSONObject: ["v": 1, "enabled": true, "deviceId": account, "folder": folder.path]).write(to: root.appendingPathComponent("sync.json"))
UnlockBridge.keyStore = keys
private let bridge = UnlockBridge()
bridge.state.set(entropy, account: account)
Fixture.service.registerStore(healthy: { true }, revision: { 1 }, projection: { _, _ in [:] })
Fixture.service.bootstrap(dataDirectory: root, defaultFolder: folder, keys: keys, safeMode: { false })
let readyDeadline = Date().addingTimeInterval(3)
while !Fixture.service.trustedSnapshot(nil).eligible && Date() < readyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
let before = Fixture.service.trustedSnapshot(nil).eligible
Fixture.service.invalidate("key")
bridge.state.set(entropy, account: account)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
let automaticRemainedQuiet = !Fixture.service.trustedSnapshot(nil).eligible
private let promise = Promise()
bridge.definition().action(account, promise)
let completed = promise.completed.wait(timeout: .now() + 3) == .success
let refreshedDeadline = Date().addingTimeInterval(3)
while !Fixture.service.trustedSnapshot(nil).eligible && Date() < refreshedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
let after = Fixture.service.trustedSnapshot(nil).eligible
print("Same-key native unlock: initial=\(before) automaticQuiet=\(automaticRemainedQuiet) resolved=\(completed && promise.resolved == true) refreshed=\(after) periodicSources=\(Fixture.timers)")
Fixture.service.invalidate("shutdown")
exit(before && automaticRemainedQuiet && completed && promise.resolved == true && after && Fixture.timers == 0 ? 0 : 1)
'''
swift = swift.replace('REGISTRATION', registration).replace('KEY_STATE', key_state).replace('PairingServices.shared', 'Fixture.service')
main = scratch / 'main.swift'
main.write_text(swift)
binary = scratch / 'pairing-unlock'
print('Production SyncModule SHA256 ' + hashlib.sha256(source.encode()).hexdigest(), flush=True)
commands = [
    ['swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx26.0', '-I', str(products), str(products / 'SolaraLegacySyncCore.o'), str(main), '-o', str(binary)],
    [str(binary), str(scratch / 'data')],
]
for command in commands:
    process = subprocess.Popen(command, start_new_session=True)
    try:
        status = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise SystemExit(124)
    if status != 0:
        raise SystemExit(status)
