import CoreGraphics
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func sidebarState(tabs: [(id: String, extra: String)], groups: String = "{}", active: String = "t1") throws -> BrowserState {
  let tabJSON = tabs.map { tab in
    let base = tab.extra.contains("\"url\"") ? "" : #", "url": "https://\#(tab.id).example/", "title": "\#(tab.id)""#
    return #""\#(tab.id)": {"id": "\#(tab.id)", "windowId": "w1", "profileId": "p"\#(base)\#(tab.extra)}"#
  }.joined(separator: ",")
  let ids = tabs.map { "\"\($0.id)\"" }.joined(separator: ",")
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": [\#(ids)], "activeTabIds": {"p": "\#(active)"}}},
     "windowOrder": ["w1"], "tabs": {\#(tabJSON)}, "groups": \#(groups)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private func layout(_ state: BrowserState, height: CGFloat = 600, addressBar: Bool = false, divided: Bool = false) -> SidebarPageLayout {
  let query = SidebarQuery(state)
  var input = SidebarLayoutInput(windowId: "w1", profileId: "p", width: 190, height: height)
  input.addressBar = addressBar
  input.divided = divided
  return SidebarLayout(query: query, input: input).layout(query.entries(windowId: "w1", profileId: "p"))
}

@Suite struct SidebarLayoutTests {
  @Test func listRowsSitAtTheRowPitchBelowTheGlowRoom() throws {
    let out = layout(try sidebarState(tabs: [("t1", ""), ("t2", ""), ("t3", "")]))
    #expect(out.tilesFixed)
    #expect(out.lineY == 30)
    #expect(out.fixedHeight == 31)
    #expect(out.scrollTop == 7)
    #expect(out.item("t:t1")?.frame == CGRect(x: 0, y: 25, width: 178, height: 34))
    #expect(out.item("t:t2")?.frame.minY == 62)
    #expect(out.item("t:t3")?.frame.minY == 99)
    #expect(out.item("newTab")?.frame.minY == 136)
    #expect(!out.docked)
  }

  @Test func tilesFillTheFixedGridAboveTheScrollEdge() throws {
    let out = layout(try sidebarState(tabs: [("a", #", "pinned": true"#), ("b", #", "pinned": true"#), ("t1", "")]))
    #expect(out.grid == PinGrid(columns: 2, width: 86))
    #expect(out.item("tile:a")?.frame == CGRect(x: 6, y: 32, width: 86, height: 41))
    #expect(out.item("tile:b")?.frame == CGRect(x: 98, y: 32, width: 86, height: 41))
    #expect(out.item("tile:a")?.region == .fixed)
    #expect(out.lineY == 77)
    #expect(out.item("t:t1")?.frame.minY == 25)
  }

  @Test func anExpandedGroupBoxHoldsItsHeaderAndIndentedMembers() throws {
    let groups = #"{"g1": {"id": "g1", "windowId": "w1", "name": "Work", "tabIds": ["t2", "t3"], "collapsed": false}}"#
    let out = layout(try sidebarState(tabs: [("t1", ""), ("t2", ""), ("t3", "")], groups: groups))
    #expect(out.item("gb:g1")?.frame == CGRect(x: 0, y: 62, width: 178, height: 108))
    #expect(out.item("gh:g1")?.frame == CGRect(x: 0, y: 62.5, width: 178, height: 34))
    #expect(out.item("t:t2")?.frame == CGRect(x: 16, y: 96.5, width: 162, height: 34))
    #expect(out.item("t:t3")?.frame.minY == 133.5)
    #expect(out.item("newTab")?.frame.minY == 173)
  }

  @Test func aCollapsedGroupKeepsOnlyTheActiveMember() throws {
    let groups = #"{"g1": {"id": "g1", "windowId": "w1", "name": "Work", "tabIds": ["t2", "t3"], "collapsed": true}}"#
    let out = layout(try sidebarState(tabs: [("t1", ""), ("t2", ""), ("t3", "")], groups: groups, active: "t3"))
    #expect(out.item("t:t2") == nil)
    #expect(out.item("t:t3")?.frame.minY == 96.5)
    #expect(out.item("gb:g1")?.frame.height == 71)
  }

  @Test func aLongListDocksTheNewTabRowAtTheBottom() throws {
    let tabs = (1...20).map { (id: "t\($0)", extra: "") }
    let out = layout(try sidebarState(tabs: tabs), height: 400)
    #expect(out.docked)
    #expect(out.item("newTab")?.frame == CGRect(x: 6, y: 360, width: 178, height: 34))
    #expect(out.item("newTab")?.region == .dock)
    #expect(out.scrollBottom == 357)
  }

  @Test func withoutPinnedRowsTheListHasNoDividerAndKeepsItsTop() throws {
    let tabs = [(id: "t1", extra: ""), (id: "t2", extra: "")]
    let plain = layout(try sidebarState(tabs: tabs))
    let divided = layout(try sidebarState(tabs: tabs), divided: true)
    #expect(!divided.items.contains { $0.kind == .divider })
    #expect(divided.item("t:t1")?.frame == plain.item("t:t1")?.frame)
    #expect(divided.item("newTab")?.frame == plain.item("newTab")?.frame)
  }

  @Test func pinnedRowsAreDividedFromTheList() throws {
    let tabs = [(id: "p1", extra: #", "pinned": true, "pinnedAsRow": true"#), (id: "t1", extra: "")]
    let plain = layout(try sidebarState(tabs: tabs, active: "t1"))
    let divided = layout(try sidebarState(tabs: tabs, active: "t1"), divided: true)
    let divider = try #require(divided.items.first { $0.kind == .divider })
    #expect(!plain.items.contains { $0.kind == .divider })
    let pinned = try #require(divided.item("t:p1"))
    let first = try #require(divided.item("t:t1"))
    #expect(divider.frame.minY > pinned.frame.maxY)
    #expect(first.frame.minY >= divider.frame.maxY)
  }

  @Test func pinGridUsesTheCountAfterTheDrop() {
    for (count, width, columns, tileWidth) in [(3, 178.0, 3, 55.0), (4, 178, 3, 55), (2, 178, 2, 86), (4, 240, 4, 55.5), (0, 178, 1, 178)] {
      #expect(PinGrid.of(count: count, innerWidth: CGFloat(width), balanced: false) == PinGrid(columns: columns, width: CGFloat(tileWidth)))
    }
  }

  @Test func balancedPinRowsKeepAtMostFourColumns() {
    for (count, width, columns) in [(5, 451.0, 3), (5, 295, 3), (5, 147, 2), (4, 408, 4), (4, 261, 4), (4, 168, 2), (9, 432, 3), (9, 290, 3), (9, 180, 3), (9, 144, 2), (7, 400, 4), (6, 400, 3), (3, 400, 3)] {
      #expect(PinGrid.of(count: count, innerWidth: CGFloat(width), balanced: true).columns == columns)
    }
    #expect(PinGrid.of(count: 4, innerWidth: 178, balanced: true) == PinGrid(columns: 2, width: 86))
    #expect(PinGrid.of(count: 9, innerWidth: 400, balanced: true) == PinGrid(columns: 3, width: 129))
    #expect(PinGrid.of(count: 9, innerWidth: 400, balanced: false) == PinGrid(columns: 7, width: 52))
  }

  @Test func balancedPinTilesGrowWithoutAddingColumns() {
    let grids = [178.0, 240, 320, 400].map { PinGrid.of(count: 6, innerWidth: CGFloat($0), balanced: true) }
    #expect(grids.map(\.columns) == [3, 3, 3, 3])
    for i in 1..<grids.count { #expect(grids[i].width > grids[i - 1].width) }
  }

  @Test func fullPinRowsNeverOverflowOrShrinkBelowTheMinimum() {
    for balanced in [false, true] {
      for halfPoints in 240...800 {
        let width = CGFloat(halfPoints) / 2
        for count in 1...12 {
          let grid = PinGrid.of(count: count, innerWidth: width, balanced: balanced)
          #expect(CGFloat(grid.columns) * grid.width + CGFloat(grid.columns - 1) * 6 <= width + 1e-9)
          #expect(grid.width >= 50 || grid.columns == 1)
        }
      }
    }
  }

  @Test func anExpandedParentSpacesANestedFirstGroupInItsHeightAndRows() throws {
    for nestedFirst in [true, false] {
      let nested = nestedFirst ? #"["t2", "t3"]"# : #"["t5", "t6"]"#
      let groups = #"{"g": {"id": "g", "windowId": "w1", "name": "G", "tabIds": ["t2", "t3", "t4", "t5", "t6"], "collapsed": false}, "n": {"id": "n", "windowId": "w1", "name": "N", "tabIds": \#(nested), "parentId": "g", "collapsed": true}}"#
      let state = try sidebarState(tabs: (0...7).map { (id: "t\($0)", extra: "") }, groups: groups, active: "t0")
      let query = SidebarQuery(state)
      let engine = SidebarLayout(query: query, input: SidebarLayoutInput(windowId: "w1", profileId: "p", width: 190, height: 600))
      let out = engine.layout(query.entries(windowId: "w1", profileId: "p"))
      #expect(query.groupEntries("g").first == (nestedFirst ? "g:n" : "t:t2"))
      #expect(engine.entryHeight("g:n") == 35)
      #expect(engine.entryHeight("g:g") == (nestedFirst ? 186 : 183))
      #expect(out.item("gb:g")?.frame.height == (nestedFirst ? 186 : 183))
      #expect(out.item("t:t4")?.frame.minY == (nestedFirst ? 174.5 : 207.5))
    }
  }

  @Test func aCollapsedParentSpacesItsActiveNestedGroupBelowTheHeader() throws {
    let groups = #"{"g": {"id": "g", "windowId": "w1", "name": "G", "tabIds": ["t2", "t3", "t4", "t5", "t6"], "collapsed": true}, "n": {"id": "n", "windowId": "w1", "name": "N", "tabIds": ["t2", "t3"], "parentId": "g", "collapsed": true}}"#
    let state = try sidebarState(tabs: (0...7).map { (id: "t\($0)", extra: "") }, groups: groups, active: "t3")
    let query = SidebarQuery(state)
    let engine = SidebarLayout(query: query, input: SidebarLayoutInput(windowId: "w1", profileId: "p", width: 190, height: 600))
    let out = engine.layout(query.entries(windowId: "w1", profileId: "p"))
    #expect(engine.entryHeight("g:n") == 71)
    #expect(engine.entryHeight("g:g") == 111)
    #expect(out.item("gb:n")?.frame.height == 71)
    #expect(out.item("gb:g")?.frame.height == 111)
    #expect(out.item("gb:n")?.frame.minY == 136.5)
    #expect(out.item("t:t3")?.frame.minY == 171)
    #expect(out.item("t:t2") == nil)
  }

  @MainActor @Test func rowTitlesFallBackToTheUrlWithoutSchemeOrWww() throws {
    let state = try sidebarState(tabs: [("t1", #", "title": "", "url": "https://www.site.test/path/""#)])
    let context = SidebarContextProbe.title(state, "t1")
    #expect(context == "site.test/path")
  }
}

@MainActor
private enum SidebarContextProbe {
  static func title(_ state: BrowserState, _ id: String) -> String {
    let context = SidebarContext(state: state, host: SidebarHostState(profileId: "p"), windowId: "w1", favicons: SidebarFavicons())
    return state.tabs[id].map(context.title) ?? ""
  }
}
