import Foundation
import SolaraOmnibox

public struct SuggestRequest: Sendable {
  public let profileId: String
  public let typed: String
  public let tabs: [TabRow]
  public let options: SuggestOptions
}

public final class SuggestionWorker: @unchecked Sendable {
  static let warmSlice: Duration = .milliseconds(4)

  private struct Rows {
    let history: [HistoryRow]
    let bookmarks: [BookmarkRow]
  }

  private let queue = DispatchQueue(label: "solara.omnibox.suggest", qos: .utility)
  private var indexes: [String: SuggestionIndex] = [:]
  private var building: [String: SuggestionIndex] = [:]
  private var next: [String: Rows] = [:]
  private let lock = NSLock()
  private var latest: [UUID: Int] = [:]
  private var generations: [String: UUID] = [:]
  private var preparedProfiles: Set<String> = []
  private var installedGenerations: [String: UUID] = [:]
  private let swapped: @Sendable (String) -> Void
  #if DEBUG
  private(set) var swapCount = 0
  private(set) var warmQoS: qos_class_t?
  private(set) var computeQoS: qos_class_t?
  #endif
  #if SOLARA_PROBES
  private var computedCount = 0
  private var droppedCount = 0
  #endif

  public init(swapped: @escaping @Sendable (String) -> Void = { _ in }) {
    self.swapped = swapped
  }

  func replace(profileId: String, history: [HistoryRow], bookmarks: [BookmarkRow], serveOldUntilReady: Bool) {
    let generation = lock.withLock {
      if !serveOldUntilReady || generations[profileId] == nil {
        generations[profileId] = UUID()
        preparedProfiles.remove(profileId)
      }
      return generations[profileId]!
    }
    queue.async {
      self.installedGenerations[profileId] = generation
      guard serveOldUntilReady, self.indexes[profileId] != nil else {
        let index = SuggestionIndex(history: history, bookmarks: bookmarks, reusing: self.building[profileId] ?? self.indexes[profileId])
        self.building[profileId] = nil
        self.next[profileId] = nil
        self.indexes[profileId] = index
        self.warm(profileId, index, generation: generation)
        return
      }
      guard self.building[profileId] == nil else {
        self.next[profileId] = Rows(history: history, bookmarks: bookmarks)
        return
      }
      self.build(profileId, Rows(history: history, bookmarks: bookmarks), generation: generation)
    }
  }

  private func build(_ profileId: String, _ rows: Rows, generation: UUID) {
    let index = SuggestionIndex(history: rows.history, bookmarks: rows.bookmarks, reusing: indexes[profileId])
    building[profileId] = index
    warm(profileId, index, generation: generation)
  }

  func remove(_ profileId: String) {
    lock.withLock {
      generations[profileId] = nil
      preparedProfiles.remove(profileId)
    }
    queue.async {
      self.installedGenerations[profileId] = nil
      self.indexes[profileId] = nil
      self.building[profileId] = nil
      self.next[profileId] = nil
    }
  }

  private func warm(_ profileId: String, _ index: SuggestionIndex, generation: UUID) {
    let swapping = building[profileId] === index
    guard swapping || indexes[profileId] === index else { return }
    #if DEBUG
    warmQoS = qos_class_self()
    #endif
    guard index.prepare(deadline: ContinuousClock.now.advanced(by: Self.warmSlice)) else {
      queue.async { self.warm(profileId, index, generation: generation) }
      return
    }
    markPrepared(profileId, generation: generation)
    guard swapping else { return }
    swap(profileId, index)
    if let rows = next.removeValue(forKey: profileId) { build(profileId, rows, generation: generation) }
  }

  private func swap(_ profileId: String, _ index: SuggestionIndex) {
    indexes[profileId] = index
    building[profileId] = nil
    #if DEBUG
    swapCount += 1
    #endif
    swapped(profileId)
  }

  private func index(_ profileId: String) -> SuggestionIndex {
    indexes[profileId] ?? SuggestionIndex(history: [], bookmarks: [])
  }

  private func compute(_ request: SuggestRequest) -> SuggestionResult {
    let index = index(request.profileId)
    let result = index.suggest(request.typed, tabs: request.tabs, options: request.options)
    if index.isPrepared, let generation = installedGenerations[request.profileId] {
      markPrepared(request.profileId, generation: generation)
    }
    return result
  }

  private func markPrepared(_ profileId: String, generation: UUID) {
    lock.withLock {
      if generations[profileId] == generation { preparedProfiles.insert(profileId) }
    }
  }

  func hasPreparedIndex(_ profileId: String) -> Bool {
    lock.withLock { preparedProfiles.contains(profileId) }
  }

  #if DEBUG
  var serving: [String: ObjectIdentifier] { queue.sync { indexes.mapValues(ObjectIdentifier.init) } }
  var known: Set<String> { queue.sync { Set(indexes.keys).union(building.keys) } }
  var swaps: Int { queue.sync { swapCount } }
  var lastWarmQoS: qos_class_t? { queue.sync { warmQoS } }
  var lastComputeQoS: qos_class_t? { queue.sync { computeQoS } }
  #endif

  func suggestNow(_ request: SuggestRequest) -> SuggestionResult {
    queue.sync { compute(request) }
  }

  func suggestIfPrepared(_ request: SuggestRequest) -> SuggestionResult? {
    guard hasPreparedIndex(request.profileId) else { return nil }
    return suggestNow(request)
  }

  func submit(_ request: SuggestRequest, for key: UUID, generation: Int, deliver: @escaping @Sendable (SuggestionResult) -> Void) {
    lock.withLock { latest[key] = generation }
    queue.async(qos: .userInitiated, flags: .enforceQoS) {
      guard self.lock.withLock({ self.latest[key] == generation }) else {
        #if SOLARA_PROBES
        self.droppedCount += 1
        #endif
        return
      }
      #if DEBUG
      self.computeQoS = qos_class_self()
      #endif
      let result = self.compute(request)
      #if SOLARA_PROBES
      self.computedCount += 1
      #endif
      deliver(result)
    }
  }

  func supersede(for key: UUID, generation: Int) {
    lock.withLock { latest[key] = generation }
  }

  func forget(_ key: UUID) {
    _ = lock.withLock { latest.removeValue(forKey: key) }
  }

  func drain() {
    queue.sync {}
  }

  func prepared(_ profileId: String) -> Bool {
    queue.sync {
      while let index = building[profileId] {
        _ = index.prepare()
        swap(profileId, index)
        if let rows = next.removeValue(forKey: profileId) {
          building[profileId] = SuggestionIndex(history: rows.history, bookmarks: rows.bookmarks, reusing: index)
        }
      }
      let prepared = indexes[profileId]?.prepare() ?? false
      if prepared, let generation = installedGenerations[profileId] {
        markPrepared(profileId, generation: generation)
      }
      return prepared
    }
  }

  #if SOLARA_PROBES
  var counts: (computed: Int, dropped: Int) { queue.sync { (computedCount, droppedCount) } }
  #endif
}
