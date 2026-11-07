import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
  abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
}

private func splitState(sizes: [Double] = [0.5, 0.5]) throws -> BrowserState {
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "a"}}},
     "windowOrder": ["w1"],
     "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/", "title": "a"},
              "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/", "title": "b"}},
     "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": \#(sizes)}}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

@Suite struct SplitDropTests {
  let left = CGRect(x: 0, y: 0, width: 600, height: 700)
  let right = CGRect(x: 607, y: 0, width: 600, height: 700)

  @Test func zonesSitWhereRnPutsThem() {
    #expect(near(SplitDrop.zoneRect(left, .left, .rest), CGRect(x: 15, y: 215.95, width: 79.44, height: 268.1)))
    #expect(near(SplitDrop.zoneRect(left, .right, .grown), CGRect(x: 459, y: 136.15, width: 129, height: 427.7)))
    #expect(near(SplitDrop.zoneRect(left, .left, .active, pointerX: 300), CGRect(x: 100.305, y: 108.5, width: 144.6, height: 483)))
    #expect(near(SplitDrop.zoneRect(right, .right, .active, pointerX: 1100), CGRect(x: 1045.085, y: 108.5, width: 144.6, height: 483)))
  }

  @Test func hitsMatchRn() {
    let panes = [(tabId: "a", rect: left), (tabId: "b", rect: right)]
    #expect(SplitDrop.zoneHit(panes, 80, 350, current: nil) == SplitDropTarget(tabId: "a", side: .left))
    #expect(SplitDrop.zoneHit(panes, 560, 350, current: nil) == SplitDropTarget(tabId: "a", side: .right))
    #expect(SplitDrop.zoneHit(panes, 300, 350, current: SplitDropTarget(tabId: "a", side: .left)) == SplitDropTarget(tabId: "a", side: .left))
    #expect(SplitDrop.zoneHit([(tabId: "a", rect: left)], 300, 50, current: nil) == nil)
  }

  @Test func rnSpringConfigConverts() {
    let pop = SpringParams.rn(speed: 14, bounciness: 14)
    #expect(abs(pop.stiffness - 384.58) < 0.01)
    #expect(abs(pop.damping - 18.2) < 0.01)
  }
}

@Suite @MainActor struct SplitChromeTests {
  @Test func dividersAndPanesFollowTheSplit() throws {
    let view = SplitChromeView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    #expect(view.panes["a"] == CGRect(x: 0, y: 0, width: 500, height: 700))
    #expect(view.panes["b"] == CGRect(x: 507, y: 0, width: 500, height: 700))
    let dividers = view.subviews.compactMap { $0 as? SplitDividerView }
    #expect(dividers.count == 1)
    #expect(dividers.first?.frame == CGRect(x: 498, y: 0, width: 11, height: 700))
  }

  @Test func theNoticeKeepsItsOwnSlotAboveALaterToast() throws {
    let view = SplitChromeView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.setNotice(SplitToastSpec(id: 1, title: "Solara couldn't read its saved session", message: "Changes in this window won't be saved."))
    view.setToast(SplitToastSpec(id: 2, title: "Cannot Add New Pane"))
    view.layoutSubtreeIfNeeded()
    let sample = view.sample()
    let notice = try #require(sample["notice"] as? [String: Any])
    let toast = try #require(sample["toast"] as? [String: Any])
    #expect(notice["title"] as? String == "Solara couldn't read its saved session")
    #expect(toast["title"] as? String == "Cannot Add New Pane")
    view.setToast(nil)
    #expect((view.sample()["notice"] as? [String: Any])?["id"] as? Int == 1)
  }

  @Test func aFullscreenTabHidesTheDividers() throws {
    let view = SplitChromeView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.setChrome(theme: .fallback, fullscreenTab: "b")
    view.layoutSubtreeIfNeeded()
    #expect(view.panes["b"] == view.bounds)
    #expect(view.subviews.compactMap { $0 as? SplitDividerView }.isEmpty)
  }

  @Test func hitTestingPassesEverythingButTheDividers() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = SplitChromeView(windowId: "w1")
    view.frame = host.bounds
    host.addSubview(view)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    #expect(view.hitTest(CGPoint(x: 200, y: 300)) == nil)
    #expect(view.hitTest(CGPoint(x: 503, y: 300)) is SplitDividerView)
  }
}

