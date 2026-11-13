import Foundation
import SolaraModel
import Synchronization

public enum Origin: Sendable, Hashable {
  case bridge
  case engine
  case sync
  case native
  case load
}

public struct Commit: Sendable {
  public let rev: Int
  public let origin: Origin
  public let fromSync: Bool
  public let commands: [Command]
  public let changes: ChangeSet
  public let patch: Patch
  public let effects: [Effect]
  public let result: JSONValue?
  public let durable: Bool
  public let state: BrowserState
  let previousPageGenerations: [String: String]
  let currentPageGenerations: [String: String]
}

public struct StoreBusy: Error, CustomStringConvertible {
  public var description: String { "a user transaction is open, so a sync apply has to retry from fresh state" }
}

public struct StorePersistenceRefused: Error, CustomStringConvertible {
  public let description: String
}

public struct StoreSequenceRequired: Error, Sendable {
  public init() {}
}

typealias QueuedSyncApply = @Sendable (Session) throws -> Void

public final class Store: Sendable {
  public static let ringSize = 65_536

  struct Core: ~Copyable {
    var state: BrowserState
    var memory: StoreMemory
    var rev: Int
    var ring: [Patch] = []
    var ringStart = 0
    var held: Session? = nil
    var heldSince: Double = 0
    var heldFromSync = false
    var queuedFromSync: [QueuedSyncApply] = []
    var replaying = false
    var sequencedCommands: [(command: Command, origin: Origin)] = []
    var sequencedHead = 0

    func suffix(since requested: Int) -> [Patch]? {
      if requested >= rev { return [] }
      guard !ring.isEmpty else { return nil }
      let oldest = ring[ringStart].rev
      guard requested >= oldest - 1 else { return nil }
      let count = rev - requested
      guard count <= ring.count else { return nil }
      let offset = ring.count - count
      return (offset..<ring.count).map { ring[(ringStart + $0) % ring.count] }
    }

    mutating func record(_ patch: Patch, state next: BrowserState) {
      state = next
      rev = patch.rev
      if ring.count < Store.ringSize {
        ring.append(patch)
      } else {
        ring[ringStart] = patch
        ringStart = (ringStart + 1) % Store.ringSize
      }
    }
  }

  public static let heldTransactionLimit: Double = 10_000

  enum DeliveryEvent {
    case commit(Commit)
    case callback(DeferredCallback)
    case sequencedFailure(Command, Error, [@Sendable (Command, Error) -> Void])
  }

  final class DeferredCallback: Sendable {
    let action: @Sendable () -> Void
    let ready: Mutex<Bool>

    init(action: @escaping @Sendable () -> Void, ready: Bool) {
      self.action = action
      self.ready = Mutex(ready)
    }
  }

  struct Delivery {
    var queue: [DeliveryEvent] = []
    var draining = false
    var deliveredRev = 0
    #if DEBUG
      var pausedForTesting = false
    #endif
  }

  struct Sequencing {
    var depth = 0
    var owner: ObjectIdentifier?
    var replaySync = false
    var persistenceRefusals: [String] = []
    var invariantReports: [(found: [String], commands: [Command])] = []
    var syncFailures: [String] = []
    var failedSequenced = false
    var callbacks: [DeferredCallback] = []
  }

  public typealias Listener = @Sendable (Commit) -> Void

  private let ingress = NSRecursiveLock()
  private let sequencing = Mutex(Sequencing())
  private let core: Mutex<Core>
  private let published: Mutex<BrowserState>
  private let delivery = Mutex(Delivery())
  private let listeners = Mutex<[(id: Int, listener: Listener)]>([])
  private let nextListener = Atomic<Int>(0)
  private let sequencedFailures = Mutex<[(id: Int, listener: @Sendable (Command, Error) -> Void)]>([])
  private let syncOriginsOn: Atomic<Bool>
  private let clock: @Sendable () -> Double
  private let launchThemeTimers = Mutex<LaunchPageThemeTimers?>(nil)
  public let env: WebAddressing
  public let config: StoreConfig
  public let checksInvariants: Bool
  public let sequencedFailure: @Sendable (Command, Error) -> Void
  public let invariantHandler: @Sendable ([String], [Command]) -> Void
  private let onPersistenceRefusal: @Sendable (String) -> Void

  public init(
    state: BrowserState = BrowserState(),
    memory: StoreMemory? = nil,
    rev: Int = 0,
    env: WebAddressing = PlainWebAddressing(),
    config: StoreConfig = StoreConfig(),
    checksInvariants: Bool = Store.debugBuild,
    sequencedFailure: @escaping @Sendable (Command, Error) -> Void = Store.logSequencedFailure,
    invariantHandler: @escaping @Sendable ([String], [Command]) -> Void = Store.logInvariants,
    onPersistenceRefusal: @escaping @Sendable (String) -> Void = { _ in },
    clock: @escaping @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
  ) {
    self.sequencedFailure = sequencedFailure
    self.invariantHandler = invariantHandler
    self.onPersistenceRefusal = onPersistenceRefusal
    self.clock = clock
    self.env = env
    self.config = config
    syncOriginsOn = Atomic(config.syncOrigins)
    self.checksInvariants = checksInvariants
    var memory = memory ?? StoreMemory(ids: IdSource.random(now: clock()))
    var state = state
    normalizePageState(&state, memory: &memory)
    core = Mutex(Core(state: state, memory: memory, rev: rev))
    published = Mutex(state)
    delivery.withLock { $0.deliveredRev = rev }
  }

