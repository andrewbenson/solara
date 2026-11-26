import SolaraModel

public struct ExtensionSearchRefresh {
  private var read: Set<String> = []
  private var serial: UInt64 = 0
  private var requests: [String: UInt64] = [:]

  public init() {}

  public mutating func listChanged(profile: String) -> [Double] {
    requests.removeValue(forKey: profile)
    return read.insert(profile).inserted ? [0.4, 3] : [0.4]
  }

  public mutating func begin(profile: String) -> UInt64 {
    serial += 1
    requests[profile] = serial
    return serial
  }

  public func current(_ request: UInt64, profile: String) -> Bool {
    requests[profile] == request
  }

  public mutating func invalidate() {
    read.removeAll()
    requests.removeAll()
  }

  public static func merge(profile: String, list: JSONValue?, current: JSONValue?) -> JSONValue? {
    guard let list, list != .null, list["error"] == nil, list.object != nil || list.array != nil else { return nil }
    let engines = extensionEnginesFromChrome(profile: profile, list: list).map { engine -> JSONValue in
      var fields: JSONObject = [
        "profile": .string(engine.profile), "extensionId": .string(engine.extensionId),
        "extensionName": .string(engine.extensionName), "name": .string(engine.name),
        "keyword": .string(engine.keyword), "url": .string(engine.url), "isDefault": .bool(engine.isDefault),
      ]
      if let suggestUrl = engine.suggestUrl { fields["suggestUrl"] = .string(suggestUrl) }
      return .object(fields)
    }
    let before = current?.array ?? []
    let next = JSONValue.array(before.filter { $0["profile"]?.string != profile } + engines)
    guard next != .array(before) else { return nil }
    return next
  }
}
