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
