import Foundation
import SolaraModel

public struct BookmarkMutation: Equatable, Sendable {
  public var method: String
  public var args: [JSONValue]
  public init(method: String, args: [JSONValue]) { self.method = method; self.args = args }
}

public enum BookmarkCoordinatorError: Error, Equatable {
  case conflictingRequest
  case staleRevision
  case invalidProfileScope
  case unknownMutation(String)
  case ownershipUnavailable
  case invalidOperation(String)
  case conditionFailed(String)
}

public struct BookmarkEditFact: Equatable, Sendable {
  public let at: Double
  public let seq: UInt64
  public let after: String?
  public let link: String
  public init(at: Double, seq: UInt64, after: String?, link: String) { self.at = at; self.seq = seq; self.after = after; self.link = link }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.at == rhs.at && lhs.seq == rhs.seq && lhs.after.map(JSKey.init) == rhs.after.map(JSKey.init) && JSKey(lhs.link) == JSKey(rhs.link)
  }
}

public struct BookmarkDesiredView: Equatable, Sendable {
  public var engine: String
  public var document: JSONValue
  public var revision: UInt64 = 0
  public var hasView = false
  public var readyForSync = false
  public var structuralBreak: Int?
  public var failedPushes = 0
  public var retryNotBeforeMs: Double?
  public var requiresRead = false
  public var inFlightTarget: JSONValue?
  public var facts: JSMap<BookmarkEditFact> = [:]
  public var lastSeen: JSMap<String> = [:]
  public static func == (lhs: Self, rhs: Self) -> Bool {
    JSKey(lhs.engine) == JSKey(rhs.engine) && lhs.document == rhs.document && lhs.revision == rhs.revision && lhs.hasView == rhs.hasView && lhs.readyForSync == rhs.readyForSync && lhs.structuralBreak == rhs.structuralBreak && lhs.failedPushes == rhs.failedPushes && lhs.retryNotBeforeMs == rhs.retryNotBeforeMs && lhs.requiresRead == rhs.requiresRead && lhs.inFlightTarget == rhs.inFlightTarget && lhs.facts == rhs.facts && lhs.lastSeen.mapValues(JSKey.init) == rhs.lastSeen.mapValues(JSKey.init)
  }
}

public struct BookmarkMembershipSnapshot: Equatable, Sendable {
  public let engine: String
  public let revision: UInt64
  public let hasView: Bool
  public let readyForSync: Bool
  public let nodeIDsByURL: JSMap<[String]>
  public var urls: Set<JSKey> { Set(nodeIDsByURL.keys.filter { !$0.isEmpty }.map(JSKey.init)) }
  public func contains(_ url: String) -> Bool { !url.isEmpty && nodeIDsByURL[url] != nil }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    JSKey(lhs.engine) == JSKey(rhs.engine) && lhs.revision == rhs.revision && lhs.hasView == rhs.hasView && lhs.readyForSync == rhs.readyForSync && lhs.nodeIDsByURL.mapValues(JSONValue.init) == rhs.nodeIDsByURL.mapValues(JSONValue.init)
  }
}

public struct BookmarkReceipt: Equatable, Sendable {
  public let view: BookmarkDesiredView
  public let results: [JSONValue]
}

public final class BookmarkCoordinator: @unchecked Sendable {
  let engineQueue = BookmarkEngineQueue.shared
  private let journalQueue = DispatchQueue(label: "app.solara.bookmarks.journal")

