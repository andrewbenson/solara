import SolaraModel
import SolaraStore
import Testing

@Suite struct NumberedTabRowsTests {
  private func fixture(_ ids: [String]) -> BrowserState {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ids
    window.activeTabIds[profile] = ids.last
    state.windows["w"] = window
    state.windowOrder = ["w"]
    for (index, id) in ids.enumerated() {
      state.tabs[id] = Tab(id: id, windowId: "w", profileId: profile, url: "https://\(id).example/", now: Double(index))
    }
    return state
  }

  private func group(_ id: String, _ tabs: [String], pinned: Bool = false) -> TabGroup {
    TabGroup(id: id, windowId: "w", profileId: BrowserState.defaultProfile.id, name: id, icon: nil, color: nil,
      collapsed: true, pinned: pinned, tabIds: tabs, createdAt: 0)
  }

  @Test func tilesRowsPinnedGroupsThenListIgnoreCollapsedState() {
    var state = fixture(["list", "grouped", "row", "tile"])
    state.tabs["tile"]?.pinned = true
    state.tabs["row"]?.pinned = true
    state.tabs["row"]?.pinnedAsRow = true
    state.groups["pinned"] = group("pinned", ["grouped"], pinned: true)
    let rows = SidebarQuery(state).numberedRows(windowId: "w")
    #expect(rows.map(\.key) == ["t:tile", "t:grouped", "t:row", "t:list"])
    #expect(rows.map(\.tabId) == ["tile", "grouped", "row", "list"])
  }

  @Test func nestedGroupsFlattenTheirRowsAndSplitUsesActivePane() {
    var state = fixture(["first", "a", "b", "last"])
    state.groups["root"] = group("root", ["first", "a", "b"])
    var child = group("child", ["a", "b"])
    child.parentId = "root"
    state.groups["child"] = child
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    state.windows["w"]?.activeTabIds[BrowserState.defaultProfile.id] = "a"
    let rows = SidebarQuery(state).numberedRows(windowId: "w")
    #expect(rows.map(\.key) == ["t:first", "s:split", "t:last"])
    #expect(rows.map(\.tabId) == ["first", "a", "last"])
  }

  @Test func splitUsesMostRecentPaneWhenItIsNotActive() {
    var state = fixture(["a", "b", "last"])
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    #expect(SidebarQuery(state).numberedRows(windowId: "w").first?.tabId == "b")
    state.tabs["a"]?.lastActiveAt = 100
    #expect(SidebarQuery(state).numberedRows(windowId: "w").first?.tabId == "a")
  }

  @Test func pinnedSplitIsOneRow() {
    var state = fixture(["a", "b", "last"])
    for id in ["a", "b"] {
      state.tabs[id]?.pinned = true
      state.tabs[id]?.pinnedAsRow = true
    }
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    #expect(SidebarQuery(state).numberedRows(windowId: "w").map(\.key) == ["s:split", "t:last"])
  }

  @Test func nineIsLastRatherThanTheNinthRowAndInvalidNumbersDoNothing() {
    let state = fixture((1...12).map { "tab\($0)" })
    let query = SidebarQuery(state)
    #expect(query.numberedTab(windowId: "w", number: 8) == "tab8")
    #expect(query.numberedTab(windowId: "w", number: 9) == "tab12")
    #expect(query.numberedTab(windowId: "w", number: 0) == nil)
    #expect(query.numberedTab(windowId: "w", number: 10) == nil)
    #expect(SidebarQuery(fixture(["only"])).numberedTab(windowId: "w", number: 9) == "only")
  }

  @Test func privateWindowsKeepNumberedTabsAndLittleSolaraDoesNot() {
    var state = fixture(["a", "b"])
    state.windows["w"]?.incognito = true
    #expect(SidebarQuery(state).numberedTab(windowId: "w", number: 1) == "a")
    state.windows["w"]?.kind = "small"
    #expect(SidebarQuery(state).numberedRows(windowId: "w").isEmpty)
  }

  @Test func tileFoldersKeepEachMemberReachable() {
    var state = fixture(["a", "b", "last"])
    for id in ["a", "b"] {
      state.tabs[id]?.pinned = true
      state.tabs[id]?.tileFolder = TileFolder(id: "folder", name: "Folder")
    }
    let query = SidebarQuery(state)
    #expect(query.entries(windowId: "w").cells == ["folder:folder"])
    #expect(query.numberedRows(windowId: "w").map(\.key) == ["t:a", "t:b", "t:last"])
    #expect(query.numberedTab(windowId: "w", number: 2) == "b")
  }

  @Test func nestedPinnedFoldedGroupsKeepEveryRowNumbered() {
    var state = fixture(["first", "a", "b", "last"])
    state.groups["root"] = group("root", ["first", "a", "b"], pinned: true)
    var child = group("child", ["a", "b"])
    child.parentId = "root"
    state.groups["child"] = child
    #expect(SidebarQuery(state).numberedRows(windowId: "w").map(\.tabId) == ["first", "a", "b", "last"])
  }

  @Test func splitPaneTimestampTieKeepsPaneOrder() {
    var state = fixture(["a", "b", "last"])
    state.tabs["a"]?.lastActiveAt = 100
    state.tabs["b"]?.lastActiveAt = 100
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["b", "a"], orientation: "horizontal", sizes: [0.5, 0.5])
    #expect(SidebarQuery(state).numberedRows(windowId: "w").first?.tabId == "b")
  }

  @Test func numberedCommandUsesSameMappingAndNineSelectsLast() throws {
    let state = fixture((1...12).map { "tab\($0)" })
    let store = Store(state: state, checksInvariants: false, clock: { 1_000 })
    try store.dispatch(Command("activateNumberedTab", ["w", 1]))
    #expect(store.state.activeTabId("w") == "tab1")
    try store.dispatch(Command("activateNumberedTab", ["w", 9]))
    #expect(store.state.activeTabId("w") == "tab12")
    let previous = store.state.activeTabId("w")
    try store.dispatch(Command("activateNumberedTab", ["w", 0]))
    try store.dispatch(Command("activateNumberedTab", ["w", 10]))
    #expect(store.state.activeTabId("w") == previous)
  }

  @Test func numberedCommandWorksWithinHeldTransaction() throws {
    let store = Store(state: fixture(["a", "b", "last"]), checksInvariants: false, clock: { 1_000 })
    try store.dispatch(Command("beginTransaction"))
    try store.dispatch(Command("activateNumberedTab", ["w", 1]))
    try store.dispatch(Command("endTransaction"))
    #expect(store.state.activeTabId("w") == "a")
  }

}
