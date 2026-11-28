import SolaraModel
import SolaraStore
import Testing

@Suite struct ViewMenuCommandTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusedWindowId = "w"
    state.ui.focusOrder = ["w"]
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.example/", now: 0)
    state.tabs["b"] = Tab(id: "b", windowId: "w", profileId: "default", url: "https://b.example/", now: 1)
    return state
  }

  private func withSmall(_ state: BrowserState) -> BrowserState {
    var state = state
    var small = BrowserWindow(id: "s", profileId: "default", incognito: false, frame: nil, createdAt: 2)
    small.kind = "small"
    small.tabIds = ["c"]
    small.activeTabIds["default"] = "c"
    state.windows["s"] = small
    state.windowOrder.append("s")
    state.ui.focusOrder = ["s", "w"]
    state.tabs["c"] = Tab(id: "c", windowId: "s", profileId: "default", url: "https://c.example/", now: 2)
    return state
  }

  @Test func validationUsesTheWindowLayoutAndSplit() {
    var state = fixture()
    state.windows["w"]?.tabLayout = "top"
    #expect(ViewMenuCommand.row("toggleAddressBar", arg: nil, windowId: "w", state: state)?.enabled == false)
    #expect(ViewMenuCommand.row("toggleTabLayout", arg: nil, windowId: "w", state: state)?.checked == false)
    #expect(ViewMenuCommand.row("focusNextPane", arg: nil, windowId: "w", state: state)?.enabled == false)
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    #expect(ViewMenuCommand.row("focusNextPane", arg: nil, windowId: "w", state: state)?.enabled == true)
  }

  @Test func windowlessSettingsAndLittleSolaraHaveSeparateValidation() {
    let state = withSmall(fixture())
    #expect(ViewMenuCommand.row("setAppearance", arg: "auto", windowId: nil, state: state)?.checked == true)
    #expect(ViewMenuCommand.row("toggleTabLayout", arg: nil, windowId: nil, state: state)?.enabled == false)
    #expect(ViewMenuCommand.row("toggleAddressBar", arg: nil, windowId: "s", state: state)?.enabled == false)
  }

  @Test func anEmptySenderIDStillAllowsWindowlessViewSettings() throws {
    let store = makeStore(BrowserState(settings: Settings.hydrated(from: nil)))
    let before = store.state.settings.bool("showFullUrl")
    try run("toggleFullUrl", windowId: "", store: store)
    #expect(store.state.settings.bool("showFullUrl") == !before)
  }

  @Test func sidebarRailCommandsTargetOnlyEligibleWindows() throws {
    let store = makeStore(withSmall(fixture()))
    try run("setSidebarPosition", arg: "right", store: store)
    #expect(store.state.windows["w"]?.effectiveSidebarPosition(store.state.settings) == "right")
    try run("toggleSidebarIconsOnly", store: store)
    #expect(store.state.windows["w"]?.effectiveSidebarIconsOnly(store.state.settings) == true)
    #expect(try run("setSidebarPosition", arg: "left", windowId: "s", store: store).commands.isEmpty)
    #expect(try run("toggleSidebarIconsOnly", windowId: "stale", store: store).commands.isEmpty)
    #expect(store.state.windows["w"]?.effectiveSidebarIconsOnly(store.state.settings) == true)
  }

  @Test func closingInvokerCannotRedirectAViewAction() throws {
    let store = makeStore(withSmall(fixture()))
    try store.dispatch(Command("setWindowClosing", ["s", true]))
    let plan = try run("toggleSidebar", windowId: "s", store: store)
    #expect(plan.commands.isEmpty && plan.focusWindow == nil)
    #expect(store.state.windows["w"]?.sidebarOpen == true)
  }

  @Test func onlyAnInternalPageReachedFromNewTabOffersBackToNewTab() throws {
    var state = fixture()
    state.tabs["a"]?.url = ""
    state.tabs["b"]?.url = "solara://bookmarks"
    let store = makeStore(state)
    #expect(!store.menuHistoryFacts("a").backToNewTab)
    #expect(!store.menuHistoryFacts("b").backToNewTab)
    try store.dispatch(Command("navigate", ["a", "solara://history"]))
    #expect(store.menuHistoryFacts("a").backToNewTab)
    #expect(!store.menuHistoryFacts("a").newTabShown)
    try store.dispatch(Command("updateTab", ["a", ["url": "", "navigation": .null]]))
    #expect(store.menuHistoryFacts("a").newTabShown)
  }

  @discardableResult private func run(_ command: String, arg: String? = nil, windowId: String? = "w", store: Store) throws -> ViewMenuPlan {
    let plan = try #require(ViewMenuCommand.plan(command, arg: arg, windowId: windowId, state: store.state, closing: store.memory.closingWindows))
    let outcome = try #require(ViewMenuCommand.perform(command, arg: arg, windowId: windowId, store: store))
    #expect(outcome.focusWindow == plan.focusWindow)
    #expect((outcome.appearance != nil) == plan.appliesAppearance)
    return plan
  }

  @Test(arguments: [
    ("toggleOpenLinksInLittleSolara", "openLinksInLittleSolara"),
    ("toggleFullUrl", "showFullUrl"),
    ("toggleJavaScriptFromAppleEvents", "allowJavaScriptFromAppleEvents"),
  ])
  func togglesFlipTheirSettingBothWays(command: String, key: String) throws {
    let store = makeStore(fixture())
    let before = store.state.settings.bool(key)
    try run(command, store: store)
    #expect(store.state.settings.bool(key) == !before)
    try run(command, store: store)
    #expect(store.state.settings.bool(key) == before)
  }

  @Test func appearanceTakesOnlyTheThreeModesAndAppliesThem() throws {
    let store = makeStore(fixture())
    for mode in ["dark", "light", "auto"] {
      let outcome = try #require(ViewMenuCommand.perform("setAppearance", arg: mode, windowId: "w", store: store))
      #expect(outcome.appearance == mode, "the appearance to apply is read after the update")
      #expect(store.state.settings.string("appearance") == mode)
    }
    let refused = try run("setAppearance", arg: "sepia", store: store)
    #expect(refused.commands.isEmpty && !refused.appliesAppearance)
    #expect(store.state.settings.string("appearance") == "auto")
    #expect(try run("setAppearance", store: store).commands.isEmpty)
  }

  @Test func addressBarAlternatesBetweenSidebarAndToolbar() throws {
    let store = makeStore(fixture())
    let first = store.state.settings.string("addressBar")
    try run("toggleAddressBar", store: store)
    #expect(store.state.settings.string("addressBar") == (first == "sidebar" ? "toolbar" : "sidebar"))
    try run("toggleAddressBar", store: store)
    #expect(store.state.settings.string("addressBar") == (first == "sidebar" ? "sidebar" : "toolbar"))
  }

  @Test func bookmarksBarModesAndTheShownOnThisPageRule() throws {
    var state = fixture()
    state.settings["bookmarksBar"] = "newTab"
    let onPage = makeStore(state)
    try run("toggleBookmarksBar", store: onPage)
    #expect(onPage.state.settings.string("bookmarksBar") == "always", "hidden on a page, so it turns on")
    state.tabs["a"]?.url = ""
    let store = makeStore(state)
    try run("toggleBookmarksBar", store: store)
    #expect(store.state.settings.string("bookmarksBar") == "never", "shown on a new tab, so it turns off")
    try run("toggleBookmarksBar", store: store)
    #expect(store.state.settings.string("bookmarksBar") == "always")
    #expect(try run("setBookmarksBar", arg: "sometimes", store: store).commands.isEmpty)
    #expect(store.state.settings.string("bookmarksBar") == "always")
  }

  @Test func windowCommandsActOnTheRequestedWindow() throws {
    let store = makeStore(fixture())
    let layout = store.state.windows["w"]?.tabLayout
    try run("toggleTabLayout", store: store)
    #expect(store.state.windows["w"]?.tabLayout != layout)
    try run("downloads", store: store)
    #expect(store.state.windowUi["w"]?.downloadsOpen == true)
    try run("downloads", store: store)
    #expect(store.state.windowUi["w"]?.downloadsOpen == false)
    let plan = try run("focusNextPane", store: store)
    #expect(plan.commands == [Command("focusPane", ["w", 1])])
    #expect(try run("focusPreviousPane", store: store).commands == [Command("focusPane", ["w", -1])])
    #expect(try run("toggleSidebar", store: store).commands == [Command("toggleSidebar", ["w"])])
  }

  @Test func littleSolaraSendsWindowCommandsToItsMainWindowAndFocusesIt() throws {
    let store = makeStore(withSmall(fixture()))
    let plan = try run("toggleSidebar", windowId: "s", store: store)
    #expect(plan.commands == [Command("toggleSidebar", ["w"])])
    #expect(plan.focusWindow == "w")
    let downloads = try run("downloads", windowId: "s", store: store)
    #expect(downloads.commands == [Command("setDownloadsOpen", ["s", true])], "Downloads is a Little Solara page command")
    #expect(downloads.focusWindow == nil)
  }

  @Test func settingsWindowCommandsUseTheFocusedBrowserWindow() throws {
    let store = makeStore(fixture())
    #expect(try run("toggleSidebar", windowId: "settings", store: store).commands == [Command("toggleSidebar", ["w"])])
  }

  @Test func withNoWindowTheSettingTogglesStillWorkAndWindowCommandsDoNothing() throws {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.settings["bookmarksBar"] = "newTab"
    let store = makeStore(state)
    #expect(try run("toggleSidebar", windowId: nil, store: store).commands.isEmpty)
    try run("toggleBookmarksBar", windowId: nil, store: store)
    #expect(store.state.settings.string("bookmarksBar") == "never", "with no page open, newTab mode counts as shown, as in JavaScript")
  }

  @Test func setBookmarksBarTakesEachValidMode() throws {
    let store = makeStore(fixture())
    for mode in ["always", "newTab", "never"] {
      try run("setBookmarksBar", arg: mode, store: store)
      #expect(store.state.settings.string("bookmarksBar") == mode)
    }
  }

  @Test func toggleBookmarksBarTurnsAnAlwaysBarOff() throws {
    var state = fixture()
    state.settings["bookmarksBar"] = "always"
    let store = makeStore(state)
    try run("toggleBookmarksBar", store: store)
    #expect(store.state.settings.string("bookmarksBar") == "never")
  }

  @Test func aWindowWithAPeekStillTakesItsWindowCommands() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    #expect(store.state.peeks["w"] != nil)
    let open = store.state.windows["w"]?.sidebarOpen
    #expect(try run("toggleSidebar", store: store).commands == [Command("toggleSidebar", ["w"])])
    #expect(store.state.windows["w"]?.sidebarOpen != open)
    try run("downloads", store: store)
    #expect(store.state.windowUi["w"]?.downloadsOpen == true)
  }

  @Test func aRedirectSkipsAMainWindowThatIsClosing() throws {
    var state = withSmall(fixture())
    var other = BrowserWindow(id: "w2", profileId: "default", incognito: false, frame: nil, createdAt: 3)
    other.tabIds = ["d"]
    other.activeTabIds["default"] = "d"
    state.windows["w2"] = other
    state.windowOrder.append("w2")
    state.ui.focusOrder = ["s", "w", "w2"]
    state.tabs["d"] = Tab(id: "d", windowId: "w2", profileId: "default", url: "https://d.example/", now: 3)
    let store = makeStore(state)
    try store.dispatch(Command("setWindowClosing", ["w", true]), origin: .native)
    #expect(store.memory.closingWindows == ["w"])
    let plan = try run("toggleSidebar", windowId: "s", store: store)
    #expect(plan.commands == [Command("toggleSidebar", ["w2"])])
    #expect(plan.focusWindow == "w2")
    #expect(store.state.ui.focusedWindowId == "w2")
  }

  @Test func focusNextPaneMovesBetweenSplitPanes() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("createSplit", [["a", "b"]]), origin: .native)
    let before = store.state.activeTabId("w")
    try run("focusNextPane", store: store)
    let after = store.state.activeTabId("w")
    #expect(after != before)
    #expect(Set([before, after]) == Set(["a", "b"]))
    try run("focusPreviousPane", store: store)
    #expect(store.state.activeTabId("w") == before)
  }

  @Test func otherCommandsAreNotViewCommands() {
    #expect(ViewMenuCommand.plan("reload", arg: nil, windowId: "w", state: fixture(), closing: []) == nil)
    #expect(ViewMenuCommand.perform("reload", arg: nil, windowId: "w", store: makeStore(fixture())) == nil)
    #expect(ViewMenuCommand.commands.isDisjoint(with: WorkspaceMenuCommand.commands))
  }
}
