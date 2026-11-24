import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct FindMenuCommandTests {
  private func fixture(query: String? = nil) -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "n"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusedWindowId = "w"
    state.ui.focusOrder = ["w"]
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.example/", now: 0)
    state.tabs["n"] = Tab(id: "n", windowId: "w", profileId: "default", url: "", now: 1)
    if let query {
      var find = FindState()
      find.json["open"] = true
      find.json["query"] = .string(query)
      state.find["a"] = find
    }
    return state
  }

  private func plan(_ command: String, windowId: String? = "w", _ state: BrowserState, request: Int = 7) throws -> FindMenuPlan {
    try #require(FindMenuCommand.plan(command, windowId: windowId, state: state, closing: [], focusRequest: request))
  }

  private func setFind(_ tabId: String, _ patch: JSONObject) -> [Command] {
    [Command("setFind", [.string(tabId), .object(patch)])]
  }

  @Test func findInPageOpensTheBarAndAsksForFocus() throws {
    let result = try plan("findInPage", fixture(), request: 41)
    #expect(result == FindMenuPlan(commands: setFind("a", ["open": true, "replace": false, "focusRequest": 41]), tabId: "a", windowId: "w", claimsFocus: true))
  }

  @Test func findAndReplaceOpensTheReplaceRowWithoutAFocusClaim() throws {
    let result = try plan("findAndReplace", fixture(), request: 42)
    #expect(result == FindMenuPlan(commands: setFind("a", ["open": true, "replace": true, "focusRequest": 42]), tabId: "a", windowId: "w"))
  }

  @Test func eachRequestCarriesItsOwnFocusValue() throws {
    let first = try plan("findInPage", fixture(), request: 100)
    let second = try plan("findInPage", fixture(), request: 101)
    #expect(first.commands != second.commands)
  }

  @Test(arguments: [("findNext", true), ("findPrevious", false)])
  func stepsSearchAgainWithTheQuery(command: String, forward: Bool) throws {
    let result = try plan(command, fixture(query: "needle"))
    #expect(result == FindMenuPlan(tabId: "a", windowId: "w", page: .find("needle", forward, true)))
  }

  @Test(arguments: ["findNext", "findPrevious"])
  func stepsWithoutAQueryOnlyOpenTheBar(command: String) throws {
    let result = try plan(command, fixture())
    #expect(result == FindMenuPlan(commands: setFind("a", ["open": true]), tabId: "a", windowId: "w"))
  }

  @Test func useSelectionReadsThePageSelection() throws {
    let result = try plan("useSelectionForFind", fixture())
    #expect(result == FindMenuPlan(tabId: "a", windowId: "w", page: .evaluate(FindMenuCommand.selectionScript), readsSelection: true))
  }

  @Test func aFindRequestNeverOutlivesItsFocusGate() {
    #expect(FindMenuCommand.focusAllowed(expired: false, pendingGateLive: true))
    #expect(!FindMenuCommand.focusAllowed(expired: false, pendingGateLive: false))
    #expect(!FindMenuCommand.focusAllowed(expired: true, pendingGateLive: true))
    #expect(!FindMenuCommand.focusAllowed(expired: true, pendingGateLive: nil))
    #expect(FindMenuCommand.focusAllowed(expired: false, pendingGateLive: nil))
  }

  @Test func nativeFindRequestsNeverMatchAJavaScriptTimestamp() {
    let now = 1_795_457_605_512
    var last = 0
    var issued: [Int] = []
    for _ in 0..<20 {
      last = FindMenuCommand.nextFocusRequest(after: last, nowMilliseconds: now)
      issued.append(last)
    }
    #expect(Set(issued).count == issued.count, "every native request is unique, even within one millisecond")
    #expect(!issued.contains(now), "a JavaScript request made with Date.now() in the same millisecond can't match")
    #expect(issued.allSatisfy { $0 != 0 && !(now...now + 20).contains($0) })
    #expect(zip(issued, issued.dropFirst()).allSatisfy { $0 != $1 })
    let later = FindMenuCommand.nextFocusRequest(after: last, nowMilliseconds: now + 5_000)
    #expect(!issued.contains(later) && later != now + 5_000)
  }

  @Test func theSelectionBecomesTheQueryOnlyWhenThereIsOne() {
    #expect(FindMenuCommand.selectionQuery(.string("\"word\"")) == "word")
    #expect(FindMenuCommand.selectionQuery(.string("\"\"")) == "")
    #expect(FindMenuCommand.selectionQuery(.null) == nil)
    #expect(FindMenuCommand.selectionFind("", tabId: "a", focusRequest: 3) == nil)
    #expect(FindMenuCommand.selectionFind("word", tabId: "a", focusRequest: 3) == Command("setFind", ["a", ["open": true, "query": "word", "focusRequest": 3]]))
  }

  @Test(arguments: ["findInPage", "findAndReplace", "findNext", "findPrevious", "useSelectionForFind"])
  func anEmptyTabDoesNothing(command: String) throws {
    var state = fixture()
    state.windows["w"]?.activeTabIds["default"] = "n"
    #expect(try plan(command, state) == FindMenuPlan())
  }

  @Test func aPeekTakesTheFind() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    let peek = try #require(store.state.peeks["w"]?.tabId)
    let result = try plan("findInPage", store.state)
    #expect(result.tabId == peek)
    #expect(result.commands.first?.args.first?.string == peek)
  }

  @Test func littleSolaraFindsInItsOwnPage() throws {
    var state = fixture()
    var small = BrowserWindow(id: "s", profileId: "default", incognito: false, frame: nil, createdAt: 2)
    small.kind = "small"
    small.tabIds = ["c"]
    small.activeTabIds["default"] = "c"
    state.windows["s"] = small
    state.windowOrder.append("s")
    state.tabs["c"] = Tab(id: "c", windowId: "s", profileId: "default", url: "https://c.example/", now: 3)
    let result = try plan("findInPage", windowId: "s", state)
    #expect(result.tabId == "c")
    #expect(result.windowId == "s")
  }

  @Test func theSettingsWindowsFindStaysWithItsSearch() {
    #expect(FindMenuCommand.plan("findInPage", windowId: "settings", state: fixture(), closing: [], focusRequest: 1) == nil)
  }

  @Test func noWindowDoesNothing() throws {
    var empty = BrowserState(settings: Settings.hydrated(from: nil))
    empty.ui.focusedWindowId = nil
    #expect(try plan("findInPage", windowId: nil, empty) == FindMenuPlan())
  }

  @Test func otherCommandsAreNotFindCommands() {
    for command in ["jumpToSelection", "reload", "copyUrl", "newTab"] {
      #expect(FindMenuCommand.plan(command, windowId: "w", state: fixture(), closing: [], focusRequest: 1) == nil)
    }
  }

  @Test func theFindSliceTakesTheNativeOpen() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(try plan("findInPage", store.state, request: 9).commands, origin: .native)
    #expect(store.state.find["a"]?.json["open"]?.truthy == true)
    #expect(store.state.find["a"]?.json["focusRequest"] == .number(9))
  }

  @Test func theFindSliceKeepsANativeRequestId() throws {
    let store = makeUIStore(fixture())
    let request = FindMenuCommand.nextFocusRequest(after: 0, nowMilliseconds: 1_795_457_605_512)
    try store.dispatch(try plan("findInPage", store.state, request: request).commands, origin: .native)
    #expect(store.state.find["a"]?.json["focusRequest"] == .number(Double(request)))
  }
}
