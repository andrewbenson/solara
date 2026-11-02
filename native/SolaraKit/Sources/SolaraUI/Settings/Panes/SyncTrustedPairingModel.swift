import AppKit
import Observation

@MainActor
@Observable
public final class SyncTrustedPairingModel {
  public private(set) var phase: TrustedPhase = .idle
  public private(set) var indicator: TrustedIndicator = .none
  public private(set) var requests: [TrustedRequest] = []
  public private(set) var comparison: TrustedComparison?
  public private(set) var renderGeneration: UInt64 = 0
  public private(set) var actionGeneration: UInt64 = 0
  public private(set) var presentationGeneration: UInt64 = 0
  public private(set) var isPresented = false
  public private(set) var eligible = false
  public private(set) var arm: TrustedArm?
  public private(set) var matched = false
  public var requiresExplicitPresentation: Bool { arm != nil && !presentationAdmitted }
  public var canDismissUnexpected: Bool { markerVerified && isPresented && arm != nil }
  public var canAllow: Bool {
    eligible && markerVerified && foreground && presentationAdmitted && phase == .comparing && matched &&
      authorization != nil && comparison?.arm === arm && arm.map { now() < $0.deadline } == true
  }
  @ObservationIgnored public let service: any TrustedPairingService
  @ObservationIgnored private let now: () -> TimeInterval
  @ObservationIgnored private weak var window: NSWindow?
  @ObservationIgnored private weak var lastWindow: NSWindow?
  @ObservationIgnored private var surface: TrustedSurface?
  @ObservationIgnored private var subscription: TrustedSubscription?
  @ObservationIgnored private var observerGeneration: UInt64 = 0
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var markerVerified = false
  @ObservationIgnored private var foreground = false
  @ObservationIgnored private var presentationAdmitted = false
  @ObservationIgnored private var authorization: TrustedAuthorization?
  @ObservationIgnored private var consumed = Set<UUID>()
  @ObservationIgnored private var selected = false
  @ObservationIgnored private var delivery: TrustedPhase?
  @ObservationIgnored private var pendingSnapshot: TrustedSnapshot?
  @ObservationIgnored private var arming = false
  @ObservationIgnored private var expiry: Task<Void, Never>?

  public init(service: any TrustedPairingService, now: @escaping () -> TimeInterval = { TrustedPairingClock.now() }) {
    self.service = service
    self.now = now
    observe(on: nil)
  }

  private func observe(on surface: TrustedSurface?) {
    subscription?.cancel()
    observerGeneration &+= 1
    let generation = observerGeneration
    revision = 0
    subscription = service.observe(on: surface) { [weak self] snapshot in
      guard let self, generation == self.observerGeneration else { return }
      if self.arming { self.pendingSnapshot = snapshot; return }
      self.apply(snapshot)
    }
  }

  public func attach(to settingsWindow: NSWindow) {
    if window === settingsWindow, surface != nil { return }
    if surface != nil { teardown() }
    window = settingsWindow
    lastWindow = settingsWindow
    surface = service.attach(to: settingsWindow)
    observe(on: surface)
  }

  public func resumeObservation() {
    if let lastWindow { attach(to: lastWindow) }
  }

  public func connect(reviewing: TrustedRequest? = nil, options: TrustedArmOptions = TrustedArmOptions()) {
    guard eligible, arm == nil, let surface else { return }
    if let reviewing, !requests.contains(where: { $0 === reviewing }) { return }
    clearComparison()
    delivery = nil
    arming = true
    defer {
      arming = false
      if let snapshot = pendingSnapshot { pendingSnapshot = nil; apply(snapshot) }
    }
    do {
      arm = try service.arm(on: surface, reviewing: reviewing, options: options)
      selected = reviewing != nil
      presentationAdmitted = true
      phase = .preparing
      startExpiry()
    } catch TrustedPairingFailure.refused(let reason) {
      arm = nil
      phase = .ended(reason)
    } catch {
      arm = nil
      phase = .ended(.verificationFailed)
    }
  }

