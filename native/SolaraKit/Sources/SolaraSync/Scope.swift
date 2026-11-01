import SolaraModel

public final class ScopeState: @unchecked Sendable {
  public var records = JSMap<SyncRecord>()
  public var base = JSMap<String>()
  public var unapplied: [String] = []
  public var vv = JSMap<Double>()
  public var extra = JSMap<[Double]>()
  public var files = JSMap<FileMeta>()
  public var damaged = JSMap<Double>()
  public var pendingSince: JSMap<Double>? = nil
  public var seq: Double = 0
  public var outbox: [Op] = []
  public var journal: [LogFile]? = nil
  public var seen = JSMap<Double>()
  public var joined = false
  public var awaitRemote: Bool? = nil
  public var applyAs: JSMap<String>? = nil
  public var snapshotAt: Double = 0
  public var pending: Double = 0

  public var unknown = JSONObject()

  var settling: [() -> Void]? = nil
  var waitingAfterPull: Bool? = nil
  var downloadingRecently: Bool? = nil
  var extractedHook: ExtractedHook? = nil

  public init() {}

  public init(json: JSONValue) {
    for (key, value) in json["records"]?.object ?? [:] { records[key] = SyncRecord(json: value) }
    for (key, value) in json["base"]?.object ?? [:] { if let text = value.string { base[key] = text } }
    unapplied = json["unapplied"]?.array?.compactMap(\.string) ?? []
    vv = numbers(json["vv"])
    for (key, value) in json["extra"]?.object ?? [:] { extra[key] = value.array?.compactMap(\.number) ?? [] }
    for (key, value) in json["files"]?.object ?? [:] { files[key] = FileMeta(json: value) }
    damaged = numbers(json["damaged"])
    pendingSince = json["pendingSince"].map(numbers)
    seq = json["seq"]?.number ?? 0
    outbox = (json["outbox"]?.array ?? []).map(Op.init(json:))
    journal = json["journal"]?.array.map { $0.map(LogFile.init(json:)) }
    seen = numbers(json["seen"])
    joined = json["joined"]?.bool ?? false
    awaitRemote = json["awaitRemote"]?.bool
    if let object = json["applyAs"]?.object {
      var out = JSMap<String>()
      for (key, value) in object { if let text = value.string { out[key] = text } }
      applyAs = out
    }
    snapshotAt = json["snapshotAt"]?.number ?? 0
    pending = json["pending"]?.number ?? 0
    for (key, value) in json.object ?? [:] where !ScopeState.knownKeys.contains(where: { $0.jsEquals(key) }) { unknown[key] = value }
  }

  static let knownKeys = [
    "records", "base", "unapplied", "vv", "extra", "files", "damaged", "pendingSince", "seq", "outbox", "journal", "seen", "joined", "awaitRemote",
    "applyAs", "snapshotAt", "pending",
  ]

  public var json: JSONValue {
    var out: JSONObject = [
      "records": .object(records.mapValues(\.json)), "base": .object(base.mapValues(JSONValue.string)), "unapplied": JSONValue(unapplied),
      "vv": .object(vv.mapValues(JSONValue.number)), "extra": .object(extra.mapValues { .array($0.map(JSONValue.number)) }),
      "files": .object(files.mapValues(\.json)), "damaged": .object(damaged.mapValues(JSONValue.number)),
    ]
    if let pendingSince { out["pendingSince"] = .object(pendingSince.mapValues(JSONValue.number)) }
    out["seq"] = .number(seq)
    out["outbox"] = .array(outbox.map(\.json))
    if let journal { out["journal"] = .array(journal.map(\.json)) }
    out["seen"] = .object(seen.mapValues(JSONValue.number))
    out["joined"] = .bool(joined)
    if let awaitRemote { out["awaitRemote"] = .bool(awaitRemote) }
    if let applyAs { out["applyAs"] = .object(applyAs.mapValues(JSONValue.string)) }
    out["snapshotAt"] = .number(snapshotAt)
    out["pending"] = .number(pending)
    for (key, value) in unknown { out[key] = value }
    return .object(out)
  }
}

