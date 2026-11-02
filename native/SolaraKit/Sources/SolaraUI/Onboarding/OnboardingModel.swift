import AppKit
import Foundation
import Observation
import SolaraModel
import SwiftUI

@MainActor
@Observable
public final class OnboardingModel {
  @ObservationIgnored public let services: OnboardingServices
  @ObservationIgnored public let store: SettingsStoreSource
  @ObservationIgnored public var powerUpView: ((PowerUpSpec) -> AnyView)?
  public let copy: OnboardingCopy
  public var appIcon: NSImage?

  public private(set) var windowId: String?
  public private(set) var step: OnboardingStep = .intro
  public private(set) var sub = 0
  public private(set) var leaving = false
  public private(set) var session = 0
  public private(set) var tourAfter = false
  public private(set) var preset: OnboardingPreset = .dia
  public private(set) var source: BrowserSourceId?
  public private(set) var draft: JSONObject = [:]
  public private(set) var extras = OnboardingExtras()
  public private(set) var baseline: JSONObject = [:]
  public private(set) var picked: [OnboardingQuestion: [String]] = [:]
  var settingsRevision = 0

  public var system: OnboardingSystemState?
  public var busy = false
  @ObservationIgnored var systemOperation: UUID?
  @ObservationIgnored var systemWaiters: [CheckedContinuation<Void, Never>] = []
  public var icons: [OnboardingAppIcon] = []
  public var currentIcon: String?
  public var sourceTiles: [BrowserSourceTile] = []
  public var importing: BrowserSourceId?
  public var introMuted = false
  public private(set) var isFirstRunOnboarding = false
  @ObservationIgnored private var previewed: JSONObject = [:]
  @ObservationIgnored private var retryingRecoveryPhrase = false
  public private(set) var syncRoute: OnboardingSyncRoute = .setup
  public private(set) var candidates: [OnboardingDiscoveryCandidate] = []
  public private(set) var selectedCID: String?
  @ObservationIgnored let scheduler: OnboardingScheduler

  @ObservationIgnored private var discoveryHandle: OnboardingDiscoveryHandle?
  @ObservationIgnored private var discoveryTimer: OnboardingScheduledTask?
  @ObservationIgnored private var hydrationTimer: OnboardingScheduledTask?
  @ObservationIgnored private var discoveryDeadline: ContinuousClock.Instant?
  @ObservationIgnored private var discoveryGeneration = 0
  @ObservationIgnored private var pairingHandle: PairingJoinHandle?
  @ObservationIgnored private weak var finishedPairingHandle: PairingJoinHandle?
  @ObservationIgnored private var pairingCallback: JoinCallback?
  @ObservationIgnored private var pairingTask: Task<Void, Never>?
  @ObservationIgnored private var pairingGeneration = 0
  @ObservationIgnored private var pairingExpires: ContinuousClock.Instant?
  @ObservationIgnored private var pendingJoinedToken: String?
  @ObservationIgnored private var joinedInstalled = false
  @ObservationIgnored private var joinedCommitted = false
  @ObservationIgnored private var bootstrapTimer: OnboardingScheduledTask?
  @ObservationIgnored private let joinedWriter: OnboardingJoinedWriter
  @ObservationIgnored private var joinedWriteInFlight = false
  @ObservationIgnored private var joinedBrowserRequested = false
  @ObservationIgnored private var joinedBrowserRetryable = false
  @ObservationIgnored private var joinedBrowserEntered = false

  @MainActor
  private final class JoinCallback {
    weak var model: OnboardingModel?
    var retainedModel: OnboardingModel?
    var writer: OnboardingJoinedWriter?
    var services: OnboardingServices?
    var scheduler: OnboardingScheduler?
    let id: UUID
    var token: String?
    var installed = false

    init(model: OnboardingModel, resumingCommitted: Bool = false) {
      id = resumingCommitted ? model.joinedWriter.resumeApprovalIdentity() : model.joinedWriter.beginApprovalIdentity()
      self.model = model
      retainedModel = model
      writer = model.joinedWriter
      services = model.services
      scheduler = model.scheduler
    }

    func captureCommittedToken() {
      guard token == nil, let current = services?.committedOnboardingJoinToken, !current.isEmpty else { return }
      token = current
    }

