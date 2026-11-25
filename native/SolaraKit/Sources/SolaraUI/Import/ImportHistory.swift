import Foundation

public struct ImportHistoryRow: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let url: String
  public let title: String
  public let visits: Int
  public let lastVisit: Double

  public init(url: String, title: String, visits: Int, lastVisit: Double) {
    self.url = url
    self.title = title
    self.visits = visits
    self.lastVisit = lastVisit
  }

  public var description: String { "ImportHistoryRow" }
  public var debugDescription: String { "ImportHistoryRow" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ImportFaviconRow: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let page: String
  public let icon: String
  public let png: String

  public init(page: String, icon: String, png: String) {
    self.page = page
    self.icon = icon
    self.png = png
  }

  public var description: String { "ImportFaviconRow" }
  public var debugDescription: String { "ImportFaviconRow" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum ImportHistory {
  nonisolated(unsafe) static let pattern = try! NSRegularExpression(pattern: "^(https?|file):")

  public static func usable(_ rows: [ImportHistoryRow]) -> [ImportHistoryRow] {
    rows.filter { pattern.firstMatch(in: $0.url, range: NSRange(location: 0, length: ($0.url as NSString).length)) != nil }
  }

  public static let adoptDeadlineCap: TimeInterval = 10
  public static let adoptSecondsPerRow: TimeInterval = 0.0001

  public static func adoptDeadline(rows: Int) -> TimeInterval {
    min(adoptDeadlineCap, 1.5 + Double(rows) * adoptSecondsPerRow)
  }

  public static let storeKeeps = 5000

  public static func fallbackCount(_ rows: [ImportHistoryRow]) -> Int { min(distinctCount(rows), storeKeeps) }

  public static func distinctCount(_ rows: [ImportHistoryRow]) -> Int {
    Set(rows.map { Array($0.url.utf16) }).count
  }
}

public enum ImportFavicons {
  static let lineTerminators: Set<UInt16> = [0x0A, 0x0D, 0x2028, 0x2029]

  public static func page(_ url: String) -> String {
    let units = Array(url.utf16)
    var index = 0
    while index < units.count {
      if units[index] == 0x23, !units[(index + 1)...].contains(where: lineTerminators.contains) {
        return String(decoding: units[..<index], as: UTF16.self)
      }
      index += 1
    }
    return url
  }

  static func links(_ nodes: [ImportBookmarkNode]) -> [String] {
    nodes.flatMap { node -> [String] in
      if node.isFolder { return links(node.children ?? []) }
      guard let url = node.url, !url.isEmpty else { return [] }
      return [url]
    }
  }

  public static func pages(_ read: ImportRead) -> [String] {
    let toolbar = (read.bookmarks?.children ?? []).filter { $0.role == "toolbar" }
    return read.favorites.map(\.url) + (read.hasSpaces ? [] : read.tabs.map(\.url)) + links(toolbar)
  }

  public static func chosen(_ read: ImportRead) -> [ImportFaviconRow] {
    chosen(read.favicons, pages: pages(read))
  }

  public static func chosen(_ favicons: [ImportFaviconRow], pages: [String]) -> [ImportFaviconRow] {
    guard !favicons.isEmpty, !pages.isEmpty else { return [] }
    let wanted = Set(pages.map { Array(page($0).utf16) })
    return favicons.filter { wanted.contains(Array(page($0.page).utf16)) }
  }

  public static func byPage(_ favicons: [ImportFaviconRow]) -> [(page: String, favicon: ImportFaviconRow)] {
    var order: [[UInt16]] = []
    var found: [[UInt16]: (String, ImportFaviconRow)] = [:]
    for favicon in favicons {
      let key = page(favicon.page)
      let units = Array(key.utf16)
      if found[units] == nil { order.append(units) }
      found[units] = (key, favicon)
    }
    return order.compactMap { found[$0].map { (page: $0.0, favicon: $0.1) } }
  }
}
