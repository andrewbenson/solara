import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct WorkspaceControlCloseTests {
  func state(_ json: String) throws -> BrowserState {
    var state = try BrowserState(stateJSON: JSONValue.parse(json).object ?? [:])
    state.settings = Settings.hydrated(from: nil)
    return state
  }

  func warning(_ close: WorkspaceControlClose, _ state: BrowserState, window: Bool, lastTab: Bool) -> String? {
    var next = state
    let store = makeStore(next)
    _ = try? store.dispatch(settingsCommand(["warnBeforeClosingWindow": .bool(window), "warnBeforeClosingLastTab": .bool(lastTab)]))
    next = store.state
    return WorkspaceClosePolicy.controlWarning(close, state: next)
  }

  @Test func anEmptyLastTabClosesItsWindowAndWarnsOnlyWithTheSetting() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let close = try #require(WorkspaceClosePolicy.control(tab, state: store.state))
    #expect(close.windowId == window)
    #expect(close.last && close.closesItsWindow && !close.peeked && !close.closesWindowWithOthers)
    #expect(warning(close, store.state, window: true, lastTab: false) == nil)
    #expect(warning(close, store.state, window: true, lastTab: true) == "warnBeforeClosingLastTab")
  }

  @Test func keepingTheLastTabsWindowMeansTheCloseIsNotTheLast() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let close = try #require(WorkspaceClosePolicy.control(tab, state: store.state, lastTabKeepsWindow: true))
    #expect(!close.last && !close.closesItsWindow)
    #expect(warning(close, store.state, window: true, lastTab: true) == nil)
  }

  @Test func aTabWithSiblingsNeverClosesTheWindowOrWarns() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    try store.dispatch(Command("newTab", [.string(window)]))
    for tab in store.state.windows[window]!.tabIds {
      let close = try #require(WorkspaceClosePolicy.control(tab, state: store.state))
      #expect(!close.last && !close.closesWindowWithOthers)
      #expect(warning(close, store.state, window: true, lastTab: true) == nil)
    }
  }

  @Test func aLoadedLastTabLeavesAnEmptyWindowInsteadOfClosingIt() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(!close.last && !close.closesWindowWithOthers)
    #expect(warning(close, s, window: true, lastTab: true) == nil)
  }

  @Test func anotherProfilesTabsMakeItTheWindowWarningAndFallBackToTheLastTabOne() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a","o"],"activeTabIds":{"p":"a","q":"o"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"","title":""},"o":{"id":"o","windowId":"w","profileId":"q","url":"https://o.example/","title":"O"}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(close.last && close.closesWindowWithOthers && close.closesItsWindow)
    #expect(warning(close, s, window: true, lastTab: true) == "warnBeforeClosingWindow")
    #expect(warning(close, s, window: false, lastTab: true) == "warnBeforeClosingLastTab")
    #expect(warning(close, s, window: false, lastTab: false) == nil)
  }

  @Test func anIncognitoLastTabClosesWithoutTheLastTabWarning() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","incognito":true,"tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(close.last && close.closesItsWindow)
    #expect(warning(close, s, window: true, lastTab: true) == nil)
  }

  @Test func aSmallWindowsLastTabClosesIt() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","kind":"small","tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(close.last && close.closesItsWindow)
    #expect(warning(close, s, window: false, lastTab: true) == "warnBeforeClosingLastTab")
  }

  @Test func aPeekedLastTabWarnsButNeverClosesItsWindow() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"","title":""}},"peeks":{"w":{"tabId":"a","sourceId":"x","sourcePage":"x"}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(close.peeked && close.last && !close.closesItsWindow && !close.closesWindowWithOthers)
    #expect(warning(close, s, window: true, lastTab: true) == "warnBeforeClosingLastTab")
  }

  @Test func pinnedTilesKeepTheWindowWhenTheLastListTabCloses() throws {
    let s = try state(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["t","a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"t":{"id":"t","windowId":"w","profileId":"p","url":"https://t.example/","title":"T","pinned":true,"unloaded":true},"a":{"id":"a","windowId":"w","profileId":"p","url":"","title":""}}}"#)
    let close = try #require(WorkspaceClosePolicy.control("a", state: s))
    #expect(!close.last && !close.closesItsWindow && !close.closesWindowWithOthers)
    let tile = try #require(WorkspaceClosePolicy.control("t", state: s))
    #expect(!tile.last && !tile.closesWindowWithOthers)
  }

  @Test func aTabThatAppearsUnderTheSheetKeepsTheWindowOpen() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    #expect(WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state).closesWindow)
    #expect(try #require(WorkspaceClosePolicy.control(tab, state: store.state)).closesItsWindow)
    try store.dispatch(Command("newTab", [.string(window)]))
    #expect(!WorkspaceClosePolicy.tabs([tab], windowId: window, state: store.state).closesWindow)
    #expect(try #require(WorkspaceClosePolicy.control(tab, state: store.state)).closesItsWindow == false)
  }

  @Test func aMissingTabHasNoPlan() {
    #expect(WorkspaceClosePolicy.control("missing", state: makeStore().state) == nil)
  }
}
