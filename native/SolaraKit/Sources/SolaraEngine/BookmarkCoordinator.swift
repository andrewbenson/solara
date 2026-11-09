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
  let engineQueue = BookmarkEngineQueue()
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
  private var lastOwningProfiles: JSMap<String> = [:]
  private var views: JSMap<BookmarkDesiredView> = [:]
  private var bases: JSMap<BookmarkFlat> = [:]
  private let durability: BookmarkDurability
  private var streams: [UUID: (JSKey, BookmarkMembershipObserver)] = [:]
  private var viewStreams: [UUID: (JSKey, BookmarkViewObserver)] = [:]

  public init(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], makeID: @escaping () -> String = { UUID().uuidString.lowercased() }, now: @escaping () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }, stampsEnabled: Bool = false, pendingStore: BookmarkPendingStore? = nil, launchInput: BookmarkLaunchInput = .init()) {
    self.profiles = profiles
    self.defaultProfile = defaultProfile
    self.owningProfiles = owningProfiles
    self.makeID = makeID
    self.now = now
    self.stampsEnabled = stampsEnabled
    durability = BookmarkDurability(store: pendingStore)
    durability.legacyPendingEngines.formUnion(launchInput.legacyPendingEngines)
    for (engine, document) in launchInput.documents {
      views[engine] = BookmarkDesiredView(engine: engine, document: document, hasView: true)
      bases[engine] = BookmarkFlat(document: document, engine: engine)
    }
    for (engine, restored) in durability.restoredViews {
      views[engine] = restored
      bases[engine] = durability.restoredBases[engine]
    }
    lastOwningProfiles = durability.owners
  }

  public var recoveryNotice: BookmarkRecoveryNotice? { locked { durability.notice } }
  public func dismissRecoveryNotice() { locked { durability.notice = nil } }
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

  private func transact<T>(_ prepare: () throws -> (BookmarkCheckpointInput?, () -> T)) throws -> T {
    try writing {
      let (input, install) = try locked(prepare)
      let checkpoint = try input.map { try durability.prepare($0) }
      do {
        if let checkpoint { try durability.store?.write(checkpoint.payload) }
      } catch {
        locked { durability.recordWriteFailure(error) }
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
    guard let mapped = profiles[regular], BookmarkReconcile.same(mapped, expectedEngine) else { throw BookmarkWriterError.staleBinding }
  }

  @discardableResult
  public func remap(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String>? = nil) -> Bool {
    do {
      return try transact {
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
      return BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: engine, generation: ownerGeneration), revision: view.revision, ready: view.readyForSync, document: view.document, facts: stampsEnabled ? view.facts : [:])
    }
  }

  func invalidatePumps() {
    writing { locked { ownerGeneration += 1; pumpEpoch += 1 } }
  }

  private func aliases(_ engine: String) -> [String] { profiles.filter { BookmarkReconcile.same($1, engine) }.keys }
  private func ownerProfile(_ engine: String) -> String {
    ownerProfile(engine, profiles: profiles, owningProfiles: owningProfiles, previous: lastOwningProfiles)
  }

  private func ownerProfile(_ engine: String, profiles: JSMap<String>, owningProfiles: JSMap<String>, previous: JSMap<String>) -> String {
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
    for stream in publication.membershipObservers { stream.yield(publication.membership) }
    for stream in publication.viewObservers { stream.yield(publication.view) }
  }

  var catalogEngines: [String] {
    locked {
      var seen = Set<JSKey>()
      let mapped = Set(profiles.values.map(JSKey.init))
      return (profiles.values + views.keys.filter { !mapped.contains(JSKey($0)) && chromePushPending($0) }).filter { !$0.hasPrefix("incognito:") && seen.insert(JSKey($0)).inserted }
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
  public func ackBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64, mintedHLC: String)]) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine) { view in
      for record in records {
        if let fact = view.facts[record.key] {
          if fact.seq <= record.seq {
            view.facts.removeValue(forKey: record.key)
          } else if fact.after.map({ jsKeyPrecedes($0, record.mintedHLC) }) ?? true {
            view.facts[record.key] = BookmarkEditFact(at: fact.at, seq: fact.seq, after: record.mintedHLC, link: fact.link)
          }
        }
        if view.lastSeen[record.key].map({ jsKeyPrecedes($0, record.mintedHLC) }) ?? true { view.lastSeen[record.key] = record.mintedHLC }
      }
    }
  }

  @discardableResult
  public func observeRemoteRecords(profileId: String, expectedEngine: String, records: [(key: String, hlc: String)]) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine) { view in
      for record in records where view.lastSeen[record.key].map({ jsKeyPrecedes($0, record.hlc) }) ?? true {
        view.lastSeen[record.key] = record.hlc
      }
    }
  }

  @discardableResult
  public func clearBookmarkFacts(profileId: String, expectedEngine: String, records: [(key: String, seq: UInt64)]) throws -> Bool {
    guard records.allSatisfy({ $0.key.hasPrefix("bm:") }) else { return false }
    return try updateBookmarkFacts(profileId: profileId, expectedEngine: expectedEngine) { view in
      for record in records {
        if let fact = view.facts[record.key], fact.seq <= record.seq { view.facts.removeValue(forKey: record.key) }
      }
    }
  }

  private func updateBookmarkFacts(profileId: String, expectedEngine: String, update: (inout BookmarkDesiredView) -> Void) throws -> Bool {
    do {
      return try transact {
        guard stampsEnabled else { return (nil, { true }) }
        let regular = Ids.isIncognitoProfile(profileId) ? Ids.incognitoOriginal(profileId) : profileId
        guard let engine = profiles[regular] else { throw BookmarkWriterError.unknownProfile }
        try validateBinding(profile: profileId, expectedEngine: expectedEngine)
        guard var view = views[engine] else { return (nil, { true }) }
        let before = view
        update(&view)
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
  public func setBookmarkSyncLinks(_ links: JSMap<String>) -> Bool {
    do {
      return try transact {
        guard stampsEnabled, links != durability.syncLinks else { return (nil, { true }) }
        let checkpoint = checkpoint(views: views, bases: bases, syncLinks: links)
        return (checkpoint, { true })
      }
    } catch { return false }
  }

  @discardableResult
  public func submit(profile: String, mutations: [BookmarkMutation], fromSync: Bool = false, requestID: String? = nil, expectedPumpEpoch: UInt64? = nil, expectedEngine: String? = nil) throws -> BookmarkReceipt {
    let result = try transact { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, BookmarkPublication)) in
      if let expectedPumpEpoch, expectedPumpEpoch != pumpEpoch { throw BookmarkCoordinatorError.staleRevision }
      let engine = engine(profile: profile)
      if let expectedEngine { try validateBinding(profile: profile, expectedEngine: expectedEngine) }
      let payload: JSONValue = ["kind": "submit", "profile": .string(profile), "engine": .string(engine), "fromSync": .bool(fromSync), "mutations": .array(mutations.map { ["method": .string($0.method), "args": .array($0.args)] })]
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, self.silentPublication(self.desiredView(engine: engine))) }) }
      guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
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
            view.facts[key] = BookmarkEditFact(at: acceptedAt, seq: factSequence, after: view.lastSeen[key], link: durability.syncLinks[profile] ?? "none")
          }
        }
      }
      let receipt = BookmarkReceipt(view: view, results: results)
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, factSequence: factSequence, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func replaceDocument(engine: String, profile: String? = nil, document: JSONValue, expectedRevision: UInt64, requestID: String? = nil, expectedEngine: String? = nil) throws -> BookmarkReceipt {
    let result = try transact { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, BookmarkPublication)) in
      if let expectedEngine {
        guard let profile, BookmarkReconcile.same(engine, expectedEngine) else { throw BookmarkWriterError.staleBinding }
        try validateBinding(profile: profile, expectedEngine: expectedEngine)
      }
      let payload: JSONValue = ["kind": "replace", "engine": .string(engine), "document": document, "expectedRevision": .string(String(expectedRevision))]
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, self.silentPublication(self.desiredView(engine: engine))) }) }
      guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
      var view = desiredView(engine: engine)
      guard view.revision == expectedRevision else { throw BookmarkCoordinatorError.staleRevision }
      try durability.validateAcceptance(document, engine: engine)
      if view.document != document { view.document = document; view.revision += 1; view.hasView = true }
      let receipt = BookmarkReceipt(view: view, results: [])
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func completeRead(engine: String, document: JSONValue, capturedRevision: UInt64, epoch: UInt64? = nil) -> Bool {
    let result: BookmarkPublication
    do {
      result = try transact { () throws -> (BookmarkCheckpointInput?, () -> BookmarkPublication) in
        guard epoch == nil || epoch == pumpEpoch else { throw BookmarkCoordinatorError.staleRevision }
        var view = desiredView(engine: engine)
        let requiredRead = view.requiresRead || view.inFlightTarget != nil
        view.requiresRead = false
        let fetched = BookmarkFlat(document: document, engine: engine)
        let base = bases[engine] ?? BookmarkFlat(records: [])
        let desired = BookmarkFlat(document: view.document, engine: engine)
        let intended = view.inFlightTarget.map { BookmarkFlat(document: $0, engine: engine) } ?? desired
        var delta = BookmarkReconcile.operations(from: base, to: intended, engine: engine)
        var replay = BookmarkReconcile.replayPending(fetched, operations: delta, engine: engine)
        if view.inFlightTarget != nil, replay.structuralBreak == nil {
          let later = BookmarkReconcile.operations(from: intended, to: desired, engine: engine)
          let latest = BookmarkReconcile.replayPending(replay.tree, operations: later, engine: engine)
          replay = BookmarkReplayResult(tree: latest.tree, structuralBreak: latest.structuralBreak.map { delta.count + $0 })
          delta.append(contentsOf: later)
        }
        view.inFlightTarget = nil
        let merged = replay.tree.document(profiles: aliases(engine), preserving: view.document)
        var conflicts = durability.conflicts
        if let offset = replay.structuralBreak {
          let conflict: JSONValue = ["engine": .string(engine), "revision": .string(String(view.revision)), "base": .array(base.records), "desired": view.document, "operations": .array(delta), "structuralBreak": JSONValue(offset)]
          if !conflicts.contains(conflict) { conflicts.append(conflict) }
        }
        let ready = !durability.legacyPendingEngines.contains(JSKey(engine))
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
        let checkpoint = durability.writable ? checkpoint(views: nextViews, bases: nextBases, conflicts: conflicts) : nil
        return (checkpoint, {
          self.views = nextViews
          self.bases = nextBases
          return self.notifications(engine)
        })
      }
    } catch { return false }
    deliver(result)
    return true
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

  private func chromePushPending(_ engine: String) -> Bool {
    guard let view = views[engine] else { return false }
    if view.inFlightTarget != nil { return true }
    let base = bases[engine] ?? BookmarkFlat(records: [])
    return !BookmarkReconcile.operations(from: base, to: BookmarkFlat(document: view.document, engine: engine), engine: engine).isEmpty
  }

  func ownsPump(engine: String, epoch: UInt64) -> Bool {
    locked { pumpEpoch == epoch && !engine.hasPrefix("incognito:") && (profiles.values.contains { BookmarkReconcile.same($0, engine) } || chromePushPending(engine)) }
  }

  func pumpInput(engine: String, epoch: UInt64) -> (BookmarkDesiredView, BookmarkFlat)? {
    locked {
      guard ownsPump(engine: engine, epoch: epoch) else { return nil }
      return (desiredView(engine: engine), bases[engine] ?? BookmarkFlat(records: []))
    }
  }

  @discardableResult
  func beginPush(engine: String, captured: BookmarkDesiredView, epoch: UInt64) -> Bool {
    do {
      let notification = try transact {
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
        let checkpoint = checkpoint(views: nextViews, bases: nextBases)
        return (checkpoint, { self.views = nextViews; self.bases = nextBases; return self.notifications(engine) })
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
    for k in ("netnyahoo-bookmark:" + id).utf16.map(UInt32.init) {
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
