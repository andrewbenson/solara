import AppKit
import CoreGraphics
import Foundation
import SolaraCore
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeProfileWarmup {
  static let shared = NativeProfileWarmup()

  private struct Shown: Equatable, Sendable {
    var windows: [String: String] = [:]
    var profiles: Set<String> = []
  }

  private final class ShownFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Shown?
    private var versions: (UInt64, UInt64)?

    func changed(_ state: BrowserState) -> Shown? {
      let versions = (state.windows.version, state.profiles.version)
      return lock.withLock {
        if let seen = self.versions, seen == versions { return nil }
        self.versions = versions
        var shown = Shown()
        for window in state.windows.values where !window.incognito { shown.windows[window.id] = window.profileId }
        shown.profiles = Set(state.profiles.keys)
        guard shown != last else { return nil }
        last = shown
        return shown
      }
    }
  }

  private var started = false
  private var quitting = false
  private var history = ProfileWarmHistory()
  private var historyURL: URL?
  private var windows: [String: String]?
  private var schedule = IdleWarmSchedule(startedAt: ProcessInfo.processInfo.systemUptime)
  private var debounce = ProfileIntentDebounce()
  private var pendingHover: DispatchWorkItem?
  private var idleCheck: DispatchWorkItem?
  private var loading = Set<String>()
  private var observers: [NSObjectProtocol] = []
  private(set) var warmed: [[String: Any]] = []

  private init() {}

  static var enabled: Bool {
    !["0", "off", "false"].contains(ProcessInfo.processInfo.environment["SOLARA_PROFILE_WARMUP"] ?? "")
  }

  func startWhenReady(tries: Int = 40) {
    guard !started, Self.enabled else { return }
    guard let store = NativeStoreHandle.store else {
      guard tries > 0 else { return NSLog("[profiles] the native store never opened, so profile warm-up stays off") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startWhenReady(tries: tries - 1) }
      return
    }
    started = true
    schedule = IdleWarmSchedule(startedAt: ProcessInfo.processInfo.systemUptime)
    historyURL = ProfileWarmup.historyURL(
      environment: ProcessInfo.processInfo.environment,
      applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      bundleId: Bundle.main.bundleIdentifier)
    history = loadHistory()
    let feed = ShownFeed()
    if let shown = feed.changed(store.state) { observe(shown) }
    store.subscribe { commit in
      guard let shown = feed.changed(commit.state) else { return }
      if Thread.isMainThread {
        MainActor.assumeIsolated { NativeProfileWarmup.shared.observe(shown) }
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { NativeProfileWarmup.shared.observe(shown) } }
      }
    }
    for (name, quitting) in [("SolaraWillQuit", true), ("SolaraCoreQuitCancelled", false)] {
      observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { NativeProfileWarmup.shared.quitting = quitting }
      })
    }
    checkIdle()
  }

  private func observe(_ shown: Shown) {
    var changed = false
    if let windows {
      for (id, profileId) in shown.windows where windows[id] != nil && windows[id] != profileId {
        changed = history.switched(to: profileId) || changed
      }
    }
    windows = shown.windows
    changed = history.keepOnly(shown.profiles) || changed
    if changed { saveHistory() }
  }

  func hover(_ profileId: String?, source: String) {
    let now = ProcessInfo.processInfo.systemUptime
    let change = debounce.hover(profileId, now: now)
    if change == .keep { return }
    pendingHover?.cancel()
    pendingHover = nil
    guard case .schedule(let due) = change else { return }
    let work = DispatchWorkItem {
      MainActor.assumeIsolated {
        let warmup = NativeProfileWarmup.shared
        warmup.pendingHover = nil
        if let id = warmup.debounce.fire(now: ProcessInfo.processInfo.systemUptime) { warmup.warm(id, source: source) }
      }
    }
    pendingHover = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now), execute: work)
  }

  func warm(_ profileId: String, source: String) {
    guard started, !quitting, SolaraCoreHost.isStarted, let state = NativeStoreHandle.store?.state,
      !Ids.isIncognitoProfile(profileId), state.profiles[profileId] != nil else { return }
    warmEngine(state.engineProfile(profileId), source: source)
  }

  private func warmEngine(_ engine: String, source: String) {
    guard !loading.contains(engine), !SolaraCoreHost.isProfileLoaded(engine) else { return }
    loading.insert(engine)
    let startedAt = ProcessInfo.processInfo.systemUptime
    warmed.append(["engine": engine, "source": source, "at": startedAt])
    if warmed.count > 32 { warmed.removeFirst(warmed.count - 32) }
    SolaraCoreHost.ensureProfile(engine) { ok in
      MainActor.assumeIsolated {
        let warmup = NativeProfileWarmup.shared
        warmup.loading.remove(engine)
        if !ok { NSLog("[profiles] warm-up of %@ (%@) did not load", engine, source) }
      }
    }
  }

  private func checkIdle() {
    idleCheck?.cancel()
    idleCheck = nil
    guard let store = NativeStoreHandle.store, !quitting else { return }
    let state = store.state
    let shownEngines = Set(state.windows.values.map { state.engineProfile($0.incognito ? $0.originalProfileId ?? Ids.incognitoOriginal($0.profileId) : $0.profileId) })
    let settled = SolaraCoreHost.isStarted && shownEngines.allSatisfy { SolaraCoreHost.isProfileLoaded($0) }
    switch schedule.check(now: ProcessInfo.processInfo.systemUptime, inputIdleSeconds: Self.inputIdleSeconds, launchSettled: settled) {
    case nil: return
    case .wait(let seconds):
      let work = DispatchWorkItem { MainActor.assumeIsolated { NativeProfileWarmup.shared.checkIdle() } }
      idleCheck = work
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    case .warm:
      var engines: [String: String] = [:]
      for id in state.profiles.keys where !Ids.isIncognitoProfile(id) { engines[id] = state.engineProfile(id) }
      guard let engine = ProfileWarmup.idleTarget(
        recent: history.recent, engines: engines, shownEngines: shownEngines,
        loadAll: state.settings.loadAllProfilesAtLaunch, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else { return }
      warmEngine(engine, source: "idle")
    }
  }

  private static var inputIdleSeconds: Double {
    guard NSRunningApplication.current.isActive else { return 3600 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
  }

  private func loadHistory() -> ProfileWarmHistory {
    guard let historyURL, let data = try? Data(contentsOf: historyURL) else { return ProfileWarmHistory() }
    return (try? JSONDecoder().decode(ProfileWarmHistory.self, from: data)) ?? ProfileWarmHistory()
  }

  private func saveHistory() {
    guard let historyURL, let data = try? JSONEncoder().encode(history) else { return }
    try? data.write(to: historyURL, options: .atomic)
  }

  #if DEBUG
  func dev(_ action: String) -> String {
    let info: [String: Any] = [
      "enabled": Self.enabled, "started": started, "recent": history.recent, "idleDone": schedule.done,
      "startedAt": schedule.startedAt, "now": ProcessInfo.processInfo.systemUptime, "warmed": warmed, "loading": Array(loading), "hoverPending": debounce.pending ?? NSNull(),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
  #endif
}
