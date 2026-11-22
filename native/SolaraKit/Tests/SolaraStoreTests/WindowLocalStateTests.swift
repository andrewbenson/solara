import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct WindowLocalStateTests {
  static func windowWithTabs(_ store: Store, count: Int) throws -> (String, [String]) {
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for _ in 1..<count {
      let tab = try store.dispatch(Command("newTab", [.string(window)])).result!.string!
      try store.dispatch(Command("settleNewTab", [.string(tab)]))
    }
    return (window, store.state.windows[window]!.tabIds)
  }

  @Test func setSelectionDedupesFiltersToTheViewAndDropsEmptyEntries() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 3)
    let commit = try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[2]), .string(tabs[0]), .string(tabs[2]), "missing"]]))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[2]), .string(tabs[0])]])
    #expect(commit.patch.json["selection"] == ["upsert": [["windowId": .string(window), "ids": [.string(tabs[2]), .string(tabs[0])]]], "remove": []])
    #expect(!commit.durable)
    let same = try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[2]), .string(tabs[0])]]))
    #expect(same.changes.isEmpty)
    let cleared = try store.dispatch(Command("setSelection", [.string(window), []]))
    #expect(store.state.stateJSON["selection"] == [:])
    #expect(cleared.patch.json["selection"] == ["upsert": [], "remove": [.string(window)]])
    let ignored = try store.dispatch(Command("setSelection", ["missing", [.string(tabs[0])]]))
    #expect(ignored.changes.isEmpty)
  }

  @Test func aPlainClickActivatesAndAnchorsInOneCommit() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 3)
    try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[0]), .string(tabs[1])]]))
    let before = store.rev
    let commit = try store.dispatch(Command("clickTab", [.string(window), .string(tabs[0]), [:]]))
    #expect(commit.rev == before + 1)
    #expect(store.state.activeTabId(window) == tabs[0])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[0])])
    #expect(store.state.stateJSON["selection"] == [:])
    #expect(commit.patch.json["selectionAnchors"] != nil)
    #expect(commit.patch.json["selection"] != nil)
  }

  @Test func commandClickTogglesFromTheActiveTabAndShiftClickSelectsTheRangeFromTheAnchor() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 4)
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    try store.dispatch(Command("clickTab", [.string(window), .string(tabs[2]), ["metaKey": true]]))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[0]), .string(tabs[2])]])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[2])])
    #expect(store.state.activeTabId(window) == tabs[0])
    try store.dispatch(Command("clickTab", [.string(window), .string(tabs[2]), ["metaKey": true]]))
    #expect(store.state.stateJSON["selection"] == [:])
    try store.dispatch(Command("clickTab", [.string(window), .string(tabs[3]), ["shiftKey": true]]))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[2]), .string(tabs[3])]])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[2])])
    try store.dispatch(Command("clickTab", [.string(window), .string(tabs[0]), ["shiftKey": true]]))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[0]), .string(tabs[1]), .string(tabs[2])]])
  }

  @Test func optionShiftClickGroupsTheTabWithTheActiveOne() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 3)
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    let before = store.rev
    let commit = try store.dispatch(Command("clickTab", [.string(window), .string(tabs[2]), ["altKey": true, "shiftKey": true]]))
    #expect(commit.rev == before + 1)
    let group = store.state.groups.values.first { $0.tabIds.contains(tabs[0]) }
    #expect(group?.tabIds.contains(tabs[2]) == true)
    #expect(store.state.activeTabId(window) == tabs[2])
    #expect(store.state.stateJSON["selection"] == [:])
  }

  @Test func panelAndDownloadsCommandsKeepOneEntryPerWindowAndIgnoreUnknownWindows() throws {
    let store = makeStore()
    let (window, _) = try Self.windowWithTabs(store, count: 1)
    #expect(try store.dispatch(Command("closePanel", [.string(window)])).changes.isEmpty)
    #expect(try store.dispatch(Command("openPanel", ["missing", "x"])).changes.isEmpty)
    let opened = try store.dispatch(Command("openPanel", [.string(window), "typed", ["kind": "tab"]]))
    let open: JSONValue = ["panel": ["open": true, "initialText": "typed", "newTab": ["kind": "tab"]], "downloadsOpen": false]
    #expect(store.state.stateJSON["windowUi"] == [window: open])
    #expect(opened.patch.json["windowUi"] == ["upsert": [["windowId": .string(window), "state": open]], "remove": []])
    #expect(!opened.durable)
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    try store.dispatch(Command("closePanel", [.string(window)]))
    #expect(store.state.stateJSON["windowUi"] == [window: ["panel": ["open": false, "initialText": ""], "downloadsOpen": true]])
    #expect(try store.dispatch(Command("closePanel", [.string(window)])).changes.isEmpty)
    try store.dispatch(Command("openPanel", [.string(window)]))
    #expect(store.state.stateJSON["windowUi"]?[window]?["panel"] == ["open": true, "initialText": ""])
  }

  @Test func activatingANewTabClosesTheOpenPanelInTheSameCommitWithoutAnEffect() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 2)
    let (other, _) = try Self.windowWithTabs(store, count: 1)
    try store.dispatch(Command("openPanel", [.string(other), "elsewhere"]))
    try store.dispatch(Command("openPanel", [.string(window), "typed"]))
    let commit = try store.dispatch(Command("activate", [.string(tabs[0])]))
    #expect(store.state.stateJSON["windowUi"]?[window]?["panel"] == ["open": false, "initialText": ""])
    #expect(store.state.stateJSON["windowUi"]?[other]?["panel"] == ["open": true, "initialText": "elsewhere"])
    #expect(commit.patch.json["windowUi"] != nil)
    #expect(commit.effects.allSatisfy { $0.json["type"] != "closePanel" })
    try store.dispatch(Command("openPanel", [.string(window), "again"]))
    try store.dispatch(Command("newTab", [.string(window)]))
    #expect(store.state.stateJSON["windowUi"]?[window]?["panel"]?["open"] == false)
  }

  @Test func groupingClearsTheWindowsSelectionInTheSameCommit() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 3)
    let (other, otherTabs) = try Self.windowWithTabs(store, count: 2)
    try store.dispatch(Command("setSelection", [.string(other), JSONValue(otherTabs)]))
    try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[1]), .string(tabs[2])]]))
    let commit = try store.dispatch(Command("groupTabs", [[.string(tabs[1]), .string(tabs[2])], ["pinned": false]]))
    #expect(store.state.stateJSON["selection"] == [other: JSONValue(otherTabs)])
    #expect(commit.patch.json["selection"] == ["upsert": [], "remove": [.string(window)]])
    #expect(commit.effects.allSatisfy { $0.json["type"] != "clearSelection" })
  }

  @Test func aNewDownloadOpensTheFocusedWindowsDownloads() throws {
    let store = makeStore()
    let (window, _) = try Self.windowWithTabs(store, count: 1)
    try store.dispatch(Command("setFocusedWindow", [.string(window)]))
    let commit = try store.dispatch(Command("upsertDownload", [["id": "d1", "state": "downloading", "profile": ""]]))
    #expect(store.state.stateJSON["windowUi"]?[window]?["downloadsOpen"] == true)
    #expect(commit.patch.json["windowUi"] != nil)
    #expect(commit.effects.allSatisfy { $0.json["type"] != "openDownloads" })
  }

  @Test func swappingTabsSwapsTheirIdsInEverySelection() {
    var state = BrowserState()
    state.selection["w1"] = TabSelection(["a", "c"])
    state.selection["w2"] = TabSelection(["b"])
    state.selection["w3"] = TabSelection(["c"])
    state.swapSelection("a", "b")
    #expect(state.selection["w1"]?.ids == ["b", "c"])
    #expect(state.selection["w2"]?.ids == ["a"])
    #expect(state.selection["w3"]?.ids == ["c"])
  }

  @Test func closingTabsAndWindowsPrunesSelectionAnchorsAndWindowUi() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 3)
    let (other, _) = try Self.windowWithTabs(store, count: 1)
    try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[1]), .string(tabs[2])]]))
    try store.dispatch(Command("closeTab", [.string(tabs[1])]))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[2])]])
    try store.dispatch(Command("closeTab", [.string(tabs[2])]))
    #expect(store.state.stateJSON["selection"] == [:])
    try store.dispatch(Command("clickTab", [.string(other), .string(store.state.windows[other]!.tabIds[0]), [:]]))
    try store.dispatch(Command("setDownloadsOpen", [.string(other), true]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(tabs[0])]))
    let commit = try store.dispatch(Command("closeWindow", [.string(other)]))
    #expect(store.state.stateJSON["windowUi"] == [:])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[0])])
    #expect(commit.patch.json["windowUi"] == ["upsert": [], "remove": [.string(other)]])
    #expect(commit.patch.json["selectionAnchors"] == ["upsert": [], "remove": [.string(other)]])
  }

  @Test func hydrateAndApplyStateCannotKeepOrReplaceWindowLocalState() throws {
    let store = makeStore()
    let (window, tabs) = try Self.windowWithTabs(store, count: 2)
    let document = store.sessionDocument().json()
    try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[0]), .string(tabs[1])]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(tabs[1])]))
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    try store.dispatch(Command("applyState", [["selection": [:], "selectionAnchors": [:], "windowUi": [:]]]))
    #expect(store.state.stateJSON["selection"]?[window] != nil)
    #expect(store.state.stateJSON["selectionAnchors"]?[window] != nil)
    #expect(store.state.stateJSON["windowUi"]?[window] != nil)
    try store.dispatch(Command("hydrate", [document]))
    #expect(store.state.stateJSON["selection"] == [:])
    #expect(store.state.stateJSON["selectionAnchors"] == [:])
    #expect(store.state.stateJSON["windowUi"] == [:])
  }
}
