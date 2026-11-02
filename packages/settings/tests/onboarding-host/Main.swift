import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
final class HostFakeJoining: @preconcurrency PairingJoining {
  final class Handle: PairingJoinHandle {
    var cancellations = 0
    var cancelResult: PairingCancelResult = .cancelled
    @discardableResult func cancel() -> PairingCancelResult { cancellations += 1; return cancelResult }
    func startAgain() {}
  }
  var callbacks: [@MainActor (PairingJoinState) -> Void] = []
  var cancelResult: PairingCancelResult = .cancelled
  var committedResult = false
  var committedState: PairingJoinState?
  var committedCallbacks: [@MainActor (PairingJoinState) -> Void] = []
  var handles: [Handle] = []
  func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool {
    committedCallbacks.append(onState)
    if committedResult, let committedState { onState(committedState) }
    return committedResult
  }
  func emitCommitted(_ state: PairingJoinState) {
    committedCallbacks.last?(state)
  }
  func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    callbacks.append(onState)
    let handle = Handle()
    handle.cancelResult = cancelResult
    handles.append(handle)
    return handle
  }
  func emit(_ state: PairingJoinState) { callbacks.last?(state) }
}

@MainActor
final class HostOnboardingScheduler: OnboardingScheduler {
  final class Scheduled: OnboardingScheduledTask {
    let deadline: ContinuousClock.Instant
    let action: @MainActor () -> Void
    var cancelled = false
    init(deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) {
      self.deadline = deadline
      self.action = action
    }
    func cancel() { cancelled = true }
  }
  var now = ContinuousClock.now
  var scheduled: [Scheduled] = []
  func schedule(at deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) -> OnboardingScheduledTask {
    let task = Scheduled(deadline: deadline, action: action)
    scheduled.append(task)
    return task
  }
  func advance(by duration: Duration) {
    now += duration
    let ready = scheduled.filter { $0.deadline <= now }
    scheduled.removeAll { $0.deadline <= now }
    for task in ready where !task.cancelled { task.action() }
  }
}

