import SolaraModel
import SolaraOmnibox

public struct ToolbarPageIdentity: Equatable, Sendable {
  public let host: String
  public let hasPage: Bool

  public static func resolve(windowId: String, tabId: String, state: BrowserState) -> Self? {
    guard let tab = state.tabs[tabId], tab.windowId == windowId else { return nil }
    return Self(host: tab.url.hasPrefix("file:") ? "File" : breadcrumb(tab.url).host, hasPage: !tab.url.isEmpty)
  }
}