    func receive(_ state: PairingJoinState, generation: Int) {
      guard !installed else { return }
      let model = retainedModel ?? self.model
      if let model {
        guard generation == model.pairingGeneration, !model.joinedInstalled else { return }
      }
      var deadline: ContinuousClock.Instant?
      switch state {
      case .approved:
        captureCommittedToken()
        if let writer, let scheduler {
          deadline = writer.approvalDeadline(token: token, callbackID: id, now: scheduler.now)
        }
      case .installed, .failed:
        writer?.clearApproval(token: token, callbackID: id)
      default: break
      }
      if let model {
        model.receivedJoin(state, generation: generation, deadline: deadline)
      } else if state == .installed, let writer, let services {
        Task { @MainActor in
          try? await writer.write(services: services, token: services.committedOnboardingJoinToken, installed: true, enterBrowser: false)
        }
      }
      switch state {
      case .installed:
        installed = true
        retainedModel = nil
        writer = nil
        services = nil
        scheduler = nil
      case .failed:
        retainedModel = nil
        writer = nil
        services = nil
        scheduler = nil
      default: break
      }
    }
  }

  private var iCloudDiscovery: Bool {
    services.onboardingSyncFolder.map { $0.hasPrefix("iCloud Drive › ") } ?? true
  }

  public var syncTitle: String {
    switch syncRoute {
    case .setup: ""
    case .discovering: "Looking for Solara on your other Macs…"
    case .found: "Use Solara from your other Mac"
    case .discoveryIssue(.permissionDenied): "Solara can't access the sync folder."
    case .discoveryIssue(.unavailable): iCloudDiscovery ? "iCloud Drive isn't available." : "The sync folder isn't available."
    case .discoveryIssue: "Couldn't finish checking iCloud Drive."
    case .joining(.preparing): "Preparing a secure connection…"
    case .joining(.waiting), .joining(.comparing): "Connect your other Mac"
    case .joining(.approved): "Finishing connection"
    case .downloading: "Approved. Your synced data is still downloading."
    case .setupIssue(.previewRestoration): "Couldn't restore your setup previews."
    case .setupIssue(.recoveryUnavailable): "Couldn't open recovery phrase entry."
    case .joining(.installed), .joined: "You're connected"
    case .joining(.failed): "Connection ended"
    case .savingFailed: "Couldn't finish saving sync on this Mac."
    }
  }

  public var syncMessage: String {
    switch syncRoute {
    case .found:
      services.onboardingSyncFolder.map { "Sync data was found in \($0)" } ?? "Sync data was found in iCloud Drive › Solara Sync"
    case .discoveryIssue(.permissionDenied): "Allow access to this folder, or choose another folder."
    case .discoveryIssue(.unavailable): iCloudDiscovery ? "Turn on iCloud Drive in System Settings, or choose another folder." : "Check that the folder is available, or choose another folder."
    case .joining(.waiting): "Open Solara on your other Mac and choose Connect another Mac or Review request."
    case .joining(.comparing): "Compare this code on your other Mac, then choose Allow there."
    case .joining(.failed(.expired)): "No Mac approved in time. Open Solara on your other Mac and try again, or use your recovery phrase."
    case .joining(.failed(.denied)): "Your other Mac declined this request."
    case .joining(.failed(.mismatch)): "The codes don't match. Nothing was connected."
    case .joining(.failed(.folderUnavailable)): "The sync folder isn't available."
    case .joining(.failed(.invalidPeer)): "This connection couldn't be verified. Nothing was connected."
    default: ""
    }
  }

  public var syncCode: String? {
    guard case .joining(.comparing(let code, _)) = syncRoute else { return nil }
    return code
  }

  public var claimedSyncName: String {
    guard case .joining(.comparing(_, let name)) = syncRoute else { return "Trusted Mac" }
    return "“\(name)”"
  }

  public var pairingRemainingSeconds: Int? {
    guard let expires = pairingExpires else { return nil }
    switch syncRoute {
    case .joining(.waiting), .joining(.comparing):
      let remaining = scheduler.now.duration(to: expires).components
      return max(0, Int(ceil(Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)))
    default: return nil
    }
  }

  public func selectSync(cid: String) {
    guard syncRoute == .found, candidates.contains(where: { $0.cid == cid }) else { return }
    selectedCID = cid
  }

  public func discoverSync() {
    guard isActive, isFirstRunOnboarding, canLeavePairing else { return }
    guard cancelPairingWork() else { return }
    invalidateDiscovery()
    clearSetupPreviews()
    candidates = []
    selectedCID = nil
    guard services.onboardingDiscovery != nil else { return continueSetup() }
    syncRoute = .discovering
    let deadline = scheduler.now + .seconds(10)
    discoveryDeadline = deadline
    let generation = discoveryGeneration
    discoveryTimer = scheduler.schedule(at: deadline) { [weak self] in
      self?.discoveryExpired(generation)
    }
    runDiscovery(generation)
  }

