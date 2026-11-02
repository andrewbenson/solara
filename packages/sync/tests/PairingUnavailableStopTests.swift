import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingUnavailableStopTests: XCTestCase {
  func testInaccessibleCommittedFolderStaysPendingWithoutTombstoneAndResumes() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("temporarily-unavailable")
    try FileManager.default.moveItem(at: custom, to: unavailable)
    let service = PairingServices()
    service.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let limit = Date().addingTimeInterval(3)
    while service.committedOnboardingJoinToken == nil && Date() < limit { usleep(1000) }
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    XCTAssertNil(service.installationHost)
    var pending: PairingJoinState?
    XCTAssertTrue(service.committedJoin { pending = $0 })
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(pending, .approved)
    service.selectFolder(defaultFolder.path)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let stop = data.appendingPathComponent("Application Support/sync-pairing/host-stop.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path))
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    try FileManager.default.moveItem(at: unavailable, to: custom)
    service.refresh()
    let resumed = Date().addingTimeInterval(3)
    while service.installationHost == nil && Date() < resumed { usleep(1000) }
    XCTAssertEqual(service.installationHost?.committedState(), .approved)
    XCTAssertEqual(host.committedState(), .approved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path))
    service.invalidate("stop")
    XCTAssertNil(service.committedOnboardingJoinToken)
    service.invalidate("shutdown")
  }


  func testStopRetiresPendingCommittedObserverBeforeFolderReturns() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("temporarily-unavailable")
    try FileManager.default.moveItem(at: custom, to: unavailable)
    let service = PairingServices()
    service.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let limit = Date().addingTimeInterval(3)
    while service.committedOnboardingJoinToken == nil && Date() < limit { usleep(1000) }
    XCTAssertEqual(service.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    var states: [PairingJoinState] = []
    XCTAssertTrue(service.committedJoin { states.append($0) })
    service.invalidate("stop")
    XCTAssertNil(service.committedOnboardingJoinToken)
    XCTAssertFalse(service.committedJoin { states.append($0) }, "Stop must retire the pending committed observer even while its folder cannot be opened")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(states.isEmpty, "A committed callback queued before Stop must not be delivered after its synchronous barrier")
    service.invalidate("shutdown")
  }


  func testStopWhileCommittedFolderUnavailableMustSurviveRestart() throws {
    if let path = ProcessInfo.processInfo.environment["SOLARA_STOP_RESTART_FIXTURE"] {
      let root = URL(fileURLWithPath: path)
      let data = root.appendingPathComponent("data")
      let keys = FileKeyStore(directory: data)
      let restarted = PairingServices()
      restarted.bootstrap(dataDirectory: data, defaultFolder: root.appendingPathComponent("default"), keys: keys, safeMode: { false })
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      try FileManager.default.moveItem(at: root.appendingPathComponent("temporarily-unavailable"), to: root.appendingPathComponent("custom"))
      restarted.refresh()
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      XCTAssertNil(restarted.committedOnboardingJoinToken)
      XCTAssertFalse(restarted.committedJoin { _ in })
      XCTAssertNil(try PairingInstallationHost.committedTarget(dataDirectory: data, keys: keys))
      restarted.invalidate("shutdown")
      return
    }
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let custom = root.appendingPathComponent("custom")
    let defaultFolder = root.appendingPathComponent("default")
    let entropy = Data(repeating: 41, count: 32)
    let cid = SyncKeys(entropy: entropy).chainTag
    for directory in [data, defaultFolder, custom.appendingPathComponent(cid)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let identity = try PairingMailbox(folder: custom, cid: cid).folderIdentity
    let keys = FileKeyStore(directory: data)
    let store = try PairingDurableStore(dataDirectory: data, syncFolder: custom, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false))
    let installation = PairingInstallation(transaction: Data(repeating: 42, count: 32), cid: cid, device: Base32.encode(Data(repeating: 43, count: 16)), folderIdentity: identity, generation: 1)
    let host = PairingInstallationHost(dataDirectory: data, folder: custom, folderIdentity: identity, keys: keys, accounting: store)
    var prepared = false
    host.prepare(installation) { prepared = $0 }
    XCTAssertTrue(prepared)
    XCTAssertTrue(keys.pairingInsert(entropy, account: installation.device))
    _ = try store.persistInstallationDecision(.init(installation: installation, disposition: .admitted))
    host.keySaved(installation, initialized: { _ in }, ready: { _ in })
    XCTAssertEqual(host.committedState(), .approved)
    let unavailable = root.appendingPathComponent("temporarily-unavailable")
    try FileManager.default.moveItem(at: custom, to: unavailable)
    var service: PairingServices? = PairingServices()
    service!.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    let limit = Date().addingTimeInterval(3)
    while service!.committedOnboardingJoinToken == nil && Date() < limit { usleep(1000) }
    XCTAssertEqual(service!.committedOnboardingJoinToken, PairingMailbox.hex(installation.transaction))
    XCTAssertNil(service!.installationHost)
    var pending: PairingJoinState?
    XCTAssertTrue(service!.committedJoin { pending = $0 })
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(pending, .approved)
    service!.invalidate("stop")
    service!.invalidate("shutdown")
    weak var stoppedService = service
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    service = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertNil(stoppedService)
    let stop = data.appendingPathComponent("Application Support/sync-pairing/host-stop.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: stop.path), "Explicit Stop must durably retire a committed join even while its folder is inaccessible")
    let restarted = PairingServices()
    restarted.bootstrap(dataDirectory: data, defaultFolder: defaultFolder, keys: keys, safeMode: { false })
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try FileManager.default.moveItem(at: unavailable, to: custom)
    restarted.refresh()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    XCTAssertNil(restarted.committedOnboardingJoinToken, "Stopped join must not recover after process restart")
    XCTAssertFalse(restarted.committedJoin { _ in }, "Stopped join recovered as committed after restart")
    XCTAssertNil(host.committedState(), "Stop tombstone must prevent old admission from resuming")
    restarted.invalidate("shutdown")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try FileManager.default.moveItem(at: custom, to: unavailable)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["-XCTest", "SolaraLegacySyncCoreTests.PairingUnavailableStopTests/testStopWhileCommittedFolderUnavailableMustSurviveRestart", Bundle(for: Self.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["SOLARA_STOP_RESTART_FIXTURE"] = root.path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let exited = expectation(description: "restarted process completed")
    process.terminationHandler = { _ in exited.fulfill() }
    try process.run()
    wait(for: [exited], timeout: 10)
    if process.isRunning { process.terminate() }
    else {
      let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertTrue(text.contains("Executed 1 test"))
      XCTAssertEqual(process.terminationStatus, 0, text.replacingOccurrences(of: "\n", with: " | "))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    XCTAssertNil(host.committedState())
  }

}
