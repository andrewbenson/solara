import Foundation
import SolaraModel
import SolaraStore
import Synchronization

let ledgerMassChangeAtLeast = 5
let ledgerMarkKey = "solara_sync_ledger"

public enum HeldChoice: Sendable {
  case restore
  case confirm
}

struct LedgerRead: Sendable {
  var local: OrderedDict<String, LocalLogin>
  var mark: Mark?
}

struct StoredLedger: Sendable {
  let object: JSONObject

  var ledger: Ledger { Ledger(json: .object(object)) }
  var held: [String] { object["held"]?.array?.compactMap(\.string) ?? [] }
  var gated: JSONObject { object["gated"]?.object ?? JSONObject() }
  func present(_ key: String) -> JSONValue? { object[key].flatMap { $0 == .null ? nil : $0 } }
}

struct LedgerPasswordsState: Sendable {
  var memory = LedgerPasswordsMemory()
  var extracting = false
  var writing = Task<Bool, Never> { true }
}

public final class LedgerPasswordsAdapter: SyncAdapter, Sendable {
  public let prefix = "pw:"
  public var publishOnlyAfterPull: Bool { true }
  public var ownsItsChanges: Bool { true }
  let host: LedgerPasswordsHost
  let profileId: String
  let forced: @Sendable () -> Bool
  let ledgerScope: @Sendable () -> String
  let now: @Sendable () -> Double
  let state: Mutex<LedgerPasswordsState>

  public init(
    host: LedgerPasswordsHost, profileId: String, forced: @escaping @Sendable () -> Bool, ledgerScope: @escaping @Sendable () -> String,
    now: @escaping @Sendable () -> Double, memory: LedgerPasswordsMemory = LedgerPasswordsMemory()
  ) {
    self.host = host
    self.profileId = profileId
    self.forced = forced
    self.ledgerScope = ledgerScope
    self.now = now
    state = Mutex(LedgerPasswordsState(memory: memory))
  }

  public var memory: LedgerPasswordsMemory { state.withLock { $0.memory } }

  var profile: String { host.engineProfile(profileId) }

  static func keyOf(_ origin: String, _ username: String) -> String { "pw:\(origin)\n\(username)" }

  func ledgerRead() -> LedgerDocumentState { readLedgerDocument(host.readLedgerDocument()) }

  var ledgerWritable: Bool {
    if case .doc = ledgerRead() { return true }
    return false
  }

  func readLedgers() -> JSONObject? {
    guard case .doc(let doc) = ledgerRead() else { return nil }
    return doc
  }

  func storedLedger(_ doc: JSONObject) -> StoredLedger? {
    guard let stored = doc["profiles"]?.object?[profile], let object = stored.object else { return nil }
    return StoredLedger(object: object)
  }

  func rejoined(_ stored: StoredLedger?) -> Bool {
    guard let scope = stored?.object["scope"] else { return false }
    return scope != .string(ledgerScope())
  }

  func ledgerNow() -> (ledger: StoredLedger?, fresh: Bool)? {
    guard let doc = readLedgers() else { return nil }
    let stored = storedLedger(doc)
    let fresh = rejoined(stored)
    return (fresh ? nil : stored, fresh)
  }

  @discardableResult
  func replaceStored(_ doc: JSONObject, _ object: JSONObject) -> Bool {
    var doc = doc
    var profiles = doc["profiles"]?.object ?? JSONObject()
    profiles[profile] = .object(object)
    doc["profiles"] = .object(profiles)
    let text = JSONValue.object(doc).text()
    guard case .doc = readLedgerDocument(text) else { return false }
    host.writeLedgerDocument(text)
    return true
  }

  func saveGated(_ gated: JSONObject) -> Bool {
    guard let doc = readLedgers() else { return false }
    guard let stored = storedLedger(doc), !rejoined(stored) else { return true }
    if (stored.present("gated") ?? .object(JSONObject())).text() == JSONValue.object(gated).text() { return true }
    var object = stored.object
    object["gated"] = .object(gated)
    return replaceStored(doc, object)
  }

