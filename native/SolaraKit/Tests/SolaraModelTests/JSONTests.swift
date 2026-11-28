import Foundation
import SolaraModel
import Testing

@Suite struct JSONTextTests {
  @Test func numbersPrintAsJavaScriptDoes() {
    let cases: [(Double, String)] = [
      (0, "0"), (-0.0, "0"), (1, "1"), (-1, "-1"), (0.1, "0.1"), (1.5e-7, "1.5e-7"), (123.456, "123.456"),
      (1e21, "1e+21"), (1e20, "100000000000000000000"), (123456789012345680000, "123456789012345680000"),
      (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (0.000001, "0.000001"),
      (0.0000001, "1e-7"), (1.0 / 3, "0.3333333333333333"), (-2.5e-10, "-2.5e-10"), (1e15, "1000000000000000"),
      (1e16 + 2, "10000000000000002"), (4294967296.5, "4294967296.5"), (190, "190"), (.nan, "null"), (.infinity, "null"),
    ]
    for (value, text) in cases { #expect(jsNumberText(value) == text, "\(value)") }
  }

  @Test func stringsEscapeOnlyWhatJSONStringifyEscapes() {
    let value: JSONValue = .string("a\"b\\c/d\n\t\u{01}é😀\u{2028}")
    #expect(value.text() == "\"a\\\"b\\\\c/d\\n\\t\\u0001é😀\u{2028}\"")
  }

  @Test func parseKeepsKeyOrderWithArrayIndexKeysFirst() throws {
    let value = try JSONValue.parse(#"{"b":1,"a":2,"10":3,"2":4,"02":5,"x":{"z":null,"y":[true,false]}}"#)
    #expect(value.object?.keys == ["2", "10", "b", "a", "02", "x"])
    #expect(value.text() == #"{"2":4,"10":3,"b":1,"a":2,"02":5,"x":{"z":null,"y":[true,false]}}"#)
    #expect(value.canonical == #"{"02":5,"10":3,"2":4,"a":2,"b":1,"x":{"y":[true,false],"z":null}}"#)
  }

  @Test func parseHandlesEscapesAndSurrogatePairs() throws {
    let value = try JSONValue.parse(#"["é😀\/\"\\\b\f\n\r\t", -1.25e2, 1E3]"#)
    #expect(value == .array([.string("é😀/\"\\\u{08}\u{0C}\n\r\t"), .number(-125), .number(1000)]))
  }

  @Test func bookmarkTextKeepsCodeUnitIdentityAndCanonicalKeyOrder() throws {
    let literalMarker = BookmarkString.encode("\u{F0000}")
    let isolatedSurrogate = BookmarkString.encode(units: [0xD800])
    let value: JSONValue = [
      "é": .string(literalMarker), "e\u{301}": .string(isolatedSurrogate),
      "\u{E000}": "nul\u{00}byte", "😀": "escape\n\""
    ]
    #expect(try JSONValue.parseBookmark(value.bookmarkText()) == value)
    #expect(value.bookmarkText(sortedKeys: true) == #"{"é":"\ud800","é":"\#(BookmarkString.display(literalMarker))","😀":"escape\n\"","\#("\u{E000}")":"nul\u0000byte"}"#)
    #expect(Set([JSKey("é"), JSKey("e\u{301}")]).count == 2)
    #expect(JSONValue.string("é") != .string("e\u{301}"))
    #expect(try JSONValue.parseBookmark("\"\u{F0000}\"") == .string(literalMarker))
  }

  @Test func bookmarkValidationMatchesTheCodecLimits() throws {
    let marker = "\u{F0000}"
    let deep = (0..<511).reduce(JSONValue.null) { value, _ in .array([value]) }
    let cases: [JSONValue] = [
      ["valid": .array([.number(.greatestFiniteMagnitude), .number(.leastNonzeroMagnitude), .number(-0.0), .string(BookmarkString.encode(marker))])],
      .string(marker), .object([marker: .null]), .number(.infinity), .number(.nan)
    ]
    for value in cases {
      let roundTrip = (try? JSONValue.parseBookmark(value.bookmarkText())) == value
      #expect(value.isValidBookmarkJSON == roundTrip)
    }
    #expect(deep.isValidBookmarkJSON)
    #expect(!JSONValue.array([deep]).isValidBookmarkJSON)
  }

  @Test func bookmarkValidationRejectsMarkerStringsThatLoseCodeUnitsWhenWritten() throws {
    let marker = BookmarkString.encode("\u{301}\u{F0000}")
    let escapedSurrogate = BookmarkString.encode(units: [0xD800, 0x0301, 0x0061])
    for text in [marker, escapedSurrogate] {
      for value in [JSONValue.string(text), .object([text: .null])] {
        #expect(try JSONValue.parseBookmark(value.bookmarkText()) != value)
        #expect(!value.isValidBookmarkJSON)
      }
    }
  }

  @Test func parseRejectsBrokenInput() {
    for text in ["{", "[1,]", "{\"a\" 1}", "tru", "\"abc", "1 2", ""] {
      #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
    }
  }

  @Test func reassigningAKeyKeepsItsPlaceAndDeletingMovesItToTheEnd() {
    var map: JSMap<Int> = ["a": 1, "b": 2, "c": 3]
    map["a"] = 9
    #expect(map.keys == ["a", "b", "c"])
    map["a"] = nil
    map["a"] = 1
    #expect(map.keys == ["b", "c", "a"])
  }
}