  public static let logInvariants: @Sendable ([String], [Command]) -> Void = { found, commands in
    let names = commands.map(\.name).joined(separator: ", ")
    FileHandle.standardError.write(Data("SolaraStore invariants after \(names): \(found.joined(separator: "; "))\n".utf8))
  }

  public static let logSequencedFailure: @Sendable (Command, Error) -> Void = { command, error in
    FileHandle.standardError.write(Data("SolaraStore ordered ingress \(command.name): \(error)\n".utf8))
  }

  public static var debugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  public var rev: Int { sequence { core.withLock { $0.rev } } }
  public var state: BrowserState { sequence { core.withLock { $0.state } } }
  public var snapshot: (rev: Int, state: BrowserState) { sequence { core.withLock { ($0.rev, $0.state) } } }
  public var memory: StoreMemory { sequence { core.withLock { $0.memory } } }

  package var committedSnapshot: (rev: Int, state: BrowserState) { core.withLock { ($0.rev, $0.state) } }
  public var displayState: BrowserState { published.withLock { $0 } }

  private func record(_ core: inout Core, _ patch: Patch, state: BrowserState) {
    core.record(patch, state: state)
    published.withLock { $0 = state }
  }
  var committedMemory: StoreMemory { core.withLock { $0.memory } }

  @discardableResult
  public func dispatch(_ command: Command, origin: Origin = .native, fromSync: Bool = false) throws -> Commit {
    try dispatch([command], origin: origin, fromSync: fromSync)
  }

  @discardableResult
  public func dispatch(_ commands: [Command], origin: Origin = .native, fromSync: Bool = false) throws -> Commit {
    try notifyingPersistenceRefusal {
      try sequence { try dispatchUnsequenced(commands, origin: origin, fromSync: fromSync) }
    }
  }

  private func dispatchUnsequenced(_ commands: [Command], origin: Origin, fromSync: Bool) throws -> Commit {
    let pinned = commands.contains { $0.name == "syncPinsApply" || $0.name == "settlePinChoices" }
    if pinned && commands.count != 1 { throw CommandError("pinned sync commands must be dispatched alone") }
    if let command = commands.first, command.name == "settlePinChoices" {
      let settled = try SettledPinChoices(command.args)
      return try transactUnsequenced(commands: commands, origin: origin, durable: false, fromSync: true, waiting: { settled.apply($0) }, replaying: false) {
        settled.apply($0)
      }!
    }
    if let command = commands.first, command.name == "syncPinsApply" { _ = try SyncPinsApplyRequest(command.args) }
    if commands.count > 1 && commands.contains(where: { $0.name == "pageReport" }) {
      var last: Commit?
      var effects: [Effect] = []
      var result: JSONValue?
      for command in commands {
        let commit = try dispatchUnsequenced([command], origin: origin, fromSync: fromSync)
        effects.append(contentsOf: commit.effects)
        if let value = commit.result { result = value }
        last = commit
      }
      let commit = last!
      return Commit(rev: commit.rev, origin: commit.origin, fromSync: commit.fromSync, commands: commands,
        changes: commit.changes, patch: commit.patch, effects: effects, result: result,
        durable: commands.contains(where: \.isDurable), state: commit.state,
        previousPageGenerations: commit.previousPageGenerations, currentPageGenerations: commit.currentPageGenerations)
    }
    return try transactUnsequenced(commands: commands, origin: origin, durable: commands.contains(where: \.isDurable), fromSync: fromSync, waiting: nil, replaying: false) { session in
      if commands.count == 1 {
        try session.apply(commands[0])
      } else {
        try session.transaction {
          for command in commands {
            session.now = clock()
            try session.apply(command)
          }
        }
      }
    }!
  }

  public var syncOrigins: Bool { syncOriginsOn.load(ordering: .relaxed) }

  public func useSyncOrigins(_ on: Bool) { syncOriginsOn.store(on, ordering: .relaxed) }

  static func closesSyncWindow(_ commands: [Command]) -> Bool {
    !commands.isEmpty && commands.allSatisfy { $0.name == "endFromSync" }
  }

  public var queuedFromSyncCount: Int { sequence { core.withLock { $0.queuedFromSync.count } } }

