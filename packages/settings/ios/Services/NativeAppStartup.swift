import AppKit
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeAppStartup {
  static let shared = NativeAppStartup()
  private var installed = false
  private var result: String?
  private var completed = false
  private var offered = false
  private var updated = false
  private var development = false
  private var presentation: (([String: Any]) -> Void)?
  private var pending: [[String: Any]] = []
  private var onboardingRequestId: String?
  private var onboardingExpiry: Task<Void, Never>?

  private init() {}

  func install() {
    guard !installed else { return }
    installed = true
    for command in ["showOnboarding", "toolTour", "videoTour", "releaseNotes"] {
      NativeMenuCommands.handlers[command] = { windowId in _ = Self.shared.perform(command, windowId: windowId) }
    }
  }

  private func onboardingSaved() -> JSONValue? {
    let saved = read("onboarding.json")
    guard let token = OnboardingPairingServices.committedJoinToken?() else { return saved }
    if saved?["joinedEnteredBrowser"]?.bool == true, saved?["joinedCompletionToken"]?.string == nil { return saved }
    guard saved?["joinedCompletionToken"]?.string != token || saved?["joinedEnteredBrowser"]?.bool != true else { return saved }
    return .object(AppStartupPolicy.onboardingDocument(saved: saved, patch: [
      "startedAt": saved?["startedAt"] ?? .number(Self.now),
      "joinedCompletionToken": .string(token),
      "joinedEnteredBrowser": false,
    ]))
  }

  func start(_ options: [String: Any], presentation: @escaping ([String: Any]) -> Void) -> String {
    install()
    self.presentation = presentation
    development = options["development"] as? Bool ?? false
    let refused = options["persistenceRefused"] as? Bool ?? true
    let safeMode = options["safeMode"] as? Bool ?? true
    let version = AppModule.systemInfo["appVersion"] as? String ?? ""
    let versions = Set(options["releaseNotesVersions"] as? [String] ?? [])
    let hasSession = !(DocumentStore.read("session.json") ?? "").isEmpty
    let hosted = options["hostedOnboarding"] as? Bool ?? false
    if result == nil, !refused, !safeMode, hosted { NativeOnboarding.resumeCommittedJoinAtLaunch() }
    if !hosted { NSLog("[appIntegration] automatic onboarding unavailable: native onboarding host is off") }
    if result != nil {
      let saved = onboardingSaved()
      let decision = AppStartupPolicy.onboarding(
        saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
        hosted: hosted, development: development, force: Self.debugEnvironment("SOLARA_ONBOARDING"),
        committedJoinToken: OnboardingPairingServices.committedJoinToken?())
      let pending = AppStartupPolicy.version(
        current: version, saved: read("release-notes.json"), hasSession: hasSession, refused: refused,
        safeMode: true, development: true, forcePostcard: false, now: Self.now, knownVersions: versions).pending
      return JSONValue.object([
        "pendingJSON": !version.isEmpty && !refused ? .string(pending.text()) : .null,
        "onboarding": .string(decision == .resume ? "resume" : "none"),
        "savedJSON": saved.map { .string($0.text()) } ?? .null,
      ]).text()
    }
    let tracked = AppStartupPolicy.version(
      current: version, saved: read("release-notes.json"), hasSession: hasSession, refused: refused,
      safeMode: safeMode, development: development, forcePostcard: Self.debugEnvironment("SOLARA_WHATS_NEW"),
      now: Self.now, knownVersions: versions)
    updated = tracked.updated
    if let document = tracked.document { save("release-notes.json", document) }
    let saved = onboardingSaved()
    let onboarding = AppStartupPolicy.onboarding(
      saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
      hosted: hosted,
      development: development, force: Self.debugEnvironment("SOLARA_ONBOARDING"),
        committedJoinToken: OnboardingPairingServices.committedJoinToken?())
    var action = "none"
    switch onboarding {
    case .none: break
    case .start:
      save("onboarding.json", AppStartupPolicy.onboardingDocument(saved: saved, patch: ["startedAt": .number(Self.now)]))
      action = "start"
    case .resume: action = "resume"
    case .complete:
      save("onboarding.json", AppStartupPolicy.onboardingDocument(saved: saved, patch: ["completedAt": .number(Self.now)]))
    }
    let payload: JSONObject = [
      "pendingJSON": !version.isEmpty && !refused ? .string(tracked.pending.text()) : .null,
      "onboarding": .string(action), "savedJSON": saved.map { .string($0.text()) } ?? .null,
    ]
    let result = JSONValue.object(payload).text()
    self.result = result
    return result
  }

  func complete() {
    guard result != nil else { return NSLog("[appIntegration] presentation completed before startup") }
    let first = !completed
    completed = true
    let waiting = pending
    pending = []
    for event in waiting { emit(event) }
    guard first, AppStartupPolicy.opensReleaseNotes(
      updated: updated, development: development, isolated: Self.isolated, force: AppModule.systemInfo["forceReleaseNotes"] as? Bool ?? false)
    else { return }
    _ = perform("releaseNotes", windowId: nil)
  }

  func disconnect() {
    presentation = nil
    if let onboardingRequestId { cancelOnboardingReplay(onboardingRequestId) }
  }

  func cancelOnboardingReplay(_ requestId: String) {
    guard onboardingRequestId == requestId else { return }
    onboardingRequestId = nil
    onboardingExpiry?.cancel()
    onboardingExpiry = nil
    pending.removeAll { $0["requestId"] as? String == requestId }
  }

  func takeOnboardingReplay(_ requestId: String?) -> Bool {
    guard let requestId, onboardingRequestId == requestId else { return false }
    cancelOnboardingReplay(requestId)
    return true
  }

  func perform(_ command: String, windowId: String?) -> Bool {
    switch command {
    case "showOnboarding":
      if let onboardingRequestId { cancelOnboardingReplay(onboardingRequestId) }
      let requestId = UUID().uuidString
      onboardingRequestId = requestId
      onboardingExpiry = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        self?.cancelOnboardingReplay(requestId)
      }
      emit(["action": command, "windowId": windowId as Any? ?? NSNull(), "requestId": requestId])
    case "toolTour":
      emit(["action": command, "windowId": windowId as Any? ?? NSNull()])
    case "videoTour":
      if let url = AppStartupPolicy.videoURL(page: AppModule.systemInfo["videoTourURL"] as? String) { open(url, windowId: windowId) }
    case "releaseNotes":
      if let url = AppStartupPolicy.releaseNotesURL(
        page: AppModule.systemInfo["releaseNotesURL"] as? String, version: AppModule.systemInfo["appVersion"] as? String ?? "")
      { open(url, windowId: windowId) }
    default: return false
    }
    return true
  }

  func firstWindow(onboardingActive: Bool) async throws {
    guard !offered else { return }
    offered = true
    let saved = read("default-browser-offer.json")
    guard AppStartupPolicy.defaultOffer(saved: saved, testInstance: Self.isolated) == .eligible, let saved else { return }
    let onboarding = !(read("onboarding.json")?["completedAt"]?.truthy ?? false) || onboardingActive
    let isDefault = onboarding ? false : SystemServices.isDefaultBrowser()
    let offer = AppStartupPolicy.completeDefaultOffer(saved: saved, onboarding: onboarding, isDefault: isDefault, now: Self.now)
    try await saveDurably("default-browser-offer.json", offer.document)
    if offer.requestDefault { _ = await SettingsAdapters.setAsDefaultBrowser() }
  }

  func notification(action: String, tabId: String?, windowId: String?) {
    guard action == "click" else { return }
    guard let store = workspace else { return unavailable("notification click") }
    let writer = StoreWorkspaceWriter(store: store, showWindow: ShellScripting.showWindow)
    switch AppStartupPolicy.notificationTarget(state: store.state, action: action, tabId: tabId, windowId: windowId) {
    case .none: break
    case .tab(let id):
      let window = store.state.tabs[id]?.windowId
      writer.activate(id)
      if let window, window != store.state.ui.focusedWindowId { writer.focusWindow(window) }
    case .window(let id): writer.focusWindow(id)
    }
  }

  private var workspace: Store? {
    guard NativeStoreHandle.opened, NativeStoreHandle.ownedWorkspaceAtLaunch, NativeStoreHandle.ownsWorkspace else { return nil }
    return NativeStoreHandle.store
  }

  private func open(_ url: String, windowId: String?) {
    guard let store = workspace else {
      unavailable("opening help URL through JS")
      return emit(["action": "openURL", "url": url, "windowId": windowId as Any? ?? NSNull()])
    }
    do {
      let state = store.state
      if let target = state.resolveWindowId(windowId), state.windows[target]?.incognito != true {
        _ = try store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
      } else {
        _ = try store.dispatch(Command("createWindow", [["url": .string(url)]]), origin: .native)
      }
    } catch {
      NSLog("[appIntegration] opening help URL failed: %@", String(describing: error))
    }
  }

  private func unavailable(_ action: String) {
    let reason = NativeSettingsHandle.unavailable?.detail ?? (NativeStoreHandle.opened ? "workspace is not owned or available" : "store is not open")
    NSLog("[appIntegration] %@: %@", action, reason)
  }

  private func emit(_ event: [String: Any]) {
    let requestId = event["requestId"] as? String
    if event["action"] as? String == "showOnboarding", requestId == nil || requestId != onboardingRequestId { return }
    guard completed, let presentation else {
      guard pending.count < 50 else {
        if let requestId { cancelOnboardingReplay(requestId) }
        return NSLog("[appIntegration] JS presentation unavailable; action queue is full")
      }
      pending.append(event)
      NSLog("[appIntegration] waiting for JS presentation: %@", event["action"] as? String ?? "unknown")
      return
    }
    presentation(event)
  }

  private func read(_ name: String) -> JSONValue? {
    let text = name == OnboardingAdapter.document ? OnboardingAdapter.readSavedDocument() : DocumentStore.read(name)
    return text.flatMap { try? JSONValue.parse($0) }
  }

  private func save(_ name: String, _ document: JSONObject) {
    do { try DocumentStore.write(name, JSONValue.object(document).text()) }
    catch { NSLog("[appIntegration] couldn't save %@: %@", name, String(describing: error)) }
  }

  private func saveDurably(_ name: String, _ document: JSONObject) async throws {
    let text = JSONValue.object(document).text()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      do {
        try DocumentStore.write(name, text) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      } catch { continuation.resume(throwing: error) }
    }
  }

  private static var now: Double { floor(Date().timeIntervalSince1970 * 1000) }
  private static var isolated: Bool { AppModule.systemInfo["isolatedInstance"] as? Bool != false }

  private static func debugEnvironment(_ name: String) -> Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment[name] == "1"
    #else
    false
    #endif
  }
}
