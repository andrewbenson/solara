import AppKit
import Foundation
import SolaraSyncAdapter
import SolaraUI

@MainActor
final class PairingAdapter: TrustedPairingService {
  static let shared = PairingAdapter()
  private let owner = PairingServices.shared
  private final class Surface {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
  }
  private var surfaces: [UUID: Surface] = [:]
  private var observers: [UUID: (TrustedSurface?, @MainActor (TrustedSnapshot) -> Void)] = [:]
  private var requests: [ObjectIdentifier: TrustedRequest] = [:]
  private var nativeRequests: [UUID: PairingNativeRequest] = [:]
  private var arm: TrustedArm?
  private var nativeArm: PairingNativeArm?
  private var armSurface: TrustedSurface?
  private var nativeComparison: PairingNativeComparison?
  private var comparison: TrustedComparison?
  private var authorizations: [ObjectIdentifier: (TrustedArm, TrustedComparison)] = [:]
  private var presentation: TrustedPresentation?
  private var pendingReview: (TrustedRequest, PairingNativeRequest, TrustedArm)?
  private var timer: Timer?
  private var revision: UInt64 = 0

  static func install() {
    TrustedPairingRegistration.service = shared
    OnboardingPairingServices.joining = { folder in
      OnboardingPairingBridge(PairingJoiningAdapter(folder: folder))
    }
    OnboardingPairingServices.committedJoinToken = { PairingServices.shared.committedOnboardingJoinToken }
  }

  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription {
    let id = UUID()
    observers[id] = (surface, receive)
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
    }
    publish()
    return TrustedSubscription { [weak self] in
      self?.observers.removeValue(forKey: id)
      if self?.observers.isEmpty == true { self?.timer?.invalidate(); self?.timer = nil }
    }
  }

  func attach(to settingsWindow: NSWindow) -> TrustedSurface {
    let surface = TrustedSurface()
    surfaces[surface.id] = Surface(settingsWindow)
    return surface
  }

  private func foreground(_ surface: TrustedSurface) -> Bool {
    guard let window = surfaces[surface.id]?.window else { return false }
    let key = NSApp.keyWindow
    let sameFamily = key === window || key?.sheetParent === window || window.attachedSheet === key && key != nil
    return window.isVisible && window.occlusionState.contains(.visible) && sameFamily && !window.isMiniaturized && NSApp.isActive
  }

  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm {
    guard foreground(surface), arm == nil else { throw TrustedPairingFailure.refused(.removed) }
    let review: PairingNativeRequest?
    if let reviewing {
      guard let mapped = nativeRequests[reviewing.id], requests[ObjectIdentifier(mapped)] === reviewing else { throw TrustedPairingFailure.refused(.verificationFailed) }
      review = mapped
    } else { review = nil }
    do {
      let native = try owner.arm(override: options.confirmedLimitOverride)
      let made = TrustedArm(deadline: native.deadline)
      nativeArm = native
      arm = made
      armSurface = surface
      presentation = TrustedPresentation()
      if let reviewing, let review { pendingReview = (reviewing, review, made) }
      publish()
      return made
    } catch { throw TrustedPairingFailure.refused(.verificationFailed) }
  }

  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws {
    guard self.arm === arm, let nativeArm, let surface = armSurface, foreground(surface), let native = nativeRequests[request.id] else { throw TrustedPairingFailure.refused(.removed) }
    do { try owner.select(native, arm: nativeArm) }
    catch { throw TrustedPairingFailure.refused(.verificationFailed) }
    publish()
  }

  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws {
    guard self.arm === arm, armSurface === surface, foreground(surface), let nativeArm else { throw TrustedPairingFailure.refused(.removed) }
    do { try owner.present(nativeArm) }
    catch { throw TrustedPairingFailure.refused(.verificationFailed) }
    presentation = TrustedPresentation()
    comparison = nil
    nativeComparison = nil
    authorizations.removeAll()
    publish()
  }

  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) {
    guard armSurface === surface else { if event == .removed { surfaces.removeValue(forKey: surface.id) }; return }
    if let nativeArm { owner.hide(nativeArm) }
    presentation = nil
    comparison = nil
    nativeComparison = nil
    authorizations.removeAll()
    if event == .removed {
      owner.end(nativeArm)
      arm = nil
      nativeArm = nil
      armSurface = nil
      surfaces.removeValue(forKey: surface.id)
    }
    publish()
  }

  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? {
    guard matched, self.comparison === comparison, armSurface === surface, foreground(surface), let nativeComparison, let arm, presentation != nil else { return nil }
    do { try owner.acknowledge(nativeComparison) }
    catch { return nil }
    let authorization = TrustedAuthorization()
    authorizations[ObjectIdentifier(authorization)] = (arm, comparison)
    return authorization
  }

  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws {
    guard let binding = authorizations.removeValue(forKey: ObjectIdentifier(authorization)), binding.0 === arm, binding.1 === comparison, armSurface === surface, foreground(surface), let nativeArm else { throw TrustedPairingFailure.refused(.removed) }
    do { try owner.allow(nativeArm) }
    catch { throw TrustedPairingFailure.refused(.authorizationFailed) }
    publish()
  }

  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) {
    if disposition == .unexpectedRequest, arm == nil, self.arm == nil {
      guard foreground(surface), owner.trustedSnapshot(nil).markerVerified else { return }
      owner.end(nil, unexpected: true)
      publish()
      return
    }
    guard armSurface === surface, arm == nil || self.arm === arm else { return }
    pendingReview = nil
    owner.end(nativeArm, unexpected: disposition == .unexpectedRequest)
    self.arm = nil
    nativeArm = nil
    armSurface = nil
    presentation = nil
    comparison = nil
    nativeComparison = nil
    authorizations.removeAll()
    publish()
  }

  private func publish() {
    revision &+= 1
    let native = owner.trustedSnapshot(nativeArm)
    let currentRequests = native.requests.map { request -> TrustedRequest in
      let id = ObjectIdentifier(request)
      if let existing = requests[id] { return existing }
      let made = TrustedRequest(chainSuffix: request.chainSuffix, requestSuffix: request.requestSuffix, sessionSuffix: request.sessionSuffix, firstObserved: request.firstObserved)
      requests[id] = made
      nativeRequests[made.id] = request
      return made
    }
    if let pendingReview, pendingReview.2 === arm, let nativeArm, currentRequests.contains(where: { $0 === pendingReview.0 }) {
      self.pendingReview = nil
      do { try owner.select(pendingReview.1, arm: nativeArm) }
      catch { owner.end(nativeArm) }
    }
    var phase: TrustedPhase
    switch native.phase {
    case "choosing": phase = .choosing
    case "comparing": phase = .comparing
    case "authenticating": phase = .authenticating
    case "sentUnconfirmed": phase = .sentUnconfirmed
    case "confirmed": phase = .confirmed
    case "preparing": phase = .preparing
    default: phase = arm == nil ? .idle : .ended(.cancelled)
    }
    if !native.eligible { phase = arm == nil ? .idle : .ended(.folderUnavailable) }
    if phase == .comparing, let next = native.comparison, let arm, let surface = armSurface, let presentation, foreground(surface) {
      if comparison?.code != next.code || comparison?.claimedName != next.claimedName {
        nativeComparison = next
        comparison = TrustedComparison(arm: arm, surface: surface, presentation: presentation, code: next.code, claimedName: next.claimedName, nameWarning: true)
        authorizations.removeAll()
      }
    } else {
      comparison = nil
      nativeComparison = nil
      authorizations.removeAll()
    }
    for (_, entry) in observers {
      let active = entry.0.map(foreground) == true
      let admitted = entry.0 === armSurface && active && presentation != nil
      entry.1(TrustedSnapshot(revision: revision, eligible: native.eligible, openMarkerVerified: native.markerVerified, indicator: native.suppressed ? .suppressed : currentRequests.isEmpty ? .none : .pending, requests: currentRequests, arm: admitted ? arm : nil, phase: admitted ? phase : .idle, foreground: active, comparison: admitted ? comparison : nil))
    }
  }
}