  func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in journalQueue.async { continuation.resume(returning: body()) } }
  }
  func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in journalQueue.async { continuation.resume(with: Result { try body() }) } }
  }
  private var pumpEpoch: UInt64 = 0
  private var ownerGeneration: UInt64 = 1
  private var catalogClaimEpoch: UInt64?
  private let lock = NSRecursiveLock()
  private let writerLock = NSLock()
  private var profiles: JSMap<String>
  private var defaultProfile: String
  private var owningProfiles: JSMap<String>
  private let makeID: () -> String
  private let now: () -> Double
  private let stampsEnabled: Bool
  private let legacySource: BookmarkLegacyMigration?
  private let launchLegacyProfiles: JSMap<String>
  private var lastOwningProfiles: JSMap<String> = [:]
  private var views: JSMap<BookmarkDesiredView> = [:]
  private var bases: JSMap<BookmarkFlat> = [:]
  private struct PendingChromeDelta {
    let desiredVersion: UInt64
    let baseVersion: UInt64
    let operations: [JSONValue]
  }
  private var desiredVersions: JSMap<UInt64> = [:]
  private var baseVersions: JSMap<UInt64> = [:]
  private var blockedEngines = Set<JSKey>()
  private var pendingChromeDeltas: JSMap<PendingChromeDelta> = [:]
  #if DEBUG
    private var pendingDiffCount = 0
    var pendingDiffCountForTesting: Int { locked { pendingDiffCount } }
  #endif
  private let launchLegacyPendingEngines: Set<JSKey>
  private var durability: BookmarkDurability
  private var streams: [UUID: (JSKey, BookmarkMembershipObserver)] = [:]
  private var viewStreams: [UUID: (JSKey, BookmarkViewObserver)] = [:]

  public init(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], makeID: @escaping () -> String = { UUID().uuidString.lowercased() }, now: @escaping () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }, stampsEnabled: Bool = false, pendingStore: BookmarkPendingStore? = nil, launchInput: BookmarkLaunchInput = .init()) {
    self.profiles = profiles
    self.defaultProfile = defaultProfile
    self.owningProfiles = owningProfiles
    self.makeID = makeID
    self.now = now
    self.stampsEnabled = stampsEnabled
    launchLegacyPendingEngines = launchInput.legacyPendingEngines
    durability = BookmarkDurability(store: pendingStore)
    legacySource = launchInput.legacyMigration ?? BookmarkLegacyMigration.recover(directory: launchInput.directory, sourceID: durability.legacyMigration?.source)
    launchLegacyProfiles = profiles
    reconcileLegacyLaunch()
    for (engine, document) in launchInput.documents where durability.terminalEngines[engine] == nil && durability.legacyMigration?.engines[engine]?.stage != "discarded" {
      views[engine] = BookmarkDesiredView(engine: engine, document: document, hasView: true)
      bases[engine] = BookmarkFlat(document: document, engine: engine)
    }
    for (engine, restored) in durability.restoredViews {
      views[engine] = restored
      bases[engine] = durability.restoredBases[engine]
    }
    lastOwningProfiles = durability.owners
  }

  private func reconcileLegacyLaunch() {
    if durability.legacyMigration == nil, let legacySource {
      var progress = BookmarkLegacyProgress(source: legacySource.sourceID, engines: launchLegacyPendingEngines.map(\.text), profiles: launchLegacyProfiles)
      for (engine, reason) in durability.terminalEngines where reason == "retired" {
        progress.engines[engine] = BookmarkLegacyEngineProgress(stage: "discarded", ids: [], target: nil)
      }
      durability.legacyMigration = progress
    }
    let changed = legacySource.map { source in durability.legacyMigration.map { $0.source != source.sourceID } ?? false } ?? false
    durability.legacyPendingEngines.formUnion(launchLegacyPendingEngines.filter { engine in
      let stage = durability.legacyMigration?.engines[engine.text]?.stage
      return durability.terminalEngines[engine.text] == nil && (changed || (stage != "confirmed" && stage != "discarded"))
    })
    if changed {
      durability.notice = BookmarkRecoveryNotice(kind: .legacyMigration, message: "The legacy bookmark source changed after migration started. Its data is preserved and bookmark sync is paused.", preservedPath: legacySource?.sourceURL.path)
    }
  }

  public var bookmarkWritesPaused: Bool { locked { !durability.writable } }
  public func bookmarkEditsPaused(engine: String) -> Bool {
    locked { !durability.writable || durability.legacyMigration?.engines[engine]?.stage == "blocked" }
  }

  public var recoveryNotice: BookmarkRecoveryNotice? {
    locked {
      if let notice = durability.notice { return notice }
      if durability.store?.readOnly == true {
        return BookmarkRecoveryNotice(kind: .safeMode, message: "Bookmarks are read-only in Safe Mode. You can open bookmarks; edits and sync are paused.")
      }
      if !durability.legacyPendingEngines.isEmpty {
        return BookmarkRecoveryNotice(kind: .legacyMigration, message: "Bookmarks are being recovered. Sync is paused until every bookmark library is confirmed.", preservedPath: legacySource?.sourceURL.path)
      }
      return nil
    }
  }
  public func dismissRecoveryNotice() { locked { if durability.writable { durability.notice = nil } } }
  public var recoveryConflicts: [JSONValue] { locked { durability.conflicts } }

  private func owners(for views: JSMap<BookmarkDesiredView>) -> JSMap<String> {
    views.mapValues { ownerProfile($0.engine) }
  }

  private func checkpoint(views: JSMap<BookmarkDesiredView>, bases: JSMap<BookmarkFlat>, factSequence: UInt64? = nil, syncLinks: JSMap<String>? = nil, requestID: String? = nil, payload: JSONValue = .null, receipt: BookmarkReceipt? = nil, conflicts: [JSONValue]? = nil) -> BookmarkCheckpointInput {
    BookmarkCheckpointInput(views: views, bases: bases, owners: owners(for: views), requestID: requestID, payload: payload, receipt: receipt, conflicts: conflicts, factSequence: factSequence ?? durability.factSequence, syncLinks: syncLinks ?? durability.syncLinks)
  }

  private func writing<T>(_ body: () throws -> T) rethrows -> T {
    writerLock.lock()
    defer { writerLock.unlock() }
    return try body()
  }

  private func transact<T>(admission: (() throws -> Void)? = nil, _ prepare: () throws -> (BookmarkCheckpointInput?, () -> T)) throws -> T {
    try writing {
      try admission?()
      let (input, install) = try locked(prepare)
      let checkpoint = try input.map { try durability.prepare($0) }
      do {
        if let checkpoint { try durability.store?.write(checkpoint.payload) }
      } catch {
        let publications = locked {
          durability.recordWriteFailure(error)
          for engine in views.keys {
            if !durability.writable, views[engine]?.readyForSync == true {
              views[engine]?.readyForSync = false
              views[engine]?.revision += 1
            }
          }
          return views.keys.map { notifications($0) }
        }
        for publication in publications { deliver(publication) }
        throw error
      }
      return locked {
        if let checkpoint { durability.install(checkpoint) }
        return install()
      }
    }
  }

  deinit {
    for stream in streams.values { stream.1.finish() }
    for stream in viewStreams.values { stream.1.finish() }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  public func engine(profile: String, originalProfile: String? = nil) -> String {
    locked {
      var regular = originalProfile ?? profile
      if regular.hasPrefix("incognito:") {
        regular = regular.firstIndex(of: "@").map { String(regular[regular.index(after: $0)...]) } ?? "default"
      }
      return profiles[regular] ?? profiles[defaultProfile] ?? ""
    }
  }

  private func validateBinding(profile: String, expectedEngine: String) throws {
    let regular = Ids.isIncognitoProfile(profile) ? Ids.incognitoOriginal(profile) : profile
    guard !blockedEngines.contains(JSKey(expectedEngine)), durability.terminalEngines[expectedEngine] == nil, let mapped = profiles[regular], BookmarkReconcile.same(mapped, expectedEngine) else { throw BookmarkWriterError.staleBinding }
  }

  @discardableResult
  public func remap(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String>? = nil, admission: (() throws -> Void)? = nil) -> Bool {
    do {
      return try transact(admission: admission) {
        var previous = lastOwningProfiles
        for engine in views.keys { previous[engine] = ownerProfile(engine) }
        let nextOwning = owningProfiles ?? self.owningProfiles
        let nextOwners = views.mapValues { ownerProfile($0.engine, profiles: profiles, owningProfiles: nextOwning, previous: previous) }
        let checkpoint = durability.writable ? BookmarkCheckpointInput(views: views, bases: bases, owners: nextOwners, requestID: nil, payload: .null, receipt: nil, conflicts: nil, factSequence: durability.factSequence, syncLinks: durability.syncLinks) : nil
        return (checkpoint, {
          self.profiles = profiles
          self.defaultProfile = defaultProfile
          self.owningProfiles = nextOwning
          self.lastOwningProfiles = previous
          self.ownerGeneration += 1
          self.pumpEpoch += 1
          return true
        })
      }
    } catch { return false }
  }

  var currentOwnerGeneration: UInt64 { locked { ownerGeneration } }

  func writerSnapshot(profile: String) -> BookmarkWriterSnapshot {
    locked { writerSnapshot(engine: engine(profile: profile)) }
  }

  func writerSnapshot(engine: String) -> BookmarkWriterSnapshot {
    locked {
      let view = desiredView(engine: engine)
      return BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: engine, generation: ownerGeneration), revision: view.revision, ready: view.readyForSync, hasView: view.hasView, document: view.document, facts: stampsEnabled ? view.facts : [:])
    }
  }

  func settleJournalForOwnerReplacement() { writing {} }

  func reloadJournalForOwnerReplacement(previous: BookmarkCoordinator? = nil) {
    writing {
      locked {
        guard let store = durability.store else { return }
        store.invalidateLoadedForOwnerReplacement()
        let restored = BookmarkDurability(store: store)
        for engine in durability.restoredViews.keys + restored.terminalEngines.keys {
          views.removeValue(forKey: engine)
          bases.removeValue(forKey: engine)
        }
        for (engine, view) in restored.restoredViews {
          views[engine] = view
          bases[engine] = restored.restoredBases[engine]
        }
        durability = restored
        reconcileLegacyLaunch()
        lastOwningProfiles = restored.owners
        pendingChromeDeltas.removeAll()
        desiredVersions.removeAll()
        baseVersions.removeAll()
        pumpEpoch += 1
        ownerGeneration += 1
      }
    }
  }

  func fencePumpAdmissions() { locked { ownerGeneration += 1; pumpEpoch += 1 } }

  func invalidatePumps() {
    writing { locked { ownerGeneration += 1; pumpEpoch += 1 } }
  }

  private func aliases(_ engine: String) -> [String] { profiles.filter { BookmarkReconcile.same($1, engine) }.keys }
  private func ownerProfile(_ engine: String) -> String {
    ownerProfile(engine, profiles: profiles, owningProfiles: owningProfiles, previous: lastOwningProfiles)
  }

  private func ownerProfile(_ engine: String, profiles: JSMap<String>, owningProfiles: JSMap<String>, previous: JSMap<String>) -> String {
    if engine.hasPrefix("incognito:") || durability.terminalEngines[engine] != nil { return engine.isEmpty ? "default" : engine }
    if let owner = owningProfiles[engine], BookmarkReconcile.same(profiles[owner], engine) { return owner }
    let conventional = engine.isEmpty ? "default" : engine
    if BookmarkReconcile.same(profiles[conventional], engine) { return conventional }
    if let alias = profiles.filter({ BookmarkReconcile.same($1, engine) }).keys.first { return alias }
    if hasPendingEdits(engine), let owner = previous[engine] ?? durability.owners[engine] { return owner }
    return conventional
  }

  #if DEBUG
    func ownerProfileForTesting(engine: String) -> String { locked { ownerProfile(engine) } }
  #endif

  public func desiredView(engine: String) -> BookmarkDesiredView {
    locked { views[engine] ?? BookmarkDesiredView(engine: engine, document: ["nodes": [:], "roots": [:]]) }
  }

  public func desiredView(profile: String) -> BookmarkDesiredView { desiredView(engine: engine(profile: profile)) }

  func seed(engine: String, document: JSONValue, ready: Bool) {
    let notification = writing {
      locked { () -> BookmarkPublication in
        var view = desiredView(engine: engine)
        view.document = document
        view.hasView = true
        view.readyForSync = ready
        view.revision += 1
        views[engine] = view
        bases[engine] = BookmarkFlat(document: document, engine: engine)
        invalidatePending(engine, desired: true, base: true)
        return notifications(engine)
      }
    }
    deliver(notification)
  }

  private func snapshot(_ view: BookmarkDesiredView) -> BookmarkMembershipSnapshot {
    let flat = BookmarkFlat(document: view.document, engine: view.engine)
    var index: JSMap<[String]> = [:]
    for id in flat.order {
      if flat.nodes[id]?["kind"] == "url", let url = flat.nodes[id]?["url"]?.string {
        index[url] = (index[url] ?? []) + [id]
      }
    }
    return BookmarkMembershipSnapshot(engine: view.engine, revision: view.revision, hasView: view.hasView, readyForSync: view.readyForSync, nodeIDsByURL: index)
  }

  public var membershipSnapshot: BookmarkMembershipSnapshot { locked { snapshot(desiredView(engine: engine(profile: defaultProfile))) } }
  public func membershipSnapshot(engine: String) -> BookmarkMembershipSnapshot { locked { snapshot(desiredView(engine: engine)) } }
  public func membership(profile: String, originalProfile: String? = nil, url: String) -> Bool {
    membershipSnapshot(engine: engine(profile: profile, originalProfile: originalProfile)).contains(url)
  }

  public func membershipSnapshots() -> AsyncStream<BookmarkMembershipSnapshot> {
    let selected = locked { engine(profile: defaultProfile) }
    return membershipSnapshots(engine: selected)
  }
  public func membershipSnapshots(engine: String) -> AsyncStream<BookmarkMembershipSnapshot> {
    let pair = AsyncStream<BookmarkMembershipSnapshot>.makeStream()
    let token = UUID()
    let observer = BookmarkMembershipObserver(pair.continuation)
    let initial = locked {
      streams[token] = (JSKey(engine), observer)
      return snapshot(desiredView(engine: engine))
    }
    pair.continuation.onTermination = { [weak self] _ in self?.removeStream(token) }
    observer.yield(initial)
    return pair.stream
  }

  private func removeStream(_ token: UUID) { locked { _ = streams.removeValue(forKey: token) } }
  public func desiredViews(engine: String) -> AsyncStream<BookmarkDesiredView> {
    let pair = AsyncStream<BookmarkDesiredView>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let token = UUID()
    let observer = BookmarkViewObserver(pair.continuation)
    let initial = locked {
      viewStreams[token] = (JSKey(engine), observer)
      return desiredView(engine: engine)
    }
    pair.continuation.onTermination = { [weak self] _ in self?.removeViewStream(token) }
    observer.yield(initial)
    return pair.stream
  }

  private func removeViewStream(_ token: UUID) { locked { _ = viewStreams.removeValue(forKey: token) } }
  private func silentPublication(_ view: BookmarkDesiredView) -> BookmarkPublication {
    BookmarkPublication(membership: snapshot(view), membershipObservers: [], view: view, viewObservers: [])
  }
  private func notifications(_ engine: String) -> BookmarkPublication {
    let view = desiredView(engine: engine)
    return BookmarkPublication(membership: snapshot(view), membershipObservers: streams.values.filter { $0.0 == JSKey(engine) }.map { $0.1 }, view: view, viewObservers: viewStreams.values.filter { $0.0 == JSKey(engine) }.map { $0.1 })
  }
  private func deliver(_ publication: BookmarkPublication) {
    NativeBookmarkOwner.invalidateProjection()
    for stream in publication.membershipObservers { stream.yield(publication.membership) }
    for stream in publication.viewObservers { stream.yield(publication.view) }
  }

  var catalogEngines: [String] {
    locked {
      var seen = Set<JSKey>()
      let mapped = Set(profiles.values.map(JSKey.init))
      return (profiles.values + durability.legacyPendingEngines.map(\.text) + views.keys.filter { !$0.hasPrefix("incognito:") && !blockedEngines.contains(JSKey($0)) && durability.terminalEngines[$0] == nil && !mapped.contains(JSKey($0)) && needsPump($0) }).filter { !$0.hasPrefix("incognito:") && !blockedEngines.contains(JSKey($0)) && durability.terminalEngines[$0] == nil && seen.insert(JSKey($0)).inserted }
    }
  }

  func catalogProfile(engine: String) -> String? { locked { aliases(engine).first } }

  func claimCatalog(epoch: UInt64, replacing previousEpoch: UInt64?) throws {
    try locked {
      guard epoch == pumpEpoch, catalogClaimEpoch == previousEpoch,
            previousEpoch.map({ epoch > $0 }) ?? true else { throw BookmarkCoordinatorError.ownershipUnavailable }
      catalogClaimEpoch = epoch
    }
  }

  public func bookmarkFacts(profileId: String) -> JSMap<BookmarkEditFact> {
    locked { stampsEnabled ? views[engine(profile: profileId)]?.facts ?? [:] : [:] }
  }

  @discardableResult
  public func ackBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64, mintedHLC: String)], expectedLink: String? = nil, admission: (() throws -> Void)? = nil) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, expectedLink: expectedLink, admission: admission) { view, link in
      for record in records {
        if let fact = view.facts[record.key] {
          if fact.seq <= record.seq {
            view.facts.removeValue(forKey: record.key)
          } else if JSKey(fact.link) == JSKey(link), fact.after.map({ BookmarkString.precedes($0, record.mintedHLC) }) ?? true {
            view.facts[record.key] = BookmarkEditFact(at: fact.at, seq: fact.seq, after: record.mintedHLC, link: fact.link)
          }
        }
        let key = Self.seenKey(link: link, key: record.key)
        if view.lastSeen[key].map({ BookmarkString.precedes($0, record.mintedHLC) }) ?? true { view.lastSeen[key] = record.mintedHLC }
      }
    }
  }

  @discardableResult
  public func observeRemoteRecords(profileId: String, expectedEngine: String, records: [(key: String, hlc: String)], expectedLink: String? = nil, admission: (() throws -> Void)? = nil) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, expectedLink: expectedLink, admission: admission) { view, link in
      Self.observe(records, link: link, view: &view)
    }
  }

  @discardableResult
  public func clearBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64)], admission: (() throws -> Void)? = nil) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine, admission: admission) { view, _ in
      for record in records {
        if let fact = view.facts[record.key], fact.seq <= record.seq { view.facts.removeValue(forKey: record.key) }
      }
    }
  }

  private static func seenKey(link: String, key: String) -> String {
    BookmarkString.encode("bm:" + JSONValue.array([.string(link), .string(key)]).bookmarkText(sortedKeys: true))
  }

  private static func observe(_ records: [(key: String, hlc: String)], link: String, view: inout BookmarkDesiredView) {
    for record in records {
      let key = seenKey(link: link, key: record.key)
      if view.lastSeen[key].map({ BookmarkString.precedes($0, record.hlc) }) ?? true { view.lastSeen[key] = record.hlc }
    }
  }

  private func updateBookmarkFacts(profileId: String, expectedEngine: String, expectedLink: String? = nil, admission: (() throws -> Void)? = nil, update: (inout BookmarkDesiredView, String) -> Void) throws -> Bool {
    do {
      return try transact(admission: admission) {
        guard stampsEnabled else {
          guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
          return (nil, { true })
        }
        let regular = Ids.isIncognitoProfile(profileId) ? Ids.incognitoOriginal(profileId) : profileId
        guard let engine = profiles[regular] else { throw BookmarkWriterError.unknownProfile }
        try validateBinding(profile: profileId, expectedEngine: expectedEngine)
        let link = durability.syncLinks[regular] ?? "none"
        if let expectedLink, JSKey(expectedLink) != JSKey(link) { throw BookmarkWriterError.staleBinding }
        guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
        guard var view = views[engine] else { return (nil, { true }) }
        let before = view
        update(&view, link)
        guard view != before else { return (nil, { true }) }
        var next = views
        next[engine] = view
        let checkpoint = checkpoint(views: next, bases: bases)
        return (checkpoint, { self.views = next; return true })
      }
    } catch let error as BookmarkWriterError {
      throw error
    } catch { return false }
  }

  @discardableResult
  public func setBookmarkSyncLinks(_ links: JSMap<String>, admission: (() throws -> Void)? = nil) -> Bool {
    do {
      return try transact(admission: admission) {
        guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
        guard stampsEnabled, links != durability.syncLinks else { return (nil, { true }) }
        let checkpoint = checkpoint(views: views, bases: bases, syncLinks: links)
        return (checkpoint, { true })
      }
    } catch { return false }
  }

  @discardableResult
  public func submit(profile: String, mutations: [BookmarkMutation], fromSync: Bool = false, requestID: String? = nil, expectedPumpEpoch: UInt64? = nil, expectedEngine: String? = nil, admission: (() throws -> Void)? = nil) throws -> BookmarkReceipt {
    let result = try transact(admission: admission) { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, BookmarkPublication)) in
      if let expectedPumpEpoch, expectedPumpEpoch != pumpEpoch { throw BookmarkCoordinatorError.staleRevision }
      let engine = engine(profile: profile)
      guard !blockedEngines.contains(JSKey(engine)), durability.terminalEngines[engine] == nil else { throw BookmarkWriterError.staleBinding }
      if let expectedEngine { try validateBinding(profile: profile, expectedEngine: expectedEngine) }
      let payload: JSONValue = ["kind": "submit", "profile": .string(profile), "engine": .string(engine), "fromSync": .bool(fromSync), "mutations": .array(mutations.map { ["method": .string($0.method), "args": .array($0.args)] })]
      guard !bookmarkEditsPaused(engine: engine) else { throw BookmarkPendingStoreError.unavailable }
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, self.silentPublication(self.desiredView(engine: engine))) }) }
      var view = desiredView(engine: engine)
      let before = view.document
      var factSequence = durability.factSequence
      for mutation in mutations {
        let target: String?
        switch mutation.method {
        case "addBookmark", "addBookmarkFolder": target = mutation.args.first?["profileId"]?.string
        case "addBookmarkTree", "toggleBookmark", "expectChildren": target = mutation.args.first?.string
        default: target = nil
        }
        if let target, !BookmarkReconcile.same(self.engine(profile: target), engine) { throw BookmarkCoordinatorError.invalidProfileScope }
      }
      var reducer = BookmarkReducer(document: before, engine: engine, profiles: aliases(engine), makeID: makeID, now: now)
      let results = try mutations.map { try reducer.apply($0) }
      view.document = reducer.document
      try durability.validateAcceptance(view.document, engine: engine)
      if view.document != before {
        view.revision += 1
        view.hasView = true
        if stampsEnabled && !fromSync {
          let oldNodes = before["nodes"]?.object ?? [:]
          let newNodes = view.document["nodes"]?.object ?? [:]
          var changed = Set<JSKey>()
          var orderedChanges: [String] = []
          func touch(_ id: String) {
            guard changed.insert(JSKey(id)).inserted else { return }
            orderedChanges.append(id)
          }
          for id in oldNodes.keys + newNodes.keys {
            let old = oldNodes[id]
            let new = newNodes[id]
            var oldFields = old?.object
            var newFields = new?.object
            oldFields?.removeValue(forKey: "children")
            newFields?.removeValue(forKey: "children")
            if oldFields != newFields { touch(id) }
            if old?["children"] != new?["children"] {
              for child in (old?["children"]?.array ?? []) + (new?["children"]?.array ?? []) {
                if let id = child.string { touch(id) }
              }
            }
          }
          let acceptedAt = now()
          for id in orderedChanges {
            let node = newNodes[id] ?? oldNodes[id]
            guard node?["parentId"]?.string != nil else { continue }
            guard factSequence < UInt64.max else { throw BookmarkCoordinatorError.invalidOperation("Bookmark fact sequence exhausted") }
            factSequence += 1
            let key = BookmarkRecordIdentity.key(id: id, node: node)
            let link = durability.syncLinks[profile] ?? "none"
            view.facts[key] = BookmarkEditFact(at: acceptedAt, seq: factSequence, after: view.lastSeen[Self.seenKey(link: link, key: key)], link: link)
          }
        }
      }
      let receipt = BookmarkReceipt(view: view, results: results)
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, factSequence: factSequence, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        self.invalidatePending(engine, desired: true, base: false)
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func replaceDocument(engine: String, profile: String? = nil, document: JSONValue, expectedRevision: UInt64, requestID: String? = nil, expectedEngine: String? = nil, records: [(key: String, hlc: String)] = [], expectedLink: String? = nil, admission: (() throws -> Void)? = nil) throws -> BookmarkReceipt {
    let result = try transact(admission: admission) { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, BookmarkPublication)) in
      guard !blockedEngines.contains(JSKey(engine)), durability.terminalEngines[engine] == nil else { throw BookmarkWriterError.staleBinding }
      if let expectedEngine {
        guard let profile, BookmarkReconcile.same(engine, expectedEngine) else { throw BookmarkWriterError.staleBinding }
        try validateBinding(profile: profile, expectedEngine: expectedEngine)
      }
      guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { throw BookmarkWriterError.invalidDocument("observations need bookmark record keys") }
      if stampsEnabled, let expectedLink {
        guard let profile, JSKey(durability.syncLinks[profile] ?? "none") == JSKey(expectedLink) else { throw BookmarkWriterError.staleBinding }
      }
      var fields: JSONObject = ["kind": "replace", "engine": .string(engine), "document": document, "expectedRevision": .string(String(expectedRevision))]
      if expectedLink != nil || !records.isEmpty {
        fields["records"] = .array(records.map { ["key": .string($0.key), "hlc": .string($0.hlc)] })
        fields["link"] = JSONValue(expectedLink)
      }
      let payload = JSONValue.object(fields)
      guard !bookmarkEditsPaused(engine: engine) else { throw BookmarkPendingStoreError.unavailable }
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, self.silentPublication(self.desiredView(engine: engine))) }) }
      var view = desiredView(engine: engine)
      guard view.revision == expectedRevision else { throw BookmarkCoordinatorError.staleRevision }
      try durability.validateAcceptance(document, engine: engine)
      if view.document != document { view.document = document; view.revision += 1; view.hasView = true }
      if stampsEnabled, let expectedLink { Self.observe(records, link: expectedLink, view: &view) }
      let receipt = BookmarkReceipt(view: view, results: [])
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        self.invalidatePending(engine, desired: true, base: false)
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func completeRead(engine: String, document: JSONValue, capturedRevision: UInt64, epoch: UInt64? = nil) -> Bool {
    let result: BookmarkPublication
    var backupFailure: String?
    if let legacySource, locked({ durability.writable && !durability.legacyPendingEngines.isEmpty }) {
      do { try legacySource.backup() } catch { backupFailure = String(describing: error) }
    }
    do {
      result = try transact { () throws -> (BookmarkCheckpointInput?, () -> BookmarkPublication) in
        guard !blockedEngines.contains(JSKey(engine)), durability.terminalEngines[engine] == nil, epoch == nil || epoch == pumpEpoch else { throw BookmarkCoordinatorError.staleRevision }
        var view = desiredView(engine: engine)
        let requiredRead = view.requiresRead || view.inFlightTarget != nil
        view.requiresRead = false
        var fetched = BookmarkFlat(document: document, engine: engine)
        let base = bases[engine] ?? BookmarkFlat(records: [])
        let attempted = view.inFlightTarget.map { BookmarkFlat(document: $0, engine: engine) }
        for id in fetched.order {
          guard var node = fetched.nodes[id]?.object, let original = base.nodes[id] ?? attempted?.nodes[id] else { continue }
          for field in ["title", "key"] {
            if let wire = original[field]?.string {
              let display = JSONValue.string(BookmarkString.encode(BookmarkString.display(wire)))
              if original[field] != display, node[field] == display { node[field] = original[field] }
            }
          }
          fetched.nodes[id] = .object(node)
        }
        let desired = BookmarkFlat(document: view.document, engine: engine)
        let intended = attempted ?? desired
        var delta = migrationOperations(BookmarkReconcile.operations(from: base, to: intended, engine: engine), engine: engine, desired: desired)
        var replay = BookmarkReconcile.replayPending(fetched, operations: delta, engine: engine)
        if view.inFlightTarget != nil, replay.structuralBreak == nil {
          let later = BookmarkReconcile.operations(from: intended, to: desired, engine: engine)
          let latest = BookmarkReconcile.replayPending(replay.tree, operations: later, engine: engine)
          replay = BookmarkReplayResult(tree: latest.tree, structuralBreak: latest.structuralBreak.map { delta.count + $0 })
          delta.append(contentsOf: later)
        }
        view.inFlightTarget = nil
        var merged = replay.tree.document(profiles: aliases(engine), preserving: view.document)
        var conflicts = durability.conflicts
        if let offset = replay.structuralBreak {
          let conflict: JSONValue = ["engine": .string(engine), "revision": .string(String(view.revision)), "base": .array(base.records), "desired": view.document, "operations": .array(delta), "structuralBreak": JSONValue(offset)]
          if !conflicts.contains(conflict) { conflicts.append(conflict) }
        }
        var progress = durability.legacyMigration
        var pending = durability.legacyPendingEngines
        if durability.writable, pending.contains(JSKey(engine)) {
          do {
            guard let legacySource else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark source could not be read") }
            if let backupFailure { throw BookmarkCoordinatorError.invalidOperation(backupFailure) }
            if progress == nil {
              progress = BookmarkLegacyProgress(source: legacySource.sourceID, engines: pending.map(\.text), profiles: launchLegacyProfiles)
            }
            guard progress?.source == legacySource.sourceID else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark source changed during migration") }
            var entry = progress?.engines[engine] ?? BookmarkLegacyEngineProgress(stage: "pending", ids: [], target: nil)
            if entry.stage == "pending" {
              let operations = try legacySource.importOperations(engine: engine, profiles: progress?.profiles ?? launchLegacyProfiles)
              let deleted = Set(base.order.filter { desired.nodes[$0] == nil }.map(JSKey.init))
              var excluded = deleted
              let admitted = operations.filter { operation in
                guard let id = operation["id"]?.string else { return false }
                if operation["parent"]?.string.map({ excluded.contains(JSKey($0)) }) == true { excluded.insert(JSKey(id)) }
                return !excluded.contains(JSKey(id))
              }
              let imported = BookmarkReconcile.replay(replay.tree, operations: admitted, engine: engine)
              guard imported.structuralBreak == nil, admitted.allSatisfy({ operation in
                operation["id"]?.string.map { imported.tree.nodes[$0] != nil } == true
              }) else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark import was refused") }
              merged = imported.tree.document(profiles: aliases(engine), preserving: view.document)
              try durability.validateAcceptance(merged, engine: engine)
              let sourceIDs = operations.compactMap { $0["id"]?.string }
              let sourceKeys = Set(sourceIDs.map(JSKey.init))
              entry = BookmarkLegacyEngineProgress(stage: "accepted", ids: sourceIDs, target: nil, imported: imported.tree.nodes.filter { id, _ in sourceKeys.contains(JSKey(id)) })
            } else if entry.stage == "pushed" || entry.stage == "blocked", let target = entry.target {
              var expected = BookmarkFlat(document: target, engine: engine)
              for id in entry.ids {
                guard let baseline = entry.imported[id], expected.nodes[id] == baseline,
                  var original = expected.nodes[id]?.object, var confirmed = fetched.nodes[id]?.object,
                  original["kind"] == "url", let url = confirmed["url"]?.string else { continue }
                original.removeValue(forKey: "url")
                confirmed.removeValue(forKey: "url")
                if original == confirmed {
                  var adopted = expected.nodes[id]?.object ?? [:]
                  adopted["url"] = .string(url)
                  expected.nodes[id] = .object(adopted)
                }
              }
              if BookmarkReconcile.operations(from: expected, to: fetched, engine: engine).isEmpty {
                entry.stage = "confirmed"
                entry.target = nil
                pending.remove(JSKey(engine))
                conflicts.removeAll { $0["kind"] == "legacyBookmarkMigration" && BookmarkReconcile.same($0["engine"]?.string, engine) }
              } else {
                entry.stage = "blocked"
                progress?.engines[engine] = entry
                throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark apply could not be confirmed; bookmark edits are paused for recovery")
              }
            }
            progress?.engines[engine] = entry
          } catch {
            let conflict: JSONValue = ["kind": "legacyBookmarkMigration", "engine": .string(engine), "source": JSONValue(legacySource?.sourceID), "message": .string(String(describing: error))]
            if !conflicts.contains(conflict) { conflicts.append(conflict) }
          }
        }
        let ready = durability.writable && !pending.contains(JSKey(engine)) && replay.structuralBreak == nil
        if view.document != merged || view.readyForSync != ready || view.structuralBreak != replay.structuralBreak || requiredRead {
          view.document = merged
          view.hasView = true
          view.readyForSync = ready
          view.structuralBreak = replay.structuralBreak
          view.revision += 1
        }
        var nextViews = views
        var nextBases = bases
        nextViews[engine] = view
        nextBases[engine] = fetched
        var input = durability.writable ? checkpoint(views: nextViews, bases: nextBases, conflicts: conflicts) : nil
        input?.legacyPendingEngines = pending
        input?.legacyMigration = progress
        return (input, {
          self.views = nextViews
          self.bases = nextBases
          self.invalidatePending(engine, desired: true, base: true)
          return self.notifications(engine)
        })
      }
    } catch { return false }
    deliver(result)
    finishLegacySource()
    return true
  }

  private func migrationOperations(_ operations: [JSONValue], engine: String, desired: BookmarkFlat) -> [JSONValue] {
    guard let entry = durability.legacyMigration?.engines[engine], entry.stage == "accepted" || entry.stage == "pushed" else { return operations }
    return operations.map { operation in
      guard operation["op"] == "add", let id = operation["id"]?.string,
        let imported = entry.imported[id], desired.nodes[id] == imported else { return operation }
      var value = operation.object ?? [:]
      value["ifAbsent"] = true
      return .object(value)
    }
  }

  func chromeOperations(_ operations: [JSONValue], engine: String, document: JSONValue) -> [JSONValue] {
    locked {
      guard let stage = durability.legacyMigration?.engines[engine]?.stage, stage == "accepted" || stage == "pushed" else { return operations }
      return migrationOperations(operations, engine: engine, desired: BookmarkFlat(document: document, engine: engine))
    }
  }

  func legacyImportPending(engine: String) -> Bool {
    locked { durability.legacyPendingEngines.contains(JSKey(engine)) }
  }

  public func migrationNeedsPush(engine: String) -> Bool {
    locked { durability.writable && durability.legacyMigration?.engines[engine]?.stage == "accepted" }
  }

  func migrationNeedsConfirmation(engine: String) -> Bool {
    locked { durability.writable && durability.legacyMigration?.engines[engine]?.stage == "pushed" }
  }

  private func finishLegacySource() {
    writing {
      let complete = locked {
        durability.writable && durability.legacyPendingEngines.isEmpty && durability.legacyMigration?.source == legacySource?.sourceID &&
          durability.legacyMigration?.engines.values.allSatisfy { $0.stage == "confirmed" || $0.stage == "discarded" } == true
      }
      guard complete, let legacySource, FileManager.default.fileExists(atPath: legacySource.sourceURL.path) else { return }
      do {
        let documents = locked { views.mapValues(\.document) }
        try BookmarkLaunchCache(directory: legacySource.sourceURL.deletingLastPathComponent()).save(documents: documents)
        try legacySource.retire()
      } catch {
        let publications = locked {
          durability.notice = BookmarkRecoveryNotice(kind: .legacyMigration, message: "Bookmarks were imported, but the legacy source could not be retired. Its recovery copy is retained.", preservedPath: legacySource.sourceURL.path)
          return views.keys.map { notifications($0) }
        }
        for publication in publications { deliver(publication) }
      }
    }
  }

  func claimPump() -> UInt64 {
    writing { locked { pumpEpoch += 1; return pumpEpoch } }
  }

  func invalidatePump(epoch: UInt64) {
    writing { locked { if pumpEpoch == epoch { pumpEpoch += 1 } } }
  }

  private func hasPendingEdits(_ engine: String) -> Bool {
    chromePushPending(engine) || !(views[engine]?.facts.isEmpty ?? true)
  }

  private func invalidatePending(_ engine: String, desired: Bool, base: Bool) {
    if desired { desiredVersions[engine] = (desiredVersions[engine] ?? 0) &+ 1 }
    if base { baseVersions[engine] = (baseVersions[engine] ?? 0) &+ 1 }
    pendingChromeDeltas.removeValue(forKey: engine)
  }

  private func pendingDelta(_ engine: String) -> [JSONValue] {
    guard !engine.hasPrefix("incognito:"), !blockedEngines.contains(JSKey(engine)), durability.terminalEngines[engine] == nil, let view = views[engine] else { return [] }
    let desiredVersion = desiredVersions[engine] ?? 0
    let baseVersion = baseVersions[engine] ?? 0
    if let cached = pendingChromeDeltas[engine], cached.desiredVersion == desiredVersion, cached.baseVersion == baseVersion { return cached.operations }
    let delta = BookmarkReconcile.operations(from: bases[engine] ?? BookmarkFlat(records: []), to: BookmarkFlat(document: view.document, engine: engine), engine: engine)
    #if DEBUG
      pendingDiffCount += 1
    #endif
    pendingChromeDeltas[engine] = PendingChromeDelta(desiredVersion: desiredVersion, baseVersion: baseVersion, operations: delta)
    return delta
  }

  private func chromePushPending(_ engine: String) -> Bool {
    guard !engine.hasPrefix("incognito:"), !blockedEngines.contains(JSKey(engine)), durability.terminalEngines[engine] == nil, let view = views[engine] else { return false }
    return view.inFlightTarget != nil || !pendingDelta(engine).isEmpty
  }

  private func needsPump(_ engine: String) -> Bool {
    chromePushPending(engine) || views[engine]?.document["nodes"]?.object?.isEmpty == true
  }

  func ownsPump(engine: String, epoch: UInt64) -> Bool {
    locked { pumpEpoch == epoch && !engine.hasPrefix("incognito:") && !blockedEngines.contains(JSKey(engine)) && durability.terminalEngines[engine] == nil && (profiles.values.contains { BookmarkReconcile.same($0, engine) } || durability.legacyPendingEngines.contains(JSKey(engine)) || needsPump(engine)) }
  }

  func pumpInput(engine: String, epoch: UInt64) -> (BookmarkDesiredView, [JSONValue])? {
    locked {
      guard ownsPump(engine: engine, epoch: epoch) else { return nil }
      return (desiredView(engine: engine), pendingDelta(engine))
    }
  }

  public func engineIncarnation(engine: String) -> UInt64 { locked { durability.incarnations[engine] ?? 1 } }

  func restorableTerminalEngines() -> Set<JSKey> {
    locked { Set(durability.terminalEngines.filter { $1 == "gone" || $1 == "emptyAliasless" }.keys.map(JSKey.init)) }
  }

  func deliberatelyRetiredEngines() -> Set<JSKey> {
    locked { Set(durability.terminalEngines.filter { $1 == "retired" }.keys.map(JSKey.init)) }
  }

  public func reactivate(engine: String, admission: (() throws -> Void)? = nil) throws {
    try transact(admission: admission) {
      guard durability.terminalEngines[engine] != nil else { return (nil, {}) }
      var terminals = durability.terminalEngines
      terminals.removeValue(forKey: engine)
      var input = checkpoint(views: views, bases: bases)
      input.terminalEngines = terminals
      return (input, { self.blockedEngines.remove(JSKey(engine)); self.pumpEpoch += 1; self.ownerGeneration += 1; self.invalidatePending(engine, desired: true, base: true) })
    }
  }

  public func retire(engine: String, admission: (() throws -> Void)? = nil) throws {
    try terminate(engine: engine, reason: "retired", epoch: nil, admission: admission)
  }

  @discardableResult
  func terminalizeGoneEngine(engine: String, epoch: UInt64) -> Bool {
    do { try terminate(engine: engine, reason: "gone", epoch: epoch); return true } catch { return false }
  }

  @discardableResult
  func terminalizeEmptyAliaslessEngine(engine: String, epoch: UInt64) -> Bool {
    do { try terminate(engine: engine, reason: "emptyAliasless", epoch: epoch); return true } catch { return false }
  }

  private func terminate(engine: String, reason: String, epoch: UInt64?, admission: (() throws -> Void)? = nil) throws {
    let publication = try transact(admission: admission) { () throws -> (BookmarkCheckpointInput?, () -> BookmarkPublication) in
      guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
      if durability.terminalEngines[engine] == reason { return (nil, { self.silentPublication(self.desiredView(engine: engine)) }) }
      if reason == "retired" {
        blockedEngines.insert(JSKey(engine))
        pumpEpoch += 1
        ownerGeneration += 1
      }
      if let epoch {
        guard ownsPump(engine: engine, epoch: epoch), aliases(engine).isEmpty else { throw BookmarkCoordinatorError.staleRevision }
      }
      var conflicts = reason == "retired" ? durability.conflicts.filter { !BookmarkReconcile.same($0["engine"]?.string, engine) } : durability.conflicts
      if reason != "retired" {
        let view = desiredView(engine: engine)
        if reason == "emptyAliasless", !(view.document["nodes"]?.object?.isEmpty ?? true) { throw BookmarkCoordinatorError.staleRevision }
        conflicts.append(["kind": reason == "gone" ? "goneBookmarkEngine" : "emptyAliaslessBookmarkEngine", "engine": .string(engine), "incarnation": .string(String(engineIncarnation(engine: engine))), "view": BookmarkDurability.encodeView(view), "desired": view.document, "base": .array(bases[engine]?.records ?? []), "operations": .array(pendingDelta(engine))])
      }
      var nextViews = views
      var nextBases = bases
      nextViews.removeValue(forKey: engine)
      nextBases.removeValue(forKey: engine)
      var terminals = durability.terminalEngines
      terminals[engine] = reason
      var incarnations = durability.incarnations
      let incarnation = incarnations[engine] ?? 1
      guard incarnation < UInt64.max else { throw BookmarkCoordinatorError.invalidOperation("Bookmark engine incarnation exhausted") }
      incarnations[engine] = incarnation + 1
      var input = checkpoint(views: nextViews, bases: nextBases, conflicts: conflicts)
      input.legacyPendingEngines = durability.legacyPendingEngines.subtracting([JSKey(engine)])
      if reason == "retired", var progress = durability.legacyMigration {
        progress.engines[engine] = BookmarkLegacyEngineProgress(stage: "discarded", ids: [], target: nil)
        input.legacyMigration = progress
      }
      input.terminalEngines = terminals
      input.incarnations = incarnations
      input.retainedRequests = durability.requests.filter { !BookmarkReconcile.same($1.receipt.view.engine, engine) }
      return (input, {
        self.views = nextViews
        self.bases = nextBases
        self.lastOwningProfiles.removeValue(forKey: engine)
        self.invalidatePending(engine, desired: true, base: true)
        return self.notifications(engine)
      })
    }
    deliver(publication)
  }

  @discardableResult
  func beginPush(engine: String, captured: BookmarkDesiredView, epoch: UInt64) -> Bool {
    do {
      let notification = try transact {
        guard !bookmarkEditsPaused(engine: engine) else { throw BookmarkPendingStoreError.unavailable }
        guard ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
        var view = desiredView(engine: engine)
        guard view.inFlightTarget == nil else { throw BookmarkCoordinatorError.staleRevision }
        view.inFlightTarget = captured.document
        view.revision += 1
        var nextViews = views
        nextViews[engine] = view
        let checkpoint = checkpoint(views: nextViews, bases: bases)
        return (checkpoint, { self.views = nextViews; return self.notifications(engine) })
      }
      deliver(notification)
      return true
    } catch { return false }
  }

  @discardableResult
  func completePush(engine: String, captured: BookmarkDesiredView, epoch: UInt64, succeeded: Bool, nowMs: Double) -> Bool {
    do {
      let notification = try transact {
        guard ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
        var view = desiredView(engine: engine)
        let before = view
        var nextBases = bases
        if succeeded {
          view.inFlightTarget = nil
          nextBases[engine] = BookmarkFlat(document: captured.document, engine: engine)
          view.failedPushes = 0
          view.retryNotBeforeMs = nil
          view.requiresRead = false
        } else {
          view.failedPushes = min(view.failedPushes + 1, 64)
          view.retryNotBeforeMs = view.failedPushes < 2 ? nil : nowMs + min(60_000, 1500 * pow(2, Double(min(view.failedPushes - 2, 6))))
          view.requiresRead = true
        }
        if view != before { view.revision += 1 }
        var nextViews = views
        nextViews[engine] = view
        var conflicts = durability.conflicts
        var progress = durability.legacyMigration
        if var entry = progress?.engines[engine], entry.stage == "accepted" || entry.stage == "pushed" {
          entry.stage = succeeded ? "pushed" : "accepted"
          entry.target = succeeded ? captured.document : nil
          progress?.engines[engine] = entry
          view.readyForSync = false
          view.requiresRead = true
          nextViews[engine] = view
          if !succeeded {
            let conflict: JSONValue = ["kind": "legacyBookmarkMigration", "engine": .string(engine), "message": "Legacy bookmarks could not be applied. Source and pending intent are retained; sync is paused."]
            if !conflicts.contains(conflict) { conflicts.append(conflict) }
          }
        }
        var input = checkpoint(views: nextViews, bases: nextBases, conflicts: conflicts)
        input.legacyMigration = progress
        return (input, { self.views = nextViews; self.bases = nextBases; self.invalidatePending(engine, desired: false, base: true); return self.notifications(engine) })
      }
      deliver(notification)
      return true
    } catch { return false }
  }

  @discardableResult
  func deferRead(engine: String, epoch: UInt64, nowMs: Double, delayMs: Double) -> Bool {
    do {
      let notification = try transact {
        guard ownsPump(engine: engine, epoch: epoch) else { throw BookmarkCoordinatorError.staleRevision }
        var view = desiredView(engine: engine)
        let before = view
        view.requiresRead = true
        view.retryNotBeforeMs = max(view.retryNotBeforeMs ?? 0, nowMs + delayMs)
        guard view != before else { return (nil, { self.silentPublication(view) }) }
        view.revision += 1
        var nextViews = views
        nextViews[engine] = view
        let checkpoint = checkpoint(views: nextViews, bases: bases)
        return (checkpoint, { self.views = nextViews; return self.notifications(engine) })
      }
      deliver(notification)
      return true
    } catch { return false }
  }

}

