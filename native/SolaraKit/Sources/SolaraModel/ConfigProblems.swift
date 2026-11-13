import Foundation

public struct ConfigProblem: Error, Sendable, Hashable, Identifiable {
  public let file: String
  public let key: String?
  public let line: Int?
  public let message: String

  public init(file: String, key: String? = nil, line: Int? = nil, message: String) {
    self.file = file
    self.key = key
    self.line = line
    self.message = message
  }

  public var id: String { [file, key ?? "", line.map(String.init) ?? "", message].joined(separator: "\u{1f}") }

  public func place(in location: ConfigLocation?) -> String {
    let path = location?.display(file) ?? file
    return line.map { "\(path), line \($0)" } ?? path
  }

  public var detail: String { key.map { "\($0): \(message)" } ?? message }

  public func summary(in location: ConfigLocation?) -> String { "\(place(in: location)): \(detail)" }

  public static func line(ofOffset offset: Int, in data: Data) -> Int {
    var line = 1
    for byte in data.prefix(max(0, offset)) where byte == UInt8(ascii: "\n") { line += 1 }
    return line
  }

  public static func line(ofKey key: String, after anchor: String? = nil, in data: Data) -> Int? {
    let bytes = [UInt8](data)
    var start = 0
    if let anchor, let found = find(Array("\"\(anchor)\"".utf8), in: bytes, from: 0) { start = found }
    guard let found = find(Array("\"\(key)\"".utf8), in: bytes, from: start) else { return nil }
    return line(ofOffset: found, in: data)
  }

  static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
      if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
      i += 1
    }
    return nil
  }
}

public final class ConfigProblems: @unchecked Sendable {
  public static let shared = ConfigProblems()
  public static let changed = Notification.Name("SolaraConfigProblemsChanged")
  public static let ownerKey = "owner"
  public static let addedKey = "added"

  let lock = NSLock()
  var byOwner: [String: [ConfigProblem]] = [:]
  var order: [String] = []

  public init() {}

  public var all: [ConfigProblem] {
    lock.lock()
    defer { lock.unlock() }
    return order.flatMap { byOwner[$0] ?? [] }
  }

  public func problems(for owner: String) -> [ConfigProblem] {
    lock.lock()
    defer { lock.unlock() }
    return byOwner[owner] ?? []
  }

  @discardableResult
  public func set(_ problems: [ConfigProblem], for owner: String) -> [ConfigProblem] {
    lock.lock()
    let previous = byOwner[owner] ?? []
    if problems.isEmpty {
      byOwner.removeValue(forKey: owner)
      order.removeAll { $0 == owner }
    } else {
      byOwner[owner] = problems
      if !order.contains(owner) { order.append(owner) }
    }
    lock.unlock()
    guard previous != problems else { return [] }
    let known = Set(previous)
    let added = problems.filter { !known.contains($0) }
    NotificationCenter.default.post(
      name: Self.changed, object: self, userInfo: [Self.ownerKey: owner, Self.addedKey: added])
    return added
  }
}
