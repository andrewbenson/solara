import Foundation

public enum KeepAwakeSites {
  public static let settingKey = "keepAwakeSites"
  public static let adoptedKey = "keepAwakeAdoptedProfiles"
  public static let detailPrefix = "keepAwake:"
  public static let sleepAfterChoices = [15, 30, 60, 120, 240]
  public static let defaultSleepAfterMinutes = 30

  public enum Cover: Equatable, Sendable {
    case none
    case exact(String)
    case parent(String)
  }

  public static func normalized(_ input: String) -> String? {
    var text = input.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
    if text.hasPrefix("[*.]") { text.removeFirst(4) }
    if text.hasPrefix("*.") { text.removeFirst(2) }
    if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
    if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      text = String(text[...close])
      return text.count > 2 && text.dropFirst().dropLast().allSatisfy(isAddressCharacter) ? text : nil
    }
    if text.filter({ $0 == ":" }).count > 1 { return text.allSatisfy(isAddressCharacter) ? "[" + text + "]" : nil }
    if let colon = text.lastIndex(of: ":") { text = String(text[..<colon]) }
    while text.hasPrefix(".") { text.removeFirst() }
    while text.hasSuffix(".") { text.removeLast() }
    guard !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }) else { return nil }
    return text
  }

  private static func isAddressCharacter(_ character: Character) -> Bool {
    character.isHexDigit || character == ":" || character == "."
  }

  public static func cover(of host: String, in sites: [String]) -> Cover {
    guard let host = normalized(host) else { return .none }
    if sites.contains(host) { return .exact(host) }
    let parents = sites.filter { host.hasSuffix("." + $0) }
    guard let parent = parents.max(by: { $0.count < $1.count }) else { return .none }
    return .parent(parent)
  }

  public static func adding(_ site: String, to sites: [String]) -> [String] {
    sites.contains(site) ? sites : sites + [site]
  }

  public static func adopting(_ patterns: [String], into sites: [String]) -> [String] {
    patterns.compactMap(normalized).reduce(sites) { adding($1, to: $0) }
  }

  public static func sites(_ value: JSONValue?) -> [String] {
    value?.array?.compactMap(\.string) ?? []
  }

  public static func sleepAfterMinutes(_ value: JSONValue?) -> Int {
    guard let minutes = value?.int, sleepAfterChoices.contains(minutes) else { return defaultSleepAfterMinutes }
    return minutes
  }
}
