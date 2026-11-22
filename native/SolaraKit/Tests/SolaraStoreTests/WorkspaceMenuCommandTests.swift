import SolaraModel
import SolaraStore
import Testing

@Suite struct WorkspaceMenuCommandTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b", "c"]
    window.activeTabIds["default"] = "b"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusedWindowId = "w"
    for (index, id) in window.tabIds.enumerated() {
      state.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://\(id).example/", now: Double(index))
    }
    return state
  }

  @discardableResult private func run(_ command: String, arg: String? = nil, windowId: String? = "w", store: Store) throws -> WorkspaceMenuPlan {
    let plan = try #require(WorkspaceMenuCommand.plan(command, arg: arg, windowId: windowId, state: store.state))
    for action in plan.commands { try store.dispatch(action, origin: .native) }
    return plan
  }

  @Test func newTabUsesTheCanonicalStoreAction() throws {
    let store = makeStore(fixture())
    let plan = try run("newTab", store: store)
    #expect(plan.commands == [Command("newTab", ["w", ["newTabCommand": true]])])
    #expect(store.state.windows["w"]?.tabIds.count == 4)
    let active = try #require(store.state.activeTabId("w"))
    #expect(!["a", "b", "c"].contains(active))
    #expect(store.state.tabs[active]?.url == "")
  }

  @Test(arguments: ["page", "empty", "panel"])
  func commandBarNewTabRowCreatesImmediately(surface: String) throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    if surface == "empty" { state.tabs["b"]?.url = "" }
    let store = makeStore(state)
    if surface == "panel" {
      try store.dispatch(Command("openPanel", ["w", "", ["kind": "list"]]))
    }
    let plan = try run("newTab", arg: "create", store: store)
    #expect(plan.commands == [Command("newTab", ["w", ["newTabCommand": true]])])
    #expect(store.state.windows["w"]?.tabIds.count == 4)
    let active = try #require(store.state.activeTabId("w"))
    #expect(!["a", "b", "c"].contains(active))
    #expect(store.state.tabs[active]?.url == "")
    #expect(store.state.windowUi["w"]?.panelOpen != true)
  }

  @Test func commandBarNewTabReusesTheActiveEmptyCard() throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    state.tabs["b"]?.url = ""
    let store = makeStore(state)
    let plan = try run("newTab", store: store)
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "into", "tabId": "b"]])])
    #expect(store.state.windowUi["w"]?.panelOpen == true)
    #expect(store.state.windowUi["w"]?.json["panel"]?["newTab"] == ["kind": "into", "tabId": "b"])
    #expect(store.state.activeTabId("w") == "b")
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
    #expect(store.state.tabs["b"]?.url == "")
  }

  @Test func commandBarNewTabOverAPageCreatesNoTabUntilSubmission() throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    let store = makeStore(state)
    let plan = try run("newTab", store: store)
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "list"]])])
    #expect(store.state.windowUi["w"]?.json["panel"]?["initialText"] == "")
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
    #expect(store.state.activeTabId("w") == "b")
    #expect(store.state.tabs["b"]?.url == "https://b.example/")
  }

  @Test func commandBarNewTabTogglesAnExistingNewTabPanelClosed() throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    let store = makeStore(state)
    try run("newTab", store: store)
    let plan = try run("newTab", store: store)
    #expect(plan.commands == [Command("closePanel", ["w"])])
    #expect(store.state.windowUi["w"]?.panelOpen == false)
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
  }

  @Test func commandBarNewTabReplacesAnAddressPanel() throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    let store = makeStore(state)
    try store.dispatch(Command("openPanel", ["w", "https://b.example/"]))
    try run("newTab", store: store)
    #expect(store.state.windowUi["w"]?.panelOpen == true)
    #expect(store.state.windowUi["w"]?.json["panel"]?["newTab"] == ["kind": "list"])
    #expect(store.state.windowUi["w"]?.json["panel"]?["initialText"] == "")
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
  }

  @Test(arguments: ["pinned", "navigation", "adopted", "split"])
  func commandBarNewTabDoesNotReuseAnOccupiedEmptyCard(reason: String) throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    state.tabs["b"]?.url = ""
    switch reason {
    case "pinned": state.tabs["b"]?.pinned = true
    case "navigation": state.tabs["b"]?.navigation = Navigation(url: "https://pending.example/", seq: 1)
    case "adopted": state.tabs["b"]?.adoptId = "adoption"
    default: state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    }
    let store = makeStore(state)
    let plan = try run("newTab", store: store)
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "list"]])])
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
  }

  @Test func commandBarNewTabInLittleSolaraKeepsTheCanonicalRedirect() throws {
    var state = fixture()
    state.settings["newTabOpens"] = "commandBar"
    state.windows["w"]?.kind = "small"
    let plan = try #require(WorkspaceMenuCommand.plan("newTab", windowId: "w", state: state))
    #expect(plan.commands == [Command("newTab", ["w", ["newTabCommand": true]])])
  }

  @Test func newTabWithoutAWindowCreatesAWindow() throws {
    let store = makeStore()
    let plan = try run("newTab", windowId: nil, store: store)
    #expect(plan.commands == [Command("createWindow", [["newTabCommand": true]])])
    #expect(store.state.windowOrder.count == 1)
    let window = try #require(store.state.windows[store.state.windowOrder[0]])
    #expect(window.tabIds.count == 1)
    #expect(store.state.tabs[window.tabIds[0]]?.newTabPlaceholder == true)
  }

  @Test(arguments: [false, true]) func closingAnUntouchedPlaceholderClosesItsTabWithEitherPresentation(panelOpen: Bool) throws {
    var start = fixture()
    var shown = start.tabs["b"]!
    shown.lastActiveAt = 10
    start.tabs["b"] = shown
    let store = makeStore(start)
    try run("newTab", store: store)
    let placeholder = try #require(store.state.activeTabId("w"))
    if panelOpen { try store.dispatch(Command("openPanel", ["w", "", ["kind": "into", "tabId": .string(placeholder)]])) }
    let before = store.state
    #expect(!WorkspaceClosePolicy.removedPlaceholder([placeholder], before: before, after: before))
    var unloaded = before
    unloaded.tabs[placeholder]!.unloaded = true
    #expect(!WorkspaceClosePolicy.removedPlaceholder([placeholder], before: before, after: unloaded))
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: store.state))
    #expect(plan.commands.isEmpty)
    #expect(plan.close == .tabs(windowId: "w", tabIds: [placeholder]))
    try store.dispatch(Command("closeCommandTabs", [[.string(placeholder)]]))
    #expect(store.state.tabs[placeholder] == nil)
    #expect(WorkspaceClosePolicy.removedPlaceholder([placeholder], before: before, after: store.state))
    #expect(!WorkspaceClosePolicy.removedPlaceholder(["b"], before: before, after: store.state))
    #expect(store.state.activeTabId("w") == "b")
    #expect(store.state.windowUi["w"]?.json["panel"]?["open"]?.truthy != true)
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func commandBarNewTabTargetsAnUntouchedPlaceholder() throws {
    let store = makeStore(fixture())
    try run("newTab", store: store)
    let placeholder = try #require(store.state.activeTabId("w"))
    #expect(store.state.tabs[placeholder]?.newTabPlaceholder == true)
    try store.dispatch(settingsCommand(["newTabOpens": "commandBar"]))
    let plan = try #require(WorkspaceMenuCommand.plan("newTab", windowId: "w", state: store.state))
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "into", "tabId": .string(placeholder)]])])
  }

  @Test func repeatedCommandTOutsideCommandBarModeStacksSavedBlankTabs() throws {
    let store = makeStore(fixture())
    let before = store.state.windows["w"]!.tabIds
    var opened: [String] = []
    for _ in 0..<3 {
      try run("newTab", store: store)
      opened.append(try #require(store.state.activeTabId("w")))
    }
    #expect(Set(opened).count == 3)
    #expect(store.state.windows["w"]!.tabIds.filter { !before.contains($0) }.count == 3)
    #expect(opened.map { store.state.tabs[$0]?.newTabPlaceholder == true } == [false, false, true])
    let saved = store.sessionDocument()
    #expect(saved.tabs[opened[0]] != nil)
    #expect(saved.tabs[opened[1]] != nil)
    #expect(saved.tabs[opened[2]] == nil)
    try store.dispatch(settingsCommand(["newTabOpens": "commandBar"]))
    let plan = try #require(WorkspaceMenuCommand.plan("newTab", windowId: "w", state: store.state))
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "into", "tabId": .string(opened[2])]])])
  }

  @Test func commandBarCloseKeyOverAPlaceholdersBarOnlyDismissesTheBar() throws {
    let store = makeStore(fixture())
    try run("newTab", store: store)
    let placeholder = try #require(store.state.activeTabId("w"))
    try store.dispatch(settingsCommand(["newTabOpens": "commandBar"]))
    try store.dispatch(Command("openPanel", ["w", "", ["kind": "into", "tabId": .string(placeholder)]]))
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: store.state))
    #expect(plan.commands == [Command("closePanel", ["w"])])
    #expect(plan.close == nil)
  }

  @Test func commandBarNewTabOpensIntoASettledBlankRowAsTheSidebarPlusDoes() throws {
    let store = makeStore(fixture())
    try run("newTab", store: store)
    let settled = try #require(store.state.activeTabId("w"))
    try run("newTab", store: store)
    #expect(store.state.tabs[settled]?.newTabPlaceholder != true)
    #expect(store.state.tabs[settled]?.navigation?.url == "about:blank")
    try store.dispatch(Command("activate", [.string(settled)]))
    try store.dispatch(settingsCommand(["newTabOpens": "commandBar"]))
    let plan = try #require(WorkspaceMenuCommand.plan("newTab", windowId: "w", state: store.state))
    #expect(plan.commands == [Command("openPanel", ["w", "", ["kind": "into", "tabId": .string(settled)]])])
  }

  @Test func anOrdinaryEmptyTabsOpenPanelKeepsItsDismissOnlyClose() throws {
    var state = fixture()
    state.tabs["b"]!.url = ""
    let store = makeStore(state)
    try store.dispatch(Command("openPanel", ["w", "", ["kind": "into", "tabId": "b"]]))
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: store.state))
    #expect(plan.commands == [Command("closePanel", ["w"])])
    #expect(plan.close == nil)
  }

  @Test func duplicateUsesTheSelectedTabAndKeepsItsSource() throws {
    let store = makeStore(fixture())
    try run("duplicateTab", store: store)
    let copy = try #require(store.state.activeTabId("w"))
    #expect(copy != "b")
    #expect(store.state.tabs[copy]?.url == "https://b.example/")
    #expect(store.state.tabs["b"]?.url == "https://b.example/")
    #expect(store.state.windows["w"]?.tabIds.count == 4)
  }

  @Test(arguments: [("nextTab", "c"), ("previousTab", "a")])
  func cycleSelectsAdjacentTab(command: String, expected: String) throws {
    let store = makeStore(fixture())
    try run(command, store: store)
    #expect(store.state.activeTabId("w") == expected)
  }

  @Test(arguments: [("selectTab", "1", "a"), ("selectTab", "2", "b"), ("selectLastTab", "", "c")])
  func numberedSelectionUsesSidebarRows(command: String, arg: String, expected: String) throws {
    let store = makeStore(fixture())
    try run(command, arg: arg, store: store)
    #expect(store.state.activeTabId("w") == expected)
  }

  @Test(arguments: ["0", "10", "-1", "abc", "1.5"])
  func invalidNumberIsConsumedWithoutMutation(arg: String) throws {
    let store = makeStore(fixture())
    let before = store.state
    try run("selectTab", arg: arg, store: store)
    #expect(store.state == before)
  }

  @Test(arguments: [("moveTabUp", ["b", "a", "c"]), ("moveTabDown", ["a", "c", "b"])])
  func moveKeepsTheActiveTabAndChangesOrder(command: String, expected: [String]) throws {
    let store = makeStore(fixture())
    try run(command, store: store)
    #expect(store.state.windows["w"]?.tabIds == expected)
    #expect(store.state.activeTabId("w") == "b")
  }

  @Test func moveToNewWindowKeepsTabIdentity() throws {
    let store = makeStore(fixture())
    try run("moveTabToWindow", arg: "new", store: store)
    let destination = try #require(store.state.tabs["b"]?.windowId)
    #expect(destination != "w")
    #expect(store.state.windows[destination]?.tabIds == ["b"])
    #expect(store.state.windows["w"]?.tabIds == ["a", "c"])
    #expect(store.state.activeTabId(destination) == "b")
  }

  @Test func moveToExistingWindowDoesNotTouchOtherTabs() throws {
    let store = makeStore(fixture())
    let destination = try #require(try store.dispatch(Command("createWindow")).result?.string)
    try run("moveTabToWindow", arg: destination, store: store)
    #expect(store.state.tabs["b"]?.windowId == destination)
    #expect(store.state.tabs["a"]?.windowId == "w")
    #expect(store.state.tabs["c"]?.windowId == "w")
  }

  @Test func newWindowUsesTheRequestedProfile() throws {
    let store = makeStore(fixture())
    let profile = try #require(try store.dispatch(Command("createProfile", [["name": "Work"]])).result?.string)
    try run("newWindow", arg: profile, store: store)
    let window = try #require(store.state.windows.values.first { $0.id != "w" })
    #expect(window.profileId == profile)
    #expect(window.incognito == false)
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
  }

  @Test func newPrivateWindowUsesTheOriginalProfile() throws {
    let store = makeStore(fixture())
    try run("newIncognitoWindow", store: store)
    let window = try #require(store.state.windows.values.first { $0.incognito })
    #expect(window.originalProfileId == "default")
    #expect(window.profileId != "default")
    #expect(store.state.tabs[window.tabIds[0]]?.profileId == window.profileId)
  }

  @Test func closeTabProducesAnIntentForTheSelectedTab() throws {
    let state = fixture()
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: state))
    #expect(plan.close == .tabs(windowId: "w", tabIds: ["b"]))
    #expect(plan.commands.isEmpty)
  }

  @Test func closePanelDoesNotCloseItsTab() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("openPanel", ["w", "query"]))
    let plan = try run("closeTab", store: store)
    #expect(plan.close == nil)
    #expect(store.state.windowUi["w"]?.panelOpen == false)
    #expect(store.state.windows["w"]?.tabIds == ["a", "b", "c"])
  }

  @Test func closeNewTabBarDoesNotCloseItsTab() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("openPanel", ["w", "", ["placement": "end"]]))
    let plan = try run("closeTab", store: store)
    #expect(plan.close == nil)
    #expect(store.state.windowUi["w"]?.panelOpen == false)
    #expect(store.state.tabs["b"] != nil)
  }

  @Test func closeUsesMultiSelection() throws {
    var state = fixture()
    state.selection["w"] = TabSelection(["a", "b"])
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: state))
    #expect(plan.close == .tabs(windowId: "w", tabIds: ["a", "b"]))
  }

  @Test func closeSelectionFollowsVisibleOrderAndIgnoresStaleIds() throws {
    var state = fixture()
    state.selection["w"] = TabSelection(["c", "missing", "a"])
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: state))
    #expect(plan.close == .tabs(windowId: "w", tabIds: ["a", "c"]))
  }

  @Test func aSingleStaleSelectionDoesNotReplaceTheActiveTab() throws {
    var state = fixture()
    state.selection["w"] = TabSelection(["a", "missing"])
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: state))
    #expect(plan.close == .tabs(windowId: "w", tabIds: ["b"]))
  }

  @Test func closePeekBeforeUnderlyingTab() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("openPeek", ["b", "https://peek.example/"]))
    let peek = try #require(store.state.peeks["w"]?.tabId)
    let plan = try run("closeTab", store: store)
    #expect(plan.close == nil)
    #expect(store.state.peeks["w"] == nil)
    #expect(store.state.tabs[peek] == nil)
    #expect(store.state.tabs["b"] != nil)
  }

  @Test func closePeekFindBeforePeek() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("openPeek", ["b", "https://peek.example/"]))
    let peek = try #require(store.state.peeks["w"]?.tabId)
    try store.dispatch(Command("setFind", [.string(peek), ["open": true, "query": "hello"]]))
    let plan = try run("closeTab", store: store)
    #expect(plan.close == nil)
    #expect(store.state.find[peek]?.json["open"] == false)
    #expect(store.state.peeks["w"]?.tabId == peek)
    #expect(store.state.tabs["b"] != nil)
  }

  @Test func closeAndReopenSelectedTabsTogether() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeCommandTabs", [["a", "b"]]))
    #expect(store.state.tabs["a"] == nil)
    #expect(store.state.tabs["b"] == nil)
    #expect(store.state.tabs["c"] != nil)
    try run("reopenClosedTab", store: store)
    #expect(store.state.windows["w"]?.tabIds.count == 3)
    #expect(store.state.closedTabs.isEmpty)
    #expect(Set(store.state.tabs.values.map(\.url)) == Set(["https://a.example/", "https://b.example/", "https://c.example/"]))
  }

  @Test func closeAndReopenOneTab() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeCommandTabs", [["b"]]))
    #expect(store.state.tabs["b"] == nil)
    #expect(store.state.closedTabs.count == 1)
    try run("reopenClosedTab", store: store)
    #expect(store.state.closedTabs.isEmpty)
    #expect(store.state.tabs.values.contains { $0.url == "https://b.example/" })
  }

  @Test func aLaterCloseInvalidatesTheCloseTogetherReceipt() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("newTab", ["w", ["url": "https://later.example/"]]))
    let later = try #require(store.state.activeTabId("w"))
    try store.dispatch(Command("closeCommandTabs", [["a", "b"]]))
    try store.dispatch(Command("closeCommandTabs", [[.string(later)]]))
    try run("reopenClosedTab", store: store)
    #expect(store.state.closedTabs.count == 2)
    #expect(store.state.tabs.values.contains { $0.url == "https://later.example/" })
    #expect(!store.state.tabs.values.contains { $0.url == "https://a.example/" })
  }

  @Test func moveToProfileKeepsIdentityAndSelectsItsProfile() throws {
    let store = makeStore(fixture())
    let profile = try #require(try store.dispatch(Command("createProfile", [["name": "Work"]])).result?.string)
    try run("moveTabToProfile", arg: profile, store: store)
    #expect(store.state.tabs["b"]?.profileId == profile)
    #expect(store.state.tabs["b"]?.windowId == "w")
    #expect(store.state.windows["w"]?.profileId == profile)
  }

  @Test func mergeAllWindowsPreservesTabIdentities() throws {
    let store = makeStore(fixture())
    let other = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result?.string)
    let tab = try #require(store.state.activeTabId(other))
    try run("mergeAllWindows", store: store)
    #expect(store.state.windowOrder == ["w"])
    #expect(store.state.tabs[tab]?.windowId == "w")
    #expect(store.state.windows["w"]?.tabIds.count == 4)
  }

  @Test func smallWindowCloseProducesAWindowIntent() throws {
    var state = fixture()
    state.windows["w"]?.kind = "small"
    let plan = try #require(WorkspaceMenuCommand.plan("closeTab", windowId: "w", state: state))
    #expect(plan.close == .window("w"))
  }

  @Test func duplicateCannotAddASecondTabToLittleSolara() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["small": true, "url": "https://small.example/"]])).result?.string)
    try run("duplicateTab", windowId: window, store: store)
    #expect(store.state.windows[window]?.tabIds.count == 1)
  }

  @Test(arguments: ["duplicateTab", "moveTabUp", "moveTabDown", "moveTabToWindow", "moveTabToProfile", "selectTab", "selectLastTab", "nextTab", "previousTab", "mergeAllWindows"])
  func smallWindowMenuDisablesWindowOnlyCommands(command: String) {
    var state = fixture()
    state.windows["w"]?.kind = "small"
    #expect(WorkspaceMenuCommand.available(command, arg: "1", windowId: "w", state: state) == false)
  }

  @Test func directSmallWindowCommandTargetsTheMainWindow() throws {
    let store = makeStore(fixture())
    let small = try #require(try store.dispatch(Command("createWindow", [["small": true, "url": "https://small.example/"]])).result?.string)
    let plan = try run("duplicateTab", windowId: small, store: store)
    #expect(plan.focusWindow == "w")
    #expect(store.state.windows[small]?.tabIds.count == 1)
    #expect(store.state.windows["w"]?.tabIds.count == 4)
    #expect(store.state.tabs.values.filter { $0.url == "https://b.example/" }.count == 2)
  }

  @Test func nativeAvailabilityDoesNotEnableEmptyOrInvalidCommands() {
    #expect(WorkspaceMenuCommand.available("duplicateTab", windowId: nil, state: BrowserState()) == false)
    #expect(WorkspaceMenuCommand.available("selectTab", arg: "0", windowId: "w", state: fixture()) == false)
    #expect(WorkspaceMenuCommand.available("reopenClosedTab", windowId: "w", state: fixture()) == false)
    #expect(WorkspaceMenuCommand.available("newTab", windowId: nil, state: BrowserState()) == true)
    #expect(WorkspaceMenuCommand.available("reload", windowId: "w", state: fixture()) == nil)
  }

  @Test func privateTabsCannotMoveToAnotherProfile() throws {
    var state = fixture()
    state.windows["w"]?.incognito = true
    let plan = try #require(WorkspaceMenuCommand.plan("moveTabToProfile", arg: "default", windowId: "w", state: state))
    #expect(plan.commands.isEmpty)
    #expect(plan.close == nil)
  }

  @Test func restoreClosedTargetsTheChosenReceipt() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeTab", ["a"]))
    let receipt = try #require(store.state.closedTabs.first?.id)
    try run("restoreClosed", arg: receipt, store: store)
    #expect(store.state.closedTabs.isEmpty)
    #expect(store.state.tabs.values.contains { $0.url == "https://a.example/" })
  }

  @Test func closeWindowProducesAWindowIntent() throws {
    let plan = try #require(WorkspaceMenuCommand.plan("closeWindow", windowId: "w", state: fixture()))
    #expect(plan.close == .window("w"))
    #expect(plan.commands.isEmpty)
  }

  @Test func reopenWindowRestoresItsTabs() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeWindow", ["w"]))
    try run("reopenClosedWindow", windowId: nil, store: store)
    #expect(store.state.windowOrder.count == 1)
    #expect(store.state.closedWindows.isEmpty)
    #expect(Set(store.state.tabs.values.map(\.url)) == Set(["https://a.example/", "https://b.example/", "https://c.example/"]))
  }

  @Test func unknownCommandLeavesTheFallbackAvailable() {
    #expect(WorkspaceMenuCommand.plan("reload", windowId: "w", state: fixture()) == nil)
  }

  @Test func closePolicyFiltersMovedAndMissingTabs() {
    let decision = WorkspaceClosePolicy.tabs(["a", "missing"], windowId: "w", state: fixture())
    #expect(decision.tabIds == ["a"])
    #expect(decision.closesWindow == false)
    #expect(decision.warningSetting == nil)
  }

  @Test func closingLastOrdinaryPageLeavesANewTab() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://last.example/"]])).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    let decision = WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state)
    #expect(decision.closesWindow == false)
    #expect(decision.warningSetting == nil)
    try store.dispatch(Command("closeCommandTabs", [[.string(tab)]]))
    #expect(store.state.windows[window]?.tabIds.count == 1)
    let replacement = try #require(store.state.activeTabId(window))
    #expect(replacement != tab)
    #expect(store.state.tabs[replacement]?.url == "")
  }

  @Test func closingAnEmptyLastTabUsesTheLastTabWarning() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    let decision = WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state)
    #expect(decision.closesWindow == true)
    #expect(decision.warningSetting == "warnBeforeClosingLastTab")
  }

  @Test func privateLastTabClosesWithoutTheOrdinaryLastTabWarning() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["incognito": true]])).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    let decision = WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state)
    #expect(decision.closesWindow == true)
    #expect(decision.warningSetting == nil)
  }

  @Test func nativeLastTabPolicyKeepsAnEmptyWindow() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    let decision = WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state, lastTabKeepsWindow: true)
    #expect(decision.closesWindow == false)
    #expect(decision.warningSetting == nil)
  }

  @Test func explicitWindowCloseUsesTheWindowWarning() {
    #expect(WorkspaceClosePolicy.windowWarning(windowId: "w", state: fixture()) == "warnBeforeClosingWindow")
    var small = fixture()
    small.windows["w"]?.kind = "small"
    #expect(WorkspaceClosePolicy.windowWarning(windowId: "w", state: small) == nil)
  }

  @Test func animatedCloseRejectsANewArrival() throws {
    let store = makeStore(fixture())
    let leaving = Set(store.state.windows["w"]!.tabIds)
    #expect(WorkspaceClosePolicy.canFinishClose(windowId: "w", leaving: leaving, state: store.state))
    try store.dispatch(Command("newTab", ["w", ["url": "https://arrived.example/"]]))
    #expect(!WorkspaceClosePolicy.canFinishClose(windowId: "w", leaving: leaving, state: store.state))
  }

  @Test func animatedCloseAcceptsEarlierDepartureAndRejectsMissingWindow() throws {
    let store = makeStore(fixture())
    let leaving = Set(store.state.windows["w"]!.tabIds)
    try store.dispatch(Command("closeTab", ["a"]))
    #expect(WorkspaceClosePolicy.canFinishClose(windowId: "w", leaving: leaving, state: store.state))
    try store.dispatch(Command("closeWindow", ["w"]))
    #expect(!WorkspaceClosePolicy.canFinishClose(windowId: "w", leaving: leaving, state: store.state))
  }

  @Test(arguments: [false, true])
  func cancelledCommandWindowRestoresFromNativeUndoWithoutAJavaScriptSnapshot(incognito: Bool) throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["incognito": .bool(incognito), "url": "https://cancel.example/"]])).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    let profile = try #require(store.state.tabs[tab]?.profileId)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.windows[window] == nil)
    let restored = try store.dispatch(Command("restoreCommandWindow", [.string(window), "cancelled-chrome-window", [["storeTabId": .string(tab), "browserId": 42, "adoptId": "cancelled-live-page"]]]))
    let id = try #require(restored.result?.string)
    #expect(restored.durable)
    #expect(store.state.windows[id]?.incognito == incognito)
    #expect(store.state.windows[id]?.chromeWindow == "cancelled-chrome-window")
    #expect(store.state.windows[id]?.tabIds == [tab])
    #expect(store.state.tabs[tab]?.url == "https://cancel.example/")
    #expect(store.state.tabs[tab]?.profileId == profile)
    #expect(store.state.tabs[tab]?.adoptId == "cancelled-live-page")
  }

  @Test func cancelledCommandWindowRejectsUnrelatedLiveTabs() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeWindow", ["w"]))
    let before = store.state
    let result = try store.dispatch(Command("restoreCommandWindow", ["w", "chrome", [["storeTabId": "unrelated", "browserId": 42, "adoptId": "wrong-page"]]]))
    #expect(result.result?.isNull != false)
    #expect(store.state == before)
  }

  @Test func cancelledCommandWindowCannotRestoreTheSameUndoTwice() throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeWindow", ["w"]))
    let command = Command("restoreCommandWindow", ["w", "chrome", [["storeTabId": "b", "browserId": 42, "adoptId": "page"]]])
    let first = try store.dispatch(command)
    #expect(first.result?.string != nil)
    let before = store.state
    let again = try store.dispatch(command)
    #expect(again.result?.isNull != false)
    #expect(store.state == before)
  }

  @Test(arguments: [1e100, -1e100, 1.5])
  func cancelledCommandWindowRejectsInvalidBrowserNumbers(browserId: Double) throws {
    let store = makeStore(fixture())
    try store.dispatch(Command("closeWindow", ["w"]))
    let before = store.state
    let result = try store.dispatch(Command("restoreCommandWindow", ["w", "chrome", [["browserId": .number(browserId), "adoptId": "wrong-page"]]]))
    #expect(result.result?.isNull != false)
    #expect(store.state == before)
  }
}
