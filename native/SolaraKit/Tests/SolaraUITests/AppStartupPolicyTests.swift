import SolaraModel
import Testing

@testable import SolaraUI

@Suite struct AppStartupPolicyTests {
  private func version(
    _ saved: JSONValue? = nil, current: String = "1.0", hasSession: Bool = false,
    refused: Bool = false, safeMode: Bool = false, development: Bool = false,
    forcePostcard: Bool = false, now: Double = 100_000_000
  ) -> AppVersionDecision {
    AppStartupPolicy.version(
      current: current, saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
      development: development, forcePostcard: forcePostcard, now: now)
  }

  private func onboarding(
    _ saved: JSONValue? = nil, hasSession: Bool = false, refused: Bool = false,
    safeMode: Bool = false, hosted: Bool = true, development: Bool = false, force: Bool = false
  ) -> AppOnboardingDecision {
    AppStartupPolicy.onboarding(
      saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
      hosted: hosted, development: development, force: force)
  }

  @Test func firstLaunchRecordsVersionWithoutInventingAnUpdate() {
    let first = version()
    #expect(!first.updated)
    #expect(first.pending == .null)
    #expect(first.document?["lastVersion"] == "1.0")
    let migrated = version(hasSession: true)
    #expect(migrated.updated)
    #expect(migrated.pending == ["version": "1.0", "since": 100_000_000])
  }

  @Test func aSuccessfulVersionWriteMakesTheNextLaunchQuiet() {
    let updated = version(["version": 1, "lastVersion": "0.9", "pending": nil])
    #expect(updated.updated)
    let next = version(updated.document.map(JSONValue.object))
    #expect(!next.updated)
    #expect(next.pending == updated.pending)
  }

  @Test func onlyKnownProductionVersionsCreatePostcards() {
    let known = version(["lastVersion": "0.9", "pending": ["version": "0.9", "since": 10]])
    #expect(known.pending == ["version": "1.0", "since": 100_000_000])
    let unknown = version(["lastVersion": "0.9", "pending": ["version": "1.0", "since": 99_999_999]], current: "2.0")
    #expect(unknown.updated)
    #expect(unknown.pending == .null)
    #expect(unknown.document?["lastVersion"] == "2.0")
  }

  @Test func developmentPreservesSavedPendingUnlessExplicitlyForced() {
    let pending: JSONValue = ["version": "0.9", "since": 99_999_999]
    let saved: JSONValue = ["lastVersion": "0.9", "pending": pending]
    let ordinary = version(saved, development: true)
    #expect(ordinary.updated)
    #expect(ordinary.pending == pending)
    let forced = version(["lastVersion": "9.9"], current: "9.9", development: true, forcePostcard: true)
    #expect(!forced.updated)
    #expect(forced.pending == ["version": "9.9", "since": 100_000_000])
    let production = version(["lastVersion": "1.0"], forcePostcard: true)
    #expect(production.pending == .null)
  }

  @Test func postcardExpiryKeepsTheBoundaryAndFutureTimestamps() {
    for since: Double in [13_600_000, 100_000_001] {
      let pending: JSONValue = ["version": "1.0", "since": .number(since)]
      #expect(version(["lastVersion": "1.0", "pending": pending]).pending == pending)
    }
    #expect(version(["lastVersion": "1.0", "pending": ["version": "1.0", "since": 13_599_999]]).pending == .null)
  }

  @Test func safeModeDisplaysAnUpdateWithoutAutomaticallyWritingIt() {
    let decision = version(["lastVersion": "0.9"], safeMode: true)
    #expect(decision.updated)
    #expect(decision.pending == ["version": "1.0", "since": 100_000_000])
    #expect(decision.document == nil)
  }

  @Test func refusedPersistenceAndEmptyVersionProduceNoAutomaticEffects() {
    let saved: JSONValue = ["lastVersion": "0.9", "pending": ["version": "0.9", "since": 1]]
    for decision in [version(saved, refused: true, forcePostcard: true), version(saved, current: "")] {
      #expect(!decision.updated)
      #expect(decision.pending == .null)
      #expect(decision.document == nil)
    }
  }

  @Test func malformedSavedShapesKeepJavaScriptTruthiness() throws {
    for saved: JSONValue in [.null, false, 0, ""] {
      #expect(!version(saved).updated)
      #expect(version(saved, hasSession: true).updated)
    }
    for saved: JSONValue in [true, 1, "saved", [], [:]] {
      #expect(version(saved).updated)
    }
    let malformed = try? JSONValue.parse("{")
    #expect(malformed == nil)
    #expect(!version(malformed).updated)
    let missingVersion = version(["version": 1])
    #expect(missingVersion.updated)
  }

