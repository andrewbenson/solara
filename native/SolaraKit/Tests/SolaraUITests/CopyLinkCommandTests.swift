import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI
@Suite struct CopyLinkCommandTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b", "n"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.test/?utm_source=x#ref", now: 0)
    state.tabs["b"] = Tab(id: "b", windowId: "w", profileId: "default", url: "https://b.test/", now: 1)
    state.tabs["n"] = Tab(id: "n", windowId: "w", profileId: "default", url: "", now: 2)
    return state
  }
  private func plan(_ state: BrowserState, closing: Set<String> = []) -> CopyLinkPlan? {
    plan("copyUrl", state, closing: closing)
  }
  private func plan(_ command: String, _ state: BrowserState, closing: Set<String> = []) -> CopyLinkPlan? {
    CopyLinkCommand.plan(command, windowId: "w", state: state, closing: closing)
  }
  @Test func selectedRowsUseSidebarOrderAndSkipBlanks() {
    var s = fixture()
    s.selection["w"] = TabSelection(["b", "n", "a"])
    #expect(plan(s)?.text == "https://a.test/#ref\nhttps://b.test/")
    #expect(plan(s)?.count == 2)
    #expect(plan("copyUrlAsMarkdown", s)?.text == "- [a.test/?utm_source=x#ref](https://a.test/#ref)\n- [b.test](https://b.test/)")
    s.selection["w"] = TabSelection(["b", "n"])
    #expect(plan(s)?.text == "https://a.test/#ref")
    #expect(plan(s)?.offerQuote == true)
  }
  @Test func emptySelectionDoesNotFallBackToAnotherPage() {
    var s = fixture()
    s.windows["w"]?.activeTabIds["default"] = "n"
    s.selection["w"] = TabSelection(["n", "b"])
    s.tabs["b"]?.url = ""
    #expect(plan(s)?.title == "No Links to Copy")
    #expect(plan(s)?.count == 0)
    #expect(plan(s, closing: ["w"]) == nil)
    #expect(plan(BrowserState(settings: Settings.hydrated(from: nil))) == nil)
  }
  @Test func markdownEscapesTitlesAndDestinationsAndCleansTrackers() {
    #expect(CopyLinkCommand.markdown(title: "A [B]\n& C", url: "https://a.test/(x)?id=1&utm_source=x#ref") == "[A \\[B\\] \\& C](https://a.test/\\(x\\)?id=1#ref)")
    #expect(plan("share", fixture())?.url == "https://a.test/?utm_source=x#ref")
    var s = fixture()
    s.tabs["a"]?.url = "file:///a"
    #expect(plan("share", s) == nil)
    #expect(plan("copyQuoteLink", s) == nil)
  }
  @Test func quoteReplacesOnlyTheTextDirectiveAndRequiresSelection() {
    let value: PageValue = .string(#"{"selected":"a-b","before":"","after":"","pageText":"a-b"}"#)
    #expect(CopyLinkCommand.quote(value, url: "https://a.test/?fbclid=x#ref:~:text=old") == "https://a.test/#ref:~:text=a%2Db")
    #expect(CopyLinkCommand.quote(.string("null"), url: "https://a.test/") == nil)
    #expect(CopyLinkCommand.quote(.null, url: "https://a.test/") == nil)
  }
  @Test func selectionAnswerIsThePagesPostedJSON() {
    #expect(CopyLinkCommand.hasSelection(.string("true")))
    #expect(!CopyLinkCommand.hasSelection(.string("false")))
    #expect(!CopyLinkCommand.hasSelection(.string("not json")))
    #expect(!CopyLinkCommand.hasSelection(.null))
  }
  @Test func peekWinsAndLittleSolaraKeepsItsOwnTarget() throws {
    var s = fixture()
    var small = BrowserWindow(id: "s", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    small.kind = "small"; small.tabIds = ["c"]; small.activeTabIds["default"] = "c"
    s.windows["s"] = small
    s.tabs["c"] = Tab(id: "c", windowId: "s", profileId: "default", url: "https://small.test/", now: 0)
    #expect(CopyLinkCommand.plan("copyUrl", windowId: "s", state: s, closing: [])?.tabId == "c")
    let store = makeUIStore(s)
    try store.dispatch(Command("openPeek", ["a", "https://peek.test/"]), origin: .native)
    try store.dispatch(Command("setSelection", ["w", ["a", "b"]]), origin: .native)
    #expect(plan(store.state)?.tabId == store.state.peeks["w"]?.tabId)
    #expect(plan(store.state)?.text == "https://peek.test/")
  }
}
