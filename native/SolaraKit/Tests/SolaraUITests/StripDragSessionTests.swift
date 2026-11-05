import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
private final class StripSessionBridge: StripDragBridge {
  var moves: [CGPoint] = []
  var ends: [(commit: Bool, at: CGPoint?)] = []
  var drops: [JSONValue] = []

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {}
  func dragPicture(windowId: String, rect: CGRect, grab: CGPoint) {}
  func dragMoved(windowId: String, at: CGPoint, lifted: Bool, dx: CGFloat) { moves.append(at) }
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    ends.append((commit, moves.last))
    done(false)
  }
  func drop(ids: [String], drop: JSONValue) -> Bool {
    drops.append(drop)
    return true
  }
  func land(ids: [String], from source: String, in windowId: String, beforeId: String?) -> Bool { false }
}

@MainActor
@Suite(.serialized) struct StripDragSessionTests {
  private func page(_ bridge: StripSessionBridge) throws -> StripPageView {
    let state = try BrowserState(stateJSON: JSONValue.parse(#"""
      {"profileOrder":["p"],"windowOrder":["w"],
       "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b","c"],"activeTabIds":{"p":"a"}}},
       "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"},
               "b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"B"},
               "c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.example/","title":"C"}}}
      """#).object ?? [:])
    let page = StripPageView(windowId: "w", profileId: "p", favicons: SidebarFavicons())
    page.frame = CGRect(x: 0, y: 0, width: 900, height: 42)
    page.pageWidth = 900
    page.dragBridge = bridge
    page.update(state: state, host: StripHostState(profileId: "p"), current: true)
    page.layoutSubtreeIfNeeded()
    return page
  }

  private func chip(in view: NSView) throws -> StripTabChip {
    if let chip = view as? StripTabChip, chip.tabId == "a" { return chip }
    for child in view.subviews {
      if let chip = try? chip(in: child) { return chip }
    }
    throw NSError(domain: "StripDragSessionTests", code: 1)
  }

  private func mouse(_ type: NSEvent.EventType, _ at: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: at.x, y: -at.y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }

  private func begin(_ page: StripPageView) throws -> StripTabChip {
    let chip = try chip(in: page)
    page.drag.press(chip, try mouse(.leftMouseDown, CGPoint(x: 70, y: 21)))
    #expect(page.drag.dragged(chip, try mouse(.leftMouseDragged, CGPoint(x: 80, y: 21))))
    #expect(page.drag.owns)
    return chip
  }

  @Test func mouseUpRefreshesTheSessionPointerBeforeEnding() throws {
    let bridge = StripSessionBridge()
    let page = try page(bridge)
    let chip = try begin(page)
    #expect(page.drag.dragged(chip, try mouse(.leftMouseDragged, CGPoint(x: 200, y: 400))))
    #expect(page.drag.released(chip, try mouse(.leftMouseUp, CGPoint(x: 500, y: 21))))
    #expect(bridge.ends.count == 1)
    #expect(bridge.ends.first?.commit == true)
    #expect(bridge.ends.first?.at == CGPoint(x: 500, y: 21))
    page.drag.cancel()
  }

  @Test(arguments: [false, true]) func reorderUsesTheMouseUpHorizontalPosition(lastMoveIsOverAnotherTab: Bool) throws {
    let bridge = StripSessionBridge()
    let page = try page(bridge)
    let chip = try begin(page)
    let first = try #require(page.frameOf("t:a"))
    let second = try #require(page.frameOf("t:b"))
    let lastX: CGFloat = lastMoveIsOverAnotherTab ? 80 + second.midX - first.midX : 90
    #expect(page.drag.dragged(chip, try mouse(.leftMouseDragged, CGPoint(x: lastX, y: 21))))
    #expect(page.drag.onto == (lastMoveIsOverAnotherTab ? .tab("b") : nil))
    #expect(page.drag.released(chip, try mouse(.leftMouseUp, CGPoint(x: 800, y: 21))))
    let now = StripTicker.now
    for frame in 1...120 { page.drag.tick(now + Double(frame) / 60) }
    #expect(bridge.drops.count == 1)
    #expect(bridge.drops.first?.object?["type"]?.string == "tabs")
    #expect(bridge.drops.first?.object?["placement"]?.object?["beforeId"] == .null)
    #expect(!page.drag.active)
  }
}
