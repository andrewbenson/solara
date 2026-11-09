import Foundation
import SolaraModel
import Synchronization
import Testing

@testable import SolaraSync

struct LedgerScript: Sendable {
  var calls: [JSONValue] = []
  var problems: [String] = []
  var now: Double = 0
  var forced = true
}

final class ScriptedLedgerHost: LedgerPasswordsHost {
  let script = Mutex(LedgerScript())

  func next(_ name: String, _ args: [JSONValue]) -> JSONValue {
    let got: JSONValue = .array(args)
    return script.withLock { s in
      guard !s.calls.isEmpty else {
        s.problems.append("swift called \(name)\(got.text().prefix(200)) after js's calls ran out")
        return .null
      }
      let call = s.calls.removeFirst()
      if call["n"] != .string(name) || call["a"]?.text() != got.text() {
        s.problems.append("host call: swift \(name)\(got.text().prefix(300)) vs js \(call["n"]?.string ?? "")\(call["a"]?.text().prefix(300) ?? "")")
      }
      return call
    }
  }

  func engineProfile(_ profileId: String) -> String { profileId }

  func readMarked(_ engineProfile: String) async throws -> JSONValue? {
    let answer = next("readMarked", [.string(engineProfile)])["r"]
    return answer?.isNull == false ? answer : nil
  }

  func checkSealed(_ values: [LedgerValue]) async throws -> [JSONValue] {
    next("checkSealed", [.array(values.map(\.json))])["r"]?.array ?? []
  }

  func saveSealed(_ engineProfile: String, _ value: LedgerValue, _ replacing: Bool) async throws -> Bool {
    next("saveSealed", [.string(engineProfile), value.json["o"] ?? .null, value.json["u"] ?? .null, value.json["s"] ?? .null, .bool(replacing)])["r"] == .bool(true)
  }

  func deletePassword(_ engineProfile: String, _ origin: String, _ username: String) async throws -> Bool {
    next("deletePassword", [.string(engineProfile), .string(origin), .string(username)])["r"] == .bool(true)
  }

  func writeMark(_ engineProfile: String, _ value: String) async throws {
    let call = next("writeMark", [.string(engineProfile), .string(value)])
    if let message = call["throw"]?.string { throw SyncError(description: message) }
  }

  func readLedgerDocument() -> DocumentRead {
    let answer = next("readLedgerDocument", [])["r"]
    if let contents = answer?["contents"]?.string { return .contents(contents) }
    if let failure = answer?["failure"]?.string { return .failure(failure) }
    return .missing
  }

  func writeLedgerDocument(_ contents: String) { _ = next("writeLedgerDocument", [.string(contents)]) }

  func sleep(_ ms: Double) async { _ = next("sleep", [.number(ms)]) }
}

func ledgerMemoryJSON(_ m: LedgerPasswordsMemory) -> JSONValue {
  let keys = { (set: OrderedSet<JSKey>) in JSONValue.array(set.map { .string($0.text) }) }
  let pairs = { (dict: OrderedDict<JSKey, String>) in JSONValue.array(dict.map { .array([.string($0.key.text), .string($0.value)]) }) }
  return [
    "lastRead": .number(m.lastRead), "quietUntil": .number(m.quietUntil), "unconfirmed": keys(m.unconfirmed), "claimed": keys(m.claimed),
    "held": keys(m.held), "heldDigests": pairs(m.heldDigests), "confirmed": keys(m.confirmed), "restoring": pairs(m.restoring),
    "judgedForFolder": keys(m.judgedForFolder),
  ]
}

@Suite struct LedgerAdapterReplayTests {
  static func load() throws -> [JSONValue] {
    let data = try (Data(contentsOf: Cases.folder.appending(path: "ledgerAdapter.json.deflate")) as NSData).decompressed(using: .zlib) as Data
    return try JSONValue.parse(data)["sessions"]?.array ?? []
  }

  static func pairs(_ json: JSONValue?) -> JSMap<JSONValue> {
    var out = JSMap<JSONValue>()
    for pair in json?.array ?? [] {
      guard let key = pair.array?.first?.string else { continue }
      out[key] = pair.array?.last ?? .null
    }
    return out
  }

  static func context(_ json: JSONValue, now: Double) -> ExtractContext {
    let base = pairs(json["base"])
    let remote = pairs(json["remote"])
    let stamp = pairs(json["stamp"])
    let downloading = json["downloading"] == .bool(true)
    let agreed = json["agreedKeys"]?.array?.compactMap(\.string) ?? []
    let unapplied = OrderedSet(json["unapplied"]?.array?.compactMap(\.string) ?? [])
    return ExtractContext(
      base: { base[$0] }, queued: { _ in false }, now: now, known: { remote.contains($0) }, remote: { remote[$0] }, stamp: { stamp[$0]?.string },
      downloading: { downloading }, agreedKeys: { agreed }, unapplied: { unapplied.contains($0) })
  }

