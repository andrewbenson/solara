import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkBulkEditTests {
  @Test func bulkDeletePlacesKeepRawIndexesFirstDuplicatesAndExactIdentifiers() throws {
    let roots = BookmarkFlat.roots("")
    var nodes: JSONObject = [
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "children": ["a", nil, "é", "a", "e\u{301}", "folder", "stay"]],
      roots.other: ["id": .string(roots.other), "kind": "folder", "children": ["b"]],
      "folder": ["id": "folder", "kind": "folder", "parentId": .string(roots.bar), "children": ["nested"]],
      "url-parent": ["id": "url-parent", "kind": "url", "parentId": .string(roots.other), "url": "https://fixture.example/"]
    ]
    for id in ["a", "é", "e\u{301}", "stay", "unlisted"] { nodes[id] = ["id": .string(id), "kind": "url", "parentId": .string(roots.bar), "url": "https://fixture.example/"] }
    for (id, parent) in [("b", roots.other), ("nested", "folder"), ("orphan", "missing"), ("nonfolder", "url-parent")] { nodes[id] = ["id": .string(id), "kind": "url", "parentId": .string(parent), "url": "https://fixture.example/"] }
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    owner.seed(engine: "", document: ["nodes": .object(nodes), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]], ready: true)
    let receipt = try owner.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [["e\u{301}", "a", "folder", "nested", "b", "orphan", "unlisted", "nonfolder"]])])
    let result = try #require(receipt.results.first)
    #expect(result["places"]?.array?.compactMap { $0["id"]?.string }.map(JSKey.init) == ["e\u{301}", "a", "folder", "b", "orphan", "unlisted", "nonfolder"].map(JSKey.init))
    #expect(result["places"]?.array?.compactMap { $0["index"]?.number } == [4, 0, 5, 0, 0, -1, 0])
    #expect(result["nodes"]?.array?.compactMap { $0["id"]?.string }.contains("nested") == true)
    #expect(receipt.view.document["nodes"]?[roots.bar]?["children"] == ["é", "stay"])
  }

  @Test func deletingAndRestoringThousandsPreservesSiblingAndSelectionOrder() throws {
    let roots = BookmarkFlat.roots("")
    let ids = (0..<3000).map { "n\($0)" }
    var nodes: JSONObject = [roots.bar: ["id": .string(roots.bar), "kind": "folder", "children": JSONValue(ids)], roots.other: ["id": .string(roots.other), "kind": "folder", "children": []]]
    for id in ids { nodes[id] = ["id": .string(id), "kind": "url", "parentId": .string(roots.bar), "url": .string("https://fixture.example/\(id)")] }
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    owner.seed(engine: "", document: ["nodes": .object(nodes), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)]]], ready: true)
    let selected = ids.reversed().filter { Int($0.dropFirst())! % 3 != 0 }
    let removed = try owner.submit(profile: "p", mutations: [.init(method: "removeBookmarks", args: [JSONValue(selected)])])
    let result = try #require(removed.results.first)
    #expect(result["places"]?.array?.compactMap { $0["id"]?.string } == selected)
    #expect(result["places"]?.array?.compactMap { $0["index"]?.number } == selected.map { Double(Int($0.dropFirst())!) })
    let restored = try owner.submit(profile: "p", mutations: [.init(method: "restoreBookmarks", args: [result])])
    #expect(restored.view.document["nodes"]?[roots.bar]?["children"] == JSONValue(ids))
  }
}
