import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeAppIntegration {
  static let shared = NativeAppIntegration()
  static var active: Bool { shared.started }
  static let handoffDelay: TimeInterval = 0.25
  static let firstHandoffDelay: TimeInterval = 1

  private var handoff = HandoffTracker()
  private var handoffQueued = false
  private var started = false
  private var retryInFlight = false
  private var scriptRev = -1
  private var scriptLoading: Set<String> = []

  private static var storeStatus: AppIntegrationStoreStatus {
    AppIntegrationPolicy.storeStatus(
      opened: NativeStoreHandle.opened, ownsWorkspace: NativeStoreHandle.ownedWorkspaceAtLaunch,
      storeAvailable: NativeStoreHandle.store != nil, failureReason: NativeSettingsHandle.unavailable?.detail)
  }

  private init() {
    ShellScripting.availabilityError = {
      MainActor.assumeIsolated {
        AppIntegrationPolicy.scriptError(
          storeStatus: Self.storeStatus, handlerAvailable: ShellScripting.nativeCommand != nil, productName: Bundle.main.productName)
      }
    }
    for action in AppIntegrationMenuAction.allCases {
      NativeMenuCommands.handlers[action.rawValue] = { windowId in _ = NativeAppIntegration.shared.perform(action.rawValue, windowId: windowId) }
    }
  }

  func startWhenReady(tries: Int = 40) {
    guard !started, !retryInFlight else { return }
    retryInFlight = true
    continueStartup(tries: tries)
  }

  private func continueStartup(tries: Int) {
    let readiness = AppIntegrationPolicy.readiness(storeStatus: Self.storeStatus)
    switch readiness {
    case .waiting:
      guard tries > 0 else {
        retryInFlight = false
        return NSLog("[services] the native store never became ready for app integration")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.continueStartup(tries: tries - 1) }
      return
    case .unavailable:
      retryInFlight = false
      return
    case .ready:
      break
    }
    retryInFlight = false
    guard let store = NativeStoreHandle.store else { return }
    started = true
    let writer = StoreWorkspaceWriter(store: store, showWindow: ShellScripting.showWindow)
    let pages = PoolScriptPages(
      page: { TabPoolHost.shared.pageView($0) },
      invoke: { page, method, args, done in
        PageCalls.run(page, method, args, resolve: { done($0, nil) }, reject: { _, message in done(nil, message) })
      })
    ShellScripting.nativeCommand = { body, done in
      MainActor.assumeIsolated {
        ScriptCommandRunner(writer: writer, pages: pages).run(body) { reply in
          switch reply {
          case .result(let result): done(result, nil)
          case .failure(let message): done(nil, message)
          }
        }
      }
    }
    ShellScripting.refresh = { MainActor.assumeIsolated { NativeAppIntegration.shared.refreshScriptState() } }
    store.subscribe { commit in
      guard AppIntegrationPolicy.handoffNeedsUpdate(commit.changes) else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeAppIntegration.shared.queueHandoff() } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstHandoffDelay) { self.syncHandoff() }
  }

  func perform(_ command: String, windowId: String?) -> Bool {
    AppIntegrationPolicy.performMenuCommand(command, storeStatus: Self.storeStatus) { action, status in
      switch action {
      case .sendFeedback: sendFeedback(windowId, storeStatus: status)
      case .copyDiagnostics: Self.copy(diagnostics(storeStatus: status))
      case .recordPerformanceIssue: recordPerformanceIssue()
      case .taskManager: SolaraCoreServices.call("ac_task_manager_open", profile: "", args: nil) { @Sendable _ in }
      }
    }
  }

  private func queueHandoff() {
    guard !handoffQueued else { return }
    handoffQueued = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffDelay) {
      self.handoffQueued = false
      self.syncHandoff()
    }
  }

  private func syncHandoff() {
    guard let state = NativeStoreHandle.store?.state else { return }
    for change in handoff.changes(state) { Handoff.setActivity(windowId: change.windowId, url: change.url, title: change.title) }
  }

  private func refreshScriptState() {
    guard let store = NativeStoreHandle.store else { return }
    let (rev, state) = store.snapshot
    let loading = ShellScripting.loadingTabs
    guard rev != scriptRev || loading != scriptLoading else { return }
    scriptRev = rev
    scriptLoading = loading
    ShellScripting.setState(ScriptState.build(state, loading: loading))
  }

  func diagnostics(storeStatus: AppIntegrationStoreStatus? = nil) -> String {
    let status = storeStatus ?? Self.storeStatus
    let state = status == .ready ? NativeStoreHandle.store?.state : nil
    return AppDiagnostics.report(
      app: AppFacts(AppModule.systemInfo), engine: SolaraCoreHost.engineInfo,
      updates: UpdaterFacts(AppUpdater.shared.state), state: state, storeStatus: status)
  }

  func feedbackTarget(storeStatus: AppIntegrationStoreStatus? = nil) -> FeedbackTarget {
    AppDiagnostics.feedback(report: diagnostics(storeStatus: storeStatus), app: AppFacts(AppModule.systemInfo))
  }

  func sendFeedback(_ windowId: String?, storeStatus: AppIntegrationStoreStatus? = nil) {
    switch feedbackTarget(storeStatus: storeStatus) {
    case .page(let url):
      openTab(url, in: windowId)
    case .mail(let draft, let body):
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[services] background instance, not opening the feedback mail draft") }
      if !(URL(string: draft).map { NSWorkspace.shared.open($0) } ?? false) { Self.copy(body) }
    }
  }

  private func openTab(_ url: String, in windowId: String?) {
    guard Self.storeStatus == .ready, let store = NativeStoreHandle.store else {
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[services] background instance, not opening the feedback page") }
      if let target = URL(string: url) { NSWorkspace.shared.open(target) }
      return
    }
    let state = store.state
    if let target = state.resolveWindowId(windowId), state.windows[target]?.incognito != true {
      _ = try? store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
    } else {
      _ = try? store.dispatch(Command("createWindow", [["url": .string(url)]]), origin: .native)
    }
  }

  private func recordPerformanceIssue() {
    guard !SolaraCoreHost.isTracing else { return }
    let name = AppFacts(AppModule.systemInfo).appName.jsTrim()
    let product = name.isEmpty ? "Solara" : name
    guard Self.confirm(
      "Record a performance issue?",
      "\(product) records what the engine does while you reproduce the problem. The recording is saved to your Downloads folder.",
      confirm: "Start Recording")
    else { return }
    SolaraCoreHost.beginTracing { started in
      guard started else { return }
      let keep = Self.confirm("Recording…", "Reproduce the problem now, then click Stop.", confirm: "Stop", cancel: "Discard")
      SolaraCoreHost.endTracing(keep: keep) { path in
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[services] recording saved to %@", path) }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
    }
  }

  private static func confirm(_ title: String, _ message: String, confirm: String, cancel: String = "Cancel") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
