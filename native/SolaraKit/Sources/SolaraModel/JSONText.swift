import Foundation

public struct JSONParseError: Error, CustomStringConvertible {
  public let offset: Int
  public let reason: String
  public var description: String { "JSON parse error at \(offset): \(reason)" }
}

public extension JSONValue {
  static func parse(_ text: String) throws -> JSONValue {
    var text = text
    return try text.withUTF8 { try parse(bytes: $0) }
  }

  static func parse(_ data: Data) throws -> JSONValue {
    try data.withUnsafeBytes { raw in
      try parse(bytes: UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count))
    }
  }

  static func parse(bytes: UnsafeBufferPointer<UInt8>) throws -> JSONValue {
    var parser = JSONParser(bytes: bytes)
    parser.skipSpace()
    let value = try parser.value(depth: 0)
    parser.skipSpace()
    if parser.at < bytes.count { throw parser.error("trailing characters") }
    return value
  }

  func text(sortedKeys: Bool = false) -> String {
    var out = ""
    out.reserveCapacity(256)
    JSONWriter.write(self, sortedKeys: sortedKeys, into: &out)
    return out
  }

  static func parseBookmark(_ text: String) throws -> JSONValue {
    try parseBookmark(Data(text.utf8))
  }

  static func parseBookmark(_ data: Data) throws -> JSONValue {
    try data.withUnsafeBytes { raw in
      let bytes = UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count)
      var parser = JSONParser(bytes: bytes, bookmarkStrings: true)
      parser.skipSpace()
      let value = try parser.value(depth: 0)
      parser.skipSpace()
      if parser.at < bytes.count { throw parser.error("trailing characters") }
      return value
    }
  }

  func bookmarkText(sortedKeys: Bool = false) -> String {
    var out = ""
    out.reserveCapacity(256)
    JSONWriter.write(self, sortedKeys: sortedKeys, bookmarkStrings: true, into: &out)
    return out
  }

  var canonical: String { text(sortedKeys: true) }
}

public func jsKeyPrecedes(_ a: String, _ b: String) -> Bool {
  a.utf16.lexicographicallyPrecedes(b.utf16)
}

public func jsNumberText(_ value: Double) -> String {
  JSONWriter.number(value)
}