  private func runDiscovery(_ generation: Int) {
    guard generation == discoveryGeneration, syncRoute == .discovering,
      let deadline = discoveryDeadline, scheduler.now < deadline,
      let discovery = services.onboardingDiscovery else { return }
    let handle = discovery.start { [weak self] result in
      self?.receivedDiscovery(result, generation: generation)
    }
    if generation == discoveryGeneration, syncRoute == .discovering {
      discoveryHandle = handle
    } else {
      handle.cancel()
    }
  }

  private func receivedDiscovery(_ result: OnboardingDiscoveryResult, generation: Int) {
    guard generation == discoveryGeneration, syncRoute == .discovering,
      let deadline = discoveryDeadline else { return }
    guard scheduler.now < deadline else { return discoveryExpired(generation) }
    switch result {
    case .needsHydration:
      discoveryHandle?.cancel()
      discoveryHandle = nil
      hydrationTimer?.cancel()
      hydrationTimer = scheduler.schedule(at: min(deadline, scheduler.now + .milliseconds(250))) { [weak self] in
        self?.runDiscovery(generation)
      }
    case .found(let candidates) where !candidates.isEmpty:
      invalidateDiscovery()
      self.candidates = candidates
      selectedCID = candidates.count == 1 ? candidates[0].cid : nil
      syncRoute = .found
    case .found, .empty:
      continueSetup()
    default:
      invalidateDiscovery()
      syncRoute = .discoveryIssue(result)
    }
  }

  private func discoveryExpired(_ generation: Int) {
    guard generation == discoveryGeneration, syncRoute == .discovering else { return }
    invalidateDiscovery()
    syncRoute = .discoveryIssue(.timedOut)
  }

  private func invalidateDiscovery() {
    discoveryGeneration += 1
    discoveryTimer?.cancel()
    discoveryTimer = nil
    hydrationTimer?.cancel()
    hydrationTimer = nil
    let handle = discoveryHandle
    discoveryHandle = nil
    discoveryDeadline = nil
    handle?.cancel()
  }

  private func clearSetupPreviews() {
    if importing != nil { services.cancelOnboardingImport() }
    revertLive(baseline.keys)
    baseline = [:]
    draft = [:]
    extras = OnboardingExtras()
    importing = nil
  }