  private func runQueuedFromSync(sequenced: Bool = true) {
    if sequenced {
      let replayer = core.withLock { core -> Bool in
        if core.replaying || core.queuedFromSync.isEmpty { return false }
        core.replaying = true
        return true
      }
      guard replayer else { return }
    }
    while true {
      do {
        let replayed: Bool
        if sequenced {
          replayed = try withIngress { try replayNextSync() }
        } else {
          replayed = try replayNextSync()
        }
        if !replayed { break }
      } catch {
        if let refusal = error as? StorePersistenceRefused {
          if sequenced { onPersistenceRefusal(refusal.description) }
          else { sequencing.withLock { $0.persistenceRefusals.append(refusal.description) } }
        }
        let message = "SolaraStore: a queued sync session failed: \(error)\n"
        if sequenced { FileHandle.standardError.write(Data(message.utf8)) }
        else { sequencing.withLock { $0.syncFailures.append(message) } }
      }
    }
    guard sequenced else { return }
    let again = core.withLock { core -> Bool in
      core.replaying = false
      return !core.queuedFromSync.isEmpty && (core.held == nil || core.heldFromSync)
    }
    if again { runQueuedFromSync() }
  }

  private func replayNextSync() throws -> Bool {
    guard let next = core.withLock({ core -> QueuedSyncApply? in
      guard core.held == nil || core.heldFromSync else { return nil }
      return core.queuedFromSync.first
    }) else { return false }
    return try transactUnsequenced(commands: [], origin: .sync, durable: false, fromSync: true, waiting: nil, replaying: true, next) != nil
  }

  @discardableResult
  public func transact(commands: [Command] = [], origin: Origin = .native, durable: Bool = false, fromSync: Bool = false, _ body: (Session) throws -> Void) throws -> Commit {
    try notifyingPersistenceRefusal {
      try sequence { try transactUnsequenced(commands: commands, origin: origin, durable: durable, fromSync: fromSync, waiting: nil, replaying: false, body)! }
    }
  }

  public func transactWhenFree(_ body: @escaping @Sendable (Session) throws -> Void) throws {
    try notifyingPersistenceRefusal {
      try sequence { _ = try transactUnsequenced(commands: [], origin: .sync, durable: false, fromSync: true, waiting: body, replaying: false, body) }
    }
  }

  private func transactUnsequenced(
    commands: [Command], origin: Origin, durable: Bool, fromSync: Bool, waiting: QueuedSyncApply?, replaying: Bool, _ body: (Session) throws -> Void
  ) throws -> Commit? {
    try transactPersisting(commands: commands, origin: origin, durable: durable, fromSync: fromSync, waiting: waiting, replaying: replaying, body)
  }

  private func notifyingPersistenceRefusal<T>(_ operation: () throws -> T) rethrows -> T {
    do { return try operation() }
    catch let refusal as StorePersistenceRefused {
      onPersistenceRefusal(refusal.description)
      throw refusal
    }
  }

  private func transactPersisting(
    commands: [Command], origin: Origin, durable: Bool, fromSync: Bool, waiting: QueuedSyncApply?, replaying: Bool, _ body: (Session) throws -> Void
  ) throws -> Commit? {
    let now = clock()
    let tags = syncOriginsOn.load(ordering: .relaxed)
    let pinned = commands.contains { $0.name == "syncPinsApply" || $0.name == "settlePinChoices" }
    let syncRequest = fromSync || origin == .sync || pinned
    let isolated = (tags && syncRequest) || pinned || waiting != nil || replaying
    let fromSync = tags && syncRequest
    defer { sequencing.withLock { $0.replaySync = true } }
    let commit: Commit? = try core.withLock { core -> Commit? in
      if tags || isolated, let held = core.held, core.heldFromSync != isolated, now - core.heldSince > Store.heldTransactionLimit {
        let heldFromSync = core.heldFromSync
        held.resume(state: core.state, memory: core.memory, now: now)
        held.closeTransactions()
        core.held = nil
        let (_, patch) = try settle(
          from: core.state, generations: pageGenerations(core.memory), rev: core.rev, settled: true, held, origin: heldFromSync ? .sync : .native, fromSync: tags && heldFromSync, tags: tags, commands: [], durable: false)
        if let patch { record(&core, patch, state: held.state) }
        core.memory = held.memory
      }
      let heldByUser = core.held != nil && !core.heldFromSync
      if replaying {
        if heldByUser { return nil }
        core.queuedFromSync.removeFirst()
      } else if isolated && (heldByUser || !core.queuedFromSync.isEmpty) && !Self.closesSyncWindow(commands) {
        guard let waiting else { throw StoreBusy() }
        core.queuedFromSync.append(waiting)
        let patch = Patch(rev: core.rev, changes: ChangeSet(), state: core.state)
        return Commit(
          rev: core.rev, origin: origin, fromSync: fromSync, commands: commands, changes: ChangeSet(), patch: patch, effects: [],
          result: commands.first?.name == "settlePinChoices" ? .bool(true) : nil, durable: false,
          state: core.state, previousPageGenerations: pageGenerations(core.memory), currentPageGenerations: pageGenerations(core.memory))
      }
      let session: Session
      if let held = core.held {
        held.resume(state: core.state, memory: core.memory, now: now)
        if now - core.heldSince > Store.heldTransactionLimit { held.closeTransactions() }
        session = held
      } else {
        session = Session(state: core.state, memory: core.memory, env: env, config: config, now: now)
      }
      let checkpoint = config.persistenceRefusal == nil ? nil : (
        state: session.state, memory: session.memory, depth: session.depth, heard: session.heard,
        effects: session.effects, result: session.result, mirroring: session.mirroring, itemSerial: session.itemSerial,
        liveEffectsAppliedThrough: session.liveEffectsAppliedThrough, liveEffectSources: session.liveEffectSources)
      let previousSyncOrigin = session.fromSyncOrigin
      session.fromSyncOrigin = syncRequest || replaying
      defer { session.fromSyncOrigin = previousSyncOrigin }
      if replaying {
        session.memory.fromSyncDepth += 1
        defer { session.memory.fromSyncDepth -= 1 }
        try body(session)
      } else {
        try body(session)
      }
      if let reason = config.persistenceRefusal, let checkpoint {
        let before = checkpoint.state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
        let after = session.state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
        if session.state.settings != checkpoint.state.settings || after != before {
          session.resume(state: checkpoint.state, memory: checkpoint.memory, now: now)
          session.depth = checkpoint.depth
          session.heard = checkpoint.heard
          session.effects = checkpoint.effects
          session.result = checkpoint.result
          session.mirroring = checkpoint.mirroring
          session.itemSerial = checkpoint.itemSerial
          session.liveEffectsAppliedThrough = checkpoint.liveEffectsAppliedThrough
          session.liveEffectSources = checkpoint.liveEffectSources
          throw StorePersistenceRefused(description: reason)
        }
      }
      if session.depth > 0 && core.held == nil {
        core.heldSince = now
        core.heldFromSync = isolated
      }
      core.held = session.depth > 0 ? session : nil
      let (commit, patch) = try settle(
        from: core.state, generations: pageGenerations(core.memory), rev: core.rev, settled: core.held == nil, session, origin: origin, fromSync: fromSync, tags: tags, commands: commands, durable: durable)
      if let patch { record(&core, patch, state: session.state) }
      core.memory = session.memory
      return commit
    }
    return commit
  }