enum JSONWriter {
  static func write(_ value: JSONValue, sortedKeys: Bool, bookmarkStrings: Bool = false, into out: inout String) {
    switch value {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .number(let n): out += number(n)
    case .string(let s):
      if bookmarkStrings { BookmarkString.write(s, into: &out) } else { string(s, into: &out) }
    case .array(let items):
      out += "["
      var first = true
      for item in items {
        if !first { out += "," }
        first = false
        write(item, sortedKeys: sortedKeys, bookmarkStrings: bookmarkStrings, into: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      var first = true
      let keys = sortedKeys ? object.keys.sorted(by: bookmarkStrings ? BookmarkString.precedes : jsKeyPrecedes) : object.keys
      for key in keys {
        if !first { out += "," }
        first = false
        if bookmarkStrings { BookmarkString.write(key, into: &out) } else { string(key, into: &out) }
        out += ":"
        write(object[key]!, sortedKeys: sortedKeys, bookmarkStrings: bookmarkStrings, into: &out)
      }
      out += "}"
    }
  }

  static func string(_ s: String, into out: inout String) {
    out += "\""
    let bytes = s.utf8
    var plainStart = bytes.startIndex
    var index = plainStart
    while index < bytes.endIndex {
      let byte = bytes[index]
      let escape: String?
      switch byte {
      case 0x22: escape = "\\\""
      case 0x5C: escape = "\\\\"
      case 0x08: escape = "\\b"
      case 0x0C: escape = "\\f"
      case 0x0A: escape = "\\n"
      case 0x0D: escape = "\\r"
      case 0x09: escape = "\\t"
      case 0..<0x20:
        let hex = String(byte, radix: 16)
        escape = "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default: escape = nil
      }
      let next = bytes.index(after: index)
      if let escape {
        out += s[plainStart..<index]
        out += escape
        plainStart = next
      }
      index = next
    }
    out += s[plainStart..<bytes.endIndex]
    out += "\""
  }

  static func number(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == 0 { return "0" }
    if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
    let negative = value < 0
    let description = abs(value).description
    var digits: [UInt8] = []
    var pointPosition: Int? = nil
    var exponent = 0
    var sawExponent = false
    var exponentText = ""
    for byte in description.utf8 {
      if sawExponent {
        exponentText.unicodeScalars.append(UnicodeScalar(byte))
      } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
        sawExponent = true
      } else if byte == UInt8(ascii: ".") {
        pointPosition = digits.count
      } else {
        digits.append(byte)
      }
    }
    if sawExponent { exponent = Int(exponentText) ?? 0 }
    var n = (pointPosition ?? digits.count) + exponent
    while let first = digits.first, first == UInt8(ascii: "0"), digits.count > 1 {
      digits.removeFirst()
      n -= 1
    }
    while let last = digits.last, last == UInt8(ascii: "0"), digits.count > 1 {
      digits.removeLast()
    }
    let k = digits.count
    let s = String(decoding: digits, as: UTF8.self)
    var out = negative ? "-" : ""
    if k <= n && n <= 21 {
      out += s + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
      out += String(s.prefix(n)) + "." + String(s.dropFirst(n))
    } else if -6 < n && n <= 0 {
      out += "0." + String(repeating: "0", count: -n) + s
    } else {
      let e = n - 1
      let sign = e < 0 ? "-" : "+"
      if k == 1 {
        out += s + "e" + sign + String(abs(e))
      } else {
        out += String(s.prefix(1)) + "." + String(s.dropFirst(1)) + "e" + sign + String(abs(e))
      }
    }
    return out
  }
}

struct JSONParser {
  let bytes: UnsafeBufferPointer<UInt8>
  var at = 0
  let bookmarkStrings: Bool

  init(bytes: UnsafeBufferPointer<UInt8>, bookmarkStrings: Bool = false) {
    self.bytes = bytes
    self.bookmarkStrings = bookmarkStrings
  }

  func error(_ reason: String) -> JSONParseError {
    JSONParseError(offset: at, reason: reason)
  }

  mutating func skipSpace() {
    while at < bytes.count {
      switch bytes[at] {
      case 0x20, 0x09, 0x0A, 0x0D: at += 1
      default: return
      }
    }
  }

