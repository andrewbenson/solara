import Foundation
import Observation
import SolaraModel
import SolaraStore
import Synchronization

public struct EngineHistoryRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int
  public var visitTimes: [Double]

  public init(url: String, title: String, visits: Int, visitTimes: [Double]) {
    self.url = url
    self.title = title
    self.visits = visits
    self.visitTimes = visitTimes
  }
}

public struct HistoryModifiedRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int

  public init(url: String, title: String, visits: Int) {
    self.url = url
    self.title = title
    self.visits = visits
  }
}

public enum HistoryChange: Sendable, Equatable {
  case visit(profile: String, url: String, title: String, visits: Int, at: Double)
  case modified(profile: String, rows: [HistoryModifiedRow])
  case deleted(profile: String, all: Bool, urls: [String])

  public var profile: String {
    switch self {
    case .visit(let profile, _, _, _, _), .modified(let profile, _), .deleted(let profile, _, _): profile
    }
  }
}

public struct HistoryEntry: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int
  public var lastVisit: Double
  public var visitTimes: [Double]
  public var visitCount: Int { visits }

  public init(url: String, title: String, visits: Int, lastVisit: Double, visitTimes: [Double]) {
    self.url = url
    self.title = title
    self.visits = visits
    self.lastVisit = lastVisit
    self.visitTimes = visitTimes
  }
}

public struct HistorySnapshot: Sendable, Equatable {
  public var entries: [HistoryEntry]
  public var floor: Double
  public var ready: Bool
  public var revision: Int

  public init(entries: [HistoryEntry] = [], floor: Double = -.infinity, ready: Bool = false, revision: Int = 0) {
    self.entries = entries
    self.floor = floor
    self.ready = ready
    self.revision = revision
  }
}

@MainActor
public protocol EngineClient: AnyObject {
  func deleteHistory(urls: [String], engineProfile: String) async throws
  func importHistory(rows: [HistoryImportRow], engineProfile: String) async throws
  func addHistoryVisits(pages: [HistoryVisitPage], toleranceMs: Double, engineProfile: String) async throws -> Int
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult
  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void)
  func watchHistory(engineProfile: String) async throws
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow]
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void)
  func watchBookmarks(engineProfile: String) async throws
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree
  func storedFavicon(page: String, engineProfile: String) async throws -> Data?
  func fetchFavicon(source: String, engineProfile: String) async -> Data?
  func bundledFavicon(page: String, dark: Bool) async -> Data?
  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws
}

@MainActor
final class HistoryLibrary {
  static let maxURLs = 5_000
  static let maxVisitTimes = 50

  let engineProfile: String
  private let client: any EngineClient
  private let publish: @MainActor (HistorySnapshot) -> Void
  private(set) var snapshot = HistorySnapshot()
  private var loading = false
  private var again = false
  private var queued: [HistoryChange] = []
  private var retired = false

  init(engineProfile: String, client: any EngineClient, publish: @escaping @MainActor (HistorySnapshot) -> Void) {
    self.engineProfile = engineProfile
    self.client = client
    self.publish = publish
  }

  func retire() {
    retired = true
    again = false
    queued = []
    snapshot = HistorySnapshot()
  }

  func reload() async {
    guard !retired else { return }
    if loading {
      again = true
      return
    }
    loading = true
    defer { loading = false }
    repeat {
      again = false
      queued = []
      do {
        try await client.watchHistory(engineProfile: engineProfile)
        guard !retired else { return }
        let rows = try await client.queryHistory(engineProfile: engineProfile, maxUrls: Self.maxURLs, maxVisits: Self.maxVisitTimes)
        guard !retired else { return }
        let read = Array(rows.prefix(Self.maxURLs))
        let floor = read.count >= Self.maxURLs ? read.map { $0.visitTimes.last ?? 0 }.min() ?? -.infinity : -.infinity
        var entries = read.filter { Self.shown($0.url) }.map {
          let times = Array($0.visitTimes.suffix(Self.maxVisitTimes))
          return HistoryEntry(url: $0.url, title: $0.title, visits: $0.visits, lastVisit: times.last ?? 0, visitTimes: times)
        }.sorted { $0.lastVisit > $1.lastVisit }
        for change in queued {
          if case .deleted(_, true, _) = change { again = true }
          else { entries = Self.applying(change, to: entries) }
        }
        update(entries: entries, floor: floor, ready: true)
      } catch {
        break
      }
    } while again
  }

