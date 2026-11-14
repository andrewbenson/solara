import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func overlayState(split: Bool) throws -> BrowserState {
  let splits = split ? #", "splits": {"s1": {"id": "s1", "windowId": "w9", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": [0.5, 0.5]}}"# : ""
  let text = #"""
    {"windows": {"w9": {"id": "w9", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "a"}}},
     "windowOrder": ["w9"],
     "tabs": {"a": {"id": "a", "windowId": "w9", "profileId": "p", "url": "https://a.example/"},
              "b": {"id": "b", "windowId": "w9", "profileId": "p", "url": "https://b.example/"}}\#(splits)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private final class PostedTabs: @unchecked Sendable {
  var tabs: [String] = []
}

@Suite(.serialized) @MainActor struct PaneOverlaysTests {
  @Test func eachVisibleTabGetsASlotOverItsPageArea() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = PaneOverlaysView(windowId: "w9")
    view.frame = host.bounds
    host.addSubview(view)
    view.update(state: try overlayState(split: true))
    view.pageTops = ["a": 41, "b": 41]
    view.layoutSubtreeIfNeeded()
    let a = try #require(PaneOverlays.shared.container(windowId: "w9", tabId: "a", layer: .native))
    let rn = try #require(PaneOverlays.shared.container(windowId: "w9", tabId: "a", layer: .rn))
    #expect(a.superview?.frame == CGRect(x: 0, y: 41, width: 500, height: 659))
    #expect(a.superview === rn.superview)
    #expect(a.superview?.subviews.last === a)
    #expect(PaneOverlays.shared.layer(windowId: "w9") === view)
    #expect(view.hitTest(NSPoint(x: 10, y: 100)) == nil)
    view.update(state: try overlayState(split: false))
    view.pageTops = ["a": 71]
    view.layoutSubtreeIfNeeded()
    #expect(PaneOverlays.shared.container(windowId: "w9", tabId: "b", layer: .native) == nil)
    #expect(a.superview?.frame == CGRect(x: 0, y: 71, width: 1007, height: 629))
    view.removeFromSuperview()
    #expect(PaneOverlays.shared.tabIds(in: "w9").isEmpty)
    #expect(PaneOverlays.shared.layer(windowId: "w9") == nil)
  }

  @Test func appliedPaneFramesRemainDistinctFromPageSlots() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = PaneOverlaysView(windowId: "w9")
    view.frame = host.bounds
    host.addSubview(view)
    defer { view.removeFromSuperview() }
    view.update(state: try overlayState(split: true))
    view.pageTops = ["a": 41, "b": 41]
    view.layoutSubtreeIfNeeded()
    #expect(view.paneFrames["a"] == CGRect(x: 0, y: 0, width: 500, height: 700))
    let slot = try #require(view.container("a", layer: .rn))
    #expect(slot.convert(slot.bounds, to: view).minY == 41)
    view.pageTops = ["a": 71, "b": 41]
    view.layoutSubtreeIfNeeded()
    #expect(view.paneFrames["a"]?.minY == 0)
    #expect(slot.convert(slot.bounds, to: view).minY == 71)
  }

  @Test func aHiddenTabKeepsItsSlotWhileAnRnRootIsInIt() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = PaneOverlaysView(windowId: "w9")
    view.frame = host.bounds
    host.addSubview(view)
    view.update(state: try overlayState(split: true))
    view.layoutSubtreeIfNeeded()
    let rn = try #require(PaneOverlays.shared.container(windowId: "w9", tabId: "b", layer: .rn))
    let root = NSView()
    rn.addSubview(root)
    let posted = PostedTabs()
    let observer = NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: nil, queue: nil) { note in
      if note.userInfo?["windowId"] as? String == "w9", let tabId = note.userInfo?["tabId"] as? String { posted.tabs.append(tabId) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    view.update(state: try overlayState(split: false))
    view.layoutSubtreeIfNeeded()
    #expect(PaneOverlays.shared.container(windowId: "w9", tabId: "b", layer: .rn) === rn)
    #expect(rn.superview?.isHidden == true)
    #expect(posted.tabs.contains("b"))
    root.removeFromSuperview()
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #expect(PaneOverlays.shared.container(windowId: "w9", tabId: "b", layer: .rn) == nil)
    view.removeFromSuperview()
  }

  @Test func aFullscreenTabHidesTheOtherPanesSlots() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = PaneOverlaysView(windowId: "w9")
    view.frame = host.bounds
    host.addSubview(view)
    view.update(state: try overlayState(split: true))
    view.layoutSubtreeIfNeeded()
    let a = try #require(PaneOverlays.shared.container(windowId: "w9", tabId: "a", layer: .rn)?.superview)
    let b = try #require(PaneOverlays.shared.container(windowId: "w9", tabId: "b", layer: .rn)?.superview)
    view.setFullscreenTab("a")
    view.layoutSubtreeIfNeeded()
    #expect(a.isHidden == false)
    #expect(a.frame == host.bounds)
    #expect(b.isHidden == true)
    view.setFullscreenTab(nil)
    view.layoutSubtreeIfNeeded()
    #expect(b.isHidden == false)
    view.removeFromSuperview()
  }

  @Test func hidingTheLayerOrItsCardTellsEverySlot() throws {
    let card = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = PaneOverlaysView(windowId: "w9")
    view.frame = card.bounds
    card.addSubview(view)
    view.update(state: try overlayState(split: true))
    view.layoutSubtreeIfNeeded()
    let posted = PostedTabs()
    let observer = NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: nil, queue: nil) { note in
      if note.userInfo?["windowId"] as? String == "w9", let tabId = note.userInfo?["tabId"] as? String { posted.tabs.append(tabId) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    card.isHidden = true
    #expect(Set(posted.tabs) == ["a", "b"])
    #expect(PaneOverlays.shared.container(windowId: "w9", tabId: "a", layer: .rn)?.isHiddenOrHasHiddenAncestor == true)
    posted.tabs = []
    card.isHidden = false
    #expect(Set(posted.tabs) == ["a", "b"])
    posted.tabs = []
    view.isHidden = true
    #expect(Set(posted.tabs) == ["a", "b"])
    view.isHidden = false
    view.removeFromSuperview()
  }
}
