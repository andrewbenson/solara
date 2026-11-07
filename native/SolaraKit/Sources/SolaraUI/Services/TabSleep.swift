import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

@MainActor
public final class TabSleep {
  private let store: Store

  public init(store: Store) {
    self.store = store
  }

  public func solaraReasonNotToSleep(_ tabId: String) -> String? {
    let state = store.state
    for window in state.windows.values {
      guard let active = state.activeTabId(window.id) else { continue }
      if active == tabId { return "shown" }
      if state.peeks[window.id]?.tabId == tabId { return "peek" }
      if state.tabs[active]?.pageIn == tabId { return "held" }
      if Splits.splitOf(state, active)?.tabIds.contains(tabId) == true { return "split" }
    }
    guard let tab = state.tabs[tabId] else { return "no page" }
    if let holder = tab.pageIn, !holder.isEmpty { return "shared" }
    if tab.url.isEmpty || tab.unloaded == true || !hasPage(tab) || Self.isInternal(tab) { return "no page" }
    return nil
  }

  private static func isInternal(_ tab: Tab) -> Bool {
    let url = tab.navigation?.url ?? tab.url
    guard let colon = url.range(of: "://"), isAppScheme(String(url[..<colon.lowerBound])) else { return false }
    let host = url[colon.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
    return ["history", "bookmarks", "downloads"].contains(host)
  }
}