  private func settle(
    from before: BrowserState, generations: [String: String], rev current: Int, settled: Bool, _ session: Session, origin: Origin, fromSync: Bool, tags: Bool, commands: [Command], durable: Bool
  ) throws -> (Commit, Patch?) {
    session.settleLive()
    session.finalizeClosingWindowLive()
    if checksInvariants && settled {
      try Invariants.check(session.state)
      let found = Invariants.violations(session.state)
      if !found.isEmpty { sequencing.withLock { $0.invariantReports.append((found, commands)) } }
    }
    let changes = ChangeSet(from: before, to: session.state)
    let changed = !changes.isEmpty
    let rev = changed ? current + 1 : current
    var patch = Patch(rev: rev, changes: changes, state: session.state)
    patch.fromBridge = tags && origin == .bridge
    patch.fromSync = fromSync
    var seen = Set<Effect>()
    var privateEnds = Set<JSKey>()
    let effects = session.effects.filter { effect in
      if case .endPrivateSession(let session) = effect { return privateEnds.insert(JSKey(session)).inserted }
      return seen.insert(effect).inserted
    }
    let commit = Commit(
      rev: rev, origin: origin, fromSync: fromSync, commands: commands, changes: changes, patch: patch, effects: effects,
      result: session.result, durable: durable, state: changed ? session.state : before,
      previousPageGenerations: generations, currentPageGenerations: pageGenerations(session.memory))
    if changed || !effects.isEmpty { delivery.withLock { $0.queue.append(.commit(commit)) } }
    return (commit, changed ? patch : nil)
  }

  private func pageGenerations(_ memory: StoreMemory) -> [String: String] {
    memory.pages.compactMapValues(\.generation)
  }

  public func catchUp(sinceRev: Int) -> StoreCatchUp {
    sequence { core.withLock { core in
      if let patches = core.suffix(since: sinceRev) { return .patches(rev: core.rev, patches: patches) }
      return .snapshot(rev: core.rev, state: core.state)
    } }
  }

  public func patches(since rev: Int) -> [Patch]? {
    sequence { core.withLock { $0.suffix(since: rev) } }
  }

  public func setPrivateSessionGeneration(session: String, generation: String) {
    sequence { core.withLock { core in
      core.memory.privateSessionGenerations[JSKey(session)] = generation
      core.held?.memory.privateSessionGenerations[JSKey(session)] = generation
    } }
  }

