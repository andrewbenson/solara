import Foundation
import SolaraModel

public enum BookmarkEngineAvailabilityError: Error, Sendable {
  case permanentlyGone
}

public struct BookmarkEngineClient: Sendable {
  public var readTree: @Sendable (String) async throws -> EngineBookmarkTree
  public var apply: @Sendable (String, [BookmarkOperation]) async throws -> BookmarkApplyResult

  public init(readTree: @escaping @Sendable (String) async throws -> EngineBookmarkTree, apply: @escaping @Sendable (String, [BookmarkOperation]) async throws -> BookmarkApplyResult) {
    self.readTree = readTree
    self.apply = apply
  }

  @MainActor
  public init(_ client: any EngineClient) {
    let adapter = BookmarkEngineAdapter(client)
    readTree = { engine in try await adapter.read(engine) }
    apply = { engine, ops in try await adapter.apply(engine, ops) }
  }
}

public struct BookmarkPumpClock {
  public var wallTimeMs: @MainActor () -> Double
  public var monotonicTimeMs: @MainActor () -> Double

  public init(wallTimeMs: @escaping @MainActor () -> Double, monotonicTimeMs: @escaping @MainActor () -> Double) {
    self.wallTimeMs = wallTimeMs
    self.monotonicTimeMs = monotonicTimeMs
  }
}

public struct BookmarkPumpScheduler {
  public var schedule: @MainActor (Double, @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)

  public init(schedule: @escaping @MainActor (Double, @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)) {
    self.schedule = schedule
  }
}

@MainActor
final class BookmarkEngineQueue {
  nonisolated static let shared = BookmarkEngineQueue()
  private var tails: JSMap<Task<Void, Never>> = [:]
  nonisolated init() {}

  func perform<T: Sendable>(engine: String, operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    let previous = tails[engine]
    let task = Task {
      await previous?.value
      return try await operation()
    }
    tails[engine] = Task { _ = await task.result }
    return try await task.value
  }
}

@MainActor
public final class BookmarkPump {
  private final class Lane {
    var read = false
    var push = false
    var readDeferred = false
    var deadline: Double?
    var wallDeadline: Double?
    var cancel: (@MainActor () -> Void)?
    var task: Task<Void, Never>?
    var halted = false
    var failedReads = 0
    var failedWrites = 0
    var writeDeadline: Double?
  }

  private let coordinator: BookmarkCoordinator
  private let client: BookmarkEngineClient
  private let clock: BookmarkPumpClock
  private let scheduler: BookmarkPumpScheduler
  let epoch: UInt64
  private var lanes: JSMap<Lane> = [:]
  private var stopped = false

  public convenience init(coordinator: BookmarkCoordinator, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler) {
    self.init(coordinator: coordinator, client: client, clock: clock, scheduler: scheduler, epoch: coordinator.claimPump())
  }

  init(coordinator: BookmarkCoordinator, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler, epoch: UInt64) {
    self.coordinator = coordinator
    self.client = client
    self.clock = clock
    self.scheduler = scheduler
    self.epoch = epoch
  }

  @discardableResult
  public func submit(profile: String, mutations: [BookmarkMutation], fromSync: Bool = false, requestID: String? = nil) async throws -> BookmarkReceipt {
    let engine = coordinator.engine(profile: profile)
    guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
    let coordinator = coordinator
    let epoch = epoch
    let receipt = try await coordinator.offMain { try coordinator.submit(profile: profile, mutations: mutations, fromSync: fromSync, requestID: requestID, expectedPumpEpoch: epoch) }
    requestPush(engine: engine)
    return receipt
  }

  func claimCatalog(coordinator: BookmarkCoordinator, replacing previousEpoch: UInt64? = nil) throws -> BookmarkCatalogClaim {
    guard self.coordinator === coordinator, !stopped else { throw BookmarkCoordinatorError.ownershipUnavailable }
    try coordinator.claimCatalog(epoch: epoch, replacing: previousEpoch)
    return BookmarkCatalogClaim(coordinator: coordinator, pump: self, epoch: epoch)
  }

  func submit(operations: [BookmarkOperation], engine: String) async throws -> (BookmarkReceipt, BookmarkApplyResult) {
    guard let profile = coordinator.catalogProfile(engine: engine) else { throw BookmarkCoordinatorError.invalidProfileScope }
    let raw = try JSONValue.parse(JSONEncoder().encode(operations))
    let values = JSONValue.array((raw.array ?? []).map { value in
      var operation = value.object ?? [:]
      for key in ["t", "u", "key"] {
        if let text = operation[key]?.string { operation[key] = .string(BookmarkString.encode(text)) }
      }
      return .object(operation)
    })
    let receipt = try await submit(profile: profile, mutations: [.init(method: "applyBookmarkOperations", args: [values, true])])
    let result = receipt.results.first
    return (receipt, BookmarkApplyResult(applied: Int(result?["applied"]?.number ?? 0), skipped: Int(result?["skipped"]?.number ?? 0), invalid: result?["invalid"]?.array?.compactMap(\.string) ?? []))
  }

