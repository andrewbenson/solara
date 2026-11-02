import AppKit
import Foundation
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncTrustedPairingModelTests {
  func setup() -> (TrustedPairingTestService, SyncTrustedPairingModel, NSWindow) {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    model.attach(to: window)
    return (service, model, window)
  }

  @Test func T01_T02_observationIsQuietAndCoalesced() {
    let (service, model, _) = setup()
    service.publish(indicator: .pending, requests: [service.request(), service.request("B")])
    #expect(model.indicator == .pending)
    #expect(!model.isPresented)
    #expect(model.comparison == nil)
    #expect(service.arms.isEmpty)
    service.publish(indicator: .overflow)
    #expect(model.indicator == .overflow)
    #expect(service.presentations.isEmpty)
  }

  @Test func T03_selectionCapturesExactEntryAndNeverLatest() async {
    let (service, model, _) = setup()
    let first = service.request()
    let second = service.request("B")
    service.publish(requests: [first])
    model.connect()
    service.publish(arm: service.arms.last, requests: [second, first])
    await model.select(first)
    #expect(service.selections.count == 1)
    #expect(service.selections.first === first)
    await model.select(second)
    #expect(service.selections.count == 1)
  }

  @Test func T03_disappearedDescriptorDoesNotRetarget() async {
    let (service, model, _) = setup()
    let first = service.request()
    service.publish(requests: [first])
    model.connect()
    service.publish(arm: service.arms.last, requests: [service.request("B")])
    await model.select(first)
    #expect(service.selections.isEmpty)
    #expect(model.isPresented)
  }

  @Test func T04_occupiedPhasesCannotRearmOrRenew() {
    for phase: TrustedPhase in [.choosing, .preparing, .comparing, .authenticating, .sentUnconfirmed] {
      let (service, model, _) = setup()
      model.connect()
      #expect(service.arms.count == 1)
      guard let arm = service.arms.first else { continue }
      service.publish(phase: phase, arm: arm)
      service.clock += 30
      model.connect()
      #expect(service.arms.count == 1)
      #expect(arm.deadline == 130)
    }
  }

  @Test func T05_unexpectedDismissalEndsEveryLivePhase() {
    for phase: TrustedPhase in [.choosing, .preparing, .comparing, .authenticating, .sentUnconfirmed] {
      let (service, model, _) = setup()
      model.connect()
      service.publish(phase: phase, arm: service.arms.last)
      #expect(model.canDismissUnexpected)
      model.end(.unexpectedRequest)
      #expect(service.ends == [.unexpectedRequest])
      #expect(model.comparison == nil)
      #expect(!model.isPresented)
    }
  }

  @Test func T06_invalidStaleAndReplacementReadinessRejected() {
    let (service, model, _) = setup()
    model.connect()
    guard !service.arms.isEmpty else { Issue.record("native arm absent"); return }
    let first = service.ready(model)
    #expect(model.comparison === first)
    let replacement = TrustedComparison(arm: first.arm, surface: service.surface, presentation: TrustedPresentation(), code: "XYZ789", claimedName: "replacement", nameWarning: false)
    service.publish(phase: .comparing, arm: first.arm, comparison: replacement)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
  }

  @Test func T06_foreignArmSurfaceInvalidNameAndCodeRejected() {
    for name in ["", "a\nname", "e\u{301}", String(repeating: "a", count: 65), "\u{202e}abc"] {
      let (service, model, _) = setup()
      model.connect()
      guard let arm = service.arms.last else { Issue.record("native arm absent"); continue }
      let comparison = TrustedComparison(arm: arm, surface: service.surface, presentation: TrustedPresentation(), code: "ABC234", claimedName: name, nameWarning: false)
      service.publish(phase: .comparing, arm: arm, comparison: comparison)
      #expect(model.comparison == nil)
    }
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    for pair in [(TrustedArm(deadline: 130), service.surface, "ABC234"), (arm, TrustedSurface(), "ABC234"), (arm, service.surface, "BAD") ] {
      let c = TrustedComparison(arm: pair.0, surface: pair.1, presentation: TrustedPresentation(), code: pair.2, claimedName: "Mac", nameWarning: false)
      service.publish(phase: .comparing, arm: arm, comparison: c)
      #expect(model.comparison == nil)
    }
  }

  @Test func T09_uncheckedCheckedUncheckAndRecheckRejectOldTargets() async {
    let (service, model, _) = setup()
    model.connect()
    guard !service.arms.isEmpty else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    model.captureAllow()()
    await Task.yield()
    #expect(service.allowed.isEmpty)
    let oldToggle = model.captureToggle()
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    #expect(model.canAllow)
    let oldAllow = model.captureAllow()
    model.setMatched(false, comparison: c, render: model.renderGeneration)
    #expect(!model.canAllow)
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    #expect(model.canAllow)
    oldAllow()
    oldToggle(false)
    await Task.yield()
    #expect(service.allowed.isEmpty)
    #expect(model.canAllow)
    model.captureAllow()()
    model.captureAllow()()
    await Task.yield()
    #expect(service.allowed.count == 1)
  }

  @Test func T10_T11_endClearsBeforeCleanupAndNeverAuthorizes() {
    let (service, model, _) = setup()
    model.connect()
    guard !service.arms.isEmpty else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    model.end(.deny)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    #expect(service.ends == [.deny])
    #expect(service.allowed.isEmpty)
    service.publish(phase: .comparing, arm: c.arm, comparison: c)
    #expect(model.comparison == nil)
    #expect(!model.isPresented)
  }

  @Test func T12_sentIsNotConnectedAndCannotAllow() {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    service.publish(phase: .sentUnconfirmed, arm: arm)
    #expect(model.phase == .sentUnconfirmed)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    #expect(SyncPairingText.sent == "Approval sent; installation not confirmed")
  }

  @Test func T13_redactedCapabilityReflectionAndCopy() {
    let (service, model, _) = setup()
    model.connect()
    guard !service.arms.isEmpty else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    #expect(!String(reflecting: c).contains(c.code))
    #expect(!String(reflecting: c).contains(c.claimedName))
    #expect(Mirror(reflecting: service.snapshot).children.isEmpty)
    #expect(SyncText.offNote == "Pairing shows this Mac’s name to the Mac you’re pairing with before you compare codes, even if you cancel. Anyone who can open your sync folder could start a pairing. Pairing files show when a pairing happened and how it ended, but none of your synced data.")
    #expect(SyncPairingText.claimQualification == "Matching codes authenticate only this connection’s claim to this name. They do not verify the Mac’s system name, hardware, legal identity or Apple account ownership.")
    #expect(SyncPairingText.authority == "Allow only if all six characters match on the Mac you’re connecting. This grants ongoing access to everything available with your recovery phrase, including synced passwords.")
  }

  @Test func T15_T16_repairAndOverrideOnlyExplicitNewArm() {
    let (service, model, _) = setup()
    service.publish(phase: .ended(.invalidLocalName))
    #expect(service.arms.isEmpty)
    model.connect(options: TrustedArmOptions(localDisplayForm: "Studio Mac"))
    #expect(service.options.last?.localDisplayForm == "Studio Mac")
    model.end(.cancel)
    service.publish(phase: .ended(.rateLimited))
    #expect(service.arms.count == 1)
    model.connect(options: TrustedArmOptions(confirmedLimitOverride: true))
    #expect(service.options.last?.confirmedLimitOverride == true)
  }

  @Test func V01_delayedReadyUpdatesSameSurfaceWithoutPresentCall() {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    service.publish(phase: .preparing, arm: arm)
    #expect(model.isPresented)
    let c = service.ready(model)
    #expect(model.comparison === c)
    #expect(service.presentations.isEmpty)
    #expect(arm.deadline == 130)
  }

  @Test func V02_V03_hiddenRemoteReadyAndActivationCannotRestore() {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    let old = model.captureAllow()
    model.surfaceChanged(.visibilityChanged)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    service.publish(phase: .comparing, arm: arm, comparison: c, foreground: false)
    service.publish(phase: .comparing, arm: arm, comparison: c, foreground: true)
    #expect(model.comparison == nil)
    old()
    #expect(service.allowed.isEmpty)
    #expect(service.presentations.isEmpty)
  }

  @Test func V04_explicitPresentRetainsOriginalArmAndClearsCheck() {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    _ = service.ready(model)
    model.surfaceChanged(.visibilityChanged)
    model.present()
    #expect(service.presentations.count == 1)
    #expect(service.presentations.first === arm)
    #expect(service.arms.count == 1)
    #expect(!model.matched)
    #expect(arm.deadline == 130)
  }

  @Test func V05_V06_remountOrRemovalInvalidatesQueuedEvents() {
    for event: TrustedSurfaceEvent in [.remounted, .removed] {
      let (service, model, _) = setup()
      model.connect()
      guard !service.arms.isEmpty else { Issue.record("native arm absent"); continue }
      let c = service.ready(model)
      model.setMatched(true, comparison: c, render: model.renderGeneration)
      let toggle = model.captureToggle()
      let allow = model.captureAllow()
      let oldSnapshot = service.snapshot
      model.surfaceChanged(event)
      toggle(true)
      allow()
      service.replay(oldSnapshot)
      #expect(model.comparison == nil)
      #expect(!model.canAllow)
      if event == .removed { #expect(model.arm == nil) }
      else { #expect(model.arm === c.arm) }
    }
  }

  @Test func V07_ineligibleAndV08_equalDeadlineCannotAllowOrPresent() {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    service.clock = arm.deadline
    #expect(!model.canAllow)
    model.present()
    model.captureAllow()()
    #expect(service.presentations.isEmpty)
    #expect(service.allowed.isEmpty)
    service.publish(phase: .comparing, arm: arm, comparison: c, eligible: false)
    #expect(model.comparison == nil)
    #expect(!model.isPresented)
  }

  @Test func V09_pendingAuthenticationCannotBeReactivatedByRemoteState() async {
    let (service, model, _) = setup()
    service.holdAllow = true
    model.connect()
    guard let arm = service.arms.last else { Issue.record("native arm absent"); return }
    let c = service.ready(model)
    model.setMatched(true, comparison: c, render: model.renderGeneration)
    model.captureAllow()()
    await Task.yield()
    #expect(service.allowed.count == 1)
    model.surfaceChanged(.unavailable)
    service.publish(phase: .authenticating, arm: arm, comparison: c)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    service.heldAllow?.resume()
    service.heldAllow = nil
  }
  @Test func pendingAuthenticationHideEndsExchangeAndLateSuccessCannotReviveIt() async throws {
    let (service, model, window) = setup()
    defer { _ = window.windowNumber }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    let oldAllow = model.captureAllow()
    oldAllow()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    #expect(service.heldAllow != nil)
    #expect(model.phase == .authenticating)
    service.publish(phase: .comparing, arm: arm, comparison: comparison)
    #expect(model.phase == .authenticating)
    model.surfaceChanged(.unavailable)
    if case .ended(let reason) = model.phase {
      #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
    } else { Issue.record("interrupted exchange did not end") }
    #expect(model.arm == nil)
    #expect(model.comparison == nil)
    #expect(!model.isPresented)
    #expect(!model.canAllow)
    #expect(service.ends == [.cancel])
    service.heldAllow?.resume()
    service.heldAllow = nil
    service.publish(phase: .sentUnconfirmed, arm: arm)
    oldAllow()
    await Task.yield()
    if case .ended(let reason) = model.phase {
      #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
    } else { Issue.record("interrupted exchange did not end") }
    #expect(service.allowed.count == 1)
    model.surfaceChanged(.removed)
    model.connect()
    let replacement = try #require(model.arm)
    #expect(replacement !== arm)
    #expect(service.arms.count == 2)
    let next = service.ready(model)
    service.publish(phase: .sentUnconfirmed, arm: arm)
    #expect(model.phase == .comparing)
    #expect(model.comparison === next)
    #expect(model.isPresented)
    service.publish(phase: .comparing, arm: replacement, comparison: next)
    #expect(model.comparison === next)
    #expect(service.allowed.count == 1)
    model.teardown()
  }

  @Test func queuedAuthenticationHideNeverRequestsAllow() async throws {
    let (service, model, _) = setup()
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    model.surfaceChanged(.unavailable)
    service.publish(phase: .sentUnconfirmed, arm: arm)
    await Task.yield()
    if case .ended(let reason) = model.phase {
      #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
    } else { Issue.record("interrupted exchange did not end") }
    #expect(model.arm == nil)
    #expect(service.allowed.isEmpty)
    #expect(service.ends == [.cancel])
    model.connect()
    #expect(service.arms.count == 2)
    model.teardown()
  }

  @Test func surfaceInterruptionUsesLocalRetryCopyOnlyWhenItEndsALiveArm() throws {
    for phase: TrustedPhase in [.choosing, .preparing, .comparing, .authenticating] {
      for event: TrustedSurfaceEvent in [.visibilityChanged, .unavailable, .remounted, .removed] {
        let (service, model, window) = setup()
        defer { _ = window.windowNumber }
        model.connect()
        let arm = try #require(model.arm)
        let comparison = service.ready(model)
        service.publish(phase: phase, arm: arm, comparison: comparison)
        model.surfaceChanged(event)
        if event == .removed || phase == .authenticating {
          #expect(model.arm == nil)
          if case .ended(let reason) = model.phase {
            #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
          } else { Issue.record("interrupted exchange did not end") }
          service.publish(phase: .ended(.cancelled))
          if case .ended(let reason) = model.phase {
            #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
          } else { Issue.record("cleanup replaced interruption state") }
        } else {
          #expect(model.arm === arm)
          #expect(model.phase == phase)
        }
        model.teardown()
      }
    }
  }

  @Test func unrelatedEndReasonsKeepTheirExistingCopy() {
    let cases: [(TrustedEndReason, String)] = [
      (.denied, "This request ended. Start again on the other Mac."),
      (.cancelled, "This request ended. Start again on the other Mac."),
      (.unexpectedRequest, "This request ended. Start again on the other Mac."),
      (.expired, "This request ended. Start again on the other Mac."),
      (.removed, "This request ended. Start again on the other Mac."),
      (.mismatch, "The codes don't match. Nothing was connected."),
      (.verificationFailed, "This connection couldn't be verified. Nothing was connected."),
      (.folderUnavailable, "The sync folder isn't available."),
      (.persistenceFailure, "Couldn't finish saving sync on this Mac."),
      (.authorizationFailed, "Couldn’t authorize this connection. Use Touch ID or this Mac’s login password and start again."),
      (.noLoginPassword, "Set a login password in System Settings › Users & Groups, then start this connection again."),
      (.rateLimited, "Too many pairing requests. Try again or use your recovery phrase."),
      (.invalidLocalName, "Enter a display form of this Mac’s real name to start a new connection.")
    ]
    for (reason, message) in cases {
      let (service, model, window) = setup()
      defer { _ = window.windowNumber }
      service.publish(phase: .ended(reason))
      #expect(model.phase == .ended(reason))
      #expect(SyncPairingText.ended(reason) == message)
      model.surfaceChanged(.removed)
      #expect(model.phase == .ended(reason))
    }
  }

  @Test func T15_fixedTerminalReasonProjectsWithoutDisplayOrArm() {
    let (service, model, _) = setup()
    service.publish(phase: .ended(.invalidLocalName))
    #expect(model.phase == .ended(.invalidLocalName))
    #expect(model.comparison == nil)
    #expect(!model.isPresented)
    #expect(service.arms.isEmpty)
  }

  @Test func T14_recoveryNavigationInvalidatesBeforeReadingAnyWords() {
    let service = TrustedPairingTestService()
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    let pane = SyncPaneModel(services: services, pairingService: service)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    guard let model = pane.pairing else { Issue.record("pairing child missing"); return }
    model.attach(to: window)
    model.connect()
    guard let arm = service.arms.last else { Issue.record("arm missing"); return }
    _ = service.ready(model)
    pane.sheet = .trustedPairing(surfaceID: arm.id)
    pane.sheet = .connectDevice
    #expect(model.arm == nil)
    #expect(model.comparison == nil)
    #expect(service.events.last == .removed)
    #expect(services.calls.isEmpty)
  }

  @Test func T09_queuedAllowAfterHideNeverEntersService() async {
    let (service, model, _) = setup()
    model.connect()
    guard !service.arms.isEmpty else { Issue.record("arm missing"); return }
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    model.surfaceChanged(.unavailable)
    await Task.yield()
    #expect(service.allowed.isEmpty)
  }

  @Test func T06_codeAlphabetMatchesLandedCore() {
    for (code, valid) in [("01ABCD", true), ("LUABCD", false), ("VWXYZ9", true), ("IOABCD", false)] {
      let (service, model, _) = setup()
      model.connect()
      guard !service.arms.isEmpty else { Issue.record("arm missing"); return }
      let comparison = service.ready(model, code: code)
      #expect((model.comparison === comparison) == valid)
    }
  }

  @Test func T12_expiryAfterReleaseKeepsUnconfirmedDeliveryStatus() async throws {
    let (service, model, _) = setup()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("arm missing"); return }
    service.publish(phase: .sentUnconfirmed, arm: arm)
    service.clock = arm.deadline
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.phase == .sentUnconfirmed)
    #expect(service.ends.isEmpty)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    service.publish(phase: .ended(.expired))
    #expect(model.phase == .sentUnconfirmed)
  }

  @Test func T03_T11_oldChooserPresentationEndAndSurfaceCallbacksCannotTargetNewArm() async {
    for queueSelectionBeforeEnd in [false, true] {
      let (service, model, _) = setup()
      let request = service.request()
      service.publish(requests: [request])
      model.connect()
      service.publish(arm: service.arms.last, requests: [request])
      let select = model.captureSelection(request)
      let present = model.capturePresentation()
      let end = model.captureEnd(.deny)
      let removed = model.captureSurfaceChange()
      if queueSelectionBeforeEnd { select() }
      model.end(.cancel)
      model.connect()
      guard let replacement = service.arms.last else { Issue.record("replacement arm missing"); return }
      service.publish(arm: replacement, requests: [request])
      if !queueSelectionBeforeEnd { select() }
      present()
      end()
      removed(.removed)
      for _ in 0..<30 { await Task.yield() }
      #expect(service.selections.isEmpty)
      #expect(service.presentations.isEmpty)
      #expect(service.ends.count == 1)
      #expect(model.arm === replacement)
    }
  }

  @Test func T03_oldChooserTargetCannotSelectAfterRemountAndFreshPresentation() async {
    let (service, model, _) = setup()
    let request = service.request()
    model.connect()
    guard let arm = service.arms.last else { Issue.record("arm missing"); return }
    service.publish(arm: arm, requests: [request])
    let oldSelect = model.captureSelection(request)
    model.surfaceChanged(.remounted)
    model.present()
    service.publish(arm: arm, requests: [request])
    oldSelect()
    for _ in 0..<30 { await Task.yield() }
    #expect(service.selections.isEmpty)
  }

}
