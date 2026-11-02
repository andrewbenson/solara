import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingServiceOwnershipTests: XCTestCase {
  private final class Gate {
    private let lock = NSLock()
    var reached: (() -> Void)?
    let release = DispatchSemaphore(value: 0)
    private var holding = false
    func hold() { lock.lock(); holding = true; lock.unlock() }
    func sample() -> Bool {
      lock.lock()
      let held = holding
      holding = false
      lock.unlock()
      if held {
        reached?()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
      }
      return false
    }
  }

  func testSupersededWorkerCannotBeginAfterBlockedConfiguration() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let folder = root.appendingPathComponent("folder")
    for directory in [data, folder] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let keys = FileKeyStore(directory: data)
    let gate = Gate()
    let service = PairingServices()
    let rig = PairingCoordinatorTests.Rig()
    service.register(rig.coordinator)
    service.bootstrap(dataDirectory: data, defaultFolder: folder, keys: keys, safeMode: { gate.sample() })
    let configured = Date().addingTimeInterval(3)
    while service.installationHost == nil && Date() < configured { usleep(1000) }
    XCTAssertNotNil(service.installationHost)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let held = expectation(description: "replacement configuration blocked")
    gate.reached = { held.fulfill() }
    gate.hold()
    var obsoleteStates: [PairingJoinState] = []
    let obsolete = service.start(cid: rig.mailbox.pairingCID) { obsoleteStates.append($0) }
    wait(for: [held], timeout: 3)
    let latest = service.start(cid: rig.mailbox.pairingCID) { _ in }
    XCTAssertEqual(latest.cancel(), .cancelled)
    gate.release.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    XCTAssertTrue(obsoleteStates.isEmpty, "A superseded worker must not invoke native start after its blocked configuration finishes")
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    _ = obsolete.cancel()
    service.invalidate("shutdown")
  }
}
