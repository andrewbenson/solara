import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkLaunchCacheTests {
  private func directory() throws -> URL {
    let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bookmark-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
  }

  private func document(engine: String = "", profile: String = "p", id: String = "cached") -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    return ["nodes": [roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": [.string(id)], "addedAt": 0], roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0], id: ["id": .string(id), "kind": "url", "parentId": .string(roots.bar), "title": "Cached", "url": "https://cache.test/é", "favicon": "local-icon", "addedAt": 42, "syncKey": "old-sync-key"]], "roots": [profile: ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  private func write(_ value: JSONValue, name: String, to directory: URL) throws {
    try Data(value.canonical.utf8).write(to: directory.appendingPathComponent(name))
  }

  private func cache(_ document: JSONValue, engine: String = "") -> JSONValue {
    ["version": 1, "trees": [engine: .array(document["nodes"]!.object!.values)]]
  }

  @Test func readsVersionOneCacheWithoutChangingBytes() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("bookmarks-cache.json")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bookmark-cache-v1.json")
    let bytes = try Data(contentsOf: fixture)
    try bytes.write(to: path)
    let mtime = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": "", "alias": ""], defaultProfile: "p")
    let restored = try #require(launch.documents[""])
    let id = "11111111-1111-4111-8111-111111111111"
    #expect(restored["nodes"]?[id]?["url"] == "https://cache.test/e\u{301}")
    #expect(restored["nodes"]?[id]?["title"] == "Cached é")
    #expect(restored["nodes"]?[id]?["favicon"] == "local-icon")
    #expect(restored["nodes"]?[id]?["addedAt"] == 0)
    #expect(restored["nodes"]?[id]?["syncKey"] == "old-sync-key")
    #expect(restored["roots"]?["alias"] == restored["roots"]?["p"])
    #expect(launch.legacyPendingEngines.isEmpty)
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir), launchInput: launch)
    owner.completeRead(engine: "", document: restored, capturedRevision: 0)
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: [.string(id)])])
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mtime)
  }

  @Test func cachePartialEnginesMatchesExistingFallback() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(cache(document()), name: "bookmarks-cache.json", to: dir)
    try write(["bookmarks": document(engine: "other", profile: "q", id: "legacy")], name: "bookmarks.json", to: dir)
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": "", "q": "other"], defaultProfile: "p")
    #expect(launch.documents[""] != nil)
    #expect(launch.documents["other"] == nil)
    #expect(launch.legacyPendingEngines == [JSKey(""), JSKey("other")])
  }

  @Test func validRetiredCacheStillSuppressesLegacyFallback() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(cache(document(engine: "retired", profile: "retired"), engine: "retired"), name: "bookmarks-cache.json", to: dir)
    try write(["bookmarks": document(id: "legacy")], name: "bookmarks.json", to: dir)
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    #expect(launch.documents.isEmpty)
    #expect(launch.legacyPendingEngines == [JSKey("")])
  }

  @Test func legacyIDsDatesOrderAndAliasesMatchExistingFallback() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source: JSONValue = ["nodes": ["old-bar": ["id": "old-bar", "kind": "folder", "parentId": nil, "title": "Old Bar", "children": ["legacy-é", "11111111-1111-4111-8111-111111111111"], "addedAt": 0], "old-other": ["id": "old-other", "kind": "folder", "parentId": nil, "title": "Old Other", "children": [], "addedAt": 0], "legacy-é": ["id": "legacy-é", "kind": "url", "parentId": "old-bar", "title": "Exact é", "url": "https://legacy.test/e\u{301}", "favicon": "icon", "addedAt": 0], "11111111-1111-4111-8111-111111111111": ["id": "11111111-1111-4111-8111-111111111111", "kind": "folder", "parentId": "old-bar", "title": "Empty", "children": [], "addedAt": 123]], "roots": ["p": ["bar": "old-bar", "other": "old-other"], "incognito:private@p": ["bar": "old-bar", "other": "old-other"]]]
    try write(["bookmarks": source], name: "bookmarks.json", to: dir)
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": "", "alias": "", "incognito:private@p": "private"], defaultProfile: "p")
    let restored = try #require(launch.documents[""])
    let children = try #require(restored["nodes"]?["bar@default"]?["children"]?.array)
    let mapped = try #require(children.first?.string)
    #expect(mapped == "11a23799-3d15-4369-a58c-831c0a2988f0")
    #expect(children[1] == "11111111-1111-4111-8111-111111111111")
    #expect(restored["nodes"]?[mapped]?["addedAt"] == 0)
    #expect(restored["nodes"]?[mapped]?["url"] == "https://legacy.test/e\u{301}")
    #expect(restored["nodes"]?[mapped]?["favicon"] == "icon")
    #expect(restored["nodes"]?[mapped]?["syncKey"] == "legacy-é")
    #expect(restored["roots"]?["alias"] == restored["roots"]?["p"])
    #expect(launch.documents["private"] == nil)
    #expect(launch.legacyPendingEngines == [JSKey("")])
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }

  @Test func invalidCacheFallsBackToLegacy() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(["version": 1, "trees": ["": [["id": "bar@default", "kind": "folder", "children": []]]]], name: "bookmarks-cache.json", to: dir)
    try write(["bookmarks": document(id: "legacy")], name: "bookmarks.json", to: dir)
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    #expect(launch.documents[""]?["nodes"]?.object?.count == 3)
    #expect(launch.legacyPendingEngines == [JSKey("")])
  }

  @Test func emptyOrFalsyLegacyDoesNotInventAMigrationGate() throws {
    for bytes in [Data(), Data("null".utf8), Data("false".utf8), Data("0".utf8), Data("\"\"".utf8)] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      try bytes.write(to: dir.appendingPathComponent("bookmarks.json"))
      let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
      #expect(launch.legacyPendingEngines.isEmpty)
      #expect(launch.documents.isEmpty)
    }
  }

  @Test func unreadableLegacyKeepsAllActiveEnginesUnready() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{".utf8).write(to: dir.appendingPathComponent("bookmarks.json"))
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": "", "q": "q", "incognito:w@p": "private"], defaultProfile: "p")
    #expect(launch.documents.isEmpty)
    #expect(launch.legacyPendingEngines == [JSKey(""), JSKey("q")])
  }
}
