import AppKit
import SolaraCore
internal import SolaraStore
internal import SolaraUI

@MainActor
final class NativePrivateSessionEffects {
  private let owner = UUID().uuidString
  private let store: Store
  nonisolated private let effects: PrivateSessionEffects
  private var lifecycle: Int?
  private var closed: NSObjectProtocol?
  private var started = false

  init(store: Store) {
    self.store = store
    effects = PrivateSessionEffects(store: store, begin: { session, generation in
      NativePrivateSessionCleanup.beginWebKitSession(session, generation: generation)
      SolaraCoreServices.setPrivateSessionGeneration(session, generation: generation)
    }, end: { ended in
      NativePrivateSessionCleanup.endWebKitSession(ended.session)
      SolaraCoreHost.endPrivateSession(ended.session, aliases: ended.engineProfiles)
      PageIssuer.shared?.endPrivateSession(engineProfiles: ended.engineProfiles)
      NotificationCenter.default.post(name: Notification.Name("SolaraPrivateSessionEnded"), object: nil,
        userInfo: ["aliases": ended.engineProfiles])
    })
    closed = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPrivateWindowClosed"), object: nil, queue: .main) { [weak self] note in
      guard let id = note.userInfo?["id"] as? String else { return }
      MainActor.assumeIsolated { self?.effects.confirmWindowClosed(id) }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
  }

  private func reconcile() {
    let owns = NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store
    if owns { NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: owner) }
    guard owns else {
      if started { stop() }
      return
    }
    started = true
    effects.start()
  }

  nonisolated func stop() {
    effects.stop()
    DispatchQueue.main.async { MainActor.assumeIsolated { self.removeObservers() } }
  }

  private func removeObservers() {
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: owner)
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    if let closed { NotificationCenter.default.removeObserver(closed) }
    lifecycle = nil
    closed = nil
  }
}
