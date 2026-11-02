import AppKit
import Darwin
import Foundation

@MainActor
public protocol TrustedPairingService: AnyObject {
  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription
  func attach(to settingsWindow: NSWindow) -> TrustedSurface
  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm
  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws
  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws
  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent)
  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization?
  func toleratesSoftLoss(_ arm: TrustedArm) -> Bool
  func panelLive(_ arm: TrustedArm) -> Bool
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws
  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd)
}

@MainActor
public final class TrustedSubscription {
  private var cancellation: (() -> Void)?
  public init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
  public func cancel() { cancellation?(); cancellation = nil }
}

public class TrustedCapability: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  public var description: String { "<native pairing capability>" }
  public var debugDescription: String { description }
  fileprivate init() {}
}

public final class TrustedSurface: TrustedCapability, Identifiable {
  public let id = UUID()
  public override init() { super.init() }
}

public final class TrustedArm: TrustedCapability, Identifiable {
  public let id = UUID()
  public let deadline: TimeInterval
  public init(deadline: TimeInterval) { self.deadline = deadline; super.init() }
}

public final class TrustedRequest: TrustedCapability, Identifiable {
  public let id = UUID()
  public let chainSuffix: String
  public let requestSuffix: String
  public let sessionSuffix: String
  public let firstObserved: TimeInterval
  public init(chainSuffix: String, requestSuffix: String, sessionSuffix: String, firstObserved: TimeInterval) {
    self.chainSuffix = chainSuffix
    self.requestSuffix = requestSuffix
    self.sessionSuffix = sessionSuffix
    self.firstObserved = firstObserved
    super.init()
  }
}

public final class TrustedAuthorization: TrustedCapability {
  public override init() { super.init() }
}

public final class TrustedPresentation: TrustedCapability {
  public override init() { super.init() }
}

public final class TrustedComparison: TrustedCapability {
  public let arm: TrustedArm
  public let surface: TrustedSurface
  public let presentation: TrustedPresentation
  public let code: String
  public let claimedName: String
  public let nameWarning: Bool
  public init(arm: TrustedArm, surface: TrustedSurface, presentation: TrustedPresentation, code: String, claimedName: String, nameWarning: Bool) {
    self.arm = arm
    self.surface = surface
    self.presentation = presentation
    self.code = code
    self.claimedName = claimedName
    self.nameWarning = nameWarning
    super.init()
  }
}

public enum TrustedPairingFailure: Error { case refused(TrustedEndReason) }

public enum TrustedSurfaceEvent: Sendable { case foreground, visibilityChanged, unavailable, remounted, removed }
public enum TrustedEnd: Sendable { case deny, cancel, unexpectedRequest }
public enum TrustedIndicator: Sendable { case none, pending, overflow, suppressed, persistenceFailure }
public enum TrustedEndReason: Sendable {
  case denied, cancelled, unexpectedRequest, mismatch, verificationFailed, folderUnavailable, persistenceFailure
  case expired, authorizationFailed, noLoginPassword, invalidLocalName, rateLimited, removed, interrupted
}
public enum TrustedPhase: Equatable, Sendable {
  case idle, choosing, preparing, comparing, authenticating, sentUnconfirmed, confirmed
  case ended(TrustedEndReason)
}
public struct TrustedArmOptions: Sendable {
  public let localDisplayForm: String?
  public let confirmedLimitOverride: Bool
  public init(localDisplayForm: String? = nil, confirmedLimitOverride: Bool = false) {
    self.localDisplayForm = localDisplayForm
    self.confirmedLimitOverride = confirmedLimitOverride
  }
}

public struct TrustedSnapshot: CustomReflectable {
  public let revision: UInt64
  public let eligible: Bool
  public let openMarkerVerified: Bool
  public let indicator: TrustedIndicator
  public let requests: [TrustedRequest]
  public let arm: TrustedArm?
  public let phase: TrustedPhase
  public let foreground: Bool
  public let comparison: TrustedComparison?
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  public init(revision: UInt64, eligible: Bool, openMarkerVerified: Bool, indicator: TrustedIndicator = .none, requests: [TrustedRequest] = [], arm: TrustedArm? = nil, phase: TrustedPhase = .idle, foreground: Bool = false, comparison: TrustedComparison? = nil) {
    self.revision = revision
    self.eligible = eligible
    self.openMarkerVerified = openMarkerVerified
    self.indicator = indicator
    self.requests = requests
    self.arm = arm
    self.phase = phase
    self.foreground = foreground
    self.comparison = comparison
  }
}

@MainActor
public enum TrustedPairingRegistration {
  public static var service: (any TrustedPairingService)?
}

public enum TrustedPairingClock {
  public static func now() -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
  }
}
