import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite struct NativeLayoutAdoptionTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"profileOrder":["p"],"windows":{"w":{"id":"w","profileId":"p","tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/"}}}"#).object ?? [:])
  }

  @Test func stoppedSidebarRejectsACommitAndPagerDeliveryWhileItsViewIsRetained() throws {
    let pager = SidebarPagerView(windowId: "w")
    pager.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
    let state = try state()
    let host = SidebarHostState(profileId: "p")
    pager.update(state: state, host: host)
    #expect(pager.current != nil)
    pager.stop()
    pager.update(state: state, host: host)
    pager.setPagerPosition(0.5)
    pager.layoutSubtreeIfNeeded()
    #expect(pager.current == nil)
    #expect(pager.subviews.isEmpty)
    #expect(state.tabs["a"]?.url == "https://a.example/")
  }

  @Test func stoppedStripRejectsACommitWithoutChangingTheRetainedTab() throws {
    let strip = TopStripView(windowId: "w")
    strip.frame = CGRect(x: 0, y: 0, width: 800, height: 42)
    let state = try state()
    let host = StripHostState(profileId: "p")
    strip.update(state: state, host: host)
    let page = try #require(strip.current)
    strip.stop()
    strip.update(state: state, host: host)
    strip.setPagerPosition(0.5)
    #expect(strip.current == nil)
    #expect(strip.subviews.isEmpty)
    #expect(page.incoming(at: CGPoint(x: 20, y: 20)) == nil)
    #expect(state.tabs["a"]?.url == "https://a.example/")
  }

  @Test func stoppedPeekCannotReadmitAQueuedEnableOrPointer() {
    let peek = StripPeekView(frame: CGRect(x: 0, y: 0, width: 1200, height: 80))
    peek.setEnabled(true)
    peek.stop()
    peek.setEnabled(true)
    peek.pointer(at: CGPoint(x: 300, y: 2))
    #expect(!peek.peek.enabled)
    #expect(!peek.live)
    #expect(!peek.watching)
    #expect(peek.hitTest(CGPoint(x: 300, y: 2)) == nil)
  }
}

@MainActor
private final class AdoptionStripBridge: StripDragBridge {
  var landed = 0
  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {}
  func dragPicture(windowId: String, rect: CGRect, grab: CGPoint) {}
  func dragMoved(windowId: String, at: CGPoint, lifted: Bool, dx: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) { done(false) }
  func drop(ids: [String], drop: JSONValue) -> Bool { false }
  func land(ids: [String], from source: String, in windowId: String, beforeId: String?) -> Bool { landed += 1; return true }
}

extension NativeLayoutAdoptionTests {
  @Test func floatingStripAimsOnlyWhileAttachedVisibleAndInsideItsRow() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
    let strip = TopStripView(windowId: "w")
    strip.takesDrops = false
    strip.frame = CGRect(x: 20, y: 10, width: 400, height: 42)
    var host = StripHostState(profileId: "p")
    host.floating = true
    host.pageWidth = 400
    strip.update(state: try state(), host: host)
    strip.takesDrops = true
    root.addSubview(strip)
    window.contentView = root
    let zone = StripDropZone(strip: strip)
    let session = TabDragSession(tabIds: ["incoming"], sourceWindow: "source")
    let point = strip.convert(CGPoint(x: 100, y: 20), to: nil)
    let inside = CGPoint(x: point.x, y: 200 - point.y)
    #expect(TabDragSession.hasZone(in: "w", .insert))
    #expect(zone.aim(session, at: inside) != nil)
    #expect(zone.aim(session, at: CGPoint(x: inside.x, y: 60)) == nil)
    strip.isHidden = true
    #expect(zone.aim(session, at: inside) == nil)
    strip.isHidden = false
    root.isHidden = true
    #expect(zone.aim(session, at: inside) == nil)
    root.isHidden = false
    #expect(zone.aim(session, at: inside) != nil)
    strip.removeFromSuperview()
    #expect(zone.aim(session, at: inside) == nil)
    strip.stop()
  }

  @Test func aCachedStripAimCannotLandAfterHidingOrDisablingTheSurface() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
    let strip = TopStripView(windowId: "w")
    strip.frame = CGRect(x: 20, y: 10, width: 400, height: 42)
    let bridge = AdoptionStripBridge()
    strip.dragBridge = bridge
    strip.update(state: try state(), host: StripHostState(profileId: "p"))
    root.addSubview(strip)
    window.contentView = root
    let zone = StripDropZone(strip: strip)
    let session = TabDragSession(tabIds: ["incoming"], sourceWindow: "source")
    let point = strip.convert(CGPoint(x: 100, y: 20), to: nil)
    let aim = try #require(zone.aim(session, at: CGPoint(x: point.x, y: 200 - point.y)))
    #expect(zone.drop(session, aim))
    #expect(bridge.landed == 1)
    strip.isHidden = true
    #expect(!zone.drop(session, aim))
    strip.isHidden = false
    strip.takesDrops = false
    #expect(!zone.drop(session, aim))
    #expect(bridge.landed == 1)
    strip.stop()
  }
}