private struct BookmarkReducer {
  var document: JSONValue
  let engine: String
  let profiles: [String]
  let makeID: () -> String
  let now: () -> Double
  var nodes: JSONObject { document["nodes"]?.object ?? [:] }

  mutating func setNodes(_ nodes: JSONObject) { var value = document.object ?? [:]; value["nodes"] = .object(nodes); document = .object(value) }
  func subtree(_ ids: [String]) -> [String] {
    var out: [String] = []
    var visited = Set<JSKey>()
    func walk(_ id: String) {
      guard let node = nodes[id], visited.insert(JSKey(id)).inserted else { return }
      defer { visited.remove(JSKey(id)) }
      out.append(id)
      if node["kind"] == "folder" { for child in node["children"]?.array?.compactMap(\.string) ?? [] { walk(child) } }
    }
    for id in ids { walk(id) }
    return out
  }
  func ancestors(_ id: String) -> [String] {
    var out: [String] = []
    var parent = nodes[id]?["parentId"]?.string
    for _ in 0..<64 {
      guard let id = parent, nodes[id]?["kind"] == "folder" else { break }
      out.append(id)
      parent = nodes[id]?["parentId"]?.string
    }
    return out
  }
  mutating func ensureRoots(_ profile: String) -> BookmarkRoots {
    if let bar = document["roots"]?[profile]?["bar"]?.string, let other = document["roots"]?[profile]?["other"]?.string { return BookmarkRoots(bar: bar, other: other) }
    let roots = BookmarkFlat.roots(engine)
    var next = nodes
    for (id, title) in [(roots.bar, "Bookmarks Bar"), (roots.other, "Other Bookmarks")] where next[id] == nil {
      next[id] = ["kind": "folder", "id": .string(id), "parentId": nil, "title": .string(title), "children": [], "addedAt": 0]
    }
    setNodes(next)
    var values = document.object ?? [:]
    var map = document["roots"]?.object ?? [:]
    map[profile] = ["bar": .string(roots.bar), "other": .string(roots.other)]
    values["roots"] = .object(map)
    document = .object(values)
    return roots
  }
  mutating func insert(_ node: JSONValue, parent: String, index: Double?) {
    guard nodes[parent]?["kind"] == "folder", let id = node["id"]?.string else { return }
    var next = nodes
    var folder = next[parent]?.object ?? [:]
    var children = (folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) }
    children.insert(id, at: BookmarkReconcile.spliceIndex(index, count: children.count))
    folder["children"] = JSONValue(children)
    var value = node.object ?? [:]
    value["parentId"] = .string(parent)
    next[id] = .object(value)
    next[parent] = .object(folder)
    setNodes(next)
  }
  mutating func remove(_ ids: [String]) {
    let gone = Set(subtree(ids).map(JSKey.init))
    var next = nodes.filter { id, _ in !gone.contains(JSKey(id)) }
    for (id, node) in next where node["kind"] == "folder" {
      var folder = node.object ?? [:]
      let children = node["children"]?.array?.compactMap(\.string) ?? []
      if children.contains(where: { gone.contains(JSKey($0)) }) {
        folder["children"] = JSONValue(children.filter { !gone.contains(JSKey($0)) })
        next[id] = .object(folder)
      }
    }
    setNodes(next)
  }
  mutating func apply(_ mutation: BookmarkMutation) throws -> JSONValue {
    let args = mutation.args
    func arg(_ index: Int) -> JSONValue { index < args.count ? args[index] : .null }
    switch mutation.method {
    case "applyBookmarkOperations":
      for profile in profiles { _ = ensureRoots(profile) }
      var flat = BookmarkFlat(document: document, engine: engine)
      let operations = arg(0).array ?? []
      var applied = 0
      var invalid: [String] = []
      for source in operations {
        var operation = source
        let kind = operation["op"]?.string ?? ""
        guard ["add", "update", "move", "remove"].contains(kind) else { break }
        let id = operation["id"]?.string ?? ""
        let existing = flat.nodes[id]
        if arg(1).bool == true, let existing {
          var fields = operation.object ?? [:]
          for (key, field) in [("t", "title"), ("u", "url"), ("key", "key")] {
            if let original = existing[field]?.string,
              fields[key] == .string(BookmarkString.encode(BookmarkString.display(original))) {
              fields[key] = .string(original)
            }
          }
          operation = .object(fields)
        }
        if kind == "add", existing == nil {
          let roots = BookmarkFlat.roots(engine)
          let parent = operation["parent"]?.string ?? ""
          let parentID = parent == "bar" ? roots.bar : parent == "other" ? roots.other : parent
          guard flat.nodes[parentID]?["kind"] == "folder", let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { break }
          var fields = operation.object ?? [:]
          fields["k"] = operation["k"] == "f" ? "f" : "u"
          operation = .object(fields)
          if operation["k"] == "u", !BookmarkReconcile.keepsURL(operation["u"]?.string ?? "") {
            invalid.append(id)
            continue
          }
        }
        let replay = BookmarkReconcile.replay(flat, operations: [operation], engine: engine)
        guard replay.structuralBreak == nil else { break }
        flat = replay.tree
        applied += 1
      }
      document = flat.document(profiles: profiles, preserving: document)
      return ["applied": JSONValue(applied), "skipped": JSONValue(operations.count - applied - invalid.count), "invalid": JSONValue(invalid)]
    case "addBookmark", "addBookmarkFolder":
      let options = arg(0)
      let profile = options["profileId"]?.string ?? ""
      let roots = ensureRoots(profile)
      let id = makeID()
      let parent = options["parentId"]?.string ?? roots.bar
      var node: JSONObject = ["kind": mutation.method == "addBookmark" ? "url" : "folder", "id": .string(id), "parentId": .string(parent), "title": options["title"] ?? "", "addedAt": .number(now())]
      if mutation.method == "addBookmark" { node["url"] = options["url"] ?? ""; node["favicon"] = options["favicon"] ?? .null }
      else { node["children"] = [] }
      insert(.object(node), parent: parent, index: options["index"]?.number)
      return .string(id)
    case "updateBookmark":
      guard let id = arg(0).string, var node = nodes[id]?.object else { return .null }
      let patch = arg(1).object ?? [:]
      for (key, value) in patch where node["kind"] == "url" || key == "title" { node[key] = value }
      var next = nodes
      next[id] = .object(node)
      setNodes(next)
      return .null
    case "moveBookmark":
      guard let id = arg(0).string, let parent = arg(1).string, let node = nodes[id], let oldParent = node["parentId"]?.string, !subtree([id]).contains(where: { BookmarkReconcile.same($0, parent) }) else { return .null }
      var next = nodes
      if var folder = next[oldParent]?.object, folder["kind"] == "folder" {
        folder["children"] = JSONValue((folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) })
        next[oldParent] = .object(folder)
        setNodes(next)
      }
      insert(node, parent: parent, index: arg(2).number)
      return .null
    case "removeBookmark":
      if let id = arg(0).string, nodes[id]?["parentId"]?.string != nil { remove([id]) }
      return .null
    case "toggleBookmark":
      let profile = arg(0).string ?? ""
      let page = arg(1)
      let url = page["url"]?.string ?? ""
      guard !url.isEmpty else { return false }
      let roots = document["roots"]?[profile]
      let ids = subtree([roots?["bar"]?.string, roots?["other"]?.string].compactMap { $0 }).filter { nodes[$0]?["kind"] == "url" && nodes[$0]?["url"] == .string(url) }
      if !ids.isEmpty { remove(ids); return false }
      _ = try apply(BookmarkMutation(method: "addBookmark", args: [["profileId": .string(profile), "url": .string(url), "title": page["title"] ?? "", "favicon": page["favicon"] ?? .null]]))
      return true
    case "expectChildren":
      let folder = arg(1).string ?? ""
      guard nodes[folder]?["kind"] == "folder", nodes[folder]?["children"]?.array?.compactMap(\.string) == arg(2).array?.compactMap(\.string) else {
        throw BookmarkCoordinatorError.conditionFailed(folder)
      }
      return true
    case "addBookmarkTree":
      let roots = ensureRoots(arg(0).string ?? "")
      let target = arg(2).string.flatMap { nodes[$0]?["kind"] == "folder" ? $0 : nil } ?? roots.bar
      var next = nodes
      func build(_ draft: JSONValue, parent: String) -> String {
        let id = makeID()
        var node: JSONObject = ["id": .string(id), "parentId": .string(parent), "title": draft["title"] ?? "", "addedAt": draft["addedAt"].flatMap { $0.isNull ? nil : $0 } ?? .number(now())]
        if draft["url"] != nil && draft["children"]?.truthy != true {
          node["kind"] = "url"; node["url"] = draft["url"]; node["favicon"] = .null
          next[id] = .object(node)
        } else {
          node["kind"] = "folder"; node["children"] = []
          next[id] = .object(node)
          node["children"] = JSONValue((draft["children"]?.array ?? []).map { build($0, parent: id) })
          next[id] = .object(node)
        }
        return id
      }
      let ids = (arg(1).array ?? []).map { build($0, parent: target) }
      var folder = next[target]?.object ?? [:]
      var children = folder["children"]?.array?.compactMap(\.string) ?? []
      children.insert(contentsOf: ids, at: BookmarkReconcile.spliceIndex(arg(3).number, count: children.count))
      folder["children"] = JSONValue(children)
      next[target] = .object(folder)
      setNodes(next)
      return JSONValue(ids)
    case "removeBookmarks":
      let removable = (arg(0).array?.compactMap(\.string) ?? []).filter { nodes[$0]?["parentId"]?.truthy == true }
      let set = Set(removable.map(JSKey.init))
      let tops = removable.filter { !ancestors($0).contains(where: { set.contains(JSKey($0)) }) }
      let places: [JSONValue] = tops.map { id in
        let parent = nodes[id]?["parentId"]?.string ?? ""
        let index = nodes[parent]?["kind"] == "folder" ? nodes[parent]?["children"]?.array?.firstIndex(of: .string(id)) ?? -1 : 0
        return ["id": .string(id), "parentId": .string(parent), "index": JSONValue(index)]
      }
      let removed = subtree(tops).compactMap { nodes[$0] }
      if !tops.isEmpty { remove(tops) }
      return ["nodes": .array(removed), "places": .array(places)]
    case "restoreBookmarks":
      var next = nodes
      for node in arg(0)["nodes"]?.array ?? [] { if let id = node["id"]?.string { next[id] = node } }
      let places = (arg(0)["places"]?.array ?? []).enumerated().sorted { a, b in
        let av = a.element["index"]?.number ?? 0
        let bv = b.element["index"]?.number ?? 0
        return av == bv ? a.offset < b.offset : av < bv
      }.map(\.element)
      for place in places {
        guard let parent = place["parentId"]?.string, let id = place["id"]?.string else { continue }
        guard var folder = next[parent]?.object, folder["kind"] == "folder" else { next.removeValue(forKey: id); continue }
        var children = (folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) }
        children.insert(id, at: BookmarkReconcile.spliceIndex(place["index"]?.number, count: children.count))
        folder["children"] = JSONValue(children)
        next[parent] = .object(folder)
      }
      setNodes(next)
      return .null
    default: throw BookmarkCoordinatorError.unknownMutation(mutation.method)
    }
  }
}

