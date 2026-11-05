import Foundation
import Synchronization
internal import SolaraModel
internal import SolaraStore
internal import SolaraUI

@MainActor
final class NativeTabSleep {
  private let store: Store
  private let runner: TabSleepRunner
  private var lifecycle: Int?
  private var settingsObserver: Int?
  private var stopped = false
  private var configured: (sleeps: Bool, minutes: Int)?
  private nonisolated let running = Mutex(false)

  var isRunning: Bool { runner.isRunning }

  nonisolated var runningNow: Bool { running.withLock { $0 } }

  func sweepNow() async -> [String] { await runner.sweep() }

  func setPressure(_ pressure: TabSleepPolicy.Pressure) { runner.setMemoryPressure(pressure) }

  init(store: Store) {
    self.store = store
    runner = TabSleepRunner(store: store, pendingPermission: { TabSleepPermissionFeed.pending?($0) != false })
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
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
    let settings = store.state.settings
    let sleeps = settings["sleepInactiveTabs"]?.bool != false
    let minutes = KeepAwakeSites.sleepAfterMinutes(settings["sleepTabsAfterMinutes"])
    configured = (sleeps, minutes)
    runner.policy = TabSleepPolicy.Configuration(idleMs: Double(minutes) * 60_000)
    let wanted = sleeps && LaunchSwitches.shared.isOn(.nativeTabSleep) && !NativeStore.safeMode && NativeStoreHandle.ownsWorkspace
    guard wanted, NativeStoreHandle.store === store else {
      runner.stop()
      publishRunning(startPending: wanted && NativeStoreHandle.resolve == nil)
      return
    }
    running.withLock { $0 = true }
    runner.start()
    publishRunning()
  }

  private func publishRunning(startPending: Bool = false) {
    let now = runner.isRunning || startPending
    running.withLock { $0 = now }
  }

  nonisolated func stop() {
    if Thread.isMainThread { MainActor.assumeIsolated { stopOnMain() } }
    else { DispatchQueue.main.sync { MainActor.assumeIsolated { stopOnMain() } } }
  }

  private func stopOnMain() {
    stopped = true
    runner.stop()
    publishRunning()
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let settingsObserver { store.unsubscribe(settingsObserver) }
    settingsObserver = nil
  }
}
