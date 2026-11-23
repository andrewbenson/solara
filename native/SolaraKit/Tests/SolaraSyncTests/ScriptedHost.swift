import Foundation
import SolaraModel
import SolaraSync

final class ScriptedHost: BookmarksHost, HistoryHost, PasswordsHost, @unchecked Sendable {
  let engine: String
  var bookmarks: JSONValue
  let bookmarksAreReady: Bool
  var entries: [JSONValue]?
  let historyIsReady: Bool
  var floor: Double?
  var calls: [JSONValue]
  var problems: [String] = []

  init(_ json: JSONValue?, calls: JSONValue?) {
    engine = json?["engine"]?.string ?? ""
    bookmarks = json?["bookmarks"] ?? ["nodes": [:], "roots": [:]]
    bookmarksAreReady = json?["bookmarksReady"]?.truthy ?? false
    entries = json?["history"]?.array
    historyIsReady = json?["historyReady"]?.truthy ?? false
    floor = json?["historyFloor"]?.number
    self.calls = calls?.array ?? []
  }

  func next(_ name: String, _ args: [JSONValue]) -> JSONValue? {
    let got: JSONValue = .array(args)
    guard !calls.isEmpty else {
      problems.append("swift called \(name)\(got.text().prefix(200)) after js's calls ran out")
      return nil
    }
    let call = calls.removeFirst()
    if call["n"] != .string(name) || call["a"]?.text() != got.text() {
      problems.append("host call: swift \(name)\(got.text().prefix(300)) vs js \(call["n"]?.string ?? "")\(call["a"]?.text().prefix(300) ?? "")")
    }
    return call["r"]
  }

  func bookmarksReady(_ profileId: String) -> Bool { bookmarksAreReady }
  func setBookmarks(_ value: JSONValue) { bookmarks = value }
  func engineProfile(_ profileId: String) -> String { engine }
  func historyReady(_ profileId: String) -> Bool { historyIsReady }
  func history(_ profileId: String) -> [JSONValue]? { entries }
  func historyFloor(_ profileId: String) -> Double? { floor }
  func setHistoryFloor(_ profileId: String, _ floor: Double) { self.floor = floor }
  func setHistory(_ profileId: String, _ entries: [JSONValue]) { self.entries = entries }

  func addHistoryVisits(_ engineProfile: String, _ visits: [JSONValue], _ sameVisitMs: Double) async throws -> JSONValue? {
    next("addHistoryVisits", [.string(engineProfile), .array(visits), .number(sameVisitMs)])
  }

  func deleteHistoryUrls(_ engineProfile: String, _ urls: [String]) async throws -> JSONValue? {
    next("deleteHistoryUrls", [.string(engineProfile), JSONValue(urls)])
  }

  func readLogins(_ engineProfile: String) async throws -> JSONValue? { next("readLogins", [.string(engineProfile)]) }

  func savePassword(_ engineProfile: String, _ origin: JSONValue?, _ username: JSONValue?, _ password: JSONValue?) async throws -> JSONValue? {
    next("savePassword", [.string(engineProfile), origin ?? .null, username ?? .null, password ?? .null])
  }

  func deletePassword(_ engineProfile: String, _ origin: String, _ username: String) async throws -> JSONValue? {
    next("deletePassword", [.string(engineProfile), .string(origin), .string(username)])
  }

  func sleep(_ ms: Double) async { _ = next("sleep", [.number(ms)]) }

  func check(_ json: JSONObject) -> [String] {
    var out = problems
    if !calls.isEmpty { out.append("js made \(calls.count) more host calls: \(calls.prefix(2).map { $0.text().prefix(200) })") }
    let name = json["adapter"]?["name"]?.string
    if let after = json["hostAfter"] {
      if name == "bookmarksAdapter", let d = adapterDifference(bookmarks, after["bookmarks"] ?? .null) { out.append("bookmarks after: \(d)") }
      if name == "historyAdapter", let d = adapterDifference(entries.map(JSONValue.array) ?? .null, after["history"] ?? .null) { out.append("history after: \(d)") }
    }
    return out
  }
}

func passwordsMemory(_ json: JSONValue?) -> PasswordsMemory {
  PasswordsMemory(
    lastRead: json?["lastRead"]?.number ?? 0, quietUntil: json?["quietUntil"]?.number ?? 0,
    created: (json?["created"]?.array ?? []).compactMap { entry in
      guard let parts = entry.array, let key = parts.first?.string else { return nil }
      return (key, parts.count > 1 ? (parts[1].isNull ? nil : parts[1]) : nil)
    })
}

func passwordsMemoryJSON(_ memory: PasswordsMemory) -> JSONValue {
  [
    "lastRead": .number(memory.lastRead), "quietUntil": .number(memory.quietUntil),
    "created": .array(memory.created.map { .array([.string($0.0), $0.1 ?? .null]) }),
  ]
}