private final class BookmarkMembershipObserver {
  private let lock = NSLock()
  private let continuation: AsyncStream<BookmarkMembershipSnapshot>.Continuation
  private var revision: UInt64?

  init(_ continuation: AsyncStream<BookmarkMembershipSnapshot>.Continuation) { self.continuation = continuation }

  func yield(_ snapshot: BookmarkMembershipSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    if let revision, snapshot.revision <= revision { return }
    revision = snapshot.revision
    continuation.yield(snapshot)
  }

  func finish() { continuation.finish() }
}

private struct BookmarkPublication {
  let membership: BookmarkMembershipSnapshot
  let membershipObservers: [BookmarkMembershipObserver]
  let view: BookmarkDesiredView
  let viewObservers: [BookmarkViewObserver]
}

private final class BookmarkViewObserver {
  private let lock = NSLock()
  private let continuation: AsyncStream<BookmarkDesiredView>.Continuation
  private var revision: UInt64?

  init(_ continuation: AsyncStream<BookmarkDesiredView>.Continuation) { self.continuation = continuation }

  func yield(_ view: BookmarkDesiredView) {
    lock.lock()
    defer { lock.unlock() }
    if let revision, view.revision <= revision { return }
    revision = view.revision
    continuation.yield(view)
  }

  func finish() { continuation.finish() }
}