public protocol SyncTransport: Sendable {
  func write(_ scope: String, _ payload: String) async throws -> String
  func read(_ scope: String, _ known: [String]) async throws -> Listing
  func remove(_ scope: String, _ ids: [String]) async throws
}

public struct Listing: Sendable {
  public var files: [(id: String, payload: String)]
  public var pending: [String]
  public var damaged: [(id: String, age: Double)]
  public var present: [String]

  public init(files: [(id: String, payload: String)], pending: [String], damaged: [(id: String, age: Double)], present: [String]) {
    self.files = files
    self.pending = pending
    self.damaged = damaged
    self.present = present
  }
}

public struct Stamped {
  public var at: Double
  public var after: HLC?

  public init(at: Double, after: HLC? = nil) {
    self.at = at
    self.after = after
  }
}

public struct Extraction {
  public var values: [(key: String, value: JSONValue?)]
  public var ignore: ((String) -> Bool)?
  public var republish: ((String) -> Bool)?
  public var published: (([String]) -> Void)?
  public var stamp: ((String) -> Stamped?)?
  public var remove: [String]
  public var reapply: [String]

  public init(
    values: [(key: String, value: JSONValue?)], ignore: ((String) -> Bool)? = nil, republish: ((String) -> Bool)? = nil,
    published: (([String]) -> Void)? = nil, stamp: ((String) -> Stamped?)? = nil, remove: [String] = [], reapply: [String] = []
  ) {
    self.values = values
    self.ignore = ignore
    self.republish = republish
    self.published = published
    self.stamp = stamp
    self.remove = remove
    self.reapply = reapply
  }
}

public struct ExtractContext {
  public let base: (String) -> JSONValue?
  public let queued: (String) -> Bool
  public let now: Double
  public let known: (String) -> Bool
  public let remote: (String) -> JSONValue?
  public let stamp: (String) -> HLC?
  public let downloading: () -> Bool
  public let agreedKeys: () -> [String]
  public let unapplied: (String) -> Bool

  public init(
    base: @escaping (String) -> JSONValue?, queued: @escaping (String) -> Bool, now: Double, known: @escaping (String) -> Bool,
    remote: @escaping (String) -> JSONValue?, stamp: @escaping (String) -> HLC?, downloading: @escaping () -> Bool = { true },
    agreedKeys: @escaping () -> [String] = { [] }, unapplied: @escaping (String) -> Bool = { _ in false }
  ) {
    self.base = base
    self.queued = queued
    self.now = now
    self.known = known
    self.remote = remote
    self.stamp = stamp
    self.downloading = downloading
    self.agreedKeys = agreedKeys
    self.unapplied = unapplied
  }
}

public struct ApplyRecords {
  public let known: (String) -> Bool
  public let now: Double
  public let horizon: Double
  public let joined: Bool

  public init(known: @escaping (String) -> Bool, now: Double, horizon: Double, joined: Bool) {
    self.known = known
    self.now = now
    self.horizon = horizon
    self.joined = joined
  }
}

public struct ApplyRefusal: Error, Sendable {
  public let refused: [String]

  public init(_ refused: [String]) {
    self.refused = refused
  }
}

public enum ApplyOutcome: Sendable, Equatable {
  case failed
  case applied
  case written([String])
}

public protocol SyncAdapter: AnyObject {
  var prefix: String { get }
  var adoptRemoteOnJoin: Bool { get }
  var publishAfterPull: Bool { get }
  var publishOnlyAfterPull: Bool { get }
  var ownsItsChanges: Bool { get }
  func extract(_ context: ExtractContext) async throws -> Extraction?
  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool?
  func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome
  func editedAt(_ value: JSONValue) -> Double?
}

