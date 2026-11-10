import Foundation
import SolaraModel
import Synchronization

func profileDataPending(_ state: BrowserState, _ engine: String, launch: String) -> Bool {
  state.orphanedProfileData.contains { $0.jsEquals(engine) } || ProfileDataCleanup.inFlight(engine, launch: launch)
}

@MainActor
public final class ProfileDataCleanup {
  public typealias Completion = @Sendable ([String]) -> Void

  private struct Item {
    let engine: String
    let generation: Int
  }

  private nonisolated static let reservations = Mutex<[UUID: (launch: String, engine: String)]>([:])

  nonisolated static func inFlight(_ engine: String, launch: String) -> Bool {
    reservations.withLock { $0.values.contains { $0.launch == launch && $0.engine.jsEquals(engine) } }
  }

  nonisolated static func validEngine(_ engine: String) -> Bool {
    !engine.contains("/") && !engine.contains("\\") && !engine.contains("\0") && engine != "." && engine != ".."
      && !Ids.isIncognitoProfile(engine)
  }

  public nonisolated static func validProfileId(_ id: String) -> Bool {
    if id == Settings.defaultProfileID { return true }
    let parts = id.split(separator: "-", omittingEmptySubsequences: false)
    func base36(_ text: Substring) -> Bool {
      !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }
    if parts.count == 3, parts[0] == "p", base36(parts[1]), base36(parts[2]), parts[2].first != "0" { return true }
    guard parts.count == 7, parts[0] == "p", parts[6] == "1" else { return false }
    return zip(parts[1...5], [8, 4, 4, 4, 12]).allSatisfy { part, length in
      part.utf8.count == length && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
  }

  private let store: Store
  private let delete: @MainActor (String, @escaping Completion) -> Void
  private let retireBookmarks: @MainActor (String) throws -> Void
  private let settleBookmarks: @MainActor (String) async throws -> Void
  private let grace: @MainActor () async throws -> Void
  private let trouble: @MainActor (String, [String]) -> Void
  private nonisolated let stopped = Atomic(false)
  private var subscription: Int?
  private(set) var task: Task<Void, Never>?
  private var failed: Set<Int> = []
  private var identityRefusals: [Int: Set<JSKey>] = [:]
  private var generations: [JSKey: Int] = [:]
  private var generation = 0
  private var observedRev: Int?
  private var ownedWorkspace = false

  public init(
    store: Store,
    delete: @escaping @MainActor (String, @escaping Completion) -> Void,
    retireBookmarks: @escaping @MainActor (String) throws -> Void = { _ in },
    settleBookmarks: @escaping @MainActor (String) async throws -> Void = { _ in },
    grace: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(1500)) },
    trouble: @escaping @MainActor (String, [String]) -> Void = { _, _ in }
  ) {
    self.store = store
    self.delete = delete
    self.retireBookmarks = retireBookmarks
    self.settleBookmarks = settleBookmarks
    self.grace = grace
    self.trouble = trouble
  }

  isolated deinit {
    if let subscription { store.unsubscribe(subscription) }
    task?.cancel()
  }

  public nonisolated var isStopped: Bool { stopped.load(ordering: .acquiring) }

  public func updateOwnership(_ ownsWorkspace: Bool, applicationReady: Bool, engineReady: Bool) {
    guard ownsWorkspace else {
      if ownedWorkspace || subscription != nil { stop() }
      return
    }
    ownedWorkspace = true
    guard applicationReady, engineReady else { return }
    start()
  }

  public func start() {
    guard subscription == nil, !isStopped, !store.config.safeMode else { return }
    subscription = store.subscribe { [weak self] commit in
      guard commit.changes.lists.contains("orphanedProfileData") || !commit.changes.profiles.isEmpty else { return }
      if Thread.isMainThread {
        MainActor.assumeIsolated { self?.wake() }
      } else {
        Task { @MainActor [weak self] in self?.wake() }
      }
    }
    wake()
  }

  public nonisolated func stop() {
    stopped.store(true, ordering: .releasing)
    Task { @MainActor [weak self] in self?.finishStop() }
  }

  private func finishStop() {
    if let subscription { store.unsubscribe(subscription) }
    subscription = nil
    task?.cancel()
  }

  public func retry() {
    failed.removeAll()
    wake()
  }

  private func wake() {
    guard !isStopped, task == nil else { return }
    task = Task { [weak self] in await self?.drain() }
  }

  private func observe(_ queue: [String]) {
    let present = Set(queue.map(JSKey.init))
    generations = generations.filter { present.contains($0.key) }
    for engine in queue where generations[JSKey(engine)] == nil {
      generation += 1
      generations[JSKey(engine)] = generation
    }
    failed.formIntersection(Set(generations.values))
    let live = Set(store.state.profiles.values.map { JSKey(engineIdOf($0)) })
    identityRefusals = identityRefusals.filter { generations.values.contains($0.key) && $0.value.isSubset(of: live) }
  }

  private func reconcile() {
    let snapshot = store.snapshot
    if let observedRev {
      if let patches = store.patches(since: observedRev) {
        for patch in patches {
          for (name, value) in patch.lists where name == "orphanedProfileData" {
            if case .strings(let queue) = value { observe(queue) }
          }
        }
      } else {
        generations.removeAll()
      }
    }
    observe(snapshot.state.orphanedProfileData)
    observedRev = snapshot.rev
  }

  private func isCurrent(_ item: Item) -> Bool {
    generations[JSKey(item.engine)] == item.generation
      && store.state.orphanedProfileData.contains { $0.jsEquals(item.engine) }
  }

  private func isReferenced(_ engine: String) -> Bool {
    store.state.profiles.values.contains { engineIdOf($0).jsEquals(engine) }
  }

  private func removeQueued(_ item: Item, acknowledged: Bool = false) throws {
    let commands = acknowledged ? [Command("profileDataDeleted", [.string(item.engine)])] : []
    try store.transact(commands: commands, durable: true) { session in
      session.update { $0.orphanedProfileData = $0.orphanedProfileData.filter { !$0.jsEquals(item.engine) } }
    }
  }

  private func drain() async {
    defer { task = nil }
    while !isStopped {
      let candidate = store.sequence {
        reconcile()
        return store.state.orphanedProfileData.first { engine in
          generations[JSKey(engine)].map { !failed.contains($0) && identityRefusals[$0] == nil } ?? false
        }.flatMap { engine in generations[JSKey(engine)].map { Item(engine: engine, generation: $0) } }
      }
      guard let item = candidate else { return }
      do {
        let discarded = try store.sequence {
          reconcile()
          guard !isStopped, isCurrent(item) else { return true }
          if !Self.validEngine(item.engine) {
            NSLog("[store] dropping invalid profile data id: %@", item.engine)
            try removeQueued(item)
            return true
          }
          if isReferenced(item.engine) {
            try removeQueued(item)
            return true
          }
          return false
        }
        if discarded { continue }
      } catch {
        failed.insert(item.generation)
        trouble(item.engine, [String(describing: error)])
        continue
      }
      do { try await grace() } catch { return }
      let launch = store.memory.ids.launch
      let reserved: Bool
      do {
        reserved = try store.sequence {
          reconcile()
          guard !isStopped, !Task.isCancelled, isCurrent(item) else { return false }
          guard Self.validEngine(item.engine), !isReferenced(item.engine) else {
            try removeQueued(item)
            return false
          }
          try ProfileDataTombstones.reserve(item.engine, at: store.config.profileDataTombstones, pending: store.state.orphanedProfileData, live: store.state.profiles.values.map(engineIdOf))
          let token = UUID()
          Self.reservations.withLock { $0[token] = (launch: launch, engine: item.engine) }
          try retireBookmarks(item.engine)
          return true
        }
      } catch {
        failed.insert(item.generation)
        trouble(item.engine, ["Profile retirement: \(error)"])
        continue
      }
      guard reserved else { continue }
      do {
        try await settleBookmarks(item.engine)
      } catch {
        failed.insert(item.generation)
        trouble(item.engine, ["Bookmark retirement drain: \(error)"])
        continue
      }
      let remaining: [String]? = await withCheckedContinuation { continuation in
        store.sequence {
          reconcile()
          guard !isStopped, !Task.isCancelled, isCurrent(item) else { continuation.resume(returning: nil); return }
          guard Self.validEngine(item.engine), !isReferenced(item.engine) else {
            do { try removeQueued(item) } catch { failed.insert(item.generation); trouble(item.engine, [String(describing: error)]) }
            continuation.resume(returning: nil)
            return
          }
          delete(item.engine) { continuation.resume(returning: $0) }
        }
      }
      guard let remaining else { continue }
      do {
        try store.sequence {
          if remaining.isEmpty {
            Self.reservations.withLock { active in
              active = active.filter { !($0.value.launch == launch && $0.value.engine.jsEquals(item.engine)) }
            }
          }
          reconcile()
          guard !isStopped, !Task.isCancelled, isCurrent(item), !isReferenced(item.engine) else { return }
          guard remaining.isEmpty else {
            if remaining.contains("live profile filesystem identity") {
              identityRefusals[item.generation] = Set(store.state.profiles.values.map { JSKey(engineIdOf($0)) })
            } else {
              failed.insert(item.generation)
            }
            trouble(item.engine, remaining)
            return
          }
          try removeQueued(item, acknowledged: true)
        }
      } catch {
        failed.insert(item.generation)
        trouble(item.engine, [String(describing: error)])
      }
    }
  }
}