  public func requestRead(engine: String) {
    guard let lane = lane(engine) else { return }
    lane.read = true
    start(engine, lane)
  }

  public func requestPush(engine: String) {
    guard let lane = lane(engine) else { return }
    lane.push = true
    start(engine, lane)
  }

  public func settle(engine: String) async {
    while let task = lanes[engine]?.task { await task.value }
  }

  public func stop() { stop(invalidate: true) }

  func stop(invalidate: Bool) {
    guard !stopped else { return }
    stopped = true
    if invalidate { coordinator.invalidatePump(epoch: epoch) }
    for (_, lane) in lanes { lane.cancel?(); lane.cancel = nil }
  }

  private func lane(_ engine: String) -> Lane? {
    guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else { return nil }
    if let lane = lanes[engine] { return lane.halted ? nil : lane }
    let lane = Lane()
    let view = coordinator.desiredView(engine: engine)
    lane.read = epoch > 1 || !view.readyForSync || view.requiresRead || view.inFlightTarget != nil
    lanes[engine] = lane
    return lane
  }

  private func start(_ engine: String, _ lane: Lane) {
    guard lane.task == nil, !lane.halted else { return }
    lane.task = Task { await self.run(engine, lane) }
  }

  private func updateDeadline(_ lane: Lane, _ view: BookmarkDesiredView) {
    guard lane.wallDeadline != view.retryNotBeforeMs else { return }
    lane.cancel?()
    lane.cancel = nil
    lane.wallDeadline = view.retryNotBeforeMs
    lane.deadline = view.retryNotBeforeMs.map { clock.monotonicTimeMs() + max(0, min(60_000, $0 - clock.wallTimeMs())) }
  }

  private static func backoffMs(_ failures: Int) -> Double {
    min(60_000, 1500 * pow(2, Double(min(max(failures, 1) - 1, 6))))
  }

  private func due(_ lane: Lane) -> Double? {
    [lane.deadline, lane.writeDeadline].compactMap { $0 }.max()
  }

  private func journaled(_ lane: Lane) {
    lane.failedWrites = 0
    lane.writeDeadline = nil
  }

  private func journalFailed(_ engine: String, _ lane: Lane) -> Bool {
    guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else {
      lane.halted = true
      return false
    }
    lane.failedWrites += 1
    lane.cancel?()
    lane.cancel = nil
    lane.writeDeadline = clock.monotonicTimeMs() + Self.backoffMs(lane.failedWrites)
    lane.read = true
    lane.readDeferred = true
    return true
  }

  private func waitForDeadline(_ engine: String, _ lane: Lane) {
    guard lane.cancel == nil, let deadline = due(lane) else { return }
    lane.cancel = scheduler.schedule(max(0, deadline - clock.monotonicTimeMs())) { [weak self, weak lane] in
      guard let self, let lane, !self.stopped, self.coordinator.ownsPump(engine: engine, epoch: self.epoch) else { return }
      lane.cancel = nil
      self.start(engine, lane)
    }
  }

