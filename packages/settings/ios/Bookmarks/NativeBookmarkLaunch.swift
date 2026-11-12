import Foundation
import SolaraCore
import SolaraEngine
import SolaraModel
import SolaraShell
import SolaraStore

enum NativeBookmarkLaunch {
  private static let selection = makeSelection()

  private static func makeSelection() -> Bool {
    DocumentStore.registerBookmarkQuitBarrier(flush: { completion in
      Task { @MainActor in
        do {
          try await NativeBookmarkOwner.flushJournalForQuit()
          completion(true)
        } catch { completion(false) }
      }
    }, cancel: { NativeBookmarkOwner.cancelJournalQuit() })
    let owned = NativeBookmarkOwner.selectOwnership()
    if owned, !LaunchSwitches.shared.isOn(.nativeBookmarks) {
      NativeBookmarkOwner.failOwnership(reason: "Native bookmarks are disabled for this development launch. Editing and sync are paused.")
    }
    return owned
  }

  static func select() { _ = selection }

  @MainActor private static let installation: NativeBookmarkInstallation = makeInstallation()

  @MainActor private static func makeInstallation() -> NativeBookmarkInstallation {
    NativeBookmarkInstallation(
      selected: LaunchSwitches.shared.isOn(.nativeBookmarks),
      safeMode: LaunchSwitches.shared.safeMode || DocumentStore.safeMode,
      selectionAlreadyLatched: selection,
      prepare: {
        guard NativeStoreHandle.ownsWorkspace,
          ["ac_bookmarks_tree", "ac_bookmarks_apply", "ac_bookmarks_watch", "ac_bookmarks_canonicalize_url_v1"].allSatisfy({ SolaraCoreEngineBridge.exports($0) }),
          let state = NativeStoreHandle.store?.state else { throw BookmarkWriterError.notOwned }
        let directory = try await Task.detached { try DocumentStore.directoryURL() }.value
        return await NativeBookmarkWriter.prepare(directory: directory, state: state, cacheDirectory: directory, readOnly: LaunchSwitches.shared.safeMode || DocumentStore.safeMode, stampsEnabled: true)
      },
      attach: { owner in
        guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store != nil else { throw BookmarkWriterError.notOwned }
        let catalog = NativeHistoryCatalog.catalog
        try await owner.start(
          catalog: catalog, client: BookmarkEngineClient(NativeHistoryCatalog.client),
          clock: .init(
            wallTimeMs: { (Date().timeIntervalSince1970 * 1000).rounded(.down) },
            monotonicTimeMs: { ProcessInfo.processInfo.systemUptime * 1000 }),
          scheduler: .init(schedule: { delay, action in
            let task = Task { @MainActor in
              do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
              action()
            }
            return { task.cancel() }
          }))
        owner.subscribeToStoreCommits()
        await owner.settleStoreSubscription()
        guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store != nil, owner.installationIsUsable(catalog: catalog) else { throw BookmarkWriterError.notOwned }
      })
  }

  @MainActor static func ensureReady() async throws {
    try await installation.ensureReady()
  }
}
