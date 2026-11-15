import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingRefreshCoalescingTests: XCTestCase {
  func testStoreRegistrationDuringConfigureIsReplayedWithoutPeriodicTimer() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data"), folder = root.appendingPathComponent("folder")
    for url in [data, folder] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let held = expectation(description: "configuration captured old store state")
    let replayed = expectation(description: "new store state captured without periodic retry")
    let lock = NSLock()
    var shouldHold = false
    let release = DispatchSemaphore(value: 0)
    let service = PairingServices()
    defer { service.invalidate("shutdown") }
    service.bootstrap(dataDirectory: data, defaultFolder: folder, keys: FileKeyStore(directory: data), safeMode: {
      lock.lock(); let hold = shouldHold; shouldHold = false; lock.unlock()
      if hold { held.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
      return false
    })
    try PairingCoordinatorTests().wait { service.installationHost != nil && service.coordinator != nil }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    lock.lock(); shouldHold = true; lock.unlock()
    service.refresh()
    wait(for: [held], timeout: 3)
    let sampled = PairingCoordinatorTests.Handoff(false)
    service.registerStore(healthy: {
      if !sampled.value { sampled.value = true; replayed.fulfill() }
      return true
    }, revision: { 1 }, projection: { _, _ in [:] })
    release.signal()
    wait(for: [replayed], timeout: 0.3)
  }
}
