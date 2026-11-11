import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct TabMemoryReplyTests {
  @Test func goodRowsKeepZeroFootprintAndMeasurementTime() throws {
    let data = Data(#"{"tabs":[{"tabId":17.0,"bytes":0,"source":"attribution","at":1794000000125},{"tabId":23,"bytes":123456789,"source":"footprint","at":1793999999000}]}"#.utf8)
    let json = try JSONSerialization.jsonObject(with: data)
    let expected: [Int: TabMemoryReading] = [
      17: TabMemoryReading(bytes: 0, source: "attribution", at: Date(timeIntervalSince1970: 1794000000.125)),
      23: TabMemoryReading(bytes: 123456789, source: "footprint", at: Date(timeIntervalSince1970: 1793999999)),
    ]
    #expect(TabMemoryReply.decode(json) == .rows(expected))
  }

  @Test func malformedRowsAreSkippedWithoutLosingGoodRows() {
    let good: [String: Any] = ["tabId": 17, "bytes": 42, "source": "attribution", "at": 1000]
    let invalid: [(String, Any)] = [
      ("tabId", 17.5), ("tabId", true), ("tabId", "17"), ("tabId", Double.infinity),
      ("tabId", Double.nan), ("tabId", Double.greatestFiniteMagnitude),
      ("tabId", NSNumber(value: UInt64.max)),
      ("bytes", -1), ("bytes", true), ("bytes", "42"), ("bytes", Double.infinity), ("bytes", Double.nan),
      ("source", "rss"), ("source", 1),
      ("at", true), ("at", "1000"), ("at", Double.infinity), ("at", Double.nan),
    ]
    var rows: [Any] = invalid.map { key, value in
      var row = good
      row[key] = value
      return row
    }
    for key in ["tabId", "bytes", "source", "at"] {
      var row = good
      row.removeValue(forKey: key)
      rows.append(row)
    }
    var valid = good
    valid["tabId"] = 99
    rows.append(contentsOf: [NSNull(), "row", [Any](), valid])
    let expected = TabMemoryReading(bytes: 42, source: "attribution", at: Date(timeIntervalSince1970: 1))
    #expect(TabMemoryReply.decode(["tabs": rows]) == .rows([99: expected]))
  }

  @Test func unavailableShapesStayDistinctFromAnEmptyMeasurement() {
    let shapes: [Any] = [
      NSNull(), [Any](), "reply", 1, [String: Any](),
      ["tabs": NSNull()], ["tabs": "rows"], ["tabs": ["17": 42]],
      ["error": "the engine has no ac_tabs_memory"],
      ["error": NSNull(), "tabs": [Any]()],
    ]
    for shape in shapes { #expect(TabMemoryReply.decode(shape) == .unavailable) }
    #expect(TabMemoryReply.decode(["tabs": [Any]()]) == .rows([:]))
    #expect(TabMemoryReply.decode(["tabs": [NSNull(), "bad"]]) == .rows([:]))
  }

  @Test func integerNumbersKeepTheirExactIdentity() {
    let ids: [Int] = [9_007_199_254_740_993, Int.max, Int.min]
    let rows: [[String: Any]] = ids.map { ["tabId": NSNumber(value: $0), "bytes": 0, "source": "attribution", "at": 1000] }
    let reading = TabMemoryReading(bytes: 0, source: "attribution", at: Date(timeIntervalSince1970: 1))
    let expected = Dictionary(uniqueKeysWithValues: ids.map { ($0, reading) })
    #expect(TabMemoryReply.decode(["tabs": rows]) == .rows(expected))
  }

  @Test func anIntegralNativeDoubleIsAcceptedAndAFractionIsSkipped() {
    let rows: [[String: Any]] = [
      ["tabId": 17.0, "bytes": 0.0, "source": "footprint", "at": -1000.0],
      ["tabId": 17.5, "bytes": 1.0, "source": "attribution", "at": 1000.0],
    ]
    let expected = TabMemoryReading(bytes: 0, source: "footprint", at: Date(timeIntervalSince1970: -1))
    #expect(TabMemoryReply.decode(["tabs": rows]) == .rows([17: expected]))
  }
}

@Suite struct TabMemoryRequestTests {
  @Test func sessionIdsAreDeduplicatedAndSorted() {
    let request = TabMemoryRequest(asked: [
      "a": (sessionId: 23, document: "a1"),
      "b": (sessionId: 17, document: "b1"),
      "c": (sessionId: 23, document: "c1"),
    ])
    #expect(request.sessionIds == [17, 23])
    #expect(TabMemoryRequest(asked: [:]).sessionIds.isEmpty)
  }

  @Test func onlyAskedTabsStillOnTheSameDocumentReceiveTheirSessionReading() {
    let request = TabMemoryRequest(asked: [
      "a": (sessionId: 17, document: "a1"),
      "alias": (sessionId: 17, document: "alias1"),
      "navigated": (sessionId: 23, document: "n1"),
      "closed": (sessionId: 29, document: "c1"),
      "unmeasured": (sessionId: 31, document: "u1"),
    ])
    let zero = TabMemoryReading(bytes: 0, source: "attribution", at: Date(timeIntervalSince1970: 1))
    let other = TabMemoryReading(bytes: 42, source: "footprint", at: Date(timeIntervalSince1970: 2))
    let current = ["a": "a1", "alias": "alias1", "navigated": "n2", "unmeasured": "u1", "unasked": "x1"]
    let result = request.readings([17: zero, 23: other, 29: other, 37: other], currentDocument: { current[$0] })
    #expect(result == ["a": zero, "alias": zero])
  }

  @Test func emptyRequestsAndEmptyRepliesProduceNoReadings() {
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date(timeIntervalSince1970: 1))
    #expect(TabMemoryRequest(asked: [:]).readings([17: reading], currentDocument: { _ in "g1" }).isEmpty)
    let request = TabMemoryRequest(asked: ["a": (sessionId: 17, document: "g1")])
    #expect(request.readings([:], currentDocument: { _ in "g1" }).isEmpty)
  }
}

@MainActor
@Suite struct TabMemoryKeyTests {
  @Test func aKeySplitsBackIntoItsTabAndDocument() {
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a?b=c")
    #expect(TabMemoryKey.parts(key).tabId == "t1")
    #expect(TabMemoryKey.parts(key).document == "https://example.com/a?b=c")
    #expect(TabMemoryKey.parts("t1").tabId == "t1")
    #expect(TabMemoryKey.parts("t1").document == "")
  }

  @Test func aReadingForOneDocumentIsNotShownForTheNextOne() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "attribution", at: Date())
    cache.query = { keys, reply in reply(Dictionary(uniqueKeysWithValues: keys.map { ($0, reading) })) }
    let a = TabMemoryKey.key(tabId: "t1", document: "https://a.example/")
    let b = TabMemoryKey.key(tabId: "t1", document: "https://b.example/")
    cache.ask(a) { _ in }
    #expect(cache.row(a, sleeping: false) == .bytes(reading.bytes))
    #expect(cache.row(b, sleeping: false) == .unknown)
  }
}

