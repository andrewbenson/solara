import Foundation
@preconcurrency import SolaraSyncAdapter

final class PairingJoiningAdapter: SolaraSyncAdapter.PairingJoining {
  private let folder: String
  private let owner = PairingServices.shared

  init(folder: String) { self.folder = folder }

  func start(cid: String, onState: @escaping @MainActor (SolaraSyncAdapter.PairingJoinState) -> Void) -> any SolaraSyncAdapter.PairingJoinHandle {
    owner.start(folder: folder, cid: cid, onState: onState)
  }

  func committedJoin(onState: @escaping @MainActor (SolaraSyncAdapter.PairingJoinState) -> Void) -> Bool {
    owner.committedJoin(onState: onState)
  }
}
