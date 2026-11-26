import Testing
import SolaraModel
import SolaraStore
@testable import SolaraUI

@MainActor
struct ExtensionPopupLifecycleTests {
  func source(_ window: String = "w", tab: String? = "a", page: Int = 1, generation: Int = 1, url: String = "https://a.test", sequence: Double = 1, registration: PageRegistrationGeneration = 1) -> ExtensionPopupLifecycle.Source {
    .init(windowId: window, tabId: tab, profile: "work", url: url, sequence: sequence, browserId: page, generation: generation, registration: tab.map { PageRegistration(tabID: $0, registrationGeneration: registration) })
  }

  @Test func lateCompletionAndSecondClickCannotResurrect() {
    var lifecycle = ExtensionPopupLifecycle()
    let request = lifecycle.begin(source(), extensionId: "ext")
    #expect(lifecycle.matches(windowId: "w", extensionId: "ext"))
    lifecycle.close(windowId: "w")
    let accepted1 = lifecycle.finish(request, source: source(), eligible: true)
    #expect(!accepted1)
    let next = lifecycle.begin(source(), extensionId: "ext")
    let accepted2 = lifecycle.finish(next, source: source(), eligible: true)
    #expect(accepted2)
  }

  @Test func tabSwitchAndReturnWindowCloseNavigationAndReplacementCancel() {
    for changed in [source(tab: "b"), source(page: 2), source(generation: 2), source(url: "https://b.test"), source(sequence: 2), source(registration: 2)] {
      var lifecycle = ExtensionPopupLifecycle()
      let request = lifecycle.begin(source(), extensionId: "ext")
      lifecycle.reconcile(sources: ["w": changed], eligible: ["w": ["ext"]])
      let accepted3 = lifecycle.finish(request, source: source(), eligible: true)
      #expect(!accepted3)
    }
    var lifecycle = ExtensionPopupLifecycle()
    let request = lifecycle.begin(source(), extensionId: "ext")
    lifecycle.reconcile(sources: [:], eligible: [:])
    let accepted4 = lifecycle.finish(request, source: source(), eligible: true)
    #expect(!accepted4)
  }

  @Test func sameExtensionInTwoWindowsUsesRequestIdentity() {
    var lifecycle = ExtensionPopupLifecycle()
    let old = lifecycle.begin(source(), extensionId: "ext")
    let firstOpened = lifecycle.finish(old, source: source(), eligible: true)
    #expect(firstOpened)
    let next = lifecycle.begin(source("other"), extensionId: "ext")
    #expect(lifecycle.matches(windowId: "w", extensionId: "ext"))
    #expect(lifecycle.matches(windowId: "other", extensionId: "ext"))
    lifecycle.close(windowId: "w")
    let accepted5 = lifecycle.finish(old, source: source(), eligible: true)
    #expect(!accepted5)
    let accepted6 = lifecycle.finish(next, source: source("other"), eligible: true)
    #expect(accepted6)
    #expect(lifecycle.open?.source.windowId == "other")
  }

  @Test func unloadInvalidatesPendingAndOpenAndReloadCannotRevive() {
    var lifecycle = ExtensionPopupLifecycle()
    let request = lifecycle.begin(source(), extensionId: "ext")
    lifecycle.reconcile(sources: ["w": source()], eligible: ["w": []])
    let accepted7 = lifecycle.finish(request, source: source(), eligible: true)
    #expect(!accepted7)
    let next = lifecycle.begin(source(), extensionId: "ext")
    let accepted8 = lifecycle.finish(next, source: source(), eligible: true)
    #expect(accepted8)
    lifecycle.reconcile(sources: ["w": source()], eligible: ["w": []])
    #expect(lifecycle.open == nil)
    let reloading = lifecycle.begin(source(), extensionId: "ext")
    lifecycle.invalidate()
    let accepted9 = lifecycle.finish(reloading, source: source(), eligible: true)
    #expect(!accepted9)
  }

  @Test func replacementPreservesNextRequestButDismissalCancelsIt() {
    var lifecycle = ExtensionPopupLifecycle()
    let first = lifecycle.begin(source(), extensionId: "first")
    let accepted10 = lifecycle.finish(first, source: source(), eligible: true)
    #expect(accepted10)
    let next = lifecycle.begin(source(), extensionId: "next")
    lifecycle.close(windowId: "w", replacement: true)
    let accepted11 = lifecycle.finish(next, source: source(), eligible: true)
    #expect(accepted11)
    let dismissed = lifecycle.begin(source(), extensionId: "next")
    lifecycle.close(windowId: "w")
    let accepted12 = lifecycle.finish(dismissed, source: source(), eligible: true)
    #expect(!accepted12)
  }

