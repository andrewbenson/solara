import AppKit
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncPairingNavigationTests {
  @Test func navigationBarrierRunsBeforePlaceMutationForEveryEntry() {
    let navigation = SettingsNavigation(place: SettingsPlace(pane: .sync))
    var transitions: [SettingsPlace] = []
    navigation.willNavigate = { old, next in
      #expect(navigation.place == old)
      transitions.append(next)
    }
    navigation.go(.general)
    navigation.goBack()
    navigation.goForward()
    navigation.replace(profileId: "some-profile", detail: "search-result")
    #expect(transitions.count == 4)
  }

  @Test func noRegisteredCoordinatorLeavesExistingConnectAndRecoveryUntouched() async {
    TrustedPairingRegistration.service = nil
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    let pane = SyncPaneModel(services: services)
    await pane.prepare(SettingsPlace(pane: .sync))
    #expect(pane.pairing == nil)
    pane.sheet = .connectDevice
    #expect(pane.sheet == .connectDevice)
    #expect(!services.calls.contains { $0.contains("recovery") || $0.contains("QRCode") })
  }
  @Test func V05_cachedWindowReopenReattachesWithoutArming() {
    let service = TrustedPairingTestService()
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    let pane = SyncPaneModel(services: services, pairingService: service)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    pane.pairing?.attach(to: window)
    pane.pairingSurfaceRemoved()
    #expect(service.observers.isEmpty)
    pane.pairingSurfaceAvailable(to: window)
    #expect(service.observers.count == 1)
    #expect(pane.pairing?.eligible == true)
    #expect(service.arms.isEmpty)
    #expect(service.presentations.isEmpty)
  }

  @Test func stoppedAuthenticationSheetDismissalAllowsImmediateRetry() throws {
    let service = TrustedPairingTestService()
    service.clock = TrustedPairingClock.now()
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    services.pairingInvalidated = { _ in service.publish(verified: false, eligible: false) }
    let pane = SyncPaneModel(services: services, pairingService: service)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    let model = try #require(pane.pairing)
    model.attach(to: window)
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    service.publish(phase: .authenticating, arm: arm, comparison: comparison)
    pane.sheet = .trustedPairing(surfaceID: arm.id)
    model.surfaceChanged(.visibilityChanged)
    #expect(model.arm == nil)
    pane.sheet = nil
    if case .ended(let reason) = model.phase {
      #expect(SyncPairingText.ended(reason) == "Pairing stopped. Try again.")
    } else { Issue.record("interrupted exchange did not end") }
    pane.connectAnotherMac()
    #expect(service.arms.count == 2)
    #expect(model.arm !== arm)
    #expect(model.eligible)
    #expect(service.allowed.isEmpty)
    #expect(service.ends == [.cancel])
    model.teardown()
  }

  @Test func stoppedAuthenticationSheetReplacementDoesNotRemoveNewArm() throws {
    let service = TrustedPairingTestService()
    service.clock = TrustedPairingClock.now()
    let services = FakeSyncServices(state: SyncState(status: .updated, enabled: true, folder: "/fixture"))
    services.pairingInvalidated = { _ in service.publish(verified: false, eligible: false) }
    let pane = SyncPaneModel(services: services, pairingService: service)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    let model = try #require(pane.pairing)
    model.attach(to: window)
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    service.publish(phase: .authenticating, arm: arm, comparison: comparison)
    pane.sheet = .trustedPairing(surfaceID: arm.id)
    model.surfaceChanged(.visibilityChanged)
    model.connect()
    let replacement = try #require(model.arm)
    service.publish(arm: replacement)
    pane.showPairingIfAdmitted()
    #expect(pane.sheet == .trustedPairing(surfaceID: replacement.id))
    #expect(model.arm === replacement)
    #expect(model.phase == .choosing)
    #expect(model.eligible)
    #expect(model.isPresented)
    #expect(service.allowed.isEmpty)
    #expect(service.ends == [.cancel])
    model.teardown()
  }

}
