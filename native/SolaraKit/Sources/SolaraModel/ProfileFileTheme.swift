import Foundation

public struct ProfileFileTheme: Sendable, Hashable {
  public let source: String
  public let name: String
  public internal(set) var own: JSONValue?

  public init(source: String, name: String, own: JSONValue? = nil) {
    self.source = source
    self.name = name
    self.own = own
  }

  public static let replicaKey = "fileTheme"

  var replicaValue: JSONValue {
    var out: JSONObject = ["name": .string(name), "source": .string(source)]
    if let own { out["own"] = own }
    return .object(out)
  }
}

public extension Profile {
  var ownTheme: JSONValue? { fileTheme.map(\.own) ?? theme }

  var own: Profile {
    guard let fileTheme else { return self }
    var copy = self
    copy.theme = fileTheme.own
    copy.fileTheme = nil
    return copy
  }

  var ownJSONValue: JSONValue { own.jsonValue }

  func applyingFileTheme(_ look: JSONValue?, name: String, source: String) -> Profile {
    var next = own
    guard let look else { return next }
    next.fileTheme = ProfileFileTheme(source: source, name: name, own: next.theme)
    next.theme = look
    return next
  }

  func carryingFileTheme(from previous: Profile, themeWritten: Bool) -> Profile {
    guard let fileTheme = previous.fileTheme else { return self }
    var next = self
    var carried = fileTheme
    carried.own = themeWritten ? theme : fileTheme.own
    next.fileTheme = carried
    next.theme = previous.theme
    return next
  }

  mutating func setOwnTheme(_ value: JSONValue?) {
    if fileTheme != nil { fileTheme?.own = value } else { theme = value }
  }
}
