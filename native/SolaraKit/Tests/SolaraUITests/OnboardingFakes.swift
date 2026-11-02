import AppKit
import Foundation
import SolaraModel
@testable import SolaraUI

@MainActor
final class OnboardingFakeStore: SettingsStoreSource {
  var settings = Settings.defaults
  var patches: [JSONObject] = []
  var profiles: [SettingsProfile] = [SettingsProfile(id: "default", name: "Personal", engineProfile: "default")]
  var topTabLayout: Bool { settings.string("tabLayout") == "top" }

  func settingValue(_ key: String) -> JSONValue? { settings[key] }

  func updateSettings(_ patch: JSONObject) {
    patches.append(patch)
    settings = settings.updated(patch, fromSync: false)
  }

  func chooseTabLayout(_ layout: String) { updateSettings(["tabLayout": .string(layout)]) }
}

@MainActor
final class OnboardingFakeServices: OnboardingServices {
  let store: OnboardingFakeStore
  var discovery: OnboardingFakeDiscovery?
  var joining: OnboardingFakeJoining?
  var onboardingDiscovery: OnboardingDiscovering? { discovery }
  var pairingJoining: PairingJoining? { joining }
  var onboardingSyncFolder: String?
  var committedOnboardingJoinToken: String?
  let onboardingJoinedWriter: OnboardingJoinedWriter? = OnboardingJoinedWriter()
  var stagesJoinedWrites = false
  private var stagedJoinedDocument: String?
  private var durableJoinedBaseline: String?
  var joinedWrites = 0
  var failJoinedWrite = false
  var holdJoinedWrite = false
  var joinedWriteContinuation: CheckedContinuation<Void, any Error>?
  var folderChoiceContinuation: CheckedContinuation<Bool, Never>?
  var folderChanges = 0
  var recoveryPhraseCalls = 0
  var recoveryAvailable = true
  var drainContinuation: CheckedContinuation<Void, any Error>?
  var holdDrain = false
  var drainCalls = 0
  var document: String?
  var session = false
  var startsOnFirstLaunch = true
  var clock = 1_790_000_000_000.0
  var windowLayout: [String: String] = [:]
  var previews: [JSONObject] = []
  var colors: [String: ProfileColorValue] = ["w1": .plum]
  var incognito = false
  var tourEnded = 0
  var toursStarted: [String] = []
  var music: [String] = []
  var installed: Set<String> = ["/Applications/Arc.app", "/Applications/Safari.app", "/Applications/Brave Browser Beta.app"]
  var importAvailable = true
  var imports: [String] = []
  var importCancelled = false
  var importedWrites = 0
  var defaultOperation: (() async -> Bool)?
  var loginOperation: (() async -> Void)?
  var dockOperation: (() async -> Void)?
  var backgroundInstance = false
  var isDefault = false
  var inDock = false
  var login: LoginItemStatus = .notRegistered
  var setDefaultResult = true
  var setDefaultCalls = 0
  var loginCalls: [Bool] = []
  var dockCalls = 0
  var icons: [OnboardingAppIcon] = [OnboardingAppIcon(id: "default", name: "Default", preview: nil), OnboardingAppIcon(id: "night", name: "Night", preview: nil)]
  var current: String? = "default"
  var iconSet: [String] = []
  var pinned: Set<String> = []
  var visits: [OnboardingHistoryVisit] = []
  var opened: [[String]] = []

  init(store: OnboardingFakeStore) {
    self.store = store
  }

