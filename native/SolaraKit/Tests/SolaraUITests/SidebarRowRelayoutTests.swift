import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarRowRelayoutTests {
  private func state(active: String, groupName: String = "Work", splits: Bool = false, pinnedRow: Bool = false) throws -> BrowserState {
    let ids = (pinnedRow ? ["p1"] : []) + ["t1", "t2", "t3", "t4", "t5"]
    var tabs: [String: Any] = [:]
    for id in ids { tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://\(id).example/", "title": id] }
    if pinnedRow { tabs["p1"] = ["id": "p1", "windowId": "w", "profileId": "p", "url": "https://p1.example/", "title": "p1", "pinned": true, "pinnedAsRow": true, "pinnedUrl": "https://p1.example/"] }
    var root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ids, "activeTabIds": ["p": active]]],
      "groups": ["g1": ["id": "g1", "windowId": "w", "name": groupName, "tabIds": ["t4", "t5"], "collapsed": false]],
    ]
    if splits {
      root["splits"] = ["s1": ["id": "s1", "windowId": "w", "tabIds": ["t2", "t3"], "orientation": "horizontal", "sizes": [0.5, 0.5]]]
    }
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func mounted(_ state: BrowserState, _ host: SidebarHostState) -> (NSWindow, SidebarView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
    window.contentView = sidebar
    sidebar.update(state: state, host: host)
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
  }

  @Test func aSplitRowInsetsItsPanesAgainWhenItBecomesActive() throws {
    let host = SidebarHostState(profileId: "p")
    let (window, sidebar) = mounted(try state(active: "t1", splits: true), host)
    _ = window
    let row = try #require(sidebar.views["s:s1"])
    #expect(all(SplitPaneView.self, in: row).map(\.frame.minX).min() == 3)
    sidebar.update(state: try state(active: "t2", splits: true), host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(all(SplitPaneView.self, in: row).map(\.frame.minX).min() == 2)
  }

  @Test func aGroupHeaderFitsItsTitleAgainWhenTheNameChanges() throws {
    let host = SidebarHostState(profileId: "p")
    let (window, sidebar) = mounted(try state(active: "t1"), host)
    _ = window
    let row = try #require(sidebar.views["gh:g1"])
    let before = try #require(all(FadeLabel.self, in: row).first).frame.width
    sidebar.update(state: try state(active: "t1", groupName: "A much longer group name"), host: host)
    sidebar.layoutSubtreeIfNeeded()
    let after = try #require(all(FadeLabel.self, in: row).first).frame.width
    #expect(after > before)
  }

  @Test func theDividerPlacesTidyWhenItAppearsBesideClear() throws {
    var host = SidebarHostState(profileId: "p")
    host.clear = true
    let (window, sidebar) = mounted(try state(active: "t1", pinnedRow: true), host)
    _ = window
    let row = try #require(sidebar.views["divider"])
    host.tidy = true
    sidebar.update(state: try state(active: "t1", pinnedRow: true), host: host)
    sidebar.layoutSubtreeIfNeeded()
    let buttons = all(DividerButton.self, in: row)
    #expect(buttons.count == 2)
    #expect(buttons.allSatisfy { $0.frame.width > 0 })
    #expect(Set(buttons.map(\.frame.minX)).count == 2)
  }
}