  @Test func malformedPendingExpiryKeepsTheSameCoercionRules() {
    for pending: JSONValue in [false, 0, "", true, ["version": "1.0"], ["version": "1.0", "since": "bad"]] {
      #expect(version(["lastVersion": "1.0", "pending": pending]).pending == pending)
    }
    for since: JSONValue in [.null, false, " 0 ", [], [0], "0x10"] {
      #expect(version(["lastVersion": "1.0", "pending": ["version": "1.0", "since": since]]).pending == .null)
    }
  }

  @Test func versionDocumentsReplaceOnlyTheExistingAutomaticRecordShape() {
    let saved: JSONValue = ["lastVersion": "0.9", "unknown": "old", "version": 99]
    let result = version(saved)
    #expect(result.document?["version"] == 1)
    #expect(result.document?["unknown"] == nil)
  }

  @Test func completedOnboardingAndMissingHostNeverStartOrResume() {
    #expect(onboarding(["completedAt": 1, "startedAt": 1]) == .none)
    #expect(onboarding(["completedAt": "done"]) == .none)
    #expect(onboarding(["startedAt": 1], hosted: false) == .none)
    #expect(onboarding(["startedAt": 1], safeMode: true) == .none)
  }

  @Test func onboardingResumePrecedesRefusalSessionAndDevelopmentChecks() {
    #expect(onboarding(["startedAt": 1], hasSession: true, refused: true, development: true) == .resume)
    #expect(onboarding(["startedAt": "started"]) == .resume)
    #expect(onboarding(["startedAt": 0]) == .start)
  }

  @Test func freshOnboardingPreservesRefusalMigrationAndDevelopmentOrdering() {
    #expect(onboarding(hasSession: true, refused: true) == .none)
    #expect(onboarding(hasSession: true, development: true) == .complete)
    #expect(onboarding(development: true) == .none)
    #expect(onboarding(development: true, force: true) == .start)
    #expect(onboarding() == .start)
    #expect(onboarding(force: true) == .start)
  }

  @Test func onboardingProgressMergesPreserveUnrelatedDocumentsFields() {
    let saved: JSONValue = ["version": 9, "completedAt": 12, "introMusicMuted": true, "defaultBrowserTrialStartedAt": 7, "unknown": [1, 2]]
    let result = AppStartupPolicy.onboardingDocument(saved: saved, patch: ["startedAt": 100, "completedAt": nil])
    #expect(result["version"] == 9)
    #expect(result["completedAt"] == .null)
    #expect(result["startedAt"] == 100)
    #expect(result["introMusicMuted"] == true)
    #expect(result["defaultBrowserTrialStartedAt"] == 7)
    #expect(result["unknown"] == [1, 2])
    #expect(AppStartupPolicy.onboardingDocument(saved: nil, patch: [:]) == ["version": 1, "completedAt": nil])
  }

  @Test func absentBrokenOrConsumedDefaultOffersNeverAsk() throws {
    let broken = try? JSONValue.parse("{")
    for saved: JSONValue? in [nil, broken, .null, false, 0, "", ["askedAt": 1], ["askedAt": -1], ["askedAt": "done"], ["askedAt": []]] {
      #expect(AppStartupPolicy.defaultOffer(saved: saved, testInstance: false) == .none)
    }
    for askedAt: JSONValue in [.null, false, 0, ""] {
      #expect(AppStartupPolicy.defaultOffer(saved: ["askedAt": askedAt], testInstance: false) == .eligible)
    }
  }

  @Test func isolatedInstancesDoNotConsumeEligibleDefaultOffers() {
    let saved: JSONValue = ["version": 1, "askedAt": nil]
    #expect(AppStartupPolicy.defaultOffer(saved: saved, testInstance: true) == .testInstance)
    #expect(AppStartupPolicy.defaultOffer(saved: saved, testInstance: false) == .eligible)
    #expect(AppStartupPolicy.defaultOffer(saved: ["askedAt": 1], testInstance: true) == .none)
  }

  @Test func defaultOfferRecordsTheMarkerAndPreservesEveryOtherField() {
    let saved: JSONValue = ["version": 8, "askedAt": nil, "unknown": ["keep": true]]
    let decision = AppStartupPolicy.completeDefaultOffer(saved: saved, onboarding: false, isDefault: false, now: 123)
    #expect(decision.document["version"] == 8)
    #expect(decision.document["askedAt"] == 123)
    #expect(decision.document["unknown"] == ["keep": true])
    #expect(decision.outcome == .asked)
    #expect(decision.requestDefault)
    #expect(AppStartupPolicy.defaultOffer(saved: .object(decision.document), testInstance: false) == .none)
  }

  @Test func onboardingAndExistingDefaultsConsumeOffersWithoutAnotherPrompt() {
    let saved: JSONValue = ["version": 1, "askedAt": nil]
    let onboarding = AppStartupPolicy.completeDefaultOffer(saved: saved, onboarding: true, isDefault: false, now: 123)
    #expect(onboarding.outcome == .onboarding)
    #expect(!onboarding.requestDefault)
    #expect(onboarding.document["askedAt"] == 123)
    let existing = AppStartupPolicy.completeDefaultOffer(saved: saved, onboarding: false, isDefault: true, now: 124)
    #expect(existing.outcome == .alreadyDefault)
    #expect(!existing.requestDefault)
    #expect(existing.document["askedAt"] == 124)
  }

