import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct AppIntegrationPolicyTests {
  @Test func readinessCanRecoverAfterAnEarlyProbe() {
    #expect(AppIntegrationPolicy.readiness(opened: false, ownsWorkspace: false, storeAvailable: false) == .waiting)
    #expect(AppIntegrationPolicy.readiness(opened: true, ownsWorkspace: true, storeAvailable: false) == .waiting)
    #expect(AppIntegrationPolicy.readiness(opened: true, ownsWorkspace: true, storeAvailable: true) == .ready)
    #expect(AppIntegrationPolicy.readiness(opened: true, ownsWorkspace: false, storeAvailable: true) == .unavailable)
  }

  private var unopened: AppIntegrationStoreStatus {
    AppIntegrationPolicy.storeStatus(opened: false, ownsWorkspace: false, storeAvailable: false, failureReason: "database refused")
  }

  @Test func diagnosticsRunsWithTheStoreNotOpened() {
    var report: String?
    let handled = AppIntegrationPolicy.performMenuCommand("copyDiagnostics", storeStatus: unopened) { action, status in
      #expect(action == .copyDiagnostics)
      report = AppDiagnostics.report(app: AppFacts(), chromiumVersion: "156", updates: nil, state: nil, storeStatus: status)
    }
    #expect(handled)
    #expect(report?.contains("store: not open\nfailed to open: database refused") == true)
    #expect(report?.contains("Engine: SolaraCore, Chromium 156") == true)
  }

  @Test func feedbackRunsWithTheStoreNotOpened() {
    var target: FeedbackTarget?
    let handled = AppIntegrationPolicy.performMenuCommand("sendFeedback", storeStatus: unopened) { action, status in
      #expect(action == .sendFeedback)
      let report = AppDiagnostics.report(app: AppFacts(), chromiumVersion: "156", updates: nil, state: nil, storeStatus: status)
      target = AppDiagnostics.feedback(report: report, app: AppFacts())
    }
    #expect(handled)
    guard case .mail(_, let body) = target else { Issue.record("expected feedback draft"); return }
    #expect(body.contains("store: not open\nfailed to open: database refused"))
  }

  @Test func performanceRecordingRunsWithTheStoreNotOpened() {
    var requested = false
    let handled = AppIntegrationPolicy.performMenuCommand("recordPerformanceIssue", storeStatus: unopened) { action, status in
      #expect(action == .recordPerformanceIssue)
      #expect(status == .failed("database refused"))
      requested = true
    }
    #expect(handled)
    #expect(requested)
  }

  @Test func taskManagerRunsWithTheStoreNotOpened() {
    var requested = false
    let handled = AppIntegrationPolicy.performMenuCommand("taskManager", storeStatus: unopened) { action, status in
      #expect(action == .taskManager)
      #expect(status == .failed("database refused"))
      requested = true
    }
    #expect(handled)
    #expect(requested)
  }

  @Test func actionsAlsoRunWhileOpeningAndWithoutWorkspaceOwnership() {
    for status in [AppIntegrationStoreStatus.opening, .notOwned] {
      var performed: [AppIntegrationMenuAction] = []
      for action in AppIntegrationMenuAction.allCases {
        let handled = AppIntegrationPolicy.performMenuCommand(action.rawValue, storeStatus: status) { command, received in
          performed.append(command)
          #expect(received == status)
        }
        #expect(handled)
      }
      #expect(performed == [.sendFeedback, .copyDiagnostics, .recordPerformanceIssue, .taskManager, .reportBug])
      #expect(!AppIntegrationPolicy.performMenuCommand("newTab", storeStatus: status) { _, _ in Issue.record("unexpected action") })
    }
  }

  @Test func appleScriptReturnsAClearErrorWithTheStoreNotOpened() {
    #expect(AppIntegrationPolicy.scriptError(storeStatus: unopened, handlerAvailable: false, productName: "Solara") ==
      "Solara isn't ready yet: store: not open; failed to open: database refused.")
    #expect(AppIntegrationPolicy.scriptError(storeStatus: .opening, handlerAvailable: false, productName: "Solara") ==
      "Solara isn't ready yet: store: not open; still opening.")
    #expect(AppIntegrationPolicy.scriptError(storeStatus: .notOwned, handlerAvailable: false, productName: "Solara") ==
      "Solara isn't ready yet: store: not open; not owned because settingsAndDownloads is scoped off.")
    #expect(AppIntegrationPolicy.scriptError(storeStatus: .ready, handlerAvailable: false, productName: "Solara") == "Solara isn't ready yet.")
    #expect(AppIntegrationPolicy.scriptError(storeStatus: .ready, handlerAvailable: true, productName: "Solara") == nil)
  }

  @Test func storeStatusDistinguishesFailureScopeAndOpening() {
    #expect(unopened == .failed("database refused"))
    #expect(AppIntegrationPolicy.storeStatus(opened: false, ownsWorkspace: false, storeAvailable: false, failureReason: nil) == .opening)
    #expect(AppIntegrationPolicy.storeStatus(opened: true, ownsWorkspace: false, storeAvailable: true, failureReason: nil) == .notOwned)
    #expect(AppIntegrationPolicy.storeStatus(opened: true, ownsWorkspace: true, storeAvailable: false, failureReason: nil) == .opening)
    #expect(AppIntegrationPolicy.storeStatus(opened: true, ownsWorkspace: true, storeAvailable: true, failureReason: nil) == .ready)
  }

  @Test func handoffIgnoresUnrelatedCommits() {
    var changes = ChangeSet()
    #expect(!AppIntegrationPolicy.handoffNeedsUpdate(changes))
    changes.settingsChanged = ["appearance"]
    changes.profiles.upserted = ["p"]
    changes.lists = ["ui", "downloads", "caches", "profileOrder", "windowOrder"]
    changes.find.upserted = ["t"]
    #expect(!AppIntegrationPolicy.handoffNeedsUpdate(changes))
  }

  @Test func handoffQueuesForTabAndWindowChanges() {
    var changes = ChangeSet()
    changes.tabs.upserted = ["t"]
    #expect(AppIntegrationPolicy.handoffNeedsUpdate(changes))
    changes = ChangeSet()
    changes.tabs.removed = ["t"]
    #expect(AppIntegrationPolicy.handoffNeedsUpdate(changes))
    changes = ChangeSet()
    changes.windows.upserted = ["w"]
    #expect(AppIntegrationPolicy.handoffNeedsUpdate(changes))
    changes = ChangeSet()
    changes.windows.removed = ["w"]
    #expect(AppIntegrationPolicy.handoffNeedsUpdate(changes))
  }
}
