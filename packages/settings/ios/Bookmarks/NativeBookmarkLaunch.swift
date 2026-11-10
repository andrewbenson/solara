import Foundation
import SolaraCore
import SolaraEngine
import SolaraModel
import SolaraShell
import SolaraStore

@MainActor
enum NativeBookmarkLaunch {
  private static let productionInstallationEnabled = false
  private static let installation: NativeBookmarkInstallation = makeInstallation()

  private static func makeInstallation() -> NativeBookmarkInstallation {
    NativeBookmarkInstallation(
      selected: productionInstallationEnabled && LaunchSwitches.shared.isOn(.nativeBookmarks),
      safeMode: LaunchSwitches.shared.safeMode || DocumentStore.safeMode,
      prepare: {
        guard NativeStoreHandle.ownsWorkspace,
          ["ac_bookmarks_tree", "ac_bookmarks_apply", "ac_bookmarks_watch"].allSatisfy({ SolaraCoreEngineBridge.exports($0) }),
          let state = NativeStoreHandle.store?.state else { throw BookmarkWriterError.notOwned }
        let directory = try await Task.detached { try DocumentStore.directoryURL() }.value
        return await NativeBookmarkOwner.prepare(directory: directory, state: state, cacheDirectory: directory, stampsEnabled: true)
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

  static func ensureReady() async throws {
    try await installation.ensureReady()
  }
}
