import Foundation

public struct HookURLPattern: Sendable, Equatable {
  public static let maxLength = 1024
  public let pattern: String
  let scheme: String
  let host: HookHostPattern?
  let port: Int?
  let path: String

  public init?(_ pattern: String) {
    guard !pattern.isEmpty, pattern.utf8.count <= Self.maxLength else { return nil }
    guard pattern.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "\\") }) else { return nil }
    guard let separator = pattern.range(of: "://") else { return nil }
    let scheme = pattern[..<separator.lowerBound].lowercased()
    guard ["http", "https", "*"].contains(scheme) else { return nil }
    let rest = pattern[separator.upperBound...]
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    var authority = rest[..<slash]
    guard !authority.contains(where: { "@?#".contains($0) }) else { return nil }
    var port: Int?
    if !authority.contains("]"), let colon = authority.lastIndex(of: ":") {
      let text = authority[authority.index(after: colon)...]
      authority = authority[..<colon]
      if text != "*" {
        guard let value = Int(text), value >= 1, value <= 65535, String(value) == text else { return nil }
        port = value
      }
    }
    if authority == "*" {
      host = nil
    } else {
      guard let parsed = HookHostPattern(String(authority)) else { return nil }
      host = parsed
    }
    self.pattern = pattern
    self.scheme = scheme
    self.port = port
    path = String(rest[slash...])
  }

  public func matchesOrigin(_ url: HookURL) -> Bool {
    if scheme != "*" && scheme != url.scheme { return false }
    if let host, !host.matches(url.host) { return false }
    if let port, port != url.effectivePort { return false }
    return true
  }

  public func matches(_ url: HookURL) -> Bool {
    matchesOrigin(url) && Self.glob(path, url.path + url.queryText)
  }

  static func glob(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.utf8)
    let t = Array(text.utf8)
    var pi = 0
    var ti = 0
    var star = -1
    var resume = 0
    while ti < t.count {
      if pi < p.count && p[pi] == UInt8(ascii: "*") {
        star = pi
        pi += 1
        resume = ti
      } else if pi < p.count && p[pi] == t[ti] {
        pi += 1
        ti += 1
      } else if star >= 0 {
        pi = star + 1
        resume += 1
        ti = resume
      } else {
        return false
      }
    }
    while pi < p.count && p[pi] == UInt8(ascii: "*") { pi += 1 }
    return pi == p.count
  }
}

public struct HookHostPattern: Sendable, Equatable {
  public let pattern: String
  let host: String
  let subdomains: Bool

  public init?(_ pattern: String) {
    let lowered = pattern.lowercased()
    let subdomains = lowered.hasPrefix("*.")
    var host = subdomains ? String(lowered.dropFirst(2)) : lowered
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty, HookURL.plainHost(Substring(host)) || HookURL.canonicalIPv6(Substring(host)) else { return nil }
    self.pattern = pattern
    self.host = host
    self.subdomains = subdomains
  }

  public func matches(_ candidate: String) -> Bool {
    candidate == host || (subdomains && candidate.hasSuffix("." + host))
  }
}

public final class HookRegex: @unchecked Sendable {
  public static let maxLength = 1024
  public static let matchLength = 65536
  public static let budget: TimeInterval = 0.05

  public let source: String
  let expression: NSRegularExpression

  public init?(_ source: String) {
    guard !source.isEmpty, source.utf8.count <= Self.maxLength, Self.portable(source),
      let expression = try? NSRegularExpression(pattern: "\\A(?:" + source + ")\\z")
    else { return nil }
    self.source = source
    self.expression = expression
  }

  public var captureGroups: Int { max(0, expression.numberOfCaptureGroups) }

  public enum Outcome: Equatable, Sendable {
    case matched([String?])
    case missed
    case failed
  }

  public func match(_ text: String) -> Outcome {
    let nsText = text as NSString
    guard nsText.length <= Self.matchLength else { return .failed }
    let started = ProcessInfo.processInfo.systemUptime
    var captures: [String?]?
    var overBudget = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: nsText.length)) { result, _, stop in
      if let result {
        captures = (0..<result.numberOfRanges).map { index in
          let found = result.range(at: index)
          return found.location == NSNotFound ? nil : nsText.substring(with: found)
        }
        stop.pointee = true
      } else if ProcessInfo.processInfo.systemUptime - started > Self.budget {
        overBudget = true
        stop.pointee = true
      }
    }
    if overBudget { return .failed }
    return captures.map(Outcome.matched) ?? .missed
  }

  public static func portable(_ source: String) -> Bool {
    let characters = Array(source)
    var index = 0
    var inClass = false
    var groups: [Bool] = []
    func at(_ offset: Int) -> Character? { index + offset < characters.count ? characters[index + offset] : nil }
    func quantifies() {
      if !groups.isEmpty { groups[groups.count - 1] = true }
    }
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        guard let escaped = at(1) else { return false }
        if "AZzQEGhHRXkKpP".contains(escaped) { return false }
        if escaped.isASCII && escaped.isNumber && escaped != "0" { return false }
        if escaped == "x" && at(2) == "{" { return false }
        index += 2
        continue
      }
      if inClass {
        if character == "]" { inClass = false }
        else if character == "[" { return false }
        else if character == "&" && at(1) == "&" { return false }
        index += 1
        continue
      }
      switch character {
      case "[":
        if at(1) == "]" || (at(1) == "^" && at(2) == "]") { return false }
        inClass = true
      case "(":
        if at(1) == "?" {
          guard let kind = at(2) else { return false }
          if kind == ":" {
            index += 2
          } else if kind == "P" || kind == "<" {
            if kind == "P" && at(3) != "<" { return false }
            let nameStart = kind == "P" ? 4 : 3
            guard let first = at(nameStart), first.isASCII, first.isLetter || first == "_" else { return false }
            var offset = nameStart
            while let next = at(offset), next != ">" {
              guard next.isASCII, next.isLetter || next.isNumber || next == "_" else { return false }
              offset += 1
            }
            guard at(offset) == ">" else { return false }
            index += offset
          } else {
            return false
          }
        }
        groups.append(false)
      case ")":
        guard let inner = groups.popLast() else { return false }
        if let next = at(1), inner, "*+{".contains(next) { return false }
        if inner { quantifies() }
      case "*", "+", "?":
        if at(1) == "+" { return false }
        quantifies()
      case "{":
        quantifies()
      case "}":
        if at(1) == "+" { return false }
      default:
        break
      }
      index += 1
    }
    return !inClass && groups.isEmpty
  }
}
