import Foundation
import Synchronization
import SolaraCore
internal import SolaraModel
internal import SolaraStore
internal import SolaraUI

@MainActor
final class NativeTabSleep {
  private let store: Store
  private let runner: TabSleepRunner
  private var lifecycle: Int?
  private var settingsObserver: Int?
  private var feedObserver: NSObjectProtocol?
  private var stopped = false
  private var loadedProfiles = Set<String>()
  private var cancelProfileRelease: (@MainActor () -> Void)?
  private var configured: (sleeps: Bool, minutes: Int)?
  private nonisolated let running = Mutex(false)
  nonisolated static let runningChanged = Notification.Name("SolaraNativeTabSleepRunningChanged")

  var isRunning: Bool { runner.isRunning }

  nonisolated var runningNow: Bool { running.withLock { $0 } }

  func sleepOnRequest(_ id: String) async -> Bool? {
    guard runner.isRunning else { return nil }
    return await runner.sleepOnRequest(id)
  }

  func sweepNow() async -> [String] { await runner.sweep() }

  func setPressure(_ pressure: TabSleepPolicy.Pressure) { runner.setMemoryPressure(pressure) }

  init(store: Store) {
    self.store = store
    runner = TabSleepRunner(store: store, pendingPermission: { TabSleepPermissionFeed.pending?($0) != false })
    PageIssuer.lifecycleObservers.append { [weak self] issuer, binding, event, _ in
      guard let self, !self.stopped, issuer.store === self.store, event == "onReady",
        !binding.profile.isEmpty, !Ids.isIncognitoProfile(binding.profile) else { return }
      self.loadedProfiles.insert(binding.profile)
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
    feedObserver = NotificationCenter.default.addObserver(forName: TabSleepPermissionFeed.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reconcile() }
    }
    settingsObserver = store.subscribe { [weak self] commit in
      let settings = commit.state.settings
      let wanted = (sleeps: settings["sleepInactiveTabs"]?.bool != false, minutes: KeepAwakeSites.sleepAfterMinutes(settings["sleepTabsAfterMinutes"]))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !self.stopped, self.configured?.sleeps != wanted.sleeps || self.configured?.minutes != wanted.minutes else { return }
          self.reconcile()
        }
      }
    }
  }

  private func reconcile() {
    guard !stopped else { return }
    let ownsStore = NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store
    if ownsStore {
      if cancelProfileRelease == nil {
        cancelProfileRelease = TabSleepRunner.scheduleTicks(30_000) { [weak self] in self?.releaseUnusedProfiles() }
      }
    } else {
      cancelProfileRelease?()
      cancelProfileRelease = nil
      loadedProfiles.removeAll()
    }
    let settings = store.state.settings
    let sleeps = settings["sleepInactiveTabs"]?.bool != false
    let minutes = KeepAwakeSites.sleepAfterMinutes(settings["sleepTabsAfterMinutes"])
    configured = (sleeps, minutes)
    runner.policy = TabSleepPolicy.Configuration(idleMs: Double(minutes) * 60_000)
    let wanted = sleeps && LaunchSwitches.shared.isOn(.nativeTabSleep) && !NativeStore.safeMode && NativeStoreHandle.ownsWorkspace && TabSleepPermissionFeed.servesPages
    guard wanted, NativeStoreHandle.store === store else {
      runner.stop()
      publishRunning(startPending: wanted && NativeStoreHandle.resolve == nil)
      return
    }
    let wasRunning = running.withLock { value in
      defer { value = true }
      return value
    }
    runner.start()
    if !wasRunning, runner.isRunning { NotificationCenter.default.post(name: Self.runningChanged, object: nil, userInfo: ["running": true]) }
    publishRunning()
  }

  private func releaseUnusedProfiles() {
    guard !loadedProfiles.isEmpty, !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace,
      NativeStoreHandle.store === store else { return }
    let inUse = store.sequence {
      let state = store.state
      let profiles = state.windows.values.map { state.engineProfile($0.profileId) }
      let pageProfiles = PageRegistry.shared.descriptors.compactMap { descriptor in
        state.tabs[descriptor.tabID].map { state.engineProfile($0.profileId) }
      }
      return Set(profiles + pageProfiles)
    }
    let unused = loadedProfiles.subtracting(inUse)
    loadedProfiles.subtract(unused)
    for profile in unused { SolaraCoreHost.releaseProfile(profile) }
  }

  private func publishRunning(startPending: Bool = false) {
    let runner = runner
    if runner.isRunning {
      HeavyTabs.sleep = { (id: String) async -> Bool in await runner.sleepOnRequest(id) }
    } else {
      HeavyTabs.sleep = nil
    }
    let now = runner.isRunning || startPending
    let changed = running.withLock { value in
      defer { value = now }
      return value != now
    }
    if changed { NotificationCenter.default.post(name: Self.runningChanged, object: nil, userInfo: ["running": now]) }
  }

  nonisolated func stop() {
    if Thread.isMainThread { MainActor.assumeIsolated { stopOnMain() } }
    else { DispatchQueue.main.sync { MainActor.assumeIsolated { stopOnMain() } } }
  }

  private func stopOnMain() {
    stopped = true
    cancelProfileRelease?()
    cancelProfileRelease = nil
    loadedProfiles.removeAll()
    runner.stop()
    publishRunning()
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let settingsObserver { store.unsubscribe(settingsObserver) }
    settingsObserver = nil
    if let feedObserver { NotificationCenter.default.removeObserver(feedObserver) }
    feedObserver = nil
  }
}
