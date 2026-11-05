import Foundation

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
