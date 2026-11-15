import AppKit
import CoreGraphics
import Testing
@testable import SolaraUI

struct AutoHideStripTests {
  @Test func modeFollowsRNsRules() {
    func mode(_ enabled: Bool, _ page: Bool, _ down: Bool, _ peek: Bool, _ bar: Bool) -> ToolbarAutoHideMode {
      ToolbarAutoHideInput(enabled: enabled, hasPage: page, scrolledDown: down, peek: peek, needsBar: bar).mode
    }
    #expect(mode(false, true, true, false, false) == .shown)
    #expect(mode(true, false, true, false, false) == .shown)
    #expect(mode(true, true, false, true, false) == .shown)
    #expect(mode(true, true, true, false, true) == .shown)
    #expect(mode(true, true, true, false, false) == .collapsed)
    #expect(mode(true, true, true, true, false) == .peek)
  }

  @Test func curvesMatchRNsInterpolations() {
    #expect(ToolbarAutoHideCurves.controlsOpacity(fade: 0) == 1)
    #expect(abs(ToolbarAutoHideCurves.controlsOpacity(fade: 0.2) - 0.45) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.controlsOpacity(fade: 0.3) - 0.3) < 1e-9)
    #expect(ToolbarAutoHideCurves.controlsOpacity(fade: 0.6) == 0)
    #expect(ToolbarAutoHideCurves.labelOpacity(fade: 0.5) == 0)
    #expect(abs(ToolbarAutoHideCurves.labelOpacity(fade: 0.75) - 0.5) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.toolbarScale(bar: 1) - 0.94) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.toolbarLift(bar: 1) - (-(0.06 * 41) / 2 - 3)) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.bandScale(bar: 1) - 20.0 / 41) < 1e-9)
    #expect(ToolbarAutoHideCurves.bandLift(bar: 1) == -10.5)
    #expect(ToolbarAutoHideCurves.dividerLift(bar: 1) == -21)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0, collapsed: true, shownTop: 41) == 41)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0.5, collapsed: true, shownTop: 41) == 30.5)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 1, collapsed: true, shownTop: 41) == 20)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 0, page: 1, collapsed: false, shownTop: 71) == 20)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 0, page: 0, collapsed: false, shownTop: 71) == 71)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0, collapsed: true, shownTop: 71) == 71)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0.5, collapsed: true, shownTop: 71) == 45.5)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 1, collapsed: true, shownTop: 71) == 20)
  }

  @Test func transitionsTakeRNsTimings() throws {
    let hide = try #require(ToolbarAutoHideTransition.between(.shown, .collapsed, current: (0, 0, 0), at: 10, reduceMotion: false))
    #expect(hide.page.duration == 0.15 && hide.page.to == 1 && hide.bar.to == 1 && hide.laid == 1)
    let show = try #require(ToolbarAutoHideTransition.between(.collapsed, .shown, current: (1, 1, 1), at: 10, reduceMotion: false))
    #expect(show.page.duration == 0.2 && show.page.to == 0 && show.fade.to == 0)
    let peek = try #require(ToolbarAutoHideTransition.between(.collapsed, .peek, current: (1, 1, 1), at: 10, reduceMotion: false))
    #expect(peek.bar == .resting(0) && peek.fade == .resting(0))
    let unpeek = try #require(ToolbarAutoHideTransition.between(.peek, .collapsed, current: (1, 0, 0), at: 10, reduceMotion: false))
    #expect(unpeek.bar.duration == 0.15 && unpeek.bar.to == 1)
    #expect(ToolbarAutoHideTransition.between(.shown, .shown, current: (0, 0, 0), at: 10, reduceMotion: false) == nil)
    let reduced = try #require(ToolbarAutoHideTransition.between(.shown, .collapsed, current: (0, 0, 0), at: 10, reduceMotion: true))
    #expect(reduced.page == .resting(1) && reduced.fade.duration == 0.15)
  }

