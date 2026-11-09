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
  private static let slot = Mutex<NativeBookmarkOwner?>(nil)
  public static var current: NativeBookmarkOwner? {
    get { slot.withLock { $0 } }
    set { slot.withLock { $0 = newValue } }
  }

  public let coordinator: BookmarkCoordinator
  private let fence = NSLock()
  private var lifecycleGeneration: UInt64 = 1
  private var installedGeneration: UInt64? = 1
  private var mapping: BookmarkProfileMap
  private var storeToken: UUID?
  private var observedRevision = -1
  @MainActor private var runtime: NativeBookmarkRuntime?
  @MainActor private var startingRuntime: NativeBookmarkRuntime?
  #if DEBUG
    private var wake: @Sendable (String) -> Void = { _ in }
    @MainActor var beforeInstallForTesting: (() async throws -> Void)?
    @MainActor var beforeClaimForTesting: (() async throws -> Void)?
    @MainActor var claimForTesting: (() throws -> Void)?
  #endif

  private init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], launchInput: BookmarkLaunchInput = .init()) {
    mapping = BookmarkProfileMap(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles)
    coordinator = BookmarkCoordinator(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles, pendingStore: store, launchInput: launchInput)
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
      mapping = BookmarkProfileMap(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles)
      lifecycleGeneration += 1
      let ticket = lifecycleGeneration
      fence.unlock()
      _ = installMapping(ticket)
    }
  #endif

  public func snapshot(profile: String) throws -> BookmarkWriterSnapshot {
    fence.lock()
    defer { fence.unlock() }
    let engine = try mappedEngine(profile)
    let snapshot = coordinator.writerSnapshot(engine: engine)
    return BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: engine, generation: lifecycleGeneration), revision: snapshot.revision, ready: snapshot.ready && installedGeneration == lifecycleGeneration, document: snapshot.document, facts: snapshot.facts)
  }

  @discardableResult
  public func ackBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64, mintedHLC: String)]) throws -> Bool {
    try coordinator.ackBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records)
  }

  @discardableResult
  public func observeRemoteRecords(profileId: String, expectedEngine: String, records: [(key: String, hlc: String)]) throws -> Bool {
    try coordinator.observeRemoteRecords(profileId: profileId, expectedEngine: expectedEngine, records: records)
  }

  @discardableResult
  public func clearBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64)]) throws -> Bool {
    try coordinator.clearBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records)
  }

  @discardableResult
  public func setBookmarkSyncLinks(_ links: JSMap<String>) -> Bool {
    coordinator.setBookmarkSyncLinks(links)
  }

  private func mappedEngine(_ profile: String) throws -> String {
    var regular = profile
    if Ids.isIncognitoProfile(regular) {
      regular = regular.firstIndex(of: "@").map { String(regular[regular.index(after: $0)...]) } ?? Settings.defaultProfileID
    }
    guard let engine = mapping.profiles[regular] else { throw BookmarkWriterError.unknownProfile }
    return engine
  }

  private func validate(profile: String, binding: BookmarkWriterBinding) throws {
    fence.lock()
    defer { fence.unlock() }
    guard JSKey(try mappedEngine(profile)) == JSKey(binding.engine) else { throw BookmarkWriterError.staleBinding }
  }

  @discardableResult
  public func replace(profile: String, document: JSONValue, expectedRevision: UInt64, binding: BookmarkWriterBinding, requestID: String? = nil) throws -> UInt64 {
    try validate(profile: profile, binding: binding)
    let revision: UInt64
    do {
      revision = try coordinator.replaceDocument(engine: binding.engine, profile: profile, document: document, expectedRevision: expectedRevision, requestID: requestID, expectedEngine: binding.engine).view.revision
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
      receipt = try coordinator.submit(profile: profile, mutations: mutations, requestID: requestID, expectedEngine: binding.engine)
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
    await Task.detached {
      let store = BookmarkPendingStore(directory: directory)
      let map = BookmarkProfileMap(state: state, previousOwners: BookmarkDurability(store: store).owners)
      let launch = cacheDirectory.map { BookmarkLaunchCache(directory: $0).load(profiles: map.profiles, defaultProfile: map.defaultProfile) } ?? BookmarkLaunchInput()
      return NativeBookmarkOwner(store: store, profiles: map.profiles, defaultProfile: map.defaultProfile, owningProfiles: map.owningProfiles, launchInput: launch)
    }.value
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
    return lifecycleGeneration == ticket
  }

  fileprivate func stage(state: BrowserState? = nil, token: UUID? = nil, revision: Int? = nil, force: Bool = true) -> UInt64? {
    fence.lock()
    defer { fence.unlock() }
    if let revision {
      guard storeToken == token, revision > observedRevision else { return nil }
      observedRevision = revision
    }
    let next = state.map { BookmarkProfileMap(state: $0, previousOwners: mapping.owningProfiles) } ?? mapping
    guard force || next != mapping else { return nil }
    mapping = next
    lifecycleGeneration += 1
    return lifecycleGeneration
  }

  fileprivate func bind(token: UUID?) {
    fence.lock()
    defer { fence.unlock() }
    storeToken = token
    observedRevision = -1
  }

  fileprivate func installMapping(_ ticket: UInt64) -> Bool {
    fence.lock()
    guard lifecycleGeneration == ticket else { fence.unlock(); return false }
    let mapping = self.mapping
    fence.unlock()
    guard coordinator.remap(profiles: mapping.profiles, defaultProfile: mapping.defaultProfile, owningProfiles: mapping.owningProfiles) else { return false }
    fence.lock()
    defer { fence.unlock() }
    guard lifecycleGeneration == ticket else { return false }
    installedGeneration = ticket
    return true
  }

  @discardableResult
  fileprivate func activate(_ ticket: UInt64, _ body: () throws -> Void) rethrows -> Bool {
    fence.lock()
    defer { fence.unlock() }
    guard lifecycleGeneration == ticket else { return false }
    try body()
    return true
  }

  @MainActor fileprivate func didActivate(_ runtime: NativeBookmarkRuntime) {
    guard startingRuntime === runtime else { return }
    self.runtime = runtime
    startingRuntime = nil
  }

  @MainActor public func start(catalog: LibraryCatalog, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler) async throws {
    guard runtime == nil, startingRuntime == nil else { throw BookmarkCoordinatorError.ownershipUnavailable }
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
    (runtime ?? startingRuntime)?.stop()
    runtime = nil
    startingRuntime = nil
    bind(token: nil)
    _ = stage()
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

  private func schedule(_ ticket: UInt64) {
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
