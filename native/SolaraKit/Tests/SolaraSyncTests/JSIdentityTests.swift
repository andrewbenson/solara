import Foundation
import SolaraModel
import SolaraStore
@testable import SolaraSync
import Testing

private final class WritesOne: SyncAdapter {
  let prefix = "pw:"
  let writes: String

  init(writes: String) { self.writes = writes }

  func extract(_ context: ExtractContext) async throws -> Extraction? { nil }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { nil }

  func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws
    -> ApplyOutcome
  {
    .written(changed.filter { $0.jsEquals(writes) })
  }
}

struct JSIdentityTests {
  let nfc = "pw:https://a.example\njos\u{e9}"
  let nfd = "pw:https://a.example\njose\u{301}"

  @Test func aKeyTheAdapterSkippedStaysUnappliedWhenItsCanonicalTwinWasWritten() async {
    let state = ScopeState()
    state.joined = true
    for key in [nfc, nfd] { state.records[key] = SyncRecord(h: "1", v: ["o": "https://a.example", "u": .string(key), "s": "x"], o: Origin("b", 1)) }
    let left = await applyAdapter(state, WritesOne(writes: nfc), OrderedSet([nfc, nfd]), 0, 0, true, nil)
    #expect(left.count == 1 && left[0].jsEquals(nfd), "the login that isn't here is left to apply again")
    #expect(state.base[nfc] != nil)
    #expect(state.base[nfd] == nil, "its base isn't set, so the next cycle can't read the missing login as a deletion here")
  }

  @Test func prefixesCompareAsJSStartsWithDoes() {
    #expect("x:\u{301}abc".jsStartsWith("x:"))
    #expect(!"caf\u{e9}!".jsStartsWith("cafe\u{301}"))
  }

  @Test func aSettingKeyWithACombiningMarkAfterThePrefixAppliesNothing() async throws {
    let store = RecordingStore()
    let adapter = SettingsAdapter(store: store)
    let key = "set:\u{301}appearance"
    _ = try await adapter.apply([(key, ["v": "dark"])], [key], { _ in nil }, ApplyRecords(known: { _ in true }, now: 0, horizon: 0, joined: true))
    #expect(store.commands.isEmpty, "JS reads the name as \"\u{301}appearance\", which isn't a synced setting")
  }

  @Test func syncSourcesKeepJSIdentity() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/SolaraSync").standardized
    let forbidden = [
      #"\.hasPrefix\("#, #"\.hasSuffix\("#, #"(?<![A-Za-z])Set<String>"#, "uniquingKeysWith", #"unapplied\.contains\(key\)"#, #"\.(dropFirst|dropLast|prefix|suffix)\("#,
      #"\.removeLast\(\)"#, #"\.removeFirst\(\)"#, #"(?<![A-Za-z])Set\("#, #"\[String *:"#, #"split\(separator:"#,
    ]
    let allowed: [(file: String, line: String)] = [
      ("StoreAdapters.swift", "for stop in raw.prefix(16) {"),
      ("StoreAdapters.swift", ".prefix(maxDeviceTabs)"),
      ("StoreAdapters.swift", "return Array(hosts.elements.filter(keep).suffix(1000))"),
      ("HostedAdapters.swift", "let times = Array(jsSort(have + fresh, numericOrder).suffix(maxVisitTimes))"),
      ("HostedAdapters.swift", "let times = Array(jsSort(merged, numericOrder).suffix(maxVisitTimes))"),
      ("HostedAdapters.swift", "let kept = Array(list.prefix(maxHistory))"),
      ("HLC.swift", "scalars = scalars.dropFirst()"),
      ("HLC.swift", "return (jsParseInt36(Substring(wall)), jsParseInt36(Substring(counter)), parts.dropFirst(2).joined(separator: \".\"))"),
      ("HLC.swift", "jsParseInt36(Substring(String(h.utf16.prefix(wallDigits)) ?? \"\"))"),
      ("Order.swift", "if n > 0 { return Array(b.prefix(n)) + (try positionBetween(Array(a.dropFirst(n)), Array(b.dropFirst(n)))) }"),
      ("Order.swift", "if let b, b.count > 1 { return Array(b.prefix(1)) }"),
      ("Order.swift", "return orderDigitText(da) + (try positionBetween(Array(a.dropFirst()), nil))"),
      ("EditJournal.swift", "let everSeen = Set(everSeen.map(JSKey.init))"),
      ("EditJournal.swift", "let tombstoned = Set(tombstoned.map(JSKey.init))"),
      ("Scope.swift", "var extra = Set(state.extra[device] ?? [])"),
      ("Scope.swift", "state.vv[device] = extra.removeFirst()"),
      ("Scope.swift", "if pendingKeys == nil { pendingKeys = Set((state.outbox + (state.journal ?? []).flatMap(\\.ops)).map { JSKey($0.k) }) }"),
      ("Scope.swift", "state.journal!.removeFirst()"),
      ("Scope.swift", "let written: Set<JSKey>? = if writtenKeysOnly, case .written(let keys) = outcome { Set(keys.map(JSKey.init)) } else { nil }"),
      ("Extensions.swift", "units = units.dropFirst()"),
      ("Extensions.swift", "return ExtensionApproval(v: known.v, fps: Array((known.fps + [fingerprint]).sorted(by: jsKeyPrecedes).suffix(maxFingerprints))).json"),
      ("PasswordLedger.swift", "let older = entry.d.dropFirst().contains(where: { $0.jsEquals(mine) })"),
      ("PasswordLedger.swift", "out.keys[key] = LedgerEntry(d: Array(([digest] + was.filter { !$0.jsEquals(digest) }).prefix(digestsKept)), h: records[key]?.h, m: jsMin(here.modified, mark.t))"),
    ]
    var found: [String] = []
    var used = Set<Int>()
    let files = FileManager.default.enumerator(atPath: sources.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
    #expect(!files.isEmpty)
    for file in files {
      let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n")
      for (n, line) in lines.enumerated() {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let i = allowed.firstIndex(where: { file == $0.file && text == $0.line }) {
          used.insert(i)
          continue
        }
        for pattern in forbidden where line.range(of: pattern, options: .regularExpression) != nil { found.append("\(file):\(n + 1): \(pattern)") }
      }
    }
    #expect(found.isEmpty, "Swift compares and slices Strings by Character and JS by UTF-16 unit; use jsStartsWith, jsEquals, jsSlice, jsSplit, JSKey, JSMap or OrderedSet: \(found)")
    #expect(used.count == allowed.count, "an allowed line no longer exists: \(allowed.indices.filter { !used.contains($0) }.map { allowed[$0] })")
  }
}

private final class RecordingStore: SyncStore {
  var state = BrowserState()
  var commands: [Command] = []

  func run(_ command: Command) throws { commands.append(command) }
}