  mutating func value(depth: Int) throws -> JSONValue {
    guard depth < 512 else { throw error("too deep") }
    guard at < bytes.count else { throw error("unexpected end") }
    switch bytes[at] {
    case UInt8(ascii: "{"):
      at += 1
      var object = JSONObject()
      skipSpace()
      if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
        at += 1
        return .object(object)
      }
      while true {
        skipSpace()
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw error("expected key") }
        let key = try string()
        skipSpace()
        guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw error("expected colon") }
        at += 1
        skipSpace()
        let item = try value(depth: depth + 1)
        object[key] = item
        skipSpace()
        guard at < bytes.count else { throw error("unexpected end") }
        if bytes[at] == UInt8(ascii: ",") {
          at += 1
          continue
        }
        if bytes[at] == UInt8(ascii: "}") {
          at += 1
          return .object(object)
        }
        throw error("expected , or }")
      }
    case UInt8(ascii: "["):
      at += 1
      var items: [JSONValue] = []
      skipSpace()
      if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
        at += 1
        return .array(items)
      }
      while true {
        skipSpace()
        items.append(try value(depth: depth + 1))
        skipSpace()
        guard at < bytes.count else { throw error("unexpected end") }
        if bytes[at] == UInt8(ascii: ",") {
          at += 1
          continue
        }
        if bytes[at] == UInt8(ascii: "]") {
          at += 1
          return .array(items)
        }
        throw error("expected , or ]")
      }
    case UInt8(ascii: "\""):
      return .string(try string())
    case UInt8(ascii: "t"):
      try literal("true")
      return .bool(true)
    case UInt8(ascii: "f"):
      try literal("false")
      return .bool(false)
    case UInt8(ascii: "n"):
      try literal("null")
      return .null
    default:
      return .number(try number())
    }
  }

  mutating func literal(_ word: StaticString) throws {
    let count = word.utf8CodeUnitCount
    guard at + count <= bytes.count else { throw error("unexpected end") }
    for i in 0..<count where bytes[at + i] != word.utf8Start[i] { throw error("bad literal") }
    at += count
  }

  mutating func number() throws -> Double {
    let start = at
    if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
    var sawDigit = false
    while at < bytes.count {
      let b = bytes[at]
      if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
        sawDigit = true
        at += 1
      } else if b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E") || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
        at += 1
      } else {
        break
      }
    }
    guard sawDigit else { throw error("bad number") }
    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
    guard let value = Double(text) else { throw error("bad number") }
    return value
  }

  mutating func hex4() throws -> UInt32 {
    guard at + 4 <= bytes.count else { throw error("bad escape") }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let b = bytes[at]
      let digit: UInt32
      switch b {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A") + 10)
      default: throw error("bad escape")
      }
      value = value * 16 + digit
      at += 1
    }
    return value
  }

  mutating func bookmarkString() throws -> String {
    at += 1
    var units: [UInt16] = []
    var start = at
    while at < bytes.count {
      let byte = bytes[at]
      if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") {
        units.append(contentsOf: String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self).utf16)
        at += 1
        if byte == UInt8(ascii: "\"") { return BookmarkString.encode(units: units) }
        guard at < bytes.count else { throw error("bad escape") }
        let escaped = bytes[at]
        at += 1
        switch escaped {
        case UInt8(ascii: "\""): units.append(0x22)
        case UInt8(ascii: "\\"): units.append(0x5C)
        case UInt8(ascii: "/"): units.append(0x2F)
        case UInt8(ascii: "b"): units.append(0x08)
        case UInt8(ascii: "f"): units.append(0x0C)
        case UInt8(ascii: "n"): units.append(0x0A)
        case UInt8(ascii: "r"): units.append(0x0D)
        case UInt8(ascii: "t"): units.append(0x09)
        case UInt8(ascii: "u"): units.append(UInt16(try hex4()))
        default: throw error("bad escape")
        }
        start = at
      } else {
        at += 1
      }
    }
    throw error("unterminated string")
  }

  mutating func string() throws -> String {
    if bookmarkStrings { return try bookmarkString() }
    at += 1
    let start = at
    while at < bytes.count {
      let b = bytes[at]
      if b == UInt8(ascii: "\"") {
        let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
        at += 1
        return s
      }
      if b == UInt8(ascii: "\\") { break }
      at += 1
    }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self).unicodeScalars)
    var pending: [UInt8] = []
    func flush(_ pending: inout [UInt8], into scalars: inout String.UnicodeScalarView) {
      if pending.isEmpty { return }
      scalars.append(contentsOf: String(decoding: pending, as: UTF8.self).unicodeScalars)
      pending.removeAll(keepingCapacity: true)
    }
    while at < bytes.count {
      let b = bytes[at]
      if b == UInt8(ascii: "\"") {
        at += 1
        flush(&pending, into: &scalars)
        return String(scalars)
      }
      if b == UInt8(ascii: "\\") {
        flush(&pending, into: &scalars)
        at += 1
        guard at < bytes.count else { throw error("bad escape") }
        let e = bytes[at]
        at += 1
        switch e {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
          let unit = try hex4()
          if unit >= 0xD800 && unit < 0xDC00, at + 6 <= bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
            let save = at
            at += 2
            let low = try hex4()
            if low >= 0xDC00 && low < 0xE000 {
              scalars.append(UnicodeScalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!)
            } else {
              at = save
              scalars.append("\u{FFFD}")
            }
          } else if let scalar = UnicodeScalar(unit) {
            scalars.append(scalar)
          } else {
            scalars.append("\u{FFFD}")
          }
        default: throw error("bad escape")
        }
        continue
      }
      pending.append(b)
      at += 1
    }
    throw error("unterminated string")
  }
}