  func receiveDuringLoad(_ change: HistoryChange) -> Bool {
    guard !retired, loading else { return false }
    queued.append(change)
    return true
  }

  func apply(_ changes: [HistoryChange]) -> Bool {
    guard !retired else { return false }
    var entries = snapshot.entries
    var reload = false
    for change in changes {
      if case .deleted(_, true, _) = change { reload = true }
      else if case .modified(_, let rows) = change, Self.addsUnknown(rows, to: entries) { reload = true }
      else { entries = Self.applying(change, to: entries) }
    }
    update(entries: entries, floor: nil, ready: snapshot.ready)
    return reload
  }

  private func update(entries: [HistoryEntry], floor: Double?, ready: Bool) {
    guard !retired else { return }
    let nextFloor = max(snapshot.floor, floor ?? -.infinity, entries.count >= Self.maxURLs ? entries.last?.lastVisit ?? -.infinity : -.infinity)
    guard entries != snapshot.entries || nextFloor != snapshot.floor || ready != snapshot.ready else { return }
    snapshot = HistorySnapshot(entries: entries, floor: nextFloor, ready: ready, revision: snapshot.revision + 1)
    publish(snapshot)
  }

  private static func addsUnknown(_ rows: [HistoryModifiedRow], to entries: [HistoryEntry]) -> Bool {
    let known = Set(entries.map(\.url))
    return rows.contains { shown($0.url) && !known.contains($0.url) }
  }

  private static func shown(_ url: String) -> Bool {
    let prefix = url.lowercased()
    return prefix.hasPrefix("http:") || prefix.hasPrefix("https:") || prefix.hasPrefix("file:")
  }

  private static func applying(_ change: HistoryChange, to entries: [HistoryEntry]) -> [HistoryEntry] {
    switch change {
    case .visit(_, let url, let title, let visits, let at):
      guard shown(url) else { return entries }
      var next = entries
      let old = next.firstIndex { $0.url == url }.map { next.remove(at: $0) }
      if let old, old.visitTimes.contains(at) { return entries }
      let times = Array(((old?.visitTimes ?? []) + [at]).sorted().suffix(maxVisitTimes))
      let entry = HistoryEntry(url: url, title: title.isEmpty ? old?.title ?? "" : title, visits: max(visits, 1), lastVisit: times.last ?? at, visitTimes: times)
      let index = next.firstIndex { $0.lastVisit <= entry.lastVisit } ?? next.endIndex
      next.insert(entry, at: index)
      return Array(next.prefix(maxURLs))
    case .modified(_, let rows):
      var next = entries
      var byURL: [String: HistoryModifiedRow] = [:]
      for row in rows { byURL[row.url] = row }
      for row in byURL.values {
        guard let index = entries.firstIndex(where: { $0.url == row.url }) else { continue }
        let old = entries[index]
        if (row.title == old.title || row.title.isEmpty) && row.visits == old.visits { continue }
        next[index].title = row.title.isEmpty ? old.title : row.title
        next[index].visits = row.visits
      }
      return next
    case .deleted(_, _, let urls):
      let gone = Set(urls)
      return entries.filter { !gone.contains($0.url) }
    }
  }
}

@MainActor
@Observable
public final class LibraryCatalog {
  public private(set) var histories = JSMap<HistorySnapshot>()
  public private(set) var bookmarkSnapshots: [String: BookmarkSnapshot] = [:]
  @ObservationIgnored let client: any EngineClient
  @ObservationIgnored let bookmarkAdmission: (@MainActor () async throws -> Void)?
  @ObservationIgnored public private(set) var favicons: FaviconLibrary?
  @ObservationIgnored private var libraries = JSMap<HistoryLibrary>()
  @ObservationIgnored private var retiredHistoryEngines: Set<JSKey> = []
  @ObservationIgnored var bookmarkClaim: BookmarkCatalogClaim?
  @ObservationIgnored var admittedRawBookmarkCommand = false
  @ObservationIgnored private let bookmarkSelection: @MainActor () -> Bool
  @ObservationIgnored private var selectedBookmarks = false
  @ObservationIgnored private var claimedBookmarks = false