public extension SyncAdapter {
  var adoptRemoteOnJoin: Bool { false }
  var publishAfterPull: Bool { false }
  var publishOnlyAfterPull: Bool { false }
  var ownsItsChanges: Bool { false }
  func editedAt(_ value: JSONValue) -> Double? { nil }

  func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome {
    try await apply(visible, changed, base, records) == false ? .failed : .applied
  }
}

public typealias ExtractedHook = (_ prefix: String, _ keys: [String], _ ignore: (String) -> Bool) -> Void

public let downloadHoldMs: Double = 10 * 60_000

public struct ScopeOptions {
  public var expired: (String, JSONValue, Double) -> Bool = { _, _, _ in false }
  public var tombstoneTTL: Double = 45 * 86_400_000
  public var compactAfterFiles: Double = 40
  public var compactInterval: Double = 10 * 60_000
  public var pruneGrace: Double = 60 * 60_000
  public var damagedGiveUp: Double = 86_400_000
  public var persist: (([LogFile]) async throws -> Void)? = nil
  public var writtenKeysOnly = false
  public var beforeApply: (([String]) -> Void)? = nil
  public var extracted: ExtractedHook? = nil

  public init() {}
}

public struct SyncError: Error, CustomStringConvertible {
  public let description: String
  public init(description: String) { self.description = description }
}

public func covered(_ vv: JSMap<Double>, _ origin: Origin) -> Bool { vv[device: origin.device] >= origin.seq }

func markApplied(_ state: ScopeState, _ device: String, _ seq: Double) {
  if covered(state.vv, Origin(device, seq)) { return }
  var extra = Set(state.extra[device] ?? [])
  extra.insert(seq)
  var top = state.vv[device: device]
  while extra.remove(top + 1) != nil { top += 1 }
  state.vv[device] = top
  if extra.isEmpty {
    state.extra.removeValue(forKey: device)
  } else {
    state.extra[device] = extra.sorted()
  }
}

func isApplied(_ state: ScopeState, _ origin: Origin) -> Bool {
  covered(state.vv, origin) || (state.extra[origin.device]?.contains(origin.seq) ?? false)
}

func see(_ state: ScopeState, _ device: String, _ at: Double) {
  if let known = state.seen[device], !(at > known) { return }
  state.seen[device] = at
}

func mergeRecord(_ state: ScopeState, _ key: String, _ record: SyncRecord, _ clock: Clock) -> Bool {
  clock.observe(record.h)
  if let current = state.records[key], !jsKeyPrecedes(current.h, record.h) { return false }
  state.records[key] = record
  return true
}

func ingestLog(_ state: ScopeState, _ file: LogFile, _ clock: Clock, _ changed: inout OrderedSet<String>) {
  see(state, file.device, file.at)
  if isApplied(state, Origin(file.device, file.seq)) { return }
  for op in file.ops where mergeRecord(state, op.k, SyncRecord(h: op.h, v: op.v, o: Origin(file.device, file.seq)), clock) { changed.insert(op.k) }
  markApplied(state, file.device, file.seq)
}

public func ingestSnapshot(_ state: ScopeState, _ file: SnapshotFile, _ clock: Clock, _ changed: inout OrderedSet<String>) {
  for (device, at) in file.seen { see(state, device, at) }
  see(state, file.device, file.at)
  for (key, record) in file.records {
    if !state.records.contains(key) && isApplied(state, record.o) { continue }
    if mergeRecord(state, key, record, clock) { changed.insert(key) }
  }
  for (key, record) in state.records where !file.records.contains(key) && covered(file.vv, record.o) {
    state.records.removeValue(forKey: key)
    changed.insert(key)
  }
  for (device, seq) in file.vv where seq > state.vv[device: device] {
    state.vv[device] = seq
    var extra = (state.extra[device] ?? []).filter { $0 > seq }
    var top = seq
    while let first = extra.first, first == top + 1 {
      state.vv[device] = extra.removeFirst()
      top += 1
    }
    if extra.isEmpty { state.extra.removeValue(forKey: device) } else { state.extra[device] = extra }
  }
}

