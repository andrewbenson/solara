import AppKit
import Foundation
@testable import SolaraUI

@MainActor
final class TrustedPairingTestService: TrustedPairingService {
  let surface = TrustedSurface()
  var snapshot = TrustedSnapshot(revision: 1, eligible: true, openMarkerVerified: true)
  var observers: [UUID: (TrustedSurface?, @MainActor (TrustedSnapshot) -> Void)] = [:]
  var arms: [TrustedArm] = []
  var selections: [TrustedRequest] = []
  var presentations: [TrustedArm] = []
  var events: [TrustedSurfaceEvent] = []
  var acknowledgments: [Bool] = []
  var allowed: [TrustedAuthorization] = []
  var ends: [TrustedEnd] = []
  var canceledObservers = 0
  var clock: TimeInterval = 10
  var heldAllow: CheckedContinuation<Void, Never>?
  var holdAllow = false
  var authorization: TrustedAuthorization?
  var options: [TrustedArmOptions] = []

  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription {
    let id = UUID()
    observers[id] = (surface, receive)
    receive(snapshot)
    return TrustedSubscription { [weak self] in self?.observers[id] = nil; self?.canceledObservers += 1 }
  }
  func attach(to settingsWindow: NSWindow) -> TrustedSurface { surface }
  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm {
    let arm = TrustedArm(deadline: clock + 120)
    arms.append(arm)
    self.options.append(options)
    if let reviewing { selections.append(reviewing) }
    return arm
  }
  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws { selections.append(request) }
  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws { presentations.append(arm) }
  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) { events.append(event); authorization = nil }
  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? {
    acknowledgments.append(matched)
    authorization = matched ? TrustedAuthorization() : nil
    return authorization
  }
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws {
    allowed.append(authorization)
    if holdAllow { await withCheckedContinuation { heldAllow = $0 } }
  }
  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) { ends.append(disposition); authorization = nil }
  func publish(phase: TrustedPhase = .choosing, arm: TrustedArm? = nil, comparison: TrustedComparison? = nil, foreground: Bool = true, verified: Bool = true, eligible: Bool = true, indicator: TrustedIndicator = .none, requests: [TrustedRequest] = []) {
    snapshot = TrustedSnapshot(revision: snapshot.revision + 1, eligible: eligible, openMarkerVerified: verified, indicator: indicator, requests: requests, arm: arm, phase: phase, foreground: foreground, comparison: comparison)
    for (_, receive) in observers.values { receive(snapshot) }
  }
  func replay(_ snapshot: TrustedSnapshot) { for (_, receive) in observers.values { receive(snapshot) } }
  func request(_ suffix: String = "A") -> TrustedRequest { TrustedRequest(chainSuffix: "ABCD", requestSuffix: suffix, sessionSuffix: "EFGH", firstObserved: clock) }
  func ready(_ model: SyncTrustedPairingModel, name: String = "Studio Mac", code: String = "ABC234") -> TrustedComparison {
    let comparison = TrustedComparison(arm: arms.last!, surface: surface, presentation: TrustedPresentation(), code: code, claimedName: name, nameWarning: false)
    publish(phase: .comparing, arm: arms.last, comparison: comparison)
    return comparison
  }
}
