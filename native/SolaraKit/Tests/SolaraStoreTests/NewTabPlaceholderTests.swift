import SolaraModel
import SolaraStore
import Testing

@Suite struct NewTabPlaceholderTests {
  func window(_ store: Store) throws -> String {
    try store.dispatch(Command("createWindow", [["url": "https://source.example/"]])).result!.string!
  }

  func open(_ store: Store, _ window: String) throws -> String {
    try store.dispatch(Command("newTab", [.string(window), ["newTabCommand": true]])).result!.string!
  }

  @Test func firstOpenIsARealSelectedTabWithoutAnOrdinaryRow() throws {
    for commandBar in [false, true] {
      let store = makeStore()
      try store.dispatch(settingsCommand(["newTabOpens": .string(commandBar ? "commandBar" : "page")]))
      let id = try window(store)
      let tab = try open(store, id)
      #expect(store.state.tabs[tab]?.newTabPlaceholder == true)
      #expect(store.state.tabs[tab]?.navigation?.url == "about:blank")
      #expect(store.state.windows[id]?.tabIds.contains(tab) == true)
      #expect(store.state.activeTabId(id) == tab)
      #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(tab)") == false)
      #expect(StripQuery(store.state).keys(windowId: id, profileId: store.state.windows[id]!.profileId).contains("tab:\(tab):") == false)
    }
  }

  @Test func aTabFromLittleSolaraWithNoMainWindowIsAPlaceholderOnlyForANewTabCommand() throws {
    for command in [false, true] {
      let store = makeStore()
      let small = try #require(try store.dispatch(Command("createWindow", [["small": true, "url": "https://small.example/"]])).result?.string)
      let options: JSONValue = command ? ["newTabCommand": true] : [:]
      let tab = try #require(try store.dispatch(Command("newTab", [.string(small), options])).result?.string)
      #expect(store.state.tabs[tab]?.windowId != small)
      #expect((store.state.tabs[tab]?.newTabPlaceholder == true) == command)
    }
  }

  @Test func repeatedOpenSettlesPreviousEmptyTabsAndKeepsTheirIdentity() throws {
    let store = makeStore()
    let id = try window(store)
    let first = try open(store, id)
    let second = try open(store, id)
    let third = try open(store, id)
    #expect(store.state.tabs[first]?.newTabPlaceholder != true)
    #expect(store.state.tabs[second]?.newTabPlaceholder != true)
    #expect(store.state.tabs[third]?.newTabPlaceholder == true)
    #expect(store.state.tabs[first]?.url == "")
    #expect(store.state.tabs[second]?.url == "")
    #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(first)"))
    #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(second)"))
    try store.dispatch(Command("activate", [.string(first)]))
    #expect(store.state.tabs[third] == nil)
    #expect(store.state.tabs[second] != nil)
  }

  @Test func settlementUsesTheConfiguredNewTabPosition() throws {
    for position in ["top", "bottom", "nextToCurrent"] {
      let store = makeStore()
      let id = try window(store)
      let source = store.state.activeTabId(id)!
      let last = try store.dispatch(Command("newTab", [.string(id), ["url": "https://last.example/", "index": 1]])).result!.string!
      try store.dispatch(Command("activate", [.string(source)]))
      try store.dispatch(settingsCommand(["newTabPosition": .string(position)]))
      let placeholder = try open(store, id)
      let expected = position == "top" ? [placeholder, source, last] : position == "bottom" ? [source, last, placeholder] : [source, placeholder, last]
      #expect(store.state.windows[id]?.tabIds == expected)
      try store.dispatch(Command("settleNewTab", [.string(placeholder)]))
      #expect(store.state.tabs[placeholder]?.newTabPlaceholder != true)
      #expect(store.state.windows[id]?.tabIds == expected)
      try store.dispatch(Command("activate", [.string(source)]))
      #expect(store.state.tabs[placeholder] != nil)
    }
  }

