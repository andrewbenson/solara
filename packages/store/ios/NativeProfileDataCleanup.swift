import AppKit
import Darwin
import SolaraCore
internal import SolaraStore
internal import SolaraEngine

@MainActor
final class NativeProfileDataCleanup {
  private let store: Store
  private let cleanup: ProfileDataCleanup
  private var lifecycle: Int?
  private var launchObserver: NSObjectProtocol?
  private var applicationReady = false
  private var readiness: Task<Void, Never>?

  init(store: Store) {
    self.store = store
    cleanup = ProfileDataCleanup(store: store, delete: { engine, done in
      let env = ProcessInfo.processInfo.environment
      if env["SOLARA_TEST_PROFILE_DELETE_CRASH"] == "after-ledger", NativeProfileDataCleanup.testHooksAllowed(env) {
        FileHandle.standardError.write(Data("[profile-delete] point after-ledger\n".utf8))
        _exit(86)
      }
      SolaraProfileData.delete(engine, liveProfiles: { store.snapshot.state.profiles.values.map { ($0.dataId ?? $0.id) == "default" ? "" : ($0.dataId ?? $0.id) } }, completion: done) }, retireBookmarks: { engine in
      try NativeBookmarkOwner.retireBookmarksForCleanup(engine: engine)
    }, settleBookmarks: { engine in
      try await NativeBookmarkOwner.settleBookmarkEngine(engine: engine)
    }, trouble: { engine, remaining in
      NSLog("[store] couldn't delete profile data (%@): %@", engine, remaining.joined(separator: ", "))
      let env = ProcessInfo.processInfo.environment
      if remaining == ["Chromium deletion pending restart"], env["SOLARA_TEST_PROFILE_DELETE_CRASH"] == "pending-restart", NativeProfileDataCleanup.testHooksAllowed(env) {
        FileHandle.standardError.write(Data("[profile-delete] point pending-restart \(engine)\n".utf8))
        _exit(86)
      }
    })
    Self.deleteUnloadedFixture(store)
    launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.applicationReady = true
        self?.reconcile()
      }
    }
    applicationReady = NSRunningApplication.current.isFinishedLaunching
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
  }

  private static func testHooksAllowed(_ env: [String: String]) -> Bool {
    env["SOLARA_TEST_REKEY"] == "1"
      && env["SOLARA_DATA_DIR"].map { !$0.isEmpty } == true
      && env["SOLARA_TEST_KEYCHAIN"] == "file"
      && !SolaraCoreHost.chromeUsesRealKeychain
      && SolaraCoreTestHooksAllowed()
  }

  private static func deleteUnloadedFixture(_ store: Store) {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["SOLARA_TEST_PROFILE_DELETE_UNLOADED"], !id.isEmpty, testHooksAllowed(env),
      NativeStore.ownsWorkspace, !store.config.safeMode, !SolaraCoreHost.isStarted,
      id != "default", ProfileDataCleanup.validProfileId(id) else { return }
    let state = store.snapshot.state
    guard let profile = state.profiles[id], (profile.dataId ?? profile.id) == id,
      !state.tabs.values.contains(where: { $0.profileId == id }),
      !state.windows.values.contains(where: { $0.profileId == id || $0.originalProfileId == id }) else { return }
    do {
      try store.dispatch(Command("deleteProfile", [.string(id)]))
      let deleted = store.snapshot.state
      guard deleted.profiles[id] == nil, deleted.orphanedProfileData.contains(id) else { return }
      FileHandle.standardError.write(Data("[profile-delete] point delete-unloaded \(id)\n".utf8))
    } catch {
      NSLog("[profile-delete] unloaded fixture command failed: %@", String(describing: error))
    }
  }

  isolated deinit {
    cleanup.stop()
    readiness?.cancel()
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
  }

  nonisolated func stop() {
    cleanup.stop()
    if Thread.isMainThread {
      MainActor.assumeIsolated { removeObservers() }
    } else {
      Task { @MainActor [weak self] in self?.removeObservers() }
    }
  }

  private func reconcile() {
    guard !cleanup.isStopped else { return }
    let owns = NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store
    let engineReady = SolaraCoreHost.isStarted
    cleanup.updateOwnership(owns, applicationReady: applicationReady, engineReady: engineReady)
    if cleanup.isStopped { removeObservers(); return }
    guard owns, applicationReady, !store.config.safeMode, !engineReady, readiness == nil else { return }
    readiness = Task { [weak self] in
      let deadline = ContinuousClock.now + .seconds(60)
      while ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, !self.cleanup.isStopped else { return }
        if SolaraCoreHost.isStarted {
          self.readiness = nil
          self.reconcile()
          return
        }
      }
      guard let self else { return }
      NSLog("[store] profile cleanup: engine wasn't ready within 60 seconds; keeping queued data")
      self.stop()
    }
  }

  private func removeObservers() {
    readiness?.cancel()
    readiness = nil
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
    launchObserver = nil
  }
}
