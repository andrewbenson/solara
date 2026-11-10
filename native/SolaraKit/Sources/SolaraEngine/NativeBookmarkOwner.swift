import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public struct BookmarkWriterBinding: Equatable, Sendable {
  public let engine: String
  public let generation: UInt64
  public init(engine: String, generation: UInt64) { self.engine = engine; self.generation = generation }
}

public enum BookmarkWriterError: Error, Equatable, CustomStringConvertible {
  case notOwned
  case staleBinding
  case unknownProfile
  case invalidDocument(String)
  case refused(String)
  case conditionFailed(String)

  public var code: String {
    switch self {
    case .notOwned: "notOwned"
    case .staleBinding: "staleBinding"
    case .unknownProfile: "unknownProfile"
    case .invalidDocument: "invalidDocument"
    case .refused: "refused"
    case .conditionFailed: "conditionFailed"
    }
  }

  public var description: String {
    switch self {
    case .notOwned: "native bookmarks are not owned by this launch"
    case .staleBinding: "the bookmark owner changed since this binding was taken"
    case .unknownProfile: "the bookmark profile is unknown"
    case .invalidDocument(let reason): "invalid bookmark document: \(reason)"
    case .refused(let reason), .conditionFailed(let reason): "bookmark replacement refused: \(reason)"
    }
  }
}

public struct BookmarkWriterSnapshot: Sendable {
  public let binding: BookmarkWriterBinding
  public let revision: UInt64
  public let ready: Bool
  public let document: JSONValue
  public let facts: JSMap<BookmarkEditFact>
}

public final class NativeBookmarkOwner: @unchecked Sendable {
  private struct Selection {
    var owner: NativeBookmarkOwner?
    var previousCoordinator: BookmarkCoordinator?
    var selected = false
  }

  private static let slot = Mutex(Selection())
  public static var current: NativeBookmarkOwner? {
    get { slot.withLock { $0.owner } }
    set {
      slot.withLock { selection in
        if selection.owner !== newValue {
          let previous = selection.owner
          previous?.revokeAdmissions()
          if let coordinator = previous?.coordinator ?? selection.previousCoordinator {
            coordinator.settleJournalForOwnerReplacement()
          }
          newValue?.acquirePreparedJournal()
          if let previous { selection.previousCoordinator = previous.coordinator }
        }
        if newValue != nil { selection.selected = true }
        selection.owner = newValue
      }
    }
  }

  public static func retireBookmarksForCleanup(engine: String) throws {
    let selection = slot.withLock { ($0.owner, $0.selected) }
    if let owner = selection.0 { try owner.retireBookmarks(engine: engine) }
    else if selection.1 { throw BookmarkCoordinatorError.ownershipUnavailable }
  }

  @MainActor public static func settleBookmarkEngine(engine: String) async throws {
    try await settle(queue: BookmarkEngineQueue.shared, engine: engine)
  }

  private static let bindingSequence = Mutex<UInt64>(0)

  private static func nextBinding() -> UInt64 {
    bindingSequence.withLock { value in value += 1; return value }
  }

  private struct Route {
    let owner: UInt64
    let generation: UInt64
  }

  public let coordinator: BookmarkCoordinator
  private let fence = NSLock()
  private var lifecycleGeneration: UInt64 = 1
  private var installedGeneration: UInt64? = 1
  private var mapping: BookmarkProfileMap
  private var ownerIncarnation = NativeBookmarkOwner.nextBinding()
  private var routes: JSMap<Route> = [:]
  private var retiredEngines = Set<JSKey>()
  private var pendingRetirements = Set<JSKey>()
  private var pendingReactivations = Set<JSKey>()
  private var accepting = true
  private var prepared = false
  private var storeToken: UUID?
  private var observedRevision = -1
  @MainActor private var runtime: NativeBookmarkRuntime?
  @MainActor private var startingRuntime: NativeBookmarkRuntime?
  #if DEBUG
    private var wake: @Sendable (String) -> Void = { _ in }
    @MainActor var beforeInstallForTesting: (() async throws -> Void)?
    @MainActor var beforeClaimForTesting: (() async throws -> Void)?
    @MainActor var claimForTesting: (() throws -> Void)?
    var beforeMappingAdmissionForTesting: (@Sendable () -> Void)?
  #endif