@Suite(.serialized) @MainActor struct SplitPanesTests {
  @Test func eachLeafRegistersItsPageContainerUnderTheToolbar() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    let a = try #require(view.container("a"))
    #expect(TabSlots.shared.container(for: .pane("w1", "a")) === a)
    #expect(a.superview?.frame == CGRect(x: 0, y: 0, width: 500, height: 700))
    #expect(a.frame == CGRect(x: 0, y: 41, width: 500, height: 659))
    #expect(TabSlots.shared.container(for: .pane("w1", "b")) === view.container("b"))
  }

  @Test func leavingTheSplitRemovesOnlyItsOwnSlots() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    let other = NSView()
    TabSlots.shared.set(.pane("w1", "b"), container: other)
    var state = try splitState()
    state.splits = Table()
    view.update(state: state)
    view.layoutSubtreeIfNeeded()
    #expect(TabSlots.shared.container(for: .pane("w1", "a")) == nil)
    #expect(TabSlots.shared.container(for: .pane("w1", "b")) === other)
    TabSlots.shared.remove(.pane("w1", "b"), container: other)
  }

  @Test func eachLeafHostsItsOwnToolbarAboveThePage() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.setToolbars(["a": paneToolbar("a")])
    view.layoutSubtreeIfNeeded()
    let a = try #require(view.toolbar("a"))
    let b = try #require(view.toolbar("b"))
    #expect(a.frame == CGRect(x: 0, y: 0, width: 500, height: 41))
    #expect(!a.isHidden)
    #expect(a.state?.tabId == "a")
    #expect(b.isHidden)
    var clicked: [String] = []
    view.onToolbarClick = { tabId, click in clicked.append("\(tabId):\(click.id)") }
    a.onClick(ToolbarClick(id: "closePane", kind: .press))
    #expect(clicked == ["a:closePane"])
    view.setFullscreenTab("a")
    view.layoutSubtreeIfNeeded()
    #expect(a.isHidden)
    #expect(view.container("a")?.frame == CGRect(x: 0, y: 0, width: 1007, height: 700))
    #expect(view.container("a")?.superview?.layer?.cornerRadius == 0)
    #expect(view.container("a")?.superview?.layer?.backgroundColor == nil)
  }

  @Test func aFullscreenPaneCoversItsSiblingWhichStaysShown() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.setFullscreenTab("a")
    view.layoutSubtreeIfNeeded()
    let a = try #require(view.container("a")?.superview)
    let b = try #require(view.container("b")?.superview)
    #expect(!b.isHiddenOrHasHiddenAncestor)
    #expect(b.frame == CGRect(x: 507, y: 0, width: 500, height: 700))
    #expect(a.layer?.zPosition == 1 && b.layer?.zPosition == 0)
    #expect(view.hitTest(NSPoint(x: 900, y: 400)).map { $0.isDescendant(of: a) } == true)
    view.setFullscreenTab(nil)
    view.layoutSubtreeIfNeeded()
    #expect(a.layer?.zPosition == 0)
    #expect(view.hitTest(NSPoint(x: 900, y: 400)).map { $0.isDescendant(of: b) } == true)
  }

  @Test func aSingleTabCardTakesTheCardFillWhichASplitOrFullscreenDrops() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    let card = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 0.5)
    view.cardColor = card
    var styles: [CardStyle] = []
    view.onCardStyle = { styles.append($0) }
    var state = try splitState()
    state.splits = Table()
    state.tabs["a"]?.url = ""
    view.update(state: state)
    #expect(styles.last == CardStyle(fill: nil, radius: 10), "React Native draws the card while the pool doesn't serve pages")
    view.pagesPooled = true
    #expect(styles.last == CardStyle(fill: card, radius: 10))
    view.setFullscreenTab("a")
    #expect(styles.last == CardStyle(fill: nil, radius: 0, edge: false))
    view.setFullscreenTab(nil)
    view.update(state: try splitState())
    #expect(styles.last == CardStyle(fill: nil, radius: 10, edge: false), "each split pane draws its own edge")
    let count = styles.count
    view.update(state: try splitState())
    #expect(styles.count == count)
  }

  @Test func aNewTabLeafShowsTheEmptyStateOverItsPage() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    var state = try splitState()
    state.tabs["b"]?.url = ""
    view.update(state: state)
    view.layoutSubtreeIfNeeded()
    #expect(view.empty("a") == nil)
    let empty = try #require(view.empty("b"))
    #expect(empty.frame == view.container("b")?.frame)
    #expect(empty.superview === view.container("b")?.superview)
    var replaced: [String] = []
    view.onReplace = { tabId, other in replaced.append("\(tabId)>\(other)") }
    empty.onReplace?("a")
    #expect(replaced == ["b>a"])
    view.small = true
    #expect(view.empty("b") == nil)
    view.small = false
    state.tabs["b"]?.url = "https://b.example/"
    view.update(state: state)
    #expect(view.empty("b") == nil)
  }
}