  @Test func navigationAndEngineReportedNavigationSettleThePlaceholder() throws {
    for reported in [false, true] {
      let store = makeStore()
      let id = try window(store)
      let tab = try open(store, id)
      let command = reported ? Command("updateTab", [.string(tab), ["url": "https://target.example/"]]) : Command("navigate", [.string(tab), "https://target.example/"])
      try store.dispatch(command)
      #expect(store.state.tabs[tab]?.newTabPlaceholder != true)
      #expect(store.state.tabs[tab]?.url == "https://target.example/")
      #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(tab)"))
    }
  }

  @Test func switchingAwayDiscardsUntouchedPlaceholderWithoutReopenEntry() throws {
    let store = makeStore()
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let tab = try open(store, id)
    try store.dispatch(Command("activate", [.string(source)]))
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.closedTabs.isEmpty)
    #expect(store.state.windows[id]?.tabIds == [source])
  }

  @Test func profileSwitchDiscardsOnlyTheUntouchedPlaceholder() throws {
    let store = makeStore()
    let id = try window(store)
    let other = try store.dispatch(Command("createProfile", [["name": "Other"]])).result!.string!
    let tab = try open(store, id)
    try store.dispatch(Command("switchProfile", [.string(id), .string(other)]))
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func sessionExportOmitsThePlaceholderAndRepairsWindowReferences() throws {
    let store = makeStore()
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let tab = try open(store, id)
    let document = store.sessionDocument()
    #expect(document.tabs[tab] == nil)
    #expect(document.windows[id]?["tabIds"]?.array?.compactMap(\.string) == [source])
    #expect(document.windows[id]?["activeTabIds"]?[store.state.windows[id]!.profileId]?.string == source)
    try store.dispatch(Command("settleNewTab", [.string(tab)]))
    #expect(store.sessionDocument().tabs[tab] != nil)
  }

  @Test func closingAnUntouchedPlaceholderNeverCreatesAClosedTab() throws {
    let store = makeStore()
    let id = try window(store)
    let tab = try open(store, id)
    try store.dispatch(Command("closeTab", [.string(tab)]))
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func settledEmptyTabStaysOutOfReopenClosedTabAsOnMain() throws {
    for engine in ["chromium", "webkit"] {
      let store = makeStore()
      try store.dispatch(settingsCommand(["pageEngine": .string(engine)]))
      let id = try window(store)
      let tab = try open(store, id)
      try store.dispatch(Command("settleNewTab", [.string(tab)]))
      try store.dispatch(Command("closeTab", [.string(tab)]))
      #expect(store.state.tabs[tab] == nil)
      #expect(store.state.closedTabs.isEmpty)
    }
  }

  @Test func legacyBlankWithoutAPageDoesNotCreateAReopenEntry() throws {
    let store = makeStore()
    let id = try window(store)
    let tab = try store.dispatch(Command("newTab", [.string(id), ["background": true]])).result!.string!
    #expect(store.state.tabs[tab]?.navigation == nil)
    try store.dispatch(Command("closeTab", [.string(tab)]))
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func closedWindowSnapshotOmitsItsUntouchedPlaceholder() throws {
    let store = makeStore()
    let id = try window(store)
    let tab = try open(store, id)
    try store.dispatch(Command("closeWindow", [.string(id)]))
    #expect(store.state.closedWindows.last?.tabs.count == 1)
    #expect(store.state.closedWindows.last?.tabs.contains { $0.tabId == tab } == false)
  }

  @Test func initialBlankReportsDoNotSettleOrReplaceNewTabPages() throws {
    for settled in [false, true] {
      let store = makeStore()
      let id = try window(store)
      let tab = try open(store, id)
      if settled { try store.dispatch(Command("settleNewTab", [.string(tab)])) }
      try store.dispatch(Command("updateTab", [.string(tab), ["url": "about:blank", "title": "about:blank"]]))
      #expect(store.state.tabs[tab]?.url == "")
      #expect(store.state.tabs[tab]?.title == "")
      #expect((store.state.tabs[tab]?.newTabPlaceholder == true) == !settled)
    }
    let store = makeStore()
    let id = try window(store)
    let first = try open(store, id)
    _ = try open(store, id)
    try store.dispatch(Command("updateTab", [.string(first), ["url": "about:blank", "title": "about:blank"]]))
    #expect(store.state.tabs[first]?.url == "")
    #expect(store.state.tabs[first]?.newTabPlaceholder != true)
  }

  @Test func hydrateRefusesLeakedUntouchedPlaceholder() throws {
    let store = makeStore()
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let tab = try open(store, id)
    var document = store.sessionDocument().json().object!
    document["tabs"] = .array(store.state.tabs.values.map(\.jsonValue))
    document["windows"] = .array(store.state.windows.values.map(\.jsonValue))
    let restored = makeStore()
    try restored.transact { _ = $0.loadSession(.object(document), downloads: nil) }
    #expect(restored.state.tabs[tab] == nil)
    #expect(restored.state.activeTabId(id) == source)
  }

  @Test func restoringAClosingWindowDoesNotReviveItsUntouchedPlaceholder() throws {
    let store = makeStore()
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let placeholder = try open(store, id)
    let before = store.state
    let snapshot: JSONValue = [
      "window": .object(before.windows[id]!.json),
      "tabs": .array(before.windows[id]!.tabIds.map { before.tabs[$0]!.jsonValue }),
      "groups": [], "splits": [],
    ]
    try store.dispatch(Command("closeWindow", [.string(id)]))
    let restored = try #require(store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(source), .string(placeholder)]])).result?.string)
    #expect(store.state.windows[restored]?.tabIds == [source])
    #expect(store.state.tabs[placeholder] == nil)
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func belowCurrentJoinsTheCurrentGroupOnlyWhenSettled() throws {
    for typing in [false, true] {
      let store = makeStore()
      let id = try window(store)
      let source = store.state.activeTabId(id)!
      let group = try store.dispatch(Command("groupTabs", [[.string(source)], ["name": "Reading", "pinned": false]])).result!.string!
      try store.dispatch(settingsCommand(["newTabPosition": "nextToCurrent"]))
      let placeholder = try open(store, id)
      #expect(store.state.groups[group]?.tabIds == [source])
      if typing {
        try store.dispatch(Command("settleNewTab", [.string(placeholder)]))
      } else {
        try store.dispatch(Command("navigate", [.string(placeholder), "https://target.example/"]))
      }
      #expect(store.state.groups[group]?.tabIds == [source, placeholder])
    }
  }

  @Test func explicitAboutBlankNavigationSettlesAndKeepsTheRequestedUrl() throws {
    let store = makeStore()
    let id = try window(store)
    let tab = try open(store, id)
    try store.dispatch(Command("navigate", [.string(tab), "about:blank"]))
    #expect(store.state.tabs[tab]?.newTabPlaceholder != true)
    #expect(store.state.tabs[tab]?.url == "about:blank")
    try store.dispatch(Command("updateTab", [.string(tab), ["url": "about:blank"]]))
    #expect(store.state.tabs[tab]?.url == "about:blank")
  }

  @Test func firstOpenUsesChromeEvenWhenPagesDefaultToWebKit() throws {
    for typing in [false, true] {
      let store = makeStore()
      let id = try window(store)
      try store.dispatch(settingsCommand(["pageEngine": "webkit"]))
      let tab = try open(store, id)
      #expect(store.pageEngine(tab, in: store.state) == "chromium")
      if typing { try store.dispatch(Command("settleNewTab", [.string(tab)])) }
      try store.dispatch(Command("navigate", [.string(tab), "https://target.example/"]))
      #expect(store.pageEngine(tab, in: store.state) == "webkit")
    }
  }

  @Test func firstOpenWithoutAMainWindowIsTheNewWindowsPlaceholder() throws {
    let store = makeStore()
    let id = try store.dispatch(Command("createWindow", [["newTabCommand": true]])).result!.string!
    let tab = try #require(store.state.activeTabId(id))
    #expect(store.state.tabs[tab]?.newTabPlaceholder == true)
    #expect(store.state.tabs[tab]?.navigation?.url == "about:blank")
    #expect(store.state.windows[id]?.tabIds == [tab])
    #expect(store.sessionDocument().tabs.isEmpty)
  }

  @Test func littleSolaraWithoutAMainWindowOpensARealPlaceholderInANewMainWindow() throws {
    let store = makeStore()
    let small = try store.dispatch(Command("createWindow", [["small": true, "url": "https://source.example/"]])).result!.string!
    let tab = try open(store, small)
    let owner = try #require(store.state.tabs[tab]?.windowId)
    #expect(owner != small)
    #expect(store.state.windows[owner]?.isSmall == false)
    #expect(store.state.tabs[tab]?.newTabPlaceholder == true)
    #expect(store.state.tabs[tab]?.navigation?.url == "about:blank")
    #expect(store.pageEngine(tab, in: store.state) == "chromium")
  }

  @Test func closingTheOnlyPlaceholderOrSettledEmptyPageClosesItsWindow() throws {
    for settled in [false, true] {
      let store = makeStore()
      let id = try store.dispatch(Command("createWindow", [["newTabCommand": true]])).result!.string!
      let tab = try #require(store.state.activeTabId(id))
      if settled { try store.dispatch(Command("settleNewTab", [.string(tab)])) }
      try store.dispatch(Command("closeTab", [.string(tab)]))
      #expect(store.state.windows[id] == nil)
      #expect(store.state.tabs[tab] == nil)
      #expect(store.state.closedTabs.isEmpty)
      #expect(store.state.closedWindows.isEmpty)
    }
  }

  @Test func closingLegacyBlankWindowsDoesNotCreateWindowHistory() throws {
    for closeTab in [false, true] {
      let store = makeStore()
      let id = try store.dispatch(Command("createWindow")).result!.string!
      let tab = try #require(store.state.activeTabId(id))
      #expect(store.state.tabs[tab]?.navigation == nil)
      #expect(store.state.tabs[tab]?.engine == nil)
      try store.dispatch(Command(closeTab ? "closeTab" : "closeWindow", [.string(closeTab ? tab : id)]))
      #expect(store.state.windows[id] == nil)
      #expect(store.state.closedWindows.isEmpty)
      #expect(store.state.closedTabs.isEmpty)
    }
  }

  @Test func closingABlankChromiumWindowLeavesNoHistoryAsOnMain() throws {
    for loaded in [false, true] {
      let store = makeStore()
      let id = try store.dispatch(Command("createWindow")).result!.string!
      let tab = try #require(store.state.activeTabId(id))
      let patch: JSONObject = loaded ? ["navigation": ["url": "about:blank", "seq": 1]] : ["engine": "chromium"]
      try store.dispatch(Command("updateTab", [.string(tab), .object(patch)]))
      try store.dispatch(Command("closeWindow", [.string(id)]))
      #expect(store.state.closedWindows.isEmpty)
      #expect(store.state.closedTabs.isEmpty)
    }
  }

  @Test func settledEmptyRowsSurviveAbandonedTabCleanupAndRelaunch() throws {
    let store = makeStore()
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let tab = try open(store, id)
    try store.dispatch(Command("settleNewTab", [.string(tab)]))
    try store.dispatch(Command("activate", [.string(source)]))
    try store.dispatch(Command("closeAbandonedNewTabs"))
    #expect(store.state.tabs[tab] != nil)
    #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(tab)"))
    let restored = makeStore()
    try restored.transact { _ = $0.loadSession(store.sessionDocument().json(), downloads: nil) }
    #expect(restored.state.tabs[tab] != nil)
    #expect(restored.state.tabs[tab]?.newTabPlaceholder != true)
  }

  @Test func explicitBackgroundAndAdoptedTabsStayOrdinary() throws {
    let store = makeStore()
    let id = try window(store)
    let variants: [JSONObject] = [["background": true], ["adoptId": "tab:123"], ["url": "https://target.example/"]]
    for options in variants {
      let tab = try store.dispatch(Command("newTab", [.string(id), .object(options)])).result!.string!
      #expect(store.state.tabs[tab]?.newTabPlaceholder != true)
    }
  }

  @Test func onlyTheNewTabCommandsMakeAPlaceholder() throws {
    for position in ["top", "nextToCurrent"] {
      let store = makeStore()
      try store.dispatch(settingsCommand(["newTabPosition": .string(position)]))
      let id = try window(store)
      let source = store.state.activeTabId(id)!
      let other = try store.dispatch(Command("newTab", [.string(id), ["url": "https://other.example/", "background": true]])).result!.string!
      let plain = try store.dispatch(Command("newTab", [.string(id)])).result!.string!
      #expect(store.state.tabs[plain]?.newTabPlaceholder != true)
      #expect(store.state.tabs[plain]?.openerId == nil)
      #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(plain)"))
      let expected = position == "top" ? [plain, other, source] : [source, other, plain]
      #expect(store.state.windows[id]?.tabIds == expected)
    }
  }

  @Test func oldStyleEmptyTabsKeepMainsHidingAndCleanup() throws {
    let store = makeStore()
    try store.dispatch(settingsCommand(["newTabOpens": "commandBar"]))
    let id = try window(store)
    let profile = store.state.windows[id]!.profileId
    let legacy = try store.dispatch(Command("newTab", [.string(id), ["background": true]])).result!.string!
    #expect(store.state.tabs[legacy]?.navigation == nil)
    #expect(SidebarQuery(store.state).entries(windowId: id).list.contains("t:\(legacy)") == false)
    #expect(StripQuery(store.state).keys(windowId: id, profileId: profile).contains("tab:\(legacy):") == false)
    try store.dispatch(Command("closeAbandonedNewTabs"))
    #expect(store.state.tabs[legacy] == nil)
    let page = makeStore()
    let shownId = try window(page)
    let shown = try page.dispatch(Command("newTab", [.string(shownId), ["background": true]])).result!.string!
    #expect(SidebarQuery(page.state).entries(windowId: shownId).list.contains("t:\(shown)"))
    try page.dispatch(Command("closeAbandonedNewTabs"))
    #expect(page.state.tabs[shown] == nil)
  }

  @Test func relaunchShowsTheTabThatWasActiveBeforeThePlaceholder() throws {
    let store = makeStore()
    let id = try window(store)
    let profile = store.state.windows[id]!.profileId
    let second = try store.dispatch(Command("newTab", [.string(id), ["url": "https://second.example/"]])).result!.string!
    let placeholder = try open(store, id)
    #expect(store.state.windows[id]?.tabIds.first == placeholder)
    #expect(store.sessionDocument().windows[id]?["activeTabIds"]?[profile]?.string == second)
    let restored = makeStore()
    try restored.transact { _ = $0.loadSession(store.sessionDocument().json(), downloads: nil) }
    #expect(restored.state.activeTabId(id) == second)
    try store.dispatch(Command("closeWindow", [.string(id)]))
    let entry = try #require(store.state.closedWindows.last)
    #expect(entry.tabs.filter(\.active).map(\.snapshot.url) == ["https://second.example/"])
  }

  @Test func aDiscardedPlaceholderKeepsOtherTabsOpeners() throws {
    let store = makeStore()
    try store.dispatch(settingsCommand(["newTabPosition": "nextToCurrent"]))
    let id = try window(store)
    let source = store.state.activeTabId(id)!
    let child = try store.dispatch(Command("newTab", [.string(id), ["url": "https://child.example/", "openerId": .string(source), "background": true]])).result!.string!
    #expect(store.state.tabs[child]?.openerId == source)
    let placeholder = try open(store, id)
    #expect(store.state.tabs[child]?.openerId == source)
    try store.dispatch(Command("activate", [.string(source)]))
    #expect(store.state.tabs[placeholder] == nil)
    #expect(store.state.tabs[child]?.openerId == source)
  }
}