enum BookmarkRecordIdentity {
  static func key(id: String, node: JSONValue?) -> String {
    if let key = node?["syncKey"]?.string, !key.isEmpty, JSKey(bookmarkUuidFor(key)) == JSKey(id) { return "bm:\(key)" }
    return "bm:\(id)"
  }

  private static func isBookmarkUuid(_ id: String) -> Bool {
    let units = Array(id.utf8)
    guard units.count == 36 else { return false }
    for (i, u) in units.enumerated() {
      if i == 8 || i == 13 || i == 18 || i == 23 {
        if u != UInt8(ascii: "-") { return false }
      } else if !((u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x66)) {
        return false
      }
    }
    return true
  }

  private static func uuidFrom(_ words: [UInt32]) -> String {
    let hex = words.map { String(repeating: "0", count: 8 - String($0, radix: 16).count) + String($0, radix: 16) }.joined()
    let units = Array(hex.utf8)
    let digit = Int(String(UnicodeScalar(units[16])), radix: 16)!
    let variant = String((digit & 0x3) | 0x8, radix: 16)
    func part(_ a: Int, _ b: Int) -> String { String(decoding: units[a..<b], as: UTF8.self) }
    return "\(part(0, 8))-\(part(8, 12))-4\(part(13, 16))-\(variant)\(part(17, 20))-\(part(20, 32))"
  }

  static func bookmarkUuidFor(_ id: String) -> String {
    if isBookmarkUuid(id) { return id }
    var h1: UInt32 = 1779033703, h2: UInt32 = 3144134277, h3: UInt32 = 1013904242, h4: UInt32 = 2773480762
    for k in BookmarkString.units("netnyahoo-bookmark:" + id).map(UInt32.init) {
      h1 = h2 ^ ((h1 ^ k) &* 597399067)
      h2 = h3 ^ ((h2 ^ k) &* 2869860233)
      h3 = h4 ^ ((h3 ^ k) &* 951274213)
      h4 = h1 ^ ((h4 ^ k) &* 2716044179)
    }
    h1 = (h3 ^ (h1 >> 18)) &* 597399067
    h2 = (h4 ^ (h2 >> 22)) &* 2869860233
    h3 = (h1 ^ (h3 >> 17)) &* 951274213
    h4 = (h2 ^ (h4 >> 19)) &* 2716044179
    h1 ^= h2 ^ h3 ^ h4
    h2 ^= h1
    h3 ^= h1
    h4 ^= h1
    return uuidFrom([h1, h2, h3, h4])
  }

}
