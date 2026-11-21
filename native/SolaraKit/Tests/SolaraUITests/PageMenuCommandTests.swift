import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct PageMenuCommandTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b", "n"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusedWindowId = "w"
    state.ui.focusOrder = ["w"]
    var a = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.example/page?q=1", now: 0)
    a.title = "A & B"
    state.tabs["a"] = a
    state.tabs["b"] = Tab(id: "b", windowId: "w", profileId: "default", url: "file:///tmp/b.html", now: 1)
    state.tabs["n"] = Tab(id: "n", windowId: "w", profileId: "default", url: "", now: 2)
    return state
  }

  private func activating(_ tabId: String, _ state: BrowserState) -> BrowserState {
    var state = state
    state.windows["w"]?.activeTabIds["default"] = tabId
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
    state.tabs["c"] = Tab(id: "c", windowId: "s", profileId: "default", url: "https://c.example/", now: 3)
    return state
  }

  private func plan(_ command: String, windowId: String? = "w", _ state: BrowserState, closing: Set<String> = []) throws -> PageMenuPlan {
    try #require(PageMenuCommand.plan(command, arg: nil, windowId: windowId, state: state, closing: closing))
  }

  @Test(arguments: [
    ("reload", PageCommand.reload), ("forceReload", .forceReload), ("stop", .stopLoading), ("print", .print),
    ("printWithSystemDialog", .runPageCommand("systemPrint")), ("savePage", .runPageCommand("savePage")),
    ("caretBrowsing", .runPageCommand("caretBrowsing")), ("devTools", .showDevTools(nil)), ("toggleDevTools", .showDevTools("toggle")),
    ("inspectElements", .showDevTools("inspect")), ("javaScriptConsole", .showDevTools("console")),
    ("zoomIn", .zoomStep(1)), ("zoomOut", .zoomStep(-1)), ("zoomReset", .zoomStep(0)),
  ])
  func pageCommandsGoToTheActiveTabsPage(command: String, action: PageCommand) throws {
    let result = try plan(command, fixture())
    #expect(result == PageMenuPlan(tabId: "a", page: action))
  }

  @Test func zoomNeedsAPageButThePageCallsDoNot() throws {
    let blank = activating("n", fixture())
    for command in ["zoomIn", "zoomOut", "zoomReset", "toggleMute", "viewSource", "emailPageLocation"] {
      #expect(try plan(command, blank) == PageMenuPlan(), "\(command) does nothing without a page")
    }
    #expect(try plan("reload", blank) == PageMenuPlan(tabId: "n", page: .reload))
    #expect(try plan("devTools", blank) == PageMenuPlan(tabId: "n", page: .showDevTools(nil)))
  }

  @Test func toggleMuteWritesTheSiteThenThePage() throws {
    var state = fixture()
    let unmuted = try plan("toggleMute", state)
    #expect(unmuted.commands == [Command("setSiteMuted", ["a", true])])
    #expect(unmuted.page == .setMuted(true))
    state.tabs["a"]?.muted = true
    let muted = try plan("toggleMute", state)
    #expect(muted.commands == [Command("setSiteMuted", ["a", false])])
    #expect(muted.page == .setMuted(false))
  }

  @Test func viewSourceOpensANewTabBesideAWebOrFilePage() throws {
    let web = try plan("viewSource", fixture())
    #expect(web.needsLivePage)
    #expect(web.page == nil)
    #expect(web.commands == [Command("newTab", ["w", ["url": "view-source:https://a.example/page?q=1", "openerId": "a", "profileId": "default"]])])
    let file = try plan("viewSource", activating("b", fixture()))
    #expect(file.commands.first?.args.last?["url"]?.string == "view-source:file:///tmp/b.html")
    var state = fixture()
    state.tabs["a"]?.url = "solara://history"
    #expect(try plan("viewSource", state) == PageMenuPlan())
  }

  @Test func emailUsesTheCustomTitleThenTheTitleThenTheAddress() throws {
    var state = fixture()
    #expect(try plan("emailPageLocation", state).external == "mailto:?subject=A%20%26%20B&body=https%3A%2F%2Fa.example%2Fpage%3Fq%3D1")
    state.tabs["a"]?.customTitle = "Mine"
    #expect(try plan("emailPageLocation", state).external?.hasPrefix("mailto:?subject=Mine&") == true)
    state.tabs["a"]?.customTitle = ""
    state.tabs["a"]?.title = ""
    #expect(try plan("emailPageLocation", state).external?.hasPrefix("mailto:?subject=https%3A%2F%2Fa.example") == true)
    #expect(try plan("emailPageLocation", activating("b", fixture())) == PageMenuPlan(), "file pages aren't mailed")
  }

  @Test func aSharedPinnedPageReloadStaysWithJavaScriptsHandOff() throws {
    var state = fixture()
    state.tabs["a"]?.pageIn = "elsewhere"
    #expect(PageMenuCommand.plan("reload", arg: nil, windowId: "w", state: state, closing: []) == nil)
    #expect(PageMenuCommand.plan("forceReload", arg: nil, windowId: "w", state: state, closing: []) == nil)
    #expect(try plan("zoomIn", state).page == .zoomStep(1))
  }

  @Test func littleSolaraActsOnItsOwnPage() throws {
    let result = try plan("zoomIn", windowId: "s", withSmall(fixture()))
    #expect(result == PageMenuPlan(tabId: "c", page: .zoomStep(1)))
  }

  @Test func aPeekTakesTheWindowsPageCommands() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    let peek = try #require(store.state.peeks["w"]?.tabId)
    #expect(try plan("reload", store.state).tabId == peek)
    #expect(try plan("zoomIn", store.state) == PageMenuPlan(tabId: peek, page: .zoomStep(1)))
  }

  @Test func aPeeksViewSourceAndMuteActOnThePeekPage() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/x"]), origin: .native)
    let peek = try #require(store.state.peeks["w"]?.tabId)
    let source = try plan("viewSource", store.state)
    #expect(source.tabId == peek)
    #expect(source.commands.first?.args.last?["url"]?.string == "view-source:https://peek.example/x")
    #expect(source.commands.first?.args.last?["openerId"]?.string == peek)
    let mute = try plan("toggleMute", store.state)
    #expect(mute.commands == [Command("setSiteMuted", [.string(peek), true])])
    #expect(mute.page == .setMuted(true))
  }

  @Test func anIncognitoWindowsCommandsStayInIt() throws {
    var state = fixture()
    var window = BrowserWindow(id: "p", profileId: "incognito-1", incognito: true, frame: nil, createdAt: 5)
    window.tabIds = ["i"]
    window.activeTabIds["incognito-1"] = "i"
    state.windows["p"] = window
    state.windowOrder.append("p")
    state.tabs["i"] = Tab(id: "i", windowId: "p", profileId: "incognito-1", url: "https://private.example/", now: 6)
    #expect(try plan("reload", windowId: "p", state) == PageMenuPlan(tabId: "i", page: .reload))
    let source = try plan("viewSource", windowId: "p", state)
    #expect(source.commands == [Command("newTab", ["p", ["url": "view-source:https://private.example/", "openerId": "i", "profileId": "incognito-1"]])])
  }

  @Test func theSettingsWindowAndNoWindowRouteLikeJavaScript() throws {
    #expect(try plan("reload", windowId: "settings", fixture()) == PageMenuPlan(tabId: "a", page: .reload))
    var empty = BrowserState(settings: Settings.hydrated(from: nil))
    empty.ui.focusedWindowId = nil
    #expect(try plan("reload", windowId: nil, empty) == PageMenuPlan())
  }

  @Test func otherCommandsAreNotPageCommands() {
    for command in ["copyUrl", "copyUrlAsMarkdown", "openBookmark", "findInPage", "back", "toggleSidebar", "newTab"] {
      #expect(PageMenuCommand.plan(command, arg: nil, windowId: "w", state: fixture(), closing: []) == nil)
    }
  }
}

private func makeUIStore(_ state: BrowserState) -> Store {
  Store(state: state, memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: true, clock: { 1_000 })
}
