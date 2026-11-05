import AppKit

public struct BookmarksBarDroppedLink: Equatable, Sendable {
  public var url: String
  public var title: String

  public init(url: String, title: String) {
    self.url = url
    self.title = title
  }

  var json: [String: String] { ["url": url, "title": title] }
}

@MainActor
public enum BookmarksBarLinkDrop {
  public static let urlName = NSPasteboard.PasteboardType("public.url-name")
  public static let webURLsWithTitles = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
  public static let types: [NSPasteboard.PasteboardType] = [.URL, webURLsWithTitles, .string]

  public struct Destination: Equatable, Sendable {
    public var parentId: String
    public var index: Int?
    public var insertionX: CGFloat?

    var json: [String: Any] { ["parentId": parentId, "index": index as Any? ?? NSNull()] }
  }

  public static func webURL(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false,
      text.lowercased().hasPrefix("\(scheme)://"), !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
    return text
  }

  public static func tabs(_ ids: [String], resolve: (String) -> BookmarksBarDroppedLink?) -> [BookmarksBarDroppedLink] {
    ids.compactMap { id in
      guard let link = resolve(id), let url = webURL(link.url) else { return nil }
      return BookmarksBarDroppedLink(url: url, title: link.title)
    }
  }

  public static func links(_ board: NSPasteboard) -> [BookmarksBarDroppedLink] {
    guard board.availableType(from: [.fileURL]) == nil else { return [] }
    if let entries = board.propertyList(forType: webURLsWithTitles) as? [[String]], let urls = entries.first {
      let titles = entries.count > 1 ? entries[1] : []
      return urls.enumerated().compactMap { index, raw in
        webURL(raw).map { BookmarksBarDroppedLink(url: $0, title: titles.indices.contains(index) ? titles[index] : "") }
      }
    }
    return (board.pasteboardItems ?? []).compactMap { item in
      guard !(item.types.contains(.fileURL)) else { return nil }
      if let raw = item.string(forType: .URL) {
        return webURL(raw).map { BookmarksBarDroppedLink(url: $0, title: item.string(forType: urlName) ?? "") }
      }
      return item.string(forType: .string).flatMap(webURL).map { BookmarksBarDroppedLink(url: $0, title: "") }
    }
  }

  public static func destination(snapshot: BookmarksBarSnapshot, visible: [BookmarksBarLayout.Placement], x: CGFloat, folderId: String? = nil) -> Destination? {
    guard x.isFinite, let barId = snapshot.barId else { return nil }
    if let folderId {
      if folderId == snapshot.otherId, snapshot.hasOther { return Destination(parentId: folderId, index: nil, insertionX: nil) }
      guard visible.contains(where: { snapshot.items.indices.contains($0.index) && snapshot.items[$0.index].id == folderId && snapshot.items[$0.index].kind == .folder }) else { return nil }
      return Destination(parentId: folderId, index: nil, insertionX: nil)
    }
    for placement in visible {
      guard snapshot.items.indices.contains(placement.index) else { continue }
      let item = snapshot.items[placement.index]
      let frame = placement.frame
      if item.kind == .folder, x > frame.minX + frame.width * 0.25, x < frame.minX + frame.width * 0.75 {
        return Destination(parentId: item.id, index: nil, insertionX: nil)
      }
      if x < frame.midX { return Destination(parentId: barId, index: placement.index, insertionX: frame.minX - 2) }
    }
    return Destination(parentId: barId, index: snapshot.items.count, insertionX: (visible.last?.frame.maxX ?? 6) + 2)
  }

  #if DEBUG
  public static func devLinks(_ payload: String, resolve: (String) -> BookmarksBarDroppedLink?) -> [BookmarksBarDroppedLink] {
    guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    if let ids = object["tabIds"] as? [String] { return tabs(ids, resolve: resolve) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    if let items = object["items"] as? [[String: String]] {
      let writers = items.compactMap { link -> NSPasteboardItem? in
        guard let url = link["url"] else { return nil }
        let item = NSPasteboardItem()
        item.setString(url, forType: .URL)
        item.setString(link["title"] ?? "", forType: urlName)
        return item
      }
      board.writeObjects(writers)
    } else if let text = object["text"] as? String {
      board.setString(text, forType: .string)
    }
    return links(board)
  }
  #endif
}