  var rawBookmarksAvailable: Bool {
    if bookmarkSelection() { selectedBookmarks = true }
    return !selectedBookmarks && !claimedBookmarks
  }

  var externalBookmarkCommandsAvailable: Bool {
    if bookmarkSelection() { selectedBookmarks = true }
    return !selectedBookmarks
  }
  @ObservationIgnored private var bookmarkTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var bookmarkLibraries: [String: BookmarkLibrary] = [:]
  @ObservationIgnored private var bookmarkObservers: [String: [UUID: AsyncStream<BookmarkSnapshot>.Continuation]] = [:]
  @ObservationIgnored private var pending: [HistoryChange] = []
  @ObservationIgnored private var flushScheduled = false
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var observers = JSMap<[UUID: AsyncStream<HistorySnapshot>.Continuation]>()

  public init(client: any EngineClient, bookmarkAdmission: (@MainActor () async throws -> Void)? = nil, bookmarkSelection: @escaping @MainActor () -> Bool = { NativeBookmarkOwner.bookmarksSelected }) {
    self.client = client
    self.bookmarkAdmission = bookmarkAdmission
    self.bookmarkSelection = bookmarkSelection
    favicons = FaviconLibrary(client: client)
  }

  deinit { for task in bookmarkTasks.values { task.cancel() } }

  public func claimBookmarks(coordinator: BookmarkCoordinator, pump: BookmarkPump) throws {
    if let claim = bookmarkClaim {
      guard claim.coordinator === coordinator else { throw BookmarkCoordinatorError.ownershipUnavailable }
    } else {
      guard !observing, !admittedRawBookmarkCommand else { throw BookmarkCoordinatorError.ownershipUnavailable }
    }
    let claim = try pump.claimCatalog(coordinator: coordinator, replacing: bookmarkClaim?.epoch)
    for task in bookmarkTasks.values { task.cancel() }
    bookmarkTasks.removeAll()
    bookmarkClaim = claim
    claimedBookmarks = true
    bookmarkLibraries.removeAll()
    let live = Set(coordinator.catalogEngines.map(JSKey.init))
    for engine in Array(bookmarkSnapshots.keys) where !live.contains(JSKey(engine)) {
      publishBookmarks(BookmarkSnapshot(), engine: engine)
      bookmarkSnapshots.removeValue(forKey: engine)
    }
    bookmarkSnapshots.removeAll()
    for engine in coordinator.catalogEngines {
      guard (try? claim.validate(engine: engine)) != nil else { continue }
      publishDesired(coordinator.desiredView(engine: engine))
      observeDesired(engine: engine, claim: claim)
    }
  }

  private func observeDesired(engine: String, claim: BookmarkCatalogClaim) {
    guard bookmarkTasks[engine] == nil else { return }
    let stream = claim.coordinator.desiredViews(engine: engine)
    bookmarkTasks[engine] = Task { [weak self, weak claim] in
      for await view in stream {
        guard let self, let claim, self.bookmarkClaim === claim else { break }
        guard (try? claim.validate(engine: engine)) != nil else { continue }
        self.publishDesired(view)
      }
    }
  }

  func publishDesired(_ view: BookmarkDesiredView) {
    if let current = bookmarkSnapshots[view.engine], current.revision > Int(clamping: view.revision) { return }
    let roots = BookmarkFlat.roots(view.engine)
    var nodes: [String: BookmarkNode] = [:]
    for (id, value) in view.document["nodes"]?.object ?? [:] {
      nodes[id] = BookmarkNode(id: id, kind: value["kind"]?.string ?? "folder", parentId: value["parentId"]?.string, title: BookmarkString.display(value["title"]?.string ?? ""), url: value["url"]?.string.map(BookmarkString.display), addedAt: value["addedAt"]?.number ?? 0, syncKey: value["syncKey"]?.string, children: value["children"]?.array?.compactMap(\.string))
    }
    publishBookmarks(BookmarkSnapshot(roots: view.hasView ? roots : nil, nodes: nodes, ready: view.hasView, revision: Int(clamping: view.revision), readyForSync: view.readyForSync, recoveryMessage: bookmarkClaim?.coordinator.recoveryNotice?.message, editsPaused: bookmarkClaim?.coordinator.bookmarkEditsPaused(engine: view.engine) ?? false, recoveryConflictCount: bookmarkClaim?.coordinator.recoveryConflicts.count ?? 0), engine: view.engine)
  }