extension Session {
  func requireGeneratedProfileIdentity(_ profile: Profile, key: String? = nil) throws {
    guard config.profileDataTombstones != nil else { return }
    guard ProfileDataCleanup.validProfileId(profile.id), ProfileDataCleanup.validProfileId(dataIdOf(profile)),
      key.map(ProfileDataCleanup.validProfileId) ?? true else {
      throw CommandError("Profile ids and data ids must use a generated lowercase profile id.")
    }
  }

  func requireGeneratedProfileIdentities(_ profiles: JSMap<Profile>?) throws {
    for (key, profile) in profiles ?? JSMap() { try requireGeneratedProfileIdentity(profile, key: key) }
  }

  func refusePendingProfileData(_ engine: String) throws {
    if profileDataPending(state, engine, launch: memory.ids.launch) {
      throw CommandError("Profile data \(engine.isEmpty ? "Default" : engine) is pending deletion. Retry after cleanup finishes.")
    }
    if state.profiles.values.contains(where: { engineIdOf($0).jsEquals(engine) }) { return }
    if try ProfileDataTombstones.contains(engine, at: config.profileDataTombstones, pending: state.orphanedProfileData, live: state.profiles.values.map(engineIdOf)) {
      throw CommandError("This profile data directory was deleted and cannot be reused. Choose a new profile.")
    }
  }