public func visible(_ state: ScopeState, _ prefix: String) -> [(key: String, value: JSONValue)] {
  state.records.compactMap { key, record in !record.v.isNull && key.jsStartsWith(prefix) ? (key, record.v) : nil }
}

func parseBase(_ text: String?) -> JSONValue? {
  guard let text else { return nil }
  return try? JSONValue.parse(text)
}

func settleWhenDurable(_ state: ScopeState, _ settle: @escaping () -> Void) {
  if state.settling == nil { state.settling = [] }
  state.settling!.append(settle)
}

func settleDurable(_ state: ScopeState) {
  guard let queue = state.settling else { return }
  state.settling = nil
  for settle in queue { settle() }
}

func stampedHLC(_ clock: Clock, _ device: String, _ stamped: Stamped) -> HLC {
  let at = clock.at(stamped.at)
  let after = stamped.after.map { hlcAfter($0, device) }
  let h = if let after, jsKeyPrecedes(at, after) { after } else { at }
  clock.observe(h)
  return h
}

func publishAdapter(_ state: ScopeState, _ adapter: SyncAdapter, _ clock: Clock, _ device: String, _ now: Double, beforePull: Bool = false) async throws
  -> OrderedSet<String>
{
  var published = OrderedSet<String>()
  if beforePull && adapter.publishOnlyAfterPull { return published }
  if adapter.adoptRemoteOnJoin && !state.joined { return published }
  if adapter.publishAfterPull && state.waitingAfterPull != false { return published }
  var pendingKeys: Set<JSKey>? = nil
  let queued: (String) -> Bool = { key in
    if pendingKeys == nil { pendingKeys = Set((state.outbox + (state.journal ?? []).flatMap(\.ops)).map { JSKey($0.k) }) }
    return pendingKeys!.contains(JSKey(key))
  }
  let context = ExtractContext(
    base: { parseBase(state.base[$0]) }, queued: queued, now: now, known: { state.records.contains($0) }, remote: { state.records[$0]?.v },
    stamp: { state.records[$0]?.h }, downloading: { state.downloadingRecently != false },
    agreedKeys: { state.base.keys.filter { key in key.jsStartsWith(adapter.prefix) && !state.unapplied.contains(where: { $0.jsEquals(key) }) } },
    unapplied: { key in state.unapplied.contains(where: { $0.jsEquals(key) }) })
  guard let extraction = try await adapter.extract(context) else { return published }
  if let hook = state.extractedHook {
    var keys = OrderedSet<String>()
    for (key, _) in extraction.values { keys.insert(key) }
    hook(adapter.prefix, keys.elements) { extraction.ignore?($0) ?? false }
  }
  func put(_ key: String, _ value: JSONValue) {
    let known = state.records[key]
    let stamped = extraction.stamp?(key)
    let editedAt = known == nil && !value.isNull ? adapter.editedAt(value) : nil
    let h = if let stamped { stampedHLC(clock, device, stamped) } else { editedAt.map(clock.at) ?? clock.tick() }
    if let known, !jsKeyPrecedes(known.h, h) { return }
    state.records[key] = SyncRecord(h: h, v: value, o: Origin(device, state.seq + 1))
    state.outbox.append(Op(k: key, h: h, v: value))
    published.insert(key)
  }
  var extracted = Set<JSKey>()
  for (key, value) in extraction.values {
    guard let value, !value.isNull else { throw SyncError(description: "[sync] \(key): a live value can't be null") }
    extracted.insert(JSKey(key))
    let json = syncCanonical(value)
    if state.base[key] == json && !(extraction.republish?(key) ?? false) { continue }
    state.base[key] = json
    put(key, value)
  }
  for key in state.base.keys {
    if !key.jsStartsWith(adapter.prefix) || extracted.contains(JSKey(key)) || (extraction.ignore?(key) ?? false) { continue }
    state.base.removeValue(forKey: key)
    put(key, .null)
  }
  var removing = OrderedSet<String>()
  for key in extraction.remove { removing.insert(key) }
  for key in removing.elements {
    if !key.jsStartsWith(adapter.prefix) || extracted.contains(JSKey(key)) { continue }
    guard let record = state.records[key], !record.v.isNull else { continue }
    state.base.removeValue(forKey: key)
    put(key, .null)
  }
  var reapplying = OrderedSet<String>()
  for key in extraction.reapply { reapplying.insert(key) }
  for key in reapplying.elements where key.jsStartsWith(adapter.prefix) && !state.unapplied.contains(where: { $0.jsEquals(key) }) { state.unapplied.append(key) }
  if let settle = extraction.published, !published.isEmpty {
    let keys = published.elements
    settleWhenDurable(state) { settle(keys) }
  }
  return published
}

