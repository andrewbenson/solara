import Foundation
import SolaraStore
import SolaraUI
import Synchronization

final class ThemeScopeFeed: Sendable {
  private let current = Mutex<Store?>(nil)
  @MainActor private var lifecycle: Int?
  @MainActor private var subscription: Int?
  @MainActor private var onChange: (@MainActor () -> Void)?

  func snapshot(windowId: String?, pageProfileId: String?) -> String? {
    guard let store = current.withLock({ $0 }) else { return nil }
    let projection = ThemeScopeProjection.project(store.displayState, windowId: windowId, pageProfileId: pageProfileId)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(projection) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  @MainActor func start(_ onChange: @escaping @MainActor () -> Void) {
    self.onChange = onChange
    if lifecycle == nil {
      lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.bind() }
    } else {
      bind()
    }
  }

  @MainActor func stop() {
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    onChange = nil
    replace(nil)
  }

  @MainActor private func bind() {
    replace(NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil)
  }

  @MainActor private func replace(_ next: Store?) {
    let prior = current.withLock { store -> Store? in
      let prior = store
      store = next
      return prior
    }
    guard prior !== next else { return }
    if let subscription { prior?.unsubscribe(subscription) }
    subscription = next?.subscribe { [weak self, weak next] commit in
      guard ThemeScopeProjection.mayChange(commit.changes) else { return }
      DispatchQueue.main.async {
        guard let self, let next, self.current.withLock({ $0 }) === next else { return }
        self.onChange?()
      }
    }
    onChange?()
  }
}
