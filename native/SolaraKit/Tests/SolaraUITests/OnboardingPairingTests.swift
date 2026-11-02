import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingPairingTests {
  let candidate = OnboardingDiscoveryCandidate(cid: "first", lastActivity: Date(timeIntervalSince1970: 10))

  func fixture() -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeStore, OnboardingFakeDiscovery, OnboardingFakeJoining, OnboardingFakeScheduler) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    let scheduler = OnboardingFakeScheduler()
    services.discovery = discovery
    services.joining = joining
    joining.onInstalled = { services.committedOnboardingJoinToken = "installed-token" }
    let model = OnboardingModel(services: services, store: store, appName: "Solara", scheduler: scheduler)
    return (model, services, store, discovery, joining, scheduler)
  }

  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  @Test func firstLaunchHoldsBeforeTheFirstCard() {
    let (model, _, _, discovery, _, _) = fixture()
    model.maybeStart()
    #expect(model.syncRoute == .discovering)
    #expect(model.syncTitle == "Looking for Solara on your other Macs…")
    #expect(discovery.callbacks.count == 1)
  }

  @Test func completedInstallsAndRestartedToursDoNotDiscover() {
    let (model, services, _, discovery, _, _) = fixture()
    services.document = #"{"version":1,"completedAt":123}"#
    model.maybeStart()
    #expect(!model.isActive)
    model.start(step: .source)
    #expect(model.syncRoute == .setup)
    #expect(discovery.callbacks.isEmpty)
  }

  @Test func emptyContinuesFreshSetup() {
    let (model, _, _, discovery, _, _) = fixture()
    model.maybeStart()
    discovery.emit(.empty)
    #expect(model.syncRoute == .setup)
    #expect(model.step == .intro)
  }

  @Test func incompleteSavedCardRunsPreflightBeforeResume() {
    let (model, services, _, discovery, _, _) = fixture()
    services.document = #"{"version":1,"startedAt":1,"step":"look","sub":2}"#
    model.maybeStart()
    #expect(model.syncRoute == .discovering)
    discovery.emit(.empty)
    #expect(model.syncRoute == .setup)
    #expect(model.step == .look && model.sub == 2)
  }

  @Test func candidatesLeadWithPairingAndKeepObservedActivity() {
    let (model, _, _, discovery, _, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    #expect(model.syncRoute == .found)
    #expect(model.syncTitle == "Use Solara from your other Mac")
    #expect(model.syncMessage == "Sync data was found in iCloud Drive › Solara Sync")
    #expect(model.candidates == [candidate])
    #expect(model.selectedCID == candidate.cid)
  }

  @Test func unavailablePermissionAndTimeoutStayDistinct() {
    for result in [OnboardingDiscoveryResult.unavailable, .permissionDenied, .timedOut] {
      let (model, _, _, discovery, _, _) = fixture()
      model.maybeStart()
      discovery.emit(result)
      #expect(model.syncRoute == .discoveryIssue(result))
      #expect(!model.syncTitle.isEmpty)
      if result == .timedOut { #expect(model.syncTitle == "Couldn't finish checking iCloud Drive.") }
    }
  }

  @Test func tenSecondDeadlineIgnoresLateResultAfterContinue() {
    let (model, _, _, discovery, _, scheduler) = fixture()
    model.maybeStart()
    scheduler.advance(.seconds(9))
    #expect(model.syncRoute == .discovering)
    scheduler.advance(.seconds(1))
    #expect(model.syncRoute == .discoveryIssue(.timedOut))
    model.continueSetup()
    discovery.emit(.found([candidate]), request: 0)
    #expect(model.syncRoute == .setup)
    #expect(model.candidates.isEmpty)
  }

  @Test func callbackChecksDeadlineEvenWhenTimerHasNotRun() {
    let (model, _, _, discovery, _, scheduler) = fixture()
    model.maybeStart()
    scheduler.advance(.seconds(10), fire: false)
    discovery.emit(.found([candidate]))
    #expect(model.syncRoute == .discoveryIssue(.timedOut))
  }

  @Test func hydrationRetriesInsideOriginalDeadline() {
    let (model, _, _, discovery, _, scheduler) = fixture()
    model.maybeStart()
    scheduler.advance(.seconds(8))
    discovery.emit(.needsHydration)
    #expect(model.syncRoute == .discovering)
    scheduler.advance(.milliseconds(250))
    discovery.emit(.found([candidate]))
    #expect(model.syncRoute == .found)
    scheduler.advance(.seconds(2))
    #expect(model.syncRoute == .found)
  }

  @Test func hydrationDoesNotExtendDeadline() {
    let (model, _, _, discovery, _, scheduler) = fixture()
    model.maybeStart()
    scheduler.advance(.seconds(9))
    discovery.emit(.needsHydration)
    scheduler.advance(.seconds(1))
    #expect(model.syncRoute == .discoveryIssue(.timedOut))
  }

  @Test func severalCIDsRequireExplicitChoiceAndStartOnlyOne() async {
    let (model, _, _, discovery, joining, _) = fixture()
    let newer = OnboardingDiscoveryCandidate(cid: "second", lastActivity: Date(timeIntervalSince1970: 99))
    model.maybeStart()
    discovery.emit(.found([candidate, newer]))
    #expect(model.selectedCID == nil)
    model.pairWithAnotherMac()
    await settle()
    #expect(joining.cids.isEmpty)
    model.selectSync(cid: "absent")
    #expect(model.selectedCID == nil)
    model.selectSync(cid: candidate.cid)
    model.pairWithAnotherMac()
    await settle()
    #expect(joining.cids == [candidate.cid])
  }

  @Test func everyJoinStateHasItsScreenModel() async {
    let (model, _, _, discovery, joining, scheduler) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    #expect(model.syncRoute == .joining(.preparing))
    #expect(model.syncTitle == "Preparing a secure connection…")
    #expect(model.claimedSyncName == "Trusted Mac")
    joining.emit(.waiting(expires: scheduler.now + .seconds(42)))
    #expect(model.syncMessage == "Open Solara on your other Mac and choose Connect another Mac or Review request.")
    #expect(model.pairingRemainingSeconds == 42)
    joining.emit(.comparing(code: "ABC DEF", claimedName: "Hill Mac"))
    #expect(model.syncCode == "ABC DEF")
    #expect(model.claimedSyncName == "“Hill Mac”")
    #expect(model.syncMessage == "Compare this code on your other Mac, then choose Allow there.")
    joining.emit(.approved)
    #expect(model.syncTitle == "Finishing connection")
    #expect(model.syncCode == nil)
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(model.syncTitle == "You're connected")
  }

  @Test func failuresUseSpecificCopyAndCancelledReturnsToFound() async {
    let cases: [(PairingJoinFailure, String)] = [
      (.expired, "No Mac approved in time. Open Solara on your other Mac and try again, or use your recovery phrase."),
      (.denied, "Your other Mac declined this request."),
      (.mismatch, "The codes don't match. Nothing was connected."),
      (.folderUnavailable, "The sync folder isn't available."),
      (.invalidPeer, "This connection couldn't be verified. Nothing was connected."),
    ]
    for (failure, message) in cases {
      let (model, _, _, discovery, joining, _) = fixture()
      model.maybeStart()
      discovery.emit(.found([candidate]))
      model.pairWithAnotherMac()
      await settle()
      joining.emit(.failed(failure))
      #expect(model.syncRoute == .joining(.failed(failure)))
      #expect(model.syncMessage == message)
      joining.emit(.failed(.cancelled))
      #expect(model.syncRoute == .found)
    }
  }

  @Test func startAgainErasesOldCodeAndNameBeforeRestart() async {
    let (model, _, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.comparing(code: "ABC DEF", claimedName: "Old name"))
    model.startPairingAgain()
    #expect(model.syncCode == nil)
    #expect(model.claimedSyncName == "Trusted Mac")
    #expect(model.syncRoute == .joining(.preparing))
    #expect(joining.handles.first?.restarts == 1)
    joining.emit(.comparing(code: "GHI JKL", claimedName: "New name"))
    #expect(model.syncCode == "GHI JKL")
  }

  @Test func recoveryPhraseInsteadCancelsAndRejectsLateCallbacks() async {
    let (model, services, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    model.useRecoveryPhrase()
    #expect(joining.handles.first?.cancellations == 1)
    await settle()
    #expect(services.recoveryPhraseCalls == 1)
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute != .joined)
    #expect(services.joinedWrites == 0)
  }

  @Test func leavingCancelsDiscoveryAndJoinAndRejectsLateCallbacks() async {
    let (preflight, _, _, firstDiscovery, _, _) = fixture()
    preflight.maybeStart()
    preflight.leaveSetup()
    #expect(firstDiscovery.handles.first?.cancellations == 1)
    firstDiscovery.emit(.found([candidate]))
    #expect(!preflight.isActive)
    let (model, services, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    model.leaveSetup()
    #expect(joining.handles.first?.cancellations == 1)
    joining.emit(.installed)
    await settle()
    #expect(services.joinedWrites == 0)
    #expect(!model.isActive)
  }

  @Test func installedAcknowledgesIdempotentCompletionWithoutImportOrSystemChanges() async {
    let (model, services, store, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.approved)
    #expect(services.joinedWrites == 0)
    joining.emit(.installed)
    await settle()
    let saved = OnboardingFixture.saved(services)
    #expect(saved["joinedCompletionToken"]?.string?.isEmpty == false)
    #expect(saved["joinedCompletionAt"] == .number(services.clock))
    #expect(saved["completedAt"] == .null)
    #expect(services.joinedWrites == 1)
    joining.emit(.installed)
    await settle()
    #expect(services.joinedWrites == 1)
    model.finishJoined()
    await settle()
    model.dismiss(session: model.session)
    #expect(!model.isActive)
    #expect(services.imports.isEmpty && services.opened.isEmpty)
    #expect(services.setDefaultCalls == 0 && services.dockCalls == 0 && services.loginCalls.isEmpty)
    #expect(store.patches.isEmpty)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == true)
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(services.clock))
  }

  @Test func joinedCompletionResumesAheadOfSavedCardsAndSessionDocument() async {
    let (model, services, _, discovery, joining, _) = fixture()
    services.session = true
    services.document = #"{"version":1,"startedAt":1,"step":"source","joinedCompletionToken":"committed","joinedCompletionAt":100,"completedAt":100}"#
    services.committedOnboardingJoinToken = "committed"
    model.maybeStart()
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(model.isActive)
    #expect(discovery.callbacks.isEmpty && joining.cids.isEmpty)
    model.finishJoined()
    await settle()
    model.dismiss(session: model.session)
    let relaunched = OnboardingModel(services: services, store: services.store, appName: "Solara")
    relaunched.maybeStart()
    #expect(!relaunched.isActive)
  }

  @Test func failedCompletionWriteStaysUncompletedAndRetriesSameToken() async {
    let (model, services, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    services.failJoinedWrite = true
    joining.emit(.installed)
    await settle()
    #expect(model.syncRoute == .savingFailed)
    #expect(model.completedAt == nil)
    #expect(model.syncTitle == "Couldn't finish saving sync on this Mac.")
    services.failJoinedWrite = false
    model.finishJoined()
    await settle()
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"]?.string?.isEmpty == false)
    #expect(model.leaving)
  }

  @Test func durableCoordinatorMarkerRecoversAfterFailedOnboardingWrite() async {
    let (model, services, _, discovery, _, _) = fixture()
    services.session = true
    services.committedOnboardingJoinToken = "installed-token"
    model.maybeStart()
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == "installed-token")
    #expect(discovery.callbacks.isEmpty)
  }

  @Test func previewsRevertAndDrainBeforePairingThenNeverOverwriteSyncedValues() async {
    let (model, services, store, discovery, joining, _) = fixture()
    model.start(step: .look, isFirstRunOnboarding: true)
    model.previewLive(["appearance": "dark", "searchEngine": "duckduckgo", "tabLayout": "top"])
    model.previewColor(.green)
    model.setDraft(["appearance": "dark"])
    model.setExtras { $0.dock = true }
    services.holdDrain = true
    model.discoverSync()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    #expect(joining.cids.isEmpty)
    #expect(services.drainCalls > 0)
    #expect(model.baseline.isEmpty && model.draft.isEmpty)
    #expect(services.colors["w1"] == .plum)
    services.drainContinuation?.resume()
    services.drainContinuation = nil
    await settle()
    #expect(joining.cids == [candidate.cid])
    store.settings = store.settings.updated(["appearance": "light", "searchEngine": "bing"], fromSync: true)
    services.windowLayout["w1"] = "sidebar"
    joining.emit(.installed)
    await settle()
    model.finishJoined()
    await settle()
    model.dismiss(session: model.session)
    let relaunched = OnboardingModel(services: services, store: store, appName: "Solara")
    relaunched.maybeStart()
    #expect(store.settings.string("appearance") == "light")
    #expect(store.settings.string("searchEngine") == "bing")
    #expect(services.windowLayout["w1"] == "sidebar")
  }

  @Test func installedMayArriveSynchronouslyFromStart() async {
    let (model, services, _, discovery, joining, _) = fixture()
    joining.initialState = .installed
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    #expect(model.syncRoute == .joined)
    #expect(services.joinedWrites == 1)
    model.leaveSetup()
    #expect(joining.handles.first?.cancellations == 0)
  }
  @Test func staleSetupCallbacksCannotPreviewOrConfirmAfterJoined() async {
    let (model, services, store, discovery, joining, _) = fixture()
    model.start(step: .look, isFirstRunOnboarding: true)
    model.discoverSync()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    let previews = services.previews.count
    store.settings = store.settings.updated(["appearance": "light"], fromSync: true)
    await model.enter(.look)
    model.confirmCurrent()
    #expect(services.previews.count == previews)
    #expect(model.baseline.isEmpty)
    #expect(store.patches.isEmpty)
    #expect(store.settings.string("appearance") == "light")
  }

  @Test func staleImportCannotRunAfterJoined() async {
    let (model, services, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    model.chooseSource(.arc)
    await model.loadSources()
    model.startImport()
    #expect(model.source == nil)
    #expect(services.imports.isEmpty)
  }

  @Test func staleSystemCallbackCannotChangeDefaultDockOrLoginAfterJoined() async {
    let (model, services, _, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    model.system = OnboardingSystemState(isDefault: false, inDock: false, loginEnabled: false)
    model.setExtras { $0.login = true }
    await model.applySystem()
    #expect(services.setDefaultCalls == 0)
    #expect(services.dockCalls == 0)
    #expect(services.loginCalls.isEmpty)
  }

  @Test func staleRecoveryTaskCannotOpenAfterANewSetupSession() async {
    let (model, services, _, _, _, _) = fixture()
    model.start(step: .source, isFirstRunOnboarding: true)
    model.useRecoveryPhrase()
    model.leaveSetup()
    model.start(step: .look, isFirstRunOnboarding: true)
    await settle()
    #expect(services.recoveryPhraseCalls == 0)
  }

  @Test func restartCanRecoverWhenTheServiceWasInitiallyUnavailable() async {
    let (model, services, _, discovery, joining, _) = fixture()
    services.joining = nil
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    #expect(model.syncRoute == .joining(.failed(.invalidPeer)))
    services.joining = joining
    model.startPairingAgain()
    await settle()
    #expect(joining.cids == [candidate.cid])
    #expect(model.syncRoute == .joining(.preparing))
  }

  @Test func installedRouteRemainsEligibleForTheHostAfterRelaunch() async {
    let (model, services, store, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    model.leaveSetup()
    let saved = OnboardingFixture.saved(services)
    let hostWouldMountOnboarding = saved["completedAt"]?.truthy != true
    #expect(hostWouldMountOnboarding)
    let relaunched = OnboardingModel(services: services, store: store, appName: "Solara")
    if hostWouldMountOnboarding { relaunched.maybeStart() }
    await settle()
    #expect(relaunched.syncRoute == .joined)
    #expect(relaunched.isActive)
    #expect(discovery.callbacks.count == 1)
  }

  @Test func browserEntryWriteFailureKeepsTheInstalledRouteRecoverable() async {
    let (model, services, store, discovery, joining, _) = fixture()
    model.maybeStart()
    discovery.emit(.found([candidate]))
    model.pairWithAnotherMac()
    await settle()
    joining.emit(.installed)
    await settle()
    let token = OnboardingFixture.saved(services)["joinedCompletionToken"]
    services.failJoinedWrite = true
    model.finishJoined()
    await settle()
    #expect(model.syncRoute == .savingFailed)
    #expect(!model.leaving)
    #expect(OnboardingFixture.saved(services)["completedAt"] == .null)
    #expect(OnboardingFixture.saved(services)["joinedEnteredBrowser"] == false)
    model.leaveSetup()
    services.failJoinedWrite = false
    let relaunched = OnboardingModel(services: services, store: store, appName: "Solara")
    relaunched.maybeStart()
    await settle()
    #expect(relaunched.syncRoute == .joined)
    relaunched.finishJoined()
    await settle()
    #expect(relaunched.leaving)
    #expect(OnboardingFixture.saved(services)["joinedCompletionToken"] == token)
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(services.clock))
  }

}
