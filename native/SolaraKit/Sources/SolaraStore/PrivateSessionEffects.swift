import Foundation
import SolaraModel
import Synchronization

public struct PrivateSessionEnd: Sendable, Equatable {
  public let session: String
  public let generation: String
  public let profiles: [String]
}

@MainActor
public final class PrivateSessionEffects {
  private struct Window {
    let id: String
    let profile: String
    let session: String
  }

  private struct Lifetime {
    let generation = UUID().uuidString
    var profiles: [String] = []
    var pending: [JSKey: Window] = [:]
  }

  private struct PendingEnd {
    let scope: JSKey
    let generation: String
  }

  private let store: Store
  private let begin: @MainActor (String, String) -> Void
  private let end: @MainActor (PrivateSessionEnd) -> Void
  nonisolated private let stopped = Mutex(false)
  private var listener: Int?
  private var windows: [JSKey: Window] = [:]
  private var lifetimes: [JSKey: Lifetime] = [:]
  private var pendingEnds: [PendingEnd] = []
  private var confirmed: [JSKey: Int] = [:]
  private var processedRev = -1

  public init(
    store: Store, begin: @escaping @MainActor (String, String) -> Void = { _, _ in },
    end: @escaping @MainActor (PrivateSessionEnd) -> Void
  ) {
    self.store = store
    self.begin = begin
    self.end = end
  }

  public func start() {
    guard listener == nil, !isStopped, store.config.nativePrivateSessionEffects else { return }
    store.sequence {
      reconcile(store.state, rev: store.rev)
      processedRev = store.rev
      listener = store.subscribe { [weak self] commit in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(commit) } }
      }
    }
  }

  public nonisolated var isStopped: Bool { stopped.withLock { $0 } }

  public nonisolated func stop() {
    stopped.withLock { $0 = true }
    DispatchQueue.main.async { MainActor.assumeIsolated { self.removeListener() } }
  }

  private func removeListener() {
    if let listener { store.unsubscribe(listener) }
    listener = nil
    windows = [:]
    lifetimes = [:]
    pendingEnds = []
    confirmed = [:]
  }

  public func confirmWindowClosed(_ id: String) {
    DispatchQueue.main.async { MainActor.assumeIsolated {
      guard !self.isStopped else { return }
      let key = JSKey(id)
      let revision = self.store.rev
      guard self.windows[key] != nil || self.lifetimes.values.contains(where: { $0.pending[key] != nil }) || self.processedRev < revision else { return }
      self.confirmed[key] = revision
      for session in Array(self.lifetimes.keys) { self.lifetimes[session]?.pending.removeValue(forKey: key) }
      self.finishReady()
    } }
  }

  private func consume(_ commit: Commit) {
    guard !isStopped, commit.rev >= processedRev else { return }
    reconcile(commit.state, rev: commit.rev)
    processedRev = commit.rev
    for case .endPrivateSession(let session) in commit.effects {
      let scope = JSKey(session)
      guard let lifetime = lifetimes[scope],
        !pendingEnds.contains(where: { $0.scope == scope && $0.generation == lifetime.generation }) else { continue }
      pendingEnds.append(PendingEnd(scope: scope, generation: lifetime.generation))
    }
    finishReady()
  }

  private func reconcile(_ state: BrowserState, rev: Int) {
    var next: [JSKey: Window] = [:]
    for window in state.windows.values where window.incognito {
      guard let session = state.privateSession(window.profileId) else { continue }
      let key = JSKey(window.id)
      let prior = windows[key]
      let item = Window(id: window.id, profile: window.profileId, session: prior?.session ?? session)
      next[key] = item
      let scope = JSKey(item.session)
      if lifetimes[scope] == nil {
        lifetimes[scope] = Lifetime()
        let generation = lifetimes[scope]!.generation
        store.setPrivateSessionGeneration(session: item.session, generation: generation)
        begin(item.session, generation)
      }
      if !lifetimes[scope]!.profiles.contains(where: { $0.jsEquals(item.profile) }) { lifetimes[scope]!.profiles.append(item.profile) }
      lifetimes[scope]?.pending.removeValue(forKey: key)
    }
    for (key, item) in windows where next[key] == nil {
      let restored = next.values.contains { $0.profile.jsEquals(item.profile) }
      if confirmed[key] == nil, !restored { lifetimes[JSKey(item.session)]?.pending[key] = item }
    }
    for (scope, lifetime) in lifetimes {
      let liveProfiles = Set(next.values.filter { JSKey($0.session) == scope }.map { JSKey($0.profile) })
      lifetimes[scope]?.pending = lifetime.pending.filter { !liveProfiles.contains(JSKey($0.value.profile)) }
    }
    confirmed = confirmed.filter { next[$0.key] != nil || rev < $0.value }
    windows = next
    let liveScopes = Set(next.values.map { JSKey($0.session) })
    pendingEnds.removeAll { liveScopes.contains($0.scope) }
  }

  private func finishReady() {
    while let pending = pendingEnds.first {
      guard !isStopped, processedRev >= store.rev else { return }
      guard let lifetime = lifetimes[pending.scope], lifetime.generation == pending.generation,
        !windows.values.contains(where: { JSKey($0.session) == pending.scope }) else {
        pendingEnds.removeFirst()
        continue
      }
      guard lifetime.pending.isEmpty else { return }
      let finished = store.sequence {
        guard !isStopped, processedRev >= store.rev,
          store.confirmPrivateSessionEnded(session: pending.scope.text, profiles: lifetime.profiles, generation: lifetime.generation) else { return false }
        pendingEnds.removeFirst()
        lifetimes[pending.scope] = nil
        end(PrivateSessionEnd(session: pending.scope.text, generation: lifetime.generation,
          profiles: lifetime.profiles))
        return true
      }
      guard finished else { return }
    }
  }
}
