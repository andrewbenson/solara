import AppKit
import SolaraCore
import SolaraEngine
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraStoreAdapter
import SolaraUI

@MainActor
enum NativeBookmarkHolderRestoration {
  private static let restoration = BookmarkHolderRestoration()

  private static var safeMode: Bool {
    SolaraCoreHost.safeMode || LaunchSwitches.shared.safeMode || DocumentStore.safeMode
  }

  private static func holders(windowId: String? = nil) -> [BookmarkHolder] {
    guard let store = NativeStoreHandle.store, let owner = NativeBookmarkOwner.displayCurrent else { return [] }
    let state = store.state
    var profiles = state.profileOrder
    if let windowId, let window = state.windows[windowId] {
      let profile = state.bookmarkProfileId(window)
      profiles = [profile] + profiles.filter { $0 != profile }
    }
    var engines = Set<JSKey>()
    let catalogs = profiles.compactMap { profile -> BookmarkHolderCatalog? in
      guard !Ids.isIncognitoProfile(profile), !engines.contains(JSKey(state.engineProfile(profile))),
        let snapshot = try? owner.snapshot(profile: profile), snapshot.hasView,
        snapshot.binding.engine == state.engineProfile(profile) else { return nil }
      engines.insert(JSKey(snapshot.binding.engine))
      return BookmarkHolderCatalog(profile: profile, snapshot: snapshot)
    }
    return BookmarkHolderRestoration.holders(in: catalogs)
  }

  static func count() -> Int { holders().count }

  static func beginDrain() -> @MainActor () async -> Void { restoration.beginDrain() }

  static func restoreAll() async -> Int {
    await restore(id: nil, windowId: nil)
    return count()
  }

  static func restore(id: String?, windowId: String?) async {
    guard !restoration.draining else { return }
    if safeMode { showSafeMode(); return }
    guard let store = SettingsDirectWrites.store, let native = NativeStore.shared,
      let owner = NativeBookmarkOwner.writableCurrent else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    let preferred = windowId.flatMap { store.state.windows[$0] }.map { store.state.engineProfile(store.state.bookmarkProfileId($0)) }
    let available = holders(windowId: windowId)
    let targets: [BookmarkHolder]
    if let id {
      targets = Array(available.lazy.filter { $0.id == id && (preferred == nil || $0.binding.engine == preferred) }.prefix(1))
    } else {
      targets = available
    }
    let tasks = targets.compactMap { holder -> Task<Void, Never>? in
      guard (try? owner.binding(profile: holder.profile)) == holder.binding else { return nil }
      return restoration.start(holder, safeMode: false, refuse: {}, place: {
        place($0, near: windowId, store: store)
      }, remove: { holder, mutations in
        do {
          let saved = await Task.detached { native.flush(timeout: 2) }.value
          guard saved == .saved else { throw BookmarkWriterError.refused(saved.description) }
          guard NativeStoreHandle.ownershipGeneration == generation, SettingsDirectWrites.store === store,
            NativeBookmarkOwner.writableCurrent === owner else { throw BookmarkWriterError.staleBinding }
          _ = try await owner.submitAsync(profile: holder.profile, mutations: mutations, binding: holder.binding)
        } catch {
          NSLog("[bookmarks] Arc folder removal failed: %@", String(describing: error))
          throw error
        }
      })
    }
    for task in tasks { await task.value }
  }

  private static func place(_ holder: BookmarkHolder, near: String?, store: Store) -> Set<String> {
    let before = store.state
    let regular = { (id: String) in
      before.windows[id].map { !$0.incognito && !$0.isSmall } == true && !store.memory.closingWindows.contains(id)
    }
    let windows = (before.ui.focusOrder + before.windowOrder).filter(regular)
    let window = near.flatMap { regular($0) && before.windows[$0]?.profileId == holder.profile ? $0 : nil }
      ?? windows.first { before.windows[$0]?.profileId == holder.profile } ?? windows.first
    var draft: JSONObject = ["tabs": [], "drafts": .array(holder.drafts)]
    if let window { draft["windowId"] = .string(window) }
    else { draft["newWindow"] = true }
    let payload: JSONValue = ["profileId": .string(holder.profile), "windows": [.object(draft)]]
    guard let result = SettingsDirectWrites.write(store, Command("importWorkspace", [payload]))?.result else { return [] }
    NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
    FrameUpdates.flush()
    return Set(result["carried"]?.array?.compactMap(\.string) ?? [])
  }

  private static func showSafeMode() {
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "Safe Mode"
      alert.informativeText = "Imported tabs, spaces, pinned tabs and new profiles cannot be saved in safe mode. Open Solara normally to import them."
      alert.addButton(withTitle: "OK")
      if let window = NativeImportWindow.hosting?.view.window, window.isVisible {
        alert.beginSheetModal(for: window, completionHandler: nil)
      } else {
        alert.runModal()
      }
    }
  }
}
