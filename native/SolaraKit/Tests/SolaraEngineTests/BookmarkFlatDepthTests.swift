import Foundation
import Synchronization
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkFlatDepthTests {
  private final class Result: Sendable {
    let value = Mutex<BookmarkFlat?>(nil)
  }

  @Test func deepDocumentFlattensOnABackgroundThreadStack() throws {
    let roots = BookmarkFlat.roots("")
    let folders = (0..<513).map { "folder\($0)" }
    var nodes: JSONObject = [
      roots.bar: ["kind": "folder", "children": ["folder0"]],
      roots.other: ["kind": "folder", "children": []],
      "leaf": ["kind": "url", "title": "Deep bookmark", "url": "https://deep.example/", "syncKey": "deep-key", "addedAt": 17]
    ]
    for index in folders.indices {
      nodes[folders[index]] = ["kind": "folder", "children": [.string(index + 1 < folders.count ? folders[index + 1] : "leaf")]]
    }
    let document: JSONValue = ["nodes": .object(nodes)]
    let result = Result()
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
      let flat = BookmarkFlat(document: document, engine: "")
      result.value.withLock { $0 = flat }
      finished.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    #expect(finished.wait(timeout: .now() + 10) == .success)
    let flat = try #require(result.value.withLock { $0 })
    #expect(flat.order == [roots.bar] + folders + ["leaf", roots.other])
    #expect(flat.children[roots.bar] == ["folder0"])
    #expect(flat.children[roots.other] == [])
    #expect(flat.children.keys == folders.reversed() + [roots.bar, roots.other])
    for index in folders.indices {
      #expect(flat.nodes[folders[index]]?["parent"] == .string(index == 0 ? roots.bar : folders[index - 1]))
      #expect(flat.children[folders[index]] == [index + 1 < folders.count ? folders[index + 1] : "leaf"])
    }
    #expect(flat.nodes["leaf"] == ["kind": "url", "parent": "folder512", "title": "Deep bookmark", "addedAt": 17, "url": "https://deep.example/", "key": "deep-key"])
  }

  @Test func traversalKeepsTheFirstDepthFirstParentAndSkipsVisitedOrMissingChildren() {
    let roots = BookmarkFlat.roots("")
    let document: JSONValue = ["nodes": .object([
      roots.bar: ["kind": "folder", "children": ["outer", "shared", "outer", "missing"]],
      roots.other: ["kind": "folder", "children": ["shared", "end"]],
      "outer": ["kind": "folder", "children": [.string(roots.bar), "shared", .string(roots.other)]],
      "shared": ["kind": "url", "url": "https://shared.example/", "children": ["ignored"]],
      "end": ["children": ["ignored"]],
      "ignored": ["kind": "url", "url": "https://ignored.example/"]
    ])]
    let flat = BookmarkFlat(document: document, engine: "")
    #expect(flat.order == [roots.bar, "outer", "shared", roots.other, "end"])
    #expect(flat.children == [roots.other: ["end"], "outer": ["shared", roots.other], roots.bar: ["outer"]])
    #expect(flat.nodes["shared"]?["parent"] == "outer")
    #expect(flat.nodes[roots.other]?["parent"] == "outer")
    #expect(flat.nodes["end"] == ["kind": "folder", "parent": .string(roots.other), "title": "", "addedAt": 0])
  }

  @Test func canonicallyEquivalentIdentifiersKeepSeparateTraversalSlots() {
    let roots = BookmarkFlat.roots("engine")
    let document: JSONValue = ["nodes": .object([
      roots.bar: ["kind": "folder", "children": ["é", "e\u{301}"]],
      roots.other: ["kind": "folder", "children": []],
      "é": ["kind": "url", "title": "Composed", "url": "https://composed.example/"],
      "e\u{301}": ["kind": "url", "title": "Decomposed", "url": "https://decomposed.example/"]
    ])]
    let flat = BookmarkFlat(document: document, engine: "engine")
    #expect(flat.order.map(JSKey.init) == [roots.bar, "é", "e\u{301}", roots.other].map(JSKey.init))
    #expect(flat.children[roots.bar]?.map(JSKey.init) == ["é", "e\u{301}"].map(JSKey.init))
    #expect(flat.nodes["é"]?["title"] == "Composed")
    #expect(flat.nodes["e\u{301}"]?["title"] == "Decomposed")
  }
}
