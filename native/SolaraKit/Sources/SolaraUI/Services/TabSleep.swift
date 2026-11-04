import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

@MainActor
public final class TabSleep {
  private let store: Store
  private let pages: PageRegistry

  public init(store: Store, pages: PageRegistry = .shared) {
    self.store = store
    self.pages = pages
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

  @discardableResult
  public func sleepNow(_ tabId: String) -> Bool {
    store.sequence {
      guard solaraReasonNotToSleep(tabId) == nil, store.state.live[tabId]?.discarded != true,
        let page = pages.descriptors.first(where: { $0.tabID == tabId }), page.engine == .chromium else { return false }
      pages.call(page.registration, command: .discard(false)) { _ in }
      return true
    }
  }

  private static func isInternal(_ tab: Tab) -> Bool {
    let url = tab.navigation?.url ?? tab.url
    guard let colon = url.range(of: "://"), isAppScheme(String(url[..<colon.lowerBound])) else { return false }
    let host = url[colon.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
    return ["history", "bookmarks", "downloads"].contains(host)
  }
}
