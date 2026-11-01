import Foundation
import SolaraModel
import SolaraStore
import SolaraSync
import Testing

enum AdapterCases {
  static let folder = ProcessInfo.processInfo.environment["ADAPTER_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Adapters")

  static func load() -> [(file: String, json: JSONObject)] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
    return files.filter { $0.lastPathComponent.hasPrefix("adapters__") && ($0.lastPathComponent.hasSuffix(".json") || $0.lastPathComponent.hasSuffix(".json.deflate")) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .flatMap { url -> [(file: String, json: JSONObject)] in
        guard var data = try? Data(contentsOf: url) else { return [] }
        if url.pathExtension == "deflate" {
          guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else { return [] }
          data = inflated
        }
        guard let document = try? JSONValue.parse(data), let cases = document["cases"]?.array else { return [] }
        let name = url.lastPathComponent.replacingOccurrences(of: ".json.deflate", with: "").replacingOccurrences(of: ".json", with: "")
        var last: JSONObject? = nil
        return cases.map { raw in
          var json = raw.object ?? [:]
          if let delta = json["beforeDelta"]?.object, let base = last {
            json["before"] = .object(applyDelta(delta, to: base))
            json.removeValue(forKey: "beforeDelta")
          }
          if let delta = json["afterDelta"]?.object, let before = json["before"]?.object {
            json["after"] = .object(applyDelta(delta, to: before))
            json.removeValue(forKey: "afterDelta")
          }
          last = json["after"]?.object
          return (name, json)
        }
      }
  }

  static func applyDelta(_ delta: JSONObject, to base: JSONObject) -> JSONObject {
    var out = base
    for (key, change) in delta {
      if change["$absent"] != nil {
        out.removeValue(forKey: key)
      } else if let table = change["$table"]?.object {
        var current = out[key]?.object ?? [:]
        for id in table["remove"]?.array?.compactMap(\.string) ?? [] { current.removeValue(forKey: id) }
        for (id, value) in table["set"]?.object ?? [:] { current[id] = value }
        if let order = table["order"]?.array?.compactMap(\.string) {
          var reordered = JSONObject()
          for id in order { if let value = current[id] { reordered[id] = value } }
          current = reordered
        }
        out[key] = .object(current)
      } else {
        out[key] = change
      }
    }
    return out
  }
}

struct RecordedURLs: WebAddressing {
  let urls: [String: ParsedURL?]
  let prefix: String?

  init(_ json: JSONValue?) {
    var urls: [String: ParsedURL?] = [:]
    for (input, parsed) in json?["urls"]?.object ?? [:] {
      urls[input] = parsed.isNull
        ? .some(nil) : ParsedURL(protocol: parsed["protocol"]?.string ?? "", host: parsed["host"]?.string ?? "", hostname: parsed["hostname"]?.string ?? "")
    }
    self.urls = urls
    prefix = json?["prefix"]?.string
  }

  func resolveInput(_ input: String, searchUrlPrefix: String) -> String { input }
  func searchUrlPrefix(_ settings: Settings) -> String { prefix ?? "https://www.google.com/search?q=%s" }
  func parseURL(_ url: String) -> ParsedURL? { urls[url] ?? PlainWebAddressing().parseURL(url) }
}

let uiOnlySlices = ["find", "selection", "selectionAnchors", "windowUi"]
let uiOnlyUiKeys = ["appDark"]

func replayedState(_ state: JSONValue) -> JSONValue {
  guard var object = state.object else { return state }
  for key in uiOnlySlices { object.removeValue(forKey: key) }
  if var ui = object["ui"]?.object {
    for key in uiOnlyUiKeys { ui.removeValue(forKey: key) }
    object["ui"] = .object(ui)
  }
  return .object(object)
}

func stateDifference(_ swift: JSONObject, _ recorded: JSONValue?) -> String? {
  var swift = swift
  if recorded?["live"] == nil { swift.removeValue(forKey: "live") }
  return adapterDifference(replayedState(.object(swift)), replayedState(recorded ?? .null))
}