  func saveHeld(_ keys: OrderedSet<JSKey>) -> Bool {
    guard let doc = readLedgers() else { return false }
    guard let stored = storedLedger(doc), !rejoined(stored) else { return true }
    let next = keys.map(\.text).jsSortedStrings()
    if (stored.present("held") ?? JSONValue([String]())).text() == JSONValue(next).text() { return true }
    var object = stored.object
    object["held"] = JSONValue(next)
    return replaceStored(doc, object)
  }

  func read() async throws -> LedgerRead? {
    guard let marked = try await host.readMarked(profile), marked.truthy else { return nil }
    var local = OrderedDict<String, LocalLogin>()
    for login in marked["logins"]?.array ?? [] {
      let origin = jsText(login["origin"])
      let username = jsText(login["username"])
      let modified = login["modified"].flatMap { $0 == .null ? nil : $0 } ?? login["created"]
      let at = modified?.number ?? .nan
      var value = JSONObject()
      for (field, from) in [("o", "origin"), ("u", "username"), ("s", "s")] { value[field] = login[from] }
      local[Self.keyOf(origin, username)] = LocalLogin(value: LedgerValue(json: .object(value))!, modified: at)
    }
    return LedgerRead(local: local, mark: parseMark(marked["mark"]?.string))
  }

  func record(_ records: inout OrderedDict<String, LedgerRecord>, _ keys: OrderedSet<String>, _ context: ExtractContext) {
    for key in keys {
      guard let h = context.stamp(key), !h.isEmpty else { continue }
      records[key] = LedgerRecord(v: context.remote(key).flatMap(LedgerValue.init(json:)), h: h)
    }
  }

  @discardableResult
  func write(_ here: LedgerRead, _ records: OrderedDict<String, LedgerRecord>, _ keys: [String], _ newest: Double, _ gone: [String] = []) -> Task<Bool, Never> {
    state.withLock { s in
      let previous = s.writing
      let next = Task {
        _ = await previous.value
        return await self.writeLedger(here, records, keys, newest, gone)
      }
      s.writing = next
      return next
    }
  }

  func writeLedger(_ here: LedgerRead, _ records: OrderedDict<String, LedgerRecord>, _ keys: [String], _ newest: Double, _ gone: [String]) async -> Bool {
    guard let before = state.withLock({ _ in ledgerNow() }) else { return false }
    let ledger = before.ledger?.ledger
    let mark = Mark(L: jsMax(ledger?.L ?? 0, here.mark?.L ?? 0) + 1, t: jsMax(now(), newest))
    do {
      try await host.writeMark(profile, formatMark(mark))
    } catch {
      return false
    }
    return state.withLock { _ in
      guard let doc = readLedgers() else { return false }
      let latest = storedLedger(doc)
      let kept = latest.flatMap { rejoined($0) ? nil : $0 }
      var object = nextLedger(ledger, here.local, records, mark, keys, deletedBeforeUpgrade: gone).json.object ?? JSONObject()
      object["scope"] = .string(ledgerScope())
      object["held"] = kept?.present("held") ?? JSONValue([String]())
      object["gated"] = kept?.present("gated") ?? .object(JSONObject())
      return replaceStored(doc, object)
    }
  }

  public func held() -> Int { state.withLock { $0.memory.held.count } }

