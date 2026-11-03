import AppKit
import SolaraLive
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
private final class RailDragBridge: SidebarDragBridge {
  var drops: [(ids: [String], drop: JSONValue)] = []
  var endings: [Bool] = []
  var captures: [Bool] = []
  var deferred = false
  var completion: (@MainActor (Bool) -> Void)?

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {}
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {}
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    endings.append(commit)
    if deferred { completion = done } else { done(false) }
  }
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) { drops.append((ids, drop)) }
  func escapeCapture(_ on: Bool) { captures.append(on) }
  func haptic() {}
  func closeFolderPanel(windowId: String) {}
  func changed(windowId: String) {}
}

@MainActor
@Suite(.serialized) struct SidebarRailInteractionTests {
  private func state() throws -> BrowserState {
    let text = #"{"profileOrder":["p"],"windowOrder":["w"],"windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b","c"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"Loose"},"b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"Member"},"c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.example/","title":"Other"}},"groups":{"g":{"id":"g","windowId":"w","profileId":"p","name":"Work","tabIds":["b"],"collapsed":false}}}"#
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func mounted(width: CGFloat) throws -> (NSWindow, SidebarView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
    window.contentView?.addSubview(sidebar)
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  @Test func droppingALooseTabOnARailGroupAddsItToTheGroup() throws {
    let bridge = RailDragBridge()
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
    _ = window
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:a"]?.frame)
    let target = try #require(controller.items["g:g"]?.headerFrame)
    controller.begin("t:a", CGPoint(x: source.midX, y: source.midY))
    controller.move(CGPoint(x: target.midX, y: target.midY))
    #expect(controller.marks.dropInto == "g")
    controller.end(commit: true)
    let drop = try #require(bridge.drops.first)
    #expect(drop.ids == ["a"])
    #expect(drop.drop.object?["placement"]?.object?["groupId"]?.string == "g")
  }

  @Test func aLiveFolderRailIconCanBeginADrag() throws {
    var live = LiveState()
    live.folders["f"] = LiveFolder(id: "f", profileId: "p", kind: .pullRequests, name: "Reviews", sources: [.github], createdAt: 0)
    live.folderOrder = ["f"]
    SidebarLiveFeed.shared.apply(live)
    defer { SidebarLiveFeed.shared.apply(LiveState()) }
    let (window, sidebar) = try mounted(width: CGFloat(SidebarRail.width))
    _ = window
    let controller = SidebarDragController.of(sidebar)
    let row = try #require(sidebar.views[SidebarLiveMetrics.headerKey("f")])
    let frame = try #require(controller.windowRect(row))
    controller.begin("lf:f", CGPoint(x: frame.midX, y: frame.midY))
    #expect(controller.active)
    #expect(controller.items["lf:f"]?.frame == frame)
    #expect(controller.items["lf:f"]?.liveFolderId == "f")
    controller.end(commit: false)
  }

  @Test func changingRailModeCancelsTheDragBeforeRemovingItsRows() throws {
    let bridge = RailDragBridge()
    bridge.deferred = true
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    let (window, sidebar) = try mounted(width: 240)
    _ = window
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:a"]?.frame)
    controller.begin("t:a", CGPoint(x: source.midX, y: source.midY))
    #expect(controller.active)
    sidebar.setFrameSize(NSSize(width: CGFloat(SidebarRail.width), height: 600))
    sidebar.layoutSubtreeIfNeeded()
    #expect(!controller.active)
    #expect(bridge.endings == [false])
    #expect(bridge.captures.last == false)
    #expect(!sidebar.subviews.contains { $0 is SidebarDragGhostView })
    bridge.completion?(false)
    #expect(!controller.active)
    #expect(bridge.drops.isEmpty)
    #expect(!sidebar.subviews.contains { $0 is SidebarDragGhostView })
    controller.end(commit: false)
  }

  @Test func aLateDragCompletionCannotAffectTheNewModeOrANewDrag() throws {
    let bridge = RailDragBridge()
    bridge.deferred = true
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    let (window, sidebar) = try mounted(width: 240)
    _ = window
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:a"]?.frame)
    let target = try #require(controller.items["g:g"]?.headerFrame)
    controller.begin("t:a", CGPoint(x: source.midX, y: source.midY))
    controller.move(CGPoint(x: target.midX, y: target.midY))
    controller.end(commit: true)
    let previousCompletion = try #require(bridge.completion)
    sidebar.setFrameSize(NSSize(width: CGFloat(SidebarRail.width), height: 600))
    sidebar.layoutSubtreeIfNeeded()
    #expect(!controller.active)
    controller.collect()
    let next = try #require(controller.items["t:c"]?.frame)
    controller.begin("t:c", CGPoint(x: next.midX, y: next.midY))
    #expect(controller.active)
    #expect(controller.marks.sources == ["t:c"])
    previousCompletion(false)
    #expect(controller.active)
    #expect(controller.marks.sources == ["t:c"])
    #expect(bridge.drops.isEmpty)
    bridge.deferred = false
    controller.end(commit: false)
  }

  @Test func changingRailModeSendsHoverLeaveForTheLastTarget() throws {
    let (window, sidebar) = try mounted(width: 240)
    _ = window
    var hover: [String?] = []
    sidebar.onAction = { action in
      if case .hover(_, let id) = action { hover.append(id) }
    }
    let row = try #require(sidebar.views["t:a"] as? SidebarRowView)
    sidebar.pointerEntered(row)
    #expect(hover == ["a"])
    sidebar.setFrameSize(NSSize(width: CGFloat(SidebarRail.width), height: 600))
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.hoverKey == nil)
    #expect(hover == ["a", nil])
    sidebar.pointerExited(row)
    #expect(hover == ["a", nil])
  }
}
