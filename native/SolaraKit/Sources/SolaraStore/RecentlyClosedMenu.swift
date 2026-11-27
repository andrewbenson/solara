import SolaraModel

public struct RecentlyClosedMenu: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let id: String
    public let title: String
  }

  public let entries: [Entry]
  public let groups: [Entry]

  public init(state: BrowserState) {
    let tabs = state.closedTabs.filter { !Ids.isIncognitoProfile($0.tab.profileId) }.map { closed in
      let tab = closed.tab
      let title = tab.title.isEmpty ? TabMenuPlan.tabLabel(url: tab.url, title: tab.title, customTitle: tab.customTitle) : tab.title
      return (at: closed.closedAt, entry: Entry(id: closed.id, title: title))
    }
    let windows = state.closedWindows.map { closed in
      (at: closed.closedAt, entry: Entry(id: closed.id, title: "Window (\(Self.tabCount(closed.tabs.count)))"))
    }
    entries = (tabs + windows).sorted { $0.at > $1.at }.prefix(10).map(\.entry)
    groups = state.closedGroups.reversed().prefix(10).map {
      Entry(id: $0.id, title: "\($0.group.name) (\(Self.tabCount($0.tabs.count)))")
    }
  }

  private static func tabCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "Tab" : "Tabs")"
  }
}