func adapterDifference(_ a: JSONValue, _ b: JSONValue, path: String = "") -> String? {
  switch (a, b) {
  case (.object(let x), .object(let y)):
    for key in Set(x.keys).union(y.keys).sorted() {
      guard let l = x[key] else { return "\(path).\(key): missing in swift, js has \(y[key]!.text().prefix(300))" }
      guard let r = y[key] else { return "\(path).\(key): swift has \(l.text().prefix(300)), missing in js" }
      if let d = adapterDifference(l, r, path: "\(path).\(key)") { return d }
    }
    return nil
  case (.array(let x), .array(let y)):
    for i in 0..<min(x.count, y.count) { if let d = adapterDifference(x[i], y[i], path: "\(path)[\(i)]") { return d } }
    return x.count == y.count ? nil : "\(path): swift has \(x.count) items, js has \(y.count)"
  default:
    return a == b ? nil : "\(path): swift \(a.text().prefix(300)) vs js \(b.text().prefix(300))"
  }
}

final class Lookups: @unchecked Sendable {
  var answers: [String: [String: JSONValue?]] = [:]
  var missed: [String] = []

  init(_ json: JSONValue?) {
    for entry in json?.array ?? [] {
      let parts = entry.array ?? []
      guard parts.count >= 2, let kind = parts[0].string, let key = parts[1].string else { continue }
      answers[kind, default: [:]][key] = parts.count > 2 ? .some(parts[2]) : .some(nil)
    }
  }

  func value(_ kind: String, _ key: String) -> JSONValue? {
    guard let answer = answers[kind]?[key] else {
      missed.append("\(kind)(\(key))")
      return nil
    }
    return answer
  }

  func flag(_ kind: String, _ key: String) -> Bool { value(kind, key)?.truthy ?? false }
}

func readArgument(_ args: [JSONValue], _ i: Int) -> JSONValue? { i < args.count ? args[i]["read"] : nil }

func makeAdapter(
  _ name: String, _ args: [JSONValue], _ store: Store, _ adopted: @escaping (String) -> Void, folders: TileFolderMemory = TileFolderMemory(),
  host: ScriptedHost? = nil, now: Double = 0, memory: JSONValue? = nil, redesign: Bool = false
) -> SyncAdapter? {
  let links = { (readArgument(args, 0)?.object).map { JSMap($0.map { ($0.key, $0.value) }) } ?? JSMap() }
  switch name {
  case "settingsAdapter": return SettingsAdapter(store: store)
  case "profilesAdapter": return ProfilesAdapter(store: store, links: links)
  case "profileThemesAdapter":
    let records: JSMap<JSONValue>? = readArgument(args, 1)?.object.map { JSMap($0.map { ($0.key, $0.value) }) }
    let given = args.count > 2 && args[2]["callback"]?.truthy == true
    return ProfileThemesAdapter(store: store, links: links, records: { records }, adopted: given ? adopted : { _ in })
  case "sharedDataAdapter": return SharedDataAdapter(store: store, links: links)
  case "deviceAdapter":
    let deviceName = readArgument(args, 1)?.string ?? ""
    return DeviceAdapter(deviceId: args[0].string ?? "", name: { deviceName }, retired: args.count > 2 && args[2].truthy)
  case "deviceTabsAdapter":
    let deviceName = readArgument(args, 2)?.string ?? ""
    return DeviceTabsAdapter(
      store: store, profileId: args[0].string ?? "", deviceId: args[1].string ?? "", name: { deviceName }, retired: args.count > 3 && args[3].truthy)
  case "developerModeAdapter": return DeveloperModeAdapter(store: store, profileId: args[0].string ?? "")
  case "pinnedAdapter": return PinnedAdapter(store: store, profileId: args[0].string ?? "")
  case "pinnedOrderAdapter": return PinnedOrderAdapter(store: store, profileId: args[0].string ?? "")
  case "pinnedRowsAdapter": return PinnedRowsAdapter(store: store, profileId: args[0].string ?? "")
  case "groupLooksAdapter": return GroupLooksAdapter(store: store, profileId: args[0].string ?? "")
  case "pinnedHomesAdapter": return PinnedHomesAdapter(store: store, profileId: args[0].string ?? "")
  case "tileFoldersAdapter": return TileFoldersAdapter(store: store, profileId: args[0].string ?? "", folders: folders)
  case "bookmarksAdapter": return host.map { BookmarksAdapter(host: $0, profileId: args[0].string ?? "") }
  case "historyAdapter": return host.map { HistoryAdapter(store: store, host: $0, profileId: args[0].string ?? "", now: { now }) }
  case "passwordsAdapter":
    let forced = readArgument(args, 1)?.truthy ?? false
    return host.map { PasswordsAdapter(host: $0, profileId: args[0].string ?? "", forced: { forced }, now: { now }, redesign: { redesign }, memory: passwordsMemory(memory)) }
  default: return nil
  }
}

