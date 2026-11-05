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

  public init(id: String, kind: Kind, title: String, url: String? = nil, favicon: String? = nil) {
    self.id = id
    self.kind = kind
    self.title = title
    self.url = url
    self.favicon = favicon
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

  public init(profileId: String, items: [BookmarksBarItem], otherId: String? = nil, hasOther: Bool, hideBookmarksBarImport: Bool, theme: [String: String], dark: Bool = false) {
    self.profileId = profileId
    self.items = items
    self.otherId = otherId
    self.hasOther = hasOther
    self.hideBookmarksBarImport = hideBookmarksBarImport
    self.theme = theme
    self.dark = dark
  }

  private enum CodingKeys: String, CodingKey {
    case profileId, items, otherId, hasOther, hideBookmarksBarImport, theme, dark
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
  }
}
