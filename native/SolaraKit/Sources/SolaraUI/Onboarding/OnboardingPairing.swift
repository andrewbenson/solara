import Foundation

public enum PairingJoinState: Equatable {
  case preparing
  case waiting(expires: ContinuousClock.Instant)
  case comparing(code: String, claimedName: String)
  case approved
  case installed
  case failed(PairingJoinFailure)
}

public enum PairingJoinFailure: Equatable { case expired, denied, mismatch, folderUnavailable, invalidPeer, cancelled }

public enum PairingCancelResult { case cancelled, alreadyCommitted, unavailable }

public protocol PairingJoining: AnyObject {
  func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle
  func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool
}

public protocol PairingJoinHandle: AnyObject {
  @discardableResult func cancel() -> PairingCancelResult
  func startAgain()
}

public struct OnboardingDiscoveryCandidate: Equatable, Sendable {
  public let cid: String
  public let lastActivity: Date?

  public init(cid: String, lastActivity: Date?) {
    self.cid = cid
    self.lastActivity = lastActivity
  }
}

public enum OnboardingDiscoveryResult: Equatable, Sendable {
  case found([OnboardingDiscoveryCandidate])
  case empty, needsHydration, unavailable, permissionDenied, timedOut
}

@MainActor
public protocol OnboardingDiscoveryHandle: AnyObject {
  func cancel()
}

@MainActor
public protocol OnboardingDiscovering: AnyObject {
  func start(onResult: @escaping @MainActor (OnboardingDiscoveryResult) -> Void) -> OnboardingDiscoveryHandle
}

@MainActor
public protocol OnboardingScheduledTask: AnyObject {
  func cancel()
}

@MainActor
public protocol OnboardingScheduler: AnyObject {
  var now: ContinuousClock.Instant { get }
  func schedule(at deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) -> OnboardingScheduledTask
}

@MainActor
public final class ContinuousOnboardingScheduler: OnboardingScheduler {
  public init() {}
  public var now: ContinuousClock.Instant { ContinuousClock.now }
  public func schedule(at deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) -> OnboardingScheduledTask {
    ScheduledTask(deadline: deadline, action: action)
  }

  private final class ScheduledTask: OnboardingScheduledTask {
    let task: Task<Void, Never>
    init(deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) {
      task = Task { @MainActor in
        do {
          try await ContinuousClock().sleep(until: deadline)
          guard !Task.isCancelled else { return }
          action()
        } catch {}
      }
    }
    func cancel() { task.cancel() }
  }
}

public enum OnboardingSetupIssue: Equatable {
  case previewRestoration, recoveryUnavailable
}

public enum OnboardingSyncRoute: Equatable {
  case setup, discovering, found
  case discoveryIssue(OnboardingDiscoveryResult)
  case setupIssue(OnboardingSetupIssue)
  case joining(PairingJoinState)
  case downloading, joined, savingFailed
}
