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
  case expired
  case staleBinding
  case unknownProfile
  case invalidDocument(String)
  case refused(String)
  case conditionFailed(String)

  public var code: String {
    switch self {
    case .expired: "expired"
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
    case .expired: "the bookmark request retry lifetime expired"
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
  public let hasView: Bool
  public let document: JSONValue
  public let facts: JSMap<BookmarkEditFact>
  public let wireDocument: JSONValue
  public let wireBaselineKeys: [String]

  public init(binding: BookmarkWriterBinding, revision: UInt64, ready: Bool, hasView: Bool, document: JSONValue, facts: JSMap<BookmarkEditFact>, wireDocument: JSONValue? = nil, wireBaselineKeys: [String] = []) {
    self.binding = binding
    self.revision = revision
    self.ready = ready
    self.hasView = hasView
    self.document = document
    self.facts = facts
    self.wireDocument = wireDocument ?? document
    self.wireBaselineKeys = wireBaselineKeys
  }
}

public struct BookmarkOwnershipState: Equatable, Sendable {
  public enum Phase: String, Sendable {
    case legacy
    case starting
    case owned
    case readOnlyUnavailable = "read-only-unavailable"
    case stopped
  }
  public let phase: Phase
  public let reason: String?
}

public final class NativeBookmarkOwner: @unchecked Sendable {
  private struct Selection {
    var owner: NativeBookmarkOwner?
    var previousCoordinator: BookmarkCoordinator?
    var selected = false
    var managed = false
    var assignmentGeneration: UInt64 = 0
    var quitting = false
    var quitGeneration: UInt64 = 0
    var state = BookmarkOwnershipState(phase: .legacy, reason: nil)
    var listeners: [UUID: AsyncStream<BookmarkOwnershipState>.Continuation] = [:]

    mutating func publish(_ phase: BookmarkOwnershipState.Phase, reason: String? = nil) {
      state = BookmarkOwnershipState(phase: phase, reason: reason)
      for listener in listeners.values { listener.yield(state) }
    }
  }

  private static let slot = Mutex(Selection())
  private static let installationLock = NSLock()
  public static var bookmarksSelected: Bool { slot.withLock { $0.selected } }
  public static let projectionChanged = Notification.Name("SolaraBookmarkProjectionChanged")

  static func invalidateProjection() {
    DispatchQueue.main.async { NotificationCenter.default.post(name: projectionChanged, object: nil) }
  }

  public static var current: NativeBookmarkOwner? {
    get { slot.withLock { $0.owner } }
    set {
      let assignment = slot.withLock { selection -> (UInt64, NativeBookmarkOwner?, BookmarkCoordinator?)? in
        if let newValue, selection.owner === newValue { return nil }
        selection.assignmentGeneration &+= 1
        let previous = selection.owner
        if selection.managed, previous != nil, newValue != nil {
          selection.publish(.readOnlyUnavailable, reason: "The native bookmark owner was replaced. Editing and sync are paused.")
        }
        if let previous { selection.previousCoordinator = previous.coordinator }
        selection.owner = nil
        if newValue != nil { selection.selected = true }
        if newValue == nil && selection.selected && selection.state.phase != .readOnlyUnavailable { selection.publish(.stopped) }
        return (selection.assignmentGeneration, previous, selection.previousCoordinator)
      }
      guard let assignment else { return }
      assignment.1?.revokeAdmissions()
      guard let newValue else { invalidateProjection(); return }
      installationLock.lock()
      defer { installationLock.unlock() }
      guard slot.withLock({ $0.assignmentGeneration == assignment.0 }) else { newValue.revokeAdmissions(); return }
      assignment.2?.settleJournalForOwnerReplacement()
      newValue.acquirePreparedJournal()
      let installed = slot.withLock { selection in
        guard selection.assignmentGeneration == assignment.0 else { return false }
        if selection.quitting { newValue.coordinator.beginJournalQuit { _ in } }
        selection.owner = newValue
        if !selection.managed { selection.publish(.owned) }
        return true
      }
      if !installed { newValue.revokeAdmissions() }
      invalidateProjection()
    }
  }

  public static func flushJournalForQuit() async throws {
    let initial = slot.withLock { selection in
      if !selection.quitting { selection.quitGeneration &+= 1 }
      selection.quitting = true
      let coordinators = [selection.owner?.coordinator, selection.previousCoordinator].compactMap { $0 }
      return (selection.quitGeneration, beginQuitBarriers(coordinators), Set(coordinators.map(ObjectIdentifier.init)))
    }
    for barrier in initial.1 { try await barrier.wait() }
    await Task.detached { settleInstallations() }.value
    let installed = slot.withLock { selection -> [BookmarkJournalBarrier] in
      guard selection.quitting, selection.quitGeneration == initial.0 else { return [] }
      let coordinators = [selection.owner?.coordinator, selection.previousCoordinator].compactMap { $0 }.filter { !initial.2.contains(ObjectIdentifier($0)) }
      return beginQuitBarriers(coordinators)
    }
    for barrier in installed { try await barrier.wait() }
  }

  private static func beginQuitBarriers(_ coordinators: [BookmarkCoordinator]) -> [BookmarkJournalBarrier] {
    var seen = Set<ObjectIdentifier>()
    return coordinators.filter { seen.insert(ObjectIdentifier($0)).inserted }.map { coordinator in
      let barrier = BookmarkJournalBarrier()
      coordinator.beginJournalQuit { barrier.complete($0) }
      return barrier
    }
  }

  private static func settleInstallations() { installationLock.lock(); installationLock.unlock() }

  public static func cancelJournalQuit() {
    slot.withLock { selection in
      selection.quitting = false
      selection.quitGeneration &+= 1
      let coordinators = [selection.owner?.coordinator, selection.previousCoordinator].compactMap { $0 }
      for coordinator in coordinators { coordinator.cancelJournalQuit() }
    }
  }

  public static var ownershipState: BookmarkOwnershipState { slot.withLock { $0.state } }

  public static var writableCurrent: NativeBookmarkOwner? {
    slot.withLock { $0.state.phase == .owned && !$0.quitting ? $0.owner : nil }
  }

  public static var displayCurrent: NativeBookmarkOwner? {
    slot.withLock { selection in
      switch selection.state.phase {
      case .owned, .readOnlyUnavailable: selection.owner
      default: nil
      }
    }
  }

  public static func ownershipStates() -> AsyncStream<BookmarkOwnershipState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<BookmarkOwnershipState>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation.onTermination = { _ in _ = slot.withLock { $0.listeners.removeValue(forKey: id) } }
    slot.withLock { selection in
      selection.listeners[id] = continuation
      continuation.yield(selection.state)
    }
    return stream
  }

  @discardableResult public static func selectOwnership() -> Bool {
    slot.withLock { selection in
      guard !selection.selected else { return false }
      selection.selected = true
      selection.managed = true
      selection.publish(.starting)
      return true
    }
  }

  public static func failOwnership(reason: String) {
    slot.withLock { selection in
      guard selection.selected, selection.state.phase != .stopped else { return }
      selection.publish(.readOnlyUnavailable, reason: reason)
    }
  }

  @MainActor @discardableResult public static func completeOwnership(_ owner: NativeBookmarkOwner, readOnly: Bool = false) -> Bool {
    guard let catalog = owner.runtime?.catalog, owner.installationIsUsable(catalog: catalog) else { return false }
    return slot.withLock { selection in
      guard selection.owner === owner, selection.state.phase == .starting else { return false }
      if readOnly || owner.coordinator.bookmarkWritesPaused {
        selection.publish(.readOnlyUnavailable, reason: owner.coordinator.recoveryNotice?.message ?? "Bookmark edits and sync are paused.")
      } else {
        selection.publish(.owned)
      }
      return true
    }
  }

  private static func ownerStopped(_ owner: NativeBookmarkOwner) {
    slot.withLock { selection in
      guard selection.owner === owner, selection.state.phase == .owned || selection.state.phase == .starting || selection.state.phase == .readOnlyUnavailable else { return }
      selection.publish(.stopped)
    }
  }

  public static func retireBookmarksForCleanup(engine: String) throws {
    let selection = slot.withLock { ($0.state.phase == .owned ? $0.owner : nil, $0.selected) }
    if let owner = selection.0 { try owner.enqueueRetirement(engine: engine) }
    else if selection.1 { throw BookmarkCoordinatorError.ownershipUnavailable }
  }

  @MainActor public static func settleBookmarkEngine(engine: String) async throws {
    let selection = slot.withLock { ($0.owner, $0.selected) }
    if let owner = selection.0 { try await owner.settleRetiredBookmarks(engine: engine) }
    else if selection.1 { throw BookmarkCoordinatorError.ownershipUnavailable }
    else { try await settle(queue: BookmarkEngineQueue.shared, engine: engine) }
  }

  private static let bindingSequence = Mutex<UInt64>(0)

  private static func nextBinding() -> UInt64 {
    bindingSequence.withLock { value in value += 1; return value }
  }

  private struct Route {
    let owner: UInt64
    let generation: UInt64
  }

  private let readOnly: Bool
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

  private init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], launchInput: BookmarkLaunchInput = .init(), stampsEnabled: Bool = false, canonicalURL: @escaping @Sendable (String) throws -> String = { $0 }) {
    readOnly = store.readOnly
    mapping = BookmarkProfileMap(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles)
    coordinator = BookmarkCoordinator(profiles: profiles, defaultProfile: defaultProfile, owningProfiles: owningProfiles, stampsEnabled: stampsEnabled, pendingStore: store, launchInput: launchInput, canonicalURL: canonicalURL)
    updateRoutes(mapping)
  }

  #if DEBUG
    public convenience init(store: BookmarkPendingStore, profiles: JSMap<String>, defaultProfile: String, launchInput: BookmarkLaunchInput = .init(), canonicalURL: @escaping @Sendable (String) throws -> String = { $0 }, wake: @escaping @Sendable (String) -> Void) {
      self.init(store: store, profiles: profiles, defaultProfile: defaultProfile, launchInput: launchInput, canonicalURL: canonicalURL)
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
      Self.invalidateProjection()
      _ = installMapping(ticket)
    }
  #endif

  public func binding(profile: String) throws -> BookmarkWriterBinding {
    fence.lock()
    defer { fence.unlock() }
    let engine = try mappedEngine(profile)
    guard let route = routes[regularProfile(profile)] else { throw BookmarkWriterError.unknownProfile }
    return BookmarkWriterBinding(engine: engine, generation: route.generation)
  }

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
      if unchanged { return BookmarkWriterSnapshot(binding: binding, revision: snapshot.revision, ready: ready, hasView: snapshot.hasView, document: snapshot.document, facts: snapshot.facts, wireDocument: snapshot.wireDocument, wireBaselineKeys: snapshot.wireBaselineKeys) }
    }
    throw BookmarkWriterError.staleBinding
  }

  public func projection() throws -> JSONValue {
    for _ in 0..<8 {
      fence.lock()
      guard accepting else { fence.unlock(); throw BookmarkWriterError.notOwned }
      let incarnation = ownerIncarnation
      let generation = lifecycleGeneration
      let installed = installedGeneration == generation
      let currentMapping = mapping
      let currentRoutes = routes
      let retired = retiredEngines
      fence.unlock()
      var profiles: JSONObject = [:]
      var views: JSONObject = [:]
      for (profile, engine) in currentMapping.profiles where !retired.contains(JSKey(engine)) {
        guard let route = currentRoutes[profile] else { continue }
        profiles[profile] = .object(["engine": .string(engine), "generation": .string(String(route.generation))])
        guard views[engine] == nil else { continue }
        let view = coordinator.desiredView(engine: engine)
        var document = view.document.object ?? [:]
        var roots: JSONObject = [:]
        if view.hasView {
          let ids = BookmarkFlat.roots(engine)
          for (alias, mapped) in currentMapping.profiles where JSKey(mapped) == JSKey(engine) {
            roots[alias] = .object(["bar": .string(ids.bar), "other": .string(ids.other)])
          }
        }
        document["roots"] = .object(roots)
        views[engine] = .object([
          "revision": .string(String(view.revision)), "hasView": .bool(view.hasView),
          "readyForSync": .bool(view.readyForSync && installed), "document": .object(document)
        ])
      }
      fence.lock()
      let valid = accepting && ownerIncarnation == incarnation && lifecycleGeneration == generation && mapping == currentMapping && retiredEngines == retired
      fence.unlock()
      if valid {
        return .object(["owner": .string(String(incarnation)), "generation": .string(String(generation)), "profiles": .object(profiles), "views": .object(views)])
      }
    }
    throw BookmarkWriterError.staleBinding
  }

  public static func projectionDelta(_ next: JSONValue, previous: JSONValue?) -> JSONValue {
    guard let previous, previous["owner"] == next["owner"], previous["generation"] == next["generation"] else {
      return .object(["full": .bool(true), "projection": next])
    }
    var result = next.object ?? [:]
    var views: JSONObject = [:]
    for (engine, view) in next["views"]?.object ?? [:] {
      guard let before = previous["views"]?[engine] else {
        views[engine] = view
        continue
      }
      var delta = view.object ?? [:]
      if view["revision"] == before["revision"], view["hasView"] == before["hasView"] {
        delta.removeValue(forKey: "document")
      } else {
        let oldNodes = before["document"]?["nodes"]?.object ?? [:]
        let newNodes = view["document"]?["nodes"]?.object ?? [:]
        var nodes: JSONObject = [:]
        for (id, node) in newNodes where oldNodes[id] != node { nodes[id] = node }
        let removed = oldNodes.keys.filter { newNodes[$0] == nil }
        delta["document"] = .object(["nodes": .object(nodes), "removed": JSONValue(removed), "roots": view["document"]?["roots"] ?? .object([:])])
      }
      views[engine] = .object(delta)
    }
    result["views"] = .object(views)
    return .object(["full": .bool(false), "projection": .object(result)])
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
    if !readOnly { pendingRetirements.formUnion(pendingDeletion.subtracting(nextEngines)) }
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
    Self.invalidateProjection()
    coordinator.fencePumpAdmissions()
    Task { @MainActor [weak self] in self?.finishRevocation() }
  }

  @MainActor private func finishRevocation() {
    (runtime ?? startingRuntime)?.stop()
    runtime = nil
    startingRuntime = nil
    bind(token: nil)
  }

  private let retirementTasks = Mutex<JSMap<Task<Void, Error>>>([:])

  private func prepareRetirement(engine: String) throws -> UInt64 {
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
    Self.invalidateProjection()
    coordinator.fencePumpAdmissions()
    return ticket
  }

  private func finishRetirement(engine: String, ticket: UInt64) throws {
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

  public func retireBookmarks(engine: String) throws {
    try finishRetirement(engine: engine, ticket: prepareRetirement(engine: engine))
  }

  private func enqueueRetirement(engine: String) throws {
    let ticket = try prepareRetirement(engine: engine)
    retirementTasks.withLock { tasks in
      tasks[engine] = Task {
        try await self.coordinator.offMain { try self.finishRetirement(engine: engine, ticket: ticket) }
      }
    }
  }

  @MainActor public func settleRetiredBookmarks(engine: String) async throws {
    if let retirement = retirementTasks.withLock({ $0[engine] }) { try await retirement.value }
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

  private func journalWrite<T: Sendable>(profile: String, binding: BookmarkWriterBinding, _ operation: @escaping @Sendable (BookmarkCoordinator) throws -> T) async throws -> T {
    try validate(profile: profile, binding: binding)
    do {
      return try await coordinator.performJournalWrite { staged in
        try self.validate(profile: profile, binding: binding)
        return try operation(staged)
      }
    } catch let error as BookmarkWriterError { throw error }
    catch let error as BookmarkCoordinatorError {
      if case .expiredRequest = error { throw BookmarkWriterError.expired }
      if case .conditionFailed = error { throw BookmarkWriterError.conditionFailed(String(describing: error)) }
      throw BookmarkWriterError.refused(String(describing: error))
    } catch { throw BookmarkWriterError.refused(String(describing: error)) }
  }

  public func submitAsync(profile: String, mutations: [BookmarkMutation], binding: BookmarkWriterBinding, requestID: String? = nil) async throws -> BookmarkReceipt {
    let receipt = try await journalWrite(profile: profile, binding: binding) { staged in
      try staged.submit(profile: profile, mutations: mutations, requestID: requestID, expectedEngine: binding.engine, admission: { try self.validate(profile: profile, binding: binding) })
    }
    dispatchWake(binding)
    return receipt
  }

  public func replaceAsync(profile: String, document: JSONValue, expectedRevision: UInt64, binding: BookmarkWriterBinding, requestID: String? = nil, records: [(key: String, hlc: String)] = [], expectedLink: String? = nil) async throws -> UInt64 {
    let receipt = try await journalWrite(profile: profile, binding: binding) { staged in
      try staged.replaceDocument(engine: binding.engine, profile: profile, document: document, expectedRevision: expectedRevision, requestID: requestID, expectedEngine: binding.engine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profile, binding: binding) })
    }
    dispatchWake(binding)
    return receipt.view.revision
  }

  public func ackBookmarkFactsAsync(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64, mintedHLC: String)], expectedLink: String? = nil, generation: UInt64) async throws -> Bool {
    let binding = BookmarkWriterBinding(engine: expectedEngine, generation: generation)
    return try await journalWrite(profile: profileId, binding: binding) { staged in
      try staged.ackBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profileId, binding: binding) })
    }
  }

  public func observeRemoteRecordsAsync(profileId: String, expectedEngine: String, records: [(key: String, hlc: String)], expectedLink: String? = nil, generation: UInt64) async throws -> Bool {
    let binding = BookmarkWriterBinding(engine: expectedEngine, generation: generation)
    return try await journalWrite(profile: profileId, binding: binding) { staged in
      try staged.observeRemoteRecords(profileId: profileId, expectedEngine: expectedEngine, records: records, expectedLink: expectedLink, admission: { try self.validate(profile: profileId, binding: binding) })
    }
  }

  public func clearBookmarkFactsAsync(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64)], generation: UInt64) async throws -> Bool {
    let binding = BookmarkWriterBinding(engine: expectedEngine, generation: generation)
    return try await journalWrite(profile: profileId, binding: binding) { staged in
      try staged.clearBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, records: records, admission: { try self.validate(profile: profileId, binding: binding) })
    }
  }

  public func setBookmarkSyncLinksAsync(_ links: JSMap<String>) async throws -> Bool {
    let incarnation = fence.withLock { ownerIncarnation }
    return try await coordinator.performJournalWrite { staged in
      staged.setBookmarkSyncLinks(links, admission: {
        try self.fence.withLock {
          guard self.accepting, !self.prepared, self.ownerIncarnation == incarnation else { throw BookmarkWriterError.staleBinding }
        }
      })
    }
  }

  public static func setCurrent(_ owner: NativeBookmarkOwner?) async {
    await Task.detached { Self.current = owner }.value
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
      if case .expiredRequest = error { throw BookmarkWriterError.expired }
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
      if case .expiredRequest = error { throw BookmarkWriterError.expired }
      if case .conditionFailed = error { throw BookmarkWriterError.conditionFailed(String(describing: error)) }
      throw BookmarkWriterError.refused(String(describing: error))
    } catch {
      throw BookmarkWriterError.refused(String(describing: error))
    }
    dispatchWake(binding)
    return receipt
  }

  @discardableResult
  public func acknowledgeReceipt(profile: String, requestID: String, binding: BookmarkWriterBinding) throws -> Bool {
    try validate(profile: profile, binding: binding)
    return try coordinator.acknowledgeReceipt(requestID: requestID, engine: binding.engine, admission: { try self.validate(profile: profile, binding: binding) })
  }

  public static func prepare(directory: URL, state: BrowserState, cacheDirectory: URL? = nil, readOnly: Bool = false, stampsEnabled: Bool = false, canonicalURL: @escaping @Sendable (String) throws -> String = { $0 }) async -> NativeBookmarkOwner {
    await prepare(directory: directory, state: state, cacheDirectory: cacheDirectory, readOnly: readOnly, stampsEnabled: stampsEnabled, canonicalURL: canonicalURL, afterLoad: {})
  }

  #if DEBUG
    static func prepareForTesting(directory: URL, state: BrowserState, afterLoad: @escaping @Sendable () async -> Void) async -> NativeBookmarkOwner {
      await prepare(directory: directory, state: state, cacheDirectory: nil, readOnly: false, stampsEnabled: false, afterLoad: afterLoad)
    }
  #endif

  private static func prepare(directory: URL, state: BrowserState, cacheDirectory: URL?, readOnly: Bool, stampsEnabled: Bool, canonicalURL: @escaping @Sendable (String) throws -> String = { $0 }, afterLoad: @escaping @Sendable () async -> Void) async -> NativeBookmarkOwner {
    await Task.detached {
      let store = BookmarkPendingStore(directory: directory, defersRecovery: true, readOnly: readOnly)
      let map = BookmarkProfileMap(state: state, previousOwners: BookmarkDurability(store: store).owners)
      let launch = cacheDirectory.map { BookmarkLaunchCache(directory: $0).load(profiles: map.profiles, defaultProfile: map.defaultProfile) } ?? BookmarkLaunchInput()
      let owner = NativeBookmarkOwner(store: store, profiles: map.profiles, defaultProfile: map.defaultProfile, owningProfiles: map.owningProfiles, launchInput: launch, stampsEnabled: stampsEnabled, canonicalURL: canonicalURL)
      owner.prepared = true
      owner.accepting = false
      owner.installedGeneration = nil
      owner.stageMapping(map, pendingDeletion: readOnly ? [] : Set(state.orphanedProfileData.map(JSKey.init)))
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
    let pendingDeletion: Set<JSKey> = readOnly ? [] : Set(state?.orphanedProfileData.map(JSKey.init) ?? [])
    let unreferencedDeletion = pendingDeletion.subtracting(Set(next.profiles.values.map(JSKey.init)))
    guard force || next != mapping || !unreferencedDeletion.isSubset(of: retiredEngines) else { return nil }
    stageMapping(next, pendingDeletion: pendingDeletion)
    lifecycleGeneration += 1
    Self.invalidateProjection()
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
    Self.invalidateProjection()
  }

  fileprivate func installMapping(_ ticket: UInt64) -> Bool {
    let displayOnly = readOnly || coordinator.bookmarkWritesPaused
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
      if !displayOnly {
        for engine in retirements { try coordinator.retire(engine: engine.text, admission: admission) }
      }
      for engine in permittedReactivations {
        if displayOnly { try coordinator.reactivateForDisplay(engine: engine.text, admission: admission) }
        else { try coordinator.reactivate(engine: engine.text, admission: admission) }
      }
    } catch { return false }
    guard coordinator.remap(profiles: mapping.profiles, defaultProfile: mapping.defaultProfile, owningProfiles: mapping.owningProfiles, admission: admission) else { return false }
    fence.lock()
    defer { fence.unlock() }
    guard accepting, lifecycleGeneration == ticket else { return false }
    pendingRetirements.subtract(retirements)
    pendingReactivations.subtract(reactivations)
    retiredEngines.subtract(permittedReactivations)
    installedGeneration = ticket
    Self.invalidateProjection()
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

  @MainActor public func start(catalog: LibraryCatalog, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler, engineAdmission: @escaping @MainActor (String) -> Bool = { _ in true }, requestEngine: @escaping @MainActor (String) -> Void = { _ in }) async throws {
    if prepared { await Self.setCurrent(self) }
    guard isCurrent(currentGeneration), runtime == nil, startingRuntime == nil else { throw BookmarkCoordinatorError.ownershipUnavailable }
    let runtime = NativeBookmarkRuntime(owner: self, catalog: catalog, client: client, clock: clock, scheduler: scheduler, engineAdmission: engineAdmission, requestEngine: requestEngine)
    startingRuntime = runtime
    if let ticket = stage() { await runtime.replacePump(ticket) }
  }

  @MainActor public func engineDidLoad(engine: String) {
    runtime?.pump?.requestRead(engine: engine)
    runtime?.pump?.requestPush(engine: engine)
  }

  @MainActor public func remap(state: BrowserState) async throws {
    guard let runtime = runtime ?? startingRuntime else { throw BookmarkCoordinatorError.ownershipUnavailable }
    if let ticket = stage(state: state) { await runtime.replacePump(ticket) }
  }

  @MainActor public func subscribeToStoreCommits() {
    (runtime ?? startingRuntime)?.subscribeToStoreCommits()
  }

  @MainActor public var hasInstalledCatalog: Bool {
    guard let catalog = runtime?.catalog else { return false }
    return installationIsUsable(catalog: catalog)
  }

  @MainActor public func installationIsUsable(catalog: LibraryCatalog) -> Bool {
    guard let runtime, runtime.catalog === catalog, let pump = runtime.pump,
      catalog.bookmarkClaim?.coordinator === coordinator, catalog.bookmarkClaim?.epoch == pump.epoch else { return false }
    fence.lock()
    defer { fence.unlock() }
    return accepting && installedGeneration == lifecycleGeneration
  }

  @MainActor public func settleStoreSubscription() async {
    guard let active = runtime ?? startingRuntime else { return }
    while true {
      let version = active.pendingVersion
      await active.pending?.value
      if version == active.pendingVersion { return }
    }
  }

  @MainActor public func stop(preservingUnavailable: Bool = false) {
    if !(preservingUnavailable && Self.ownershipState.phase == .readOnlyUnavailable) { Self.ownerStopped(self) }
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
  let engineAdmission: @MainActor (String) -> Bool
  let requestEngine: @MainActor (String) -> Void
  var pump: BookmarkPump?
  var pending: Task<Void, Never>?
  var pendingVersion: UInt64 = 0
  private var lifecycle: Int?
  private var store: Store?
  private var hasBoundStore = false
  private var subscription: Int?
  private var retryTicket: UInt64?
  private var retryFailures = 0
  private var cancelRetry: (@MainActor () -> Void)?

  init(owner: NativeBookmarkOwner, catalog: LibraryCatalog, client: BookmarkEngineClient, clock: BookmarkPumpClock, scheduler: BookmarkPumpScheduler, engineAdmission: @escaping @MainActor (String) -> Bool, requestEngine: @escaping @MainActor (String) -> Void) {
    self.owner = owner
    self.catalog = catalog
    self.client = client
    self.clock = clock
    self.scheduler = scheduler
    self.engineAdmission = engineAdmission
    self.requestEngine = requestEngine
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
      let epoch = try await coordinator.offMain {
        try coordinator.claimPump(admission: {
          guard owner.isCurrent(ticket) else { throw BookmarkCoordinatorError.staleRevision }
        })
      }
      let next = BookmarkPump(coordinator: coordinator, client: client, clock: clock, scheduler: scheduler, epoch: epoch, engineAdmission: engineAdmission, requestEngine: requestEngine)
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
      if coordinator.bookmarkWritesPaused, owner.isCurrent(ticket), owner.installationIsUsable(catalog: catalog) {
        for engine in coordinator.catalogEngines { catalog.publishDesired(coordinator.desiredView(engine: engine)) }
      }
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
    pendingVersion += 1
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
