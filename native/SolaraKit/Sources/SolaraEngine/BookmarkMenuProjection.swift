import SolaraModel

public struct BookmarkMenuProjection: Sendable {
  public struct Row: Sendable {
    public let id: String
    public let title: String
    public let url: String?
    public let children: [Row]?
  }

  public let folders: [Row]
  public let recent: [Row]
  public let bar: [Row]
  public let other: [Row]

  public init(document: JSONValue, profile: String, engine: String) {
    let nodes = document["nodes"]?.object ?? [:]
    let roots = Self.roots(document, profile: profile, engine: engine)
    let barId = roots.bar, otherId = roots.other
    let rootIds: Set<JSKey> = [JSKey(barId), JSKey(otherId)]

    func children(_ id: String) -> [String] {
      nodes[id]?["children"]?.array?.compactMap(\.string).filter { nodes[$0] != nil } ?? []
    }

    func link(_ id: String, _ node: JSONValue) -> Row {
      let url = node["url"]?.string ?? ""
      let title = node["title"]?.string ?? ""
      return Row(id: id, title: title.isEmpty ? url : title, url: url, children: nil)
    }

    func tree(_ parent: String, depth: Int = 0) -> [Row] {
      children(parent).compactMap { id in
        guard let node = nodes[id] else { return nil }
        if node["kind"] == "url" { return link(id, node) }
        return Row(id: id, title: node["title"]?.string ?? "", url: nil,
                   children: depth < 6 ? tree(id, depth: depth + 1) : [])
      }
    }

    let links = nodes.enumerated().filter { $0.element.value["kind"] == "url" && Self.belongs($0.element.key, to: rootIds, nodes: nodes) }
    recent = links.sorted {
      let a = $0.element.value["addedAt"]?.number ?? 0
      let b = $1.element.value["addedAt"]?.number ?? 0
      return a == b ? $0.offset < $1.offset : a > b
    }.prefix(5).map { link($0.element.key, $0.element.value) }
    folders = [Row(id: barId, title: "Bookmarks Bar", url: nil, children: nil),
               Row(id: otherId, title: "Other Bookmarks", url: nil, children: nil)]
      + (children(barId) + children(otherId)).filter { nodes[$0]?["kind"] == "folder" }.map {
        Row(id: $0, title: nodes[$0]?["title"]?.string ?? "", url: nil, children: nil)
      }
    bar = tree(barId)
    other = tree(otherId)
  }

  public static func contains(url: String, document: JSONValue, profile: String, engine: String) -> Bool {
    let nodes = document["nodes"]?.object ?? [:]
    let roots = roots(document, profile: profile, engine: engine)
    let rootIds: Set<JSKey> = [JSKey(roots.bar), JSKey(roots.other)]
    return nodes.contains { id, node in
      node["kind"] == "url" && node["url"] == .string(url) && belongs(id, to: rootIds, nodes: nodes)
    }
  }

  private static func roots(_ document: JSONValue, profile: String, engine: String) -> (bar: String, other: String) {
    let defaults = BookmarkFlat.roots(engine)
    return (document["roots"]?[profile]?["bar"]?.string ?? defaults.bar,
            document["roots"]?[profile]?["other"]?.string ?? defaults.other)
  }

  private static func belongs(_ id: String, to roots: Set<JSKey>, nodes: JSONObject) -> Bool {
    var current: String? = id
    var seen = Set<JSKey>()
    while let id = current, seen.count < 64, seen.insert(JSKey(id)).inserted {
      if roots.contains(JSKey(id)) { return true }
      current = nodes[id]?["parentId"]?.string
    }
    return false
  }
}
