import AppKit
import Foundation
import Testing
@testable import SolaraUI

@MainActor
final class SuppressionDisk {
  enum Barrier: String, CaseIterable { case write, rename, directorySync, readback }
  let directory: URL
  let record: URL
  var held = false
  var failure: Barrier?
  var failSuppressed = false
  var attempts: [String] = []
  var committedRevision: UInt64 = 0

  init(bytes: String) throws {
    directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("pairing-suppression-\(UUID().uuidString)")
    record = directory.appendingPathComponent("suppression.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: record)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
  var bytes: Data { (try? Data(contentsOf: record)) ?? Data() }

  func write(_ state: String, revision: UInt64) -> Bool {
    attempts.append(state)
    guard !held, revision >= committedRevision, failure != .write, !(state == "suppressed" && failSuppressed) else { return false }
    let data = Data("{\"v\":1,\"state\":\"\(state)\",\"revision\":\(revision)}".utf8)
    do {
      let staged = directory.appendingPathComponent("pending.json")
      try data.write(to: staged, options: .atomic)
      guard failure != .rename else { return false }
      try data.write(to: record, options: .atomic)
      committedRevision = revision
      guard failure != .directorySync, failure != .readback else { return false }
      guard try Data(contentsOf: record) == data else { return false }
      committedRevision = revision
      return true
    } catch { return false }
  }
}

@MainActor
final class SuppressionContractService: TrustedPairingService {
  enum Refusal: Error { case invalid }
  let disk: SuppressionDisk
  let surface = TrustedSurface()
  var activeArm: TrustedArm?
  var revision: UInt64 = 1
  var openVerified = false
  var suppressed = true
  var unresolvedFailure = false
  var quiesced = false
  var acceptedDismissals = 0
  var armCalls = 0
  var history = 7
  var clock: TimeInterval = 10
  var phase: TrustedPhase = .idle
  var requests: [TrustedRequest] = []
  var projectedIndicator: TrustedIndicator?
  var subscribers: [UUID: (TrustedSurface?, @MainActor (TrustedSnapshot) -> Void)] = [:]

  init(disk: SuppressionDisk) {
    self.disk = disk
    if let object = try? JSONSerialization.jsonObject(with: disk.bytes) as? [String: Any],
       object["v"] as? Int == 1, object["state"] as? String == "enabledClean" {
      open()
    }
  }

  func open() {
    revision += 1
    if disk.write("enabledOpen", revision: revision) {
      openVerified = true
      suppressed = false
      unresolvedFailure = false
    } else {
      openVerified = false
      suppressed = true
      unresolvedFailure = true
    }
  }

  var snapshot: TrustedSnapshot {
    TrustedSnapshot(revision: revision, eligible: !quiesced, openMarkerVerified: openVerified,
      indicator: projectedIndicator ?? (unresolvedFailure ? .persistenceFailure : suppressed ? .suppressed : requests.isEmpty ? .none : .pending),
      requests: requests, arm: activeArm, phase: phase, foreground: activeArm != nil)
  }

  func publish() {
    revision += 1
    for (_, (_, receive)) in subscribers { receive(snapshot) }
  }

  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription {
    let id = UUID()
    subscribers[id] = (surface, receive)
    receive(snapshot)
    return TrustedSubscription { [weak self] in self?.subscribers.removeValue(forKey: id) }
  }

  func attach(to settingsWindow: NSWindow) -> TrustedSurface { surface }

  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm {
    guard surface === self.surface, activeArm == nil, !quiesced else { throw Refusal.invalid }
    armCalls += 1
    activeArm = TrustedArm(deadline: clock + 120)
    phase = .choosing
    if suppressed || !openVerified { open() }
    return activeArm!
  }

  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws {
    guard openVerified, !suppressed, activeArm === arm, requests.contains(where: { $0 === request }) else { throw Refusal.invalid }
    phase = .preparing
    publish()
  }

  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws {
    guard openVerified, !suppressed, activeArm === arm, surface === self.surface else { throw Refusal.invalid }
    publish()
  }

  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) {
    if event == .removed { activeArm = nil; phase = .ended(.removed) }
    publish()
  }

  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? { nil }
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws { throw Refusal.invalid }

  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) {
    guard surface === self.surface, arm == nil || arm === activeArm, !quiesced else { return }
    if disposition == .unexpectedRequest {
      guard openVerified else { return }
      acceptedDismissals += 1
      suppressed = true
      activeArm = nil
      phase = .ended(.unexpectedRequest)
      publish()
      if !disk.write("suppressed", revision: revision) { unresolvedFailure = true }
      publish()
    } else {
      activeArm = nil
      phase = .ended(.cancelled)
      publish()
    }
  }

  func cleanShutdown() {
    quiesced = true
    if !suppressed && !unresolvedFailure && openVerified { _ = disk.write("enabledClean", revision: revision + 1) }
  }

  func remoteRequest() {
    requests = [TrustedRequest(chainSuffix: "CID", requestSuffix: "RID", sessionSuffix: "SID", firstObserved: clock)]
    publish()
  }
}

@MainActor
struct SyncSuppressionContractTests {
  private func mounted(_ service: SuppressionContractService) -> SyncTrustedPairingModel {
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    model.attach(to: NSWindow())
    return model
  }

