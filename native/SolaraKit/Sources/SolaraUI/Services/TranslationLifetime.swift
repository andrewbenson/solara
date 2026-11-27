import Foundation

public struct TranslationLifetime {
  public enum Phase: String { case idle, translating, translated }

  public struct Receipt: Equatable, Sendable {
    public let document: String
    public let token: String
  }

  public private(set) var receipt: Receipt?
  public private(set) var phase = Phase.idle
  public var source: String?
  public private(set) var target: String?

  public init() {}

  @discardableResult
  public mutating func replace(document: String) -> Receipt {
    let next = Receipt(document: document, token: UUID().uuidString)
    receipt = next
    phase = .idle
    source = nil
    target = nil
    return next
  }

  public func accepts(_ candidate: Receipt) -> Bool { receipt == candidate }

  public mutating func begin(source: String, target: String) -> Receipt? {
    guard let document = receipt?.document else { return nil }
    let next = Receipt(document: document, token: UUID().uuidString)
    receipt = next
    self.source = source
    self.target = target
    phase = .translating
    return next
  }

  @discardableResult
  public mutating func finish(_ candidate: Receipt) -> Bool {
    guard accepts(candidate), phase == .translating else { return false }
    phase = .translated
    return true
  }

  @discardableResult
  public mutating func cancel(_ candidate: Receipt) -> Bool {
    guard accepts(candidate) else { return false }
    receipt = Receipt(document: candidate.document, token: UUID().uuidString)
    phase = .idle
    target = nil
    return true
  }

  public mutating func invalidate() {
    receipt = nil
    source = nil
    phase = .idle
    target = nil
  }

  public static func baseLanguage(_ language: String) -> String {
    let parts = language.lowercased().split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "_" }
    guard let first = parts.first else { return "" }
    guard first == "zh" else { return String(first) }
    return parts.count > 1 && ["hant", "tw", "hk", "mo"].contains(parts[1]) ? "zh-Hant" : "zh-Hans"
  }

  public static func offer(_ language: String?, preferred: [String]) -> String? {
    guard let language, !language.isEmpty, !preferred.map(baseLanguage).contains(baseLanguage(language)) else { return nil }
    return language
  }

  public static func site(_ url: String) -> String? {
    guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()),
      let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  public static func ruleOwner(profile: String, original: String?, privateWindow: Bool) -> String {
    privateWindow ? original ?? profile : profile
  }

  public static func canChangeRule(privateWindow: Bool) -> Bool { !privateWindow }
}
