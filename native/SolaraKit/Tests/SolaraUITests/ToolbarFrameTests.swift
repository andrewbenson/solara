import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarFrameTests {
  static func state(windowToolbar: Bool = false, bare: Bool = false, inSplit: Bool = false) -> ToolbarState {
    var state = ToolbarWebKitPillTests.state(extensions: "")
    state.windowToolbar = windowToolbar
    state.bare = bare
    state.inSplit = inSplit
    state.palette.background = "#202030"
    state.hairline = true
    state.url?.pinned = true
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    state.stripes = root.appendingPathComponent("apps/browser/assets/developer-stripes-light.png").path
    return state
  }

  static func surfaceLayers(_ toolbar: ToolbarView) -> [CALayer] {
    let surface = toolbar.layer!.sublayers!.first!
    return [toolbar.layer!, surface] + (surface.sublayers ?? [])
  }

  static func effectViews(_ view: NSView) -> [NSVisualEffectView] {
    view.subviews.flatMap { ($0 as? NSVisualEffectView).map { [$0] } ?? effectViews($0) }
  }

  static func expectFrameIsClear(_ toolbar: ToolbarView) throws {
    for layer in surfaceLayers(toolbar) {
      #expect(layer.backgroundColor == nil || layer.backgroundColor!.alpha == 0)
      #expect(layer.contents == nil)
      #expect(layer.animationKeys()?.isEmpty != false)
    }
    #expect(effectViews(toolbar).isEmpty)
    let hairline = try #require(toolbar.layer?.sublayers?[1])
    #expect(hairline.isHidden)
    let field = try #require(ToolbarWebKitPillTests.fieldIn(toolbar))
    #expect(field.layer?.sublayers?.first?.backgroundColor?.alpha ?? 0 > 0)
  }

  @Test func anIconsOnlyToolbarHasNoSurfaceButKeepsTheAddressPill() throws {
    let f = ToolbarResizeTests.Fixture(bare: false)
    f.toolbar.update(Self.state(windowToolbar: true))
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.cardStyle.fill = NSColor.black
    f.shell.setSidebarWidth(42, animated: false)
    try Self.expectFrameIsClear(f.toolbar)
    #expect(f.toolbar.superview !== f.owner)
    #expect(f.toolbarRect.minX == f.shell.frames.card.minX)
  }

  @Test func aWindowToolbarClearsThePageBandImmediatelyAndStaysClearAcrossLayouts() throws {
    let f = ToolbarResizeTests.Fixture(bare: false)
    f.toolbar.update(Self.state())
    f.toolbar.layoutSubtreeIfNeeded()
    #expect(Self.surfaceLayers(f.toolbar).contains { $0.backgroundColor?.alpha ?? 0 > 0 })
    f.toolbar.update(Self.state(windowToolbar: true))
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    try Self.expectFrameIsClear(f.toolbar)
    f.shell.update { $0.topTabs = true }
    try Self.expectFrameIsClear(f.toolbar)
    f.shell.update { $0.fullscreen = true }
    try Self.expectFrameIsClear(f.toolbar)
    f.shell.update { $0.sidebarWidth = 270 }
    try Self.expectFrameIsClear(f.toolbar)
    #expect(f.toolbarRect.minX == f.shell.frames.card.minX)
  }

  @Test func thePaneBandReturnsAfterLeavingTheWindowFrame() throws {
    let f = ToolbarResizeTests.Fixture(bare: false)
    f.toolbar.update(Self.state(inSplit: true))
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.setSidebarWidth(42, animated: false)
    try Self.expectFrameIsClear(f.toolbar)
    f.shell.setSidebarWidth(190, animated: false)
    #expect(f.toolbar.superview === f.owner)
    #expect(Self.surfaceLayers(f.toolbar).contains { $0.backgroundColor?.alpha ?? 0 > 0 })
    #expect(f.toolbar.layer?.sublayers?[1].isHidden == false)
  }

  @Test func aPaneThatRemainsInsideTheCardKeepsItsSurfaceInRail() {
    let f = ToolbarResizeTests.Fixture(bare: false)
    var state = Self.state(inSplit: true)
    state.focused = false
    f.toolbar.update(state)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.setSidebarWidth(42, animated: false)
    #expect(f.toolbar.superview === f.owner)
    #expect(Self.surfaceLayers(f.toolbar).contains { $0.backgroundColor?.alpha ?? 0 > 0 })
    #expect(f.toolbar.layer?.sublayers?[1].isHidden == false)
  }

  @Test(arguments: [false, true]) func aRailPaneRestoresItsSurfaceAndStripWhenReleased(unregister: Bool) throws {
    let f = ToolbarResizeTests.Fixture(bare: false)
    var state = Self.state(inSplit: true)
    f.toolbar.update(state)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.setSidebarWidth(CGFloat(SidebarRail.width), animated: false)
    let strip = AutoHideStripView(frame: .zero)
    strip.reduceMotion = true
    strip.set(style: AutoHideStripStyle(card: CSSColor("#222222")!, band: CSSColor("#336699"), divider: CSSColor("#FFFFFF")!,
      secondary: CSSColor("#FFFFFF80")!, host: "example.com", hasPage: true), mode: .shown, shownTop: 41)
    f.toolbar.onGeometryChange = { [weak toolbar = f.toolbar, weak strip] in
      if let toolbar, let strip { toolbar.placeBackdrop(strip) }
    }
    f.toolbar.placeBackdrop(strip)
    #expect(strip.frameSurface)
    if unregister {
      f.shell.unregisterToolbar(f.toolbar)
    } else {
      state.focused = false
      f.toolbar.update(state)
      f.shell.registerToolbar(f.toolbar, owner: f.owner)
    }
    #expect(f.toolbar.superview === f.owner)
    #expect(!f.toolbar.sitsOnWindowFrame)
    #expect(Self.surfaceLayers(f.toolbar).contains { $0.backgroundColor?.alpha ?? 0 > 0 })
    #expect(f.toolbar.layer?.sublayers?[1].isHidden == false)
    #expect(!strip.frameSurface)
    #expect(strip.bandShown == CSSColor("#336699")!.cg)
  }
}
