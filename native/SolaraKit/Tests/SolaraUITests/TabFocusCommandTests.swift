import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI
@Suite struct TabFocusCommandTests {
  private func fixture() -> BrowserState {
    var s = BrowserState(settings: Settings.hydrated(from: nil))
    var w = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    w.tabIds = ["a", "b", "c", "gone", "private"]; w.activeTabIds["default"] = "a"
    s.windows["w"] = w; s.windowOrder = ["w"]; s.ui.focusedWindowId = "w"
    for (i, id) in ["a", "b", "c"].enumerated() { s.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://\(id).test", now: Double(3 - i)) }
    s.tabs["private"] = Tab(id: "private", windowId: "w", profileId: "private", url: "https://private.test", now: 4)
    return s
  }
  @Test func recentIdsExcludeMissingOtherProfilesAndStaleTail() {
    #expect(TabFocusCommand.recent(fixture(), windowId: "w", now: 3) == ["a", "b", "c"])
    #expect(TabFocusCommand.recent(fixture(), windowId: "w", now: 50_000_000) == ["a", "b"])
  }
  @Test func backwardWrapAndReleaseOnce() throws {
    let s = fixture(); var hold = try #require(TabFocusCommand.begin(s, windowId: "w", backward: true, now: 3))
    #expect(hold.selected == "c"); hold.step(1, state: s); #expect(hold.selected == "a")
    #expect(hold.release(s) == "a"); #expect(hold.release(s) == nil)
  }
  @Test(arguments: 0..<5) func cancellationClosedTargetAndUnrelatedSelectionRefuseRelease(change: Int) throws {
    var s = fixture(); var hold = try #require(TabFocusCommand.begin(s, windowId: "w", backward: false, now: 3))
    switch change {
    case 0: hold.cancel()
    case 1: s.tabs["b"] = nil
    case 2: s.windows["w"]?.activeTabIds["default"] = "c"
    case 3: s.windows["w"]?.profileId = "private"
    default: s.windows["w"] = nil
    }
    #expect(hold.release(s) == nil)
  }
  @Test func singleTabDoesNotCaptureAndRemovedRowsAreSkipped() throws {
    var s = fixture(); var hold = try #require(TabFocusCommand.begin(s, windowId: "w", backward: false, now: 3))
    s.tabs["b"] = nil; hold.step(1, state: s); #expect(hold.selected == "c")
    s.tabs["c"] = nil; #expect(TabFocusCommand.begin(s, windowId: "w", backward: false, now: 3) == nil)
  }
  @Test func searchScopesOpenClosedAndPeekCandidates() throws {
    let store = makeUIStore(fixture()); try store.dispatch(Command("openPeek", ["a", "https://peek.test/"]), origin: .native)
    let peek = try #require(store.state.peeks["w"]?.tabId); try store.dispatch(Command("closeTab", ["b"]), origin: .native)
    let rows = TabFocusCommand.search(store.state, windowId: "w", dark: false, theme: [:])
    #expect(!rows.open.contains { $0.id == peek || $0.id == "private" })
    #expect(rows.closed.count == 1 && rows.closed.first?.url == "https://b.test"); #expect(rows.open.first?.detail == "Current Tab")
  }
  @Test(arguments: ["default", "private"]) func searchRequiresEveryClosedGroupMemberInCurrentProfile(profileId: String) throws {
    var s = fixture()
    let a = try TabSnapshot(json: #require(s.tabs["a"]).json)
    let b = try TabSnapshot(json: #require(s.tabs["b"]).json)
    let c = try TabSnapshot(json: #require(s.tabs["c"]).json)
    let other = try TabSnapshot(json: #require(s.tabs["private"]).json)
    s.closedGroups = [
      ClosedGroup(id: "mixed", group: ClosedGroupHead(id: "mixed", name: "Mixed profiles", icon: nil, color: nil, pinned: false, parentId: nil),
        tabs: [a, other], tabIds: ["a", "private"], nested: nil, windowId: "w", index: 0, closedAt: 5),
      ClosedGroup(id: "same", group: ClosedGroupHead(id: "same", name: "Same profile", icon: nil, color: nil, pinned: false, parentId: nil),
        tabs: [b, c], tabIds: ["b", "c"], nested: nil, windowId: "w", index: 1, closedAt: 6)
    ]
    for id in ["a", "b", "c", "private"] { s.tabs[id] = nil }
    s.windows["w"]?.tabIds = []; s.windows["w"]?.activeTabIds = [:]
    s.windows["w"]?.profileId = profileId
    let rows = TabFocusCommand.search(s, windowId: "w", dark: false, theme: [:])
    #expect(!rows.closed.contains { $0.id == "mixed" })
    #expect(rows.closed.map(\.id) == (profileId == "default" ? ["same"] : []))
  }
}