  private func publishBookmarks(_ snapshot: BookmarkSnapshot, engine: String) {
    bookmarkSnapshots[engine] = snapshot
    if let continuations = bookmarkObservers[engine]?.values {
      for continuation in continuations { continuation.yield(snapshot) }
    }
  }

  public func history(engineProfile: String) -> HistorySnapshot { histories[engineProfile] ?? HistorySnapshot() }

  public func bookmarks(engineProfile: String) -> BookmarkSnapshot { bookmarkSnapshots[engineProfile] ?? BookmarkSnapshot() }

  public func observeBookmarks(engineProfile: String) -> AsyncStream<BookmarkSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<BookmarkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    bookmarkObservers[engineProfile, default: [:]][id] = continuation
    continuation.yield(bookmarks(engineProfile: engineProfile))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.bookmarkObservers[engineProfile]?[id] = nil }
    }
    return stream
  }

  public func observe(engineProfile: String) -> AsyncStream<HistorySnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<HistorySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    if retiredHistoryEngines.contains(JSKey(engineProfile)) {
      continuation.yield(HistorySnapshot())
      continuation.finish()
      return stream
    }
    var continuations = observers[engineProfile] ?? [:]
    continuations[id] = continuation
    observers[engineProfile] = continuations
    continuation.yield(history(engineProfile: engineProfile))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.observers[engineProfile]?[id] = nil }
    }
    return stream
  }

  public func retireHistory(engineProfile: String, remainingEngineProfiles: [String]) {
    guard !remainingEngineProfiles.contains(where: { $0.jsEquals(engineProfile) }) else { return }
    retiredHistoryEngines.insert(JSKey(engineProfile))
    libraries.removeValue(forKey: engineProfile)?.retire()
    histories.removeValue(forKey: engineProfile)
    pending.removeAll { $0.profile.jsEquals(engineProfile) }
    if let continuations = observers.removeValue(forKey: engineProfile)?.values {
      for continuation in continuations {
        continuation.yield(HistorySnapshot())
        continuation.finish()
      }
    }
  }

  public func start(engineProfiles: [String]) async {
    do { try await bookmarkAdmission?() } catch { return }
    if !observing {
      observing = true
      client.observeHistory { [weak self] change in self?.receive(change) }
      client.observeBookmarks { [weak self] profile in self?.bookmarkChanged(engineProfile: profile) }
    }
    for profile in Set(engineProfiles.map(JSKey.init)).map(\.text).sorted() where !profile.hasPrefix("incognito:") && !retiredHistoryEngines.contains(JSKey(profile)) {
      if libraries[profile] == nil {
        libraries[profile] = HistoryLibrary(engineProfile: profile, client: client) { [weak self] snapshot in
          guard let self, !self.retiredHistoryEngines.contains(JSKey(profile)) else { return }
          self.histories[profile] = snapshot
          if let continuations = self.observers[profile]?.values {
            for continuation in continuations { continuation.yield(snapshot) }
          }
        }
      }
      if libraries[profile]?.snapshot.ready != true { await libraries[profile]?.reload() }
      guard !retiredHistoryEngines.contains(JSKey(profile)) else { continue }
      if let claim = bookmarkClaim {
        if (try? claim.validate(engine: profile)) != nil {
          observeDesired(engine: profile, claim: claim)
          publishDesired(claim.coordinator.desiredView(engine: profile))
          if !claim.coordinator.desiredView(engine: profile).readyForSync { claim.pump.requestRead(engine: profile) }
        }
        continue
      }
      guard rawBookmarksAvailable else { continue }
      if bookmarkLibraries[profile] == nil {
        bookmarkLibraries[profile] = BookmarkLibrary(engineProfile: profile, client: client, admission: { [weak self] in self?.rawBookmarksAvailable == true }) { [weak self] snapshot in
          guard let self, self.rawBookmarksAvailable else { return }
          self.publishBookmarks(snapshot, engine: profile)
        }
      }
      if bookmarkLibraries[profile]?.snapshot.ready != true { await bookmarkLibraries[profile]?.reload() }
    }
  }

  public func reloadBookmarks(engineProfile: String) async {
    do { try await bookmarkAdmission?() } catch { return }
    if let claim = bookmarkClaim {
      guard (try? claim.validate(engine: engineProfile)) != nil else { return }
      claim.pump.requestRead(engine: engineProfile)
      await claim.pump.settle(engine: engineProfile)
      guard (try? claim.validate(engine: engineProfile)) != nil else { return }
      publishDesired(claim.coordinator.desiredView(engine: engineProfile))
      return
    }
    guard rawBookmarksAvailable else { return }
    await bookmarkLibraries[engineProfile]?.reload()
  }

  private func bookmarkChanged(engineProfile: String) {
    if let claim = bookmarkClaim {
      guard (try? claim.validate(engine: engineProfile)) != nil else { return }
      claim.pump.requestRead(engine: engineProfile)
      return
    }
    guard rawBookmarksAvailable, let library = bookmarkLibraries[engineProfile] else { return }
    Task { await library.reload() }
  }

  public func reload(engineProfile: String) async {
    await libraries[engineProfile]?.reload()
  }

  private func receive(_ change: HistoryChange) {
    guard !retiredHistoryEngines.contains(JSKey(change.profile)), let library = libraries[change.profile] else { return }
    switch change {
    case .deleted(_, let all, let urls): favicons?.invalidate(engineProfile: change.profile, pages: all ? nil : urls)
    case .visit(_, let url, _, _, _): favicons?.forgetMisses(engineProfile: change.profile, pages: [url])
    case .modified(_, let rows): favicons?.forgetMisses(engineProfile: change.profile, pages: rows.map(\.url))
    }
    if library.receiveDuringLoad(change) { return }
    pending.append(change)
    if !flushScheduled {
      flushScheduled = true
      Task { await self.flushPending() }
    }
  }

  public func flushPending() async {
    let changes = pending
    pending = []
    flushScheduled = false
    var byProfile = JSMap<[HistoryChange]>()
    for change in changes { byProfile[change.profile] = (byProfile[change.profile] ?? []) + [change] }
    for (profile, batch) in byProfile {
      guard let library = libraries[profile] else { continue }
      if library.apply(batch) { await library.reload() }
    }
  }

}