  @discardableResult
  public func confirmPrivateSessionEnded(session: String, profiles: [String], generation: String? = nil) -> Bool {
    sequence {
      let active = core.withLock { core in
        if let generation, core.memory.privateSessionGenerations[JSKey(session)] != generation { return true }
        return core.state.windows.values.contains { window in
          window.incognito && (profiles.contains { $0.jsEquals(window.profileId) } || core.state.privateSession(window.profileId)?.jsEquals(session) == true)
        }
      }
      guard !active else { return false }
      do {
        _ = try transactUnsequenced(commands: [], origin: .native, durable: false, fromSync: false, waiting: nil, replaying: false) { transaction in
          let removed = transaction.state.downloads.filter { download in
            guard download.isPrivate else { return false }
            if download.offTheRecord && (download.profile ?? "").jsEquals(session) { return true }
            guard let profile = download.profile else { return false }
            return profiles.contains { $0.jsEquals(profile) } || transaction.state.privateSession(profile)?.jsEquals(session) == true
          }
          let ids = Set(removed.map { JSKey($0.id) })
          transaction.memory.endedPrivateDownloads.formUnion(removed.map(\.id))
          if !ids.isEmpty { transaction.update { $0.downloads = $0.downloads.filter { !ids.contains(JSKey($0.id)) } } }
        }
      } catch { return false }
      core.withLock { core in
        core.memory.privateSessionGenerations.removeValue(forKey: JSKey(session))
        scrubPrivateClosingMemory(&core.memory, session: session, profiles: profiles)
        if let held = core.held {
          held.memory.privateSessionGenerations.removeValue(forKey: JSKey(session))
          scrubPrivateClosingMemory(&held.memory, session: session, profiles: profiles)
          if let heard = held.heard { held.heard = scrubPrivateClosingState(heard, session: session, profiles: profiles) }
        }
        core.ring.removeAll(keepingCapacity: false)
        core.ringStart = 0
      }
      return true
    }
  }

  private var ownsSequence: Bool {
    sequencing.withLock { $0.depth > 0 && $0.owner == ObjectIdentifier(Thread.current) }
  }

  public func withinSequence<T>(_ body: () throws -> T) throws -> T {
    let owns = ownsSequence
    #if DEBUG
      precondition(owns, "withinSequence requires an outer sequence on the calling thread")
    #endif
    guard owns else { throw StoreSequenceRequired() }
    return try body()
  }

  public func afterSequence(_ action: @escaping @Sendable () -> Void) {
    ingress.lock()
    let callback = sequencing.withLock { sequencing in
      let callback = DeferredCallback(action: action, ready: sequencing.depth == 0)
      if sequencing.depth > 0 { sequencing.callbacks.append(callback) }
      return callback
    }
    delivery.withLock { $0.queue.append(.callback(callback)) }
    ingress.unlock()
    if callback.ready.withLock({ $0 }) { drain() }
  }

  public func pageHostSnapshotInScope(_ tabId: String, generation: String) throws -> (state: BrowserState, facts: PageFacts?, producerCurrent: Bool) {
    try withinSequence { core.withLock { core in
      let fence = core.memory.pageProducerFence[tabId]
      return (core.state, core.memory.pages[tabId]?.facts,
        fence?.generation == generation && fence?.retired == false)
    } }
  }

  public func rebasePageExecutionInScope(_ tabId: String, generation: String, executedNavigationSeq: Int?) throws {
    try withinSequence {
      _ = try transactUnsequenced(commands: [], origin: .engine, durable: false, fromSync: false, waiting: nil, replaying: false) { session in
        guard var page = session.memory.pages[tabId], page.generation == generation,
          let tab = session.state.tabs[tabId] else { return }
        page.model = TabPageModel(navigation: pageNavigation(tab), adoptedUrl: truthy(tab.adoptId) ? tab.url : nil,
          handoffSeq: executedNavigationSeq, webkitWithoutHandoff: false, wasNewTab: page.wasNewTab)
        page.modelSerial = try session.nextPageModelSerial()
        session.memory.pages[tabId] = page
      }
    }
  }

  public func confirmPageExecutionInScope(_ tabId: String, generation: String) throws {
    try withinSequence {
      _ = try transactUnsequenced(commands: [], origin: .engine, durable: false, fromSync: false, waiting: nil, replaying: false) { session in
        guard var page = session.memory.pages[tabId], page.generation == generation else { return }
        page.model.executionConfirmed()
        page.modelSerial = try session.nextPageModelSerial()
        session.memory.pages[tabId] = page
      }
    }
  }

  public func deliveryCursor() -> (committed: Int, delivered: Int) {
    let capture = { (self.core.withLock { $0.rev }, self.delivery.withLock { $0.deliveredRev }) }
    return ownsSequence ? capture() : sequence(capture)
  }

  #if DEBUG
    func pauseDeliveryForTesting() -> Bool {
      delivery.withLock { delivery in
        guard !delivery.draining, !delivery.pausedForTesting else { return false }
        delivery.pausedForTesting = true
        return true
      }
    }

    var queuedDeliveriesForTesting: Int { delivery.withLock { $0.queue.count } }

    func resumeDeliveryForTesting() {
      delivery.withLock { $0.pausedForTesting = false }
      drain()
    }
  #endif

  public func startLaunchPageThemeTimers(after: @escaping LaunchPageTheme.Schedule = { delay, work in
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
  }) {
    launchThemeTimers.withLock { $0 = LaunchPageThemeTimers(after: after) }
    sequence {}
  }

  private func refreshLaunchPageThemeTimers() {
    guard let timers = launchThemeTimers.withLock({ $0 }) else { return }
    timers.refresh(now: clock(), store: self) {
      core.withLock { core in
        core.memory.pages.compactMapValues { page -> LaunchPageThemeDeadline? in
          guard let generation = page.generation, let at = page.live.settleAt else { return nil }
          return LaunchPageThemeDeadline(generation: generation, at: at)
        }
      }
    }
  }

