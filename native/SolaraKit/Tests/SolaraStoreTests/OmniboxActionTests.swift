import SolaraModel
import SolaraStore
import Testing

@Suite struct OmniboxActionTests {
  private func fixture() -> BrowserState {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["source", "target"]
    window.activeTabIds[profile] = "source"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.tabs["source"] = Tab(id: "source", windowId: "w", profileId: profile, url: "https://source.example/", now: 0)
    state.tabs["target"] = Tab(id: "target", windowId: "w", profileId: profile, url: "https://target.example/", now: 0)
    state.ui.focusedWindowId = "w"
    state.ui.focusOrder = ["w"]
    return state
  }

  private func store(_ state: BrowserState? = nil) -> Store {
    Store(state: state ?? fixture(), checksInvariants: false, clock: { 1_000 })
  }

  private func open(_ store: Store, _ disposition: String = "current", target: JSONValue? = nil, url: String = "https://opened.example/") throws -> Commit {
    var args: [JSONValue] = ["w", "source", .string(url), .string(disposition)]
    if let target { args.append(target) }
    return try store.dispatch(Command("omniboxOpen", args))
  }

  @Test(arguments: ["https://typed.example/", "cats and dogs"])
  func ordinaryReturnNavigatesTheExistingTab(_ input: String) throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    let commit = try open(store, url: input)
    #expect(commit.result?["tabId"]?.string == "source")
    #expect(commit.result?["windowId"]?.string == "w")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.tabs["source"]?.navigation != nil)
    #expect(store.state.tabs["source"]?.navigation?.userInitiated == true)
    #expect(store.state.windowUi["w"]?.panelOpen == false)
  }

  @Test func foregroundAndBackgroundModifiersUseCanonicalNewTabs() throws {
    for disposition in ["newTab", "backgroundTab"] {
      let store = store()
      let commit = try open(store, disposition)
      let id = try #require(commit.result?["tabId"]?.string)
      #expect(id != "source")
      #expect(store.state.tabs[id]?.navigation?.url == "https://opened.example/")
      #expect(store.state.tabs[id]?.openerId == "source")
      #expect(store.state.activeTabId("w") == (disposition == "backgroundTab" ? "source" : id))
    }
  }

  @Test func shiftReturnCreatesAWindowWithTheSourceProfile() throws {
    let store = store()
    let commit = try open(store, "newWindow")
    let windowId = try #require(commit.result?["windowId"]?.string)
    let tabId = try #require(commit.result?["tabId"]?.string)
    #expect(windowId != "w")
    #expect(store.state.windows[windowId]?.profileId == BrowserState.defaultProfile.id)
    #expect(store.state.tabs[tabId]?.navigation?.url == "https://opened.example/")
    #expect(store.state.ui.focusedWindowId == windowId)
  }

  @Test func privateNewWindowCreatesANewPrivateIdentity() throws {
    let store = store()
    let created = try store.dispatch(Command("createWindow", [["incognito": true]]))
    let windowId = try #require(created.result?.string)
    let tabId = try #require(store.state.activeTabId(windowId))
    let result = try store.dispatch(Command("omniboxOpen", [.string(windowId), .string(tabId), "https://private.example/", "newWindow"]))
    let other = try #require(result.result?["windowId"]?.string)
    #expect(store.state.windows[other]?.incognito == true)
    #expect(store.state.windows[other]?.originalProfileId == BrowserState.defaultProfile.id)
    #expect(store.state.windows[other]?.profileId != store.state.windows[windowId]?.profileId)
  }

  @Test func heroReturnNavigatesItsExistingEmptyTab() throws {
    var state = fixture()
    state.tabs["source"]?.url = ""
    let store = store(state)
    let commit = try open(store)
    #expect(commit.result?["tabId"]?.string == "source")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.tabs["source"]?.navigation?.url == "https://opened.example/")
  }

  @Test func newTabIntoTargetNavigatesItsExistingEmptyTab() throws {
    var state = fixture()
    state.tabs["source"]?.url = ""
    let store = store(state)
    try store.dispatch(Command("openPanel", ["w", "", ["kind": "into", "tabId": "source"]]))
    let commit = try open(store, target: true)
    #expect(commit.result?["tabId"]?.string == "source")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.tabs["source"]?.navigation?.url == "https://opened.example/")
    #expect(store.state.windowUi["w"]?.panelOpen == false)
  }

  @Test func listTargetCallsNewTabAndHonorsPlacement() throws {
    let store = store()
    try store.dispatch(Command("updateSettings", [["newTabPosition": "nextToCurrent"]]))
    let commit = try open(store, target: ["kind": "list"])
    let id = try #require(commit.result?["tabId"]?.string)
    #expect(store.state.windows["w"]?.tabIds == ["source", id, "target"])
    #expect(store.state.activeTabId("w") == id)
  }

  @Test func groupTargetUsesCanonicalGroupCreationAndNavigation() throws {
    var state = fixture()
    state.groups["group"] = TabGroup(id: "group", windowId: "w", profileId: BrowserState.defaultProfile.id,
      name: "Group", icon: nil, color: nil, collapsed: true, pinned: false, tabIds: ["target"], createdAt: 0)
    let store = store(state)
    let commit = try open(store, target: ["kind": "group", "groupId": "group"])
    let id = try #require(commit.result?["tabId"]?.string)
    #expect(store.state.groups["group"]?.tabIds == ["target", id])
    #expect(store.state.groups["group"]?.collapsed == false)
    #expect(store.state.tabs[id]?.navigation?.url == "https://opened.example/")
    #expect(store.state.activeTabId("w") == id)
  }

  @Test func staleIntoTargetFallsBackToCanonicalListOpen() throws {
    let store = store()
    let commit = try open(store, target: ["kind": "into", "tabId": "target"])
    let id = try #require(commit.result?["tabId"]?.string)
    #expect(id != "target")
    #expect(store.state.tabs["target"]?.url == "https://target.example/")
    #expect(store.state.tabs.count == 3)
  }

  @Test func modifiedOpenDoesNotReuseTheIntoTarget() throws {
    var state = fixture()
    state.tabs["source"]?.url = ""
    let store = store(state)
    let commit = try open(store, "backgroundTab", target: ["kind": "into", "tabId": "source"])
    #expect(commit.result?["tabId"]?.string != "source")
    #expect(store.state.tabs["source"]?.navigation == nil)
    #expect(store.state.activeTabId("w") == "source")
  }

  @Test func staleOrForeignSourceDoesNothing() throws {
    let store = store()
    try store.dispatch(Command("activate", ["target"]))
    let state = store.state
    #expect(try open(store).result == .null)
    #expect(store.state == state)
    #expect(try store.dispatch(Command("omniboxOpen", ["missing", "target", "https://opened.example/", "newWindow"])).result == .null)
    #expect(store.state == state)
  }

  @Test func emptyInputDoesNotDismissThePanel() throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    #expect(try open(store, url: "  ").result == .null)
    #expect(store.state.windowUi["w"]?.panelOpen == true)
  }

  @Test func unknownDispositionIsRejectedWithoutMutation() throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    let before = store.snapshot
    for command in [
      Command("omniboxOpen", ["w", "source", "https://opened.example/", "invalid"]),
      Command("omniboxSwitch", ["w", "source", "target", "https://target.example/", "invalid"]),
    ] {
      #expect(throws: CommandError.self) { try store.dispatch(command) }
      #expect(store.state == before.state)
      #expect(store.rev == before.rev)
    }
  }

  @Test func switchReturnActivatesAnExistingTabWithoutNavigating() throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    let commit = try store.dispatch(Command("omniboxSwitch", ["w", "source", "target", "https://target.example/", "current"]))
    #expect(commit.result?["tabId"]?.string == "target")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.activeTabId("w") == "target")
    #expect(store.state.tabs["target"]?.navigation?.url == "https://target.example/")
    #expect(store.state.windowUi["w"]?.panelOpen == false)
  }

  @Test func modifiedSwitchOpensRatherThanActivatesTheSuggestedTab() throws {
    let store = store()
    let commit = try store.dispatch(Command("omniboxSwitch", ["w", "source", "target", "https://target.example/", "backgroundTab"]))
    let id = try #require(commit.result?["tabId"]?.string)
    #expect(id != "target")
    #expect(store.state.tabs[id]?.navigation?.url == "https://target.example/")
    #expect(store.state.activeTabId("w") == "source")
  }

  @Test func switchAcrossWindowsUsesTheTargetsProfileAndFocus() throws {
    let store = store()
    let created = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]]))
    let windowId = try #require(created.result?.string)
    let tabId = try #require(store.state.activeTabId(windowId))
    let commit = try store.dispatch(Command("omniboxSwitch", ["w", "source", .string(tabId), "https://other.example/", "current"]))
    #expect(commit.result?["windowId"]?.string == windowId)
    #expect(store.state.ui.focusedWindowId == windowId)
    #expect(store.state.activeTabId(windowId) == tabId)
  }

  @Test func closedSuggestionDoesNotNavigateOrDismiss() throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    let before = store.state
    #expect(try store.dispatch(Command("omniboxSwitch", ["w", "source", "gone", "https://gone.example/", "current"])).result == .null)
    #expect(store.state == before)
  }

  @Test func privateSuggestionCannotSwitchIntoANormalWindow() throws {
    let store = store()
    let created = try store.dispatch(Command("createWindow", [["incognito": true]]))
    let windowId = try #require(created.result?.string)
    let tabId = try #require(store.state.activeTabId(windowId))
    let before = store.state
    let commit = try store.dispatch(Command("omniboxSwitch", [.string(windowId), .string(tabId), "target", "https://target.example/", "current"]))
    #expect(commit.result == .null)
    #expect(store.state == before)
  }

  @Test(arguments: ["showHistory", "manageBookmarks"])
  func internalPageCommandsReuseAnExistingTab(_ command: String) throws {
    var state = fixture()
    let url = command == "showHistory" ? "solara://history" : "solara://bookmarks"
    state.tabs["target"]?.url = url
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", .string(command)]))
    #expect(commit.result?["tabId"]?.string == "target")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.activeTabId("w") == "target")
  }

  @Test func internalPageCommandUsesAnEmptyActiveTab() throws {
    var state = fixture()
    state.tabs["source"]?.url = ""
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "showHistory"]))
    #expect(commit.result?["tabId"]?.string == "source")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.tabs["source"]?.navigation?.url == "solara://history")
  }

  @Test func internalPageCommandCreatesATabWhenTheActivePageIsOccupied() throws {
    let store = store()
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "manageBookmarks"]))
    let id = try #require(commit.result?["tabId"]?.string)
    #expect(id != "source")
    #expect(store.state.tabs[id]?.navigation?.url == "solara://bookmarks")
  }

  @Test(arguments: ["newTab", "newWindow", "newIncognitoWindow", "duplicateTab"])
  func openingCommandsUseCanonicalStoreActions(_ command: String) throws {
    let store = store()
    try store.dispatch(Command("openPanel", ["w", "", .null]))
    let commit = try store.dispatch(Command("omniboxCommand", ["w", .string(command)]))
    let id = try #require(commit.result?["tabId"]?.string)
    let windowId = try #require(commit.result?["windowId"]?.string)
    #expect(id != "source")
    #expect(store.state.windowUi["w"]?.panelOpen == false)
    if command == "newWindow" || command == "newIncognitoWindow" {
      #expect(windowId != "w")
      #expect(store.state.windows[windowId]?.incognito == (command == "newIncognitoWindow"))
    } else {
      #expect(windowId == "w")
      #expect(store.state.activeTabId("w") == id)
    }
    if command == "duplicateTab" { #expect(store.state.tabs[id]?.url == "https://source.example/") }
  }

  @Test func downloadsCommandTogglesTheNativeWindowState() throws {
    let store = store()
    #expect(try store.dispatch(Command("omniboxCommand", ["w", "downloads"])).result == true)
    #expect(store.state.windowUi["w"]?.downloadsOpen == true)
    try store.dispatch(Command("omniboxCommand", ["w", "downloads"]))
    #expect(store.state.windowUi["w"]?.downloadsOpen == false)
  }

  @Test func profileCommandUsesTheExistingProfileAction() throws {
    let store = store()
    let created = try store.dispatch(Command("createProfile", [["name": "Other"]]))
    let profileId = try #require(created.result?.string)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", .string("switchProfile:" + profileId)]))
    #expect(store.state.windows["w"]?.profileId == profileId)
    #expect(commit.result?["tabId"]?.string == store.state.activeTabId("w"))
  }

  @Test func unknownCommandLeavesTheFallbackAvailableWithoutMutation() throws {
    let store = store()
    let before = store.state
    #expect(try store.dispatch(Command("omniboxCommand", ["w", "unknown"])).result == false)
    #expect(store.state == before)
  }

  @Test(arguments: ["SOLARA://HiStOrY?q=swift", "solara://history/?q=swift#fragment"])
  func internalPageReusePreservesQueriesAndUsesThePendingDestination(_ url: String) throws {
    var state = fixture()
    state.tabs["target"]?.navigation = Navigation(url: url, seq: 1)
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "showHistory"]))
    #expect(commit.result?["tabId"]?.string == "target")
    #expect(store.state.tabs.count == 2)
    #expect(store.state.tabs["target"]?.navigation?.url == url)
  }

  @Test func internalPageReuseRejectsATabAlreadyNavigatingAway() throws {
    var state = fixture()
    state.tabs["target"]?.url = "solara://history?q=old"
    state.tabs["target"]?.navigation = Navigation(url: "https://elsewhere.example/", seq: 1)
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "showHistory"]))
    #expect(commit.result?["tabId"]?.string != "target")
    #expect(store.state.tabs.count == 3)
  }

  @Test func switchToAnotherProfileActivatesTheExistingTab() throws {
    let store = store()
    let created = try store.dispatch(Command("createProfile", [["name": "Other"]]))
    let profileId = try #require(created.result?.string)
    let opened = try store.dispatch(Command("newTab", ["w", ["profileId": .string(profileId), "url": "https://profile.example/", "background": true]]))
    let targetId = try #require(opened.result?.string)
    let commit = try store.dispatch(Command("omniboxSwitch", ["w", "source", .string(targetId), "https://profile.example/", "current"]))
    #expect(commit.result?["tabId"]?.string == targetId)
    #expect(store.state.windows["w"]?.profileId == profileId)
    #expect(store.state.activeTabId("w") == targetId)
  }

  @Test(arguments: ["split:sideBySide", "split:stacked"])
  func splitOpeningCommandsUseTheRequestedSide(_ command: String) throws {
    let store = store()
    let commit = try store.dispatch(Command("omniboxCommand", ["w", .string(command)]))
    let tabId = try #require(commit.result?["tabId"]?.string)
    let split = try #require(store.state.splits.values.first)
    #expect(split.tabIds == ["source", tabId])
    #expect(split.orientation == (command == "split:sideBySide" ? "horizontal" : "vertical"))
    #expect(store.state.activeTabId("w") == tabId)
    #expect(store.state.tabs.count == 3)
  }

  @Test(arguments: ["horizontal", "vertical"])
  func addingASplitUsesTheExistingOrientation(_ orientation: String) throws {
    var state = fixture()
    state.splits["existing"] = SplitView(id: "existing", windowId: "w", tabIds: ["source", "target"],
      orientation: orientation, sizes: [0.5, 0.5])
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "split:add"]))
    let tabId = try #require(commit.result?["tabId"]?.string)
    let split = try #require(store.state.splits["existing"])
    #expect(split.orientation == orientation)
    #expect(split.tabIds == ["source", tabId, "target"])
    #expect(split.stack == nil)
    #expect(split.sizes.count == 3)
  }

  @Test(arguments: ["horizontal", "vertical"])
  func crossSplitUsesTheOppositeAxisInTheActiveSlot(_ orientation: String) throws {
    var state = fixture()
    state.splits["existing"] = SplitView(id: "existing", windowId: "w", tabIds: ["source", "target"],
      orientation: orientation, sizes: [0.5, 0.5])
    let store = store(state)
    let commit = try store.dispatch(Command("omniboxCommand", ["w", "split:cross"]))
    let tabId = try #require(commit.result?["tabId"]?.string)
    let split = try #require(store.state.splits["existing"])
    #expect(split.orientation == orientation)
    #expect(split.tabIds == ["source", tabId, "target"])
    #expect(split.stack?.index == 0)
    #expect(Splits.slotsOf(split) == [["source", tabId], ["target"]])
    #expect(split.sizes.count == 2)
  }

  @Test func splitCommandsConsumeMissingActiveTabsWithoutCreatingAnything() throws {
    var state = fixture()
    state.tabs = Table()
    state.windows["w"]?.tabIds = []
    state.windows["w"]?.activeTabIds = JSMap()
    let store = store(state)
    for command in ["split:sideBySide", "split:stacked", "split:add", "split:cross"] {
      #expect(try store.dispatch(Command("omniboxCommand", ["w", .string(command)])).result == true)
      #expect(store.state.tabs.isEmpty)
      #expect(store.state.splits.isEmpty)
    }
  }

  @Test func splitCommandsRespectTheCanonicalMaximumPaneLimit() throws {
    var state = fixture()
    state.tabs["third"] = Tab(id: "third", windowId: "w", profileId: BrowserState.defaultProfile.id, url: "https://third.example/", now: 0)
    state.windows["w"]?.tabIds.append("third")
    state.splits["existing"] = SplitView(id: "existing", windowId: "w", tabIds: ["source", "target", "third"],
      orientation: "horizontal", sizes: [0.3, 0.3, 0.4])
    let store = store(state)
    let before = store.state
    #expect(try store.dispatch(Command("omniboxCommand", ["w", "split:add"])).result == true)
    #expect(store.state.tabs == before.tabs)
    #expect(store.state.splits == before.splits)
  }
}
