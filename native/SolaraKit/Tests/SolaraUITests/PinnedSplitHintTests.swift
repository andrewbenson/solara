import AppKit
import SolaraModel
import SolaraStore
import XCTest
@testable import SolaraUI

final class PinnedSplitHintTests: XCTestCase {
  @MainActor
  func testStripPinnedSplitShowsItsShortcutOnTheSelectedPane() {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b", "last"]
    window.activeTabIds[profile] = "last"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    for (index, id) in window.tabIds.enumerated() {
      var tab = Tab(id: id, windowId: "w", profileId: profile, url: "https://\(id).example/", now: Double(index))
      if id != "last" {
        tab.pinned = true
        tab.pinnedAsRow = true
      }
      state.tabs[id] = tab
    }
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let feed = TabNumberHintFeed.shared
    let target = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsChanged"), object: target, userInfo: ["visible": true, "bindings": ["selectTab:1": "⌃K"]])
    defer { feed.cancel() }
    let host = StripHostState(profileId: profile)
    let favicons = SidebarFavicons()
    let recent = StripContext(state: state, host: host, windowId: "w", favicons: favicons, previous: nil)
    let recentCell = StripPinnedCell()
    recentCell.update("b", members: [], recent)
    XCTAssertEqual(recentCell.numberHint.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, "⌃K")
    state.windows["w"]?.activeTabIds[profile] = "a"
    let focused = StripContext(state: state, host: host, windowId: "w", favicons: favicons, previous: recent)
    let focusedCell = StripPinnedCell()
    focusedCell.update("a", members: [], focused)
    XCTAssertEqual(focusedCell.numberHint.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, "⌃K")
  }
}