  public func enqueuePageReport(id: String, report: JSONValue) {
    enqueueSequenced(Command("pageReport", [.string(id), report]), origin: .engine)
  }

  public func pageFacts(_ tabId: String) -> PageFacts? {
    sequence { core.withLock { core in
      guard let tab = core.state.tabs[tabId], tab.unloaded != true, !truthy(tab.pageIn) else { return nil }
      return core.memory.pages[tabId]?.facts
    } }
  }

  public func livePages() -> [String: PageFacts] {
    sequence { core.withLock { core in
      var pages: [String: PageFacts] = [:]
      for (id, page) in core.memory.pages {
        guard let tab = core.state.tabs[id], tab.unloaded != true, !truthy(tab.pageIn), let facts = page.facts else { continue }
        pages[id] = facts
      }
      return pages
    } }
  }

  public func registerKeepAliveRuntime() -> Int {
    do {
      let result = try dispatch(Command("registerKeepAliveRuntime")).result?.number
      guard let result, result > 0, result <= 9_007_199_254_740_991, result.rounded(.towardZero) == result else {
        preconditionFailure("keepalive runtime registration returned an invalid epoch")
      }
      return Int(result)
    } catch { preconditionFailure("keepalive runtime epoch exhausted: \(error)") }
  }

  public func preparePageIssueInScope(id: String, report: JSONValue) throws -> PreparedPageIssue? {
    try withinSequence { try committedPageIssue(id: id, report: report) }
  }

  public func preparePooledIssue(id: String, report: JSONValue) throws -> PreparedPageIssue? {
    try notifyingPersistenceRefusal { try sequence { try committedPageIssue(id: id, report: report) } }
  }

  private func committedPageIssue(id: String, report: JSONValue) throws -> PreparedPageIssue? {
    let now = clock()
    guard let (state, memory) = committedUnlessHeldExpired(now: now) else {
      var prepared: PreparedPageIssue?
      _ = try transactUnsequenced(commands: [], origin: .engine, durable: false, fromSync: false, waiting: nil, replaying: false) {
        prepared = try $0.preparePageIssue(id: id, report: report)
      }
      return prepared
    }
    return try Session(state: state, memory: memory, env: env, config: config, now: now).preparePageIssue(id: id, report: report)
  }

  private func committedUnlessHeldExpired(now: Double) -> (BrowserState, StoreMemory)? {
    core.withLock { core in
      if core.held != nil, now - core.heldSince > Store.heldTransactionLimit { return nil }
      return (core.state, core.memory)
    }
  }

  public func consumePooledIssue(id: String, prepared: PreparedPageIssue) -> Bool {
    var accepted = false
    do {
      let consume = {
        let now = self.clock()
        if let (state, memory) = self.committedUnlessHeldExpired(now: now),
          Session(state: state, memory: memory, env: self.env, config: self.config, now: now).pageIssueAlreadyConsumed(id: id, prepared: prepared) {
          accepted = true
          return
        }
        _ = try self.transactUnsequenced(commands: [], origin: .engine, durable: false, fromSync: false,
          waiting: nil, replaying: false) { accepted = try $0.consumePageIssue(id: id, prepared: prepared) }
      }
      if ownsSequence { try withinSequence(consume) }
      else { try sequence(consume) }
    } catch { return false }
    return accepted
  }

  public func enqueueSequenced(_ command: Command, origin: Origin = .engine) {
    ingress.lock()
    defer { ingress.unlock() }
    core.withLock { $0.sequencedCommands.append((command, origin)) }
  }

  public func sequence<T>(_ operation: () throws -> T) rethrows -> T {
    try withIngress {
      drainSequenced()
      return try operation()
    }
  }

  public func drainForQuit(until deadline: ContinuousClock.Instant) -> Bool {
    while ContinuousClock.now < deadline {
      if ingress.try() {
        guard ContinuousClock.now < deadline else { ingress.unlock(); return false }
        let drained = withAcquiredIngress { drainSequenced(until: deadline) }
        return drained && ContinuousClock.now < deadline
      }
      let remaining = ContinuousClock.now.duration(to: deadline).components
      let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1_000_000_000_000_000_000
      if seconds > 0 { Thread.sleep(forTimeInterval: min(seconds, 0.001)) }
    }
    return false
  }

  private func withIngress<T>(_ operation: () throws -> T) rethrows -> T {
    ingress.lock()
    return try withAcquiredIngress(operation)
  }