private func paneToolbar(_ tabId: String) -> String {
  #"""
    {"tabId": "\#(tabId)", "height": 41, "bare": false, "focused": true, "accent": "#3478F6",
     "palette": {"text": "#000000", "secondary": "#00000080", "icon": "#000000D4", "iconDisabled": "#0000006E", "hover": "#0000000D", "pressed": "#0000001A", "pill": "#0000000A", "divider": "#0000001A"},
     "geometry": {"back": 12, "forward": 40, "reload": 68, "urlLeft": 100, "urlRight": 8},
     "left": [], "url": null, "right": [{"id": "closePane", "icon": "xmark"}], "rightInset": 8, "hairline": false}
    """#
}


@Suite struct SplitEmptyStateTests {
  @Test func suggestsRecentTabsOutsideTheSplitInTheSameProfile() throws {
    let text = #"""
      {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b", "c", "d", "e", "f"], "activeTabIds": {"p": "a"}}},
       "windowOrder": ["w1"],
       "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "", "title": ""},
                "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/", "title": "B", "lastActiveAt": 9},
                "c": {"id": "c", "windowId": "w1", "profileId": "p", "url": "https://www.c.example/x", "title": "C page", "lastActiveAt": 5},
                "d": {"id": "d", "windowId": "w1", "profileId": "q", "url": "https://d.example/", "title": "D", "lastActiveAt": 7},
                "e": {"id": "e", "windowId": "w1", "profileId": "p", "url": "https://e.example/", "title": "E", "lastActiveAt": 8},
                "f": {"id": "f", "windowId": "w1", "profileId": "p", "url": "", "title": "", "lastActiveAt": 10}},
       "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": [0.5, 0.5]}}}
      """#
    let state = try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
    let list = SplitEmptyState.suggestions(state, tabId: "a")
    #expect(list.map(\.tabId) == ["e", "c"])
    #expect(list.last?.label == "c.example")
    #expect(list.last?.detail == "C page")
  }
}

@Suite(.serialized) @MainActor struct SplitDropZoneTests {
  @Test func candidatesAreTheOtherPanesOrTheRecentTabForASinglePage() throws {
    var state = try splitState()
    let panes = ["a": CGRect(x: 0, y: 0, width: 500, height: 700), "b": CGRect(x: 507, y: 0, width: 500, height: 700)]
    #expect(SplitDropZone.candidates(state, windowId: "w1", dragging: "a", panes: panes).map(\.tabId) == ["b"])
    state.splits = Table()
    let single = ["a": CGRect(x: 0, y: 0, width: 1007, height: 700)]
    let fallback = SplitDropZone.candidates(state, windowId: "w1", dragging: "a", panes: single)
    #expect(fallback.map(\.tabId) == ["b"])
    #expect(fallback.first?.rect == single["a"])
  }

  @Test func aSplitAtItsLimitTakesNoOutsideTab() throws {
    let text = #"""
      {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b", "c", "d"], "activeTabIds": {"p": "a"}}},
       "windowOrder": ["w1"],
       "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/"},
                "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/"},
                "c": {"id": "c", "windowId": "w1", "profileId": "p", "url": "https://c.example/"},
                "d": {"id": "d", "windowId": "w1", "profileId": "p", "url": "https://d.example/"}},
       "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b", "c"], "orientation": "horizontal", "sizes": [0.34, 0.33, 0.33]}}}
      """#
    let state = try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
    let panes = ["a": CGRect.zero, "b": CGRect.zero, "c": CGRect.zero]
    #expect(SplitDropZone.candidates(state, windowId: "w1", dragging: "d", panes: panes).isEmpty)
    #expect(SplitDropZone.candidates(state, windowId: "w1", dragging: "a", panes: panes).map(\.tabId) == ["b", "c"])
  }

  @Test func dropRunsTheSplitOnlyForASplitAim() {
    let zone = SplitDropZone(windowId: "w1", chrome: SplitChromeView(windowId: "w1"))
    var drops: [String] = []
    zone.onDrop = { tabId, target, side in drops.append("\(tabId)>\(target):\(side.rawValue)") }
    let session = TabDragSession.begin(tabIds: ["a"], from: "w1")
    #expect(!zone.drop(session, .page))
    #expect(zone.drop(session, .split(tabId: "b", side: .left)))
    #expect(!zone.drop(session, .split(tabId: "a", side: .left)))
    #expect(drops == ["a>b:left"])
    session.cancel()
  }

  @Test func aPointCoveredByThePeekingSidebarIsNotThePage() throws {
    let chrome = SplitChromeView(windowId: "w1")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1007, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = chrome
    let state = try splitState()
    chrome.update(state: state)
    chrome.layoutSubtreeIfNeeded()
    let zone = SplitDropZone(windowId: "w1", chrome: chrome)
    zone.state = { state }
    let session = TabDragSession.begin(tabIds: ["a"], from: "w1")
    defer { session.cancel() }
    #expect(zone.aim(session, at: CGPoint(x: 700, y: 350)) == .page)
    zone.covered = { $0.x < 750 }
    #expect(zone.aim(session, at: CGPoint(x: 700, y: 350)) == nil)
    #expect(zone.aim(session, at: CGPoint(x: 800, y: 350)) == .page)
  }
}