  @Test func retiringTheOldPagePreservesTheReplacementRequestInTheSameWindow() {
    var lifecycle = ExtensionPopupLifecycle()
    let original = lifecycle.begin(source(), extensionId: "ext")
    let opened = lifecycle.finish(original, source: source(), eligible: true)
    #expect(opened)
    let replacement = lifecycle.begin(source(registration: 2), extensionId: "ext")
    lifecycle.reconcile(sources: ["w": source(registration: 2)], eligible: ["w": ["ext"]])
    #expect(lifecycle.open == nil)
    #expect(lifecycle.pending == replacement)
  }

  @Test func unsuccessfulActivationClosesOnlyItsWindowsPopup() {
    var lifecycle = ExtensionPopupLifecycle()
    let first = lifecycle.begin(source(), extensionId: "withPopup")
    let opened = lifecycle.finish(first, source: source(), eligible: true)
    #expect(opened)
    let otherWindow = lifecycle.begin(source("other"), extensionId: "noPopup")
    let completedElsewhere = lifecycle.completeWithoutPopup(otherWindow)
    #expect(completedElsewhere)
    #expect(lifecycle.open == first)

    let second = lifecycle.begin(source(), extensionId: "noPopup")
    let completedHere = lifecycle.completeWithoutPopup(second)
    #expect(completedHere)
    #expect(lifecycle.pending == nil)
    #expect(lifecycle.open == nil)
  }

  @Test func staleUnsuccessfulActivationLeavesNewRequestsAlone() {
    var lifecycle = ExtensionPopupLifecycle()
    let stale = lifecycle.begin(source(), extensionId: "noPopup")
    let newer = lifecycle.begin(source(), extensionId: "withPopup")
    let rejectedBeforeOpen = !lifecycle.completeWithoutPopup(stale)
    #expect(rejectedBeforeOpen)
    #expect(lifecycle.pending == newer)
    let opened = lifecycle.finish(newer, source: source(), eligible: true)
    #expect(opened)
    let rejectedAfterOpen = !lifecycle.completeWithoutPopup(stale)
    #expect(rejectedAfterOpen)
    #expect(lifecycle.open == newer)
  }

  @Test func queuedTabRoundTripDismissesOnlyThePopupThatPredatesIt() throws {
    var state = BrowserState()
    let profile = state.settings.defaultProfileId
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b"]
    window.activeTabIds[profile] = "a"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    for tab in window.tabIds {
      state.tabs[tab] = Tab(id: tab, windowId: "w", profileId: profile, url: "https://\(tab).test", now: 0)
    }
    let store = Store(state: state, checksInvariants: false)
    let shown = ExtensionPopupLifecycle.Source(windowId: "w", tabId: "a", profile: profile, url: nil,
      sequence: nil, browserId: 1, generation: 1)
    var lifecycle = ExtensionPopupLifecycle()
    let first = lifecycle.begin(shown, extensionId: "ext", revision: store.rev)
    let opened = lifecycle.finish(first, source: shown, eligible: true)
    #expect(opened)

    let away = try store.dispatch(Command("activate", ["b"]), origin: .native)
    let back = try store.dispatch(Command("activate", ["a"]), origin: .native)
    #expect(away.state.activeTabId("w") == "b")
    #expect(ExtensionPresentation.affectsActions(away))
    #expect(store.state.activeTabId("w") == "a")
    lifecycle.reconcileContext(away)
    lifecycle.reconcileContext(back)
    #expect(lifecycle.open == nil)

    let newer = lifecycle.begin(shown, extensionId: "ext", revision: store.rev)
    lifecycle.reconcileContext(away)
    #expect(lifecycle.pending == newer)
    let openedAfterRoundTrip = lifecycle.finish(newer, source: shown, eligible: true)
    #expect(openedAfterRoundTrip)
    lifecycle.reconcileContext(away)
    #expect(lifecycle.open == newer)
  }

  @Test func activeAdmissionAndPopupURLValidationKeepFirstClickPolicy() {
    #expect(ExtensionPopupLifecycle.admits(requiresActive: false, key: false, active: false))
    #expect(!ExtensionPopupLifecycle.admits(requiresActive: true, key: false, active: true))
    #expect(!ExtensionPopupLifecycle.admits(requiresActive: true, key: true, active: false))
    #expect(ExtensionPopupLifecycle.admits(requiresActive: true, key: true, active: true))
    #expect(ExtensionPopupLifecycle.validURL("chrome-extension://abc/popup.html", extensionId: "abc"))
    #expect(!ExtensionPopupLifecycle.validURL("https://abc/popup.html", extensionId: "abc"))
    #expect(!ExtensionPopupLifecycle.validURL("chrome-extension://other/popup.html", extensionId: "abc"))
  }
}