  private func withAcquiredIngress<T>(_ operation: () throws -> T) rethrows -> T {
    sequencing.withLock {
      if $0.depth == 0 { $0.owner = ObjectIdentifier(Thread.current) }
      $0.depth += 1
    }
    defer {
      let completion = sequencing.withLock { sequencing in
        sequencing.depth -= 1
        let replay = sequencing.replaySync
        let outermost = sequencing.depth == 0
        let refusals = outermost ? sequencing.persistenceRefusals : []
        let failures = outermost ? sequencing.syncFailures : []
        let invariants = outermost ? sequencing.invariantReports : []
        let callbacks = outermost ? sequencing.callbacks : []
        let delivers = replay || sequencing.failedSequenced || !callbacks.isEmpty
        if outermost {
          sequencing.owner = nil
          sequencing.replaySync = false
          sequencing.failedSequenced = false
          sequencing.persistenceRefusals.removeAll(keepingCapacity: true)
          sequencing.syncFailures.removeAll(keepingCapacity: true)
          sequencing.invariantReports.removeAll(keepingCapacity: true)
          sequencing.callbacks.removeAll(keepingCapacity: true)
        }
        return (outermost: outermost, replay: replay, delivers: delivers, refusals: refusals, failures: failures, invariants: invariants, callbacks: callbacks)
      }
      if !completion.outermost && completion.replay { runQueuedFromSync(sequenced: false) }
      ingress.unlock()
      if completion.outermost {
        for callback in completion.callbacks { callback.ready.withLock { $0 = true } }
        refreshLaunchPageThemeTimers()
        for report in completion.invariants { invariantHandler(report.found, report.commands) }
        for message in completion.failures { FileHandle.standardError.write(Data(message.utf8)) }
        for reason in completion.refusals { onPersistenceRefusal(reason) }
        if completion.delivers { drain() }
        if completion.replay { runQueuedFromSync() }
      }
    }
    return try operation()
  }

  @discardableResult
  private func drainSequenced(until deadline: ContinuousClock.Instant? = nil) -> Bool {
    while true {
      if let deadline, ContinuousClock.now >= deadline { return false }
      let next = core.withLock { core -> (command: Command, origin: Origin)? in
        if let deadline, ContinuousClock.now >= deadline { return nil }
        guard core.sequencedHead < core.sequencedCommands.count else {
          core.sequencedCommands.removeAll(keepingCapacity: true)
          core.sequencedHead = 0
          return nil
        }
        let next = core.sequencedCommands[core.sequencedHead]
        core.sequencedHead += 1
        return next
      }
      guard let next else { return deadline.map { ContinuousClock.now < $0 } ?? true }
      do {
        _ = try dispatchUnsequenced([next.command], origin: next.origin, fromSync: false)
      } catch {
        if let refusal = error as? StorePersistenceRefused {
          sequencing.withLock { $0.persistenceRefusals.append(refusal.description) }
        }
        let observers = sequencedFailures.withLock { $0.map(\.listener) }
        delivery.withLock { $0.queue.append(.sequencedFailure(next.command, error, observers)) }
        sequencing.withLock { $0.failedSequenced = true }
      }
      if sequencing.withLock({ $0.replaySync }) { runQueuedFromSync(sequenced: false) }
    }
  }

  @discardableResult
  public func observeSequencedFailures(_ listener: @escaping @Sendable (Command, Error) -> Void) -> Int {
    let id = nextListener.add(1, ordering: .relaxed).newValue
    sequencedFailures.withLock { $0.append((id, listener)) }
    return id
  }

  @discardableResult
  public func observeLive(tabId: String, _ listener: @escaping @Sendable (LiveChange) -> Void) -> (token: Int, baseline: PageLiveFacts?) {
    sequence {
      let baseline = core.withLock { (rev: $0.rev, facts: $0.state.live[tabId]) }
      let previous = Mutex(baseline.facts)
      let token = subscribe { commit in
        guard commit.rev > baseline.rev else { return }
        let current = commit.state.live[tabId]
        let before = previous.withLock { previous in
          let before = previous
          previous = current
          return before
        }
        if before != current {
          listener(LiveChange(tabId: tabId, rev: commit.rev, previous: before, current: current, url: commit.state.tabs[tabId]?.url, profileId: commit.state.tabs[tabId]?.profileId,
            previousGeneration: commit.previousPageGenerations[tabId], currentGeneration: commit.currentPageGenerations[tabId]))
        }
      }
      return (token, baseline.facts)
    }
  }

  @discardableResult
  public func observeLive(_ listener: @escaping @Sendable (LiveChange) -> Void) -> (token: Int, baseline: [String: PageLiveFacts]) {
    sequence {
      let baseline = core.withLock { (rev: $0.rev, facts: $0.state.live) }
      let previous = Mutex(baseline.facts)
      let token = subscribe { commit in
        guard commit.rev > baseline.rev else { return }
        let current = commit.state.live
        let before = previous.withLock { previous in
          let before = previous
          previous = current
          return before
        }
        for id in Set(before.keys).union(current.keys).sorted() where before[id] != current[id] {
          listener(LiveChange(tabId: id, rev: commit.rev, previous: before[id], current: current[id], url: commit.state.tabs[id]?.url, profileId: commit.state.tabs[id]?.profileId,
            previousGeneration: commit.previousPageGenerations[id], currentGeneration: commit.currentPageGenerations[id]))
        }
      }
      return (token, baseline.facts)
    }
  }

  @discardableResult
  public func subscribe(_ listener: @escaping Listener) -> Int {
    let id = nextListener.add(1, ordering: .relaxed).newValue
    listeners.withLock { $0.append((id, listener)) }
    return id
  }

