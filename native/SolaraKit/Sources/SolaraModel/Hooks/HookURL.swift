import Foundation

public struct HookURL: Sendable, Equatable {
  public static let maxLength = 2_097_152

  public let scheme: String
  public let host: String
  public let port: Int?
  public let path: String
  public let query: String?
  public let fragment: String?

  public var origin: String { scheme + "://" + host + portText }
  public var portText: String { port.map { ":\($0)" } ?? "" }
  public var effectivePort: Int { port ?? (scheme == "https" ? 443 : 80) }
  public var queryText: String { query.map { "?" + $0 } ?? "" }
  public var fragmentText: String { fragment.map { "#" + $0 } ?? "" }
  public var string: String { origin + path + queryText + fragmentText }

  public init?(_ text: String) {
    guard text.utf8.count <= Self.maxLength else { return nil }
    for byte in text.utf8 where byte <= 0x20 || byte >= 0x7F || byte == UInt8(ascii: "\\") { return nil }
    guard let separator = text.range(of: "://") else { return nil }
    let scheme = text[..<separator.lowerBound].lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    let rest = text[separator.upperBound...]
    let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
    var authority = rest[..<authorityEnd]
    if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
    guard !authority.isEmpty, !authority.contains("%") else { return nil }
    var hostPart = Substring(authority)
    var port: Int?
    if hostPart.hasPrefix("[") {
      guard let close = hostPart.firstIndex(of: "]") else { return nil }
      let after = hostPart[hostPart.index(after: close)...]
      if !after.isEmpty {
        guard after.hasPrefix(":"), let parsed = Self.port(after.dropFirst()) else { return nil }
        port = parsed
      }
      hostPart = hostPart[...close]
      guard Self.canonicalIPv6(hostPart) else { return nil }
    } else {
      if let colon = hostPart.lastIndex(of: ":") {
        guard let parsed = Self.port(hostPart[hostPart.index(after: colon)...]) else { return nil }
        port = parsed
        hostPart = hostPart[..<colon]
      }
      if hostPart.hasSuffix(".") { hostPart = hostPart.dropLast() }
      guard Self.plainHost(hostPart) else { return nil }
    }
    if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) { port = nil }
    var path = ""
    var query: String?
    var fragment: String?
    var tail = rest[authorityEnd...]
    if let hash = tail.firstIndex(of: "#") {
      fragment = String(tail[tail.index(after: hash)...])
      tail = tail[..<hash]
    }
    if let mark = tail.firstIndex(of: "?") {
      query = String(tail[tail.index(after: mark)...])
      tail = tail[..<mark]
    }
    path = tail.isEmpty ? "/" : String(tail)
    self.scheme = scheme
    self.host = hostPart.lowercased()
    self.port = port
    self.path = path
    self.query = query
    self.fragment = fragment
  }

  static func port(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.first != "0" else { return nil }
    guard let value = Int(text), value >= 1, value <= 65535 else { return nil }
    return value
  }

  static func plainHost(_ host: Substring) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("."), !host.contains("..") else { return false }
    let allowed = host.utf8.allSatisfy { byte in
      (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
    }
    guard allowed else { return false }
    guard let last = host.split(separator: ".").last else { return false }
    let lowered = last.lowercased()
    let numeric = lowered.allSatisfy { $0.isASCII && $0.isNumber }
    let hex = lowered.hasPrefix("0x") && lowered.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
    return numeric || hex ? dottedDecimal(host) : true
  }

  static func dottedDecimal(_ host: Substring) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 || (parts.count == 5 && parts.last == "") else { return false }
    for part in parts.prefix(4) {
      guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
      if part.count > 1 && part.first == "0" { return false }
      guard let value = Int(part), value <= 255 else { return false }
    }
    return true
  }

  static func canonicalIPv6(_ bracketed: Substring) -> Bool {
    let inner = bracketed.dropFirst().dropLast()
    guard !inner.isEmpty, inner == inner.lowercased(), !inner.contains("%") else { return false }
    var address = in6_addr()
    guard inet_pton(AF_INET6, String(inner), &address) == 1 else { return false }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return false }
    let printed = buffer.withUnsafeBufferPointer { String(decoding: $0.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    return printed == String(inner)
  }
}