  private init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], launchInput: BookmarkLaunchInput = .init()) {
    mapping = BookmarkProfileMap(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles)
    coordinator = BookmarkCoordinator(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles, pendingStore: store, launchInput: launchInput)
    updateRoutes(mapping)
  }

  #if DEBUG
    public convenience init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, launchInput: BookmarkLaunchInput = .init(), wake: @escaping @Sendable (String) -> Void) {
      self.init(store: store, profiles: profiles, defaultProfile: defaultProfile, launchInput: launchInput)
      self.wake = wake
    }
  #endif

  public var currentGeneration: UInt64 {
    fence.lock()
    defer { fence.unlock() }
    return lifecycleGeneration
  }

  #if DEBUG
    public func remap(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:]) {
      fence.lock()
      let next = BookmarkProfileMap(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles)
      stageMapping(next, pendingDeletion: [])
      lifecycleGeneration += 1
      let ticket = lifecycleGeneration
      fence.unlock()
      _ = installMapping(ticket)
    }
  #endif

  public func snapshot(profile: String) throws -> BookmarkWriterSnapshot {
    for _ in 0..<8 {
      fence.lock()
      let engine: String
      let binding: BookmarkWriterBinding
      do {
        engine = try mappedEngine(profile)
        let regular = regularProfile(profile)
        guard let route = routes[regular] else { throw BookmarkWriterError.unknownProfile }
        binding = BookmarkWriterBinding(engine: engine, generation: route.generation)
      } catch {
        fence.unlock()
        throw error
      }
      let generation = lifecycleGeneration
      fence.unlock()
      let snapshot = coordinator.writerSnapshot(engine: engine)
      fence.lock()
      let unchanged = generation == lifecycleGeneration && routes[regularProfile(profile)]?.generation == binding.generation
      let ready = snapshot.ready && installedGeneration == lifecycleGeneration && accepting && !prepared && !retiredEngines.contains(JSKey(engine))
      fence.unlock()
      if unchanged { return BookmarkWriterSnapshot(binding: binding, revision: snapshot.revision, ready: ready, document: snapshot.document, facts: snapshot.facts) }
    }
    throw BookmarkWriterError.staleBinding
  }

  @discardableResult
  public func ackBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64, mintedHLC: String)], expectedLink: String? = nil, generation: UInt64) throws -> Bool {
    try coordinator.ackBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profileId, binding: BookmarkWriterBinding(engine: expectedEngine, generation: generation)) })
  }

  @discardableResult
  public func observeRemoteRecords(profileId: String, expectedEngine: String, records: [(key: String, hlc: String)], expectedLink: String? = nil, generation: UInt64) throws -> Bool {
    try coordinator.observeRemoteRecords(profileId: profileId, expectedEngine: expectedEngine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profileId, binding: BookmarkWriterBinding(engine: expectedEngine, generation: generation)) })
  }

  @discardableResult
  public func clearBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64)], generation: UInt64) throws -> Bool {
    try coordinator.clearBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records, admission: { try self.validate(profile: profileId, binding: BookmarkWriterBinding(engine: expectedEngine, generation: generation)) })
  }

  @discardableResult
  public func setBookmarkSyncLinks(_ links: JSMap<String>) -> Bool {
    fence.lock()
    let incarnation = ownerIncarnation
    fence.unlock()
    return coordinator.setBookmarkSyncLinks(links, admission: {
      self.fence.lock()
      defer { self.fence.unlock() }
      guard self.accepting, !self.prepared, self.ownerIncarnation == incarnation else { throw BookmarkWriterError.staleBinding }
    })
  }

  private func regularProfile(_ profile: String) -> String {
    Ids.isIncognitoProfile(profile) ? Ids.incognitoOriginal(profile) : profile
  }

  private func mappedEngine(_ profile: String) throws -> String {
    guard let engine = mapping.profiles[regularProfile(profile)] else { throw BookmarkWriterError.unknownProfile }
    return engine
  }

  private func updateRoutes(_ next: BookmarkProfileMap) {
    var updated: JSMap<Route> = [:]
    for (profile, engine) in next.profiles {
      if let route = routes[profile], route.owner == ownerIncarnation, mapping.profiles[profile].map({ JSKey($0) == JSKey(engine) }) == true {
        updated[profile] = route
      } else {
        updated[profile] = Route(owner: ownerIncarnation, generation: Self.nextBinding())
      }
    }
    routes = updated
  }

  private func stageMapping(_ next: BookmarkProfileMap, pendingDeletion: Set<JSKey>) {
    let previousEngines = Set(mapping.profiles.values.map(JSKey.init))
    let nextEngines = Set(next.profiles.values.map(JSKey.init))
    pendingRetirements.formUnion(pendingDeletion.subtracting(nextEngines))
    retiredEngines.formUnion(pendingRetirements)
    pendingReactivations.formUnion(nextEngines.subtracting(previousEngines).subtracting(pendingDeletion))
    updateRoutes(next)
    mapping = next
  }

  private func validate(profile: String, binding: BookmarkWriterBinding) throws {
    fence.lock()
    defer { fence.unlock() }
    let engine = try mappedEngine(profile)
    guard accepting, !prepared, !retiredEngines.contains(JSKey(engine)), JSKey(engine) == JSKey(binding.engine),
      let route = routes[regularProfile(profile)], route.owner == ownerIncarnation, route.generation == binding.generation else { throw BookmarkWriterError.staleBinding }
  }

  private func revokeAdmissions() {
    fence.lock()
    accepting = false
    lifecycleGeneration += 1
    installedGeneration = nil
    ownerIncarnation = Self.nextBinding()
    updateRoutes(mapping)
    fence.unlock()
    coordinator.fencePumpAdmissions()
    Task { @MainActor [weak self] in self?.finishRevocation() }
  }

  @MainActor private func finishRevocation() {
    (runtime ?? startingRuntime)?.stop()
    runtime = nil
    startingRuntime = nil
    bind(token: nil)
  }

  public func retireBookmarks(engine: String) throws {
    fence.lock()
    guard accepting, !prepared else { fence.unlock(); throw BookmarkWriterError.staleBinding }
    retiredEngines.insert(JSKey(engine))
    pendingRetirements.insert(JSKey(engine))
    pendingReactivations.remove(JSKey(engine))
    lifecycleGeneration += 1
    let ticket = lifecycleGeneration
    for profile in mapping.profiles.keys where mapping.profiles[profile].map({ JSKey($0) == JSKey(engine) }) == true {
      routes[profile] = Route(owner: ownerIncarnation, generation: Self.nextBinding())
    }
    fence.unlock()
    coordinator.fencePumpAdmissions()
    try coordinator.retire(engine: engine, admission: {
      guard self.isCurrent(ticket) else { throw BookmarkWriterError.staleBinding }
    })
    fence.lock()
    pendingRetirements.remove(JSKey(engine))
    fence.unlock()
    Task { @MainActor [weak self] in
      guard let self else { return }
      (self.runtime ?? self.startingRuntime)?.schedule(ticket)
    }
  }

  @MainActor public func settleRetiredBookmarks(engine: String) async throws {
    try await Self.settle(queue: coordinator.engineQueue, engine: engine)
  }

  @MainActor private static func settle(queue: BookmarkEngineQueue, engine: String) async throws {
    let settled = await withCheckedContinuation { continuation in
      var finished = false
      var timeout: Task<Void, Never>?
      Task { @MainActor in
        _ = try? await queue.perform(engine: engine) { true }
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        continuation.resume(returning: true)
      }
      timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: false)
      }
    }
    guard settled else { throw BookmarkCoordinatorError.ownershipUnavailable }
  }

  @discardableResult
  public func replace(profile: String, document: JSONValue, expectedRevision: UInt64, binding: BookmarkWriterBinding, requestID: String? = nil, records: [(key: String, hlc: String)] = [], expectedLink: String? = nil) throws -> UInt64 {
    try validate(profile: profile, binding: binding)
    let revision: UInt64
    do {
      revision = try coordinator.replaceDocument(engine: binding.engine, profile: profile, document: document, expectedRevision: expectedRevision, requestID: requestID, expectedEngine: binding.engine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profile, binding: binding) }).view.revision
    } catch let error as BookmarkWriterError {
      throw error
    } catch let error as BookmarkCoordinatorError {
      if case .conditionFailed = error { throw BookmarkWriterError.conditionFailed(String(describing: error)) }
      throw BookmarkWriterError.refused(String(describing: error))
    } catch {
      throw BookmarkWriterError.refused(String(describing: error))
    }
    dispatchWake(binding)
    return revision
  }

  public func submit(profile: String, mutations: [BookmarkMutation], binding: BookmarkWriterBinding, requestID: String? = nil) throws -> BookmarkReceipt {
    try validate(profile: profile, binding: binding)
    let receipt: BookmarkReceipt
    do {
      receipt = try coordinator.submit(profile: profile, mutations: mutations, requestID: requestID, expectedEngine: binding.engine, admission: { try self.validate(profile: profile, binding: binding) })
    } catch let error as BookmarkWriterError {
      throw error
    } catch let error as BookmarkCoordinatorError {
      if case .conditionFailed = error { throw BookmarkWriterError.conditionFailed(String(describing: error)) }
      throw BookmarkWriterError.refused(String(describing: error))
    } catch {
      throw BookmarkWriterError.refused(String(describing: error))
    }
    dispatchWake(binding)
    return receipt
  }

  public static func prepare(directory: URL, state: BrowserState, cacheDirectory: URL? = nil) async -> NativeBookmarkOwner {
    await prepare(directory: directory, state: state, cacheDirectory: cacheDirectory, afterLoad: {})
  }

  #if DEBUG
    static func prepareForTesting(directory: URL, state: BrowserState, afterLoad: @escaping @Sendable () async -> Void) async -> NativeBookmarkOwner {
      await prepare(directory: directory, state: state, cacheDirectory: nil, afterLoad: afterLoad)
    }
  #endif

  private static func prepare(directory: URL, state: BrowserState, cacheDirectory: URL?, afterLoad: @escaping @Sendable () async -> Void) async -> NativeBookmarkOwner {
    await Task.detached {
      let store = BookmarkPendingStore(directory: directory, defersRecovery: true)
      let map = BookmarkProfileMap(state: state, previousOwners: BookmarkDurability(store: store).owners)
      let launch = cacheDirectory.map { BookmarkLaunchCache(directory: $0).load(profiles: map.profiles, defaultProfile: map.defaultProfile) } ?? BookmarkLaunchInput()
      let owner = NativeBookmarkOwner(store: store, profiles: map.profiles, defaultProfile: map.defaultProfile, owningProfiles: map.owningProfiles, launchInput: launch)
      owner.prepared = true
      owner.accepting = false
      owner.installedGeneration = nil
      owner.stageMapping(map, pendingDeletion: Set(state.orphanedProfileData.map(JSKey.init)))
      await afterLoad()
      return owner
    }.value
  }

  private func acquirePreparedJournal() {
    fence.lock()
    let wasPrepared = prepared
    fence.unlock()
    coordinator.reloadJournalForOwnerReplacement()
    guard wasPrepared else { return }
    let restorable = coordinator.restorableTerminalEngines()
    let retired = coordinator.deliberatelyRetiredEngines()
    fence.lock()
    retiredEngines.formUnion(retired)
    pendingReactivations.formUnion(Set(mapping.profiles.values.map(JSKey.init)).intersection(restorable))
    accepting = true
    let ticket = lifecycleGeneration
    let needsInstallation = !pendingRetirements.isEmpty || !pendingReactivations.isEmpty
    fence.unlock()
    let installed = !needsInstallation || installMapping(ticket)
    fence.lock()
    prepared = false
    if installed { installedGeneration = ticket }
    fence.unlock()
  }

  private func dispatchWake(_ binding: BookmarkWriterBinding) {
    #if DEBUG
      fence.lock()
      let wake = self.wake
      fence.unlock()
      wake(binding.engine)
    #endif
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.runtime?.pump?.requestPush(engine: binding.engine)
    }
  }

  fileprivate func isCurrent(_ ticket: UInt64) -> Bool {
    fence.lock()
    defer { fence.unlock() }
    return accepting && lifecycleGeneration == ticket
  }

  fileprivate func stage(state: BrowserState? = nil, token: UUID? = nil, revision: Int? = nil, force: Bool = true) -> UInt64? {
    fence.lock()
    defer { fence.unlock() }
    guard accepting else { return nil }
    if let revision {
      guard storeToken == token, revision > observedRevision else { return nil }
      observedRevision = revision
    }
    let next = state.map { BookmarkProfileMap(state: $0, previousOwners: mapping.owningProfiles) } ?? mapping
    let pendingDeletion = Set(state?.orphanedProfileData.map(JSKey.init) ?? [])
    let unreferencedDeletion = pendingDeletion.subtracting(Set(next.profiles.values.map(JSKey.init)))
    guard force || next != mapping || !unreferencedDeletion.isSubset(of: retiredEngines) else { return nil }
    stageMapping(next, pendingDeletion: pendingDeletion)
    lifecycleGeneration += 1
    return lifecycleGeneration
  }

  fileprivate func bind(token: UUID?) {
    fence.lock()
    defer { fence.unlock() }
    if storeToken != token {
      ownerIncarnation = Self.nextBinding()
      updateRoutes(mapping)
    }
    storeToken = token
    observedRevision = -1
  }

  fileprivate func installMapping(_ ticket: UInt64) -> Bool {
    let deliberatelyRetired = coordinator.deliberatelyRetiredEngines()
    fence.lock()
    guard accepting, lifecycleGeneration == ticket else { fence.unlock(); return false }
    let mapping = self.mapping
    let retirements = pendingRetirements
    let reactivations = pendingReactivations.intersection(Set(mapping.profiles.values.map(JSKey.init))).subtracting(retirements)
    retiredEngines.formUnion(deliberatelyRetired)
    let permittedReactivations = reactivations.subtracting(deliberatelyRetired)
    fence.unlock()
    #if DEBUG
      beforeMappingAdmissionForTesting?()
    #endif
    let admission = {
      guard self.isCurrent(ticket) else { throw BookmarkCoordinatorError.staleRevision }
    }
    do {
      for engine in retirements { try coordinator.retire(engine: engine.text, admission: admission) }
      for engine in permittedReactivations { try coordinator.reactivate(engine: engine.text, admission: admission) }
    } catch { return false }
    guard coordinator.remap(profiles: mapping.profiles, defaultProfile: mapping.defaultProfile, owningProfiles: mapping.owningProfiles, admission: admission) else { return false }
    fence.lock()
    defer { fence.unlock() }
    guard accepting, lifecycleGeneration == ticket else { return false }
    pendingRetirements.subtract(retirements)
    pendingReactivations.subtract(reactivations)
    retiredEngines.subtract(permittedReactivations)
    installedGeneration = ticket
    return true
  }

  @discardableResult
  fileprivate func activate(_ ticket: UInt64, _ body: () throws -> Void) rethrows -> Bool {
    fence.lock()
    defer { fence.unlock() }
    guard accepting, lifecycleGeneration == ticket else { return false }
    try body()
    return true
  }

  @MainActor fileprivate func didActivate(_ runtime: NativeBookmarkRuntime) {
    guard startingRuntime === runtime else { return }
    self.runtime = runtime
    startingRuntime = nil
  }

  @MainActor public func start(catalog: LibraryCatalog, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler) async throws {
    if prepared { Self.current = self }
    guard isCurrent(currentGeneration), runtime == nil, startingRuntime == nil else { throw BookmarkCoordinatorError.ownershipUnavailable }
    let runtime = NativeBookmarkRuntime(owner: self, catalog: catalog, client: client, clock: clock, scheduler: scheduler)
    startingRuntime = runtime
    if let ticket = stage() { await runtime.replacePump(ticket) }
  }

  @MainActor public func remap(state: BrowserState) async throws {
    guard let runtime = runtime ?? startingRuntime else { throw BookmarkCoordinatorError.ownershipUnavailable }
    if let ticket = stage(state: state) { await runtime.replacePump(ticket) }
  }

  @MainActor public func subscribeToStoreCommits() {
    (runtime ?? startingRuntime)?.subscribeToStoreCommits()
  }

  @MainActor public func stop() {
    revokeAdmissions()
    finishRevocation()
  }

  #if DEBUG
    @MainActor func bindStore(_ store: Store?) { (runtime ?? startingRuntime)?.bindStore(store) }
    @MainActor func settleLifecycleForTesting() async { await (runtime ?? startingRuntime)?.pending?.value }
    @MainActor var runtimeIsActiveForTesting: Bool { runtime != nil }
    func stageForTesting(state: BrowserState) -> UInt64? { stage(state: state) }
    func installMappingForTesting(_ ticket: UInt64) async -> Bool {
      await coordinator.offMain { self.installMapping(ticket) }
    }
  #endif
}

