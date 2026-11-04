import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
private final class PopoverDragBridge: SidebarDragBridge {
  var drops: [(ids: [String], drop: JSONValue)] = []
  var endings: [Bool] = []
  var began: [[String]] = []
  var deferred = false
  var completion: (@MainActor (Bool) -> Void)?

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) { began.append(tabIds) }
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {}
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    endings.append(commit)
    if deferred { completion = done } else { done(false) }
  }
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) { drops.append((ids, drop)) }
  func escapeCapture(_ on: Bool) {}
  func haptic() {}
  func closeFolderPanel(windowId: String) {}
  func changed(windowId: String) {}
}

@MainActor
@Suite(.serialized) struct SidebarRailPopoverDragTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"""
      {"profileOrder":["p"],"windowOrder":["w"],
       "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b","d","c"],"activeTabIds":{"p":"a"}}},
       "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"Loose"},
               "b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"Member"},
               "d":{"id":"d","windowId":"w","profileId":"p","url":"https://d.example/","title":"Second"},
               "c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.example/","title":"Other"}},
       "groups":{"g":{"id":"g","windowId":"w","profileId":"p","name":"Work","tabIds":["b","d"],"collapsed":false}}}
      """#).object ?? [:])
  }

  private func mounted(width: CGFloat, selection: [String] = []) throws -> (NSWindow, SidebarView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 400, y: 200, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    window.orderBack(nil)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
    window.contentView?.addSubview(sidebar)
    var host = SidebarHostState(profileId: "p")
    host.selection = selection
    sidebar.update(state: try state(), host: host)
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func withBridge(_ run: (PopoverDragBridge) throws -> Void) rethrows {
    let bridge = PopoverDragBridge()
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    try run(bridge)
  }

  private func railGroup(_ sidebar: SidebarView) throws -> RailGroupView {
    try #require(sidebar.views.values.compactMap { $0 as? RailGroupView }.first)
  }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  private func escape(in window: NSWindow? = nil) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
  }

  private func below(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.maxY + 6) }

  @Test func aGroupMemberDraggedOutOfTheRailPopoverBecomesTheDragSource() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = SidebarDragController.of(sidebar)
      let group = try #require(controller.windowRect(try railGroup(sidebar)))
      controller.popoverDrag(tabId: "b", groupId: "g", size: group.size, at: CGPoint(x: group.midX, y: group.midY))
      #expect(controller.active)
      #expect(controller.followsPopoverDrag)
      #expect(controller.marks.sources == ["t:b"])
      #expect(controller.items["t:b"]?.parentGroup == "g")
      #expect(bridge.began == [["b"]])
      #expect(sidebar.subviews.contains { $0 is SidebarDragGhostView })
      controller.end(commit: false)
      #expect(!controller.followsPopoverDrag)
    }
  }

  @Test func droppingAPopoverMemberBelowTheLastTabMatchesTheWideSidebarDrop() throws {
    var wide: (ids: [String], drop: JSONValue)?
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: 240)
      defer { window.close() }
      let controller = SidebarDragController.of(sidebar)
      controller.collect()
      let source = try #require(controller.items["t:b"]?.frame)
      let last = try #require(controller.items["t:c"]?.frame)
      controller.begin("t:b", CGPoint(x: source.midX, y: source.midY))
      controller.move(below(last))
      controller.end(commit: true)
      wide = bridge.drops.first
    }
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = SidebarDragController.of(sidebar)
      controller.collect()
      let group = try #require(controller.windowRect(try railGroup(sidebar)))
      let last = try #require(controller.items["t:c"]?.frame)
      controller.popoverDrag(tabId: "b", groupId: "g", size: group.size, at: CGPoint(x: group.midX, y: group.midY))
      #expect(controller.handlePopoverEvent(try mouse(.leftMouseDragged, at: NSPoint(x: last.midX, y: window.contentView!.bounds.height - below(last).y), in: window)))
      #expect(controller.handlePopoverEvent(try mouse(.leftMouseUp, at: NSPoint(x: last.midX, y: window.contentView!.bounds.height - below(last).y), in: window)))
      let rail = try #require(bridge.drops.first)
      let expected = try #require(wide)
      #expect(rail.ids == ["b"])
      #expect(rail.ids == expected.ids)
      #expect(rail.drop.object?["placement"] == expected.drop.object?["placement"])
      #expect(rail.drop.object?["placement"]?.object?["groupId"]?.string == nil)
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
    }
  }

  @Test func escapeCancelsAPopoverDragAndStopsFollowingTheMouse() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = SidebarDragController.of(sidebar)
      let group = try #require(controller.windowRect(try railGroup(sidebar)))
      controller.popoverDrag(tabId: "b", groupId: "g", size: group.size, at: CGPoint(x: group.midX, y: group.midY))
      #expect(controller.handlePopoverEvent(try escape()))
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
      #expect(bridge.endings == [false])
      #expect(bridge.drops.isEmpty)
      #expect(!controller.handlePopoverEvent(try mouse(.leftMouseUp, at: NSPoint(x: 40, y: 40), in: window)))
      #expect(bridge.drops.isEmpty)
    }
  }

  @Test func leavingRailModeMidDragCancelsAndAStaleMonitorIgnoresLaterEvents() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = SidebarDragController.of(sidebar)
      let group = try #require(controller.windowRect(try railGroup(sidebar)))
      controller.popoverDrag(tabId: "b", groupId: "g", size: group.size, at: CGPoint(x: group.midX, y: group.midY))
      sidebar.setFrameSize(NSSize(width: 240, height: 600))
      sidebar.layoutSubtreeIfNeeded()
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
      controller.collect()
      let next = try #require(controller.items["t:c"]?.frame)
      controller.begin("t:c", CGPoint(x: next.midX, y: next.midY))
      #expect(!controller.handlePopoverEvent(try mouse(.leftMouseUp, at: NSPoint(x: 40, y: 40), in: window)))
      #expect(controller.active)
      #expect(controller.marks.sources == ["t:c"])
      #expect(bridge.drops.isEmpty)
      controller.end(commit: false)
    }
  }

  @Test func draggingARowInTheGroupPopoverClosesItAndStartsTheSidebarDrag() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let icon = try railGroup(sidebar)
      icon.click(SidebarClickMods([]), count: 1)
      defer { icon.popover?.close() }
      let popover = try #require(icon.popover?.popover)
      #expect(popover.isShown)
      let content = try #require(popover.contentViewController?.view)
      let row = try #require(descendants(content).compactMap { $0 as? SidebarRailPopoverRowView }.first { $0.tabId == "b" })
      let panel = try #require(row.window)
      let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
      row.mouseDown(with: try mouse(.leftMouseDown, at: start, in: panel))
      row.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y), in: panel))
      #expect(popover.isShown)
      #expect(!SidebarDragController.of(sidebar).active)
      row.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: start.x - 40, y: start.y), in: panel))
      #expect(!popover.isShown)
      let controller = SidebarDragController.of(sidebar)
      #expect(controller.active)
      #expect(controller.followsPopoverDrag)
      #expect(controller.marks.sources == ["t:b"])
      #expect(bridge.began == [["b"]])
      controller.end(commit: false)
      #expect(!controller.followsPopoverDrag)
    }
  }

  private func startPopoverDrag(_ sidebar: SidebarView, tabId: String = "b") throws -> SidebarDragController {
    let controller = SidebarDragController.of(sidebar)
    let group = try #require(controller.windowRect(try railGroup(sidebar)))
    controller.popoverDrag(tabId: tabId, groupId: "g", size: group.size, at: CGPoint(x: group.midX, y: group.midY))
    return controller
  }

  @Test(arguments: [["a", "b"], ["b", "d"]]) func aPopoverDragMovesOnlyTheGrabbedTabWhateverIsSelected(_ selection: [String]) throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width), selection: selection)
      defer { window.close() }
      let controller = try startPopoverDrag(sidebar)
      #expect(controller.active)
      #expect(controller.followsPopoverDrag)
      #expect(controller.marks.sources == ["t:b"])
      #expect(bridge.began == [["b"]])
      controller.end(commit: false)
    }
  }

  @Test func resigningActiveCancelsAPopoverDrag() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let applicationNotifications = NotificationCenter()
      SidebarDragController.of(sidebar).applicationNotifications = applicationNotifications
      let controller = try startPopoverDrag(sidebar)
      applicationNotifications.post(name: NSApplication.didResignActiveNotification, object: NSApp)
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
      #expect(bridge.endings == [false])
      #expect(bridge.drops.isEmpty)
      #expect(!controller.handlePopoverEvent(try mouse(.leftMouseUp, at: NSPoint(x: 40, y: 40), in: window)))
      #expect(bridge.drops.isEmpty)
    }
  }

  @Test func endingAPopoverDragStopsFollowingBeforeTheBridgeAnswers() throws {
    try withBridge { bridge in
      bridge.deferred = true
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = try startPopoverDrag(sidebar)
      SidebarDragHub.escape()
      #expect(!controller.followsPopoverDrag)
      #expect(!controller.handlePopoverEvent(try escape(in: window)))
      bridge.completion?(false)
      #expect(!controller.active)
      #expect(bridge.drops.isEmpty)
    }
  }

  @Test func escapeInAnotherWindowCancelsTheDragButReachesThatWindow() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
      other.isReleasedWhenClosed = false
      defer { other.close() }
      let controller = try startPopoverDrag(sidebar)
      #expect(!controller.handlePopoverEvent(try escape(in: other)))
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
      #expect(bridge.endings == [false])
    }
  }

  @Test func aSidebarLeavingItsWindowCancelsOnTheNextEvent() throws {
    try withBridge { bridge in
      let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
      defer { window.close() }
      let controller = try startPopoverDrag(sidebar)
      sidebar.removeFromSuperview()
      #expect(!controller.handlePopoverEvent(try mouse(.leftMouseUp, at: NSPoint(x: 40, y: 40), in: window)))
      #expect(!controller.active)
      #expect(!controller.followsPopoverDrag)
      #expect(bridge.drops.isEmpty)
    }
  }
}