  func refusePendingProfileData(_ next: BrowserState, allowRecordedAliases: Bool = false) throws {
    let admitting = !allowRecordedAliases && next.profiles.keys.contains { state.profiles[$0] == nil }
    let aliases = admitting ? ProfileDataTombstones.aliases(at: config.profileDataTombstones, pending: state.orphanedProfileData, live: state.profiles.values.map(engineIdOf)) : []
    for (id, profile) in next.profiles {
      if state.profiles[id] == nil && aliases.contains(where: { $0.jsEquals(id) || $0.jsEquals(profile.id) }) {
        throw CommandError("This profile was deleted and cannot be reused. Choose a new profile.")
      }
      let engine = engineIdOf(profile)
      if let previous = state.profiles[id], engineIdOf(previous).jsEquals(engine) { continue }
      try refusePendingProfileData(engine)
      if profileDataPending(next, engine, launch: memory.ids.launch) {
        throw CommandError("Profile data \(engine.isEmpty ? "Default" : engine) is pending deletion. Retry after cleanup finishes.")
      }
    }
  }

  func refuseInFlightProfileData(_ data: HydrateData) throws {
    let profiles = data.profiles.flatMap { $0.isEmpty ? nil : $0 } ?? JSMap([(BrowserState.defaultProfile.id, BrowserState.defaultProfile)])
    for profile in profiles.values where ProfileDataCleanup.inFlight(engineIdOf(profile), launch: memory.ids.launch) {
      throw CommandError("Saved profile data is still being deleted. Retry restoring the session after cleanup finishes.")
    }
  }
}
