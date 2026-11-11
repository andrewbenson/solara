import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct WindowShellFrameSurfaceTests {
  @Test func theFullSidebarToolbarKeepsCardFillAndEdgesUnderItsControls() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
    fixture.shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
    let shell = fixture.shell
    shell.cardStyle = CardStyle(fill: .black, radius: 10)
    #expect(shell.cardClip.frame == CGRect(x: 0, y: 0, width: 803, height: 687))
    #expect(shell.cardShadow.edgeRect == CGRect(x: 0, y: 0, width: 803, height: 687))
    #expect(shell.cardRim.edgeRect == CGRect(x: 0, y: 0, width: 803, height: 687))
    #expect(shell.cardClip.convert(shell.cardClip.bounds, to: shell) == CGRect(x: 190, y: 6, width: 803, height: 687))
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 190, y: 47, width: 803, height: 646))
    #expect(shell.cardClip.layer?.backgroundColor == NSColor.black.cgColor)
    shell.update { $0.sidebarWidth = 270 }
    #expect(shell.cardClip.convert(shell.cardClip.bounds, to: shell) == CGRect(x: 270, y: 6, width: 723, height: 687))
    #expect(fixture.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    shell.unregisterToolbar(fixture.toolbar)
    #expect(shell.cardClip.frame == CGRect(x: 0, y: 0, width: 723, height: 687))
    #expect(shell.cardClip.bounds.origin == .zero)
    #expect(shell.cardRim.edgeRect == CGRect(x: 0, y: 0, width: 723, height: 687))
  }

  @Test func theFullSidebarCardCoversTheToolbarDespiteTheLivePageTop() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
    fixture.shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
    let shell = fixture.shell
    shell.cardPageFrame = CGRect(x: 0, y: 20, width: 803, height: 667)
    #expect(shell.cardClip.frame == CGRect(x: 0, y: 0, width: 803, height: 687))
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 190, y: 26, width: 803, height: 667))
    shell.cardPageFrame = nil
    shell.update { $0.topTabs = true }
    #expect(shell.cardClip.convert(shell.cardClip.bounds, to: shell) == CGRect(x: 6, y: 42, width: 988, height: 652))
    shell.update { $0.topTabs = false }
    shell.setSidebarWidth(CGFloat(SidebarRail.width), animated: false)
    #expect(shell.cardClip.frame == CGRect(x: 0, y: 0, width: 1000, height: 700))
    shell.cardStyle = CardStyle(fill: .black, radius: 10)
    shell.update { $0.dock = 0 }
    #expect(shell.cardClip.layer?.backgroundColor == NSColor.black.cgColor)
    #expect(shell.cardClip.layer?.cornerRadius == 10)
    #expect(shell.cardRim.edgeRect == CGRect(x: 0, y: 0, width: 1000, height: 700))
  }

  @Test func theFrameAutoHideStripHasNoPaintAndRetainsItsCollapsedHitTarget() throws {
    let fixture = ToolbarResizeTests.Fixture()
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 803, height: 41))
    let style = AutoHideStripStyle(card: CSSColor("#222222")!, band: CSSColor("#336699"), divider: CSSColor("#FFFFFF")!, secondary: CSSColor("#FFFFFF80")!, host: "example.com", hasPage: true)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    fixture.shell.setSidebarWidth(CGFloat(SidebarRail.width), animated: false)
    fixture.toolbar.placeBackdrop(strip)
    #expect(strip.bandShown == nil)
    #expect(!strip.stripesShown)
    for layer in strip.layer?.sublayers ?? [] {
      for paint in [layer] + (layer.sublayers ?? []) {
        #expect(paint.isHidden || paint.backgroundColor == nil || paint.backgroundColor?.alpha == 0)
      }
    }
    let hit = strip.convert(CGPoint(x: 400, y: 10), to: strip.superview)
    #expect(strip.hitTest(hit) === strip)
    var events: [AutoHideStripEvent] = []
    strip.onEvent = { events.append($0) }
    let location = strip.convert(CGPoint(x: 400, y: 10), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    strip.mouseUp(with: event)
    #expect(events == [.reveal])
    fixture.shell.setSidebarWidth(190, animated: false)
    fixture.toolbar.placeBackdrop(strip)
    #expect(!strip.frameSurface)
    #expect(strip.bandShown == CSSColor("#336699")!.cg)
    let divider = try #require(strip.layer?.sublayers?[1])
    #expect(!divider.isHidden)
    var pane = fixture.toolbar.state!
    pane.bare = true
    pane.inSplit = true
    pane.windowToolbar = false
    fixture.toolbar.update(pane)
    fixture.shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
    fixture.toolbar.placeBackdrop(strip)
    #expect(strip.bandShown == CSSColor("#336699")!.cg)
    let card = try #require(strip.layer?.sublayers?.first?.sublayers?.first)
    #expect(card.backgroundColor == CSSColor("#222222")!.cg)
  }
}
