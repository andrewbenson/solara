import Foundation
import SolaraSyncAdapter
import SolaraUI

@MainActor
public enum OnboardingPairingServices {
  public static var joining: ((String) -> SolaraUI.PairingJoining?)?
  public static var committedJoinToken: (() -> String?)?
}

public final class OnboardingPairingBridge: SolaraUI.PairingJoining {
  private let joining: SolaraSyncAdapter.PairingJoining

  public init(_ joining: SolaraSyncAdapter.PairingJoining) {
    self.joining = joining
  }

  public func start(cid: String, onState: @escaping @MainActor (SolaraUI.PairingJoinState) -> Void) -> SolaraUI.PairingJoinHandle {
    Handle(joining.start(cid: cid) { onState(Self.state($0)) })
  }

  public func committedJoin(onState: @escaping @MainActor (SolaraUI.PairingJoinState) -> Void) -> Bool {
    joining.committedJoin { onState(Self.state($0)) }
  }

  static func state(_ state: SolaraSyncAdapter.PairingJoinState) -> SolaraUI.PairingJoinState {
    switch state {
    case .preparing: .preparing
    case .waiting(let expires): .waiting(expires: expires)
    case .comparing(let code, let claimedName): .comparing(code: code, claimedName: claimedName)
    case .approved: .approved
    case .installed: .installed
    case .failed(let failure): .failed(Self.failure(failure))
    }
  }

  static func state(_ state: SolaraUI.PairingJoinState) -> SolaraSyncAdapter.PairingJoinState {
    switch state {
    case .preparing: .preparing
    case .waiting(let expires): .waiting(expires: expires)
    case .comparing(let code, let claimedName): .comparing(code: code, claimedName: claimedName)
    case .approved: .approved
    case .installed: .installed
    case .failed(let failure): .failed(Self.failure(failure))
    }
  }

  static func failure(_ failure: SolaraSyncAdapter.PairingJoinFailure) -> SolaraUI.PairingJoinFailure {
    switch failure {
    case .expired: .expired
    case .denied: .denied
    case .mismatch: .mismatch
    case .folderUnavailable: .folderUnavailable
    case .invalidPeer: .invalidPeer
    case .cancelled: .cancelled
    }
  }

  static func failure(_ failure: SolaraUI.PairingJoinFailure) -> SolaraSyncAdapter.PairingJoinFailure {
    switch failure {
    case .expired: .expired
    case .denied: .denied
    case .mismatch: .mismatch
    case .folderUnavailable: .folderUnavailable
    case .invalidPeer: .invalidPeer
    case .cancelled: .cancelled
    }
  }

  static func cancelResult(_ result: SolaraSyncAdapter.PairingCancelResult) -> SolaraUI.PairingCancelResult {
    switch result {
    case .cancelled: .cancelled
    case .alreadyCommitted: .alreadyCommitted
    case .unavailable: .unavailable
    }
  }

  static func cancelResult(_ result: SolaraUI.PairingCancelResult) -> SolaraSyncAdapter.PairingCancelResult {
    switch result {
    case .cancelled: .cancelled
    case .alreadyCommitted: .alreadyCommitted
    case .unavailable: .unavailable
    }
  }

  private final class Handle: SolaraUI.PairingJoinHandle {
    private let handle: SolaraSyncAdapter.PairingJoinHandle

    init(_ handle: SolaraSyncAdapter.PairingJoinHandle) {
      self.handle = handle
    }

    @discardableResult func cancel() -> SolaraUI.PairingCancelResult {
      OnboardingPairingBridge.cancelResult(handle.cancel())
    }

    func startAgain() {
      handle.startAgain()
    }
  }
}

@MainActor
final class OnboardingDiscoveryAdapter: OnboardingDiscovering {
  var folder: URL

  init(folder: URL) {
    self.folder = folder
  }

  func start(onResult: @escaping @MainActor (OnboardingDiscoveryResult) -> Void) -> OnboardingDiscoveryHandle {
    let handle = Handle()
    SyncDiscoveryBridge.run(folder: folder) { outcome in
      Task { @MainActor in
        guard !handle.cancelled else { return }
        onResult(Self.result(outcome))
      }
    }
    return handle
  }

  static func result(_ outcome: SyncDiscoveryOutcome) -> OnboardingDiscoveryResult {
    switch outcome {
    case .found(let candidates): .found(candidates.map { .init(cid: $0.cid, lastActivity: $0.lastActivity) })
    case .empty: .empty
    case .needsHydration: .needsHydration
    case .unavailable: .unavailable
    case .permissionDenied: .permissionDenied
    case .timedOut: .timedOut
    }
  }

  private final class Handle: OnboardingDiscoveryHandle {
    var cancelled = false
    func cancel() { cancelled = true }
  }
}