  @MainActor @Test(arguments: [ToolbarAutoHideMode.shown, .collapsed, .peek])
  func nativeProjectionTopMatchesTheEmittedPresentationSample(mode: ToolbarAutoHideMode) throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 71))
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil,
      divider: try #require(CSSColor("#00000020")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    var emitted: Double?
    strip.onFrame = { frame in
      emitted = frame.liveTop
      #expect(strip.presentationTop == frame.liveTop)
    }
    strip.set(style: style, mode: mode, shownTop: 71)
    #expect(strip.presentationTop == (mode == .shown ? 71 : 20))
    #expect(emitted == strip.presentationTop)
  }

  @MainActor @Test func changingShownHeightPublishesWithoutChangingMode() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 71))
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil,
      divider: try #require(CSSColor("#00000020")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.set(style: style, mode: .shown, shownTop: 71)
    #expect(strip.presentationTop == 71)
  }

  @MainActor @Test func transitionFirstFrameUsesTheDestinationMode() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil,
      divider: try #require(CSSColor("#00000020")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    #expect(strip.presentationTop >= 20 && strip.presentationTop <= 41)
    strip.set(style: style, mode: .shown, shownTop: 41)
    #expect(strip.presentationTop >= 20 && strip.presentationTop <= 41)
    strip.removeFromSuperview()
  }

  @MainActor @Test func revealCancelsAnOlderPendingHoverPeek() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 41), styleMask: [.borderless], backing: .buffered, defer: true)
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    window.contentView?.addSubview(strip)
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil,
      divider: try #require(CSSColor("#00000020")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    var events: [AutoHideStripEvent] = []
    strip.onEvent = { events.append($0) }
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 300, y: 35), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    strip.mouseMoved(with: event)
    strip.set(style: style, mode: .shown, shownTop: 41)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    #expect(events.isEmpty)
    strip.removeFromSuperview()
  }

  @MainActor @Test func aSiteWithoutAColorLeavesTheBandClearAndDeveloperSitesGetStripes() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    let plain = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: plain, mode: .collapsed, shownTop: 41)
    #expect(strip.bandShown == nil)
    #expect(!strip.stripesShown)
    var colored = plain
    colored.band = try #require(CSSColor("#336699"))
    strip.set(style: colored, mode: .collapsed, shownTop: 41)
    #expect(strip.bandShown != nil)
    strip.set(style: plain, mode: .collapsed, shownTop: 41)
    #expect(strip.bandShown == nil)
  }

  @MainActor @Test func theCollapsedBandFillsTheStripAndStaysThereAcrossLayouts() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.layout()
    #expect(strip.bandFrame == CGRect(x: 0, y: 0, width: 600, height: 41))
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    strip.reduceMotion = true
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    for _ in 0..<3 { strip.layout() }
    let band = strip.bandFrame
    #expect(abs(band.minY) < 0.01 && abs(band.height - 20) < 0.01 && band.width == 600)
  }

  @MainActor @Test func withNoDisplayFramesACollapseStillSettles() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    strip.reduceMotion = false
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    var moving: [Bool] = []
    strip.onMotion = { moving.append($0) }
    strip.set(style: style, mode: .shown, shownTop: 41)
    moving = []
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    #expect(moving == [true])
    let deadline = Date().addingTimeInterval(3)
    while moving.last != false && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    #expect(moving.last == false)
    let band = strip.bandFrame
    #expect(abs(band.minY) < 0.01 && abs(band.height - 20) < 0.01)
  }

  @MainActor @Test func developerStripesDrawInTheBand() throws {
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../apps/browser/assets/developer-stripes-light@2x.png").standardized
    try #require(FileManager.default.fileExists(atPath: asset.path), "copy apps/browser/assets next to native/SolaraKit")
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 200, height: 41))
    var style = AutoHideStripStyle(card: try #require(CSSColor("#202020")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    style.stripes = asset.path
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.layout()
    #expect(strip.stripesShown)
    let rep = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
    strip.cacheDisplay(in: strip.bounds, to: rep)
    var shades = Set<Int>()
    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
      if let c = rep.colorAt(x: x, y: rep.pixelsHigh / 2) { shades.insert(Int((c.redComponent * 255).rounded())) }
    }
    #expect(shades.count > 1)
  }

  @MainActor @Test func theShowToolbarTipOnlyAppliesWhileCollapsed() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    strip.reduceMotion = true
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    #expect(!strip.showsToolTip)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    #expect(strip.showsToolTip)
    strip.set(style: style, mode: .peek, shownTop: 41)
    #expect(!strip.showsToolTip)
  }

  @MainActor @Test func hoverPeeksAfterRNsDelaysAndAClickReveals() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 41), styleMask: [.borderless], backing: .buffered, defer: true)
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    window.contentView?.addSubview(strip)
    strip.reduceMotion = true
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    var events: [AutoHideStripEvent] = []
    strip.onEvent = { events.append($0) }
    func mouse(_ type: NSEvent.EventType, top: CGFloat) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 300, y: 41 - top), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }
    func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.mouseMoved(with: try mouse(.mouseMoved, top: 6))
    wait(0.25)
    #expect(events.isEmpty)

    strip.set(style: style, mode: .collapsed, shownTop: 41)
    strip.mouseEntered(with: try mouse(.mouseMoved, top: 6))
    strip.mouseMoved(with: try mouse(.mouseMoved, top: 30))
    wait(0.25)
    #expect(events.isEmpty)

    strip.mouseMoved(with: try mouse(.mouseMoved, top: 6))
    wait(0.08)
    #expect(events.isEmpty)
    wait(0.17)
    #expect(events == [.peek(true)])

    events.removeAll()
    strip.set(style: style, mode: .peek, shownTop: 41)
    strip.mouseExited(with: try mouse(.mouseMoved, top: 50))
    wait(0.1)
    strip.mouseEntered(with: try mouse(.mouseMoved, top: 10))
    wait(0.3)
    #expect(events.isEmpty)
    strip.mouseExited(with: try mouse(.mouseMoved, top: 50))
    wait(0.15)
    #expect(events.isEmpty)
    wait(0.2)
    #expect(events == [.peek(false)])

    events.removeAll()
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    strip.mouseUp(with: try mouse(.leftMouseUp, top: 30))
    strip.mouseUp(with: try mouse(.leftMouseUp, top: 6))
    #expect(events == [.reveal])
  }

  @MainActor @Test func theCollapsedLabelDrawsInTheSecondaryColorOnce() throws {
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 300, height: 41))
    strip.reduceMotion = true
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "HHHHHHHH", hasPage: true)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    strip.layout()
    let rep = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
    strip.cacheDisplay(in: strip.bounds, to: rep)
    var ink = 0.0
    for y in 0..<min(rep.pixelsHigh, Int(ToolbarAutoHideMetrics.stripHeight) * rep.pixelsHigh / 41) {
      for x in 0..<rep.pixelsWide {
        if let c = rep.colorAt(x: x, y: y) { ink = max(ink, c.alphaComponent * (1 - c.redComponent)) }
      }
    }
    print("label ink", ink)
    #expect(abs(ink - 0.5) < 0.06)
  }

  @MainActor @Test func theStripRoundsTheCardsTopCornersOnly() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 41), styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 41))
    host.wantsLayer = true
    window.contentView = host
    let strip = AutoHideStripView(frame: host.bounds)
    host.addSubview(strip)
    strip.reduceMotion = true
    let style = AutoHideStripStyle(card: try #require(CSSColor("#000000")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.layout()
    host.displayIfNeeded()
    CATransaction.flush()
    let ctx = try #require(CGContext(data: nil, width: 200, height: 41, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    try #require(host.layer).render(in: ctx)
    let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
    func alpha(_ x: Int, fromTop y: Int) -> UInt8 { pixels[(y * ctx.bytesPerRow) + x * 4 + 3] }
    #expect(alpha(0, fromTop: 0) == 0 && alpha(199, fromTop: 0) == 0)
    #expect(alpha(0, fromTop: 39) == 255 && alpha(199, fromTop: 39) == 255)
    #expect(alpha(100, fromTop: 0) == 255)
  }
}