public func publish(_ state: ScopeState, _ adapters: [SyncAdapter], _ clock: Clock, _ device: String, _ now: Double) async throws -> OrderedSet<String> {
  var published = OrderedSet<String>()
  for adapter in adapters { for key in try await publishAdapter(state, adapter, clock, device, now, beforePull: true).elements { published.insert(key) } }
  return published
}

public func flush(_ state: ScopeState, _ transport: SyncTransport, _ scope: String, _ device: String, _ now: Double, _ options: ScopeOptions = ScopeOptions()) async throws {
  if !state.outbox.isEmpty {
    state.seq += 1
    if state.journal == nil { state.journal = [] }
    state.journal!.append(LogFile(device: device, seq: state.seq, at: now, ops: state.outbox))
    state.outbox = []
  }
  guard let journal = state.journal, !journal.isEmpty else { return }
  if let persist = options.persist {
    try await persist(journal)
    settleDurable(state)
  }
  while let file = state.journal?.first {
    let id = try await transport.write(scope, file.json.text())
    state.files[id] = FileMeta(d: file.device, k: .log, s: file.seq, at: file.at)
    state.journal!.removeFirst()
    markApplied(state, file.device, file.seq)
    see(state, file.device, now)
  }
  state.journal = nil
  settleDurable(state)
}

public func restoreJournal(_ state: ScopeState, _ batches: [LogFile], _ clock: Clock, _ written: Double = 0) {
  let saved = state.seq
  for file in batches.stableSorted(by: { $0.seq < $1.seq }) {
    if file.seq <= state.seq { continue }
    if file.seq == saved + 1 { state.outbox = [] }
    for op in file.ops {
      _ = mergeRecord(state, op.k, SyncRecord(h: op.h, v: op.v, o: Origin(file.device, file.seq)), clock)
      if op.v.isNull { state.base.removeValue(forKey: op.k) } else { state.base[op.k] = syncCanonical(op.v) }
    }
    state.seq = file.seq
    if file.seq <= written {
      markApplied(state, file.device, file.seq)
    } else {
      if state.journal == nil { state.journal = [] }
      state.journal!.append(file)
    }
  }
  state.seq = max(state.seq, written)
}

public func writtenSeq(_ state: ScopeState) -> Double { state.seq - Double(state.journal?.count ?? 0) }

enum ParsedFile {
  case log(LogFile)
  case snapshot(SnapshotFile)
}

func parseFile(_ payload: String) -> ParsedFile? {
  guard let json = try? JSONValue.parse(payload), json["v"] == .number(1) else { return nil }
  switch json["kind"]?.string {
  case "log": return .log(LogFile(json: json))
  case "snapshot": return .snapshot(SnapshotFile(json: json))
  default: return nil
  }
}

