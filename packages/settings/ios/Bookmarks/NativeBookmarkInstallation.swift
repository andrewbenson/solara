import Foundation
import SolaraEngine

@MainActor
final class NativeBookmarkInstallation {
  private let selected: Bool
  private let ownsSelection: Bool
  private let prepare: @MainActor () async throws -> NativeBookmarkOwner
  private let attach: @MainActor (NativeBookmarkOwner) async throws -> Void
  private var task: Task<Void, Error>?
  private var lifetime = 0

  init(selected: Bool, safeMode: Bool, prepare: @escaping @MainActor () async throws -> NativeBookmarkOwner, attach: @escaping @MainActor (NativeBookmarkOwner) async throws -> Void) {
    self.selected = selected
    self.prepare = prepare
    self.attach = attach
    ownsSelection = selected && NativeBookmarkOwner.selectOwnership()
    if ownsSelection, safeMode {
      NativeBookmarkOwner.failOwnership(reason: "Bookmarks are read-only in safe mode. Editing and sync are paused.")
    }
  }

  func ensureReady() async throws {
    if !selected, NativeBookmarkOwner.ownershipState.phase == .legacy { return }
    if NativeBookmarkOwner.ownershipState.phase == .owned { return }
    guard ownsSelection, NativeBookmarkOwner.ownershipState.phase == .starting else { throw BookmarkWriterError.notOwned }
    if let task { return try await task.value }
    let ticket = lifetime
    let task = Task { @MainActor in
      var prepared: NativeBookmarkOwner?
      do {
        let owner = try await prepare()
        prepared = owner
        guard lifetime == ticket, !Task.isCancelled, NativeBookmarkOwner.ownershipState.phase == .starting else { throw BookmarkWriterError.notOwned }
        NativeBookmarkOwner.current = owner
        try await attach(owner)
        guard lifetime == ticket, !Task.isCancelled, NativeBookmarkOwner.completeOwnership(owner) else { throw BookmarkWriterError.notOwned }
      } catch {
        if lifetime == ticket { NativeBookmarkOwner.failOwnership(reason: String(describing: error)) }
        prepared?.stop()
        throw error
      }
    }
    self.task = task
    try await task.value
  }

  func stop() {
    lifetime += 1
    task?.cancel()
    NativeBookmarkOwner.current?.stop()
    NativeBookmarkOwner.current = nil
  }
}
