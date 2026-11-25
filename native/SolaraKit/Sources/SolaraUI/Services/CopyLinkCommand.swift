import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
public struct CopyLinkPlan: Equatable, Sendable {
  public let windowId: String
  public let tabId: String
  public let url: String
  public let text: String
  public let count: Int
  public let title: String?
  public let offerQuote: Bool
}
public enum CopyLinkCommand {
  public static let commands: Set<String> = ["copyUrl", "copyUrlAsMarkdown", "copyQuoteLink", "share"]
  public static func plan(_ command: String, windowId: String?, state: BrowserState, closing: Set<String>, tabId explicit: String? = nil, ids: [String]? = nil, groupId: String? = nil) -> CopyLinkPlan? {
    let route = CommandRoute.resolve(command == "copyQuoteLink" ? "copyUrl" : command, windowId: windowId, state: state, closing: closing)
    guard commands.contains(command), let windowId = route.windowId, !closing.contains(windowId),
      let window = state.windows[windowId], let tabId = explicit ?? route.tabId,
      let tab = state.tabs[tabId], tab.windowId == windowId, tab.profileId == window.profileId else { return nil }
    let markdown = command == "copyUrlAsMarkdown"
    if command == "share" || command == "copyQuoteLink" {
      guard tab.url.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    }
    let selected = state.viewTabIds(windowId).filter { state.selection[windowId]?.ids.contains($0) == true }
    let multi = explicit == nil && state.peeks[windowId] == nil && selected.count > 1 && selected.contains(tabId)
    let group = groupId.flatMap { state.groups[$0] }
    if groupId != nil && (group?.windowId != windowId || group?.profileId != window.profileId) { return nil }
    let requested = group?.tabIds ?? ids ?? (multi ? selected : [tabId])
    let tabs = requested.compactMap { state.tabs[$0] }.filter { $0.windowId == windowId && $0.profileId == window.profileId && !$0.url.isEmpty }
    let lines = tabs.map { markdown ? self.markdown(title: label($0, fallback: requested.count > 1 || ids != nil || groupId != nil), url: $0.url) : cleanUrl($0.url) }
    let text = markdown && lines.count > 1 ? lines.map { "- \($0)" }.joined(separator: "\n") : lines.joined(separator: "\n")
    let batch = multi || ids != nil || groupId != nil
    if tabs.isEmpty && !batch { return nil }
    let title = batch ? (tabs.isEmpty ? "No Links to Copy" : "Copied \(tabs.count) \(tabs.count == 1 ? "Link" : "Links")\(markdown ? " as Markdown" : "")") : markdown || command == "share" ? nil : cleanUrl(tab.url) != tab.url ? "Copied a clean link without trackers" : "Copied Current URL"
    return CopyLinkPlan(windowId: windowId, tabId: tabId, url: tab.url, text: text, count: tabs.count, title: title, offerQuote: !batch && !markdown && command == "copyUrl" && !tab.url.isEmpty)
  }
  public static func label(_ tab: Tab, fallback: Bool) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if !tab.title.isEmpty { return tab.title }
    return fallback ? tab.url.replacingOccurrences(of: "^[a-z][\\w+.-]*://(www\\.)?", with: "", options: [.regularExpression, .caseInsensitive]).replacingOccurrences(of: "/$", with: "", options: .regularExpression) : ""
  }
  public static func markdown(title: String, url: String) -> String {
    let title = (title.isEmpty ? url : title).replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
    func escaped(_ text: String, _ chars: String) -> String { text.reduce("") { $0 + (chars.contains($1) ? "\\" : "") + String($1) } }
    let href = WhatwgURL(cleanUrl(url))?.href ?? cleanUrl(url)
    let destination = escaped(href, "\\()<>&").unicodeScalars.map { scalar -> String in
      if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value < 32 || (127...159).contains(scalar.value) {
        return String(scalar).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
      }
      return String(scalar)
    }.joined()
    return "[\(escaped(title, "\\[]<>`&"))](\(destination))"
  }
  public static func posted(_ value: PageValue) -> PageValue? {
    guard case .string(let text) = value, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
    return try? PageValue(any: object)
  }
  public static func hasSelection(_ value: PageValue) -> Bool { posted(value) == .bool(true) }
  public static func quote(_ value: PageValue, url: String) -> String? {
    guard case .object(let fields)? = posted(value),
      case .string(let selected) = fields["selected"], case .string(let before) = fields["before"],
      case .string(let after) = fields["after"], case .string(let page) = fields["pageText"],
      let fragment = chooseTextFragment(SelectionContext(selected: selected, before: before, after: after, pageText: page)) else { return nil }
    return withTextFragment(cleanUrl(url), fragment)
  }
}
