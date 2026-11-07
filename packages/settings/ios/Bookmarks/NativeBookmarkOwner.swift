import Foundation
import SolaraEngine
import SolaraModel
import Synchronization

struct BookmarkWriterBinding: Equatable, Sendable {
  let engine: String
  let generation: UInt64
}

enum BookmarkWriterError: Error, Equatable, CustomStringConvertible {
  case notOwned
  case staleBinding
  case invalidDocument(String)
  case refused(String)

  var description: String {
    switch self {
    case .notOwned: "native bookmarks are not owned by this launch"
    case .staleBinding: "the bookmark owner changed since this binding was taken"
    case .invalidDocument(let reason): "invalid bookmark document: \(reason)"
    case .refused(let reason): "bookmark replacement refused: \(reason)"
    }
  }
}

struct BookmarkWriterSnapshot: Sendable {
  let binding: BookmarkWriterBinding
  let revision: UInt64
  let ready: Bool
  let document: JSONValue
}

final class NativeBookmarkOwner: @unchecked Sendable {
  private static let slot = Mutex<NativeBookmarkOwner?>(nil)
  static var current: NativeBookmarkOwner? {
    get { slot.withLock { $0 } }
    set { slot.withLock { $0 = newValue } }
  }

  let coordinator: BookmarkCoordinator
  private let fence = NSLock()
  private var generation: UInt64 = 1
  private let wake: @Sendable (String) -> Void

  init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, launchInput: BookmarkLaunchInput = .init(), wake: @escaping @Sendable (String) -> Void) {
    coordinator = BookmarkCoordinator(profiles: profiles, defaultProfile: defaultProfile, pendingStore: store, launchInput: launchInput)
    self.wake = wake
  }

  var currentGeneration: UInt64 {
    fence.lock()
    defer { fence.unlock() }
    return generation
  }

  func remap(profiles: JSMap<String>, defaultProfile: String) {
    fence.lock()
    defer { fence.unlock() }
    generation += 1
    coordinator.remap(profiles: profiles, defaultProfile: defaultProfile)
  }

  func snapshot(profile: String) -> BookmarkWriterSnapshot {
    fence.lock()
    defer { fence.unlock() }
    let engine = coordinator.engine(profile: profile)
    let view = coordinator.desiredView(engine: engine)
    return BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: engine, generation: generation), revision: view.revision, ready: view.readyForSync, document: view.document)
  }

  @discardableResult
  func replace(profile: String, document: JSONValue, expectedRevision: UInt64, binding: BookmarkWriterBinding, requestID: String? = nil) throws -> UInt64 {
    let revision: UInt64
    do {
      fence.lock()
      defer { fence.unlock() }
      guard binding.generation == generation, JSKey(coordinator.engine(profile: profile)) == JSKey(binding.engine) else { throw BookmarkWriterError.staleBinding }
      do {
        revision = try coordinator.replaceDocument(engine: binding.engine, document: document, expectedRevision: expectedRevision, requestID: requestID).view.revision
      } catch {
        throw BookmarkWriterError.refused(String(describing: error))
      }
    }
    wake(binding.engine)
    return revision
  }
}

enum NativeBookmarkWriter {
  static func state() -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { return ["state": "legacy"] }
    return ["state": "owned", "generation": String(owner.currentGeneration)]
  }

  static func snapshot(profile: String) throws -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { throw BookmarkWriterError.notOwned }
    let snapshot = owner.snapshot(profile: profile)
    return [
      "engine": snapshot.binding.engine, "generation": String(snapshot.binding.generation),
      "revision": String(snapshot.revision), "ready": snapshot.ready, "document": snapshot.document.text(),
    ]
  }

  static func replace(profile: String, documentJSON: String, expectedRevision: String, engine: String, generation: String, requestID: String?) throws -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { throw BookmarkWriterError.notOwned }
    guard let expected = UInt64(expectedRevision), let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("revision and generation must be decimal strings") }
    let document: JSONValue
    do { document = try JSONValue.parse(documentJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    let revision = try owner.replace(profile: profile, document: document, expectedRevision: expected, binding: BookmarkWriterBinding(engine: engine, generation: generation), requestID: requestID)
    return ["revision": String(revision)]
  }
}
