import CryptoKit
import Foundation
import SolaraModel

struct BookmarkLegacyEngineProgress: Sendable {
  var stage: String
  var ids: [String]
  var target: JSONValue?
  var imported: JSONObject = [:]
}

struct BookmarkLegacyProgress: Sendable {
  let source: String
  let profiles: JSMap<String>
  var engines: JSMap<BookmarkLegacyEngineProgress>

  var value: JSONValue {
    ["source": .string(source), "profiles": .object(profiles.mapValues(JSONValue.string)), "engines": .object(engines.mapValues { entry in
      ["stage": .string(entry.stage), "ids": JSONValue(entry.ids), "target": entry.target ?? .null, "imported": .object(entry.imported)]
    })]
  }

  init(source: String, engines: [String], profiles: JSMap<String>) {
    self.source = source
    self.profiles = profiles.filter { profile, _ in !Ids.isIncognitoProfile(profile) }
    self.engines = JSMap(engines.map { ($0, BookmarkLegacyEngineProgress(stage: "pending", ids: [], target: nil)) })
  }

  init(_ value: JSONValue) throws {
    guard let source = value["source"]?.string, source.utf8.count == 64, source.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), let entries = value["engines"]?.object, let routes = value["profiles"]?.object else { throw BookmarkPendingStoreError.invalidEnvelope }
    self.source = source
    var profiles: JSMap<String> = [:]
    for (profile, value) in routes {
      guard !Ids.isIncognitoProfile(profile), let engine = value.string, !engine.hasPrefix("incognito:") else { throw BookmarkPendingStoreError.invalidEnvelope }
      profiles[profile] = engine
    }
    self.profiles = profiles
    var engines: JSMap<BookmarkLegacyEngineProgress> = [:]
    for (engine, entry) in entries {
      guard !engine.hasPrefix("incognito:"), let stage = entry["stage"]?.string,
        ["pending", "accepted", "pushed", "blocked", "confirmed", "discarded"].contains(stage),
        let ids = entry["ids"]?.array, ids.allSatisfy({ $0.string != nil }),
        Set(ids.compactMap(\.string).map(JSKey.init)).count == ids.count,
        let imported = entry["imported"]?.object,
        let target = entry["target"], target.isNull || target.object != nil,
        (stage != "pushed" && stage != "blocked") || !target.isNull else { throw BookmarkPendingStoreError.invalidEnvelope }
      let identities = Set(ids.compactMap(\.string).map(JSKey.init))
      guard ids.compactMap(\.string).allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
        imported.allSatisfy({ id, node in identities.contains(JSKey(id)) && node["parent"]?.string != nil && node["title"]?.string != nil && node["addedAt"]?.number?.isFinite == true && (node["kind"] == "folder" || (node["kind"] == "url" && node["url"]?.string != nil)) }) else { throw BookmarkPendingStoreError.invalidEnvelope }
      engines[engine] = BookmarkLegacyEngineProgress(stage: stage, ids: ids.compactMap(\.string), target: target.isNull ? Optional<JSONValue>.none : Optional.some(target), imported: imported)
    }
    self.engines = engines
  }
}

public final class BookmarkLegacyMigration: @unchecked Sendable {
  public let sourceID: String
  public let sourceURL: URL
  let bytes: Data
  let document: JSONValue?
  private let directory: URL
  private let operations: BookmarkPendingFileOperations
  private let lock = NSLock()

  public init(directory: URL, bytes: Data, fileOperations: BookmarkPendingFileOperations = .live) {
    self.directory = directory
    self.bytes = bytes
    operations = fileOperations
    sourceURL = directory.appendingPathComponent("bookmarks.json")
    sourceID = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    document = try? JSONValue.parseBookmark(bytes)
  }

  static func recover(directory: URL?, sourceID: String?) -> BookmarkLegacyMigration? {
    guard let directory, let sourceID, !FileManager.default.fileExists(atPath: directory.appendingPathComponent("bookmarks.json").path),
      let bytes = try? Data(contentsOf: directory.appendingPathComponent("bookmarks-legacy-\(sourceID).json")) else { return nil }
    let source = BookmarkLegacyMigration(directory: directory, bytes: bytes)
    return source.sourceID == sourceID ? source : nil
  }

  func backup() throws {
    lock.lock()
    defer { lock.unlock() }
    let target = directory.appendingPathComponent("bookmarks-legacy-\(sourceID).json")
    if operations.exists(target) {
      guard try operations.read(target) == bytes else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark backup is incomplete") }
      try operations.syncFile(target)
      try operations.syncDirectory(directory)
      return
    }
    let temporary = directory.appendingPathComponent("bookmarks-legacy-\(sourceID).tmp-\(UUID().uuidString.lowercased())")
    do {
      try operations.writeNew(temporary, bytes)
      try operations.syncFile(temporary)
      try operations.rename(temporary, target)
      try operations.syncDirectory(directory)
    } catch {
      try? operations.remove(temporary)
      throw error
    }
  }