  @Test func validWrongShapeOffersPreserveObjectSpreadSemantics() {
    #expect(AppStartupPolicy.defaultOffer(saved: [], testInstance: false) == .eligible)
    let array = AppStartupPolicy.completeDefaultOffer(saved: ["a", "b"], onboarding: false, isDefault: false, now: 1)
    #expect(array.document["0"] == "a")
    #expect(array.document["1"] == "b")
    #expect(array.document["askedAt"] == 1)
    let string = AppStartupPolicy.completeDefaultOffer(saved: "ab", onboarding: true, isDefault: false, now: 2)
    #expect(string.document["0"] == "a")
    #expect(string.document["1"] == "b")
  }

  @Test func helpURLsKeepTheExactHttpPrefixAndFragmentBehavior() {
    for page in [nil, "", "file:///notes", "javascript:alert(1)", " https://notes"] as [String?] {
      #expect(AppStartupPolicy.releaseNotesURL(page: page, version: "1.0") == nil)
      #expect(AppStartupPolicy.videoURL(page: page) == nil)
    }
    #expect(AppStartupPolicy.releaseNotesURL(page: "HTTPS://notes/#old", version: "1.0 beta") == "HTTPS://notes/#old#1.0 beta")
    #expect(AppStartupPolicy.releaseNotesURL(page: "https://notes", version: "") == "https://notes")
    #expect(AppStartupPolicy.videoURL(page: "http://") == "http://")
  }

  @Test func automaticReleasePagesRespectDevelopmentIsolationAndForce() {
    for development in [true, false] {
      for isolated in [true, false] {
        #expect(AppStartupPolicy.shouldOpenAfterUpdate(development: development, isolated: isolated, force: true))
        #expect(AppStartupPolicy.shouldOpenAfterUpdate(development: development, isolated: isolated, force: false) == (!development && !isolated))
      }
    }
  }

  @Test func releaseNotesOpenOnTheFirstLaunchOfANewVersionAndNotOnRelaunch() {
    let first = version(["version": 1, "lastVersion": "0.9", "pending": nil])
    #expect(AppStartupPolicy.opensReleaseNotes(updated: first.updated, development: false, isolated: false, force: false))
    let relaunch = version(first.document.map(JSONValue.object))
    #expect(!AppStartupPolicy.opensReleaseNotes(updated: relaunch.updated, development: false, isolated: false, force: false))
    #expect(!AppStartupPolicy.opensReleaseNotes(updated: relaunch.updated, development: false, isolated: false, force: true))
    let fresh = version()
    #expect(!AppStartupPolicy.opensReleaseNotes(updated: fresh.updated, development: false, isolated: false, force: false))
  }

  @Test func genericNotificationClicksPreferLiveTabsThenLiveWindows() {
    var state = BrowserState()
    state.windows["w"] = BrowserWindow(id: "w", profileId: "p", incognito: false, frame: nil, createdAt: 0)
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "p", url: "https://example.com", now: 0)
    #expect(AppStartupPolicy.notificationTarget(state: state, action: "click", tabId: "t", windowId: "other") == .tab("t"))
    #expect(AppStartupPolicy.notificationTarget(state: state, action: "click", tabId: "missing", windowId: "w") == .window("w"))
    #expect(AppStartupPolicy.notificationTarget(state: state, action: "close", tabId: "t", windowId: "w") == .none)
    #expect(AppStartupPolicy.notificationTarget(state: state, action: "click", tabId: "missing", windowId: "missing") == .none)
    state.tabs[""] = state.tabs["t"]
    state.windows[""] = state.windows["w"]
    #expect(AppStartupPolicy.notificationTarget(state: state, action: "click", tabId: "", windowId: "") == .none)
  }
  @Test func joinedRouteTakesPriorityOverCompletedAndSessionDocuments() {
    let saved: JSONValue = ["completedAt": 100, "joinedCompletionToken": "joined", "joinedEnteredBrowser": false]
    #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false, committedJoinToken: "joined") == .resume)
  }

  @Test func durableJoinMarkerResumesWithoutAnOnboardingDocument() {
    for saved: JSONValue? in [nil, ["completedAt": 100]] {
      #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false, committedJoinToken: "durable") == .resume)
    }
  }

  @Test func acknowledgedBrowserEntryKeepsNormalLaunchQuiet() {
    let saved: JSONValue = ["completedAt": 100, "joinedCompletionToken": "joined", "joinedEnteredBrowser": true]
    #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false, committedJoinToken: "joined") == .none)
    #expect(AppStartupPolicy.onboarding(saved: saved, hasSession: true, refused: false, safeMode: false, hosted: true, development: false, force: false, committedJoinToken: "new-join") == .resume)
  }

}