public struct BookmarkProfileMap: Equatable, Sendable {
  public let profiles: JSMap<String>
  public let defaultProfile: String
  public let owningProfiles: JSMap<String>

  init(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String>) {
    self.profiles = profiles
    self.defaultProfile = defaultProfile
    self.owningProfiles = owningProfiles
  }

  public init(state: BrowserState, previousOwners: JSMap<String> = [:]) {
    let regular = state.profiles.keys.filter { !Ids.isIncognitoProfile($0) }.sorted(by: jsKeyPrecedes)
    let mapped = JSMap(regular.map { ($0, state.engineProfile($0)) })
    profiles = mapped
    let preferred = state.settings.defaultProfileId
    defaultProfile = mapped[preferred] != nil ? preferred : mapped[Settings.defaultProfileID] != nil ? Settings.defaultProfileID : regular.first ?? Settings.defaultProfileID
    var owners: JSMap<String> = [:]
    for profile in regular {
      let engine = mapped[profile]!
      guard owners[engine] == nil else { continue }
      let aliases = regular.filter { JSKey(mapped[$0]!) == JSKey(engine) }
      let conventional = engine.isEmpty ? Settings.defaultProfileID : engine
      if let previous = previousOwners[engine], aliases.contains(where: { JSKey($0) == JSKey(previous) }) { owners[engine] = previous }
      else { owners[engine] = aliases.first(where: { JSKey($0) == JSKey(conventional) }) ?? aliases.first }
    }
    owningProfiles = owners
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.profiles.mapValues(JSKey.init) == rhs.profiles.mapValues(JSKey.init) && JSKey(lhs.defaultProfile) == JSKey(rhs.defaultProfile) && lhs.owningProfiles.mapValues(JSKey.init) == rhs.owningProfiles.mapValues(JSKey.init)
  }
}

