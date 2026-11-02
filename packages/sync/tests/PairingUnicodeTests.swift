import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingUnicodeTests: XCTestCase {
  func testLocalNamesNormalizeToNFCAndPeerNamesMustAlreadyBeNFC() throws {
    for (source, expected) in [
      ("e\u{301}", "\u{e9}"),
      ("\u{1100}\u{1161}\u{11a8}", "\u{ac01}"),
      ("\u{ac00}\u{11a8}", "\u{ac01}"),
      ("A\u{315}\u{300}", "\u{c0}\u{315}"),
      ("\u{301}\u{323}", "\u{323}\u{301}"),
      (String(repeating: "\u{e9}", count: 63) + "e\u{301}", String(repeating: "\u{e9}", count: 64)),
    ] {
      XCTAssertEqual(Data(try PairingUnicode.canonicalName(Data(source.utf8), normalizeLocal: true).utf8), Data(expected.utf8))
      XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(source.utf8)))
      XCTAssertEqual(Data(try PairingUnicode.canonicalName(Data(expected.utf8)).utf8), Data(expected.utf8))
    }
    let blocked = "A\u{305}\u{301}"
    XCTAssertEqual(Data(try PairingUnicode.canonicalName(Data(blocked.utf8)).utf8), Data(blocked.utf8))
    XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(repeating: 0x61, count: 1025), normalizeLocal: true))
  }

  func testLocalNormalizedNameStillHas128ByteLimit() throws {
    let raw = Data(String(repeating: "\u{1fae8}", count: 33).utf8)
    XCTAssertEqual(raw.count, 132)
    XCTAssertThrowsError(try PairingUnicode.canonicalName(raw, normalizeLocal: true))
  }

  func testScalarLimitCountsScalarsRatherThanGraphemes() throws {
    let name = String(repeating: "A\u{305}\u{301}", count: 22)
    let raw = Data(name.utf8)
    XCTAssertEqual(name.unicodeScalars.count, 66)
    XCTAssertEqual(name.count, 22)
    XCTAssertEqual(raw.count, 110)
    XCTAssertEqual(Data(name.precomposedStringWithCanonicalMapping.utf8), raw)
    for local in [false, true] {
      XCTAssertThrowsError(try PairingUnicode.canonicalName(raw, normalizeLocal: local), "normalizeLocal=\(local)")
    }
  }

  func testUnicode151IsRejectedInBothModesWhenRuntimeKnowsItsAge() throws {
    let scalar = Unicode.Scalar(0x2ebf0)!
    guard let age = scalar.properties.age else { throw XCTSkip("Runtime does not report the age of U+2EBF0; only the Unicode 15.1 witness is skipped") }
    XCTAssertEqual(age.major, 15)
    XCTAssertEqual(age.minor, 1)
    for local in [false, true] {
      XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(String(scalar).utf8), normalizeLocal: local), "normalizeLocal=\(local)")
    }
  }

  func testCanonicalNormalizationPreservesCompatibilityCharactersInBothModes() throws {
    let raw = Data("①".utf8)
    for local in [false, true] {
      XCTAssertEqual(Data(try PairingUnicode.canonicalName(raw, normalizeLocal: local).utf8), raw, "normalizeLocal=\(local)")
    }
  }

  func testRepertoireStopsAtTheOldestSupportedReceiver() throws {
    for name in ["\u{1fae8}", "\u{1f6dc}", "Andrew’s MacBook Pro", "山田のMac"] {
      XCTAssertEqual(Data(try PairingUnicode.canonicalName(Data(name.utf8)).utf8), Data(name.utf8))
    }
    for name in ["\u{1c89}", "\u{1fae9}", "\u{105c9}", "\u{378}", "\u{e000}", "\u{f8ff}", "\u{202e}", "\u{200b}", "\u{feff}A", "\u{2028}", "\u{2029}", "\u{0}"] {
      XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(name.utf8)))
      XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(name.utf8), normalizeLocal: true))
    }
  }

  func testMalformedUTF8IsRefusedRatherThanRepaired() throws {
    for invalid in [Data([0xff]), Data([0xc0, 0xaf]), Data([0xed, 0xa0, 0x80]), Data([0xf0, 0x9f, 0x9b]), Data([0xef, 0xbb, 0xbf, 0x41])] {
      XCTAssertThrowsError(try PairingUnicode.canonicalName(invalid))
      XCTAssertThrowsError(try PairingUnicode.canonicalName(invalid, normalizeLocal: true))
    }
  }

  func testNameByteScalarAndWhitespaceBounds() throws {
    for name in ["a", String(repeating: "\u{e9}", count: 64), "A B"] {
      XCTAssertEqual(Data(try PairingUnicode.canonicalName(Data(name.utf8)).utf8), Data(name.utf8))
    }
    for name in ["", String(repeating: "a", count: 65), String(repeating: "\u{e9}", count: 63) + "\u{20ac}", " A", "A ", "\u{a0}A", "A\u{3000}", "\u{2003}A", "A\nB"] {
      XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(name.utf8)))
    }
  }
}
