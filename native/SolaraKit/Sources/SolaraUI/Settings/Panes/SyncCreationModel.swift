import Foundation
import Observation

public enum SyncCreationCompleteness: String, Sendable {
  case complete, incomplete, needsHydration, unavailable, permissionDenied, timedOut, unknown
}

public struct SyncCreationInspection: Equatable, Sendable {
  public let id: String
  public let folder: String
  public let candidates: [String]
  public let completeness: SyncCreationCompleteness

  public init(id: String, folder: String, candidates: [String], completeness: String) {
    self.id = id
    self.folder = folder
    self.candidates = candidates
    self.completeness = SyncCreationCompleteness(rawValue: completeness) ?? .unknown
  }
}

@MainActor
public protocol SyncCreationServices: AnyObject {
  func inspectSyncCreation(folder: String) async -> SyncCreationInspection
  func createSync(folder: String, inspectionID: String) async -> String?
  func invalidateSyncCreation(inspectionID: String)
}

public extension SyncCreationServices {
  func invalidateSyncCreation(inspectionID: String) {}
}

@MainActor
@Observable
public final class SyncCreationModel {
  public enum State: Equatable {
    case idle, checking, warning(SyncCreationInspection), creating, created, failed(String)
  }

  public private(set) var state: State = .idle
  @ObservationIgnored let services: SyncCreationServices

  public init(services: SyncCreationServices) { self.services = services }
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var currentInspection: String?

  public func start(folder: String) async {
    guard state != .checking, state != .creating else { return }
    if let currentInspection { services.invalidateSyncCreation(inspectionID: currentInspection) }
    currentInspection = nil
    generation &+= 1
    let captured = generation
    state = .checking
    let inspection = await services.inspectSyncCreation(folder: folder)
    guard captured == generation else {
      services.invalidateSyncCreation(inspectionID: inspection.id)
      return
    }
    currentInspection = inspection.id
    guard inspection.folder == folder, inspection.completeness == .complete else {
      state = .failed(Self.failure(inspection.completeness.rawValue))
      return
    }
    if inspection.candidates.isEmpty {
      await create(inspection, generation: captured)
    } else {
      state = .warning(inspection)
    }
  }

  public func confirmSeparateSync() async {
    guard case .warning(let inspection) = state else { return }
    await create(inspection, generation: generation)
  }

  private func create(_ inspection: SyncCreationInspection, generation captured: UInt64) async {
    state = .creating
    let error = await services.createSync(folder: inspection.folder, inspectionID: inspection.id)
    guard captured == generation else { return }
    currentInspection = nil
    state = error.map(State.failed) ?? .created
  }

  public func cancel() {
    if let currentInspection { services.invalidateSyncCreation(inspectionID: currentInspection) }
    currentInspection = nil
    generation &+= 1
    state = .idle
  }

  private static func failure(_ disposition: String) -> String {
    switch disposition {
    case "permissionDenied": "This folder isn't accessible. Choose another folder or enter your recovery phrase."
    case "needsHydration": "Sync data is still downloading. Try again or enter your recovery phrase."
    case "timedOut": "Couldn't finish checking iCloud Drive. Try Again."
    default: "Couldn't finish checking iCloud Drive."
    }
  }
}