  public func resolveHeld(_ choice: HeldChoice) {
    state.withLock { s in
      switch choice {
      case .confirm:
        for key in s.memory.held { s.memory.confirmed.insert(key) }
      case .restore:
        for key in s.memory.held { s.memory.restoring[key] = s.memory.heldDigests[key] ?? "" }
      }
      s.memory.held = OrderedSet()
      _ = saveHeld(s.memory.held)
      s.memory.lastRead = 0
    }
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    let at = now()
    guard ledgerWritable else { return nil }
    let entered = state.withLock { s -> Bool in
      if (at < s.memory.quietUntil || at - s.memory.lastRead < passwordReadInterval) && !forced() { return false }
      if s.extracting { return false }
      s.extracting = true
      return true
    }
    guard entered else { return nil }
    defer { state.withLock { $0.extracting = false } }
    _ = await state.withLock { $0.writing }.value
    guard let here = try await read() else { return nil }
    let localValues = Array(here.local)
    let opens = try await host.checkSealed(localValues.map(\.value.value))
    let unopened = OrderedSet(localValues.indices.filter { !(($0 < opens.count ? opens[$0] : nil) == .bool(true)) }.map { localValues[$0].key })
    state.withLock { $0.memory.lastRead = at }
    guard let decided = ledgerNow() else { return nil }
    let stored = decided.ledger
    let ledger = stored?.ledger
    var records = OrderedDict<String, LedgerRecord>()
    let firstLedger = stored == nil
    record(&records, OrderedSet(here.local.keys + (ledger?.keys.keys ?? []) + (firstLedger ? context.agreedKeys() : [])), context)
    var j = judge(
      here.local, decided.fresh ? nil : here.mark, ledger, records, at, agreedHere: { context.base($0).flatMap(LedgerValue.init(json:)) },
      unapplied: context.unapplied)
    let deletedBeforeUpgrade = j.deletedBeforeUpgrade.elements
    let recordOpens = try await host.checkSealed(deletedBeforeUpgrade.map { records[$0]!.v! })
    for (i, key) in deletedBeforeUpgrade.enumerated() where !((i < recordOpens.count ? recordOpens[i] : nil) == .bool(true)) {
      j.deletedBeforeUpgrade.remove(key)
    }
    let decision = state.withLock { s -> (live: [Claim], gated: OrderedSet<String>)? in
      j.claims = j.claims.filter { !unopened.contains($0.key) }
      for key in unopened {
        j.apply.remove(key)
        j.seed.remove(key)
      }
      let keptHeld = OrderedSet(stored?.held ?? [])
      if j.mode == .rebuild {
        for key in keptHeld {
          j.apply.remove(key)
          j.seed.remove(key)
        }
      }
      func lost(_ c: Claim) -> Bool {
        guard let r = records[c.key] else { return false }
        return (c.afterRecord ?? "").isEmpty && jsMin(c.at, at) <= hlcWall(r.h)
      }
      let winning = j.claims.filter { !lost($0) }
      for c in j.claims where lost(c) { j.apply.insert(c.key) }
      let known = ledger?.keys.count ?? 0
      for (key, digest) in s.memory.restoring where !unopened.contains(key.text) && digestOf(here.local[key.text]?.value) == digest {
        j.apply.insert(key.text)
      }
      let changes = winning.filter { ledger?.keys[$0.key] != nil && !s.memory.confirmed.contains(JSKey($0.key)) && !j.apply.contains($0.key) }
      let changed = OrderedSet(changes.map(\.key))
      let stillHeld = keptHeld.filter { key in
        changed.contains(key) || (j.mode == .rebuild && digestOf(here.local[key]?.value) != digestOf(records[key]?.v))
      }
      let mass = changes.count > ledgerMassChangeAtLeast && Double(changes.count) > Double(known) / 2
      let nextHeld = OrderedSet(stillHeld + (mass ? changes.map(\.key) : []))
      let live = winning.filter { !nextHeld.contains($0.key) && !j.apply.contains($0.key) }
      let deletions = live.filter { $0.v == nil }.map(\.key)
      let storedGated = stored?.gated ?? JSONObject()
      var firstGated = JSONObject()
      for key in deletions { firstGated[key] = storedGated[key].flatMap { $0 == .null ? nil : $0 } ?? .number(at) }
      let busy = context.downloading()
      let gated = OrderedSet(busy ? deletions.filter { at - jsNumber(jsPrimitive(firstGated[$0])) < downloadHoldMs } : [])
      let heldKeys = OrderedSet(nextHeld.map(JSKey.init))
      guard saveHeld(heldKeys) else { return nil }
      var keptGated = JSONObject()
      if busy { for (key, value) in firstGated where gated.contains(key) || storedGated[key] != nil { keptGated[key] = value } }
      guard saveGated(keptGated) else { return nil }
      s.memory.restoring = OrderedDict()
      s.memory.confirmed = OrderedSet()
      s.memory.held = heldKeys
      var heldDigests = OrderedDict<JSKey, String>()
      for key in heldKeys { heldDigests[key] = digestOf(here.local[key.text]?.value) }
      s.memory.heldDigests = heldDigests
      s.memory.claimed = OrderedSet(live.map { JSKey($0.key) })
      s.memory.judgedForFolder = OrderedSet(j.apply.elements.map(JSKey.init))
      return (live, gated)
    }
    guard let decision else { return nil }
    var byKey = OrderedDict<String, Claim>()
    for c in decision.live where !decision.gated.contains(c.key) { byKey[c.key] = c }
    let seeds = j.seed.elements.filter { k in j.mode != .consistent || ledger?.keys[k]?.d.first != digestOf(here.local[k]?.value) }
    if j.mode != .consistent || !seeds.isEmpty, !(await write(here, records, seeds, 0, j.deletedBeforeUpgrade.elements).value) { return nil }
    let claims = byKey
    return Extraction(
      values: claims.values.compactMap { c in c.v.map { (c.key, $0.json) } },
      ignore: { claims[$0] == nil },
      republish: { claims[$0] != nil },
      published: { keys, _ in
        self.state.withLock { s in for key in keys { s.memory.claimed.remove(JSKey(key)) } }
        self.write(here, records, keys, 0)
      },
      stamp: { key in claims[key].map { Stamped(at: $0.at, after: $0.afterRecord) } },
      remove: claims.values.filter { $0.v == nil }.map(\.key),
      reapply: j.apply.elements)
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    try await applyKeys(visible, changed, base, records) != .failed
  }

