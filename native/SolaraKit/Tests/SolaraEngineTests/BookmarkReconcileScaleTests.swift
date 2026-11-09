import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

@Suite(.serialized)
struct BookmarkReconcileScaleTests {
  private func flatFolder(_ ids: [String], engine: String = "") -> BookmarkFlat {
    let roots = BookmarkFlat.roots(engine)
    var records: [JSONValue] = [["id": .string(roots.bar), "kind": "folder", "parent": nil, "title": "Bar", "addedAt": 0, "children": JSONValue(ids)], ["id": .string(roots.other), "kind": "folder", "parent": nil, "title": "Other", "addedAt": 0, "children": []]]
    for id in ids { records.append(["id": .string(id), "kind": "url", "parent": .string(roots.bar), "title": .string("T\(id)"), "url": .string("https://\(id).test/"), "addedAt": 1]) }
    return BookmarkFlat(records: records)
  }

  private func threadCPUMs() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
  }

  private func fastestDiffMs(_ sizes: [Int], _ make: (Int) -> (BookmarkFlat, BookmarkFlat)) -> [Int: Double] {
    let inputs = sizes.map { ($0, make($0)) }
    for (_, (before, after)) in inputs {
      #expect(BookmarkReconcile.operations(from: before, to: after, engine: "") == Self.referenceOperations(from: before, to: after, engine: ""))
    }
    var fastest: [Int: Double] = [:]
    for _ in 0..<3 {
      for (count, (before, after)) in inputs {
        let start = threadCPUMs()
        _ = BookmarkReconcile.operations(from: before, to: after, engine: "")
        fastest[count] = min(fastest[count] ?? .infinity, threadCPUMs() - start)
      }
    }
    return fastest
  }

  private func expectLinearGrowth(_ fastest: [Int: Double], small: Int, large: Int, _ label: String) {
    let ratio = fastest[large]! / max(fastest[small]!, 0.5)
    print("\(label): \(small) took \(fastest[small]!) ms, \(large) took \(fastest[large]!) ms, \(ratio)x")
    #expect(ratio < 6.5, "\(label): \(large / small)x the bookmarks took \(ratio)x as long")
  }

  @Test(arguments: ["swap", "delete", "drag"]) func largeFolderDiffsGrowLinearly(_ edit: String) {
    let fastest = fastestDiffMs([1250, 5000]) { count in
      let ids = (0..<count).map { "n\($0)" }
      var reordered = ids
      switch edit {
      case "swap": reordered.swapAt(10, count * 4 / 5)
      case "delete": reordered.remove(at: 7)
      default: reordered.insert(reordered.remove(at: count * 9 / 10), at: 3)
      }
      var after = flatFolder(reordered)
      var renamed = after.nodes["n20"]?.object ?? [:]
      renamed["title"] = "Renamed"
      after.nodes["n20"] = .object(renamed)
      return (flatFolder(ids), after)
    }
    expectLinearGrowth(fastest, small: 1250, large: 5000, "same-folder \(edit)")
  }

  @Test func moveEveryBookmarkBetweenTwoLargeFoldersGrowsLinearly() {
    let fastest = fastestDiffMs([5000, 20000]) { count in
      let ids = (0..<count).map { "n\($0)" }
      let before = flatFolder(ids)
      let roots = BookmarkFlat.roots("")
      var after = before
      after.children[roots.bar] = []
      after.children[roots.other] = ids
      for id in ids {
        var node = after.nodes[id]?.object ?? [:]
        node["parent"] = .string(roots.other)
        after.nodes[id] = .object(node)
      }
      return (before, after)
    }
    expectLinearGrowth(fastest, small: 5000, large: 20000, "cross-folder")
  }

  @Test func indexedDiffMatchesTheReferenceOnRandomEdits() {
    var generator = SplitMix(seed: 0x5eed)
    for round in 0..<3000 {
      let engine = round % 3 == 0 ? "e" : ""
      let roots = BookmarkFlat.roots(engine)
      let before = randomTree(&generator, engine: engine, roots: roots, prefix: "a")
      let after = mutate(before, &generator, roots: roots, round: round)
      #expect(BookmarkReconcile.operations(from: before, to: after, engine: engine) == Self.referenceOperations(from: before, to: after, engine: engine), "round \(round)")
    }
  }

  @Test func crossFolderDiffMatchesReferenceOnRandomDuplicateAndMissingChildren() {
    var generator = SplitMix(seed: 0xc2055f01de2)
    for round in 0..<2000 {
      let engine = round % 2 == 0 ? "" : "e"
      let roots = BookmarkFlat.roots(engine)
      let folders = [roots.bar, roots.other, "f0", "f1", "f2"]
      let ids = (0..<24).map { "n\($0)" } + ["é", "e\u{301}"]
      var before = flatFolder([], engine: engine)
      for folder in folders.dropFirst(2) {
        before.nodes[folder] = ["kind": "folder", "parent": .string(roots.bar), "title": .string(folder), "addedAt": 0]
        before.order.append(folder)
        before.children[folder] = []
      }
      before.children[roots.bar] = Array(folders.dropFirst(2))
      for id in ids {
        let parent = folders[Int(generator.next() % UInt64(folders.count))]
        before.nodes[id] = ["kind": "url", "parent": .string(parent), "title": .string(id), "url": .string("https://example.test/\(id)"), "addedAt": 1]
        before.order.append(id)
        if generator.next() % 4 != 0 { before.children[parent] = (before.children[parent] ?? []) + [id] }
        if generator.next() % 3 == 0 { before.children[parent] = (before.children[parent] ?? []) + [id] }
      }
      var after = before
      for folder in folders { after.children[folder] = [] }
      for folder in folders.dropFirst(2) {
        let parent = generator.next() % 2 == 0 ? roots.bar : roots.other
        after.children[parent] = (after.children[parent] ?? []) + [folder]
        if round % 2 != 0 && generator.next() % 5 == 0 { after.children[parent] = (after.children[parent] ?? []) + [folder] }
      }
      var targets = ids
      for index in targets.indices.reversed() { targets.swapAt(index, Int(generator.next() % UInt64(index + 1))) }
      if round % 2 != 0 { targets += (0..<54).map { _ in ids[Int(generator.next() % UInt64(ids.count))] } }
      for id in targets {
        let parent = folders[Int(generator.next() % UInt64(folders.count))]
        after.children[parent] = (after.children[parent] ?? []) + [id]
      }
      let ops = BookmarkReconcile.operations(from: before, to: after, engine: engine)
      #expect(ops == Self.referenceOperations(from: before, to: after, engine: engine), "cross-folder round \(round)")
    }
  }

  @Test func addingFolderDiscardsItsPendingSourceRemovals() {
    let roots = BookmarkFlat.roots("")
    var before = flatFolder(["a", "b", "c"])
    before.children[roots.bar] = []
    before.children["f"] = ["a", "b", "c"]
    for id in ["a", "b", "c"] {
      var node = before.nodes[id]?.object ?? [:]
      node["parent"] = "f"
      before.nodes[id] = .object(node)
    }
    var after = before
    after.nodes["f"] = ["kind": "folder", "parent": .string(roots.bar), "title": "F", "addedAt": 0]
    after.order.append("f")
    after.children[roots.bar] = ["a", "f"]
    after.children["f"] = ["b", "c"]
    let ops = BookmarkReconcile.operations(from: before, to: after, engine: "")
    #expect(ops == Self.referenceOperations(from: before, to: after, engine: ""))
    #expect(ops.filter { $0["op"] == "move" }.compactMap { $0["id"]?.string } == ["a", "b", "c"])
  }

  @Test func crossFolderDiffMatchesJavaScriptOracleRecords() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bookmark-desired.json")
    let oracle = try BookmarkWireFixture.parse(String(contentsOf: path, encoding: .utf8), checksum: "eb4271f5877e517372e512ebf17d891705ee5cd36abf1bfeac8bc7d70ad9d00c")
    for record in oracle["pure"]?.array ?? [] {
      let engine = record["engine"]?.string ?? ""
      let before = BookmarkFlat(records: record["before"]?.array ?? [])
      let after = BookmarkFlat(records: record["after"]?.array ?? [])
      let ops = BookmarkReconcile.operations(from: before, to: after, engine: engine)
      #expect(ops == Self.referenceOperations(from: before, to: after, engine: engine), "\(record["name"]?.string ?? "")")
      #expect(JSKey(JSONValue.array(ops).canonical) == JSKey((record["ops"] ?? []).canonical), "\(record["name"]?.string ?? "")")
    }
  }

  private func randomTree(_ generator: inout SplitMix, engine: String, roots: BookmarkRoots, prefix: String) -> BookmarkFlat {
    var records: [JSONValue] = []
    var children: [String: [String]] = [roots.bar: [], roots.other: []]
    var folders = [roots.bar, roots.other]
    var order: [String] = []
    var parents: [String: String] = [:]
    var kinds: [String: String] = [:]
    for index in 0..<Int(generator.next() % 40) {
      let id = "\(prefix)\(index)"
      let parent = folders[Int(generator.next() % UInt64(folders.count))]
      let folder = generator.next() % 4 == 0
      children[parent, default: []].append(id)
      parents[id] = parent
      kinds[id] = folder ? "folder" : "url"
      order.append(id)
      if folder { folders.append(id); children[id] = [] }
    }
    for root in [roots.bar, roots.other] { records.append(["id": .string(root), "kind": "folder", "parent": nil, "title": "R", "addedAt": 0, "children": JSONValue(children[root] ?? [])]) }
    for id in order {
      var record: JSONObject = ["id": .string(id), "kind": .string(kinds[id]!), "parent": .string(parents[id]!), "title": .string("t\(id)"), "addedAt": 1]
      if kinds[id] == "folder" { record["children"] = JSONValue(children[id] ?? []) } else { record["url"] = .string("https://\(id).test/") }
      records.append(.object(record))
    }
    return BookmarkFlat(records: records)
  }

  private func mutate(_ tree: BookmarkFlat, _ generator: inout SplitMix, roots: BookmarkRoots, round: Int) -> BookmarkFlat {
    var next = tree
    let folders = next.children.keys
    let movable = next.order.filter { next.nodes[$0]?["parent"]?.isNull == false }
    for step in 0..<Int(generator.next() % 6) {
      switch generator.next() % 5 {
      case 0 where !movable.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        for folder in next.children.keys { next.children[folder] = next.children[folder]?.filter { !BookmarkReconcile.same($0, id) } }
      case 1 where !folders.isEmpty:
        let folder = folders[Int(generator.next() % UInt64(folders.count))]
        if var list = next.children[folder], list.count > 1 {
          list.swapAt(Int(generator.next() % UInt64(list.count)), Int(generator.next() % UInt64(list.count)))
          next.children[folder] = list
        }
      case 2 where !movable.isEmpty && !folders.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        let target = folders[Int(generator.next() % UInt64(folders.count))]
        guard !BookmarkReconcile.same(id, target) else { break }
        for folder in next.children.keys { next.children[folder] = next.children[folder]?.filter { !BookmarkReconcile.same($0, id) } }
        var list = next.children[target] ?? []
        list.insert(id, at: Int(generator.next() % UInt64(list.count + 1)))
        next.children[target] = list
        var node = next.nodes[id]?.object ?? [:]
        node["parent"] = .string(target)
        next.nodes[id] = .object(node)
      case 3 where !movable.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        var node = next.nodes[id]?.object ?? [:]
        node["title"] = .string("changed \(round) \(step)")
        next.nodes[id] = .object(node)
      default:
        let id = "b\(round)-\(step)"
        let target = [roots.bar, roots.other][Int(generator.next() % 2)]
        next.nodes[id] = ["kind": "url", "parent": .string(target), "title": "new", "url": .string("https://\(id).test/"), "addedAt": 2]
        next.order.append(id)
        var list = next.children[target] ?? []
        list.insert(id, at: Int(generator.next() % UInt64(list.count + 1)))
        if generator.next() % 7 == 0, let first = list.first { list.append(first) }
        next.children[target] = list
      }
    }
    if generator.next() % 9 == 0, let folder = folders.first { next.children[folder] = (next.children[folder] ?? []) + ["missing-\(round)"] }
    return next
  }

  static func referenceOperations(from: BookmarkFlat, to: BookmarkFlat, engine: String) -> [JSONValue] {
    let roots = BookmarkFlat.roots(engine)
    var parents = from.nodes.mapValues { $0["parent"] ?? .null }
    var kids = from.children
    var ops: [JSONValue] = []
    var queue = [roots.bar, roots.other]
    var cursor = 0
    func opParent(_ id: String) -> String { BookmarkReconcile.same(id, roots.bar) ? "bar" : BookmarkReconcile.same(id, roots.other) ? "other" : id }
    while cursor < queue.count {
      let folder = queue[cursor]
      cursor += 1
      if kids[folder] == nil { kids[folder] = [] }
      for (index, id) in (to.children[folder] ?? []).enumerated() {
        guard let node = to.nodes[id] else { continue }
        let was = from.nodes[id]
        if parents[id] == nil {
          var op: JSONObject = ["op": "add", "id": .string(id), "k": node["kind"] == "url" ? "u" : "f", "t": node["title"] ?? ""]
          if let url = node["url"] { op["u"] = url }
          op["a"] = node["addedAt"] ?? 0
          if node["key"]?.truthy == true { op["key"] = node["key"] }
          op["parent"] = .string(opParent(folder))
          op["index"] = JSONValue(index)
          ops.append(.object(op))
          var list = kids[folder] ?? []
          list.insert(id, at: min(index, list.count))
          kids[folder] = list
          parents[id] = .string(folder)
          if node["kind"] == "folder" { kids[id] = [] }
        } else {
          if parents[id] != .string(folder) || (kids[folder] ?? []).firstIndex(where: { BookmarkReconcile.same($0, id) }) != index {
            if let parent = parents[id]?.string, var old = kids[parent] {
              BookmarkReconcile.removeSplice(&old, id)
              kids[parent] = old
            }
            var list = kids[folder] ?? []
            list.insert(id, at: min(index, list.count))
            kids[folder] = list
            parents[id] = .string(folder)
            ops.append(["op": "move", "id": .string(id), "parent": .string(opParent(folder)), "index": JSONValue(index)])
          }
          if let was, was["title"] != node["title"] || (node["url"] != nil && was["url"] != node["url"]) {
            var op: JSONObject = ["op": "update", "id": .string(id), "t": node["title"] ?? ""]
            if let url = node["url"] { op["u"] = url }
            ops.append(.object(op))
          }
        }
        if node["kind"] == "folder" { queue.append(id) }
      }
    }
    for id in from.order {
      guard to.nodes[id] == nil, from.nodes[id]?["parent"]?.isNull == false else { continue }
      var under = false
      var at = parents[id]?.string
      var visited = Set<JSKey>()
      while let parent = at, visited.insert(JSKey(parent)).inserted {
        if to.nodes[parent] == nil { under = true }
        at = parents[parent]?.string
      }
      if !under { ops.append(["op": "remove", "id": .string(id)]) }
    }
    return ops
  }

}

struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}
