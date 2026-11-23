import Foundation
import SolaraModel
@testable import SolaraStore
@testable import SolaraSync
import Testing

private let day: Double = 86_400_000

private final class CapFolder: @unchecked Sendable {
  var files: [String: String] = [:]
  var counter = 0
}

private struct CapTransport: SyncTransport, @unchecked Sendable {
  let folder: CapFolder
  func write(_ scope: String, _ payload: String) async throws -> String {
    folder.counter += 1
    let id = "f\(folder.counter)"
    folder.files[id] = payload
    return id
  }
  func read(_ scope: String, _ known: [String]) async throws -> Listing {
    let knownSet = Set(known)
    let files = folder.files.filter { !knownSet.contains($0.key) }.sorted { $0.key < $1.key }.map { (id: $0.key, payload: $0.value) }
    return Listing(files: files, pending: [], damaged: [], present: Array(folder.files.keys))
  }
  func remove(_ scope: String, _ ids: [String]) async throws {
    for id in ids { folder.files[id] = nil }
  }
}

private final class CappedChromeHistory: HistoryHost {
  var chrome: [String: [Double]] = [:]
  var entries: [JSONValue] = []
  var floor: Double?
  func historyReady(_ profileId: String) -> Bool { true }
  func history(_ profileId: String) -> [JSONValue]? { entries }
  func historyFloor(_ profileId: String) -> Double? { floor }
  func setHistoryFloor(_ profileId: String, _ floor: Double) { self.floor = max(self.floor ?? -.infinity, floor) }
  func engineProfile(_ profileId: String) -> String { "" }
  func setHistory(_ profileId: String, _ entries: [JSONValue]) { self.entries = entries }
  func addHistoryVisits(_ engineProfile: String, _ visits: [JSONValue], _ sameVisitMs: Double) async throws -> JSONValue? {
    for v in visits {
      let url = v["url"]?.string ?? ""
      let times = (v["visitTimes"]?.array ?? []).compactMap(\.number)
      chrome[url, default: []] = Array(Set(chrome[url, default: []] + times)).sorted()
    }
    return nil
  }
  func deleteHistoryUrls(_ engineProfile: String, _ urls: [String]) async throws -> JSONValue? {
    for url in urls { chrome[url] = nil }
    return nil
  }
  func readChrome() {
    var out: [JSONValue] = []
    for (url, times) in chrome.sorted(by: { ($0.value.last ?? 0) > ($1.value.last ?? 0) }).prefix(maxHistory) {
      var entry = JSONObject()
      entry["url"] = .string(url)
      entry["title"] = .string(url)
      entry["visits"] = .number(Double(times.count))
      entry["lastVisit"] = .number(times.last ?? 0)
      entry["visitTimes"] = .array(times.map { JSONValue.number($0) })
      out.append(.object(entry))
    }
    entries = out
    if out.count >= maxHistory, let last = out.last?["lastVisit"]?.number { setHistoryFloor("default", last) }
  }
}

private final class CapMac {
  let id: String
  let folder: CapFolder
  let store = Store(checksInvariants: false)
  let host = CappedChromeHistory()
  let state = ScopeState()
  var clock: Clock

  init(_ id: String, _ folder: CapFolder) {
    self.id = id
    self.folder = folder
    clock = Clock(device: id, now: { (Date().timeIntervalSince1970 * 1000).rounded(.down) })
    state.joined = true
  }

  @discardableResult
  func sync(readingChrome: Bool = true) async throws -> CycleResult {
    if readingChrome { host.readChrome() }
    var options = ScopeOptions()
    options.expired = { SolaraSync.historyExpired($0, $1, $2) }
    let adapter = HistoryAdapter(store: store, host: host, profileId: "default", now: { Date().timeIntervalSince1970 * 1000 })
    return try await syncScope(scope: "p", state: state, transport: CapTransport(folder: folder), adapters: [adapter], clock: clock, device: id, now: { Date().timeIntervalSince1970 * 1000 }, options: options)
  }

  func visit(_ url: String, _ at: Double) { host.chrome[url, default: []].append(at) }
  func visits(_ url: String) -> [Double] { host.chrome[url] ?? [] }
  var tombstones: Int { state.records.filter { $0.key.hasPrefix("h:") && $0.value.v == .null }.count }
}

@Suite(.serialized) struct HistoryViewCapTests {
  @Test func anApplyThatPushesSyncedURLsOutOfTheViewPublishesNoTombstones() async throws {
    let folder = CapFolder()
    let a = CapMac("A", folder)
    let b = CapMac("B", folder)
    let c = CapMac("C", folder)
    let base = Date().timeIntervalSince1970 * 1000 - 30 * day
    let aURLs = (0..<3000).map { "https://a\($0).example/" }
    for (i, url) in aURLs.enumerated() { a.visit(url, base + Double(i) * 1000) }
    for i in 0..<3000 { b.visit("https://b\(i).example/", base + 10 * day + Double(i) * 1000) }
    try await a.sync()
    try await c.sync()
    try await c.sync()
    #expect(aURLs.filter { !c.visits($0).isEmpty }.count == 3000)
    try await b.sync()
    try await a.sync()
    #expect(a.host.entries.count == maxHistory)
    try await a.sync(readingChrome: false)
    #expect(a.tombstones == 0)
    try await c.sync()
    #expect(aURLs.filter { c.visits($0).isEmpty }.count == 0)
    #expect(aURLs.filter { a.visits($0).isEmpty }.count == 0)
  }
}
