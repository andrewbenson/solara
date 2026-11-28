import Foundation
import JavaScriptCore
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

  @Test func rowsUsePeekForPageFactsAndActiveTabForPinning() {
    var state = fixture()
    state.tabs["a"]?.pinned = true
    state.tabs["a"]?.pinnedAsRow = true
    state.tabs["b"]?.muted = true
    let menu = BrowserMenuContext(state: state, windowId: "w", pageId: "b", opensPeek: true, loading: true)
    #expect(menu.row("stop")?.enabled == true)
    #expect(menu.row("toggleMute")?.title == "Unmute Site")
    #expect(menu.row("closeTab")?.title == "Close Peek")
    #expect(menu.row("togglePin", arg: "tile")?.title == "Move to Top Apps")
  }

  @Test func validationDistinguishesBlankInternalAndLittleWindows() {
    let idle = BrowserMenuContext(state: fixture(), windowId: "w", pageId: "a")
    #expect(idle.row("stop")?.enabled == false)
    let internalPage = BrowserMenuContext(state: fixture(), windowId: "w", pageId: "a", internalPage: true)
    #expect(internalPage.row("reload")?.enabled == false)
    #expect(internalPage.row("copyUrl")?.enabled == true)
    let blank = BrowserMenuContext(state: fixture(), windowId: "w", pageId: "n")
    #expect(blank.row("copyUrl")?.enabled == false)
    let little = BrowserMenuContext(state: withSmall(fixture()), windowId: "s", pageId: "c")
    #expect(little.row("duplicateTab")?.enabled == false)
    #expect(little.row("openFile")?.title == "Open in Solara")
    let windowless = BrowserMenuContext(state: fixture(), windowId: nil, pageId: nil)
    #expect(windowless.row("reload")?.enabled == false)
  }

  @Test func developerValidationUsesPageProfileAndSettings() {
    var state = fixture()
    state.settings = state.settings.choosing(["developerMode": ["default": ["on": ["a.example"]]]])
    let menu = BrowserMenuContext(state: state, windowId: "w", pageId: "a")
    #expect(menu.row("toggleDeveloperMode")?.enabled == true)
    #expect(menu.row("toggleDeveloperMode")?.title == "Turn off Developer Mode for this site")
    let file = BrowserMenuContext(state: state, windowId: "w", pageId: "b")
    #expect(file.row("toggleDeveloperMode")?.enabled == false)
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

  @Test func aSharedPinnedPageReloadIsRecognizedNatively() throws {
    var state = fixture()
    state.tabs["a"]?.pageIn = "elsewhere"
    #expect(PageMenuCommand.plan("reload", arg: nil, windowId: "w", state: state, closing: [])?.page == .reload)
    #expect(PageMenuCommand.plan("forceReload", arg: nil, windowId: "w", state: state, closing: [])?.page == .forceReload)
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

  @Test func jumpUsesTheRequestedWindowsPageWithoutStoreEffects() throws {
    let result = try plan("jumpToSelection", fixture())
    #expect(result.tabId == "a")
    #expect(result.commands.isEmpty)
    #expect(result.external == nil)
    guard case .evaluate = result.page else { Issue.record("Jump needs a page evaluation"); return }
    let small = try plan("jumpToSelection", windowId: "s", withSmall(fixture()))
    #expect(small.tabId == "c")
    #expect(small.page == result.page)
  }

  @Test func jumpKeepsPrivateWindowsIsolated() throws {
    var state = fixture()
    var window = BrowserWindow(id: "p", profileId: "incognito-1", incognito: true, frame: nil, createdAt: 5)
    window.tabIds = ["i"]
    window.activeTabIds["incognito-1"] = "i"
    state.windows["p"] = window
    state.windowOrder.append("p")
    state.tabs["i"] = Tab(id: "i", windowId: "p", profileId: "incognito-1", url: "https://private.example/", now: 6)
    #expect(try plan("jumpToSelection", windowId: "p", state).tabId == "i")
    #expect(try plan("jumpToSelection", windowId: "w", state).tabId == "a")
  }

  @Test func jumpUsesThePeekAndNeverTheUnderlyingPage() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    let peek = try #require(store.state.peeks["w"]?.tabId)
    #expect(try plan("jumpToSelection", store.state).tabId == peek)
  }

  @Test func jumpConsumesBlankAndMissingTargetsWithoutEvaluating() throws {
    #expect(try plan("jumpToSelection", activating("n", fixture())) == PageMenuPlan())
    var state = fixture()
    state.tabs["a"] = nil
    #expect(try plan("jumpToSelection", state) == PageMenuPlan())
    #expect(try plan("jumpToSelection", windowId: nil, BrowserState(settings: Settings.hydrated(from: nil))) == PageMenuPlan())
  }

  @Test(arguments: ["INPUT", "TEXTAREA", "shadow", "frame"])
  func jumpPreservesTheFocusedFieldsSelection(kind: String) throws {
    let context = try jumpContext()
    context.evaluateScript("""
      field.tagName = \(kind == "TEXTAREA" ? "'TEXTAREA'" : "'INPUT'");
      field.value = "one\\ntwo\\nthree";
      field.selectionStart = 8; field.selectionEnd = 10;
      document.activeElement = field;
      """)
    if kind == "shadow" { context.evaluateScript("document.activeElement = { shadowRoot: { activeElement: field } };") }
    if kind == "frame" { context.evaluateScript("document.activeElement = { tagName: 'IFRAME', contentDocument: { activeElement: field } };") }
    try runJump(context)
    #expect(context.objectForKeyedSubscript("result")?.toString() == "true")
    #expect(context.evaluateScript("JSON.stringify(ranges)")?.toString() == "[[10,10],[8,10]]")
    #expect(context.evaluateScript("field.scrolled")?.toBool() == true)
    if kind == "TEXTAREA" { #expect(context.evaluateScript("field.scrollTop")?.toDouble() == 30) }
  }

  @Test(arguments: [false, true])
  func jumpScrollsDocumentSelectionOrEditableCaret(editable: Bool) throws {
    let context = try jumpContext()
    context.evaluateScript("""
      field.tagName = 'DIV'; field.isContentEditable = \(editable);
      document.activeElement = field;
      selection.rangeCount = 1; selection.isCollapsed = \(editable);
      """)
    try runJump(context)
    #expect(context.objectForKeyedSubscript("result")?.toString() == "true")
    #expect(context.evaluateScript("node.scrolled")?.toBool() == true)
    #expect(context.evaluateScript("JSON.stringify(scrolls)")?.toString() == "[[0,710]]")
    #expect(context.evaluateScript("ranges.length")?.toInt32() == 0)
  }

  @Test(arguments: ["readOnly", "disabled", "crossOrigin"])
  func jumpWithoutAnAccessibleSelectionDoesNothing(kind: String) throws {
    let context = try jumpContext()
    context.evaluateScript("field.tagName = 'INPUT'; document.activeElement = field;")
    if kind == "crossOrigin" {
      context.evaluateScript("field.tagName = 'IFRAME'; Object.defineProperty(field, 'contentDocument', { get() { throw new Error('cross origin'); } });")
    } else {
      context.evaluateScript("field[\(kind.debugDescription)] = true;")
    }
    try runJump(context)
    #expect(context.objectForKeyedSubscript("result")?.toString() == "false")
    #expect(context.evaluateScript("scrolls.length + ranges.length")?.toInt32() == 0)
  }

  @Test func jumpWithoutASelectionDoesNothing() throws {
    let context = try jumpContext()
    try runJump(context)
    #expect(context.objectForKeyedSubscript("result")?.toString() == "false")
    #expect(context.evaluateScript("scrolls.length + ranges.length")?.toInt32() == 0)
    #expect(context.evaluateScript("node.scrolled")?.toBool() == false)
  }

  private func jumpContext() throws -> JSContext {
    let context = try #require(JSContext())
    context.evaluateScript("""
      var result, ranges = [], scrolls = [];
      var post = (kind, value) => { result = value; };
      var window = { innerHeight: 600, scrollBy: (x, y) => scrolls.push([x, y]) };
      var node = { nodeType: 1, scrolled: false, scrollIntoView() { this.scrolled = true; } };
      var selection = { rangeCount: 0, isCollapsed: true, getRangeAt: () => ({
        startContainer: node, getBoundingClientRect: () => ({ height: 20, top: 1000, bottom: 1020 })
      }) };
      window.getSelection = () => selection;
      var document = { activeElement: null };
      var field = { ownerDocument: { defaultView: window }, scrolled: false, clientHeight: 20,
        getAttribute: () => 'text', scrollIntoView() { this.scrolled = true; },
        setSelectionRange: (start, end) => ranges.push([start, end]) };
      var getComputedStyle = () => ({ lineHeight: '20', fontSize: '16' });
      """)
    #expect(context.exception == nil)
    return context
  }

  private func runJump(_ context: JSContext) throws {
    let result = try plan("jumpToSelection", fixture())
    let action = try #require(result.page)
    guard case .evaluate(let script) = action else { Issue.record("Jump needs a page evaluation"); return }
    context.evaluateScript(script)
    #expect(context.exception == nil)
  }

  @Test func otherCommandsAreNotPageCommands() {
    for command in ["copyUrl", "copyUrlAsMarkdown", "openBookmark", "findInPage", "back", "toggleSidebar", "newTab"] {
      #expect(PageMenuCommand.plan(command, arg: nil, windowId: "w", state: fixture(), closing: []) == nil)
    }
  }
}

func makeUIStore(_ state: BrowserState) -> Store {
  Store(state: state, memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: true, clock: { 1_000 })
}
