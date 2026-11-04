import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
private final class RailPinDragBridge: SidebarDragBridge {
  var drops: [(ids: [String], drop: JSONValue)] = []

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {}
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {}
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) { done(false) }
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) { drops.append((ids, drop)) }
  func escapeCapture(_ on: Bool) {}
  func haptic() {}
  func closeFolderPanel(windowId: String) {}
  func changed(windowId: String) {}
}

@MainActor
@Suite(.serialized) struct SidebarRailDragMetricsTests {
  @Test func railPinSlotsFollowTheThirtyTwoPointPitchInOneColumn() {
    let grid = CGRect(x: 6, y: 32, width: 72, height: 126)
    for (y, expected) in [(47.0, 0), (79, 1), (111, 2), (143, 3)] {
      #expect(PinZone.slot(grid: grid, count: 4, x: 42, y: CGFloat(y), balanced: false, rail: true) == expected)
      #expect(PinZone.slot(grid: grid, count: 4, x: 42, y: CGFloat(y), balanced: true, rail: true) == expected)
    }
  }

  @Test func railPinHeightTracksTheNumberOfThirtyPointTiles() {
    #expect(PinZone.height(1, 72, false, rail: true) == 30)
    #expect(PinZone.height(4, 72, false, rail: true) == 126)
    #expect(PinZone.height(4, 72, true, rail: true) == 126)
  }

  @Test(arguments: [true, false]) func draggingTheLastPinBeforeTheFirstUsesTheRailPitch(fixed: Bool) throws {
    let state = try BrowserState(stateJSON: JSONValue.parse(#"""
      {"profileOrder":["p"],"windowOrder":["w"],
       "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b","c","d"],"activeTabIds":{"p":"a"}}},
       "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","pinned":true},
               "b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","pinned":true},
               "c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.example/","pinned":true},
               "d":{"id":"d","windowId":"w","profileId":"p","url":"https://d.example/"}}}
      """#).object ?? [:])
    let height: CGFloat = fixed ? 600 : 240
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 84, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    defer { window.close() }
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 84, height: height)
    window.contentView?.addSubview(sidebar)
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.pageLayout.tilesFixed == fixed)

    let bridge = RailPinDragBridge()
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:c"]?.frame)
    let target = try #require(controller.items["t:a"]?.frame)
    let middle = try #require(controller.items["t:b"]?.frame)
    #expect(middle.minY - target.minY == 32)
    controller.begin("t:c", CGPoint(x: source.midX, y: source.midY))
    controller.move(CGPoint(x: target.minX + 2, y: target.minY + target.height / 4))
    #expect(controller.marks.pins)
    #expect(controller.gapKey == "t:a")
    #expect(controller.pitch == 32)
    controller.end(commit: true)

    let drop = try #require(bridge.drops.first)
    #expect(drop.ids == ["c"])
    #expect(drop.drop["placement"]?["beforeId"]?.string == "a")
    #expect(drop.drop["placement"]?["pinned"]?.truthy == true)
    #expect(drop.drop["placement"]?["row"]?.truthy == false)
  }
}