  static func describe(_ extraction: Extraction?, _ universe: [String]) -> JSONValue {
    guard let extraction else { return .null }
    let stamps: [JSONValue] = universe.compactMap { key in
      extraction.stamp?(key).map { .array([.string(key), ["at": .number($0.at), "after": $0.after.map(JSONValue.string) ?? .null]]) }
    }
    return [
      "values": .array(extraction.values.map { .array([.string($0.key), $0.value ?? .null]) }),
      "ignore": .array(universe.filter { extraction.ignore?($0) ?? false }.map(JSONValue.string)),
      "republish": .array(universe.filter { extraction.republish?($0) ?? false }.map(JSONValue.string)),
      "remove": .array(extraction.remove.map(JSONValue.string)),
      "stamp": .array(stamps),
      "reapply": .array(extraction.reapply.map(JSONValue.string)),
    ]
  }

  static func replay(_ session: JSONValue) async -> [String] {
    let host = ScriptedLedgerHost()
    let scope = session["scope"]?.string ?? ""
    let adapter = LedgerPasswordsAdapter(
      host: host, profileId: "A", forced: { host.script.withLock { $0.forced } }, ledgerScope: { scope }, now: { host.script.withLock { $0.now } })
    let origins = ["https://a.example", "https://b.example"]
    let universe = origins.flatMap { o in ["bob", "jos\u{00e9}", "jose\u{0301}", "al"].map { "pw:\(o)\n\($0)" } }
    var last: Extraction? = nil
    var problems: [String] = []
    for (i, op) in (session["ops"]?.array ?? []).enumerated() {
      let now = op["setup"]?["now"]?.number ?? 0
      host.script.withLock { s in
        s.calls = op["hostCalls"]?.array ?? []
        s.problems = []
        s.now = now
        s.forced = op["forced"] == .bool(true)
      }
      var result: JSONValue = .null
      switch op["op"]?.string {
      case "extract":
        do {
          let extraction = try await adapter.extract(context(op["context"] ?? .null, now: now))
          if extraction != nil { last = extraction }
          result = describe(extraction, universe)
        } catch {
          result = ["throw": .string("\(error)")]
        }
      case "apply":
        var visible: [(key: String, value: JSONValue)] = []
        for pair in op["visible"]?.array ?? [] { visible.append((pair.array?.first?.string ?? "", pair.array?.last ?? .null)) }
        let changed = op["changed"]?.array?.compactMap(\.string) ?? []
        do {
          let outcome = try await adapter.applyKeys(visible, changed, { _ in nil }, ApplyRecords(known: { _ in false }, now: now, horizon: 0, joined: true))
          if case .written(let keys) = outcome { result = .array(keys.map(JSONValue.string)) } else { result = .bool(false) }
        } catch {
          result = ["throw": .string("\(error)")]
        }
      case "published":
        last?.published?(op["keys"]?.array?.compactMap(\.string) ?? [], JSMap())
      case "resolveHeld":
        adapter.resolveHeld(op["choice"] == .string("confirm") ? .confirm : .restore)
      default:
        problems.append("op \(i): unknown operation \(op["op"]?.text() ?? "")")
      }
      _ = await adapter.state.withLock { $0.writing }.value
      let label = "seed \(session["seed"]?.text() ?? "") op \(i) \(op["op"]?.string ?? "")"
      let (hostProblems, left) = host.script.withLock { ($0.problems, $0.calls.count) }
      problems += hostProblems.map { "\(label): \($0)" }
      if left > 0 { problems.append("\(label): swift left \(left) of js's host calls unmade, next \(host.script.withLock { $0.calls.first?.text().prefix(200) ?? "" })") }
      if result.text() != (op["result"] ?? .null).text() {
        problems.append("\(label): result swift \(result.text().prefix(400)) vs js \((op["result"] ?? .null).text().prefix(400))")
      }
      if adapter.held() != Int(op["held"]?.number ?? -1) { problems.append("\(label): held swift \(adapter.held()) vs js \(op["held"]?.text() ?? "")") }
      let memory = ledgerMemoryJSON(adapter.memory)
      if memory.text() != (op["memory"] ?? .null).text() {
        problems.append("\(label): memory swift \(memory.text().prefix(400)) vs js \((op["memory"] ?? .null).text().prefix(400))")
      }
      if !problems.isEmpty { return problems }
    }
    return problems
  }

  @Test func recordedSessionsReplay() async throws {
    let sessions = try Self.load()
    #expect(sessions.count > 100)
    var failed: [String] = []
    for session in sessions {
      let problems = await Self.replay(session)
      if !problems.isEmpty { failed.append(problems.prefix(3).joined(separator: "\n")) }
    }
    #expect(failed.isEmpty, "\(failed.count) of \(sessions.count) sessions differ; first:\n\(failed.prefix(3).joined(separator: "\n---\n"))")
  }
}