@MainActor
@Suite struct TabMemoryRetentionTests {
  @Test func visitingManyTabsKeepsOnlyRecentReadings() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    cache.query = { keys, reply in reply(Dictionary(uniqueKeysWithValues: keys.map { ($0, reading) })) }
    let keys = (0..<1000).map { TabMemoryKey.key(tabId: "t\($0)", document: "https://example.com/\($0)") }
    for key in keys { cache.ask(key) { _ in } }
    let retained = keys.filter { cache.row($0, sleeping: false) == .bytes(42) }.count
    let keyBytes = keys.filter { cache.row($0, sleeping: false) == .bytes(42) }.reduce(0) { $0 + $1.utf8.count }
    print("hover-retention visits=1000 retained=\(retained) keyBytes=\(keyBytes)")
    #expect(retained <= 128)
    #expect(cache.row(keys[0], sleeping: false) == .unknown)
    #expect(cache.row(keys[999], sleeping: false) == .bytes(42))
  }

  @Test func pendingKeysShareTheSameBoundAsCompletedReadings() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor () -> Void] = []
    var answered: [String] = []
    let keys = (0..<1000).map { TabMemoryKey.key(tabId: "t\($0)", document: "https://example.com/\($0)") }
    cache.query = { keys, reply in
      let key = keys[0]
      if Int(TabMemoryKey.parts(key).tabId.dropFirst())!.isMultiple(of: 2) { reply([key: reading]) }
      else { replies.append { reply([key: reading]) } }
    }
    for key in keys { cache.ask(key) { answered.append($0) } }
    answered.removeAll()
    for reply in replies { reply() }
    let retained = keys.filter { cache.row($0, sleeping: false) == .bytes(42) }.count
    print("hover-mixed visits=1000 retained=\(retained) pendingRepliesAccepted=\(answered.count)")
    #expect(retained == 128)
    #expect(answered.count == 64)
    #expect(cache.row(keys[999], sleeping: false) == .bytes(42))
  }

  @Test func readingAnOlderEntryProtectsItFromTheNextEviction() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    cache.query = { keys, reply in reply(Dictionary(uniqueKeysWithValues: keys.map { ($0, reading) })) }
    for id in 0..<128 { cache.ask("t\(id)") { _ in } }
    #expect(cache.row("t0", sleeping: false) == .bytes(42))
    cache.ask("t128") { _ in }
    #expect(cache.row("t0", sleeping: false) == .bytes(42))
    #expect(cache.row("t1", sleeping: false) == .unknown)
    #expect(cache.row("t128", sleeping: false) == .bytes(42))
  }

  @Test func forgettingAPendingKeyRejectsItsReplyAndAllowsANewRequest() {
    let cache = TabMemoryCache()
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answers.append("old") }
    cache.forget(key)
    cache.ask(key) { _ in answers.append("new") }
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    #expect(answers.isEmpty)
    replies.last?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answers == ["new"])
  }

  @Test func askingANewDocumentRetiresTheOldDocumentsPendingReply() {
    let cache = TabMemoryCache()
    let old = TabMemoryKey.key(tabId: "t1", document: "https://example.com/old")
    let current = TabMemoryKey.key(tabId: "t1", document: "https://example.com/current")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(old) { answers.append($0) }
    cache.ask(current) { answers.append($0) }
    replies[0]([old: reading])
    #expect(cache.row(old, sleeping: false) == .unknown)
    #expect(answers.isEmpty)
    replies[1]([current: reading])
    #expect(cache.row(current, sleeping: false) == .bytes(42))
    #expect(answers == [current])
  }
}

