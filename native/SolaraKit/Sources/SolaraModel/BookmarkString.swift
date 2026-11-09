import Foundation

public enum BookmarkString {
  private static let marker: UInt32 = 0xF0000

  private static func containsMarker(_ value: String) -> Bool { value.unicodeScalars.contains { $0.value == marker } }

  public static func encode(_ value: String) -> String {
    containsMarker(value) ? encode(units: Array(value.utf16)) : value
  }

  public static func encode(units: [UInt16]) -> String {
    var result = String.UnicodeScalarView()
    var at = 0
    while at < units.count {
      let unit = UInt32(units[at])
      if (0xD800..<0xDC00).contains(unit), at + 1 < units.count, (0xDC00..<0xE000).contains(UInt32(units[at + 1])) {
        let scalar = 0x10000 + ((unit - 0xD800) << 10) + UInt32(units[at + 1]) - 0xDC00
        result.append(UnicodeScalar(scalar)!)
        if scalar == marker { result.append(UnicodeScalar(marker)!) }
        at += 2
      } else if (0xD800..<0xE000).contains(unit) {
        result.append(UnicodeScalar(marker)!)
        result.append(UnicodeScalar(marker + 1 + unit - 0xD800)!)
        at += 1
      } else {
        result.append(UnicodeScalar(unit)!)
        at += 1
      }
    }
    return String(result)
  }

  public static func units(_ encoded: String) -> [UInt16] {
    if !containsMarker(encoded) { return Array(encoded.utf16) }
    let scalars = Array(encoded.unicodeScalars)
    var result: [UInt16] = []
    var at = 0
    while at < scalars.count {
      let scalar = scalars[at]
      if scalar.value == marker, at + 1 < scalars.count {
        let next = scalars[at + 1].value
        if next == marker {
          result.append(contentsOf: String(scalar).utf16)
          at += 2
          continue
        }
        if (marker + 1...marker + 0x800).contains(next) {
          result.append(UInt16(0xD800 + next - marker - 1))
          at += 2
          continue
        }
      }
      result.append(contentsOf: String(scalar).utf16)
      at += 1
    }
    return result
  }

  public static func display(_ encoded: String) -> String {
    containsMarker(encoded) ? String(decoding: units(encoded), as: UTF16.self) : encoded
  }

  public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    if !containsMarker(lhs), !containsMarker(rhs) { return lhs.utf16.lexicographicallyPrecedes(rhs.utf16) }
    return units(lhs).lexicographicallyPrecedes(units(rhs))
  }

  static func write(_ encoded: String, into out: inout String) {
    if !containsMarker(encoded) { JSONWriter.string(encoded, into: &out); return }
    let codeUnits = units(encoded)
    var pending: [UInt16] = []
    func flush() {
      guard !pending.isEmpty else { return }
      var text = ""
      JSONWriter.string(String(decoding: pending, as: UTF16.self), into: &text)
      out += text.dropFirst().dropLast()
      pending.removeAll(keepingCapacity: true)
    }
    out += "\""
    var at = 0
    while at < codeUnits.count {
      let unit = codeUnits[at]
      if (0xD800..<0xDC00).contains(unit), at + 1 < codeUnits.count, (0xDC00..<0xE000).contains(codeUnits[at + 1]) {
        pending.append(unit)
        pending.append(codeUnits[at + 1])
        at += 2
      } else if (0xD800..<0xE000).contains(unit) {
        flush()
        out += "\\u" + String(unit, radix: 16)
        at += 1
      } else {
        pending.append(unit)
        at += 1
      }
    }
    flush()
    out += "\""
  }
}