@MainActor fileprivate final class NativeBookmarkRuntime {
  weak var owner: NativeBookmarkOwner?
  let catalog: LibraryCatalog
  let client: BookmarkEngineClient
  let clock: BookmarkPumpClock
  let scheduler: BookmarkPumpScheduler
  var pump: BookmarkPump?
  var pending: Task<Void, Never>?
  private var lifecycle: Int?
  private var store: Store?
  private var hasBoundStore = false
  private var subscription: Int?
  private var retryTicket: UInt64?
  private var retryFailures = 0
  private var cancelRetry: (@MainActor () -> Void)?

  init(owner: NativeBookmarkOwner, catalog: LibraryCatalog, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler) {
    self.owner = owner
    self.catalog = catalog
    self.client = client
    self.clock = clock
    self.scheduler = scheduler
  }

  isolated deinit {
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    if let subscription { store?.unsubscribe(subscription) }
    cancelRetry?()
    stopPump()
  }

  private func stopPump() {
    guard let pump else { return }
    self.pump = nil
    pump.stop(invalidate: false)
    guard let coordinator = owner?.coordinator else { return }
    let epoch = pump.epoch
    Task { await coordinator.offMain { coordinator.invalidatePump(epoch: epoch) } }
  }

  func replacePump(_ ticket: UInt64) async {
    guard let owner, owner.isCurrent(ticket) else { return }
    cancelRetry?()
    cancelRetry = nil
    if retryTicket != ticket { retryTicket = ticket; retryFailures = 0 }
    stopPump()
    let coordinator = owner.coordinator
    #if DEBUG
      try? await owner.beforeInstallForTesting?()
    #endif
    do {
      guard await coordinator.offMain({ owner.installMapping(ticket) }) else {
        guard owner.isCurrent(ticket) else { return }
        throw BookmarkCoordinatorError.ownershipUnavailable
      }
      #if DEBUG
        try await owner.beforeClaimForTesting?()
      #endif
      guard owner.isCurrent(ticket) else { return }
      let epoch = await coordinator.offMain { coordinator.claimPump() }
      let next = BookmarkPump(coordinator: coordinator, client: client, clock: clock, scheduler: scheduler, epoch: epoch)
      do {
        let activated = try owner.activate(ticket) {
          #if DEBUG
            try owner.claimForTesting?()
          #endif
          try catalog.claimBookmarks(coordinator: coordinator, pump: next)
          pump = next
        }
        guard activated else { next.stop(invalidate: false); return }
      } catch {
        next.stop(invalidate: false)
        throw error
      }
      retryFailures = 0
      owner.didActivate(self)
      for engine in coordinator.catalogEngines { next.requestRead(engine: engine) }
    } catch {
      guard owner.isCurrent(ticket) else { return }
      retryFailures = min(retryFailures + 1, 7)
      let delay = min(60_000, 1000 * pow(2, Double(retryFailures - 1)))
      cancelRetry = scheduler.schedule(delay) { [weak self] in self?.schedule(ticket) }
    }
  }

  func subscribeToStoreCommits() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.bindStore(NativeStoreHandle.store) }
  }

  func bindStore(_ next: Store?) {
    guard !hasBoundStore || store !== next, let owner else { return }
    let reconnecting = hasBoundStore && store == nil && next != nil
    hasBoundStore = true
    if let subscription { store?.unsubscribe(subscription) }
    subscription = nil
    store = next
    let token = next.map { _ in UUID() }
    owner.bind(token: token)
    guard let next else {
      stopPump()
      _ = owner.stage()
      return
    }
    let ticket = next.sequence {
      let snapshot = next.snapshot
      let ticket = owner.stage(state: snapshot.state, token: token, revision: snapshot.rev, force: reconnecting)
      subscription = next.subscribe { [weak self, weak owner] commit in
        guard let owner, let ticket = owner.stage(state: commit.state, token: token, revision: commit.rev, force: false) else { return }
        let deliver: @MainActor @Sendable () -> Void = { [weak self] in self?.schedule(ticket) }
        if Thread.isMainThread { MainActor.assumeIsolated { deliver() } }
        else { DispatchQueue.main.async(execute: deliver) }
      }
      return ticket
    }
    if let ticket { schedule(ticket) }
  }

  fileprivate func schedule(_ ticket: UInt64) {
    guard owner?.isCurrent(ticket) == true else { return }
    pending = Task { [weak self] in
      guard let self else { return }
      await self.replacePump(ticket)
    }
  }

  func stop() {
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let subscription { store?.unsubscribe(subscription) }
    subscription = nil
    store = nil
    pending?.cancel()
    pending = nil
    cancelRetry?()
    cancelRetry = nil
    stopPump()
  }
}
