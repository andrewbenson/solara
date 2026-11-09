import Foundation
import SolaraModel

public struct BookmarkLaunchInput: Sendable {
  public let documents: JSMap<JSONValue>
  public let legacyPendingEngines: Set<JSKey>
  public init(documents: JSMap<JSONValue> = [:], legacyPendingEngines: Set<JSKey> = []) {
    self.documents = documents
    self.legacyPendingEngines = legacyPendingEngines
  }
}

public struct BookmarkLaunchCache {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func load(profiles: JSMap<String>, defaultProfile: String) -> BookmarkLaunchInput {
    let regularProfiles = profiles.filter { profile, _ in !profile.hasPrefix("incognito:") }
    let activeEngines = Set(regularProfiles.values.map(JSKey.init))
    let legacyPath = directory.appendingPathComponent("bookmarks.json")
    let legacyExists = FileManager.default.fileExists(atPath: legacyPath.path)
    let legacy = read(legacyPath)
    let legacyPending = legacyExists && legacy?.truthy != false ? activeEngines : []
    func aliases(_ engine: String) -> [String] { regularProfiles.filter { _, mapped in JSKey(mapped) == JSKey(engine) }.keys }
    var cached: JSMap<JSONValue> = [:]
    if let cache = read(directory.appendingPathComponent("bookmarks-cache.json")), cache["version"] == 1 {
      for (engine, records) in cache["trees"]?.object ?? [:] {
        guard let records = records.array else { continue }
        var nodes: JSONObject = [:]
        for record in records {
          if let id = record["id"]?.string { nodes[id] = record }
        }
        let roots = BookmarkFlat.roots(engine)
        guard nodes[roots.bar] != nil, nodes[roots.other] != nil else { continue }
        let source: JSONValue = ["nodes": .object(nodes), "roots": [:]]
        cached[engine] = BookmarkFlat(document: source, engine: engine).document(profiles: aliases(engine), preserving: source)
      }
    }
    if !cached.isEmpty {
      return BookmarkLaunchInput(documents: cached.filter { engine, _ in activeEngines.contains(JSKey(engine)) }, legacyPendingEngines: legacyPending)
    }
    var documents: JSMap<JSONValue> = [:]
    let legacyNodes = legacy?["bookmarks"]?["nodes"]?.object ?? [:]
    for (profile, roots) in legacy?["bookmarks"]?["roots"]?.object ?? [:] {
      guard let engine = regularProfiles[profile], documents[engine] == nil,
        let oldBar = roots["bar"]?.string, let oldOther = roots["other"]?.string else { continue }
      let synthetic = BookmarkFlat.roots(engine)
      func mappedID(_ old: String) -> String {
        if JSKey(old) == JSKey(oldBar) { return synthetic.bar }
        if JSKey(old) == JSKey(oldOther) { return synthetic.other }
        return Self.legacyUUID(old)
      }
      var nodes: JSONObject = [:]
      for (_, node) in legacyNodes {
        guard var value = node.object, let oldID = node["id"]?.string else { continue }
        let id = mappedID(oldID)
        value["id"] = .string(id)
        value["parentId"] = node["parentId"]?.string.map { .string(mappedID($0)) } ?? .null
        if node["kind"] == "folder" { value["children"] = JSONValue((node["children"]?.array?.compactMap(\.string) ?? []).map(mappedID)) }
        nodes[id] = .object(value)
      }
      let source: JSONValue = ["nodes": .object(nodes), "roots": [:]]
      documents[engine] = BookmarkFlat(document: source, engine: engine).document(profiles: aliases(engine), preserving: source)
    }
    return BookmarkLaunchInput(documents: documents, legacyPendingEngines: legacyPending)
  }

  private func read(_ path: URL) -> JSONValue? {
    guard let data = try? Data(contentsOf: path) else { return nil }
    if data.isEmpty { return .null }
    return try? JSONValue.parseBookmark(data)
  }

  private static func legacyUUID(_ id: String) -> String {
    let units = Array(id.utf8)
    if units.count == 36 && units.enumerated().allSatisfy({ index, unit in
      [8, 13, 18, 23].contains(index) ? unit == 45 : (48...57).contains(unit) || (97...102).contains(unit)
    }) { return id }
    var h1: UInt32 = 1779033703, h2: UInt32 = 3144134277, h3: UInt32 = 1013904242, h4: UInt32 = 2773480762
    for unit in BookmarkString.units("netnyahoo-bookmark:" + id).map(UInt32.init) {
      h1 = h2 ^ ((h1 ^ unit) &* 597399067)
      h2 = h3 ^ ((h2 ^ unit) &* 2869860233)
      h3 = h4 ^ ((h3 ^ unit) &* 951274213)
      h4 = h1 ^ ((h4 ^ unit) &* 2716044179)
    }
    h1 = (h3 ^ (h1 >> 18)) &* 597399067
    h2 = (h4 ^ (h2 >> 22)) &* 2869860233
    h3 = (h1 ^ (h3 >> 17)) &* 951274213
    h4 = (h2 ^ (h4 >> 19)) &* 2716044179
    h1 ^= h2 ^ h3 ^ h4
    h2 ^= h1
    h3 ^= h1
    h4 ^= h1
    let hex = Array([h1, h2, h3, h4].map { String(repeating: "0", count: 8 - String($0, radix: 16).count) + String($0, radix: 16) }.joined().utf8)
    let digit = Int(String(UnicodeScalar(hex[16])), radix: 16)!
    func part(_ start: Int, _ end: Int) -> String { String(decoding: hex[start..<end], as: UTF8.self) }
    return "\(part(0, 8))-\(part(8, 12))-4\(part(13, 16))-\(String((digit & 3) | 8, radix: 16))\(part(17, 20))-\(part(20, 32))"
  }
}