  private func run(_ engine: String, _ lane: Lane) async {
    defer {
      lane.task = nil
      if !coordinator.ownsPump(engine: engine, epoch: epoch) {
        lane.cancel?()
        lanes.removeValue(forKey: engine)
      }
    }
    while !stopped, let (view, pendingDelta) = coordinator.pumpInput(engine: engine, epoch: epoch) {
      let delta = coordinator.chromeOperations(pendingDelta, engine: engine, document: view.document)
      if coordinator.catalogProfile(engine: engine) == nil, view.document["nodes"]?.object?.isEmpty == true, !coordinator.legacyImportPending(engine: engine) {
        let coordinator = coordinator
        let epoch = epoch
        let terminated = await coordinator.offMain { coordinator.terminalizeEmptyAliaslessEngine(engine: engine, epoch: epoch) }
        if terminated { return }
        guard journalFailed(engine, lane) else { return }
        waitForDeadline(engine, lane)
        return
      }
      updateDeadline(lane, view)
      let waiting = due(lane).map { $0 > clock.monotonicTimeMs() } ?? false
      if lane.read && !(lane.readDeferred && waiting) {
        lane.read = false
        do {
          let client = client
          let coordinator = coordinator
          let epoch = epoch
          let tree = try await coordinator.engineQueue.perform(engine: engine) {
            guard coordinator.ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
            return try await client.readTree(engine)
          }
          guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else { return }
          let document = try Self.document(tree, engine: engine)
          let revision = view.revision
          let read = await coordinator.offMain { coordinator.completeRead(engine: engine, document: document, capturedRevision: revision, epoch: epoch) }
          guard read else {
            guard journalFailed(engine, lane) else { return }
            continue
          }
          journaled(lane)
          lane.failedReads = 0
          lane.readDeferred = false
          lane.push = true
        } catch {
          guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else { return }
          if case BookmarkEngineAvailabilityError.permanentlyGone = error, coordinator.catalogProfile(engine: engine) == nil {
            let coordinator = coordinator
            let epoch = epoch
            let terminated = await coordinator.offMain { coordinator.terminalizeGoneEngine(engine: engine, epoch: epoch) }
            if terminated { return }
            guard journalFailed(engine, lane) else { return }
            waitForDeadline(engine, lane)
            return
          }
          let coordinator = coordinator
          let epoch = epoch
          let now = clock.wallTimeMs()
          lane.failedReads += 1
          let delay = Self.backoffMs(lane.failedReads)
          let deferred = await coordinator.offMain { coordinator.deferRead(engine: engine, epoch: epoch, nowMs: now, delayMs: delay) }
          guard deferred else {
            guard journalFailed(engine, lane) else { return }
            continue
          }
          journaled(lane)
          lane.read = true
          lane.readDeferred = true
        }
        continue
      }
      if waiting {
        waitForDeadline(engine, lane)
        return
      }
      guard !coordinator.bookmarkEditsPaused(engine: engine) else { return }
      guard lane.push else { return }
      lane.push = false
      guard !BookmarkFlat(document: view.document, engine: engine).nodes.isEmpty else { return }
      if delta.isEmpty && !coordinator.migrationNeedsPush(engine: engine) {
        if view.failedPushes != 0 || view.retryNotBeforeMs != nil {
          let coordinator = coordinator
          let epoch = epoch
          let now = clock.wallTimeMs()
          let cleared = await coordinator.offMain { coordinator.completePush(engine: engine, captured: view, epoch: epoch, succeeded: true, nowMs: now) }
          guard cleared else {
            guard journalFailed(engine, lane) else { return }
            continue
          }
          journaled(lane)
        }
        return
      }
      let coordinator = coordinator
      let epoch = epoch
      let began = await coordinator.offMain { coordinator.beginPush(engine: engine, captured: view, epoch: epoch) }
      guard began else {
        guard journalFailed(engine, lane) else { return }
        continue
      }
      journaled(lane)
      let succeeded: Bool
      do {
        let ops = try delta.map { try JSONDecoder().decode(BookmarkOperation.self, from: Data($0.text().utf8)) }
        let client = client
        let coordinator = coordinator
        let epoch = epoch
        let result = try await coordinator.engineQueue.perform(engine: engine) {
          guard coordinator.ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
          return try await client.apply(engine, ops)
        }
        succeeded = result.skipped == 0 && result.invalid.isEmpty && result.applied == ops.count
      } catch { succeeded = false }
      guard !stopped, coordinator.ownsPump(engine: engine, epoch: epoch) else { return }
      let now = clock.wallTimeMs()
      let completed = await coordinator.offMain { coordinator.completePush(engine: engine, captured: view, epoch: epoch, succeeded: succeeded, nowMs: now) }
      guard completed else {
        guard journalFailed(engine, lane) else { return }
        continue
      }
      journaled(lane)
      lane.push = true
      if !succeeded || coordinator.migrationNeedsConfirmation(engine: engine) { lane.read = true }
    }
  }

  private static func document(_ tree: EngineBookmarkTree, engine: String) throws -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    var records: [JSONValue] = []
    var seen = Set<JSKey>()
    func visit(_ node: EngineBookmarkNode, id: String, parent: String?, depth: Int) throws {
      guard depth <= 512, seen.insert(JSKey(id)).inserted, node.kind == "f" || node.kind == "u", parent != nil || node.kind == "f" else { throw BookmarkReadUnavailable.unsupported }
      var record: JSONObject = ["id": .string(id), "kind": node.kind == "f" ? "folder" : "url", "parent": JSONValue(parent), "title": .string(node.title), "addedAt": .number(node.addedAt)]
      if let key = node.syncKey { record["key"] = .string(key) }
      if node.kind == "u" { record["url"] = .string(node.url ?? "") }
      else { record["children"] = JSONValue((node.children ?? []).map(\.id)) }
      records.append(.object(record))
      if node.kind == "f" {
        for child in node.children ?? [] { try visit(child, id: child.id, parent: id, depth: depth + 1) }
      }
    }
    try visit(tree.bar, id: roots.bar, parent: nil, depth: 0)
    try visit(tree.other, id: roots.other, parent: nil, depth: 0)
    return BookmarkFlat(records: records).document(profiles: [])
  }
}

@MainActor
private final class BookmarkEngineAdapter {
  let client: any EngineClient
  init(_ client: any EngineClient) { self.client = client }
  func read(_ engine: String) async throws -> EngineBookmarkTree {
    try await client.watchBookmarks(engineProfile: engine)
    return try await client.readBookmarks(engineProfile: engine)
  }
  func apply(_ engine: String, _ ops: [BookmarkOperation]) async throws -> BookmarkApplyResult {
    try await client.applyBookmarks(ops: ops, engineProfile: engine)
  }
}

@MainActor
final class BookmarkCatalogClaim {
  let coordinator: BookmarkCoordinator
  let pump: BookmarkPump
  let epoch: UInt64

  init(coordinator: BookmarkCoordinator, pump: BookmarkPump, epoch: UInt64) {
    self.coordinator = coordinator
    self.pump = pump
    self.epoch = epoch
  }

  func validate(engine: String) throws {
    guard coordinator.ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
  }
}