  public func captureSelection(_ request: TrustedRequest) -> () -> Void {
    let originalArm = arm
    let generation = observerGeneration
    let presentation = presentationGeneration
    return { [weak self, weak originalArm] in
      guard let self, let originalArm, self.arm === originalArm, self.observerGeneration == generation, self.presentationGeneration == presentation else { return }
      Task { [weak self, weak originalArm] in
        guard let self, let originalArm, self.arm === originalArm, self.observerGeneration == generation, self.presentationGeneration == presentation else { return }
        await self.select(request)
      }
    }
  }

  public func capturePresentation() -> () -> Void {
    let originalArm = arm
    let generation = observerGeneration
    let presentation = presentationGeneration
    return { [weak self, weak originalArm] in
      guard let self, let originalArm, self.arm === originalArm, self.observerGeneration == generation, self.presentationGeneration == presentation else { return }
      self.present()
    }
  }

  public func captureEnd(_ disposition: TrustedEnd, then next: (() -> Void)? = nil) -> () -> Void {
    let originalArm = arm
    let generation = observerGeneration
    let presentation = presentationGeneration
    return { [weak self, weak originalArm] in
      guard let self, let originalArm, self.arm === originalArm, self.observerGeneration == generation, self.presentationGeneration == presentation else { return }
      self.end(disposition)
      next?()
    }
  }

  public func captureSurfaceChange() -> (TrustedSurfaceEvent) -> Void {
    let originalArm = arm
    let generation = observerGeneration
    let presentation = presentationGeneration
    return { [weak self, weak originalArm] event in
      guard let self, let originalArm, self.arm === originalArm, self.observerGeneration == generation, self.presentationGeneration == presentation else { return }
      self.surfaceChanged(event)
    }
  }

  public func select(_ request: TrustedRequest) async {
    guard eligible, markerVerified, isPresented, presentationAdmitted, !selected,
          phase == .choosing, requests.contains(where: { $0 === request }),
          let arm, now() < arm.deadline, now() < request.firstObserved + 300 else { return }
    selected = true
    phase = .preparing
    do { try await service.select(request, in: arm) }
    catch { if self.arm === arm { end(.cancel); phase = .ended(.verificationFailed) } }
  }

  public func present() {
    guard eligible, markerVerified, let arm, let surface, now() < arm.deadline else { return }
    clearComparison()
    presentationAdmitted = true
    do { try service.present(arm, on: surface) }
    catch { presentationAdmitted = false }
  }

  public func setMatched(_ matched: Bool, comparison: TrustedComparison, render: UInt64) {
    guard self.comparison === comparison, render == renderGeneration, eligible, markerVerified,
          foreground, presentationAdmitted, phase == .comparing, let surface,
          let arm, now() < arm.deadline else { return }
    actionGeneration &+= 1
    authorization = service.acknowledge(comparison, matched: matched, on: surface)
    self.matched = matched && authorization != nil
  }

  public func captureToggle() -> (Bool) -> Void {
    let comparison = comparison
    let render = renderGeneration
    let action = actionGeneration
    return { [weak self, weak comparison] matched in
      guard let self, let comparison, action == self.actionGeneration else { return }
      self.setMatched(matched, comparison: comparison, render: render)
    }
  }

  public func captureAllow() -> () -> Void {
    let authorization = authorization
    let comparison = comparison
    let render = renderGeneration
    let action = actionGeneration
    return { [weak self, weak authorization, weak comparison] in
      guard let self, let authorization, let comparison, self.canAllow,
            self.authorization === authorization, self.comparison === comparison,
            self.renderGeneration == render, self.actionGeneration == action,
            let surface = self.surface else { return }
      self.phase = .authenticating
      self.matched = false
      self.authorization = nil
      Task { [weak self] in
        guard let self, self.phase == .authenticating, self.comparison === comparison,
              self.renderGeneration == render, self.actionGeneration == action,
              self.foreground, self.eligible, self.now() < comparison.arm.deadline else { return }
        do { try await self.service.allow(authorization, on: surface) }
        catch {
          guard self.arm === comparison.arm, self.renderGeneration == render else { return }
          self.end(.cancel)
          self.phase = .ended(.authorizationFailed)
        }
      }
    }
  }

