import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingReviewTests {
  func fixture() -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeStore, OnboardingFakeDiscovery, OnboardingFakeJoining) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    return (OnboardingModel(services: services, store: store, appName: "Solara"), services, store, discovery, joining)
  }

  func settle() async {
    for _ in 0..<30 { await Task.yield() }
  }

  func beginPairing(_ model: OnboardingModel, _ discovery: OnboardingFakeDiscovery) async {
    model.maybeStart()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "candidate", lastActivity: nil)]))
    model.pairWithAnotherMac()
    await settle()
  }

  @Test func completedTourRejectsSyncRouteAndPreservesCompletion() async {
    let (model, services, _, discovery, joining) = fixture()
    services.document = #"{"version":1,"completedAt":123}"#
    model.start(step: .source)
    model.discoverSync()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "candidate", lastActivity: nil)]))
    model.pairWithAnotherMac()
    await settle()
    services.committedOnboardingJoinToken = "installed"
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .setup)
    #expect(discovery.callbacks.isEmpty)
    #expect(services.joinedWrites == 0)
    #expect(OnboardingFixture.saved(services)["completedAt"] == 123)
  }

  @Test func replayedTourRejectsDiscoveryWithoutCompletionDocument() {
    let (model, _, _, discovery, _) = fixture()
    model.start(step: .source)
    model.discoverSync()
    #expect(model.syncRoute == .setup)
    #expect(discovery.callbacks.isEmpty)
  }

  @Test func approvedCancelAndRecoveryCannotDropInstalledCompletion() async {
    let (model, services, _, discovery, joining) = fixture()
    await beginPairing(model, discovery)
    joining.emit(.approved)
    model.cancelPairing()
    model.useRecoveryPhrase()
    model.continueSetup()
    model.go(.look)
    model.finish()
    await settle()
    #expect(model.syncRoute == .joining(.approved))
    #expect(model.syncTitle == "Finishing connection")
    #expect(joining.handles.first?.cancellations == 0)
    #expect(services.recoveryPhraseCalls == 0)
    services.committedOnboardingJoinToken = "durable-join"
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "durable-join")
    #expect(services.joinedWrites == 1)
  }

  @Test func documentOnlyJoinTokenCannotOverrideCompletedStartup() {
    let saved: JSONValue = ["completedAt": 123, "joinedCompletionToken": "document-only"]
    #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false) == .none)
  }

  @Test func documentOnlyJoinTokenCannotAdmitJoinedRoute() {
    let (model, services, _, discovery, _) = fixture()
    services.document = #"{"version":1,"startedAt":1,"step":"source","joinedCompletionToken":"untrusted-document"}"#
    model.maybeStart()
    #expect(model.syncRoute == .discovering)
    #expect(discovery.callbacks.count == 1)
    #expect(services.joinedWrites == 0)
  }

  @Test func installedWithoutDurableTokenNeverInventsCompletionIdentity() async {
    let (model, services, _, discovery, joining) = fixture()
    await beginPairing(model, discovery)
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .savingFailed)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == nil)
    #expect(services.joinedWrites == 0)
    services.committedOnboardingJoinToken = "durable-later"
    model.finishJoined()
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "durable-later")
  }

  @Test func recoveryPresentationFailureIsVisibleAndRetryable() async {
    let (model, services, _, discovery, _) = fixture()
    model.maybeStart()
    discovery.emit(.empty)
    services.recoveryAvailable = false
    model.useRecoveryPhrase()
    await settle()
    #expect(model.syncTitle == "Couldn't open recovery phrase entry.")
    services.recoveryAvailable = true
    model.useRecoveryPhrase()
    await settle()
    #expect(services.recoveryPhraseCalls == 1)
  }

  @Test func recoveryPreviewFailureIsVisibleAndRetryable() async {
    let (model, services, _, discovery, _) = fixture()
    model.maybeStart()
    discovery.emit(.empty)
    services.holdDrain = true
    model.useRecoveryPhrase()
    await settle()
    services.drainContinuation?.resume(throwing: CocoaError(.fileWriteUnknown))
    services.drainContinuation = nil
    await settle()
    #expect(model.syncTitle == "Couldn't restore your setup previews.")
    #expect(services.recoveryPhraseCalls == 0)
    services.holdDrain = false
    model.useRecoveryPhrase()
    await settle()
    #expect(services.recoveryPhraseCalls == 1)
  }

  @Test func previewReversionKeepsSettingsThatArrivedFromSync() {
    let (model, services, store, discovery, _) = fixture()
    model.maybeStart()
    discovery.emit(.empty)
    model.previewLive(["appearance": "dark", "tabLayout": "top"])
    model.previewColor(.green)
    store.settings = store.settings.updated(["appearance": "light"], fromSync: true)
    services.windowLayout["w1"] = "sidebar"
    services.colors["w1"] = .blue
    model.discoverSync()
    #expect(store.settings.string("appearance") == "light")
    #expect(services.windowLayout["w1"] == "sidebar")
    #expect(services.colors["w1"] == .blue)
  }

  @Test func pairingPreviewDrainFailureDoesNotBlameSyncFolder() async {
    let (model, services, _, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "candidate", lastActivity: nil)]))
    services.holdDrain = true
    model.pairWithAnotherMac()
    await settle()
    services.drainContinuation?.resume(throwing: CocoaError(.fileWriteUnknown))
    services.drainContinuation = nil
    await settle()
    #expect(model.syncRoute != .joining(.failed(.folderUnavailable)))
    #expect(model.syncTitle == "Couldn't restore your setup previews.")
    #expect(joining.cids.isEmpty)
  }
}