public func pull(_ state: ScopeState, _ transport: SyncTransport, _ scope: String, _ clock: Clock, _ now: Double, _ options: ScopeOptions = ScopeOptions()) async throws
  -> OrderedSet<String>
{
  let damagedGiveUp = options.damagedGiveUp
  let listing = try await transport.read(scope, state.files.keys)
  var changed = OrderedSet<String>()
  var parsed: [(id: String, file: ParsedFile)] = []
  func bad(_ id: String) {
    state.damaged[id] = min(state.damaged[id] ?? now, now)
    if now - state.damaged[id]! > damagedGiveUp {
      state.files[id] = FileMeta(d: "", k: .bad, at: now)
      state.damaged.removeValue(forKey: id)
    }
  }
  for (id, payload) in listing.files {
    if let file = parseFile(payload) { parsed.append((id, file)) } else { bad(id) }
  }
  for (id, _) in listing.damaged { bad(id) }
  let ordered = parsed.stableSorted { a, b in
    if case .snapshot = a.file, case .log = b.file { return true }
    return false
  }
  for (id, file) in ordered {
    switch file {
    case .snapshot(let snapshot):
      ingestSnapshot(state, snapshot, clock, &changed)
      state.files[id] = FileMeta(d: snapshot.device, k: .snapshot, vv: snapshot.vv, at: snapshot.at)
    case .log(let log):
      ingestLog(state, log, clock, &changed)
      state.files[id] = FileMeta(d: log.device, k: .log, s: log.seq, at: log.at)
    }
    state.damaged.removeValue(forKey: id)
  }
  let present = OrderedSet(listing.present)
  for id in state.files.keys where !present.contains(id) { state.files.removeValue(forKey: id) }
  for id in state.damaged.keys where !present.contains(id) { state.damaged.removeValue(forKey: id) }
  state.pending = Double(listing.pending.count)
  var pendingSince = JSMap<Double>()
  for id in listing.pending { pendingSince[id] = min(state.pendingSince?[id] ?? now, now) }
  state.pendingSince = listing.pending.isEmpty ? nil : pendingSince
  let downloading = pendingSince.values.contains { now - $0 <= damagedGiveUp }
  state.waitingAfterPull = downloading || !state.damaged.isEmpty
  state.downloadingRecently = (pendingSince.values + state.damaged.values).contains { now - $0 <= downloadHoldMs }
  return changed
}

func applyAdapter(
  _ state: ScopeState, _ adapter: SyncAdapter, _ keys: OrderedSet<String>, _ now: Double, _ horizon: Double, _ writtenKeysOnly: Bool,
  _ beforeApply: (([String]) -> Void)?
) async -> [String] {
  let mine = keys.elements.filter { $0.jsStartsWith(adapter.prefix) }
  if mine.isEmpty { return mine }
  let view = visible(state, adapter.prefix)
  if state.applyAs == nil { state.applyAs = JSMap() }
  if state.applyAs![adapter.prefix] == nil { state.applyAs![adapter.prefix] = state.joined ? "joined" : "joining" }
  let records = ApplyRecords(known: { state.records.contains($0) }, now: now, horizon: horizon, joined: state.applyAs![adapter.prefix] == "joined")
  beforeApply?(mine)
  let outcome: ApplyOutcome
  var refused = Set<JSKey>()
  do {
    outcome = try await adapter.applyKeys(view, mine, { parseBase(state.base[$0]) }, records)
  } catch let error as ApplyRefusal {
    refused = Set<JSKey>(error.refused.map(JSKey.init))
    outcome = .applied
  } catch {
    outcome = .failed
  }
  if outcome == .failed { return mine }
  state.applyAs![adapter.prefix] = "joined"
  var shown = JSMap<JSONValue>()
  for (key, value) in view { shown[key] = value }
  let written: Set<JSKey>? = if writtenKeysOnly, case .written(let keys) = outcome { Set(keys.map(JSKey.init)) } else { nil }
  var left: [String] = []
  for key in mine {
    if refused.contains(JSKey(key)) || (written.map { !$0.contains(JSKey(key)) } ?? false) {
      left.append(key)
    } else if let value = shown[key] {
      state.base[key] = syncCanonical(value)
    } else {
      state.base.removeValue(forKey: key)
    }
  }
  return left
}

