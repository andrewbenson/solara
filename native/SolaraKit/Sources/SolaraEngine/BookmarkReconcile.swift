import Foundation
import SolaraModel

public struct BookmarkFlat: Equatable, Sendable {
  public var nodes: JSONObject
  public var children: JSMap<[String]>
  public var order: [String]

  public init(records: [JSONValue]) {
    nodes = [:]
    children = [:]
    order = []
    for record in records {
      guard let id = record["id"]?.string, var node = record.object else { continue }
      node.removeValue(forKey: "id")
      node.removeValue(forKey: "children")
      order.append(id)
      nodes[id] = .object(node)
      if record["kind"] == "folder" { children[id] = record["children"]?.array?.compactMap(\.string) ?? [] }
    }
  }

  public init(document: JSONValue, engine: String) {
    self.init(records: [])
    let source = document["nodes"]?.object ?? [:]
    struct Frame {
      let id: String
      let sourceChildren: [String]
      var cursor = 0
      var acceptedChildren: [String] = []
    }
    var stack: [Frame] = []
    func enter(_ id: String, parent: String?) -> Bool {
      guard nodes[id] == nil, let node = source[id] else { return false }
      var flat: JSONObject = ["kind": node["kind"] ?? "folder", "parent": JSONValue(parent), "title": node["title"] ?? "", "addedAt": node["addedAt"] ?? 0]
      if node["kind"] == "url" { flat["url"] = node["url"] ?? "" }
      if node["syncKey"]?.truthy == true { flat["key"] = node["syncKey"] }
      nodes[id] = .object(flat)
      order.append(id)
      if node["kind"] == "folder" {
        stack.append(Frame(id: id, sourceChildren: node["children"]?.array?.compactMap(\.string) ?? []))
      }
      return true
    }
    let roots = Self.roots(engine)
    for root in [roots.bar, roots.other] {
      _ = enter(root, parent: nil)
      while !stack.isEmpty {
        let index = stack.count - 1
        guard stack[index].cursor < stack[index].sourceChildren.count else {
          let frame = stack.removeLast()
          children[frame.id] = frame.acceptedChildren
          continue
        }
        let child = stack[index].sourceChildren[stack[index].cursor]
        let parent = stack[index].id
        stack[index].cursor += 1
        if enter(child, parent: parent) { stack[index].acceptedChildren.append(child) }
      }
    }
  }

  public var records: [JSONValue] {
    order.compactMap { id in
      guard let node = nodes[id]?.object else { return nil }
      var result: JSONObject = ["id": .string(id)]
      for (key, value) in node { result[key] = value }
      if let kids = children[id] { result["children"] = JSONValue(kids) }
      return .object(result)
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.records == rhs.records }

  public static func roots(_ engine: String) -> BookmarkRoots {
    let suffix = engine.isEmpty ? "default" : engine
    return BookmarkRoots(bar: "bar@\(suffix)", other: "other@\(suffix)")
  }

  public func document(profiles: [String], preserving previous: JSONValue = [:]) -> JSONValue {
    var documentNodes: JSONObject = [:]
    for id in order {
      guard let node = nodes[id] else { continue }
      var value: JSONObject = ["id": .string(id), "kind": node["kind"] ?? "folder", "parentId": node["parent"] ?? .null, "title": node["title"] ?? "", "addedAt": node["addedAt"] ?? 0]
      if node["kind"] == "folder" { value["children"] = JSONValue(children[id] ?? []) }
      else {
        value["url"] = node["url"] ?? ""
        value["favicon"] = previous["nodes"]?[id]?["favicon"] ?? .null
      }
      if node["key"]?.truthy == true { value["syncKey"] = node["key"] }
      documentNodes[id] = .object(value)
    }
    var roots: JSONObject = [:]
    if let root = order.first(where: { nodes[$0]?["parent"]?.isNull == true }), let other = order.first(where: { nodes[$0]?["parent"]?.isNull == true && JSKey($0) != JSKey(root) }) {
      for (id, title) in [(root, "Bookmarks Bar"), (other, "Other Bookmarks")] {
        var node = documentNodes[id]?.object ?? [:]
        node["title"] = .string(title)
        documentNodes[id] = .object(node)
      }
      for profile in profiles { roots[profile] = ["bar": .string(root), "other": .string(other)] }
    }
    return ["nodes": .object(documentNodes), "roots": .object(roots)]
  }
}

public struct BookmarkReplayResult: Equatable, Sendable {
  public let tree: BookmarkFlat
  public let structuralBreak: Int?
}

public enum BookmarkReconcile {
  static func same(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSKey(lhs) == JSKey(rhs)
  }

