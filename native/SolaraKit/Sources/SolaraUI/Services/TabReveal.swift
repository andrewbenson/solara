import SolaraModel
import SolaraStore

public enum TabReveal: Equatable, Sendable {
  case drop(String)
  case tab(String)
  case offered(String, over: String)

  public static func transition(
    windowId: String, before: BrowserState, after: BrowserState,
    sharing: Bool, runtime: (String) -> PageRuntimeState?, scrolledDown: (String) -> Bool
  ) -> Self? {
    guard let previous = before.windows[windowId], let window = after.windows[windowId],
      let source = before.activeTabId(windowId) else { return nil }
    let next = after.activeTabId(windowId)
    guard next != source else { return nil }
    let drop = Self.drop(source)
    guard let next, previous.profileId == window.profileId, !window.isSmall, !sharing,
      before.peeks[windowId] == nil, after.peeks[windowId] == nil,
      Splits.splitOf(before, source) == nil, Splits.splitOf(after, next) == nil,
      plain(runtime(source)), plain(runtime(next)),
      let tab = after.tabs[next], tab.windowId == windowId, webPage(tab) else { return drop }
    if let old = before.tabs[next] {
      return old.windowId == windowId && previous.tabIds.contains(next) && webPage(old) ? .tab(next) : drop
    }
    if let offer = tab.adoptId, offer.hasPrefix("tab:") || offer.hasPrefix("solaracore:"),
      let old = before.tabs[source], webPage(old), !scrolledDown(source) {
      return .offered(offer, over: source)
    }
    return drop
  }

  private static func plain(_ state: PageRuntimeState?) -> Bool {
    guard let state else { return true }
    return !state.newTabShown && !state.fullscreen && !state.crashed && !state.unresponsive
  }

  private static func webPage(_ tab: Tab) -> Bool {
    guard hasPage(tab), let scheme = tab.url.split(separator: ":", maxSplits: 1).first, tab.url.contains(":") else { return false }
    return ["http", "https", "file"].contains(scheme.lowercased())
  }
}
