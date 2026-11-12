import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarResizeTests {
  @MainActor final class Fixture {
    let window: NSWindow
    let shell: WindowShellView
    let owner = FlippedContainerView()
    let toolbar = ToolbarView(frame: .zero)
    let handle = SidebarResizeHandle(frame: .zero)
    var committed: Double?

    init(bare: Bool = true, reactOnTop: Bool = false) {
      shell = WindowShellView(windowId: "toolbar-resize", reactOnTop: reactOnTop)
      window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView = shell
      let react = FlippedContainerView()
      shell.mount(.react, react)
      owner.frame = CGRect(x: 190, y: 6, width: 803, height: 41)
      react.addSubview(owner)
      toolbar.frame = owner.bounds
      toolbar.autoresizingMask = [.width, .height]
      owner.addSubview(toolbar)
      var state = ToolbarWebKitPillTests.state(extensions: "")
      state.height = 41
      state.bare = bare
      toolbar.update(state)
      toolbar.layoutSubtreeIfNeeded()
      shell.registerToolbar(toolbar, owner: owner)
      handle.savedWidth = { 190 }
      handle.onWidth = { [weak self] action in
        guard let self else { return }
        switch action {
        case .liveWidth(let width):
          shell.widthDragActive = width != nil
          if let width { shell.update { $0.sidebarWidth = CGFloat(width) } }
        case .commitWidth(let width): committed = width
        default: break
        }
      }
    }

    func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    var toolbarRect: CGRect { toolbar.convert(toolbar.bounds, to: shell) }
  }

  @Test func oneResizeEventPlacesTheWindowToolbarAndItsControlsWithThePage() throws {
    let f = Fixture()
    f.handle.mouseDown(with: f.mouse(.leftMouseDown, x: 190))
    f.handle.mouseDragged(with: f.mouse(.leftMouseDragged, x: 270))
    #expect(f.shell.card.frame == CGRect(x: 270, y: 6, width: 723, height: 687))
    #expect(f.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    #expect(f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell).minX == f.toolbarRect.minX)
    let field = try #require(ToolbarWebKitPillTests.fieldIn(f.toolbar))
    #expect(field.frame.width == 553)
    #expect(field.superview?.bounds.width == 723)
    #expect(f.owner.frame == CGRect(x: 190, y: 6, width: 803, height: 41))
    #expect(f.toolbar.layer?.animationKeys()?.isEmpty != false)
  }

  @Test(arguments: [197.25, 197.5, 197.75])
  func fractionalResizePlacesToolbarAndPageOnTheSameWholePointEdges(width: Double) throws {
    let f = Fixture()
    f.handle.mouseDown(with: f.mouse(.leftMouseDown, x: 190))
    f.handle.mouseDragged(with: f.mouse(.leftMouseDragged, x: CGFloat(width)))
    let page = f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell)
    #expect(f.toolbarRect.minX == CGFloat(SidebarResizeMath.live(width)).rounded())
    #expect(page.minX == f.toolbarRect.minX)
    #expect(page.maxX == f.toolbarRect.maxX)
    #expect(page.width == page.width.rounded())
    f.handle.mouseUp(with: f.mouse(.leftMouseUp, x: CGFloat(width)))
    let committed = try #require(f.committed)
    #expect(committed == width)
    f.shell.update { $0.sidebarWidth = CGFloat(committed) }
    let settled = f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell)
    #expect(settled.minX == CGFloat(width).rounded())
    #expect(settled.width == settled.width.rounded())
    #expect(f.toolbarRect.minX == settled.minX)
    #expect(f.toolbarRect.maxX == settled.maxX)
  }

  @Test func aDelayedPageOverrideOnlySuppliesVerticalGeometry() {
    let f = Fixture()
    f.shell.update { $0.sidebarWidth = 197.5 }
    f.shell.cardPageFrame = CGRect(x: -7.5, y: 20.25, width: 803, height: 666.75)
    let page = f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell)
    #expect(page == CGRect(x: 198, y: 26, width: 795, height: 667))
    #expect(page.minX == f.toolbarRect.minX)
    #expect(page.maxX == f.toolbarRect.maxX)
    f.shell.cardPageFrame = CGRect(x: -0.5, y: 20.25, width: 795.5, height: 666.75)
    #expect(f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell) == page)
    f.shell.update { $0.sidebarWidth = 220.75 }
    let resized = f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell)
    #expect(resized == CGRect(x: 221, y: 26, width: 772, height: 667))
    #expect(resized.minX == f.toolbarRect.minX)
    #expect(resized.maxX == f.toolbarRect.maxX)
  }

  @Test func delayedOwnerLayoutCannotMoveTheToolbarAndMouseUpKeepsTheFinalGeometry() {
    let f = Fixture()
    f.handle.mouseDown(with: f.mouse(.leftMouseDown, x: 190))
    f.handle.mouseDragged(with: f.mouse(.leftMouseDragged, x: 270))
    f.owner.frame = CGRect(x: 230, y: 6, width: 763, height: 41)
    f.owner.layoutSubtreeIfNeeded()
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    f.handle.mouseUp(with: f.mouse(.leftMouseUp, x: 270))
    #expect(f.committed == 270)
    #expect(!f.shell.widthDragActive)
    #expect(!f.shell.widthMoving)
    #expect(f.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    f.shell.update { $0.sidebarWidth = 220 }
    #expect(f.toolbarRect == CGRect(x: 220, y: 6, width: 773, height: 41))
  }

  @Test func aBareToolbarKeepsShellOwnershipAcrossRailTopTabsAndFullscreen() {
    let f = Fixture()
    let parent = f.toolbar.superview
    #expect(parent !== f.owner)
    f.shell.setSidebarWidth(42, animated: false)
    #expect(f.toolbar.superview === parent)
    #expect(f.toolbarRect.minX == f.shell.frames.card.minX)
    #expect(f.toolbarRect.height == 47)
    f.shell.setSidebarWidth(190, animated: false)
    #expect(f.toolbar.superview === parent)
    #expect(f.toolbarRect == CGRect(x: 190, y: 6, width: 803, height: 41))
    f.shell.update { $0.topTabs = true }
    #expect(f.toolbarRect == CGRect(x: 6, y: 42, width: 988, height: 41))
    f.shell.update { $0.fullscreen = true }
    #expect(f.toolbarRect == CGRect(x: 0, y: 0, width: 1000, height: 41))
  }

  @Test func aPaneToolbarStaysInItsOwnerExceptDuringRail() {
    let f = Fixture(bare: false)
    #expect(f.toolbar.superview === f.owner)
    f.shell.update { $0.sidebarWidth = 260 }
    #expect(f.toolbar.superview === f.owner)
    #expect(f.toolbarRect == CGRect(x: 190, y: 6, width: 803, height: 41))
    f.shell.setSidebarWidth(42, animated: false)
    #expect(f.toolbar.superview !== f.owner)
    f.shell.setSidebarWidth(190, animated: false)
    #expect(f.toolbar.superview === f.owner)
    #expect(f.toolbar.frame == f.owner.bounds)
    #expect(f.toolbar.autoresizingMask == [.width, .height])
  }

  @Test func hiddenDetachedAndUnregisteredOwnersGetTheirToolbarBack() {
    let f = Fixture()
    f.owner.isHidden = true
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview === f.owner)
    f.owner.isHidden = false
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview !== f.owner)
    f.owner.removeFromSuperview()
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview === f.owner)
    let react = f.shell.view(in: .react)!
    react.addSubview(f.owner)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview !== f.owner)
    f.shell.unregisterToolbar(f.toolbar)
    #expect(f.toolbar.superview === f.owner)
    f.shell.update { $0.sidebarWidth = 260 }
    #expect(f.toolbar.superview === f.owner)
  }

  @Test func autoHideTransformStaysCenteredOnTheResizedToolbar() {
    let f = Fixture()
    f.toolbar.setAutoHide(opacity: 0.6, scale: 0.9, lift: 5, interactive: false)
    f.shell.update { $0.sidebarWidth = 270 }
    let transform = f.toolbar.layer!.sublayerTransform
    #expect(abs(transform.m41 - 36.15) < 0.0001)
    #expect(abs(transform.m42 - (2.05 - 5)) < 0.0001)
    #expect(transform.m11 == 0.9)
    #expect(f.toolbar.alphaValue == 0.6)
    #expect(f.toolbar.hitTest(CGPoint(x: 400, y: 20)) == nil)
  }

  @Test func theAutoHideBackdropFollowsTheToolbarThroughResizeRailAndDetachedRestoration() {
    let f = Fixture()
    let strip = AutoHideStripView(frame: .zero)
    strip.reduceMotion = true
    strip.set(style: AutoHideStripStyle(card: CSSColor("#FFFFFF")!, band: nil, divider: CSSColor("#000000")!,
      secondary: CSSColor("#000000")!, host: "example.com", hasPage: true), mode: .shown, shownTop: 41)
    f.toolbar.onGeometryChange = { [weak toolbar = f.toolbar, weak strip] in
      if let toolbar, let strip { toolbar.placeBackdrop(strip) }
    }
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.update { $0.sidebarWidth = 270 }
    #expect(strip.convert(strip.bounds, to: f.shell) == CGRect(x: 270, y: 6, width: 723, height: 41))
    #expect(strip.bandFrame.width == 723)
    #expect(strip.superview === f.toolbar.superview)
    #expect(strip.superview?.subviews.suffix(2) == [strip, f.toolbar])
    f.shell.setSidebarWidth(42, animated: false)
    #expect(strip.convert(strip.bounds, to: f.shell).minY == f.toolbarRect.minY + 6)
    #expect(strip.frame.height == 41)
    f.owner.removeFromSuperview()
    f.shell.unregisterToolbar(f.toolbar)
    #expect(f.toolbar.window == nil)
    #expect(strip.superview === f.owner)
    #expect(strip.frame == f.owner.bounds)
  }

  @Test func ambientImplicitAnimationsDoNotAnimateToolbarGeometry() throws {
    let f = Fixture()
    CATransaction.flush()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 1
      context.allowsImplicitAnimation = true
      f.shell.update { $0.sidebarWidth = 270 }
    }
    let clip = try #require(f.toolbar.superview)
    let field = try #require(ToolbarWebKitPillTests.fieldIn(f.toolbar))
    #expect(f.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    #expect(field.frame.width == 553)
    for view in [clip, f.toolbar, field, field.superview!] {
      let animations = (view.layer?.animationKeys() ?? []).filter { key in
        let path = (view.layer?.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? key
        return path.hasPrefix("position") || path.hasPrefix("bounds") || path.hasPrefix("frame")
      }
      #expect(animations.isEmpty)
    }
  }

  @Test func aBareSplitPaneToolbarKeepsItsPaneGeometryOutsideRail() {
    let f = Fixture()
    f.owner.frame = CGRect(x: 600, y: 6, width: 393, height: 41)
    let json = """
      {"tabId":"t1","height":41,"bare":true,"inSplit":true,"focused":true,"palette":\(ToolbarWebKitPillTests.palette),"accent":"#0A84FF",
       "geometry":{"back":40,"forward":70,"reload":100,"urlLeft":130,"urlRight":40},"left":[],"right":[],"rightInset":8,"hairline":false}
      """
    f.toolbar.update(ToolbarState.decode(json)!)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.update { $0.sidebarWidth = 270 }
    #expect(f.toolbar.superview === f.owner)
    #expect(f.toolbarRect == CGRect(x: 600, y: 6, width: 393, height: 41))
  }

  @Test func controlsOutsideTheStaleOwnerStillReceiveHits() throws {
    let f = Fixture()
    var state = f.toolbar.state!
    state.left = [try JSONDecoder().decode(ToolbarButtonState.self, from: Data(#"{"id":"back","icon":"chevron.left"}"#.utf8))]
    f.toolbar.update(state)
    f.shell.update { $0.sidebarWidth = 270 }
    f.owner.frame = CGRect(x: 270, y: 6, width: 723, height: 41)
    f.handle.savedWidth = { 270 }
    f.handle.mouseDown(with: f.mouse(.leftMouseDown, x: 270))
    f.handle.mouseDragged(with: f.mouse(.leftMouseDragged, x: 190))
    let button = try #require(ToolbarWebKitPillTests.buttons(in: f.toolbar).first { $0.state.id == "back" })
    let point = button.convert(CGPoint(x: 15, y: 15), to: f.shell)
    #expect(point.x == 230)
    #expect(point.x < f.owner.frame.minX)
    #expect(f.shell.hitTest(f.shell.convert(point, to: f.shell.superview)) === button)
  }

  @Test func focusVisibilityAndModalsControlTheShellToolbar() {
    let f = Fixture()
    var state = f.toolbar.state!
    state.focused = false
    f.toolbar.update(state)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview === f.owner)
    state.focused = true
    f.toolbar.update(state)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview !== f.owner)
    f.toolbar.isHidden = true
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(f.toolbar.superview === f.owner)
    f.toolbar.isHidden = false
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    #expect(!f.toolbar.isHiddenOrHasHiddenAncestor)
    f.shell.setModal("test", shown: true)
    #expect(f.toolbar.isHiddenOrHasHiddenAncestor)
    f.shell.setModal("test", shown: false)
    #expect(!f.toolbar.isHiddenOrHasHiddenAncestor)
  }

  @Test func aStaticWindowToolbarMovesItsNativeSurfaceWithItsControls() throws {
    let f = Fixture(bare: false)
    var state = ToolbarFrameTests.state(windowToolbar: true)
    state.height = 41
    f.toolbar.update(state)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.shell.update { $0.sidebarWidth = 270 }
    #expect(f.toolbar.superview !== f.owner)
    #expect(f.toolbarRect == CGRect(x: 270, y: 6, width: 723, height: 41))
    #expect(f.toolbar.layer?.sublayers?.first?.frame.width == 723)
    try ToolbarFrameTests.expectBand(f.toolbar)
    f.owner.frame = CGRect(x: 270, y: 6, width: 723, height: 41)
    f.handle.savedWidth = { 270 }
    f.handle.mouseDown(with: f.mouse(.leftMouseDown, x: 270))
    for width: CGFloat in [250, 210, 190] {
      f.handle.mouseDragged(with: f.mouse(.leftMouseDragged, x: width))
      #expect(f.owner.frame.width == 723)
      #expect(f.toolbarRect == CGRect(x: width, y: 6, width: 993 - width, height: 41))
      #expect(f.toolbar.layer?.sublayers?.first?.frame.width == 993 - width)
      #expect(f.shell.cardClip.convert(f.shell.cardClip.bounds, to: f.shell).minX == width)
      #expect(f.shell.cardPage.convert(f.shell.cardPage.bounds, to: f.shell).minX == width)
      try ToolbarFrameTests.expectBand(f.toolbar)
    }
    f.handle.mouseUp(with: f.mouse(.leftMouseUp, x: 190))
  }

  @Test func shellToolbarLayeringMatchesTheReactRootAndRailRoundTrip() throws {
    for reactOnTop in [false, true] {
      let f = Fixture(reactOnTop: reactOnTop)
      let peek = FlippedContainerView()
      f.shell.mount(.peek, peek)
      f.shell.registerToolbar(f.toolbar, owner: f.owner)
      let clip = try #require(f.toolbar.superview)
      if reactOnTop {
        #expect(clip.superview === f.shell.overlay)
      } else {
        #expect(clip.superview === f.shell)
        let children = f.shell.subviews
        let clipIndex = try #require(children.firstIndex(of: clip))
        #expect(clipIndex < children.firstIndex(of: peek)!)
        #expect(clipIndex > children.firstIndex(of: f.shell.card)!)
      }
      f.shell.setSidebarWidth(42, animated: false)
      #expect(clip.superview === f.shell.overlay)
      f.shell.setSidebarWidth(190, animated: false)
      #expect(clip.superview === (reactOnTop ? f.shell.overlay : f.shell))
    }
  }

  @Test func anAutoHideTransitionKeepsRunningThroughTheRailParentRoundTrip() {
    let f = Fixture()
    let strip = AutoHideStripView(frame: .zero)
    strip.reduceMotion = false
    let style = AutoHideStripStyle(card: CSSColor("#FFFFFF")!, band: nil, divider: CSSColor("#000000")!,
      secondary: CSSColor("#000000")!, host: "example.com", hasPage: true)
    strip.set(style: style, mode: .shown, shownTop: 41)
    f.toolbar.onGeometryChange = { [weak toolbar = f.toolbar, weak strip] in
      if let toolbar, let strip { toolbar.placeBackdrop(strip) }
    }
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    var frames: [AutoHideFrame] = []
    var settled = false
    strip.onMotion = { if !$0 { settled = true } }
    strip.onFrame = { frame in
      frames.append(frame)
      f.toolbar.setAutoHide(opacity: CGFloat(frame.controlsOpacity), scale: CGFloat(frame.toolbarScale),
        lift: CGFloat(-frame.toolbarLift), interactive: frame.interactive)
    }
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    #expect(!settled)
    f.shell.setSidebarWidth(42, animated: false)
    f.shell.setSidebarWidth(190, animated: false)
    frames.removeAll()
    let deadline = Date().addingTimeInterval(0.8)
    while !settled, Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
    #expect(settled)
    #expect(!frames.isEmpty)
    #expect(frames.last?.controlsOpacity == 0)
    #expect(frames.last?.liveTop == strip.restingTop)
    #expect(f.toolbar.alphaValue == 0)
    #expect(strip.superview === f.toolbar.superview)
    strip.removeFromSuperview()
  }
}