  @Test func S01_dismissalStaysSuppressedAfterRestartFromActualBytes() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    service.publish()
    #expect(model.isPresented)
    #expect(model.canDismissUnexpected)
    model.end(.unexpectedRequest)
    #expect(service.acceptedDismissals == 1)
    #expect(!model.isPresented)
    let relaunched = SuppressionContractService(disk: disk)
    let reopened = mounted(relaunched)
    relaunched.remoteRequest()
    #expect(reopened.indicator == .suppressed)
    #expect(!reopened.isPresented)
  }

  @Test func S02_failedDismissalThenImmediateCrashRetainsOpenMarker() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    service.publish()
    disk.failSuppressed = true
    model.end(.unexpectedRequest)
    #expect(service.acceptedDismissals == 1)
    #expect(service.unresolvedFailure)
    #expect(String(decoding: disk.bytes, as: UTF8.self).contains("enabledOpen"))
    let relaunched = SuppressionContractService(disk: disk)
    let reopened = mounted(relaunched)
    relaunched.remoteRequest()
    #expect(reopened.indicator == .suppressed)
    #expect(!reopened.isPresented)
  }

  @Test(arguments: SuppressionDisk.Barrier.allCases)
  func S03_noChooserOrPreparingSurfaceBeforeEveryMarkerBarrier(_ barrier: SuppressionDisk.Barrier) throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    disk.failure = barrier
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    service.projectedIndicator = .pending
    for phase: TrustedPhase in [.choosing, .preparing, .comparing, .authenticating, .sentUnconfirmed] {
      service.phase = phase
      service.publish()
      #expect(!model.isPresented)
      #expect(!model.canDismissUnexpected)
      #expect(model.indicator != .pending && model.indicator != .overflow)
      model.end(.unexpectedRequest)
      #expect(service.acceptedDismissals == 0)
    }
    #expect(service.armCalls == 1)
    service.cleanShutdown()
    #expect(!disk.attempts.contains("enabledClean"))
    let relaunched = SuppressionContractService(disk: disk)
    let reopened = mounted(relaunched)
    relaunched.remoteRequest()
    #expect(!reopened.isPresented)
    #expect(!reopened.canDismissUnexpected)
  }

  @Test(arguments: ["", "corrupt", "{\"v\":2,\"state\":\"enabledClean\"}", "{\"v\":1,\"state\":\"enabledOpen\"}", "{\"v\":1,\"state\":\"unknown\"}"])
  func S04_missingCorruptUnknownAndUncleanRecordsStaySuppressed(_ bytes: String) throws {
    let disk = try SuppressionDisk(bytes: bytes)
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    service.remoteRequest()
    #expect(model.indicator == .suppressed)
    #expect(!model.isPresented)
    #expect(disk.attempts.isEmpty)
  }

  @Test func S05_olderSnapshotAndWriteCannotUndoNewerDismissal() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    service.remoteRequest()
    let stale = service.snapshot
    model.end(.unexpectedRequest)
    let saved = disk.bytes
    #expect(!disk.write("enabledOpen", revision: stale.revision))
    for (_, (_, callback)) in service.subscribers { callback(stale) }
    #expect(disk.bytes == saved)
    #expect(model.indicator == .suppressed)
    #expect(!model.isPresented)
  }

  @Test func S06_failedDismissalForbidsCleanShutdownWrite() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    service.publish()
    disk.failSuppressed = true
    model.end(.unexpectedRequest)
    service.cleanShutdown()
    #expect(service.acceptedDismissals == 1)
    #expect(!disk.attempts.contains("enabledClean"))
    #expect(String(decoding: disk.bytes, as: UTF8.self).contains("enabledOpen"))
    #expect(model.indicator == .persistenceFailure)
  }

  @Test func S07_remoteAndPaneEventsCannotRepairSuppression() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"suppressed\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    for event: TrustedSurfaceEvent in [.visibilityChanged, .remounted, .removed] {
      service.remoteRequest()
      model.surfaceChanged(event)
      #expect(model.indicator == .suppressed)
      #expect(!model.isPresented)
    }
    model.teardown()
    let reopened = mounted(service)
    service.remoteRequest()
    #expect(reopened.indicator == .suppressed)
    #expect(service.armCalls == 0)
    #expect(disk.attempts.isEmpty)
  }

  @Test func S08_explicitRepairRequiresVerifiedWriteAndRetainsAccounting() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"suppressed\"}")
    defer { disk.remove() }
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    disk.failure = .readback
    model.connect()
    service.publish()
    #expect(service.armCalls == 1)
    #expect(!model.isPresented)
    #expect(model.indicator == .persistenceFailure)
    model.end(.cancel)
    disk.failure = nil
    model.connect()
    service.publish()
    #expect(service.armCalls == 2)
    #expect(model.isPresented)
    #expect(model.canDismissUnexpected)
    #expect(service.history == 7)
    #expect(service.activeArm?.deadline == 130)
  }

  @Test func S03_heldOpenEarlyDismissalBothFailuresImmediateCrashRelaunch() throws {
    let disk = try SuppressionDisk(bytes: "{\"v\":1,\"state\":\"enabledClean\"}")
    defer { disk.remove() }
    disk.held = true
    disk.failSuppressed = true
    let service = SuppressionContractService(disk: disk)
    let model = mounted(service)
    model.connect()
    let deadline = service.activeArm?.deadline
    service.publish()
    #expect(!model.isPresented)
    #expect(!model.canDismissUnexpected)
    model.end(.unexpectedRequest)
    #expect(service.acceptedDismissals == 0)
    #expect(service.activeArm?.deadline == deadline)
    disk.held = false
    disk.failure = .write
    service.open()
    service.publish()
    #expect(!model.isPresented)
    #expect(!disk.attempts.contains("suppressed"))
    let relaunched = SuppressionContractService(disk: disk)
    let reopened = mounted(relaunched)
    relaunched.remoteRequest()
    #expect(reopened.indicator == .persistenceFailure)
    #expect(!reopened.isPresented)
    #expect(relaunched.acceptedDismissals == 0)
    disk.failure = nil
    relaunched.open()
    relaunched.publish()
    #expect(relaunched.openVerified)
    #expect(!reopened.isPresented)
  }
}