  public func surfaceChanged(_ event: TrustedSurfaceEvent) {
    guard let surface else { return }
    presentationGeneration &+= 1
    clearComparison()
    foreground = false
    presentationAdmitted = false
    if event == .removed {
      if let arm { consumed.insert(arm.id) }
      arm = nil
      selected = false
      isPresented = false
      phase = delivery ?? .ended(.removed)
      expiry?.cancel()
    }
    service.surfaceChanged(surface, event: event)
  }

  public func end(_ disposition: TrustedEnd) {
    guard let surface else { return }
    if disposition == .unexpectedRequest, !markerVerified { return }
    let endedArm = arm
    if let endedArm { consumed.insert(endedArm.id) }
    clearComparison()
    arm = nil
    isPresented = false
    foreground = false
    presentationAdmitted = false
    selected = false
    phase = delivery ?? .ended(disposition == .deny ? .denied : disposition == .unexpectedRequest ? .unexpectedRequest : .cancelled)
    if disposition == .unexpectedRequest { indicator = .suppressed; markerVerified = false }
    expiry?.cancel()
    service.end(endedArm, on: surface, disposition: disposition)
  }

  public func teardown() {
    surfaceChanged(.removed)
    observerGeneration &+= 1
    subscription?.cancel()
    subscription = nil
    surface = nil
    window = nil
    requests = []
    eligible = false
    pendingSnapshot = nil
    expiry?.cancel()
    expiry = nil
  }

  private func clearComparison() {
    if let comparison, authorization != nil, let surface {
      _ = service.acknowledge(comparison, matched: false, on: surface)
    }
    comparison = nil
    authorization = nil
    matched = false
    renderGeneration &+= 1
    actionGeneration &+= 1
  }

  private func apply(_ snapshot: TrustedSnapshot) {
    guard snapshot.revision > revision else { return }
    revision = snapshot.revision
    eligible = snapshot.eligible
    markerVerified = snapshot.openMarkerVerified
    indicator = markerVerified ? snapshot.indicator : snapshot.indicator == .persistenceFailure ? .persistenceFailure : .suppressed
    requests = Array(snapshot.requests.prefix(8))
    guard let arm else {
      if case .ended = snapshot.phase, delivery == nil { phase = snapshot.phase }
      return
    }
    guard snapshot.arm === arm, !consumed.contains(arm.id), now() < arm.deadline,
          eligible, markerVerified else {
      clearComparison()
      isPresented = false
      if !eligible || now() >= arm.deadline { expire(arm) }
      return
    }
    if snapshot.phase == .sentUnconfirmed || snapshot.phase == .confirmed { delivery = snapshot.phase }
    if case .ended = snapshot.phase {
      clearComparison()
      consumed.insert(arm.id)
      self.arm = nil
      phase = delivery ?? snapshot.phase
      isPresented = false
      expiry?.cancel()
      return
    }
    guard presentationAdmitted, snapshot.foreground else {
      clearComparison()
      foreground = false
      presentationAdmitted = false
      return
    }
    foreground = true
    isPresented = true
    phase = snapshot.phase
    guard snapshot.phase == .comparing || snapshot.phase == .authenticating else {
      clearComparison()
      return
    }
    guard let incoming = snapshot.comparison else { clearComparison(); return }
    guard incoming.arm === arm, incoming.surface === surface,
          SyncPairingName.isValid(incoming.claimedName), Self.validCode(incoming.code) else {
      clearComparison()
      presentationAdmitted = false
      return
    }
    if let comparison, comparison !== incoming {
      clearComparison()
      presentationAdmitted = false
      return
    }
    comparison = incoming
  }

  private static func validCode(_ code: String) -> Bool {
    code.utf8.count == 6 && code.utf8.allSatisfy { Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8).contains($0) }
  }

  private func startExpiry() {
    expiry?.cancel()
    expiry = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, let arm = self.arm else { return }
        if self.now() >= arm.deadline { self.expire(arm); return }
      }
    }
  }

  private func expire(_ arm: TrustedArm) {
    guard self.arm === arm else { return }
    if let delivery {
      consumed.insert(arm.id)
      clearComparison()
      self.arm = nil
      phase = delivery
      isPresented = false
      foreground = false
      presentationAdmitted = false
      expiry?.cancel()
      return
    }
    end(.cancel)
    phase = .ended(.expired)
  }
}
