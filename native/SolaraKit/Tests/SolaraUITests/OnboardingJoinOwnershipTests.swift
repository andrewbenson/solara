import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingJoinOwnershipTests {
  let candidate = OnboardingDiscoveryCandidate(cid: "first", lastActivity: Date(timeIntervalSince1970: 10))

  func fixture() -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeDiscovery, OnboardingFakeJoining) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    joining.onInstalled = { services.committedOnboardingJoinToken = "installed-token" }
    let model = OnboardingModel(services: services, store: store, appName: "Solara", scheduler: OnboardingFakeScheduler())
    return (model, services, discovery, joining)
  }

  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  @Test func recoveryKeepsAnExistingCompletionTime() async {
    let (model, services, _, _) = fixture()
    services.document = #"{"version":1,"startedAt":1,"completedAt":100}"#
    services.committedOnboardingJoinToken = "committed"
    model.maybeStart()
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == .string("committed"))
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(100))
    model.finishJoined()
    await settle()
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(100))
  }

  @Test func installedAfterHandOverAndModelReleaseIsStillRecorded() async {
    var (model, services, discovery, joining): (OnboardingModel?, OnboardingFakeServices, OnboardingFakeDiscovery, OnboardingFakeJoining) = fixture()
    model?.maybeStart()
    discovery.emit(.found([candidate]))
    model?.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    #expect(model?.syncRoute == .joining(.approved))
    joining.committedResult = true
    model?.leaveSetup()
    weak var released = model
    model = nil
    await settle()
    #expect(released == nil)
    #expect(joining.committedCallbacks.count >= 2)
    joining.emitCommitted(.installed)
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == .string("installed-token"))
  }

  @Test func browserEntryWaitsBehindTheInstalledWrite() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    services.holdJoinedWrite = true
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .joining(.approved))
    #expect(!model.leaving)
    #expect(services.music.isEmpty)
    #expect(services.joinedWrites == 1)
    joining.emit(.installed)
    model.finishJoined()
    model.finishJoined()
    await settle()
    #expect(services.joinedWrites == 1)
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
    #expect(services.joinedWrites == 2)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == false)
    #expect(model.syncRoute == .joining(.approved))
    #expect(!model.leaving)
    #expect(services.music.isEmpty)
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(model.syncRoute == .joined)
    #expect(model.leaving)
    #expect(services.music == ["stop 0.6"])
    model.finishJoined()
    await settle()
    #expect(services.joinedWrites == 2)
  }

  @Test func unmountDiscardsBrowserEntryQueuedBehindTheInstalledWrite() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    services.holdJoinedWrite = true
    joining.emit(.installed)
    await settle()
    model.finishJoined()
    model.leaveSetup()
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
    #expect(services.joinedWrites == 1)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == false)
    #expect(!model.isActive)
    #expect(!model.leaving)
    #expect(services.music.isEmpty)
    #expect(services.setDefaultCalls == 0 && services.dockCalls == 0 && services.loginCalls.isEmpty)
  }

  @Test func terminalCallbacksReleaseTheModel() async {
    for terminal in [PairingJoinState.installed, .failed(.denied)] {
      var (model, services, discovery, joining): (OnboardingModel?, OnboardingFakeServices, OnboardingFakeDiscovery, OnboardingFakeJoining) = fixture()
      weak var retainedModel = model
      model?.maybeStart()
      discovery.emit(.found([candidate]))
      model?.pairWithAnotherMac()
      await settle()
      joining.emit(.approved)
      model = nil
      await settle()
      #expect(retainedModel != nil)
      joining.emit(terminal)
      await settle()
      #expect(retainedModel == nil)
      if terminal == .installed {
        #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == .string("installed-token"))
      }
    }
  }

  @Test func detachedCancellationDoesNotChangeTheRouteAndReleasesTheModel() async {
    var (model, _, discovery, joining): (OnboardingModel?, OnboardingFakeServices, OnboardingFakeDiscovery, OnboardingFakeJoining) = fixture()
    weak var retainedModel = model
    model?.maybeStart()
    discovery.emit(.found([candidate]))
    model?.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    model?.leaveSetup()
    #expect(joining.committedCallbacks.count >= 2)
    joining.emit(.failed(.cancelled))
    #expect(model?.syncRoute == .joining(.approved))
    #expect(model?.isActive == false)
    model = nil
    await settle()
    #expect(retainedModel == nil)
  }

  @Test func installedAdmittedBeforeACancelIsStillRecorded() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.handles.last?.cancelResult = .alreadyCommitted
    joining.committedResult = true
    joining.emit(.comparing(code: "ABC123", claimedName: "Other Mac"))
    model.cancelPairing()
    #expect(joining.committedCallbacks.count >= 2)
    joining.emitCommitted(.installed)
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == .string("installed-token"))
    #expect(model.syncRoute == .joined)
  }
  @Test func unavailableCancelResumesThroughCommittedJoinWithoutRecordingCompletion() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    let callbacks = joining.committedCallbacks.count
    joining.handles.last?.cancelResult = .unavailable
    joining.committedResult = true
    joining.committedState = .approved
    joining.emit(.comparing(code: "ABC123", claimedName: "Other Mac"))
    model.cancelPairing()
    await settle()
    #expect(joining.committedCallbacks.count == callbacks + 1)
    #expect(model.syncRoute == .joining(.approved))
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == nil)
    joining.emitCommitted(.installed)
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == .string("installed-token"))
    #expect(model.syncRoute == .joined)
  }

  @Test func unavailableCancelWithoutACommittedJoinShowsFolderUnavailable() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    let callbacks = joining.committedCallbacks.count
    joining.handles.last?.cancelResult = .unavailable
    joining.committedResult = false
    joining.emit(.comparing(code: "ABC123", claimedName: "Other Mac"))
    model.cancelPairing()
    await settle()
    #expect(joining.committedCallbacks.count == callbacks + 1)
    #expect(model.syncRoute == .joining(.failed(.folderUnavailable)))
    #expect(joining.handles.last?.restarts == 0)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == nil)
    joining.emit(.comparing(code: "LATE00", claimedName: "Other Mac"))
    #expect(model.syncRoute == .joining(.failed(.folderUnavailable)))
  }

  @Test func cancelledReturnsToFoundAndDropsLateCallback() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    #expect(joining.committedCallbacks.count == 1)
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    model.cancelPairing()
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .found)
    #expect(services.joinedWrites == 0)
  }

  @Test func approvedAloneNeverEntersJoinedOrRecordsBrowserEntry() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    #expect(joining.committedCallbacks.count == 1)
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    model.finishJoined()
    await settle()
    #expect(model.syncRoute == .joining(.approved))
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] != true)
    #expect(services.joinedWrites == 0)
    #expect(!model.canLeavePairing)
  }

  @Test func downloadingAppearsAtSixtySecondsAndKeepWaitingDoesNotLoop() async {
    let (model, services, discovery, joining) = fixture()
    let scheduler = model.scheduler as! OnboardingFakeScheduler
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    scheduler.advance(.seconds(59))
    #expect(model.syncTitle == "Finishing connection")
    scheduler.advance(.seconds(1))
    #expect(model.syncTitle == "Approved. Your synced data is still downloading.")
    let tasks = scheduler.tasks.count
    model.keepWaitingForSync()
    scheduler.advance(.seconds(120))
    joining.emit(.approved)
    #expect(model.syncTitle == "Approved. Your synced data is still downloading.")
    #expect(scheduler.tasks.count == tasks)
    #expect(!model.leaving && !model.canLeavePairing)
    #expect(services.joinedWrites == 0)
  }

  @Test(arguments: [false, true]) func browserEntryWhileDownloadingSurvivesLaterInstall(committedCallback: Bool) async {
    let (model, services, discovery, joining) = fixture()
    let scheduler = model.scheduler as! OnboardingFakeScheduler
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.committedResult = true
    joining.emit(.approved)
    scheduler.advance(.seconds(60))
    model.finishJoined()
    await settle()
    #expect(model.leaving)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(model.syncRoute == .joined)
    model.dismiss(session: model.session)
    #expect(!model.isActive)
    let completed = OnboardingFixture.saved(services)["completedAt"]
    if committedCallback { joining.emitCommitted(.installed) } else { joining.emit(.installed) }
    await settle()
    #expect(!model.isActive && !model.leaving)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "installed-token")
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(OnboardingFixture.saved(services)["completedAt"] == completed)
    #expect(services.imports.isEmpty && services.opened.isEmpty && services.store.patches.isEmpty)
    #expect(services.setDefaultCalls == 0 && services.dockCalls == 0 && services.loginCalls.isEmpty)
  }

  @Test func launchConsultsCommittedJoinBeforeTokenOrDiscovery() async {
    let (model, services, discovery, joining) = fixture()
    joining.committedResult = true
    joining.committedState = .approved
    services.committedOnboardingJoinToken = "admitted-token"
    model.maybeStart()
    await settle()
    #expect(joining.committedCallbacks.count == 1)
    #expect(model.syncRoute == .joining(.approved))
    #expect(discovery.callbacks.isEmpty)
    #expect(services.joinedWrites == 0)
    joining.emitCommitted(.installed)
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "installed-token")
  }

  @Test(arguments: ["discover", "recovery", "setup", "go", "finish", "start"])
  func admissionWinsAcrossSetupExits(action: String) async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.handles.last?.cancelResult = .alreadyCommitted
    joining.committedResult = true
    switch action {
    case "discover": model.discoverSync()
    case "recovery": model.useRecoveryPhrase()
    case "setup": model.continueSetup()
    case "go": model.go(.look)
    case "finish": model.finish()
    default: model.start(step: .look)
    }
    await settle()
    #expect(joining.committedCallbacks.count >= 2)
    #expect(model.syncRoute == .joining(.approved))
    #expect(services.recoveryPhraseCalls == 0)
    #expect(!model.leaving)
    joining.emitCommitted(.installed)
    await settle()
    #expect(model.syncRoute == .joined)
  }

  @Test func earlyBrowserEntryPreventsStartupFromResumingOnboarding() {
    let saved: JSONValue = ["startedAt": 1, "completedAt": 100, "joinedEnteredBrowser": true]
    #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false, committedJoinToken: "admitted") == .none)
  }

  @Test func earlyEntryForAReplacementJoinStaysDismissedAfterRelaunch() async {
    let (model, services, _, joining) = fixture()
    services.document = #"{"version":1,"startedAt":1,"completedAt":100,"joinedCompletionToken":"old-token","joinedEnteredBrowser":true}"#
    services.committedOnboardingJoinToken = "replacement-token"
    joining.committedResult = true
    joining.committedState = .approved
    model.maybeStart()
    #expect(model.syncRoute == .joining(.approved))
    (model.scheduler as! OnboardingFakeScheduler).advance(.seconds(60))
    model.finishJoined()
    await settle()
    model.dismiss(session: model.session)
    let relaunched = OnboardingModel(services: services, store: services.store, appName: "Solara")
    relaunched.maybeStart()
    await settle()
    #expect(joining.committedCallbacks.count >= 2)
    #expect(!relaunched.isActive)
    joining.emitCommitted(.installed)
    await settle()
    #expect(!relaunched.isActive && !model.isActive)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(OnboardingFixture.saved(services)["completedAt"] == 100)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "installed-token")
  }

  @Test(arguments: [false, true]) func maybeStartDoesNotTrustStagedBrowserEntry(failed: Bool) async {
    let (model, services, discovery, joining) = fixture()
    services.stagesJoinedWrites = true
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    services.holdJoinedWrite = true
    model.finishJoined()
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    if failed {
      services.joinedWriteContinuation?.resume(throwing: CocoaError(.fileWriteOutOfSpace))
      services.joinedWriteContinuation = nil
      await settle()
      #expect(model.syncRoute == .savingFailed)
    }
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara")
    remount.maybeStart()
    await settle()
    #expect(remount.isActive)
    #expect(remount.syncRoute != .setup && remount.syncRoute != .joined)
    services.holdJoinedWrite = false
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
    #expect(remount.syncRoute == .joined && !remount.leaving)
    model.leaveSetup()
    remount.leaveSetup()
  }

  @Test func liveMaybeStartRetriesFailedStagedBrowserEntry() async {
    let (model, services, discovery, joining) = fixture()
    services.stagesJoinedWrites = true
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    services.failJoinedWrite = true
    model.finishJoined()
    await settle()
    #expect(model.syncRoute == .savingFailed)
    services.failJoinedWrite = false
    services.holdJoinedWrite = true
    let writes = services.joinedWrites
    model.maybeStart()
    await settle()
    #expect(services.joinedWrites == writes + 1)
    #expect(!model.leaving)
    services.holdJoinedWrite = false
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
    #expect(model.syncRoute == .joined)
    model.leaveSetup()
  }

  @Test(arguments: [false, true]) func earlyStagedBrowserEntryDoesNotDismissRemountedJoin(failed: Bool) async {
    let (model, services, discovery, joining) = fixture()
    services.stagesJoinedWrites = true
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.committedResult = true
    joining.committedState = .approved
    joining.emit(.approved)
    (model.scheduler as! OnboardingFakeScheduler).advance(.seconds(60))
    services.holdJoinedWrite = true
    model.finishJoined()
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == nil)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    if failed {
      services.joinedWriteContinuation?.resume(throwing: CocoaError(.fileWriteOutOfSpace))
      services.joinedWriteContinuation = nil
      await settle()
      #expect(model.syncRoute == .savingFailed)
    }
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara")
    remount.maybeStart()
    #expect(remount.isActive)
    #expect(remount.syncRoute == .joining(.approved))
    model.leaveSetup()
    remount.leaveSetup()
    services.holdJoinedWrite = false
    services.joinedWriteContinuation?.resume()
    services.joinedWriteContinuation = nil
    await settle()
  }

  @Test func tryAgainAfterEarlyBrowserEntryFailureDoesNotNeedAnInstallToken() async {
    let (model, services, discovery, joining) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    (model.scheduler as! OnboardingFakeScheduler).advance(.seconds(60))
    #expect(services.committedOnboardingJoinToken == nil)
    services.failJoinedWrite = true
    model.finishJoined()
    await settle()
    #expect(model.syncRoute == .savingFailed)
    #expect(!model.leaving)
    #expect(services.joinedWrites == 1)
    services.failJoinedWrite = false
    model.finishJoined()
    await settle()
    #expect(services.joinedWrites == 2)
    #expect(model.syncRoute == .joined)
    #expect(model.leaving)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(services.clock))
    #expect(services.committedOnboardingJoinToken == nil)
    model.leaveSetup()
  }

}
