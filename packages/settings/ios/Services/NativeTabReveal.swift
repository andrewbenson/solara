import Foundation
import SolaraCore
import SolaraStore
import SolaraUI
import Synchronization

@MainActor
enum NativeTabReveal {
  private static var lifecycle: Int?
  private static weak var store: Store?
  private static var observer: Int?

  static func install() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { bind() }
  }

  private static func bind() {
    let next = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard next !== store else { return }
    if let observer { store?.unsubscribe(observer) }
    observer = nil
    store = next
    guard let next else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    observer = next.sequence {
      let previous = Mutex(next.state)
      let revision = next.rev
      return next.subscribe { [weak next] commit in
        guard commit.rev > revision else { return }
        let before = previous.withLock { state in
          defer { state = commit.state }
          return state
        }
        let windows = commit.changes.windows.upserted.filter { before.activeTabId($0) != commit.state.activeTabId($0) }
        guard !windows.isEmpty else { return }
        let apply: @MainActor @Sendable () -> Void = { [weak next] in
          guard let next, next === store, generation == NativeStoreHandle.ownershipGeneration,
            !NativeStoreHandle.frozen else { return }
          let current = next.state
          for id in windows {
            let selected = current.activeTabId(id)
            guard selected == commit.state.activeTabId(id),
              current.windows[id]?.profileId == commit.state.windows[id]?.profileId,
              current.peeks[id] == commit.state.peeks[id],
              selected.map({ current.tabs[$0]?.adoptId == commit.state.tabs[$0]?.adoptId }) != false else { continue }
            switch TabReveal.transition(windowId: id, before: before, after: current, sharing: NativeDisplayCapture.hasTabShare,
              runtime: { PageIssuer.shared?.runtimeState(tabId: $0) }, scrolledDown: AutoHideHost.scrolledDown) {
            case .drop(let source): SolaraCoreWebView.dropTabReveals(source)
            case .tab(let tab): SolaraCoreWebView.revealTab(tab)
            case .offered(let offer, let source): SolaraCoreWebView.revealOffered(offer, over: source)
            case nil: break
            }
          }
        }
        if Thread.isMainThread { MainActor.assumeIsolated { apply() } }
        else { DispatchQueue.main.async(execute: apply) }
      }
    }
  }
}