func replayAdapterCase(_ json: JSONObject) async throws -> String?? {
  let now = json["now"]?.number ?? 0
  let store = Store(
    state: try BrowserState(stateJSON: json["before"]?.object ?? [:]), memory: StoreMemory(replayJSON: json["memory"]?.object ?? [:]),
    env: RecordedURLs(json["web"]), config: { () -> StoreConfig in
      var config = StoreConfig()
      config.handOffPinsImmediately = json["config"]?["handOffPinsImmediately"]?.bool ?? true
      if let names = json["config"]?["listeners"]?.array?.compactMap(\.string) { config.listeners = names.compactMap(SettleListener.init(rawValue:)) }
      return config
    }(), clock: { now })
  var adopted: [JSONValue] = []
  let name = json["adapter"]?["name"]?.string ?? ""
  var held: [String: [String]] = [:]
  for (profileId, ids) in json["memory"]?["tileFolders"]?.object ?? [:] { held[profileId] = ids.array?.compactMap(\.string) ?? [] }
  let folders = TileFolderMemory(held)
  let host = json["host"].map { ScriptedHost($0, calls: json["hostCalls"]) }
  guard
    let adapter = makeAdapter(
      name, json["adapter"]?["args"]?.array ?? [], store, { adopted.append([.string($0)]) }, folders: folders, host: host, now: now, memory: json["adapterMemory"],
      redesign: json["redesign"]?.truthy ?? false)
  else { return .some(nil) }
  let lookups = Lookups(json["lookups"])
  var problems: [String] = []
  var stateChecked = false
  if json["call"] == "extract" {
    let context = ExtractContext(
      base: { lookups.value("base", $0) }, queued: { lookups.flag("queued", $0) }, now: json["at"]?.number ?? 0, known: { lookups.flag("known", $0) },
      remote: { lookups.value("remote", $0) }, stamp: { lookups.value("stamp", $0)?.string },
      unapplied: { json["unappliedGiven"]?.bool == true ? lookups.flag("unapplied", $0) : false })
    let extraction = try await adapter.extract(context)
    let expected = json["values"]
    if let extraction {
      let got: JSONValue = .array(extraction.values.map { entry -> JSONValue in
        if let v = entry.value { return .array([.string(entry.key), v]) }
        return .array([.string(entry.key)])
      })
      if expected?.isNull ?? true {
        problems.append("extract: swift returned values, js returned nothing")
      } else if got.text() != expected!.text() {
        problems.append("values: " + (adapterDifference(got, expected!) ?? "same values in another key order: swift \(got.text().prefix(400)) vs js \(expected!.text().prefix(400))"))
      }
      for entry in json["asked"]?.array ?? [] {
        let parts = entry.array ?? []
        guard parts.count == 3, let kind = parts[0].string, let key = parts[1].string else { continue }
        let fn = kind == "ignore" ? extraction.ignore : extraction.republish
        let answer = fn.map { $0(key) }
        if answer.map(JSONValue.bool) != parts[2] && !(answer == nil && parts[2].isNull) {
          problems.append("\(kind)(\(key)): swift \(answer.map(String.init) ?? "no function") vs js \(parts[2].text())")
        }
      }
      if let d = stateDifference(store.state.stateJSON, json["after"]) { problems.append("state after: \(d)") }
      stateChecked = true
      if let published = json["published"]?.array?.compactMap(\.string) {
        if let choices = json["publishedChoices"] {
          try store.dispatch(Command("applyState", [["pinChoices": choices["before"] ?? .null]]))
          extraction.published?(published)
          if let d = adapterDifference(store.state.stateJSON["pinChoices"] ?? .null, choices["after"] ?? .null) { problems.append("pin choices after published: \(d)") }
        } else {
          extraction.published?(published)
        }
      }
      if let recorded = json["memoryAfter"]?["tileFolders"]?.object {
        var want: [String: [String]] = [:]
        for (profileId, ids) in recorded { want[profileId] = ids.array?.compactMap(\.string) ?? [] }
        if folders.snapshot != want { problems.append("tile folders: swift \(folders.snapshot) vs js \(want)") }
      }
      for entry in json["editedAt"]?.array ?? [] {
        guard let parts = entry.array, let value = parts.first else { continue }
        let answer = adapter.editedAt(value).map(JSONValue.number) ?? .null
        let recorded = parts.count > 1 ? parts[1] : .null
        if answer.text() != recorded.text() && !(answer.number?.isNaN == true && recorded.isNull) { problems.append("editedAt(\(value.text().prefix(120))): swift \(answer.text()) vs js \(recorded.text())") }
      }
    } else if !(expected?.isNull ?? true) {
      problems.append("extract: swift returned nothing, js returned \(expected!.text().prefix(300))")
    }
  } else {
    let visible: [(key: String, value: JSONValue)] = (json["visible"]?.array ?? []).compactMap { entry in
      guard let parts = entry.array, parts.count == 2, let key = parts[0].string else { return nil }
      return (key, parts[1])
    }
    let changed = json["changed"]?.array?.compactMap(\.string) ?? []
    let r = json["records"]
    let records = ApplyRecords(known: { lookups.flag("recordKnown", $0) }, now: r?["now"]?.number ?? now, horizon: r?["horizon"]?.number ?? 0, joined: r?["joined"]?.truthy ?? false)
    let expected = json["result"] ?? .null
    let got: JSONValue
    if expected["written"] != nil {
      switch try await adapter.applyKeys(visible, changed, { lookups.value("base", $0) }, records) {
      case .failed: got = false
      case .applied: got = true
      case .written(let keys): got = ["written": .array(keys.map(JSONValue.string))]
      }
    } else {
      got = try await adapter.apply(visible, changed, { lookups.value("base", $0) }, records).map(JSONValue.bool) ?? .null
    }
    if got != expected { problems.append("result: swift \(got.text()) vs js \(expected.text())") }
  }
  if !stateChecked, let d = stateDifference(store.state.stateJSON, json["after"]) { problems.append("state after: \(d)") }
  if let d = memoryDifference(store.memory, json["memoryAfter"]) { problems.append("memory after: \(d)") }
  if let callbacks = json["callbacks"], JSONValue.array(adopted) != callbacks { problems.append("adopted: swift \(JSONValue.array(adopted).text()) vs js \(callbacks.text())") }
  if !lookups.missed.isEmpty { problems.append("asked what js didn't: \(lookups.missed.prefix(4).joined(separator: ", "))") }
  if let host { problems += host.check(json) }
  if let passwords = adapter as? PasswordsAdapter, let recorded = json["adapterMemoryAfter"], passwordsMemoryJSON(passwords.memory).text() != recorded.text() {
    problems.append("passwords memory after: swift \(passwordsMemoryJSON(passwords.memory).text().prefix(300)) vs js \(recorded.text().prefix(300))")
  }
  return .some(problems.isEmpty ? nil : problems.joined(separator: "; "))
}

