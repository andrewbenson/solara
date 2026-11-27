import CoreGraphics
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func stripState(tabs: [(id: String, extra: String)], groups: String = "{}", splits: String = "{}", active: String) throws -> BrowserState {
  let tabJSON = tabs.map { tab in
    #""\#(tab.id)": {"id": "\#(tab.id)", "windowId": "w1", "profileId": "p", "url": "https://\#(tab.id).example/", "title": "\#(tab.id)"\#(tab.extra)}"#
  }.joined(separator: ",")
  let ids = tabs.map { "\"\($0.id)\"" }.joined(separator: ",")
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": [\#(ids)], "activeTabIds": {"p": "\#(active)"}}},
     "windowOrder": ["w1"], "tabs": {\#(tabJSON)}, "groups": \#(groups), "splits": \#(splits)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private let tabs = StripDragGeometry(
  [StripDragSlot(tabIds: ["a"], width: 100), StripDragSlot(tabIds: ["b"], width: 100), StripDragSlot(tabIds: ["c"], width: 100)], gap: 4)

private func aim(_ from: Int, _ pointer: CGFloat, _ target: (Int) -> Bool = { _ in true }) -> StripAim {
  StripLayout.aimDrop(tabs, from: from, pointer: pointer, target: target, edge: 43)
}

@Suite struct StripLayoutTests {
  @Test func workspaceProjectionReplacesFeedSelectionAndStatusInTheCurrentWindow() throws {
    var state = try BrowserState(stateJSON: JSONValue.parse(#"""
      {"windows":{"a":{"id":"a","profileId":"work","tabIds":["t","placeholder"]},"b":{"id":"b","profileId":"p","tabIds":["other"]}},
       "tabs":{"t":{"id":"t","windowId":"a","profileId":"work","url":"https://example.com/"},
               "placeholder":{"id":"placeholder","windowId":"a","profileId":"work","url":""},
               "other":{"id":"other","windowId":"b","profileId":"p","url":"https://example.org/"}}}
      """#).object ?? [:])
    state.selection["a"] = TabSelection(["t"])
    state.live["t"] = PageLiveFacts(themeColor: "#336699")
    state.live["placeholder"] = PageLiveFacts(themeColor: "#FFFFFF")
    state.live["other"] = PageLiveFacts(themeColor: "#FF0000")
    var host = StripHostState(profileId: "stale")
    host.selection = ["other"]
    host.engines = ["other": "old"]
    host.bands = ["other": "#FF0000"]
    host.applyWorkspace(state: state, windowId: "a") { $0.id == "t" ? "engine" : nil }
    #expect(host.profileId == "work")
    #expect(host.selection == ["t"])
    #expect(host.engines == ["t": "engine"])
    #expect(host.bands == ["t": "#336699"])
  }

  @Test func draggingRightHoldsTheRoomUntilTheFarQuarter() {
    #expect(aim(0, 110) == StripAim(to: 0, onto: nil))
    #expect(aim(0, 129) == StripAim(to: 0, onto: nil))
    #expect(aim(0, 154) == StripAim(to: 0, onto: 1))
    #expect(aim(0, 178) == StripAim(to: 0, onto: 1))
    #expect(aim(0, 180) == StripAim(to: 1, onto: nil))
    #expect(aim(0, 260) == StripAim(to: 1, onto: 2))
    #expect(aim(0, 320) == StripAim(to: 2, onto: nil))
  }

  @Test func draggingLeftMirrorsIt() {
    #expect(aim(2, 200) == StripAim(to: 2, onto: nil))
    #expect(aim(2, 154) == StripAim(to: 2, onto: 1))
    #expect(aim(2, 129) == StripAim(to: 1, onto: nil))
    #expect(aim(2, 50) == StripAim(to: 1, onto: 0))
    #expect(aim(2, 10) == StripAim(to: 0, onto: nil))
  }

  @Test func slotsThatTakeNoDropReorderAtTheirCentre() {
    #expect(aim(0, 153) { _ in false } == StripAim(to: 0, onto: nil))
    #expect(aim(0, 155) { _ in false } == StripAim(to: 1, onto: nil))
  }

  @Test func aWideGroupsEndsStayNarrow() {
    let strip = StripDragGeometry([StripDragSlot(tabIds: ["a"], width: 100), StripDragSlot(tabIds: ["g1", "g2", "g3"], width: 400 + StripMetrics.membersInset)], gap: 4)
    #expect(StripLayout.aimDrop(strip, from: 0, pointer: 134, target: { _ in true }, edge: 43) == StripAim(to: 0, onto: nil))
    #expect(StripLayout.aimDrop(strip, from: 0, pointer: 154, target: { _ in true }, edge: 43) == StripAim(to: 0, onto: 1))
    #expect(StripLayout.aimDrop(strip, from: 0, pointer: 504, target: { _ in true }, edge: 43) == StripAim(to: 1, onto: nil))
  }

  @Test func revealScrollsOnlyAsFarAsNeeded() {
    #expect(StripLayout.revealOffset(left: 200, width: 150, scrolled: 0, viewport: 600, pad: 19) == nil)
    #expect(StripLayout.revealOffset(left: 400, width: 150, scrolled: 100, viewport: 600, pad: 19) == nil)
    #expect(StripLayout.revealOffset(left: 900, width: 150, scrolled: 0, viewport: 600, pad: 19) == 469)
    #expect(StripLayout.revealOffset(left: 500, width: 150, scrolled: 0, viewport: 600, pad: 19) == 69)
    #expect(StripLayout.revealOffset(left: 300, width: 150, scrolled: 500, viewport: 600, pad: 19) == 281)
    #expect(StripLayout.revealOffset(left: 10, width: 150, scrolled: 500, viewport: 600, pad: 19) == 0)
    #expect(StripLayout.revealOffset(left: 1000, width: 800, scrolled: 0, viewport: 600, pad: 19) == 981)
  }

  @Test func aTabWithItsOwnDockCellRevealsThatCell() {
    let members = ["folder:f": ["a", "b"], "a": ["a"], "c": ["c"]]
    let cells = ["folder:f", "c", "a"]
    #expect(StripLayout.dockCell(cells, members: { members[$0]! }, tabId: "a") == 2)
    #expect(StripLayout.dockCell(cells, members: { members[$0]! }, tabId: "b") == 0)
    #expect(StripLayout.dockCell(cells, members: { members[$0]! }, tabId: "z") == nil)
  }

  @Test func reorderOffsetsMoveTheDraggedSlotAndCloseTheGap() {
    #expect(StripLayout.reorderOffsets(tabs, from: 0, to: 2) == [208, -104, -104])
    #expect(StripLayout.reorderOffsets(tabs, from: 2, to: 0) == [104, 104, -208])
  }

  @Test func reorderOffsetsLeaveAStripThatNoLongerHoldsTheDraggedSlotInPlace() {
    #expect(StripLayout.reorderOffsets(StripDragGeometry([], gap: 4), from: 0, to: 0) == [])
    #expect(StripLayout.reorderOffsets(tabs, from: 3, to: 1) == [0, 0, 0])
  }

  @Test func tabWidthSharesTheRoomBetweenMinAndMax() {
    let w = StripLayout.tabWidth(pageWidth: 1000, dockWidth: 0, groups: [], tabUnits: 4, fixed: 0, gap: 4, plus: 32, min: 96, max: 173)
    #expect(w == 173)
    let tight = StripLayout.tabWidth(pageWidth: 700, dockWidth: 0, groups: [], tabUnits: 5, fixed: 0, gap: 4, plus: 32, min: 96, max: 173)
    #expect(tight == 129)
  }

  @Test func theStripShowsARootGroupsNestedGroupsAsOneFolderEach() throws {
    let groups = #"""
      {"outer": {"id": "outer", "windowId": "w1", "profileId": "p", "name": "Outer", "tabIds": ["a", "b", "c", "d"], "pinned": true, "collapsed": false},
       "inner": {"id": "inner", "windowId": "w1", "profileId": "p", "name": "Inner", "tabIds": ["b", "c"], "parentId": "outer", "collapsed": false},
       "deep": {"id": "deep", "windowId": "w1", "profileId": "p", "name": "Deep", "tabIds": ["c"], "parentId": "inner", "collapsed": false}}
      """#
    let state = try stripState(
      tabs: [("r1", #", "pinned": true, "pinnedAsRow": true"#), ("r2", #", "pinned": true, "pinnedAsRow": true"#), ("home", ""), ("a", ""), ("b", ""), ("c", ""), ("d", ""), ("x", "")],
      groups: groups, active: "home")
    let keys = StripQuery(state).keys(windowId: "w1", profileId: "p")
    #expect(keys == ["pinned:r1", "pinned:r2", "tab:home:", "group:outer:0", "tab:a:outer", "folder:inner:b,c:outer", "tab:d:outer", "tab:x:"])
    let entries = StripQuery.parse(keys)
    guard case .group(let outer) = entries[2] else { Issue.record("no group"); return }
    #expect(outer.members.map(\.id) == ["a", "inner", "d"])
  }

  @Test func pageLayoutPlacesTheDockGroupsAndNewTab() throws {
    let groups = #"{"g": {"id": "g", "windowId": "w1", "profileId": "p", "name": "G", "tabIds": ["b", "c"], "collapsed": false}}"#
    let state = try stripState(tabs: [("p1", #", "pinned": true"#), ("a", ""), ("b", ""), ("c", "")], groups: groups, active: "a")
    let entries = StripQuery(state).entries(windowId: "w1", profileId: "p")
    let layout = StripPageLayout(entries: entries, activeId: "a", pageWidth: 1000, flare: 15, chipWidth: { _ in 60 }, folderWidth: { _ in 0 })
    #expect(layout.chip == 173)
    #expect(layout.items.map(\.key) == ["dock", "tab:a", "group:g", "newTab"])
    #expect(layout.items[0].x == 15)
    let tabX: CGFloat = 53.5
    let groupX: CGFloat = 234
    let groupWidth: CGFloat = 446.75
    #expect(layout.items[1].x == tabX)
    #expect(layout.items[2].x == groupX)
    #expect(layout.items[2].width == groupWidth)
    #expect(layout.span(of: "c")?.x == 477.5)
    #expect(layout.items[3].x == 689.25)
  }
}