  public func pairWithAnotherMac() {
    guard isFirstRunOnboarding, syncRoute == .found, let cid = selectedCID else { return }
    retryingRecoveryPhrase = false
    clearSetupPreviews()
    source = nil
    picked = [:]
    invalidateDiscovery()
    guard cancelPairingWork() else { return }
    syncRoute = .joining(.preparing)
    let generation = pairingGeneration
    pairingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        await waitForSystemChoices()
        try await services.drainOnboardingPreviews()
      } catch {
        guard pairingGeneration == generation, !Task.isCancelled else { return }
        syncRoute = .setupIssue(.previewRestoration)
        return
      }
      guard pairingGeneration == generation, isActive, !Task.isCancelled else { return }
      guard let joining = services.pairingJoining else {
        syncRoute = .joining(.failed(.invalidPeer))
        return
      }
      let callback = JoinCallback(model: self)
      pairingCallback = callback
      let handle = joining.start(cid: cid) { state in
        callback.receive(state, generation: generation)
      }
      if pairingGeneration == generation, !joinedInstalled, callback.retainedModel != nil {
        pairingHandle = handle
      } else if pairingGeneration != generation, !joinedInstalled {
        handle.cancel()
      } else if !joinedInstalled {
        finishedPairingHandle = handle
      }
    }
  }

  private func receivedJoin(_ state: PairingJoinState, generation: Int, deadline: ContinuousClock.Instant?) {
    guard generation == pairingGeneration, !joinedInstalled else { return }
    switch state {
    case .approved:
      joinedCommitted = true
      if isActive, !joinedBrowserEntered, syncRoute != .downloading { syncRoute = .joining(.approved) }
      if let deadline, isActive, !joinedBrowserEntered, scheduler.now >= deadline {
        bootstrapTimer?.cancel()
        bootstrapTimer = nil
        syncRoute = .downloading
      } else if let deadline, bootstrapTimer == nil, isActive, !joinedBrowserEntered {
        bootstrapTimer = scheduler.schedule(at: deadline) { [weak self] in
          guard let self, isActive, !joinedInstalled, !joinedBrowserEntered else { return }
          syncRoute = .downloading
        }
      }
    case .installed:
      joinedCommitted = true
      bootstrapTimer?.cancel()
      bootstrapTimer = nil
      joinedInstalled = true
      finishedPairingHandle = nil
      pairingHandle = nil
      pairingCallback = nil
      pairingTask = nil
      pendingJoinedToken = services.committedOnboardingJoinToken
      persistJoined(enterBrowser: false)
    case .failed(.cancelled):
      cancelPairingWork()
      if isActive { syncRoute = .found }
    case .failed:
      bootstrapTimer?.cancel()
      bootstrapTimer = nil
      finishedPairingHandle = pairingHandle
      pairingHandle = nil
      pairingCallback = nil
      pairingTask = nil
      if isActive { syncRoute = .joining(state) }
    case .waiting(let expires):
      guard isActive else { return }
      pairingExpires = expires
      syncRoute = .joining(state)
    default:
      if isActive { syncRoute = .joining(state) }
    }
  }

  public func startPairingAgain() {
    guard canLeavePairing else { return }
    guard let handle = pairingHandle else {
      guard selectedCID != nil else { return }
      syncRoute = .found
      return pairWithAnotherMac()
    }
    pairingExpires = nil
    syncRoute = .joining(.preparing)
    handle.startAgain()
  }

  public var canLeavePairing: Bool { !joinedCommitted && !joinedInstalled }

  public func cancelPairing() {
    guard canLeavePairing else { return }
    guard cancelPairingWork() else { return }
    syncRoute = candidates.isEmpty ? .setup : .found
  }

  @discardableResult
  private func cancelPairingWork() -> Bool {
    let handle = pairingHandle ?? finishedPairingHandle
    let result = joinedInstalled ? nil : handle?.cancel()
    if result == .alreadyCommitted {
      joinedCommitted = true
      syncRoute = .joining(.approved)
      _ = resumeCommittedJoin()
      return false
    }
    if result == .unavailable {
      if resumeCommittedJoin() { return false }
      releasePairingWork()
      syncRoute = .joining(.failed(.folderUnavailable))
      return false
    }
    releasePairingWork()
    return true
  }

  private func releasePairingWork() {
    pairingGeneration += 1
    pairingTask?.cancel()
    pairingTask = nil
    pairingExpires = nil
    pairingHandle = nil
    finishedPairingHandle = nil
    bootstrapTimer?.cancel()
    bootstrapTimer = nil
    pairingCallback?.retainedModel = nil
    pairingCallback?.writer = nil
    pairingCallback?.services = nil
    pairingCallback?.scheduler = nil
    pairingCallback = nil
  }

  @discardableResult
  public func resumeCommittedJoin() -> Bool {
    guard let joining = services.pairingJoining else { return false }
    let callback = pairingCallback ?? JoinCallback(model: self, resumingCommitted: true)
    let generation = pairingGeneration
    let found = joining.committedJoin { state in
      callback.receive(state, generation: generation)
    }
    guard found else {
      if pairingCallback == nil {
        callback.retainedModel = nil
        callback.writer = nil
        callback.services = nil
        callback.scheduler = nil
      }
      return false
    }
    joinedCommitted = true
    callback.captureCommittedToken()
    if !joinedInstalled {
      pairingCallback = callback
      if !joinedBrowserEntered, syncRoute != .downloading { syncRoute = .joining(.approved) }
    }
    pairingHandle = nil
    finishedPairingHandle = nil
    callback.retainedModel = nil
    return true
  }

  public func useRecoveryPhrase() {
    guard isFirstRunOnboarding, canLeavePairing else { return }
    guard cancelPairingWork() else { return }
    retryingRecoveryPhrase = true
    invalidateDiscovery()
    clearSetupPreviews()
    syncRoute = candidates.isEmpty ? .setup : .found
    let generation = pairingGeneration
    Task { @MainActor [weak self] in
      guard let self, generation == pairingGeneration, isActive else { return }
      do {
        await waitForSystemChoices()
        try await services.drainOnboardingPreviews()
      } catch {
        guard generation == pairingGeneration, isActive, !Task.isCancelled else { return }
        syncRoute = .setupIssue(.previewRestoration)
        return
      }
      guard generation == pairingGeneration, isActive else { return }
      if !services.openOnboardingRecoveryPhrase() { syncRoute = .setupIssue(.recoveryUnavailable) }
    }
  }

  public func retrySetupTransition() {
    guard case .setupIssue = syncRoute else { return }
    if retryingRecoveryPhrase {
      useRecoveryPhrase()
    } else {
      syncRoute = .found
      pairWithAnotherMac()
    }
  }

  public func continueSetup() {
    guard canLeavePairing else { return }
    invalidateDiscovery()
    guard cancelPairingWork() else { return }
    syncRoute = .setup
  }

  public func leaveSetup() {
    invalidateDiscovery()
    joinedBrowserRequested = false
    joinedBrowserRetryable = false
    windowId = nil
    leaving = false
    if joinedCommitted, !joinedInstalled {
      _ = resumeCommittedJoin()
      pairingCallback?.retainedModel = nil
      pairingCallback = nil
      pairingHandle = nil
      finishedPairingHandle = nil
      bootstrapTimer?.cancel()
    } else {
      if cancelPairingWork(), !joinedInstalled { clearSetupPreviews() }
    }
  }

  public func keepWaitingForSync() {}

  public func finishJoined() {
    guard joinedInstalled || pendingJoinedToken != nil || syncRoute == .downloading || joinedBrowserRetryable else { return }
    if isActive { joinedBrowserRetryable = true }
    persistJoined(enterBrowser: true)
  }

  private func persistJoined(enterBrowser: Bool) {
    let token = pendingJoinedToken ?? services.committedOnboardingJoinToken
    guard !joinedInstalled || token?.isEmpty == false else {
      if isActive { syncRoute = .savingFailed }
      return
    }
    pendingJoinedToken = token
    guard !enterBrowser || !joinedBrowserEntered else { return }
    joinedBrowserRequested = joinedBrowserRequested || (enterBrowser && isActive)
    guard !joinedWriteInFlight else { return }
    joinedWriteInFlight = true
    if isActive, !joinedBrowserEntered, syncRoute != .downloading { syncRoute = .joining(.approved) }
    let session = self.session
    let enteringBrowser = joinedBrowserRequested
    joinedBrowserRequested = false
    Task { @MainActor in
      var enterBrowser = enteringBrowser && isActive && self.session == session
      while true {
        let wasInstalled = joinedInstalled
        do {
          try await joinedWriter.write(services: services, token: pendingJoinedToken ?? services.committedOnboardingJoinToken, installed: wasInstalled, enterBrowser: enterBrowser)
        } catch {
          joinedWriteInFlight = false
          joinedBrowserRequested = false
          if isActive, self.session == session { syncRoute = .savingFailed }
          return
        }
        if enterBrowser {
          joinedBrowserEntered = true
          joinedBrowserRetryable = false
        }
        if !wasInstalled, joinedInstalled { continue }
        if !enterBrowser, joinedBrowserRequested, isActive, self.session == session {
          joinedBrowserRequested = false
          enterBrowser = true
          continue
        }
        joinedWriteInFlight = false
        joinedBrowserRequested = false
        guard isActive, self.session == session else { return }
        syncRoute = .joined
        if enterBrowser {
          if !joinedInstalled { _ = resumeCommittedJoin() }
          services.stopIntroMusic(fade: 0.6)
          leaving = true
        }
        return
      }
    }
  }

  public init(services: OnboardingServices, store: SettingsStoreSource, appName: String, appIcon: NSImage? = nil, scheduler: OnboardingScheduler = ContinuousOnboardingScheduler()) {
    joinedWriter = services.onboardingJoinedWriter ?? OnboardingJoinedWriter()
    self.scheduler = scheduler
    self.services = services
    self.store = store
    copy = OnboardingCopy(product: appName)
    self.appIcon = appIcon
  }

  public var isActive: Bool { windowId != nil }
  public func isActive(in windowId: String) -> Bool { self.windowId == windowId }

  public func questions(for step: OnboardingStep) -> [OnboardingQuestion] {
    _ = settingsRevision
    let list = OnboardingQuestion.all(in: step)
    if step != .layout { return list }
    return resolve(["tabLayout"])["tabLayout"]?.string == "top" ? list.filter { $0 != .address } : list
  }

  public var question: OnboardingQuestion? {
    let list = questions(for: step)
    return list.indices.contains(sub) ? list[sub] : nil
  }

  public var isFirstPage: Bool { step.advanced(by: -1) == .intro && sub == 0 }

  func base(_ key: String) -> JSONValue {
    if key == "tabLayout" { return .string(services.windowTabLayout(windowId)) }
    return store.settingValue(key) ?? .null
  }

  public func resolve(_ keys: [String]) -> JSONObject {
    _ = settingsRevision
    let presetValues = preset.settings
    let chosen = store.settingValue("chosen")?.array?.compactMap(\.string) ?? []
    var out: JSONObject = [:]
    for key in keys {
      if let drafted = draft[key] {
        out[key] = drafted
      } else if let presetValue = presetValues[key], !chosen.contains(key) {
        out[key] = presetValue
      } else {
        out[key] = base(key)
      }
    }
    return out
  }

  public func value(_ key: String) -> JSONValue { resolve([key])[key] ?? .null }
  public func string(_ key: String) -> String { value(key).string ?? "" }
  public func bool(_ key: String) -> Bool { value(key).truthy }

  public func mock(_ keys: [String]) -> MockSettings {
    let values = resolve(keys)
    func pick(_ key: String) -> JSONValue { values[key] ?? base(key) }
    return MockSettings(
      tabLayout: pick("tabLayout").string ?? "sidebar",
      addressBar: pick("addressBar").string ?? "toolbar",
      appearance: pick("appearance").string ?? "auto",
      extendWebsiteColor: pick("extendWebsiteColor").bool ?? true
    )
  }

  public var accent: String {
    _ = settingsRevision
    guard let windowId, let color = services.profileColor(windowId) else { return ProfileColorValue.plum.swatch }
    return color.swatch
  }

  public func go(_ step: OnboardingStep, sub: Int = 0) {
    guard canLeavePairing else { return }
    if syncRoute != .setup { continueSetup() }
    guard syncRoute == .setup else { return }
    self.step = step
    self.sub = max(0, min(sub, questions(for: step).count - 1))
    save(["step": .string(step.rawValue), "sub": .number(Double(sub))])
  }

  public func next() {
    guard syncRoute == .setup else { return }
    if sub < questions(for: step).count - 1 { return go(step, sub: sub + 1) }
    if let after = step.advanced(by: 1) {
      go(after)
    } else {
      finish()
    }
  }

  public func back() {
    guard syncRoute == .setup else { return }
    if sub > 0 { return go(step, sub: sub - 1) }
    if let before = step.advanced(by: -1), before != .intro {
      go(before, sub: max(0, questions(for: before).count - 1))
    }
  }

  public func chooseSource(_ source: BrowserSourceId?) {
    guard syncRoute == .setup else { return }
    let preset = OnboardingPreset.forSource(source)
    self.source = source
    self.preset = preset
    save(["source": JSONValue(source?.rawValue), "preset": .string(preset.rawValue)])
  }

  public func setDraft(_ patch: JSONObject) {
    guard syncRoute == .setup else { return }
    for (key, value) in patch { draft[key] = value }
  }

  public func setExtras(_ change: (inout OnboardingExtras) -> Void) {
    guard syncRoute == .setup else { return }
    change(&extras)
  }

  public func previewLive(_ patch: JSONObject) {
    guard syncRoute == .setup else { return }
    var recorded = baseline
    for key in patch.keys where !recorded.contains(key) {
      recorded[key] = base(key)
    }
    baseline = recorded
    for (key, value) in patch { previewed[key] = value }
    var rest = patch
    let tabLayout = rest.removeValue(forKey: "tabLayout")
    if let layout = tabLayout?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !rest.isEmpty { services.previewSettings(rest) }
    settingsRevision += 1
  }

  public func previewColor(_ color: ProfileColorValue) {
    guard syncRoute == .setup else { return }
    guard let windowId, let current = services.profileColor(windowId) else { return }
    if !baseline.contains("color") { baseline["color"] = .string(current.rawValue) }
    previewed["color"] = .string(color.rawValue)
    services.setProfileColor(windowId, color)
    settingsRevision += 1
  }

  public func confirm(_ question: OnboardingQuestion, patch: JSONObject, picked lines: [String]) {
    guard syncRoute == .setup else { return }
    if let layout = patch["tabLayout"]?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !patch.isEmpty { store.updateSettings(patch) }
    var kept = baseline
    for key in patch.keys {
      _ = kept.removeValue(forKey: key)
      _ = previewed.removeValue(forKey: key)
    }
    if question == .color {
      _ = kept.removeValue(forKey: "color")
      _ = previewed.removeValue(forKey: "color")
    }
    picked[question] = lines
    baseline = kept
    settingsRevision += 1
    save(["picked": pickedJSON])
    next()
  }

  public func skip() {
    guard syncRoute == .setup else { return }
    let rest = Array(questions(for: step).dropFirst(sub))
    let keys = rest.flatMap(\.keys)
    revertLive(keys + (rest.contains(.color) ? ["color"] : []))
    for key in keys { _ = draft.removeValue(forKey: key) }
    if let after = step.advanced(by: 1) {
      go(after)
    } else {
      finish()
    }
  }

  func revertLive(_ keys: [String]) {
    var restore: JSONObject = [:]
    for key in keys {
      let current = key == "color" ? windowId.flatMap { services.profileColor($0) }.map { JSONValue.string($0.rawValue) } : base(key)
      if let value = baseline[key], current == previewed[key] { restore[key] = value }
      _ = previewed.removeValue(forKey: key)
    }
    var kept = baseline
    for key in keys { _ = kept.removeValue(forKey: key) }
    baseline = kept
    if restore.isEmpty { return }
    let color = restore.removeValue(forKey: "color")
    let tabLayout = restore.removeValue(forKey: "tabLayout")
    if let layout = tabLayout?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !restore.isEmpty { services.previewSettings(restore) }
    if let name = color?.string, let value = ProfileColorValue(rawValue: name), let windowId { services.setProfileColor(windowId, value) }
    settingsRevision += 1
  }

  public func finish(tour: Bool = false) {
    guard canLeavePairing || joinedInstalled else { return }
    if joinedInstalled { return finishJoined() }
    invalidateDiscovery()
    guard cancelPairingWork() else { return }
    revertLive(baseline.keys)
    save(["completedAt": .number(services.now())])
    services.stopIntroMusic(fade: 0.6)
    if windowId != nil {
      leaving = true
      tourAfter = tour
    }
  }

  public func dismiss(session: Int) {
    guard session == self.session, !joinedCommitted || joinedBrowserEntered || joinedInstalled else { return }
    invalidateDiscovery()
    if !joinedCommitted, !cancelPairingWork() { return }
    let windowId = self.windowId
    let tour = tourAfter
    self.windowId = nil
    step = .intro
    leaving = false
    tourAfter = false
    if tour, let windowId { services.startToolTour(windowId) }
  }

  private func reset() -> Bool {
    invalidateDiscovery()
    guard cancelPairingWork() else { return false }
    syncRoute = .setup
    isFirstRunOnboarding = false
    previewed = [:]
    joinedInstalled = false
    joinedCommitted = false
    pendingJoinedToken = nil
    joinedBrowserEntered = false
    joinedBrowserRetryable = false
    candidates = []
    selectedCID = nil
    preset = .dia
    source = nil
    draft = [:]
    extras = OnboardingExtras()
    baseline = [:]
    picked = [:]
    system = nil
    busy = false
    importing = nil
    leaving = false
    tourAfter = false
    sub = 0
    return true
  }

  public func start(windowId: String? = nil, step: OnboardingStep = .intro, isFirstRunOnboarding: Bool = false) {
    guard !joinedCommitted || joinedBrowserEntered else { return }
    guard let id = services.resolveWindowId(windowId) else { return }
    services.endToolTour()
    guard reset() else { return }
    self.windowId = id
    self.isFirstRunOnboarding = isFirstRunOnboarding && readDurableSaved()?["completedAt"]?.truthy != true
    self.step = step
    session += 1
    introMuted = introMusicMuted
    save(["step": .string(step.rawValue), "sub": 0, "source": nil, "preset": "dia", "picked": [:]])
  }

  func resume(_ saved: JSONObject) {
    guard let id = services.resolveWindowId(nil) else { return }
    let savedStep = saved["step"]?.string.flatMap(OnboardingStep.init(rawValue:))
    let step = savedStep.flatMap { $0 == .intro ? nil : $0 } ?? .source
    let source = saved["source"]?.string.flatMap(BrowserSourceId.init(rawValue:))
    guard reset() else { return }
    windowId = id
    self.step = step
    self.source = source
    preset = saved["preset"]?.string.flatMap(OnboardingPreset.init(rawValue:)) ?? OnboardingPreset.forSource(source)
    picked = Self.pickedFrom(saved["picked"])
    session += 1
    introMuted = introMusicMuted
    let sub = min(saved["sub"]?.int ?? 0, questions(for: step).count - 1)
    if sub > 0 { self.sub = sub }
  }

  @discardableResult
  public func startCommittedJoin(windowId: String? = nil) -> Bool {
    guard !joinedCommitted, !joinedWriteInFlight else { return joinedCommitted }
    let previousWindow = self.windowId
    let saved = readDurableSaved()
    let completion = saved?["joinedCompletionToken"]?.string
    let entered = saved?["joinedEnteredBrowser"]?.bool == true && (completion == nil || completion == services.committedOnboardingJoinToken)
    self.windowId = entered ? nil : services.resolveWindowId(windowId)
    joinedBrowserEntered = entered
    session += 1
    if resumeCommittedJoin() { return true }
    self.windowId = previousWindow
    joinedBrowserEntered = false
    return false
  }

  public func maybeStart(windowId: String? = nil) {
    guard !joinedWriteInFlight, !joinedCommitted || syncRoute == .savingFailed else { return }
    if !joinedCommitted, startCommittedJoin(windowId: windowId) { return }
    let saved = readDurableSaved()
    let token = services.committedOnboardingJoinToken
    if let token {
      if saved?["joinedCompletionToken"]?.string == token, saved?["joinedEnteredBrowser"]?.bool == true { return }
      guard let id = services.resolveWindowId(windowId) else { return }
      guard reset() else { return }
      self.windowId = id
      session += 1
      joinedInstalled = true
      pendingJoinedToken = token
      persistJoined(enterBrowser: false)
      return
    }
    if saved?["completedAt"]?.truthy == true { return }
    if let saved, saved["startedAt"]?.truthy == true {
      resume(saved)
      isFirstRunOnboarding = true
      if services.onboardingDiscovery != nil { discoverSync() }
      return
    }
    if services.hasSessionDocument() { return save(["completedAt": .number(services.now())]) }
    if !services.startsOnFirstLaunch { return }
    save(["startedAt": .number(services.now())])
    start(windowId: windowId, isFirstRunOnboarding: true)
    if services.onboardingDiscovery != nil { discoverSync() }
  }

  public var completedAt: Double? { readDurableSaved()?["completedAt"]?.number }
  public var introMusicMuted: Bool { readSaved()?["introMusicMuted"]?.bool ?? false }
  public var defaultBrowserTrialStartedAt: Double? { readSaved()?["defaultBrowserTrialStartedAt"]?.number }
  public var defaultBrowserCheckInDoneAt: Double? { readSaved()?["defaultBrowserCheckInDoneAt"]?.number }
  public func recordDefaultBrowserTrial() { save(["defaultBrowserTrialStartedAt": .number(services.now())]) }
  public func recordDefaultBrowserCheckInDone() { save(["defaultBrowserCheckInDoneAt": .number(services.now())]) }

  public func toggleIntroMute() {
    introMuted.toggle()
    services.setIntroMusicMuted(introMuted)
    save(["introMusicMuted": .bool(introMuted)])
  }

  var pickedJSON: JSONValue {
    var object: JSONObject = [:]
    for question in OnboardingQuestion.allCases { if let lines = picked[question] { object[question.rawValue] = JSONValue(lines) } }
    return .object(object)
  }

  static func pickedFrom(_ value: JSONValue?) -> [OnboardingQuestion: [String]] {
    var out: [OnboardingQuestion: [String]] = [:]
    for (key, lines) in value?.object ?? [:] {
      if let question = OnboardingQuestion(rawValue: key) { out[question] = lines.array?.compactMap(\.string) ?? [] }
    }
    return out
  }

  public var pickedLines: [String] { OnboardingQuestion.order.flatMap { picked[$0] ?? [] } }

  private func readDurableSaved() -> JSONObject? { OnboardingDocument.parse(services.readDurableOnboardingDocument()) }

  func readSaved() -> JSONObject? { OnboardingDocument.parse(services.readOnboardingDocument()) }

  func save(_ patch: JSONObject) {
    services.writeOnboardingDocument(OnboardingDocument.stringify(.object(OnboardingDocument.merged(readSaved(), patch))))
  }

  public func refreshSettings() { settingsRevision += 1 }
}

public struct MockSettings: Equatable, Sendable {
  public var tabLayout: String
  public var addressBar: String
  public var appearance: String
  public var extendWebsiteColor: Bool

  public init(tabLayout: String = "sidebar", addressBar: String = "toolbar", appearance: String = "auto", extendWebsiteColor: Bool = true) {
    self.tabLayout = tabLayout
    self.addressBar = addressBar
    self.appearance = appearance
    self.extendWebsiteColor = extendWebsiteColor
  }

  public var top: Bool { tabLayout == "top" }
  public var addressInSidebar: Bool { !top && addressBar == "sidebar" }
}
