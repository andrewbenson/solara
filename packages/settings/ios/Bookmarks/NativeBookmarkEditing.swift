import AppKit
import SolaraEngine
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
struct NativeBookmarkEditing {
  let store: Store
  let target: BookmarkFormTarget
  private let generation: Int

  init?(windowId: String) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let target = BookmarkFormTarget.resolve(windowId: windowId, state: store.state, closing: store.memory.closingWindows) else { return nil }
    self.store = store
    self.target = target
    generation = NativeStoreHandle.ownershipGeneration
  }

  var live: Bool {
    NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store && NativeStoreHandle.ownershipGeneration == generation
      && target.isLive(in: store.state, closing: store.memory.closingWindows)
  }

  var windowId: String { target.windowId }
  var profile: String { target.profileId }

  func snapshot() -> BookmarkWriterSnapshot? {
    guard live, let owner = NativeBookmarkOwner.displayCurrent, let view = try? owner.snapshot(profile: profile),
      view.hasView, view.binding.engine == target.engine else { return nil }
    return view
  }

  func write(_ mutations: [BookmarkMutation], binding expected: BookmarkWriterBinding? = nil) async throws -> BookmarkReceipt {
    guard live else { throw BookmarkWriterError.staleBinding }
    guard let owner = NativeBookmarkOwner.writableCurrent else { throw BookmarkWriterError.notOwned }
    let binding = try owner.binding(profile: profile)
    guard binding.engine == target.engine, expected == nil || binding == expected else { throw BookmarkWriterError.staleBinding }
    return try await owner.submitAsync(profile: profile, mutations: mutations, binding: binding)
  }

  func report(_ error: Error, showToast: Bool = true) {
    if case .expired? = error as? BookmarkWriterError { return }
    guard live else { return }
    let description = String(describing: error)
    NSLog("[bookmarks] edit failed: %@", description)
    guard showToast, let host = WindowHost.contentView(windowId) else { return }
    if description.contains("savedUnconfirmed") || description.contains("may have been saved") {
      LinkToast.show(in: host, title: "Bookmark save unconfirmed",
        message: "This change may have been saved. Bookmark edits and sync are paused until Solara restarts.")
    } else {
      LinkToast.show(in: host, title: "Bookmark not saved", message: "Solara couldn’t save that bookmark change. Try it again.")
    }
  }
}
