import Foundation
import SolaraEngine
import SolaraModel
import SolaraOmnibox

public struct BookmarksBarItem: Decodable, Equatable, Sendable {
  public enum Kind: String, Decodable, Sendable {
    case url, folder
  }

  public var id: String
  public var kind: Kind
  public var title: String
  public var url: String?
  public var favicon: String?
  public var cleanUrl: String?
  public var children: [BookmarksBarItem]
  public var folderLinks: Int
  public var makesGroup: Bool
  public var restorableArcHolder: Bool

  public init(id: String, kind: Kind, title: String, url: String? = nil, favicon: String? = nil, cleanUrl: String? = nil, children: [BookmarksBarItem] = [], folderLinks: Int = 0, makesGroup: Bool = false, restorableArcHolder: Bool = false) {
    self.id = id
    self.kind = kind
    self.title = title
    self.url = url
    self.favicon = favicon
    self.cleanUrl = cleanUrl
    self.children = children
    self.folderLinks = folderLinks
    self.makesGroup = makesGroup
    self.restorableArcHolder = restorableArcHolder
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, url, favicon, cleanUrl, children, folderLinks, makesGroup, restorableArcHolder
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    kind = try values.decode(Kind.self, forKey: .kind)
    title = try values.decode(String.self, forKey: .title)
    url = try values.decodeIfPresent(String.self, forKey: .url)
    favicon = try values.decodeIfPresent(String.self, forKey: .favicon)
    cleanUrl = try values.decodeIfPresent(String.self, forKey: .cleanUrl)
    children = try values.decodeIfPresent([BookmarksBarItem].self, forKey: .children) ?? []
    folderLinks = try values.decodeIfPresent(Int.self, forKey: .folderLinks) ?? 0
    makesGroup = try values.decodeIfPresent(Bool.self, forKey: .makesGroup) ?? false
    restorableArcHolder = try values.decodeIfPresent(Bool.self, forKey: .restorableArcHolder) ?? false
  }

  public var displayTitle: String { title.isEmpty && kind == .url ? url ?? "" : title }
}

public struct BookmarksBarSnapshot: Decodable, Equatable, Sendable {
  public var profileId: String
  public var items: [BookmarksBarItem]
  public var otherId: String?
  public var hasOther: Bool
  public var hideBookmarksBarImport: Bool
  public var theme: [String: String]
  public var dark: Bool
  public var sidebarEdge: CGFloat?
  public var barId: String?
  public var otherFolder: BookmarksBarItem?
  public var bookmarksBar: String

  public init(profileId: String, items: [BookmarksBarItem], otherId: String? = nil, hasOther: Bool, hideBookmarksBarImport: Bool, theme: [String: String], dark: Bool = false, sidebarEdge: CGFloat? = nil, barId: String? = nil, otherFolder: BookmarksBarItem? = nil, bookmarksBar: String = "always") {
    self.profileId = profileId
    self.items = items
    self.otherId = otherId
    self.hasOther = hasOther
    self.hideBookmarksBarImport = hideBookmarksBarImport
    self.theme = theme
    self.dark = dark
    self.sidebarEdge = sidebarEdge
    self.barId = barId
    self.otherFolder = otherFolder
    self.bookmarksBar = bookmarksBar
  }

  private enum CodingKeys: String, CodingKey {
    case profileId, items, otherId, hasOther, hideBookmarksBarImport, theme, dark, sidebarEdge, barId, otherFolder, bookmarksBar
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    profileId = try values.decode(String.self, forKey: .profileId)
    items = try values.decode([BookmarksBarItem].self, forKey: .items)
    otherId = try values.decodeIfPresent(String.self, forKey: .otherId)
    hasOther = try values.decode(Bool.self, forKey: .hasOther)
    hideBookmarksBarImport = try values.decode(Bool.self, forKey: .hideBookmarksBarImport)
    theme = try values.decode([String: String].self, forKey: .theme)
    dark = try values.decodeIfPresent(Bool.self, forKey: .dark) ?? false
    sidebarEdge = try values.decodeIfPresent(CGFloat.self, forKey: .sidebarEdge)
    barId = try values.decodeIfPresent(String.self, forKey: .barId)
    otherFolder = try values.decodeIfPresent(BookmarksBarItem.self, forKey: .otherFolder)
    bookmarksBar = try values.decodeIfPresent(String.self, forKey: .bookmarksBar) ?? "always"
  }
}

public extension BookmarksBarSnapshot {
  func reading(_ document: JSONValue, engine: String) -> Self {
    let nodes = document["nodes"]?.object ?? [:]
    let roots = BookmarkFlat.roots(engine)
    let bar = document["roots"]?[profileId]?["bar"]?.string ?? roots.bar
    let other = document["roots"]?[profileId]?["other"]?.string ?? roots.other
    var summaries: [JSKey: (links: Int, groupable: Bool)] = [:]
    var visiting = Set<JSKey>()
    func summary(_ id: String) -> (links: Int, groupable: Bool) {
      let key = JSKey(id)
      if let cached = summaries[key] { return cached }
      guard !visiting.contains(key), let node = nodes[id] else { return (0, false) }
      if node["kind"] == "url" {
        let url = node["url"]?.string?.lowercased() ?? ""
        return (1, url.hasPrefix("http:") || url.hasPrefix("https:") || url.hasPrefix("file:"))
      }
      visiting.insert(key)
      var result = (links: 0, groupable: false)
      for child in node["children"]?.array?.compactMap(\.string) ?? [] {
        let value = summary(child)
        result.links += value.links
        result.groupable = result.groupable || value.groupable
      }
      visiting.remove(key)
      summaries[key] = result
      return result
    }
    func build(_ id: String, depth: Int) -> BookmarksBarItem? {
      guard let node = nodes[id], let kind = node["kind"]?.string.flatMap(BookmarksBarItem.Kind.init(rawValue:)) else { return nil }
      let title = node["title"]?.string ?? ""
      let url = node["url"]?.string
      if kind == .url { return BookmarksBarItem(id: id, kind: kind, title: title, url: url, favicon: node["favicon"]?.string, cleanUrl: url.map(cleanUrl)) }
      let ids = node["children"]?.array?.compactMap(\.string) ?? []
      let info = summary(id)
      let restorable = title.hasSuffix(" (Arc)") && node["parentId"]?.string.map(JSKey.init) == JSKey(bar)
        && ids.contains { nodes[$0]?["kind"] == "folder" && summary($0).groupable }
      return BookmarksBarItem(id: id, kind: kind, title: title, children: depth < 8 ? ids.compactMap { build($0, depth: depth + 1) } : [], folderLinks: info.links, makesGroup: info.groupable, restorableArcHolder: restorable)
    }
    var result = self
    result.barId = nodes[bar]?["kind"] == "folder" ? bar : nil
    result.items = result.barId == nil ? [] : (nodes[bar]?["children"]?.array?.compactMap(\.string) ?? []).compactMap { build($0, depth: -1) }
    result.otherId = nodes[other]?["kind"] == "folder" ? other : nil
    result.otherFolder = result.otherId.flatMap { build($0, depth: -1) }
    result.hasOther = result.otherId != nil && !(nodes[other]?["children"]?.array?.isEmpty ?? true)
    return result
  }
}
