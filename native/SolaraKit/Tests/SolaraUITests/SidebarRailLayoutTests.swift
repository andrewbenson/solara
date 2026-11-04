import CoreGraphics
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func railState(tabs: [(id: String, extra: String)], groups: String = "{}", active: String = "t1") throws -> BrowserState {
  let tabJSON = tabs.map { tab in
    #""\#(tab.id)": {"id": "\#(tab.id)", "windowId": "w1", "profileId": "p", "url": "https://\#(tab.id).example/", "title": "\#(tab.id)"\#(tab.extra)}"#
  }.joined(separator: ",")
  let ids = tabs.map { "\"\($0.id)\"" }.joined(separator: ",")
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": [\#(ids)], "activeTabIds": {"p": "\#(active)"}}},
     "windowOrder": ["w1"], "tabs": {\#(tabJSON)}, "groups": \#(groups)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private func railLayout(_ state: BrowserState, height: CGFloat = 600, divided: Bool = false) -> SidebarPageLayout {
  let query = SidebarQuery(state)
  var input = SidebarLayoutInput(windowId: "w1", profileId: "p", width: CGFloat(SidebarRail.width), height: height)
  input.rail = true
  input.divided = divided
  return SidebarLayout(query: query, input: input).layout(query.entries(windowId: "w1", profileId: "p"))
}

@Suite struct SidebarRailLayoutTests {
  @Test func theRailHoldsTheTrafficLightsAndIsNarrowerThanTheMinimumSidebar() {
    #expect(SidebarRail.width >= 70.75 + 7 + 6)
    #expect(SidebarRail.width < SidebarChromeMetrics.minWidth)
    #expect(SidebarRail.contains(width: SidebarRail.width))
    #expect(!SidebarRail.contains(width: SidebarChromeMetrics.minWidth))
  }

  @Test func theEffectiveWidthIsTheRailOnlyWhileItIsOnAndKeepsTheFullWidth() {
    let window = BrowserWindow(id: "w1", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    let full = Settings.defaults.merging(["sidebarWidth": 240])
    #expect(SidebarRail.effectiveWidth(window, full) == 240)
    let rail = full.merging(["sidebarIconsOnly": true])
    #expect(SidebarRail.effectiveWidth(window, rail) == SidebarRail.width)
    #expect(rail.number("sidebarWidth") == 240)
    #expect(SidebarRail.effectiveWidth(window, Settings.defaults) == 190)
    #expect(Settings.defaults.values["sidebarIconsOnly"] == .bool(false))
  }

  @Test func theRailUsesItsOwnWindowsWidthAndIconsOnlyValue() {
    var window = BrowserWindow(id: "w1", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    let settings = Settings.defaults.merging(["sidebarWidth": 240, "sidebarIconsOnly": true])
    window.sidebarWidth = 280
    window.sidebarIconsOnly = false
    #expect(SidebarRail.effectiveWidth(window, settings) == 280)
    window.sidebarIconsOnly = true
    #expect(SidebarRail.effectiveWidth(window, settings) == SidebarRail.width)
  }

  @Test func topAppsStackInOneColumnAcrossTheRail() throws {
    let out = railLayout(try railState(tabs: [("a", #", "pinned": true"#), ("b", #", "pinned": true"#), ("c", #", "pinned": true"#), ("t1", "")]))
    let inner = CGFloat(SidebarRail.width) - SidebarMetrics.inset * 2
    #expect(out.grid == PinGrid(columns: 1, width: inner))
    #expect(out.item("tile:a")?.frame == CGRect(x: 6, y: 32, width: inner, height: 30))
    #expect(out.item("tile:b")?.frame == CGRect(x: 6, y: 64, width: inner, height: 30))
    #expect(out.item("tile:c")?.frame.minY == 96)
  }

  @Test func eachTabIsOneIconCellAtTheRowPitch() throws {
    let out = railLayout(try railState(tabs: [("t1", ""), ("t2", ""), ("t3", "")]))
    let inner = CGFloat(SidebarRail.width) - SidebarMetrics.inset * 2
    #expect(out.item("t:t1")?.frame == CGRect(x: 0, y: 25, width: inner, height: 30))
    #expect(out.item("t:t2")?.frame.minY == 57)
    #expect(out.item("newTab")?.frame.minY == 121)
  }

  @Test func aGroupIsOneIconWhoseBoxIsJustTheIconAndHasNoMembers() throws {
    let groups = #"{"g1": {"id": "g1", "windowId": "w1", "name": "Work", "tabIds": ["t2", "t3"], "collapsed": false}}"#
    let out = railLayout(try railState(tabs: [("t1", ""), ("t2", ""), ("t3", ""), ("t4", "")], groups: groups))
    let inner = CGFloat(SidebarRail.width) - SidebarMetrics.inset * 2
    #expect(out.item("gb:g1")?.frame == out.item("gh:g1")?.frame)
    #expect(out.item("t:t2") == nil)
    #expect(out.item("t:t3") == nil)
    #expect(out.item("gh:g1")?.frame == CGRect(x: 0, y: 57, width: inner, height: 30))
    #expect(out.item("t:t4")?.frame.minY == 89)
  }

  @Test func theActiveTabInAGroupStillShowsAsTheGroupsIcon() throws {
    let groups = #"{"g1": {"id": "g1", "windowId": "w1", "name": "Work", "tabIds": ["t2", "t3"], "collapsed": true}}"#
    let out = railLayout(try railState(tabs: [("t1", ""), ("t2", ""), ("t3", "")], groups: groups, active: "t3"))
    #expect(out.item("t:t3") == nil)
    #expect(out.item("gh:g1") != nil)
  }

  @Test func theDividerStaysAsALineBetweenPinnedRowsAndTabs() throws {
    let out = railLayout(try railState(tabs: [("p1", #", "pinned": true, "pinnedAsRow": true"#), ("t1", "")]))
    #expect(out.item("divider")?.frame.height == 1)
    #expect(out.item("t:p1")!.frame.maxY < out.item("divider")!.frame.minY)
    #expect(out.item("divider")!.frame.maxY <= out.item("t:t1")!.frame.minY)
  }

  @Test(arguments: [600.0, 160.0]) func topAppsAndPinnedRowsShareTheRailPitch(_ height: CGFloat) throws {
    let out = railLayout(try railState(tabs: [("a", #", "pinned": true"#), ("b", #", "pinned": true"#), ("p", #", "pinned": true, "pinnedAsRow": true"#), ("t1", "")]), height: height)
    let lastTile = try #require(out.item("tile:b"))
    let pinned = try #require(out.item("t:p"))
    let tileBottom = lastTile.frame.maxY + (lastTile.region == .scroll ? out.scrollTop : 0)
    #expect(pinned.frame.minY + out.scrollTop - tileBottom == 2)
    #expect(lastTile.frame.height == 30)
    #expect(pinned.frame.height == 30)
    #expect(out.item("divider")?.frame.height == 1)
    #expect(pinned.frame.maxY < out.item("divider")!.frame.minY)
    #expect(out.item("divider")!.frame.maxY < out.item("t:t1")!.frame.minY)
  }

  @Test(arguments: [600.0, 160.0]) func topAppsAloneStillDividePinnedItemsFromTabs(_ height: CGFloat) throws {
    let out = railLayout(try railState(tabs: [("a", #", "pinned": true"#), ("b", #", "pinned": true"#), ("t1", "")]), height: height)
    let tile = try #require(out.item("tile:b"))
    let divider = try #require(out.item("divider"))
    let tab = try #require(out.item("t:t1"))
    let tileBottom = tile.frame.maxY + (tile.region == .scroll ? out.scrollTop : 0)
    #expect(divider.frame.height == 1)
    #expect(tileBottom < divider.frame.minY + out.scrollTop)
    #expect(divider.frame.maxY < tab.frame.minY)
  }

  @Test func theRailHasNoDividerWithoutBothPinnedItemsAndTabs() throws {
    for tabs in [[("t1", "")], [("p", #", "pinned": true"#)], [("p", #", "pinned": true, "pinnedAsRow": true"#)]] {
      #expect(railLayout(try railState(tabs: tabs), divided: true).item("divider") == nil)
    }
  }

  @Test func theRailDropsTheIncognitoBadgeTheUpsellAndThePlayer() throws {
    let state = try railState(tabs: [("t1", "")])
    let query = SidebarQuery(state)
    var input = SidebarLayoutInput(windowId: "w1", profileId: "p", width: CGFloat(SidebarRail.width), height: 600)
    input.rail = true
    input.incognitoBadge = true
    input.upsellHeight = 80
    input.playerHeight = 120
    let out = SidebarLayout(query: query, input: input).layout(query.entries(windowId: "w1", profileId: "p"))
    #expect(out.item("incognito") == nil)
    #expect(out.item("upsell") == nil)
    #expect(out.playerFrame == nil)
    #expect(out.item("t:t1")?.frame.minY == 25)
  }

  @Test func theFullSidebarLayoutIsUnchangedWithTheRailOff() throws {
    let groups = #"{"g1": {"id": "g1", "windowId": "w1", "name": "Work", "tabIds": ["t2", "t3"], "collapsed": false}}"#
    let state = try railState(tabs: [("t1", ""), ("t2", ""), ("t3", "")], groups: groups)
    let query = SidebarQuery(state)
    let out = SidebarLayout(query: query, input: SidebarLayoutInput(windowId: "w1", profileId: "p", width: 190, height: 600))
      .layout(query.entries(windowId: "w1", profileId: "p"))
    #expect(out.item("gb:g1")?.frame == CGRect(x: 0, y: 62, width: 178, height: 108))
    #expect(out.item("t:t2")?.frame == CGRect(x: 16, y: 96.5, width: 162, height: 34))
  }
}
