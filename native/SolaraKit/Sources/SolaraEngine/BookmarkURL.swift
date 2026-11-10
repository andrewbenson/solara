import Foundation
import SolaraModel

public struct BookmarkWireURL: Equatable, Sendable {
  public let wire: String
  public let canonical: String
  public let conversionOnly: Bool

  public init(wire: String, canonical: String, conversionOnly: Bool = true) { self.wire = wire; self.canonical = canonical; self.conversionOnly = conversionOnly }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    JSKey(lhs.wire) == JSKey(rhs.wire) && JSKey(lhs.canonical) == JSKey(rhs.canonical) && lhs.conversionOnly == rhs.conversionOnly
  }
}

enum BookmarkURLProjection {
  static func normalize(_ document: JSONValue, preserving previous: JSMap<BookmarkWireURL> = [:], captureWire: Bool, canonicalURL: (String) throws -> String) throws -> (document: JSONValue, wireURLs: JSMap<BookmarkWireURL>) {
    var nodes = document["nodes"]?.object ?? [:]
    var wireURLs: JSMap<BookmarkWireURL> = [:]
    for (id, value) in nodes where value["kind"] == "url" {
      guard var node = value.object, let wire = node["url"]?.string else { throw BookmarkCoordinatorError.invalidOperation("A bookmark URL must be a string") }
      let canonical = try canonicalURL(wire)
      guard !canonical.isEmpty else { throw BookmarkCoordinatorError.invalidOperation("A bookmark URL cannot be empty") }
      node["url"] = .string(canonical)
      nodes[id] = .object(node)
      if let saved = previous[id], JSKey(saved.canonical) == JSKey(canonical), (JSKey(wire) == JSKey(saved.canonical) || JSKey(wire) == JSKey(saved.wire)) {
        wireURLs[id] = saved
      } else if captureWire, JSKey(wire) != JSKey(canonical) {
        let conversionOnly = previous[id].map { JSKey($0.wire) == JSKey(wire) ? $0.conversionOnly : true } ?? true
        wireURLs[id] = BookmarkWireURL(wire: wire, canonical: canonical, conversionOnly: conversionOnly)
      }
    }
    var value = document.object ?? [:]
    value["nodes"] = .object(nodes)
    return (.object(value), wireURLs)
  }

  static func retaining(_ previous: JSMap<BookmarkWireURL>, in document: JSONValue) -> JSMap<BookmarkWireURL> {
    previous.filter { id, value in document["nodes"]?[id]?["kind"] == "url" && document["nodes"]?[id]?["url"] == .string(value.canonical) }
  }

  static func markingEdits(_ previous: JSMap<BookmarkWireURL>, before: JSONValue, after: JSONValue) -> JSMap<BookmarkWireURL> {
    var retained = retaining(previous, in: after)
    guard retained.values.contains(where: { $0.conversionOnly }) else { return retained }
    let oldNodes = before["nodes"]?.object ?? [:]
    let newNodes = after["nodes"]?.object ?? [:]
    let common = Set(oldNodes.keys.filter { newNodes[$0] != nil && oldNodes[$0]?["parentId"] == newNodes[$0]?["parentId"] }.map(JSKey.init))
    func positions(_ document: JSONValue) -> JSMap<Int> {
      var positions: JSMap<Int> = [:]
      for (_, node) in document["nodes"]?.object ?? [:] {
        let children = (node["children"]?.array?.compactMap(\.string) ?? []).filter { common.contains(JSKey($0)) }
        for (index, child) in children.enumerated() { positions[child] = index }
      }
      return positions
    }
    let oldPositions = positions(before)
    let newPositions = positions(after)
    for (id, value) in retained where value.conversionOnly {
      let changed = ["kind", "parentId", "title", "url", "addedAt", "syncKey"].contains { before["nodes"]?[id]?[$0] != after["nodes"]?[id]?[$0] }
      if changed || oldPositions[id] != newPositions[id] {
        retained[id] = BookmarkWireURL(wire: value.wire, canonical: value.canonical, conversionOnly: false)
      }
    }
    return retained
  }

  static func wireDocument(_ document: JSONValue, urls: JSMap<BookmarkWireURL>) -> JSONValue {
    var nodes = document["nodes"]?.object ?? [:]
    for (id, value) in retaining(urls, in: document) {
      var node = nodes[id]?.object ?? [:]
      node["url"] = .string(value.wire)
      nodes[id] = .object(node)
    }
    var value = document.object ?? [:]
    value["nodes"] = .object(nodes)
    return .object(value)
  }
}