  public func unsubscribe(_ id: Int) {
    listeners.withLock { $0.removeAll { $0.id == id } }
    sequencedFailures.withLock { $0.removeAll { $0.id == id } }
  }

  private func drain() {
    let owner = delivery.withLock { delivery -> Bool in
      #if DEBUG
        if delivery.pausedForTesting { return false }
      #endif
      if delivery.draining || delivery.queue.isEmpty { return false }
      delivery.draining = true
      return true
    }
    guard owner else { return }
    while let event = delivery.withLock({ delivery -> DeliveryEvent? in
      if delivery.queue.isEmpty {
        delivery.draining = false
        return nil
      }
      if case .callback(let callback) = delivery.queue[0], !callback.ready.withLock({ $0 }) {
        delivery.draining = false
        return nil
      }
      return delivery.queue.removeFirst()
    }) {
      switch event {
      case .callback(let callback):
        callback.action()
      case .commit(let commit):
        for (_, listener) in listeners.withLock({ $0 }) { listener(commit) }
        delivery.withLock { $0.deliveredRev = max($0.deliveredRev, commit.rev) }
      case .sequencedFailure(let command, let error, let observers):
        sequencedFailure(command, error)
        for listener in observers { listener(command, error) }
      }
    }
  }
}

public struct InvariantViolation: Error, CustomStringConvertible {
  public let description: String
}

public enum Invariants {
  public static func violations(_ s: BrowserState) -> [String] {
    var out: [String] = []
    var seenIds = Set<String>()
    for id in s.profiles.keys + s.windows.keys + s.tabs.keys + s.groups.keys + s.splits.keys where !seenIds.insert(id).inserted {
      out.append("id \(id) is used twice")
    }
    var placed: [String: String] = [:]
    let peekTabs = Set(s.peeks.values.map(\.tabId))
    for w in s.windows.values {
      var mine = Set<String>()
      for id in w.tabIds {
        if !mine.insert(id).inserted { out.append("window \(w.id) lists \(id) twice") }
        guard let t = s.tabs[id] else {
          out.append("window \(w.id) lists missing tab \(id)")
          continue
        }
        if t.windowId != w.id { out.append("window \(w.id) lists \(id) of window \(t.windowId)") }
        placed[id] = w.id
      }
      if pinnedFirst(w.tabIds, s.tabs, s.groups) != w.tabIds { out.append("window \(w.id) is not pinned first") }
      for (profileId, active) in w.activeTabIds {
        guard let t = s.tabs[active], t.windowId == w.id, t.profileId == profileId else {
          out.append("window \(w.id) shows \(active) for \(profileId)")
          continue
        }
      }
      if !w.tabIds.isEmpty && w.activeTabIds[w.profileId] == nil && w.tabIds.contains(where: { s.tabs[$0]?.profileId == w.profileId }) {
        out.append("window \(w.id) shows no tab for its profile")
      }
    }
    for t in s.tabs.values where placed[t.id] == nil && !peekTabs.contains(t.id) { out.append("tab \(t.id) is in no window") }
    for g in s.groups.values {
      if g.tabIds.isEmpty { out.append("group \(g.id) is empty") }
      guard let w = s.windows[g.windowId] else {
        out.append("group \(g.id) is in no window")
        continue
      }
      let spots = g.tabIds.compactMap { w.tabIds.firstIndex(of: $0) }
      if spots.count != g.tabIds.count { out.append("group \(g.id) holds tabs outside its window") }
      if let low = spots.min(), let high = spots.max(), high - low + 1 != spots.count { out.append("group \(g.id) is not contiguous") }
      if let parent = g.parentId {
        if let p = s.groups[parent] {
          if !g.tabIds.allSatisfy({ p.tabIds.contains($0) }) { out.append("group \(g.id) sits outside its parent") }
        } else {
          out.append("group \(g.id) has a missing parent")
        }
      }
    }
    var paneOf: [String: String] = [:]
    for v in s.splits.values {
      if v.tabIds.count < 2 || v.tabIds.count > Splits.maxPanes { out.append("split \(v.id) has \(v.tabIds.count) panes") }
      for id in v.tabIds {
        if let other = paneOf[id] { out.append("tab \(id) is in splits \(other) and \(v.id)") }
        paneOf[id] = v.id
      }
    }
    let members = s.pinnedGroupMemberSet()
    for t in s.tabs.values {
      if t.tileFolder != nil && t.pinSection != .tile { out.append("tab \(t.id) has a folder but is not a tile") }
      let housed = t.pinned || members.contains(t.id)
      if housed != (t.pinnedUrl != nil && !(t.pinnedUrl ?? "").isEmpty) && !(housed && t.url.isEmpty) {
        out.append("tab \(t.id) pinnedUrl does not match its place")
      }
    }
    return out
  }

  public static func check(_ state: BrowserState) throws {
    var seen = Set<String>()
    for download in state.downloads where !seen.insert(download.id).inserted {
      throw InvariantViolation(description: "download \(download.id) is listed twice")
    }
  }
}