@Suite struct AdapterReplayTests {
  @Test func everyRecordedAdapterCallReplays() async throws {
    let cases = AdapterCases.load()
    #expect(cases.count > 100)
    var passed: [String: Int] = [:]
    var failed: [String: Int] = [:]
    var unported: [String: Int] = [:]
    var reports: [String] = []
    for (file, json) in cases where json["lossy"] == nil {
      let label = "\(json["adapter"]?["name"]?.string ?? "?") \(json["call"]?.string ?? "")"
      do {
        guard let outcome = try await replayAdapterCase(json) else { continue }
        guard let problem = outcome else {
          if makeAdapterName(json) { passed[label, default: 0] += 1 } else { unported[label, default: 0] += 1 }
          continue
        }
        failed[label, default: 0] += 1
        if reports.count < 30 { reports.append("\(file): \(json["test"]?.string ?? "") [\(label)]\n    \(problem)") }
      } catch {
        failed[label, default: 0] += 1
        if reports.count < 30 { reports.append("\(file): \(json["test"]?.string ?? "") [\(label)]\n    threw \(error)") }
      }
    }
    var summary = "adapter replay: \(passed.values.reduce(0, +)) passed, \(failed.values.reduce(0, +)) failed, \(unported.values.reduce(0, +)) not ported yet\n"
    for label in Set(passed.keys).union(failed.keys).sorted() { summary += "  \(label): \(passed[label] ?? 0) ok, \(failed[label] ?? 0) failed\n" }
    if !unported.isEmpty { summary += "  not ported: \(unported.keys.sorted().joined(separator: ", "))\n" }
    try? (summary + reports.joined(separator: "\n")).write(
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "solara-adapter-replay.txt"), atomically: true, encoding: .utf8)
    print(summary)
    for report in reports.prefix(12) { print(report) }
    #expect(failed.isEmpty)
  }
}

