import Foundation
internal import SolaraModel
internal import SolaraStore
internal import SolaraUI

@MainActor
final class NativeTabSleep {
  private let store: Store
  private let runner: TabSleepRunner
  private var lifecycle: Int?

  var isRunning: Bool { runner.isRunning }

  func sweepNow() async -> [String] { await runner.sweep() }

  func setPressure(_ pressure: TabSleepPolicy.Pressure) { runner.setMemoryPressure(pressure) }

  init(store: Store) {
    self.store = store
    runner = TabSleepRunner(store: store, pendingPermission: { TabSleepPermissionFeed.pending?($0) != false })
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
  }

  private func reconcile() {
    guard LaunchSwitches.shared.isOn(.nativeTabSleep), !NativeStore.safeMode,
      NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else {
      runner.stop()
      return
    }
    runner.start()
  }

  nonisolated func stop() {
    if Thread.isMainThread { MainActor.assumeIsolated { stopOnMain() } }
    else { DispatchQueue.main.sync { MainActor.assumeIsolated { stopOnMain() } } }
  }

  private func stopOnMain() {
    runner.stop()
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
  }
}
