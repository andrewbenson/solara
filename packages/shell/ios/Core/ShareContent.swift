import Foundation

public struct ShareContext: Equatable {
  public var selection: String
  public var link: String
  public var source: String
  public var mediaType: String
  public var page: String
  public var title: String
  public var editable: Bool

  public init(selection: String = "", link: String = "", source: String = "", mediaType: String = "", page: String = "",
    title: String = "", editable: Bool = false)
  {
    self.selection = selection
    self.link = link
    self.source = source
    self.mediaType = mediaType
    self.page = page
    self.title = title
    self.editable = editable
  }

  public init(_ fields: [String: Any]) {
    func text(_ key: String) -> String { fields[key] as? String ?? "" }
    self.init(selection: text("selection"), link: text("link"), source: text("source"), mediaType: text("mediaType"),
      page: text("page"), title: text("title"), editable: fields["editable"] as? Bool ?? false)
  }
}

public enum ShareContent: Equatable {
  case text(String)
  case link(URL, title: String?)
  case image(source: URL?, title: String?)
  case media(URL, title: String?)

  public static func menuItem(for context: ShareContext) -> (id: String, title: String)? {
    switch choose(context) {
    case .text: return ("share:selection", "Share Selection…")
    case .image: return ("share:image", "Share Image…")
    case .media(_, _): return ("share:media", context.mediaType == "audio" ? "Share Audio…" : "Share Video…")
    case .link(_, _): return webURL(context.link) == nil ? ("share:page", "Share Page…") : ("share:link", "Share Link…")
    case nil: return nil
    }
  }

  public static func choose(_ context: ShareContext) -> ShareContent? {
    if let link = webURL(context.link) { return .link(link, title: nil) }
    if context.mediaType == "image" { return .image(source: webURL(context.source), title: nil) }
    if context.mediaType == "video" || context.mediaType == "audio" {
      if let source = webURL(context.source) { return .media(source, title: context.title.isEmpty ? nil : context.title) }
      return webURL(context.page).map { .link($0, title: context.title.isEmpty ? nil : context.title) }
    }
    if context.editable { return nil }
    if !context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(context.selection) }
    return webURL(context.page).map { .link($0, title: context.title.isEmpty ? nil : context.title) }
  }

  static func webURL(_ text: String) -> URL? {
    guard CleanURL.webHost(text) != nil else { return nil }
    return URL(string: CleanURL.clean(text))
  }
}
