import Darwin
import Foundation

public final class SyncCreationAdmission: @unchecked Sendable {
  public static let shared = SyncCreationAdmission()
  struct Inspection: Equatable {
    let id: String
    let folder: String
    let candidates: [String]
    let completeness: String
  }

  enum Failure: Error { case unavailable, changed, invalidPermit }

  struct Reservation {
    let id: String
    let finish: () -> Void
    func callAsFunction() { finish() }
  }

  private struct Pending {
    let inspection: Inspection
    let identity: String
    let deadline: ContinuousClock.Instant
    var consented = false
  }

  private let fileSystem: DiscoveryFileSystem
  private let lock = NSLock()
  private var pending: [String: Pending] = [:]
  private var active: Pending?

  init(fileSystem: DiscoveryFileSystem = LiveDiscoveryFileSystem()) { self.fileSystem = fileSystem }

  func discover(folder: URL, _ done: @escaping (Inspection) -> Void) {
    let identity = Self.identity(folder)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    SyncDiscovery(folder: folder, fileSystem: fileSystem).run { result in
      let inspection = self.lock.withLock {
        self.record(result, folder: folder, identity: identity, deadline: deadline).inspection
      }
      done(inspection)
    }
  }

  func inspect(folder: URL) -> Inspection {
    lock.withLock { inspectLocked(folder: folder).inspection }
  }

  private func inspectLocked(folder: URL) -> Pending {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let identity = Self.identity(folder)
    let result = SyncDiscovery.result(of: fileSystem.scan(folder, limit: SyncDiscovery.entriesPerPass), folder: folder, fileSystem: fileSystem)
    return record(result, folder: folder, identity: identity, deadline: deadline)
  }

  private func record(_ result: SyncDiscovery.Result, folder: URL, identity: String, deadline: ContinuousClock.Instant) -> Pending {
    let candidates: [String]
    let completeness: String
    switch result {
    case .found(let found): candidates = found.map(\.cid); completeness = "complete"
    case .foundIncomplete(let found): candidates = found.map(\.cid); completeness = "incomplete"
    case .empty: candidates = []; completeness = "complete"
    case .needsHydration: candidates = []; completeness = "needsHydration"
    case .unavailable: candidates = []; completeness = "unavailable"
    case .permissionDenied: candidates = []; completeness = "permissionDenied"
    case .timedOut: candidates = []; completeness = "timedOut"
    }
    let inspection = Inspection(id: UUID().uuidString, folder: folder.standardizedFileURL.path, candidates: candidates.sorted(), completeness: ContinuousClock.now < deadline && identity == Self.identity(folder) ? completeness : "timedOut")
    let record = Pending(inspection: inspection, identity: identity, deadline: ContinuousClock.now.advanced(by: .seconds(120)))
    if pending.count >= 32 { pending.removeAll() }
    pending[inspection.id] = record
    return record
  }

  func admit(folder: URL, inspectionID: String?) throws -> Reservation {
    try lock.withLock {
      guard active == nil else { throw Failure.invalidPermit }
      let expected: Pending
      if let inspectionID {
        guard let record = pending.removeValue(forKey: inspectionID) else { throw Failure.invalidPermit }
        guard record.inspection.completeness == "complete" else { throw Failure.unavailable }
        guard record.inspection.candidates.isEmpty || record.consented else { throw Failure.invalidPermit }
        expected = record
      } else {
        expected = inspectLocked(folder: folder)
        pending.removeValue(forKey: expected.inspection.id)
        guard expected.inspection.completeness == "complete" else { throw Failure.unavailable }
        guard expected.inspection.candidates.isEmpty else { throw Failure.invalidPermit }
      }
      try validate(expected, folder: folder)
      active = expected
      return Reservation(id: expected.inspection.id) { [weak self] in
        self?.lock.withLock {
          if self?.active?.inspection.id == expected.inspection.id { self?.active = nil }
        }
      }
    }
  }

  public func consent(inspectionID: String) -> Bool {
    lock.withLock {
      guard active == nil, var record = pending[inspectionID],
            record.inspection.completeness == "complete", ContinuousClock.now < record.deadline else { return false }
      record.consented = true
      pending[inspectionID] = record
      return true
    }
  }

  public func invalidate(inspectionID: String) {
    lock.withLock {
      pending.removeValue(forKey: inspectionID)
      if active?.inspection.id == inspectionID { active = nil }
    }
  }

  func commit(folder: URL, reservation: Reservation, _ action: () throws -> Void) throws {
    try lock.withLock {
      guard let active, active.inspection.id == reservation.id else { throw Failure.invalidPermit }
      try validate(active, folder: folder)
      try action()
    }
  }

  func recheck(folder: URL, reservation: Reservation) throws {
    try lock.withLock {
      guard let active, active.inspection.id == reservation.id else { throw Failure.invalidPermit }
      try validate(active, folder: folder)
    }
  }

  private func validate(_ expected: Pending, folder: URL) throws {
    guard expected.inspection.completeness == "complete", ContinuousClock.now < expected.deadline else { throw Failure.unavailable }
    guard expected.inspection.folder == folder.standardizedFileURL.path, expected.identity == Self.identity(folder) else { throw Failure.changed }
    let current = inspectLocked(folder: folder)
    pending.removeValue(forKey: current.inspection.id)
    guard current.inspection.completeness == "complete", current.identity == expected.identity, current.inspection.candidates == expected.inspection.candidates else { throw Failure.changed }
  }

  private static func identity(_ folder: URL) -> String {
    var info = stat()
    if lstat(folder.path, &info) == 0 { return "\(info.st_dev):\(info.st_ino):\(info.st_mode)" }
    guard errno == ENOENT else { return "unavailable" }
    let parent = folder.deletingLastPathComponent()
    guard parent.path != folder.path else { return "unavailable" }
    return "missing:\(folder.lastPathComponent):\(identity(parent))"
  }
}