  func readOnboardingDocument() -> String? { document }
  func readDurableOnboardingDocument() -> String? {
    stagedJoinedDocument == nil ? document : durableJoinedBaseline
  }
  func writeOnboardingDocument(_ json: String) {
    stagedJoinedDocument = nil
    durableJoinedBaseline = nil
    document = json
  }
  func landJoinedRetry() {
    guard let stagedJoinedDocument else { return }
    document = stagedJoinedDocument
    self.stagedJoinedDocument = nil
    durableJoinedBaseline = nil
  }
  func writeJoinedOnboardingDocument(_ json: String) async throws {
    joinedWrites += 1
    if stagesJoinedWrites {
      if stagedJoinedDocument == nil { durableJoinedBaseline = document }
      stagedJoinedDocument = json
      document = json
    }
    if holdJoinedWrite { try await withCheckedThrowingContinuation { joinedWriteContinuation = $0 } }
    if failJoinedWrite { throw CocoaError(.fileWriteUnknown) }
    stagedJoinedDocument = nil
    durableJoinedBaseline = nil
    document = json
  }
  func drainOnboardingPreviews() async throws {
    drainCalls += 1
    if holdDrain { try await withCheckedThrowingContinuation { drainContinuation = $0 } }
  }
  func chooseOnboardingFolder(beforeChange: @MainActor () -> Bool) async -> Bool {
    let selected = await withCheckedContinuation { folderChoiceContinuation = $0 }
    guard selected, beforeChange() else { return false }
    folderChanges += 1
    return true
  }
  func openOnboardingRecoveryPhrase() -> Bool {
    if recoveryAvailable { recoveryPhraseCalls += 1 }
    return recoveryAvailable
  }
  func hasSessionDocument() -> Bool { session }
  func now() -> Double { clock }
  func resolveWindowId(_ windowId: String?) -> String? { windowId ?? "w1" }
  func windowTabLayout(_ windowId: String?) -> String { windowLayout[windowId ?? ""] ?? store.settings.string("tabLayout") ?? "sidebar" }
  func setWindowTabLayout(_ windowId: String, _ layout: String) { windowLayout[windowId] = layout }
  func previewSettings(_ patch: JSONObject) {
    previews.append(patch)
    store.settings = store.settings.updated(patch, fromSync: true)
  }
  func profileColor(_ windowId: String) -> ProfileColorValue? { colors[windowId] }
  func isIncognito(_ windowId: String) -> Bool { incognito }
  func setProfileColor(_ windowId: String, _ color: ProfileColorValue) { colors[windowId] = color }
  func endToolTour() { tourEnded += 1 }
  func startToolTour(_ windowId: String) { toursStarted.append(windowId) }
  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool) { music.append("play \(muted)") }
  func setIntroMusicMuted(_ muted: Bool) { music.append("mute \(muted)") }
  func stopIntroMusic(fade: Double) { music.append("stop \(fade)") }
  func fileExists(_ path: String) -> Bool { installed.contains(path) }
  func fileIcon(_ path: String, size: Int) async -> NSImage? { nil }
  func openImport(_ browserId: String) { imports.append(browserId); importCancelled = false }
  func cancelOnboardingImport() { importCancelled = true }
  func completeImport() { if !importCancelled { importedWrites += 1 } }
  func isDefaultBrowser() async -> Bool { isDefault }
  func isInDock() async -> Bool { inDock }
  func loginItemStatus() async -> LoginItemStatus { login }
  func setAsDefaultBrowser() async -> Bool {
    setDefaultCalls += 1
    if let defaultOperation { return await defaultOperation() }
    return setDefaultResult
  }
  func setLaunchAtLogin(_ on: Bool) async {
    loginCalls.append(on)
    await loginOperation?()
  }
  func addToDock() async {
    dockCalls += 1
    await dockOperation?()
  }
  func appIcons(size: Int) async -> [OnboardingAppIcon] { icons }
  func currentAppIcon() async -> String? { current }
  func setAppIcon(_ id: String) async { iconSet.append(id) }
  func pinnedHosts(_ windowId: String) -> Set<String> { pinned }
  func history(_ windowId: String) -> [OnboardingHistoryVisit] { visits }
  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite]) { opened.append(sites.map(\.id)) }
  func favicon(_ url: String) async -> NSImage? { nil }
}

@MainActor
enum OnboardingFixture {
  static func make() -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeStore) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let model = OnboardingModel(services: services, store: store, appName: "Solara")
    return (model, services, store)
  }

  static func saved(_ services: OnboardingFakeServices) -> JSONObject {
    (try? JSONValue.parse(services.document ?? "{}"))?.object ?? [:]
  }
}

@MainActor
final class OnboardingFakeDiscovery: OnboardingDiscovering {
  final class Handle: OnboardingDiscoveryHandle {
    var cancellations = 0
    func cancel() { cancellations += 1 }
  }
  var callbacks: [@MainActor (OnboardingDiscoveryResult) -> Void] = []
  var handles: [Handle] = []
  func start(onResult: @escaping @MainActor (OnboardingDiscoveryResult) -> Void) -> OnboardingDiscoveryHandle {
    callbacks.append(onResult)
    let handle = Handle()
    handles.append(handle)
    return handle
  }
  func emit(_ result: OnboardingDiscoveryResult, request: Int? = nil) {
    guard !callbacks.isEmpty else { return }
    callbacks[request ?? callbacks.count - 1](result)
  }
}

@MainActor
final class OnboardingFakeJoining: @preconcurrency PairingJoining {
  final class Handle: PairingJoinHandle {
    var cancellations = 0
    var restarts = 0
    var cancelResult: PairingCancelResult = .cancelled
    @discardableResult func cancel() -> PairingCancelResult { cancellations += 1; return cancelResult }
    func startAgain() { restarts += 1 }
  }
  var cids: [String] = []
  var callbacks: [@MainActor (PairingJoinState) -> Void] = []
  var cancelResult: PairingCancelResult = .cancelled
  var committedResult = false
  var committedState: PairingJoinState?
  var committedCallbacks: [@MainActor (PairingJoinState) -> Void] = []
  var handles: [Handle] = []
  var initialState: PairingJoinState?
  var onStart: (() -> Void)?
  var onInstalled: (() -> Void)?
  func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool {
    committedCallbacks.append(onState)
    if committedResult, let committedState { onState(committedState) }
    return committedResult
  }
  func emitCommitted(_ state: PairingJoinState) {
    if state == .installed { onInstalled?() }
    committedCallbacks.last?(state)
  }
  func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    cids.append(cid)
    callbacks.append(onState)
    let handle = Handle()
    handle.cancelResult = cancelResult
    handles.append(handle)
    onStart?()
    if let initialState {
      if initialState == .installed { onInstalled?() }
      onState(initialState)
    }
    return handle
  }
  @MainActor
  func emit(_ state: PairingJoinState, request: Int? = nil) {
    guard !callbacks.isEmpty else { return }
    if state == .installed { onInstalled?() }
    callbacks[request ?? callbacks.count - 1](state)
  }
}

@MainActor
final class OnboardingFakeScheduler: OnboardingScheduler {
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
  var tasks: [Scheduled] = []
  func schedule(at deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) -> OnboardingScheduledTask {
    let scheduled = Scheduled(deadline: deadline, action: action)
    tasks.append(scheduled)
    return scheduled
  }
  func advance(_ duration: Duration, fire: Bool = true) {
    now += duration
    guard fire else { return }
    let due = tasks.filter { !$0.cancelled && $0.deadline <= now }
    for scheduled in due {
      scheduled.cancelled = true
      scheduled.action()
    }
  }
}