  func retire() throws {
    guard operations.exists(sourceURL) else { return }
    guard try operations.read(sourceURL) == bytes else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark source changed during migration") }
    try operations.remove(sourceURL)
    try operations.syncDirectory(directory)
  }

  func importOperations(engine: String, profiles: JSMap<String>) throws -> [JSONValue] {
    guard let document, let bookmarks = document["bookmarks"]?.object,
      let nodes = bookmarks["nodes"]?.object, let roots = bookmarks["roots"]?.object else {
      throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark source is unreadable")
    }
    for (profile, _) in roots where !Ids.isIncognitoProfile(profile) && profiles[profile] == nil {
      throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark profile is not mapped: \(profile)")
    }
    var eligible = Set<JSKey>()
    var reachable = Set<JSKey>()
    var queue: [String] = []
    for (profile, root) in roots where !Ids.isIncognitoProfile(profile) {
      guard let mapped = profiles[profile], eligible.insert(JSKey(mapped)).inserted else { continue }
      guard let bar = root["bar"]?.string, let other = root["other"]?.string else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark roots are invalid") }
      queue.append(contentsOf: [bar, other])
    }
    var cursor = 0
    while cursor < queue.count {
      let id = queue[cursor]
      cursor += 1
      guard reachable.insert(JSKey(id)).inserted else { continue }
      guard let node = nodes[id], BookmarkReconcile.same(node["id"]?.string, id) else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark record is missing") }
      if node["kind"] == "folder" {
        guard let children = node["children"]?.array, children.allSatisfy({ $0.string != nil }) else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark children are invalid") }
        queue.append(contentsOf: children.compactMap(\.string))
      }
    }
    guard nodes.keys.allSatisfy({ reachable.contains(JSKey($0)) }) else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark records are not mapped to a regular library") }
    guard let profile = roots.keys.first(where: { !Ids.isIncognitoProfile($0) && BookmarkReconcile.same(profiles[$0], engine) }) else { return [] }
    guard let bar = roots[profile]?["bar"]?.string, let other = roots[profile]?["other"]?.string, JSKey(bar) != JSKey(other) else {
      throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark roots are invalid")
    }
    var seen = Set<JSKey>()
    var mapped = Set<JSKey>()
    var operations: [JSONValue] = []
    func walk(_ folder: String, parent: String, depth: Int) throws {
      guard depth < 512, let node = nodes[folder], node["kind"] == "folder", let children = node["children"]?.array else {
        throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark folder is invalid")
      }
      for (index, child) in children.enumerated() {
        guard let old = child.string, seen.insert(JSKey(old)).inserted, let value = nodes[old],
          BookmarkReconcile.same(value["id"]?.string, old), BookmarkReconcile.same(value["parentId"]?.string, folder),
          let title = value["title"]?.string, let addedAt = value["addedAt"]?.number, addedAt.isFinite,
          value["kind"] == "folder" || value["kind"] == "url" else {
          throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark record is invalid")
        }
        let id = BookmarkLaunchCache.legacyUUID(old)
        guard mapped.insert(JSKey(id)).inserted else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark identities collide") }
        var operation: JSONObject = ["op": "add", "id": .string(id), "parent": .string(parent), "index": JSONValue(index), "t": .string(title), "a": .number(addedAt), "ifAbsent": true, "k": value["kind"] == "folder" ? "f" : "u"]
        let keyValue = value["syncKey"].flatMap { $0.isNull ? nil : $0 } ?? value["ac_sync_key"].flatMap { $0.isNull ? nil : $0 }
        if let keyValue {
          guard let key = keyValue.string else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark key is invalid") }
          if !key.isEmpty { operation["key"] = .string(key) }
        } else if JSKey(id) != JSKey(old) { operation["key"] = .string(old) }
        if value["kind"] == "url" {
          guard let url = value["url"]?.string, !url.isEmpty else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark URL is invalid") }
          operation["u"] = .string(url)
        }
        operations.append(.object(operation))
        if value["kind"] == "folder" { try walk(old, parent: id, depth: depth + 1) }
      }
    }
    for root in [bar, other] {
      guard let value = nodes[root], BookmarkReconcile.same(value["id"]?.string, root), value["parentId"]?.isNull == true else { throw BookmarkCoordinatorError.invalidOperation("Legacy bookmark roots are invalid") }
      seen.insert(JSKey(root))
    }
    try walk(bar, parent: "bar", depth: 0)
    try walk(other, parent: "other", depth: 0)
    return operations
  }
}
