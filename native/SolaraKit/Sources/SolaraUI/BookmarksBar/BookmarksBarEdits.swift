import SolaraEngine
import SolaraModel

@MainActor
public struct BookmarksBarEdits {
  public let nodes: JSONObject
  private let profile: String
  private let bar: String
  private let other: String

  public init(profile: String, bar: String, other: String, document: JSONValue) {
    self.profile = profile
    self.bar = bar
    self.other = other
    nodes = document["nodes"]?.object ?? [:]
  }

  public static func acceptsTab(sourceWindow: String, targetProfile: String, tabWindow: String, tabProfile: String) -> Bool {
    sourceWindow == tabWindow && targetProfile == tabProfile
  }

  public func children(_ id: String) -> [String] {
    nodes[id]?["children"]?.array?.compactMap(\.string) ?? []
  }

  public func contains(_ id: String) -> Bool {
    var current = id
    var seen = Set<JSKey>()
    while seen.count < 64, seen.insert(JSKey(current)).inserted, let node = nodes[current] {
      if JSKey(current) == JSKey(bar) || JSKey(current) == JSKey(other) { return true }
      guard let parent = node["parentId"]?.string, children(parent).contains(where: { JSKey($0) == JSKey(current) }) else { return false }
      current = parent
    }
    return false
  }

  public func move(_ id: String, into: String?, index: Int?, listed: [String]) -> [BookmarkMutation] {
    guard nodes[bar]?["kind"] == "folder", children(bar) == listed, listed.contains(id),
      let source = nodes[id], source["parentId"] == .string(bar) else { return [] }
    var conditions = [expectChildren(bar, listed)]
    let destination: String
    if let into {
      guard into != id, listed.contains(into), let folder = nodes[into], folder["kind"] == "folder",
        folder["parentId"] == .string(bar) else { return [] }
      conditions.append(.init(method: "expectBookmarkNodes", args: [[id: source, into: folder]]))
      destination = into
    } else {
      guard let index, listed.indices.contains(index) else { return [] }
      destination = bar
    }
    return conditions + [.init(method: "moveBookmark", args: [.string(id), .string(destination), index.map { JSONValue($0) } ?? .null])]
  }

  public func drop(_ links: [BookmarksBarDroppedLink], parent: String, index: Int?, listed: [String]?) -> [BookmarkMutation] {
    guard let node = nodes[parent], node["kind"] == "folder" else { return [] }
    let condition: BookmarkMutation
    if parent == bar {
      guard let index, let listed, children(bar) == listed, (0...listed.count).contains(index) else { return [] }
      condition = expectChildren(bar, listed)
    } else {
      guard index == nil, parent == other || (node["parentId"] == .string(bar) && children(bar).contains(parent)) else { return [] }
      condition = .init(method: "expectBookmarkNodes", args: [[parent: node]])
    }
    let valid = links.compactMap { link in
      BookmarksBarLinkDrop.webURL(link.url).map { BookmarksBarDroppedLink(url: $0, title: link.title.jsTrim()) }
    }
    guard !valid.isEmpty else { return [] }
    return [condition] + valid.enumerated().map { offset, link in
      .init(method: "addBookmark", args: [[
        "profileId": .string(profile), "parentId": .string(parent), "index": index.map { JSONValue($0 + offset) } ?? .null,
        "title": .string(link.title.isEmpty ? link.url : link.title), "url": .string(link.url),
      ]])
    }
  }

  private func expectChildren(_ id: String, _ listed: [String]) -> BookmarkMutation {
    .init(method: "expectChildren", args: [.string(profile), .string(id), JSONValue(listed)])
  }
}
