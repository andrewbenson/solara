import CoreGraphics
import SolaraLive
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func browser(_ tabs: String, ids: [String], active: String) throws -> BrowserState {
  let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": [\#(list)], "activeTabIds": {"p": "\#(active)"}}},
     "windowOrder": ["w1"], "tabs": {\#(tabs)}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private func tab(_ id: String, _ extra: String = "") -> String {
  #""\#(id)": {"id": "\#(id)", "windowId": "w1", "profileId": "p", "url": "https://\#(id).example/", "title": "\#(id)"\#(extra)}"#
}

private func item(_ n: Int, section: String = "authored", stack: (String, Int)? = nil) -> String {
  let stackJSON = stack.map { #", "stack": {"id": "\#($0.0)", "position": \#($0.1), "size": 2}"# } ?? ""
  return #"""
    {"id": "pr\#(n)", "source": "github", "url": "https://example.com/pr/\#(n)", "title": "PR \#(n)", "subtitle": "", "icon": null, "updatedAt": 1,
     "section": "\#(section)", "pr": {"number": \#(n), "repo": "o/app", "author": "a", "authorAvatar": null, "draft": false, "headRef": "h", "baseRef": "main",
     "review": null, "mergeable": "mergeable", "checks": [], "comments": 0, "unresolvedThreads": 0, "additions": 1, "deletions": 1, "changedFiles": 1\#(stackJSON)}}
    """#
}

private func live(items: [String], collapsed: Bool = false, after: String = "") -> LiveState {
  let text = #"""
    {"folders": {"f1": {"id": "f1", "profileId": "p", "kind": "pullRequests", "name": "PRs", "icon": null, "collapsed": \#(collapsed), "sources": ["github"],
      "filters": {"authored": true, "reviewRequests": true}, "groupStacks": true, "showCompleted": true, "createdAt": 1\#(after)}},
     "folderOrder": ["f1"], "items": {"f1": [\#(items.joined(separator: ","))]},
     "status": {"f1": {"state": "idle", "lastFetch": 1, "error": null}}}
    """#
  return SidebarLive.decode(text)!
}

private func layout(_ state: BrowserState, _ liveState: LiveState) -> SidebarPageLayout {
  let query = SidebarQuery(state)
  var input = SidebarLayoutInput(windowId: "w1", profileId: "p", width: 190, height: 900)
  let blocks = SidebarLiveBlocks(SidebarLive(state: liveState), state: state, windowId: "w1", profileId: "p")
  input.live = blocks
  var entries = query.entries(windowId: "w1", profileId: "p")
  entries.pinned = blocks.sequence(entries.pinned)
  return SidebarLayout(query: query, input: input).layout(entries)
}

@Suite struct SidebarLiveLayoutTests {
  @Test func aFolderSitsInThePinnedSectionWithItsRowsInsideTheBox() throws {
    let state = try browser([tab("t1")].joined(separator: ","), ids: ["t1"], active: "t1")
    let out = layout(state, live(items: [item(1), item(2)]))
    #expect(out.item("lf:f1")?.frame == CGRect(x: 0, y: 25, width: 178, height: 108))
    #expect(out.item("livefolder|f1")?.frame == CGRect(x: 0.5, y: 25.5, width: 177, height: 34))
    #expect(out.item("live|f1|pr1")?.frame == CGRect(x: 2.5, y: 59.5, width: 173, height: 34))
    #expect(out.item("live|f1|pr2")?.frame.minY == 96.5)
    #expect(out.item("t:t1")?.frame.minY == 140)
  }

  @Test func sectionsStacksAndStraysTakeRnHeights() throws {
    let state = try browser(
      [tab("t1"), tab("s1", #", "liveItem": {"folderId": "f1", "itemId": "gone"}"#)].joined(separator: ","), ids: ["t1", "s1"], active: "t1")
    let out = layout(state, live(items: [item(1), item(2, section: "review", stack: ("k", 1)), item(3, section: "review", stack: ("k", 2))]))
    #expect(out.item("li:f1|h:review")?.frame.height == 22)
    #expect(out.item("li:f1|k:k")?.frame.height == 26)
    let stack = try #require(out.item("li:f1|k:k")?.frame)
    #expect(out.item("live|f1|pr2")?.frame.minY == stack.maxY + 3)
    #expect(out.item("t:s1")?.frame.minY == out.item("live|f1|pr3")!.frame.maxY + 3)
    #expect(out.item("lf:f1")?.frame.maxY == out.item("t:s1")!.frame.maxY + 2 + 0.5)
  }

  @Test func aCollapsedFolderKeepsOnlyTheActiveItem() throws {
    let state = try browser(
      [tab("t1"), tab("o2", #", "liveItem": {"folderId": "f1", "itemId": "pr2"}"#)].joined(separator: ","), ids: ["t1", "o2"], active: "o2")
    let out = layout(state, live(items: [item(1), item(2)], collapsed: true))
    #expect(out.item("live|f1|pr1") == nil)
    #expect(out.item("live|f1|pr2")?.frame.minY == 59.5)
    #expect(out.item("lf:f1")?.frame.height == 71)
    let shut = layout(try browser(tab("t1"), ids: ["t1"], active: "t1"), live(items: [item(1)], collapsed: true))
    #expect(shut.item("lf:f1")?.frame.height == 35)
  }

  @Test func aGroupedLiveTabHasOnlyItsGroupRow() throws {
    var state = try browser(
      [tab("keep"), tab("moved", #", "liveItem": {"folderId": "f1", "itemId": "gone"}"#),
       tab("stays", #", "liveItem": {"folderId": "f1", "itemId": "also-gone"}"#)].joined(separator: ","),
      ids: ["keep", "moved", "stays"], active: "moved")
    state.groups["g1"] = TabGroup(
      id: "g1", windowId: "w1", profileId: "p", name: "Group", icon: nil, color: nil, collapsed: false, pinned: false,
      tabIds: ["keep", "moved"], createdAt: 0)
    let out = layout(state, live(items: []))
    #expect(out.items.filter { $0.key == "t:moved" }.map(\.groups) == [["g1"]])
    let folder = try #require(out.item("lf:f1"))
    let stays = try #require(out.item("t:stays"))
    #expect(folder.frame.contains(stays.frame))
  }

  @Test func aLiveTabAloneInAGroupStaysInTheGroup() throws {
    var state = try browser(
      [tab("keep"), tab("moved", #", "liveItem": {"folderId": "f1", "itemId": "gone"}"#)].joined(separator: ","),
      ids: ["keep", "moved"], active: "keep")
    state.groups["g1"] = TabGroup(
      id: "g1", windowId: "w1", profileId: "p", name: "Group", icon: nil, color: nil, collapsed: false, pinned: false,
      tabIds: ["moved"], createdAt: 0)
    let out = layout(state, live(items: []))
    #expect(out.items.filter { $0.key == "t:moved" }.map(\.groups) == [["g1"]])
    #expect(out.item("gh:g1") != nil)
  }

  @Test func aGroupedTabOfAListedItemLeavesTheItemUnopened() throws {
    var state = try browser(
      [tab("keep"), tab("moved", #", "liveItem": {"folderId": "f1", "itemId": "pr1"}"#)].joined(separator: ","),
      ids: ["keep", "moved"], active: "moved")
    state.groups["g1"] = TabGroup(
      id: "g1", windowId: "w1", profileId: "p", name: "Group", icon: nil, color: nil, collapsed: false, pinned: false,
      tabIds: ["keep", "moved"], createdAt: 0)
    let out = layout(state, live(items: [item(1)], collapsed: true))
    #expect(out.items.filter { $0.key == "t:moved" }.map(\.groups) == [["g1"]])
    #expect(out.item("live|f1|pr1") == nil)
    let block = try #require(SidebarLive(state: live(items: [item(1)])).block("f1", browser: state, windowId: "w1", profileId: "p"))
    let specs = block.entries.flatMap(\.rows).compactMap { if case .item(let spec) = $0.kind { spec } else { nil } }
    #expect(specs.map(\.tabId) == [nil])
  }

  @Test func anUnpinnedAnchorMovesItsFolderToThePreviousPinnedRow() throws {
    let pinned = #", "pinned": true, "pinnedAsRow": true"#
    let before = try browser([tab("a", pinned), tab("b", pinned)].joined(separator: ","), ids: ["a", "b"], active: "a")
    let after = try browser([tab("a", pinned), tab("b")].joined(separator: ","), ids: ["a", "b"], active: "a")
    let sidebar = SidebarLive(state: live(items: [], after: #", "after": "t:b""#))
    let expected = [FolderPlacement(id: "f1", after: "t:a")]
    #expect(sidebar.removedAnchorPlacements(before: before, after: after) == expected)
    #expect(sidebar.placements(["t:a", "t:b", "lf:f1"], browser: after, windowId: "w1") == expected)
  }

  @Test func livePinOrderRefusesPrivateAndForeignFolders() throws {
    let pinned = #", "pinned": true, "pinnedAsRow": true"#
    var state = try browser(tab("a", pinned), ids: ["a"], active: "a")
    let sidebar = SidebarLive(state: live(items: []))
    #expect(sidebar.placements(["lf:foreign", "lf:f1", "t:a"], browser: state, windowId: "w1") == [
      FolderPlacement(id: "f1", after: nil),
    ])
    state.windows["w1"]?.incognito = true
    #expect(sidebar.placements(["lf:f1", "t:a"], browser: state, windowId: "w1").isEmpty)
  }

  @Test func foldersFollowTheirAnchor() throws {
    let state = try browser(
      [tab("p1", #", "pinned": true, "pinnedAsRow": true"#), tab("p2", #", "pinned": true, "pinnedAsRow": true"#)].joined(separator: ","),
      ids: ["p1", "p2"], active: "p1")
    let blocks = SidebarLiveBlocks(SidebarLive(state: live(items: [], after: #", "after": "t:p1""#)), state: state, windowId: "w1", profileId: "p")
    #expect(blocks.sequence(["t:p1", "t:p2"]) == ["t:p1", "lf:f1", "t:p2"])
    let first = SidebarLiveBlocks(SidebarLive(state: live(items: [], after: #", "after": null"#)), state: state, windowId: "w1", profileId: "p")
    #expect(first.sequence(["t:p1", "t:p2"]) == ["lf:f1", "t:p1", "t:p2"])
    #expect(SidebarLiveBlocks(SidebarLive(state: live(items: [])), state: state, windowId: "w1", profileId: "p").sequence(["t:p1"]) == ["t:p1", "lf:f1"])
  }
}
