import Foundation
public final class PairingNativeArm { public let deadline: Double = .greatestFiniteMagnitude }
public final class PairingNativeRequest { public let chainSuffix = "CHAIN1"; public let requestSuffix = "REQ001"; public let sessionSuffix = "SES001"; public let firstObserved: Double = 0 }
public final class PairingNativeComparison { public let code = "123456"; public let claimedName = "Other Mac" }
public struct PairingNativeTrustedSnapshot { public let eligible = true; public let markerVerified = true; public let suppressed = false; public var requests: [PairingNativeRequest] = []; public var phase: String; public var comparison: PairingNativeComparison? }
public final class PairingServices {
  public init() {}
  public static var shared = PairingServices()
  public var committedOnboardingJoinToken: String? = nil
  public var phase = "choosing"
  public var live = false
  public var hides = 0
  public var allows = 0
  public var validate: ((@escaping (Bool) -> Void) -> Void)?
  public var foregroundAtReply: Bool?
  private var foregroundObserved = false
  private var observingReply: ((@escaping (Bool) -> Void) -> Void)?
  public func reply() {
    live = false
    observingReply? { self.foregroundAtReply = $0; self.foregroundObserved = $0 }
  }
  public func toleratesSoftLoss(_ arm: PairingNativeArm, foreground: Bool) -> Bool {
    if live { return true }
    guard foregroundAtReply != nil else { return false }
    if foreground { foregroundObserved = true; return true }
    return !foregroundObserved
  }
  private let comparisonValue = PairingNativeComparison()
  public func arm(override: Bool) throws -> PairingNativeArm { PairingNativeArm() }
  public func select(_ request: PairingNativeRequest, arm: PairingNativeArm) throws {}
  public func present(_ arm: PairingNativeArm) throws { phase = "comparing" }
  public func hide(_ arm: PairingNativeArm) { hides += 1; live = false; if phase != "sentUnconfirmed" { phase = "idle" } }
  public func end(_ arm: PairingNativeArm?, unexpected: Bool = false) { phase = "idle"; live = false }
  public func acknowledge(_ comparison: PairingNativeComparison) throws {}
  public func allow(_ arm: PairingNativeArm, observingSurfaceAtReply: @escaping (@escaping (Bool) -> Void) -> Void, validatingSurface: @escaping (@escaping (Bool) -> Void) -> Void) throws { allows += 1; observingReply = observingSurfaceAtReply; validate = validatingSurface; live = true }
  public func panelLive(_ arm: PairingNativeArm) -> Bool { live }
  public func trustedSnapshot(_ arm: PairingNativeArm?) -> PairingNativeTrustedSnapshot { .init(phase: phase, comparison: phase == "comparing" ? comparisonValue : nil) }
}
