import SolaraModel
import SolaraStore

public protocol PinnedSyncStore: SyncStore {
  func runPinned(_ body: (Session) throws -> Void) throws
  func runPinnedWhenFree(_ body: @escaping @Sendable (Session) throws -> Void) throws
}

extension Store: PinnedSyncStore {
  public func runPinned(_ body: (Session) throws -> Void) throws { try transact(origin: .sync, body) }
  public func runPinnedWhenFree(_ body: @escaping @Sendable (Session) throws -> Void) throws { try transactWhenFree(body) }
}

let legacyKeys = JSMap<String>([
  ("openLinksInSmallYahu", "openLinksInLittleSolara"), ("smallYahuSize", "littleSolaraSize"), ("newSmallYahu", "newLittleSolara"),
  ("toggleOpenLinksInSmallYahu", "toggleOpenLinksInLittleSolara"),
])

public func fromLegacy(_ value: JSONValue) -> JSONValue {
  switch value {
  case .string(let s): return .string(fromLegacyUrl(s))
  case .array(let items): return .array(items.map(fromLegacy))
  case .object(let source):
    var out = JSONObject()
    for (key, v) in source {
      let name = legacyKeys[key] ?? key
      if !name.jsEquals(key) && source.contains(name) { continue }
      out[name] = fromLegacy(v)
    }
    return .object(out)
  default: return value
  }
}

public final class LegacyNamesAdapter: SyncAdapter {
  let inner: SyncAdapter

  public init(_ inner: SyncAdapter) { self.inner = inner }

  public var prefix: String { inner.prefix }
  public var adoptRemoteOnJoin: Bool { inner.adoptRemoteOnJoin }
  public var publishAfterPull: Bool { inner.publishAfterPull }
  public var publishOnlyAfterPull: Bool { inner.publishOnlyAfterPull }
  public var ownsItsChanges: Bool { inner.ownsItsChanges }
  public func editedAt(_ value: JSONValue) -> Double? { inner.editedAt(value) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? { try await inner.extract(context) }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    let renamed = visible.map { ($0.key, fromLegacy($0.value)) }
    return try await withoutActuallyEscaping(base) { base in
      try await inner.apply(renamed, changed, { base($0).map(fromLegacy) }, records)
    }
  }

  public func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome {
    let renamed = visible.map { ($0.key, fromLegacy($0.value)) }
    return try await withoutActuallyEscaping(base) { base in
      try await inner.applyKeys(renamed, changed, { base($0).map(fromLegacy) }, records)
    }
  }
}

func pinnedLookups(_ c: ExtractContext) -> PinnedLookups {
  PinnedLookups(positions: assignPositions, base: c.base, queued: c.queued, now: c.now, known: c.known, remote: c.remote, stamp: c.stamp)
}

public class PinnedAreaAdapter {
  let store: PinnedSyncStore
  let profileId: String

  init(store: PinnedSyncStore, profileId: String) {
    self.store = store
    self.profileId = profileId
  }

  func extraction(_ e: PinnedExtraction) -> Extraction {
    let store = store
    let profileId = profileId
    return Extraction(
      values: e.values.map { ($0.key, Optional($0.value)) }, ignore: e.ignore, republish: e.republish,
      published: e.settled.map { settled in
        { keys, _ in
          let published = settled(keys)
          try? store.runPinnedWhenFree { $0.settlePinChoices(profileId, published) }
        }
      })
  }

  func write<Result>(_ body: (Session) -> Result?) async throws -> Result? {
    while true {
      do {
        var result: Result? = nil
        try store.runPinned { result = body($0) }
        return result
      } catch is StoreBusy {
        try await Task.sleep(for: .milliseconds(50))
      }
    }
  }
}

public final class PinnedAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = "pin"

  public override init(store: PinnedSyncStore, profileId: String) { super.init(store: store, profileId: profileId) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(try PinnedSync.pinnedValues(store.state, profileId, pinnedLookups(context)))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await write { $0.applySyncedPins(profileId, visible, changed, base, known: records.known, now: records.now, horizon: records.horizon) }
  }
}

public final class PinnedOrderAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = PinnedSync.order

  public override init(store: PinnedSyncStore, profileId: String) { super.init(store: store, profileId: profileId) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(PinnedSync.orderValues(store.state, profileId, pinnedLookups(context)))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await write { $0.applySyncedPinOrder(profileId, visible) }
  }
}

public final class PinnedRowsAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = PinnedSync.row

  public override init(store: PinnedSyncStore, profileId: String) { super.init(store: store, profileId: profileId) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(PinnedSync.rowValues(store.state, profileId, pinnedLookups(context)))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await write { $0.applySyncedPinRows(profileId, visible, changed, base) }
  }
}

public final class GroupLooksAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = PinnedSync.groupLook

  public override init(store: PinnedSyncStore, profileId: String) { super.init(store: store, profileId: profileId) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(PinnedSync.groupLookValues(store.state, profileId, pinnedLookups(context)))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await write { $0.applySyncedGroupLooks(profileId, visible, changed) }
  }
}

public final class PinnedHomesAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = PinnedSync.home
  public var publishAfterPull: Bool { true }

  public override init(store: PinnedSyncStore, profileId: String) { super.init(store: store, profileId: profileId) }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(PinnedSync.homeValues(store.state, profileId, pinnedLookups(context)))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await applyKeys(visible, changed, base, records) != .failed
  }

  public func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome {
    let written = try await write { $0.applySyncedPinHomes(profileId, visible, changed, base) }
    return written.map(ApplyOutcome.written) ?? .applied
  }
}

public final class TileFoldersAdapter: PinnedAreaAdapter, SyncAdapter {
  public let prefix = PinnedSync.tileFolder
  let folders: TileFolderMemory

  public init(store: PinnedSyncStore, profileId: String, folders: TileFolderMemory = .shared) {
    self.folders = folders
    super.init(store: store, profileId: profileId)
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    extraction(PinnedSync.tileFolderValues(store.state, profileId, pinnedLookups(context), folders))
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await write { $0.applySyncedTileFolders(profileId, visible, changed) }
  }
}

public func pinnedAreaAdapters(store: PinnedSyncStore, profileId: String, folders: TileFolderMemory = .shared) -> [SyncAdapter] {
  [
    TileFoldersAdapter(store: store, profileId: profileId, folders: folders),
    PinnedRowsAdapter(store: store, profileId: profileId),
    PinnedOrderAdapter(store: store, profileId: profileId),
    GroupLooksAdapter(store: store, profileId: profileId),
    LegacyNamesAdapter(PinnedHomesAdapter(store: store, profileId: profileId)),
    LegacyNamesAdapter(PinnedAdapter(store: store, profileId: profileId)),
  ]
}
