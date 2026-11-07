import Foundation
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
