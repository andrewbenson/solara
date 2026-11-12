import Foundation
import SolaraEngine

@MainActor
final class NativeBookmarkInstallation {
  private let ownsSelection: Bool
  private let safeMode: Bool
  private let prepare: @MainActor () async throws -> NativeBookmarkOwner
  private let attach: @MainActor (NativeBookmarkOwner) async throws -> Void
  private var task: Task<Void, Error>?
  private var lifetime = 0
  private weak var installedOwner: NativeBookmarkOwner?

  init(selected: Bool, safeMode: Bool, selectionAlreadyLatched: Bool = false, prepare: @escaping @MainActor () async throws -> NativeBookmarkOwner, attach: @escaping @MainActor (NativeBookmarkOwner) async throws -> Void) {
    self.prepare = prepare
    self.attach = attach
    self.safeMode = safeMode
    ownsSelection = selectionAlreadyLatched || NativeBookmarkOwner.selectOwnership()
    if ownsSelection, !selected {
      NativeBookmarkOwner.failOwnership(reason: "Native bookmarks are disabled for this development launch. Editing and sync are paused.")
    }
  }

  func ensureReady() async throws {
    if let owner = NativeBookmarkOwner.current, task != nil,
      NativeBookmarkOwner.ownershipState.phase == .owned || NativeBookmarkOwner.ownershipState.phase == .readOnlyUnavailable,
      isInstalled(owner) { return }
    guard ownsSelection, NativeBookmarkOwner.ownershipState.phase == .starting else { throw BookmarkWriterError.notOwned }
    if let task { return try await task.value }
    let ticket = lifetime
    let task = Task { @MainActor in
      var prepared: NativeBookmarkOwner?
      do {
        let owner = try await prepare()
        prepared = owner
        guard lifetime == ticket, !Task.isCancelled, NativeBookmarkOwner.ownershipState.phase == .starting else { throw BookmarkWriterError.notOwned }
        await NativeBookmarkOwner.setCurrent(owner)
        guard lifetime == ticket, !Task.isCancelled, NativeBookmarkOwner.ownershipState.phase == .starting else { throw BookmarkWriterError.notOwned }
        try await attach(owner)
        guard lifetime == ticket, !Task.isCancelled, NativeBookmarkOwner.completeOwnership(owner, readOnly: safeMode) else { throw BookmarkWriterError.notOwned }
        installedOwner = owner
      } catch {
        if lifetime == ticket { NativeBookmarkOwner.failOwnership(reason: String(describing: error)) }
        prepared?.stop(preservingUnavailable: lifetime == ticket)
        if lifetime != ticket, let prepared, NativeBookmarkOwner.current === prepared { NativeBookmarkOwner.current = nil }
        throw error
      }
    }
    self.task = task
    try await task.value
  }

  private func isInstalled(_ owner: NativeBookmarkOwner) -> Bool {
    owner === installedOwner && owner.hasInstalledCatalog
  }

  func stop() {
    lifetime += 1
    task?.cancel()
    NativeBookmarkOwner.current?.stop()
    NativeBookmarkOwner.current = nil
  }
}