@MainActor
public final class HistoryProfileLifetimes {
  private let catalog: LibraryCatalog
  private let store: Store
  private var subscription: Int?
  private nonisolated let observedRevision = Mutex(0)

  public init(catalog: LibraryCatalog, store: Store) {
    self.catalog = catalog
    self.store = store
    subscription = store.sequence {
      observedRevision.withLock { $0 = store.rev }
      return store.subscribe { [weak self] commit in
        guard let self else { return }
        let engines = self.retirements(commit)
        guard !engines.isEmpty else { return }
        let deliver: @MainActor @Sendable () -> Void = { [weak self] in
          guard let self, self.subscription != nil else { return }
          for engine in engines { self.catalog.retireHistory(engineProfile: engine, remainingEngineProfiles: []) }
        }
        if Thread.isMainThread { MainActor.assumeIsolated { deliver() } }
        else { DispatchQueue.main.async(execute: deliver) }
      }
    }
  }

  isolated deinit { if let subscription { store.unsubscribe(subscription) } }

  public func stop() {
    if let subscription { store.unsubscribe(subscription) }
    subscription = nil
  }

  nonisolated private func retirements(_ commit: Commit) -> [String] {
    observedRevision.withLock { previous in
      guard commit.rev > previous else { return [] }
      let live = commit.state.profiles.keys.map { commit.state.engineProfile($0) }
      var retired: Set<JSKey> = []
      for effect in commit.effects {
        guard case .profileDeleted(_, false, let engine) = effect,
          !live.contains(where: { $0.jsEquals(engine) }) else { continue }
        retired.insert(JSKey(engine))
      }
      previous = commit.rev
      return retired.map(\.text).sorted()
    }
  }
}
