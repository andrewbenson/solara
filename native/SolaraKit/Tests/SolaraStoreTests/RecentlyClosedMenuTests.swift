import SolaraModel
import SolaraStore
import Testing

@Suite struct RecentlyClosedMenuTests {
  private func closedTab(_ id: String, at: Double, url: String = "", title: String = "",
                         customTitle: String? = nil, profile: String = "default") throws -> ClosedTab {
    let tab = try TabSnapshot(json: [
      "url": .string(url), "title": .string(title), "customTitle": customTitle.map(JSONValue.string) ?? .null,
      "profileId": .string(profile),
    ])
    return ClosedTab(id: id, tab: tab, tabId: nil, restoreFrom: nil, windowId: "w", index: 0,
                     group: nil, parents: nil, closedAt: at)
  }

  private func closedWindow(_ id: String, at: Double, count: Int) throws -> ClosedWindow {
    let tab = try TabSnapshot(json: [:])
    return ClosedWindow(id: id, profileId: "default", sidebarOpen: true, frame: nil,
                        tabs: Array(repeating: ClosedWindowTab(snapshot: tab, active: false, tabId: nil), count: count),
                        groups: [], closedAt: at)
  }

  @Test func emptyArchive() {
    let menu = RecentlyClosedMenu(state: BrowserState())
    #expect(menu.entries.isEmpty)
    #expect(menu.groups.isEmpty)
  }

  @Test func combinedEntriesExcludePrivateTabsAndPreserveTieOrderAndTitles() throws {
    var state = BrowserState()
    state.closedTabs = [
      try closedTab("page-title", at: 3, url: "https://www.example.com/", title: "Page title", customTitle: "Custom"),
      try closedTab("custom-title", at: 5, url: "https://www.example.com/", customTitle: "Custom"),
      try closedTab("private", at: 100, title: "Private", profile: "incognito:w@default"),
      try closedTab("site", at: 3, url: "https://www.example.com/path"),
      try closedTab("blank", at: 4),
    ]
    state.closedWindows = [try closedWindow("one", at: 3, count: 1), try closedWindow("two", at: 6, count: 2)]
    let menu = RecentlyClosedMenu(state: state)
    #expect(menu.entries.map(\.id) == ["two", "custom-title", "blank", "page-title", "site", "one"])
    #expect(menu.entries.map(\.title) == ["Window (2 Tabs)", "Custom", "New Tab", "Page title", "example.com", "Window (1 Tab)"])
  }

  @Test func tabsAndWindowsShareTheLimitWhileGroupsUseReverseArchiveOrder() throws {
    var state = BrowserState()
    state.closedTabs = try (0..<12).map { try closedTab("t\($0)", at: Double($0)) }
    state.closedWindows = [try closedWindow("new-window", at: 12, count: 1)]
    state.closedGroups = try (0..<12).map { index in
      let group = try ClosedGroupHead(json: ["name": .string("Group \(index)")])
      let tabs = try (0..<(index == 11 ? 1 : 2)).map { _ in try TabSnapshot(json: [:]) }
      return ClosedGroup(id: "g\(index)", group: group, tabs: tabs, tabIds: nil, nested: nil,
                         windowId: "w", index: 0, closedAt: Double(11 - index))
    }
    let menu = RecentlyClosedMenu(state: state)
    #expect(menu.entries.map(\.id) == ["new-window"] + (3...11).reversed().map { "t\($0)" })
    #expect(menu.groups.map(\.id) == (2...11).reversed().map { "g\($0)" })
    #expect(menu.groups.prefix(2).map(\.title) == ["Group 11 (1 Tab)", "Group 10 (2 Tabs)"])
  }
}