private final class TabMemoryCallbackToken {
  let id: Int
  init(_ id: Int) { self.id = id }
}

private struct WeakTabMemoryCallbackToken {
  weak var value: TabMemoryCallbackToken?
}

@MainActor
@Suite struct TabMemoryStoreLifecycleTests {
  private func store() -> Store {
    var state = BrowserState()
    var window = BrowserWindow(id: "w1", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["t1", "t2"]
    window.activeTabIds["default"] = "t2"
    state.windows[window.id] = window
    state.tabs["t1"] = Tab(id: "t1", windowId: "w1", profileId: "default", url: "https://example.com/a", now: 0)
    state.tabs["t2"] = Tab(id: "t2", windowId: "w1", profileId: "default", url: "https://example.com/other", now: 0)
    return Store(state: state, checksInvariants: false)
  }

  @Test func closingATabRetiresReadingAndPendingReplyWithoutAnotherHover() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    cache.query = { _, answer in answer([key: reading]) }
    cache.ask(key) { _ in }
    cache.query = { _, answer in reply = answer }
    var answered = false
    cache.ask(key) { _ in answered = true }
    _ = try store.dispatch(Command("closeTabs", [["t1"]]))
    #expect(store.state.tabs["t1"] == nil)
    #expect(cache.row(key, sleeping: false) == .unknown)
    reply?([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    #expect(!answered)
  }

  @Test func navigatingAwayAndBackCannotAcceptTheOldDocumentsReply() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answers.append("old") }
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
    cache.ask(key) { _ in answers.append("new") }
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    replies.last?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answers == ["new"])
  }

  @Test func closingAndRecreatingTheSameTabAndURLCannotAcceptTheOldReply() throws {
    let store = store()
    let original = store.state.stateJSON
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answers.append("old") }
    _ = try store.dispatch(Command("closeTabs", [["t1"]]))
    _ = try store.dispatch(Command("applyState", [["tabs": original["tabs"]!, "windows": original["windows"]!]]))
    #expect(store.state.tabs["t1"]?.url == "https://example.com/a")
    cache.ask(key) { _ in answers.append("new") }
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    replies.last?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answers == ["new"])
  }

  private func navigateOffMain(_ store: Store) -> DispatchTimeoutResult {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do {
        _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
        _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
      } catch { Issue.record(error) }
      done.signal()
    }
    return done.wait(timeout: .now() + 2)
  }

  @Test func offMainNavigationInvalidatesBeforeTheMainActorCanDeliverItsCleanup() {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answers.append("old") }
    #expect(navigateOffMain(store) == .success)
    cache.ask(key) { _ in answers.append("new") }
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    replies.last?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answers == ["new"])
  }

  @Test func delayedCleanupPreservesARequestStartedAfterOffMainNavigation() async throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    cache.query = { _, reply in reply([key: reading]) }
    cache.ask(key) { _ in }
    #expect(navigateOffMain(store) == .success)
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    var answered = false
    cache.query = { _, answer in reply = answer }
    cache.ask(key) { _ in answered = true }
    for _ in 0..<20 { await Task.yield() }
    reply?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answered)
  }

  @Test func admissionRechecksTheURLAfterAStoreReadDeliversNavigation() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let listener = store.subscribe { commit in
      guard commit.commands.contains(where: { $0.name == "updateTab" && $0.args.count > 1 && $0.args[1]["title"] == "admission" }) else { return }
      do { _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]])) }
      catch { Issue.record(error) }
    }
    defer { store.unsubscribe(listener) }
    var asked = false
    var answered = false
    cache.query = { _, reply in
      asked = true
      do { _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]])) }
      catch { Issue.record(error) }
      reply([key: TabMemoryReading(bytes: 84, source: "footprint", at: Date())])
    }
    store.enqueueSequenced(Command("updateTab", ["t1", ["title": "admission"]]))
    cache.ask(key) { _ in answered = true }
    #expect(!asked)
    #expect(!answered)
    #expect(cache.row(key, sleeping: false) == .unknown)
  }

  @Test func delayedHistoricalNavigationCannotInvalidateANewerAdmission() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    #expect(store.pauseDeliveryForTesting())
    defer { store.resumeDeliveryForTesting() }
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    var answered = false
    cache.query = { _, answer in reply = answer }
    cache.ask(key) { _ in answered = true }
    store.resumeDeliveryForTesting()
    reply?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answered)
  }

  @Test func anOldReplyWaitsForAlreadyCommittedNavigationInvalidations() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    var answered = false
    cache.query = { _, answer in reply = answer }
    cache.ask(key) { _ in answered = true }
    #expect(store.pauseDeliveryForTesting())
    defer { store.resumeDeliveryForTesting() }
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
    reply?([key: reading])
    #expect(!answered)
    store.resumeDeliveryForTesting()
    #expect(cache.row(key, sleeping: false) == .unknown)
    #expect(!answered)
  }

  @Test func queryAndAnswerCallbacksRunAfterStoreIngressIsReleased() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    func updateFromAnotherThread(_ title: String) -> DispatchTimeoutResult {
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        do { _ = try store.dispatch(Command("updateTab", ["t1", ["title": .string(title)]])) }
        catch { Issue.record(error) }
        done.signal()
      }
      return done.wait(timeout: .now() + 2)
    }
    cache.query = { _, reply in
      #expect(updateFromAnotherThread("query") == .success)
      reply([key: reading])
    }
    var answered = false
    cache.ask(key) { _ in
      #expect(updateFromAnotherThread("answer") == .success)
      answered = true
    }
    #expect(answered)
    #expect(cache.row(key, sleeping: false) == .bytes(42))
  }

  @Test func blockedDeliveryRetainsOnlyRecentKeysAndTheirCallbacks() throws {
    var state = store().state
    let keys = (0..<1000).map { TabMemoryKey.key(tabId: "stress\($0)", document: "https://example.com/\($0)") }
    for id in 0..<1000 {
      let tabId = "stress\(id)"
      state.tabs[tabId] = Tab(id: tabId, windowId: "w1", profileId: "default", url: "https://example.com/\(id)", now: 0)
      state.windows["w1"]?.tabIds.append(tabId)
    }
    let store = Store(state: state, checksInvariants: false)
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    #expect(store.pauseDeliveryForTesting())
    defer { store.resumeDeliveryForTesting() }
    _ = try store.dispatch(Command("updateTab", ["t2", ["title": "blocked"]]))
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var asked: [String] = []
    var answered: [Int] = []
    var tokens: [WeakTabMemoryCallbackToken] = []
    cache.query = { keys, reply in
      asked.append(contentsOf: keys)
      reply(Dictionary(uniqueKeysWithValues: keys.map { ($0, reading) }))
    }
    for (id, key) in keys.enumerated() {
      let token = TabMemoryCallbackToken(id)
      tokens.append(WeakTabMemoryCallbackToken(value: token))
      cache.ask(key) { _ in answered.append(token.id) }
    }
    #expect(asked.isEmpty)
    #expect(tokens.filter { $0.value != nil }.count == 128)
    store.resumeDeliveryForTesting()
    #expect(Set(asked) == Set(keys.suffix(128)))
    #expect(Set(answered) == Set(872..<1000))
    #expect(tokens.allSatisfy { $0.value == nil })
    let retained = keys.filter { cache.row($0, sleeping: false) == .bytes(42) }.count
    print("hover-blocked visits=1000 retained=\(retained) queried=\(asked.count) answered=\(answered.count)")
    #expect(retained == 128)
  }

  @Test func invalidatingOldStatePreservesANewerDeferredAsk() throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    cache.query = { _, reply in reply([key: reading]) }
    cache.ask(key) { _ in }
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answered: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answered.append("old") }
    #expect(store.pauseDeliveryForTesting())
    defer { store.resumeDeliveryForTesting() }
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
    cache.ask(key) { _ in answered.append("new") }
    store.resumeDeliveryForTesting()
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(answered.isEmpty)
    replies.last?([key: reading])
    #expect(answered == ["new"])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
  }

  private func resumeOffMain(_ store: Store) -> DispatchTimeoutResult {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      store.resumeDeliveryForTesting()
      done.signal()
    }
    return done.wait(timeout: .now() + 2)
  }

  @Test func readingAnInvalidatedRowPreservesANewerDeferredAsk() async throws {
    let store = store()
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store)
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    cache.query = { _, reply in reply([key: reading]) }
    cache.ask(key) { _ in }
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    var answered = false
    cache.query = { _, answer in reply = answer }
    #expect(store.pauseDeliveryForTesting())
    defer { store.resumeDeliveryForTesting() }
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/b"]]))
    _ = try store.dispatch(Command("updateTab", ["t1", ["url": "https://example.com/a"]]))
    cache.ask(key) { _ in answered = true }
    #expect(resumeOffMain(store) == .success)
    #expect(cache.row(key, sleeping: false) == .unknown)
    for _ in 0..<20 { await Task.yield() }
    #expect(reply != nil)
    reply?([key: reading])
    #expect(answered)
    #expect(cache.row(key, sleeping: false) == .bytes(42))
  }

  @Test func replacingTheStoreRejectsOldRepliesForTheSameTabAndURL() {
    let cache = TabMemoryCache()
    cache.observeDocuments(in: store())
    let key = TabMemoryKey.key(tabId: "t1", document: "https://example.com/a")
    let reading = TabMemoryReading(bytes: 42, source: "footprint", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    var answers: [String] = []
    cache.query = { _, reply in replies.append(reply) }
    cache.ask(key) { _ in answers.append("old") }
    cache.observeDocuments(in: store())
    cache.ask(key) { _ in answers.append("new") }
    #expect(replies.count == 2)
    replies[0]([key: reading])
    #expect(cache.row(key, sleeping: false) == .unknown)
    replies.last?([key: reading])
    #expect(cache.row(key, sleeping: false) == .bytes(42))
    #expect(answers == ["new"])
    cache.observeDocuments(in: nil)
    #expect(cache.row(key, sleeping: false) == .unknown)
  }
}
