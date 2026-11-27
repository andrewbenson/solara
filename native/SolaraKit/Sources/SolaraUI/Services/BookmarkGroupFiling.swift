import SolaraModel
import SolaraStore

public enum BookmarkGroupDraft {
  public static func folder(_ id: String, nodes: JSONObject) -> JSONValue? {
    guard nodes[id]?["kind"] == "folder" else { return nil }
    var seen: Set<JSKey> = []
    var expected: JSONObject = [:]
    var links: [String: String] = [:]
    guard let draft = build(id, nodes: nodes, depth: 0, seen: &seen, expected: &expected, links: &links),
      !links.isEmpty else { return nil }
    return draft
  }

  static func build(_ id: String, nodes: JSONObject, depth: Int, seen: inout Set<JSKey>,
    expected: inout JSONObject, links: inout [String: String]) -> JSONValue? {
    guard depth < 64, seen.insert(JSKey(id)).inserted, let node = nodes[id] else { return nil }
    expected[id] = node
    let title = String(decoding: BookmarkString.units(node["title"]?.string ?? ""), as: UTF16.self)
    var draft: JSONObject = ["id": .string(id), "title": .string(title)]
    switch node["kind"] {
    case "url":
      guard let url = node["url"]?.string else { return nil }
      draft["url"] = .string(String(decoding: BookmarkString.units(url), as: UTF16.self))
      if ["http:", "https:", "file:"].contains(where: url.lowercased().hasPrefix) { links[id] = url }
    case "folder":
      var children: [JSONValue] = []
      for child in node["children"]?.array?.compactMap(\.string) ?? [] where nodes[child]?["parentId"] == .string(id) {
        if let item = build(child, nodes: nodes, depth: depth + 1, seen: &seen, expected: &expected, links: &links) {
          children.append(item)
        }
      }
      draft["children"] = .array(children)
    default: return nil
    }
    return .object(draft)
  }
}

@MainActor
public final class BookmarkGroupFiling {
  private var pending: Set<String> = []

  public init() {}

  public func run<Receipt>(_ id: String, save: @MainActor () async throws -> Receipt,
    didSave: @MainActor (Receipt) async throws -> Void) async throws {
    guard pending.insert(id).inserted else { return }
    defer { pending.remove(id) }
    let receipt = try await save()
    try await didSave(receipt)
  }
}