@discardableResult
public func compact(
  _ state: ScopeState, _ transport: SyncTransport, _ scope: String, _ device: String, _ now: Double, _ options: ScopeOptions = ScopeOptions(),
  force: Bool = false
) async throws -> Bool {
  let count = Double(state.files.count)
  let newestSnapshot = ([state.snapshotAt] + state.files.values.filter { $0.k == .snapshot }.map(\.at)).reduce(-Double.infinity) { jsMax($0, $1) }
  if !force && (count <= options.compactAfterFiles || now - newestSnapshot < options.compactInterval) { return false }
  try await flush(state, transport, scope, device, now, options)
  var records = JSMap<SyncRecord>()
  let tombstoneTTL = state.extra.isEmpty ? options.tombstoneTTL : 2 * options.tombstoneTTL
  for (key, record) in state.records {
    let drop = record.v.isNull ? now - hlcWall(record.h) > tombstoneTTL : options.expired(key, record.v, now)
    if drop { state.records.removeValue(forKey: key) } else { records[key] = record }
  }
  let vv = state.vv
  let file = SnapshotFile(device: device, at: now, vv: vv, seen: state.seen, records: records)
  let id = try await transport.write(scope, file.json.text())
  state.files[id] = FileMeta(d: device, k: .snapshot, vv: vv, at: now)
  state.snapshotAt = now
  func dominated(_ other: JSMap<Double>) -> Bool { other.allSatisfy { d, s in vv[device: d] >= s } }
  let prune = state.files.filter { fileId, f in
    if fileId == id || now - f.at < options.pruneGrace { return false }
    switch f.k {
    case .log: return covered(vv, Origin(f.d, f.s ?? .infinity))
    case .snapshot: return dominated(f.vv ?? JSMap())
    case .bad: return false
    }
  }.keys
  if !prune.isEmpty {
    try await transport.remove(scope, prune)
    for fileId in prune { state.files.removeValue(forKey: fileId) }
  }
  return true
}

func jsMax(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  return max(a, b)
}

public struct CycleResult: Sendable, Equatable {
  public var published: Int
  public var changed: Int
  public var pending: Double
  public var compacted: Bool
}

public func syncScope(
  scope: String, state: ScopeState, transport: SyncTransport, adapters: [SyncAdapter], clock: Clock, device: String, now: () -> Double,
  options: ScopeOptions = ScopeOptions()
) async throws -> CycleResult {
  state.extractedHook = options.extracted
  var published = try await publish(state, adapters, clock, device, now()).count
  try await flush(state, transport, scope, device, now(), options)
  let changed = try await pull(state, transport, scope, clock, now(), options)
  var keys = OrderedSet(state.unapplied)
  for key in changed.elements { keys.insert(key) }
  var unapplied: [String] = []
  for adapter in adapters {
    let late = try await publishAdapter(state, adapter, clock, device, now())
    published += late.count
    for key in state.unapplied where key.jsStartsWith(adapter.prefix) { keys.insert(key) }
    for key in late.elements { keys.remove(key) }
    unapplied += await applyAdapter(state, adapter, keys, now(), 2 * options.tombstoneTTL, options.writtenKeysOnly, options.beforeApply)
  }
  state.unapplied = unapplied + keys.elements.filter { key in !adapters.contains { key.jsStartsWith($0.prefix) } }
  if state.awaitRemote != true || state.seen.keys.contains(where: { $0 != device }) {
    state.joined = true
    state.awaitRemote = nil
  }
  try await flush(state, transport, scope, device, now(), options)
  let compacted = try await compact(state, transport, scope, device, now(), options)
  return CycleResult(published: published, changed: changed.count, pending: state.pending, compacted: compacted)
}