  static func spliceIndex(_ number: Double?, count: Int, clampNegative: Bool = false) -> Int {
    guard let number else { return count }
    if number.isNaN { return 0 }
    if number == .infinity { return count }
    if number == -.infinity { return 0 }
    let rounded = number.rounded(.towardZero)
    if rounded >= Double(count) { return count }
    if rounded < 0 { return clampNegative ? 0 : max(0, count + Int(max(rounded, -Double(count)))) }
    return Int(rounded)
  }

  static func removeSplice(_ values: inout [String], _ id: String) {
    guard !values.isEmpty else { return }
    values.remove(at: values.firstIndex(where: { same($0, id) }) ?? values.count - 1)
  }

  static func keepsURL(_ url: String) -> Bool {
    let units = Array(url.utf16)
    guard let first = units.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
    var at = 1
    while at < units.count {
      let unit = units[at]
      if unit == 58 { return at + 1 < units.count && ![10, 13, 0x2028, 0x2029].contains(units[at + 1]) }
      guard (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || [43, 46, 45].contains(unit) else { return false }
      at += 1
    }
    return false
  }

  private static func alignedTargets(_ targets: [String], folder: String, nodes: JSONObject) -> Bool {
    var seen: Set<JSKey> = [JSKey(folder)]
    return targets.allSatisfy { nodes[$0] != nil && seen.insert(JSKey($0)).inserted }
  }

  private static func addOperation(_ id: String, node: JSONValue, parent: String, index: Int) -> JSONValue {
    var op: JSONObject = ["op": "add", "id": .string(id), "k": node["kind"] == "url" ? "u" : "f", "t": node["title"] ?? ""]
    if let url = node["url"] { op["u"] = url }
    op["a"] = node["addedAt"] ?? 0
    if node["key"]?.truthy == true { op["key"] = node["key"] }
    op["parent"] = .string(parent)
    op["index"] = JSONValue(index)
    return .object(op)
  }

  private static func updateOperation(_ id: String, was: JSONValue?, node: JSONValue) -> JSONValue? {
    guard let was, was["title"] != node["title"] || (node["url"] != nil && was["url"] != node["url"]) else { return nil }
    var op: JSONObject = ["op": "update", "id": .string(id), "t": node["title"] ?? ""]
    if let url = node["url"] { op["u"] = url }
    return .object(op)
  }

  private static func moveIntoPlace(_ id: String, at index: Int, in list: inout [String]) -> Bool {
    guard index < list.count else { return false }
    guard let found = list[index...].firstIndex(where: { same($0, id) }) else { return false }
    guard found != index else { return true }
    let moved = list[found]
    for position in stride(from: found, to: index, by: -1) { list[position] = list[position - 1] }
    list[index] = moved
    return true
  }

  private final class SourceChildren {
    private let values: [String]
    private var first: [JSKey: Int] = [:]
    private var next: [Int]
    private var removed: [Bool]
    private var tail: Int

    init(_ values: [String]) {
      self.values = values
      next = Array(repeating: -1, count: values.count)
      removed = Array(repeating: false, count: values.count)
      tail = values.count - 1
      for index in values.indices.reversed() {
        let key = JSKey(values[index])
        next[index] = first[key] ?? -1
        first[key] = index
      }
    }

    func remove(_ id: String) {
      let key = JSKey(id)
      var index = first[key] ?? -1
      while index >= 0 && removed[index] { index = next[index] }
      first[key] = index >= 0 && next[index] >= 0 ? next[index] : nil
      let position = index >= 0 ? index : tail
      guard position >= 0 else { return }
      removed[position] = true
      while tail >= 0 && removed[tail] { tail -= 1 }
    }

    var remaining: [String] {
      values.indices.compactMap { removed[$0] ? nil : values[$0] }
    }
  }

  public static func operations(from: BookmarkFlat, to: BookmarkFlat, engine: String) -> [JSONValue] {
    let roots = BookmarkFlat.roots(engine)
    var parents = from.nodes.mapValues { $0["parent"] ?? .null }
    var kids = from.children
    var sources: [JSKey: SourceChildren] = [:]
    var ops: [JSONValue] = []
    var queue = [roots.bar, roots.other]
    var cursor = 0
    func opParent(_ id: String) -> String { same(id, roots.bar) ? "bar" : same(id, roots.other) ? "other" : id }
    func restoreChildren(_ folder: String) {
      if let source = sources.removeValue(forKey: JSKey(folder)) { kids[folder] = source.remaining }
    }
    func removeFromSource(_ id: String, parent: String) {
      let key = JSKey(parent)
      if let source = sources[key] {
        source.remove(id)
      } else if let values = kids.removeValue(forKey: parent) {
        let source = SourceChildren(values)
        source.remove(id)
        sources[key] = source
      }
    }
    func resetChildren(_ folder: String) {
      sources.removeValue(forKey: JSKey(folder))
      kids[folder] = []
    }
    while cursor < queue.count {
      let folder = queue[cursor]
      cursor += 1
      restoreChildren(folder)
      if kids[folder] == nil { kids[folder] = [] }
      let targets = to.children[folder] ?? []
      if alignedTargets(targets, folder: folder, nodes: to.nodes) {
        var current = kids.removeValue(forKey: folder) ?? []
        for (index, id) in targets.enumerated() {
          let node = to.nodes[id]!
          if parents[id] == nil {
            ops.append(addOperation(id, node: node, parent: opParent(folder), index: index))
            current.insert(id, at: min(index, current.count))
            parents[id] = .string(folder)
            if node["kind"] == "folder" { resetChildren(id) }
          } else {
            let inFolder = parents[id] == .string(folder)
            if !(inFolder && index < current.count && same(current[index], id)) {
              if inFolder {
                if !moveIntoPlace(id, at: index, in: &current) {
                  removeSplice(&current, id)
                  current.insert(id, at: min(index, current.count))
                }
              } else {
                if let parent = parents[id]?.string { removeFromSource(id, parent: parent) }
                current.insert(id, at: min(index, current.count))
              }
              parents[id] = .string(folder)
              ops.append(["op": "move", "id": .string(id), "parent": .string(opParent(folder)), "index": JSONValue(index)])
            }
            if let update = updateOperation(id, was: from.nodes[id], node: node) { ops.append(update) }
          }
          if node["kind"] == "folder" { queue.append(id) }
        }
        kids[folder] = current
        continue
      }
      for (index, id) in targets.enumerated() {
        guard let node = to.nodes[id] else { continue }
        if parents[id] == nil {
          ops.append(addOperation(id, node: node, parent: opParent(folder), index: index))
          var list = kids[folder] ?? []
          list.insert(id, at: min(index, list.count))
          kids[folder] = list
          parents[id] = .string(folder)
          if node["kind"] == "folder" { resetChildren(id) }
        } else {
          if parents[id] != .string(folder) || (kids[folder] ?? []).firstIndex(where: { same($0, id) }) != index {
            if let parent = parents[id]?.string {
              if same(parent, folder) {
                var old = kids[parent] ?? []
                removeSplice(&old, id)
                kids[parent] = old
              } else {
                removeFromSource(id, parent: parent)
              }
            }
            var list = kids[folder] ?? []
            list.insert(id, at: min(index, list.count))
            kids[folder] = list
            parents[id] = .string(folder)
            ops.append(["op": "move", "id": .string(id), "parent": .string(opParent(folder)), "index": JSONValue(index)])
          }
          if let update = updateOperation(id, was: from.nodes[id], node: node) { ops.append(update) }
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

  public static func replayPending(_ tree: BookmarkFlat, operations: [JSONValue], engine: String) -> BookmarkReplayResult {
    replay(tree, operations: operations, engine: engine, satisfiedRemovals: true)
  }

  public static func replay(_ tree: BookmarkFlat, operations: [JSONValue], engine: String) -> BookmarkReplayResult {
    replay(tree, operations: operations, engine: engine, satisfiedRemovals: false)
  }

  private static func replay(_ tree: BookmarkFlat, operations: [JSONValue], engine: String, satisfiedRemovals: Bool) -> BookmarkReplayResult {
    var flat = tree
    let roots = BookmarkFlat.roots(engine)
    func parentID(_ parent: String) -> String { same(parent, "bar") ? roots.bar : same(parent, "other") ? roots.other : parent }
    func detach(_ id: String) {
      if let parent = flat.nodes[id]?["parent"]?.string, var list = flat.children[parent] {
        removeSplice(&list, id)
        flat.children[parent] = list
      }
    }
    func attach(_ id: String, parent: String, index: Double?) {
      var list = flat.children[parent] ?? []
      list.insert(id, at: spliceIndex(index, count: list.count, clampNegative: true))
      flat.children[parent] = list
      var node = flat.nodes[id]?.object ?? [:]
      node["parent"] = .string(parent)
      flat.nodes[id] = .object(node)
    }
    func inside(_ id: String, parent: String) -> Bool {
      var at: String? = parent
      var visited = Set<JSKey>()
      while let current = at, visited.insert(JSKey(current)).inserted {
        if same(id, current) { return true }
        at = flat.nodes[current]?["parent"]?.string
      }
      return false
    }
    func drop(_ id: String) {
      for child in flat.children[id] ?? [] { drop(child) }
      flat.nodes.removeValue(forKey: id)
      flat.children.removeValue(forKey: id)
      flat.order.removeAll { same($0, id) }
    }
    for (offset, op) in operations.enumerated() {
      guard let id = op["id"]?.string else { return BookmarkReplayResult(tree: flat, structuralBreak: offset) }
      let node = flat.nodes[id]
      let kind = op["op"]?.string ?? ""
      if kind == "remove" {
        if node == nil && satisfiedRemovals { continue }
        guard let node, node["parent"]?.isNull == false else { return BookmarkReplayResult(tree: flat, structuralBreak: offset) }
        detach(id)
        drop(id)
        continue
      }
      if kind == "update" {
        guard let node, node["parent"]?.isNull == false else { return BookmarkReplayResult(tree: flat, structuralBreak: offset) }
        var next = node.object ?? [:]
        if let title = op["t"] { next["title"] = title }
        if let url = op["u"]?.string, !url.isEmpty, node["kind"] == "url", keepsURL(url) { next["url"] = .string(url) }
        flat.nodes[id] = .object(next)
        continue
      }
      let parent = parentID(op["parent"]?.string ?? "")
      guard flat.nodes[parent]?["kind"] == "folder" else { return BookmarkReplayResult(tree: flat, structuralBreak: offset) }
      if kind == "add", node != nil, op["ifAbsent"]?.truthy == true { continue }
      if kind == "move" || node != nil {
        guard let node, node["parent"]?.isNull == false, !inside(id, parent: parent) else { return BookmarkReplayResult(tree: flat, structuralBreak: offset) }
        detach(id)
        attach(id, parent: parent, index: op["index"]?.number)
        if kind == "add" {
          var next = flat.nodes[id]?.object ?? [:]
          next["title"] = op["t"]
          if let url = op["u"]?.string, !url.isEmpty, node["kind"] == "url", keepsURL(url) { next["url"] = .string(url) }
          flat.nodes[id] = .object(next)
        }
        continue
      }
      if op["k"] == "u", !keepsURL(op["u"]?.string ?? "") { continue }
      var next: JSONObject = ["kind": op["k"] == "u" ? "url" : "folder", "parent": .string(parent), "title": op["t"] ?? "", "addedAt": op["a"] ?? 0]
      if op["k"] == "u" { next["url"] = op["u"] ?? "" }
      if op["key"]?.truthy == true { next["key"] = op["key"] }
      flat.nodes[id] = .object(next)
      flat.order.append(id)
      if op["k"] == "f" { flat.children[id] = [] }
      attach(id, parent: parent, index: op["index"]?.number)
    }
    return BookmarkReplayResult(tree: flat, structuralBreak: nil)
  }
}