@main
struct HostRegressionTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let test = CommandLine.arguments[1]
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let settings = SettingsModel(store: Store())
    switch test {
    case "dismissalKeepsOwnPresentationId":
      NativeSettingsHandle.model = settings
      NativeOnboarding.register()
      var events: [[String: Any]] = []
      _ = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { events.append($0) }
      NativeAppStartup.shared.complete()
      _ = NativeAppStartup.shared.perform("showOnboarding", windowId: "B")
      let firstId = events.last?["requestId"] as? String ?? ""
      let first = HostedViews.make("onboarding", windowId: "B", state: firstId)
      _ = NativeAppStartup.shared.perform("showOnboarding", windowId: "B")
      let secondId = events.last?["requestId"] as? String ?? ""
      let second = HostedViews.make("onboarding", windowId: "B", state: secondId)
      expect(!firstId.isEmpty && !secondId.isEmpty && firstId != secondId, "the two mounted presentations must have distinct IDs")
      let firstRoot = (first?.view as? NSHostingView<OnboardingHostedRoot>)?.rootView
      let secondRoot = (second?.view as? NSHostingView<OnboardingHostedRoot>)?.rootView
      expect(firstRoot != nil && secondRoot != nil, "the production session must supply each hosted dismissal callback")
      firstRoot?.onDismiss()
      for _ in 0..<80 { await Task.yield() }
      secondRoot?.onDismiss()
      for _ in 0..<80 { await Task.yield() }
      let dismissals = SettingsJS.shared.invocations.filter { $0.name == "onboarding.dismissed" }
      expect(dismissals.count == 2, "both production session callbacks must reach the JS transport")
      if dismissals.count == 2 {
        expect(dismissals[0].arguments.first as? String == "B", "the old dismissal must preserve its host window")
        expect(dismissals[0].arguments.count == 2 && dismissals[0].arguments[1] as? String == firstId, "request 1 dismissal must carry its own ID after request 2 mounts")
        expect(dismissals[1].arguments.count == 2 && dismissals[1].arguments[1] as? String == secondId, "request 2 dismissal must carry its own ID")
      }
      first?.onUnmount()
      second?.onUnmount()
      firstRoot?.onDismiss()
      for _ in 0..<40 { await Task.yield() }
      expect(SettingsJS.shared.invocations.filter { $0.name == "onboarding.dismissed" }.count == 2, "an ended session must not emit another dismissal")
    case "automaticDismissalHasNoPresentationId":
      let host = OnboardingSession(windowId: "B", settings: settings)
      let root = (host.view as? NSHostingView<OnboardingHostedRoot>)?.rootView
      expect(root != nil, "the automatic production session must supply a hosted dismissal callback")
      root?.onDismiss()
      for _ in 0..<80 { await Task.yield() }
      let dismissals = SettingsJS.shared.invocations.filter { $0.name == "onboarding.dismissed" }
      expect(dismissals.count == 1, "automatic session dismissal must reach the JS transport")
      if let dismissal = dismissals.first {
        expect(dismissal.arguments.first as? String == "B", "automatic dismissal must preserve its host window")
        expect(dismissal.arguments.count == 1 || (dismissal.arguments.count == 2 && (dismissal.arguments[1] is NSNull || dismissal.arguments[1] as? String == "")), "automatic dismissal must preserve the legacy absent presentation ID")
      }
      host.end()
    case "pendingBrowserEntryRemount", "failedBrowserEntryRemount", "pendingBrowserEntryReload", "failedBrowserEntryReload",
      "pendingInstallRemount", "failedInstallRemount", "pendingInstallReload", "failedInstallReload":
      let browserEntry = test.contains("BrowserEntry")
      let failed = test.hasPrefix("failed")
      let reload = test.hasSuffix("Reload")
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      let options: [String: Any] = [
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]
      _ = NativeAppStartup.shared.start(options) { _ in }
      let host = OnboardingSession(windowId: "join-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      host.model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.holdWrites = !browserEntry
      committed = "installed-token"
      joining.emit(.installed)
      for _ in 0..<40 { await Task.yield() }
      if browserEntry {
        expect(host.model.syncRoute == .joined, "installation must be acknowledged before browser entry")
        DocumentStore.holdWrites = true
        host.model.finishJoined()
        for _ in 0..<40 { await Task.yield() }
      }
      let staged = try! JSONValue.parse(DocumentStore.read("onboarding.json")!)
      expect(staged["joinedCompletionToken"]?.string == committed, "pending installation must be readable from DocumentStore")
      expect(staged["joinedEnteredBrowser"]?.bool == browserEntry, "DocumentStore must expose the staged browser-entry flag")
      expect(!DocumentStore.pending.isEmpty, "joined write must remain pending")
      if failed {
        DocumentStore.finishPending(CocoaError(.fileWriteOutOfSpace))
        for _ in 0..<40 { await Task.yield() }
        expect((try? JSONValue.parse(DocumentStore.read("onboarding.json")!)) == staged, "failed contents must remain staged")
        expect(host.model.syncRoute == .savingFailed, "live model must show retry after failure")
      }
      if reload {
        let payload = try! JSONValue.parse(NativeAppStartup.shared.start(options) { _ in })
        expect(payload["onboarding"]?.string == "resume", "JS reload must resume unacknowledged joined onboarding")
        let saved = try! JSONValue.parse(payload["savedJSON"]!.string!)
        expect(saved["joinedEnteredBrowser"]?.bool != true, "startup must not publish unacknowledged browser entry")
      } else {
        host.end()
        let remount = OnboardingSession(windowId: "join-window", settings: settings)
        for _ in 0..<40 { await Task.yield() }
        expect(remount.model.isActive, "remount must preserve the joined retry")
        expect(remount.model.syncRoute != .setup && remount.model.syncRoute != .discovering, "remount must offer joined recovery instead of setup")
        expect(remount.model.syncRoute != .joined, "remount must await acknowledgment before showing joined")
        DocumentStore.finishPending(nil)
        for _ in 0..<80 { await Task.yield() }
        DocumentStore.finishPending(nil)
        for _ in 0..<80 { await Task.yield() }
        expect(remount.model.syncRoute == .joined && !remount.model.leaving, "acknowledged recovery must offer browser entry")
        remount.end()
      }
      host.end()
    case "silentBrowserEntryRetryRemount", "silentBrowserEntryRetryReload", "silentBrowserEntryRetryThenInstalled", "installedBeforeBrowserEntryRetry":
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      let scheduler = HostOnboardingScheduler()
      let adapter = OnboardingAdapter(windowId: "join-window", settings: settings)
      let model = OnboardingModel(services: adapter, store: StoreSettingsSource(model: settings), appName: "Solara", scheduler: scheduler)
      model.start(windowId: "join-window", isFirstRunOnboarding: true)
      model.discoverSync()
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      joining.emit(.approved)
      scheduler.advance(by: .seconds(60))
      expect(model.syncRoute == .downloading, "approved join must offer early browser entry after 60 seconds")
      DocumentStore.holdWrites = true
      model.finishJoined()
      for _ in 0..<40 { await Task.yield() }
      let requested = try? JSONValue.parse(DocumentStore.read("onboarding.json") ?? "{}")
      let completion = requested?["completedAt"]?.number
      DocumentStore.finishPending(CocoaError(.fileWriteOutOfSpace))
      for _ in 0..<40 { await Task.yield() }
      expect(model.syncRoute == .savingFailed, "failed early browser entry must show retry")
      if test != "installedBeforeBrowserEntryRetry" {
        DocumentStore.landRetries()
      }
      if test == "silentBrowserEntryRetryRemount" {
        joining.committedResult = true
        joining.committedState = .approved
        model.leaveSetup()
        adapter.dispose()
        let remount = OnboardingSession(windowId: "join-window", settings: settings)
        for _ in 0..<40 { await Task.yield() }
        expect(!remount.model.isActive, "silently durable browser entry must keep an approved remount in the browser")
        remount.end()
      } else if test == "silentBrowserEntryRetryReload" {
        let payload = try! JSONValue.parse(NativeAppStartup.shared.start([
          "development": false, "persistenceRefused": false,
          "safeMode": false, "hostedOnboarding": true,
        ]) { _ in })
        expect(payload["onboarding"]?.string == "none", "silently durable browser entry must suppress automatic onboarding on reload")
        model.leaveSetup()
        adapter.dispose()
      } else {
        committed = "installed-token"
        joining.emit(.installed)
        for _ in 0..<40 { await Task.yield() }
        DocumentStore.finishPending(nil)
        for _ in 0..<80 { await Task.yield() }
        DocumentStore.landRetries()
        let durable = try? JSONValue.parse(DocumentStore.documents["onboarding.json"] ?? "{}")
        expect(durable?["joinedCompletionToken"]?.string == "installed-token", "installation must record its committed token")
        expect(durable?["joinedEnteredBrowser"]?.bool == true, "installation must preserve browser entry that may land through native retry")
        expect(completion != nil && durable?["completedAt"]?.number == completion, "installation must preserve the failed browser entry's completion time")
        model.leaveSetup()
        adapter.dispose()
      }
    case "showOnboardingReroutesClosedWindow", "automaticMountCannotTakeShowOnboarding", "nilWindowReplayRequiresPresentation":
      let joining = HostFakeJoining()
      joining.committedResult = true
      joining.committedState = .installed
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { "installed-token" }
      let finished = OnboardingSession(windowId: "A", settings: settings)
      for _ in 0..<80 { await Task.yield() }
      finished.model.finishJoined()
      for _ in 0..<80 { await Task.yield() }
      expect(finished.model.leaving, "finished join must acknowledge browser entry")
      finished.end()
      NativeSettingsHandle.model = settings
      NativeOnboarding.register()
      let options: [String: Any] = [
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]
      var events: [[String: Any]] = []
      _ = NativeAppStartup.shared.start(options) { events.append($0) }
      NativeAppStartup.shared.complete()
      NativeAppStartup.shared.disconnect()
      _ = NativeAppStartup.shared.perform("showOnboarding", windowId: test == "nilWindowReplayRequiresPresentation" ? nil : "A")
      expect(events.isEmpty, "disconnected presentation must remain queued")
      let presentedWindow = test == "automaticMountCannotTakeShowOnboarding" ? "A" : "B"
      var presented: HostedContent?
      _ = NativeAppStartup.shared.start(options) { event in
        guard event["action"] as? String == "showOnboarding" else { return }
        events.append(event)
        if test != "showOnboardingReroutesClosedWindow" {
          let automatic = HostedViews.make("onboarding", windowId: presentedWindow)
          let state = try! JSONValue.parse(NativeOnboarding.drive("state", nil))
          expect(state["active"]?.bool == false, "automatic mount before presentation must remain inactive")
          automatic?.onUnmount()
        }
        presented = HostedViews.make("onboarding", windowId: presentedWindow, state: event["requestId"] as? String ?? "")
      }
      NativeAppStartup.shared.complete()
      for _ in 0..<80 { await Task.yield() }
      expect(events.count == 1, "reconnect must deliver one explicit presentation")
      let state = try! JSONValue.parse(NativeOnboarding.drive("state", nil))
      expect(state["active"]?.bool == true, "presentation mount must open the replay on its resolved window")
      expect(state["step"]?.string == "intro", "presentation replay must open at intro")
      expect(state["windowId"]?.string == presentedWindow, "presentation must target the resolved mount window")
      presented?.onUnmount()
      for windowId in ["A", "B"] {
        let automatic = HostedViews.make("onboarding", windowId: windowId)
        for _ in 0..<80 { await Task.yield() }
        let state = try! JSONValue.parse(NativeOnboarding.drive("state", nil))
        expect(state["active"]?.bool == false, "no stale replay may remain for automatic mount of \(windowId)")
        automatic?.onUnmount()
      }
    case "supersededReplayCannotMount", "disconnectedReplayCannotMount", "unavailableReplayCannotMount":
      let joining = HostFakeJoining()
      joining.committedResult = true
      joining.committedState = .installed
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { "installed-token" }
      let finished = OnboardingSession(windowId: "A", settings: settings)
      for _ in 0..<80 { await Task.yield() }
      finished.model.finishJoined()
      for _ in 0..<80 { await Task.yield() }
      expect(finished.model.leaving, "finished join must acknowledge browser entry")
      finished.end()
      NativeSettingsHandle.model = settings
      NativeOnboarding.register()
      var events: [[String: Any]] = []
      _ = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { events.append($0) }
      NativeAppStartup.shared.complete()
      _ = NativeAppStartup.shared.perform("showOnboarding", windowId: "A")
      let oldId = events.last?["requestId"] as? String ?? ""
      expect(!oldId.isEmpty, "each explicit presentation must carry a request ID")
      if test == "supersededReplayCannotMount" {
        _ = NativeAppStartup.shared.perform("showOnboarding", windowId: "A")
        expect(events.last?["requestId"] as? String != oldId, "superseding presentation must have a fresh ID")
      } else if test == "disconnectedReplayCannotMount" {
        NativeAppStartup.shared.disconnect()
      } else {
        NativeSettingsHandle.model = nil
        expect(HostedViews.make("onboarding", windowId: "A", state: oldId) == nil, "unavailable host must reject presentation")
        NativeSettingsHandle.model = settings
      }
      let stale = HostedViews.make("onboarding", windowId: "A", state: oldId)
      for _ in 0..<80 { await Task.yield() }
      expect((try! JSONValue.parse(NativeOnboarding.drive("state", nil)))["active"]?.bool == false, "stale presentation must not replay")
      stale?.onUnmount()
      if test == "supersededReplayCannotMount" {
        let current = HostedViews.make("onboarding", windowId: "B", state: events.last?["requestId"] as? String ?? "")
        for _ in 0..<80 { await Task.yield() }
        expect((try! JSONValue.parse(NativeOnboarding.drive("state", nil)))["active"]?.bool == true, "stale mount must leave the current replay available")
        current?.onUnmount()
      }
    case "showOnboardingAfterFinishedCommittedJoin":
      let joining = HostFakeJoining()
      joining.committedResult = true
      joining.committedState = .installed
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { "installed-token" }
      let finished = OnboardingSession(windowId: "join-window", settings: settings)
      for _ in 0..<80 { await Task.yield() }
      finished.model.finishJoined()
      for _ in 0..<80 { await Task.yield() }
      expect(finished.model.leaving, "finished join must acknowledge browser entry")
      finished.end()
      let automatic = OnboardingSession(windowId: "join-window", settings: settings)
      for _ in 0..<80 { await Task.yield() }
      expect(!automatic.model.isActive, "automatic remount must preserve a finished join's browser entry")
      automatic.end()
      NativeSettingsHandle.model = settings
      NativeOnboarding.register()
      var requested: HostedContent?
      _ = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { event in
        if event["action"] as? String == "showOnboarding" {
          requested = HostedViews.make("onboarding", windowId: event["windowId"] as? String ?? "", state: event["requestId"] as? String ?? "")
        }
      }
      NativeAppStartup.shared.complete()
      _ = NativeAppStartup.shared.perform("showOnboarding", windowId: "requested-window")
      for _ in 0..<80 { await Task.yield() }
      let replay = try! JSONValue.parse(NativeOnboarding.drive("state", nil))
      expect(replay["active"]?.bool == true, "explicit Show Onboarding must open after a finished committed join")
      expect(replay["step"]?.string == "intro", "explicit Show Onboarding must begin the tour at intro")
      let replayModel = (requested?.view as? NSHostingView<OnboardingHostedRoot>)?.rootView.model
      expect(replayModel?.syncRoute == .setup, "explicit Show Onboarding must open the setup tour")
      requested?.onUnmount()
      let subsequent = OnboardingSession(windowId: "requested-window", settings: settings)
      for _ in 0..<80 { await Task.yield() }
      expect(!subsequent.model.isActive, "explicit replay request must be consumed by its first host mount")
      subsequent.end()
    case "firstLaunchStartupKeepsIntroAndHostWindow":
      let raw = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { _ in }
      let payload = try! JSONValue.parse(raw)
      expect(payload["onboarding"]?.string == "start", "native startup should admit first launch")
      let saved = try! JSONValue.parse(DocumentStore.read("onboarding.json")!)
      expect(saved["startedAt"]?.number != nil, "startup must persist startedAt before mount")
      let host = OnboardingSession(windowId: "launch-window", settings: settings)
      expect(host.model.syncRoute == .discovering, "first card must wait for discovery")
      OnboardingDiscoveryAdapter.callbacks.last?(.empty)
      expect(host.model.step == .intro, "first launch should reveal intro, got \(host.model.step)")
      expect(host.model.windowId == "launch-window", "intro must target mounting window")
      await Task.yield()
      expect(SettingsJS.shared.calls.contains("onboarding.endToolTour"), "forced start must end the previous tool tour")
      host.end()
    case "showOnboardingWithOnlySessionForcesIntro":
      DocumentStore.documents["session.json"] = "{}"
      let host = OnboardingSession(windowId: "requested-window", settings: settings)
      expect(host.model.isActive, "explicit host mount must force onboarding")
      expect(host.model.windowId == "requested-window", "explicit host window must be honored")
      expect(host.model.syncRoute == .setup, "session-only explicit replay must remain in setup")
      expect(!host.model.isFirstRunOnboarding, "session-only explicit replay must not be treated as first run")
      expect(OnboardingDiscoveryAdapter.callbacks.isEmpty, "session-only explicit replay must not discover")
      OnboardingDiscoveryAdapter.callbacks.last?(.empty)
      expect(host.model.step == .intro, "explicit setup should start at intro")
      let saved = try! JSONValue.parse(DocumentStore.read("onboarding.json") ?? "{}")
      expect(saved["completedAt"]?.number == nil, "mount must not write completion merely because session exists")
      host.end()
    case "savedIntroRestartsIntro":
      DocumentStore.documents["onboarding.json"] = "{\"version\":1,\"startedAt\":1,\"step\":\"intro\"}"
      let host = OnboardingSession(windowId: "intro-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.empty)
      expect(host.model.step == .intro, "saved intro must retain intro")
      expect(host.model.windowId == "intro-window", "saved intro must honor mounting window")
      await Task.yield()
      expect(SettingsJS.shared.calls.contains("onboarding.endToolTour"), "saved intro forced start must end tool tour")
      host.end()
    case "folderAdapterAdmitsChangeAfterSelection":
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      let original = adapter.onboardingSyncFolder
      var admitted = false
      let selection = Task { await adapter.chooseOnboardingFolder { admitted = true; return true } }
      for _ in 0..<20 where SyncAdapter.folderChoice == nil { await Task.yield() }
      expect(SyncAdapter.folderChoice != nil, "folder panel must remain pending")
      expect(!admitted, "pairing cancellation must wait for a selection")
      expect(adapter.onboardingSyncFolder == original, "folder must remain unchanged during selection")
      SyncAdapter.folderChoice?.resume(returning: "/scratch/selected-sync")
      SyncAdapter.folderChoice = nil
      let changed = await selection.value
      expect(changed, "selected folder must be accepted")
      expect(admitted, "change must admit cancellation")
      expect(adapter.onboardingSyncFolder == "/scratch/selected-sync", "selection must update discovery folder")
      adapter.dispose()
    case "folderAdapterRejectsStaleSelection":
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      let original = adapter.onboardingSyncFolder
      let selection = Task { await adapter.chooseOnboardingFolder { false } }
      for _ in 0..<20 where SyncAdapter.folderChoice == nil { await Task.yield() }
      SyncAdapter.folderChoice?.resume(returning: "/scratch/stale-selection")
      SyncAdapter.folderChoice = nil
      let changed = await selection.value
      expect(!changed, "stale selection must be rejected")
      expect(adapter.onboardingSyncFolder == original, "stale selection must not update discovery folder")
      adapter.dispose()
    case "recoveryWithoutHostReportsUnavailable":
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      expect(!adapter.openOnboardingRecoveryPhrase(), "missing native host must report presentation failure")
      adapter.dispose()
    case "importCancellationDrainsThroughProductionAdapter":
      let importer = NativeImportWindow()
      NativeImportWindow.current = importer
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      adapter.cancelOnboardingImport()
      expect(importer.disposed, "native import task must be disposed")
      expect(ImportAdapter.closes == 1, "import window must be closed")
      do { try await adapter.drainOnboardingPreviews() }
      catch { failures.append("import cancellation drain failed: \(error)") }
      expect(SettingsJS.shared.calls.contains("import.cancelAndDrain"), "adapter drain must acknowledge JS import cancellation")
      adapter.dispose()
    case "replacementCommittedInstallDoesNotReuseOldBrowserEntry":
      let joining = HostFakeJoining()
      joining.committedResult = true
      joining.committedState = .installed
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { "replacement-token" }
      NativeSettingsHandle.model = settings
      DocumentStore.documents["onboarding.json"] = #"{"version":1,"startedAt":1,"completedAt":100,"joinedCompletionToken":"old-token","joinedEnteredBrowser":true}"#
      let raw = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { _ in }
      let payload = try! JSONValue.parse(raw)
      expect(payload["onboarding"]?.string == "resume", "a different committed join must resume its joined route")
      expect(joining.committedCallbacks.count == 1, "launch must observe a replacement committed join")
      for _ in 0..<80 { await Task.yield() }
      let saved = try? JSONValue.parse(DocumentStore.read("onboarding.json") ?? "{}")
      expect(saved?["joinedCompletionToken"]?.string == "replacement-token", "replacement completion must be recorded")
      expect(saved?["joinedEnteredBrowser"]?.bool == false, "an older join's browser entry must not complete a replacement join")
      expect(saved?["completedAt"]?.number == 100, "replacement completion must preserve completion time")
    case "launchCommittedJoinWithoutOnboardingMount":
      let joining = HostFakeJoining()
      joining.committedResult = true
      joining.committedState = .approved
      var committed: String? = "admitted-token"
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      NativeSettingsHandle.model = settings
      DocumentStore.documents["onboarding.json"] = #"{"version":1,"startedAt":1,"completedAt":100,"joinedEnteredBrowser":true}"#
      let raw = NativeAppStartup.shared.start([
        "development": false, "persistenceRefused": false,
        "safeMode": false, "hostedOnboarding": true,
      ]) { _ in }
      let payload = try! JSONValue.parse(raw)
      expect(payload["onboarding"]?.string == "none", "early browser entry must suppress onboarding at launch")
      expect(joining.committedCallbacks.count == 1, "launch must consult committedJoin without mounting onboarding")
      committed = "installed-token"
      joining.emitCommitted(.installed)
      for _ in 0..<80 { await Task.yield() }
      let saved = try? JSONValue.parse(DocumentStore.read("onboarding.json") ?? "{}")
      expect(saved?["joinedCompletionToken"]?.string == "installed-token", "background launch listener must record installed")
      expect(saved?["joinedEnteredBrowser"]?.bool == true, "background completion must preserve browser entry")
      expect(saved?["completedAt"]?.number == 100, "background completion must preserve completion time")
    case "approvedInstallSurvivesHostUnmount":
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      var host: OnboardingSession? = OnboardingSession(windowId: "join-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      host?.model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      joining.emit(.approved)
      expect(host?.model.syncRoute == .joining(.approved), "pairing must reach approved, got \(String(describing: host?.model.syncRoute))")
      weak let retainedModel = host?.model
      joining.committedResult = true
      host?.end()
      expect(joining.committedCallbacks.count >= 2, "unmount must hand over to committedJoin")
      expect(retainedModel?.isActive == false, "unmount must detach the approved model from its window")
      host = nil
      for _ in 0..<40 { await Task.yield() }
      expect(retainedModel == nil, "hand-over must release the model before a terminal state")
      committed = "installed-token"
      joining.emitCommitted(.installed)
      for _ in 0..<40 { await Task.yield() }
      let saved = try? JSONValue.parse(DocumentStore.read("onboarding.json") ?? "{}")
      expect(saved?["joinedCompletionToken"]?.string == "installed-token", "an install admitted before unmount must still record its completion")
      expect(saved?["joinedEnteredBrowser"]?.bool == false, "an unmounted install must not enter the browser")
      expect(retainedModel == nil, "the installed callback must release its model after persistence")
    case "joinedCompletionWaitsForTheDurableWrite":
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      let host = OnboardingSession(windowId: "join-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      host.model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.holdWrites = true
      committed = "installed-token"
      joining.emit(.installed)
      for _ in 0..<40 { await Task.yield() }
      expect(DocumentStore.pending.contains { $0.name == "onboarding.json" }, "the completion write must be issued")
      expect(host.model.syncRoute != .joined, "joined must wait for the durable completion write, got \(host.model.syncRoute)")
      DocumentStore.finishPending(CocoaError(.fileWriteOutOfSpace))
      for _ in 0..<40 { await Task.yield() }
      expect(host.model.syncRoute == .savingFailed, "a failed completion write must show savingFailed, got \(host.model.syncRoute)")
      host.end()
    case "joinedWriteWaitsForSuccessfulAcknowledgment":
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      DocumentStore.holdWrites = true
      var acknowledged = false
      let write = Task {
        do {
          try await adapter.writeJoinedOnboardingDocument("{}")
          acknowledged = true
        } catch { failures.append("successful write failed: \(error)") }
      }
      for _ in 0..<40 { await Task.yield() }
      expect(!DocumentStore.pending.isEmpty, "the adapter must issue the completion write")
      expect(!acknowledged, "the adapter must suspend until done succeeds")
      DocumentStore.finishPending(nil)
      await write.value
      expect(acknowledged, "successful done must resume the adapter")
      adapter.dispose()
    case "joinedWritePropagatesImmediateFailure":
      let adapter = OnboardingAdapter(windowId: "w1", settings: settings)
      DocumentStore.writeError = CocoaError(.fileWriteNoPermission)
      do {
        try await adapter.writeJoinedOnboardingDocument("{}")
        failures.append("a thrown DocumentStore error must fail the adapter write")
      } catch {
        expect((error as? CocoaError)?.code == .fileWriteNoPermission, "the adapter must preserve the thrown error")
      }
      adapter.dispose()
    case "failedStagedBrowserEntryCanBeRetried":
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      let host = OnboardingSession(windowId: "join-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      host.model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      committed = "installed-token"
      joining.emit(.installed)
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.holdWrites = true
      host.model.finishJoined()
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.finishPending(CocoaError(.fileWriteOutOfSpace))
      for _ in 0..<40 { await Task.yield() }
      expect(host.model.syncRoute == .savingFailed, "failed staged browser entry must report savingFailed")
      host.model.finishJoined()
      for _ in 0..<40 { await Task.yield() }
      expect(DocumentStore.pending.count == 1, "retry must issue a fresh write even when the failed document remains readable")
      expect(!host.model.leaving, "retry must still wait for acknowledgment")
      DocumentStore.finishPending(nil)
      for _ in 0..<40 { await Task.yield() }
      expect(host.model.syncRoute == .joined && host.model.leaving, "acknowledged retry must enter the browser")
      host.end()
    case "failedStagedInstallIsAcknowledgedOnRecovery":
      let joining = HostFakeJoining()
      var committed: String?
      OnboardingPairingServices.joining = { _ in joining }
      OnboardingPairingServices.committedJoinToken = { committed }
      let host = OnboardingSession(windowId: "join-window", settings: settings)
      OnboardingDiscoveryAdapter.callbacks.last?(.found([OnboardingDiscoveryCandidate(cid: "first", lastActivity: nil)]))
      host.model.pairWithAnotherMac()
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.holdWrites = true
      committed = "installed-token"
      joining.emit(.installed)
      for _ in 0..<40 { await Task.yield() }
      DocumentStore.finishPending(CocoaError(.fileWriteOutOfSpace))
      for _ in 0..<40 { await Task.yield() }
      expect(host.model.syncRoute == .savingFailed, "failed staged install must report savingFailed")
      host.model.maybeStart()
      for _ in 0..<40 { await Task.yield() }
      expect(DocumentStore.pending.count == 1, "recovery must acknowledge the staged install before showing joined")
      expect(host.model.syncRoute != .joined, "staged contents alone cannot complete recovery")
      DocumentStore.finishPending(nil)
      for _ in 0..<40 { await Task.yield() }
      expect(host.model.syncRoute == .joined && !host.model.leaving, "acknowledged recovery must show joined without browser entry")
      host.end()
    default:
      failures.append("unknown test \(test)")
    }
    for failure in failures { print("FAIL \(test): \(failure)") }
    if failures.isEmpty { print("PASS \(test)") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
