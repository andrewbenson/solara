import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailCloseHoverTests {
  @Test(arguments: [false, true]) func theWholeCornerBadgeKeepsItsTabHoveredAndReceivesClicks(_ pinned: Bool) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    defer { window.close() }
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 42, height: 600)
    window.contentView?.addSubview(sidebar)
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"First","pinned":\#(pinned)},"b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"Second","pinned":\#(pinned)}}}"#).object ?? [:])
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    let key = pinned ? "tile:b" : "t:b"
    let row = try #require(sidebar.views[key] as? RailTabView)
    sidebar.pointerEntered(row)
    sidebar.layoutSubtreeIfNeeded()
    let close = try #require(row.subviews.compactMap { $0 as? SidebarIconButton }.first)
    let local = NSPoint(x: close.frame.midX, y: -3)
    let windowPoint = row.convert(local, to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    sidebar.mouseMoved(with: event)
    #expect(sidebar.hoverKey == key)
    #expect(row.hovered)
    let hit = sidebar.hitTest(sidebar.superview?.convert(windowPoint, from: nil) ?? .zero)
    #expect(hit === close)
    var closed: [String] = []
    sidebar.onAction = { if case .close(let id) = $0 { closed.append(id) } }
    let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let release = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    hit?.mouseDown(with: press)
    hit?.mouseUp(with: release)
    #expect(closed == ["b"])
    sidebar.pointerExited(row)
    let restingPoint = row.convert(NSPoint(x: close.frame.midX, y: 4), to: sidebar.superview)
    #expect(sidebar.hitTest(restingPoint) !== close)
  }
}