  public func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> ApplyOutcome {
    guard ledgerWritable else { return .failed }
    _ = await state.withLock { $0.writing }.value
    guard let before = try await read() else { return .failed }
    guard let decided = ledgerNow() else { return .failed }
    let ledger = decided.ledger?.ledger
    let shown = shown(visible)
    let wantedValue = { (key: String) in shown[key].flatMap(LedgerValue.init(json:)) }
    let haveHere = changed.filter { before.local[$0] != nil }
    let opens = try await host.checkSealed(haveHere.map { before.local[$0]!.value })
    let unopened = OrderedSet(haveHere.indices.filter { !(($0 < opens.count ? opens[$0] : nil) == .bool(true)) }.map { haveHere[$0] })
    let kept = state.withLock { s in
      OrderedSet(changed.filter { key in
        if unopened.contains(key) || s.memory.claimed.contains(JSKey(key)) || s.memory.held.contains(JSKey(key)) { return true }
        guard let have = before.local[key], !s.memory.judgedForFolder.contains(JSKey(key)) else { return false }
        if let entry = ledger?.keys[key] { return digestOf(have.value) != entry.d.first }
        return digestOf(have.value) != digestOf(wantedValue(key))
      })
    }
    var refused = OrderedSet<String>()
    let engine = profile
    for key in changed where !kept.contains(key) {
      let v = wantedValue(key)
      let have = before.local[key]?.value
      let newline = key.jsIndexOf("\n")
      var ok = true
      if let v, v.json.truthy {
        if have?.json["s"] == v.json["s"] { continue }
        ok = try await host.saveSealed(engine, v, have != nil)
      } else if have != nil {
        ok = try await host.deletePassword(engine, key.jsSlice(3, newline), key.jsSlice(newline + 1)) && ok
      }
      if !ok { refused.insert(key) }
    }
    let wanted = changed.filter { !kept.contains($0) && !refused.contains($0) }
    func confirmed(_ now: LedgerRead?, _ k: String) -> Bool {
      guard let now else { return false }
      return wantedValue(k)?.json["s"] == now.local[k]?.value.json["s"]
    }
    var latest: LedgerRead? = nil
    var settled = false
    var i = 0
    while i < 20 && !settled {
      latest = try await read()
      settled = wanted.allSatisfy { confirmed(latest, $0) }
      if !settled { await host.sleep(250) }
      i += 1
    }
    let failing = OrderedSet(wanted.filter { !confirmed(latest, $0) }.map(JSKey.init))
    let quietAt = now() + 30_000
    state.withLock { s in
      if failing.contains(where: { !s.memory.unconfirmed.contains($0) }) { s.memory.quietUntil = quietAt }
      s.memory.unconfirmed = failing
    }
    guard let latest else { return .failed }
    let written = wanted.filter { confirmed(latest, $0) }
    if !written.isEmpty {
      var writtenRecords = OrderedDict<String, LedgerRecord>()
      for key in written { writtenRecords[key] = LedgerRecord(v: wantedValue(key), h: "") }
      let newest = jsMax(0, written.map { latest.local[$0]?.modified ?? 0 }.reduce(-Double.infinity, jsMax))
      if !(await write(latest, writtenRecords, written, newest).value) { return .failed }
    }
    return .written(written)
  }
}
