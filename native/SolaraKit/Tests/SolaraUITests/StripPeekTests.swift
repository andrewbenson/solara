import AppKit
import Testing

@testable import SolaraUI

@Suite(.serialized) @MainActor struct StripPeekTests {
  private func view() -> StripPeekView {
    let view = StripPeekView(frame: NSRect(x: 0, y: 0, width: 1200, height: 80))
    view.bandLeft = 78
    view.peek.schedule = { _, run in
      run()
      return nil
    }
    view.setEnabled(true)
    return view
  }

  @Test func thePanelSitsUnderTheBandAndSlidesFromAboveIt() {
    #expect(StripPeekMetrics.panel(windowWidth: 1200) == CGRect(x: 6, y: 4, width: 1188, height: 46))
    #expect(StripPeekMetrics.row(in: CGSize(width: 1188, height: 46)) == CGRect(x: 0.5, y: 2.5, width: 1187, height: 42))
    #expect(StripPeekMetrics.offset(0) == -54)
    #expect(StripPeekMetrics.offset(1) == 0)
  }

  @Test func theBandRunsFromTheTrafficLightsToThePanelsRightEdge() {
    #expect(StripPeekMetrics.holds(CGPoint(x: 80, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 40, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 1196, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(StripPeekMetrics.holds(CGPoint(x: 10, y: 40), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 10, y: 51), windowWidth: 1200, bandLeft: 78))
  }

  @Test func thePointerInTheBandSlidesThePanelInOverRNs180msOutCubic() {
    let view = view()
    view.pointer(at: CGPoint(x: 300, y: 2))
    #expect(view.live)
    view.step(by: 0.09)
    #expect(abs(view.slideValue - 0.875) < 1e-9)
    view.step(by: 0.09)
    #expect(view.slideValue == 1)
  }

  @Test func leavingThePanelSlidesItOutAndEndsTheLiveState() {
    let view = view()
    view.pointer(at: CGPoint(x: 300, y: 2))
    view.step(by: 0.2)
    view.pointer(at: CGPoint(x: 300, y: 30))
    #expect(view.live)
    view.pointer(at: CGPoint(x: 300, y: 70))
    view.step(by: 0.2)
    #expect(view.slideValue == 0)
    #expect(!view.live)
  }

  @Test func onlyTheContentTakesClicksSoTheEmptyPanelFallsThroughToTheDragRegionBelow() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 80))
    let view = view()
    container.addSubview(view)
    let content = StripPeekRow(strip: TopStripView(windowId: "w1"))
    view.content = content
    let tab = NSView(frame: NSRect(x: 100, y: 5, width: 50, height: 30))
    content.strip.addSubview(tab)
    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? { view.hitTest(view.convert(NSPoint(x: x, y: y), to: container)) }
    #expect(hit(120, 20) == nil)
    view.pointer(at: CGPoint(x: 300, y: 2))
    view.step(by: 0.2)
    view.layoutSubtreeIfNeeded()
    #expect(hit(6.5 + 8 + 120, 4.5 + 2 + 20) === tab)
    #expect(hit(600, 20) == nil)
    #expect(hit(600, 70) == nil)
  }

  @Test func itWatchesThePointerOnlyWhileEnabledInAWindow() {
    let before = StripPeekView.monitors
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 80), styleMask: [], backing: .buffered, defer: true)
    let view = view()
    window.contentView?.addSubview(view)
    #expect(StripPeekView.monitors == before + 1)
    view.setEnabled(false)
    #expect(StripPeekView.monitors == before)
    view.setEnabled(true)
    view.removeFromSuperview()
    #expect(StripPeekView.monitors == before)
  }

  @Test func aHeldPeekStaysOutUntilRechecked() {
    let view = view()
    var held = true
    view.peek.held = { held }
    view.pointer(at: CGPoint(x: 300, y: 2))
    view.step(by: 0.2)
    view.pointer(at: nil)
    #expect(view.live)
    held = false
    view.peek.recheck()
    view.step(by: 0.2)
    #expect(!view.live)
  }

  #if DEBUG
  @Test func postedAppKitMouseMovesShowHoldAndDismissThePeekWithoutAPointerOverride() async throws {
    await configurePairingTestApplication()
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let view = StripPeekView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
    view.bandLeft = 78
    window.contentView = view
    view.setEnabled(true)
    defer {
      view.stop()
      window.close()
    }
    func post(_ point: CGPoint) throws {
      let event = try #require(NSEvent.mouseEvent(
        with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
      NSApp.postEvent(event, atStart: false)
    }
    func pump(_ seconds: TimeInterval, check: () -> Void = {}) async throws {
      let end = Date(timeIntervalSinceNow: seconds)
      while Date() < end {
        try await Task.sleep(for: .milliseconds(10))
        check()
      }
    }
    #expect(view.watching)
    try post(CGPoint(x: 300, y: 160))
    try await pump(0.1)
    #expect(!view.live)
    try post(CGPoint(x: 300, y: 2))
    try await pump(0.3)
    try #require(view.live)
    try post(CGPoint(x: 520, y: 30))
    try await pump(0.6) { #expect(view.live) }
    try post(CGPoint(x: 520, y: 160))
    let dismissedBy = Date(timeIntervalSinceNow: 2)
    while view.live && Date() < dismissedBy {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!view.live)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
  }

  @Test func theDebugPointerNotificationShowsHoldsAndDismissesThePeek() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 80), styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = view()
    window.contentView?.addSubview(view)
    defer {
      view.setEnabled(false)
      window.close()
    }
    func pointer(_ point: CGPoint?) {
      let screen = point.map { NSValue(point: window.convertPoint(toScreen: view.convert($0, to: nil))) }
      NotificationCenter.default.post(name: DevPointer.changed, object: screen)
    }
    pointer(CGPoint(x: 300, y: 30))
    view.step(by: 0.2)
    #expect(view.live)
    pointer(CGPoint(x: 520, y: 30))
    view.step(by: 0.2)
    #expect(view.live)
    pointer(CGPoint(x: 520, y: 70))
    view.step(by: 0.2)
    #expect(!view.live)
    pointer(CGPoint(x: 300, y: 30))
    view.step(by: 0.2)
    #expect(view.live)
    pointer(nil)
    view.step(by: 0.2)
    #expect(!view.live)
    view.setEnabled(false)
    pointer(CGPoint(x: 300, y: 30))
    view.setEnabled(true)
    pointer(CGPoint(x: 300, y: 30))
    view.step(by: 0.2)
    #expect(view.live)
  }
  #endif
}