func makeAdapterName(_ json: JSONObject) -> Bool {
  [
    "settingsAdapter", "profilesAdapter", "profileThemesAdapter", "sharedDataAdapter", "deviceAdapter", "deviceTabsAdapter", "developerModeAdapter",
    "pinnedAdapter", "pinnedOrderAdapter", "pinnedRowsAdapter", "groupLooksAdapter", "pinnedHomesAdapter", "tileFoldersAdapter",
    "bookmarksAdapter", "historyAdapter", "passwordsAdapter",
  ].contains(json["adapter"]?["name"]?.string ?? "")
}

func memoryDifference(_ memory: StoreMemory, _ recorded: JSONValue?) -> String? {
  guard let recorded, recorded.object != nil else { return nil }
  var out: [String] = []
  if let n = recorded["counter"]?.number, Double(memory.ids.counter) != n { out.append("counter swift \(memory.ids.counter) vs js \(jsNumberText(n))") }
  if let n = recorded["navSeq"]?.number, Double(memory.navSeq) != n { out.append("navSeq swift \(memory.navSeq) vs js \(jsNumberText(n))") }
  if let n = recorded["lastPinChoice"]?.number, memory.lastPinChoice != n { out.append("lastPinChoice swift \(jsNumberText(memory.lastPinChoice)) vs js \(jsNumberText(n))") }
  if let n = recorded["fromSyncDepth"]?.number, Double(memory.fromSyncDepth) != n { out.append("fromSyncDepth swift \(memory.fromSyncDepth) vs js \(jsNumberText(n))") }
  if let deletions = recorded["remotePinDeletions"]?.object {
    var want = JSMap<Double>()
    for (k, v) in deletions { want[k] = v.number ?? 0 }
    if want.keys.sorted() != memory.remotePinDeletions.keys.sorted() || want.keys.contains(where: { want[$0] != memory.remotePinDeletions[$0] }) {
      out.append("remotePinDeletions swift \(memory.remotePinDeletions.map { "\($0.key)=\(jsNumberText($0.value))" }) vs js \(want.map { "\($0.key)=\(jsNumberText($0.value))" })")
    }
  }
  return out.isEmpty ? nil : out.joined(separator: ", ")
}
