import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarResizeTests {
  @Test(arguments: [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 31, height: 31),
    CGSize(width: 32, height: 32), CGSize(width: 42, height: 42), CGSize(width: 84, height: 48)])
  func compactAndRevealedToolbarsLeaveEmptyPagesWhenTheWindowIsTooSmall(size: CGSize) {
    let fixture = Fixture(bare: false)
    defer { fixture.window.contentView = nil; fixture.window.close() }
    fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
    fixture.shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
    fixture.shell.frame.size = size
    fixture.shell.setSidebarWidth(42, animated: false)
    #expect(fixture.shell.frames.page.height == (size.height == 48 ? 9 : size.height == 42 ? 3 : 0))
    for topTabs in [false, true] {
      fixture.shell.update { $0.topTabs = topTabs }
      fixture.shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 37)
      let page = fixture.shell.cardPage.convert(fixture.shell.cardPage.bounds, to: fixture.shell)
      for reveal: CGFloat in [0.5, 1, 0] {
        fixture.shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 37)
        fixture.toolbar.layoutSubtreeIfNeeded()
        #expect(fixture.shell.cardPage.convert(fixture.shell.cardPage.bounds, to: fixture.shell) == page)
        let rects = [fixture.shell.cardClip.frame, fixture.shell.cardRim.edgeRect,
          fixture.shell.cardShadow.edgeRect, fixture.toolbarRect] + Array(fixture.toolbar.layoutAnchors.values)
        #expect(rects.allSatisfy {
          $0.origin.x.isFinite && $0.origin.y.isFinite && $0.size.width.isFinite && $0.size.height.isFinite
            && $0.size.width >= 0 && $0.size.height >= 0
        })
      }
    }
  }

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

  @Test(arguments: [false, true])
  func oneResizeEventPlacesTheWindowToolbarAndItsControlsWithThePage(reactOnTop: Bool) throws {
    let f = Fixture(reactOnTop: reactOnTop)
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

  @Test(arguments: [false, true])
  func delayedOwnerLayoutCannotMoveTheToolbarAndMouseUpKeepsTheFinalGeometry(reactOnTop: Bool) {
    let f = Fixture(reactOnTop: reactOnTop)
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
    #expect(f.toolbarRect.minX == 0)
    #expect(f.toolbarRect.maxX == f.shell.bounds.maxX)
    #expect(f.toolbarRect.height == 32)
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

  @Test(arguments: [CGFloat(0), 1])
  func iconToolbarCentersEveryControlWithinItsBand(_ dock: CGFloat) throws {
    let f = Fixture(bare: false)
    defer { f.window.close() }
    var state = ToolbarWebKitPillTests.state(extensions: ToolbarWebKitPillTests.pill)
    state.height = 41
    state.windowToolbar = true
    state.update = try JSONDecoder().decode(ToolbarUpdateState.self, from: Data(#"{"text":"Update available","short":"Update","tooltip":"Install update"}"#.utf8))
    f.toolbar.update(state)
    f.shell.update { $0.dock = dock }
    f.shell.setSidebarWidth(CGFloat(SidebarRail.width), animated: false)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    f.toolbar.layoutSubtreeIfNeeded()
    let row = f.toolbarRect
    #expect(row.minY == 0 && row.maxY == 32)
    for button in ToolbarWebKitPillTests.buttons(in: f.toolbar) where !button.isHiddenOrHasHiddenAncestor {
      #expect(abs(button.convert(button.bounds, to: f.shell).midY - row.midY) <= 0.5)
    }
    let field = try #require(ToolbarWebKitPillTests.fieldIn(f.toolbar))
    #expect(field.convert(field.bounds, to: f.shell).midY == row.midY)
    let update = try #require(f.toolbar.subviews.flatMap(\.subviews).compactMap { $0 as? SidebarUpdatePill }.first)
    #expect(!update.isHidden)
    #expect(abs(update.convert(update.bounds, to: f.shell).midY - row.midY) <= 0.5)
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
    #expect(strip.convert(strip.bounds, to: f.shell).minY == f.toolbarRect.minY + ShellMetrics.railToolbarTop)
    #expect(strip.frame.height == 32)
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

  @Test(arguments: [false, true])
  func controlsOutsideTheStaleOwnerStillReceiveHits(reactOnTop: Bool) throws {
    let f = Fixture(reactOnTop: reactOnTop)
    f.shell.cardPage.addSubview(NSView(frame: f.shell.cardPage.bounds))
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

  @Test(arguments: [false, true])
  func ordinaryToolbarPaintsAboveEarlierReactBackgroundsAndOutsideItsStaleOwner(windowToolbar: Bool) throws {
    let f = Fixture(bare: !windowToolbar, reactOnTop: true)
    defer { f.window.close() }
    var state = f.toolbar.state!
    state.windowToolbar = windowToolbar
    f.toolbar.update(state)
    let react = try #require(f.shell.view(in: .react))
    let background = NSView(frame: react.bounds)
    background.wantsLayer = true
    background.layer?.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor
    react.addSubview(background, positioned: .below, relativeTo: f.owner)
    let marker = CALayer()
    marker.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    f.toolbar.layer?.addSublayer(marker)
    f.shell.setSidebarWidth(120, animated: false)
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    marker.frame = f.toolbar.bounds
    f.shell.displayIfNeeded()
    CATransaction.flush()
    let layer = try #require(f.shell.layer)
    let first = try DeveloperStripesTests.rendered(layer, f.shell.bounds, scale: 1)
    let toolbar = try #require(first.colorAt(x: 150, y: first.pixelsHigh - 20)?.usingColorSpace(.sRGB))
    #expect(toolbar.redComponent > 0.95)
    #expect(toolbar.blueComponent < 0.05)
    #expect(f.owner.frame.minX == 190)
    #expect(f.toolbarRect.minX == 120)
    let peek = NSView(frame: CGRect(x: 120, y: 6, width: 200, height: 41))
    peek.wantsLayer = true
    peek.layer?.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
    react.addSubview(peek)
    f.shell.displayIfNeeded()
    CATransaction.flush()
    let second = try DeveloperStripesTests.rendered(layer, f.shell.bounds, scale: 1)
    let covered = try #require(second.colorAt(x: 150, y: second.pixelsHigh - 20)?.usingColorSpace(.sRGB))
    #expect(covered.greenComponent > 0.95)
    #expect(covered.redComponent < 0.05)
  }

  @Test func shellToolbarLayeringMatchesTheReactRootAndRailRoundTrip() throws {
    for reactOnTop in [false, true] {
      let f = Fixture(reactOnTop: reactOnTop)
      let peek = FlippedContainerView()
      f.shell.mount(.peek, peek)
      f.shell.registerToolbar(f.toolbar, owner: f.owner)
      let clip = try #require(f.toolbar.superview)
      if reactOnTop {
        #expect(clip.superview === f.owner)
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
      #expect(clip.superview === (reactOnTop ? f.owner : f.shell))
    }
  }

  @Test(arguments: [false, true], [false, true])
  func aLiveStripPeekReceivesWindowClicksAboveTheWindowToolbar(reactOnTop: Bool, windowToolbar: Bool) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let f = Fixture(bare: !windowToolbar, reactOnTop: reactOnTop)
    f.window.alphaValue = 0
    f.window.level = NSWindow.Level(rawValue: -1_000_000)
    f.window.orderBack(nil)
    defer { f.window.close() }
    var state = f.toolbar.state!
    state.windowToolbar = windowToolbar
    state.geometry.urlRight = 8
    f.toolbar.update(state)
    f.shell.update { $0.topTabs = true; $0.dock = 0 }
    f.shell.registerToolbar(f.toolbar, owner: f.owner)
    let react = try #require(f.shell.view(in: .react))
    let dragRegion = NSView(frame: react.bounds)
    react.addSubview(dragRegion, positioned: .below, relativeTo: f.owner)
    let peek = StripPeekView(frame: f.shell.bounds)
    peek.peek.schedule = { _, run in run(); return nil }
    let row = StripPeekRow(strip: TopStripView(windowId: f.shell.windowId))
    row.controls.update(StripControlsState(title: "Default", incognito: false, profiles: 1, nameColor: "#000000", downloadsOpen: false, downloadsTooltip: "Downloads"), theme: [:])
    peek.content = row
    if reactOnTop {
      f.shell.view(in: .react)!.addSubview(peek)
    } else {
      f.shell.mount(.peek, peek)
      peek.frame = f.shell.bounds
    }
    peek.setEnabled(true)
    peek.peek.show()
    peek.pin(1)
    peek.layoutSubtreeIfNeeded()
    var actions: [StripControlAction] = []
    var clicks: [String] = []
    row.controls.onAction = { actions.append($0) }
    f.toolbar.onClick = { clicks.append($0.id) }
    func click(_ point: CGPoint) throws {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        f.window.sendEvent(event)
      }
    }
    let downloads = try #require(row.controls.downloadsRect)
    try click(CGPoint(x: downloads.midX, y: downloads.midY))
    #expect(actions == [.toggleDownloads])
    #expect(clicks.isEmpty)
    if reactOnTop { #expect(f.shell.slotUnderPointer(at: CGPoint(x: downloads.midX, y: downloads.midY)) == .react) }
    let overlay = ToolbarButtonView(state: try JSONDecoder().decode(ToolbarButtonState.self, from: Data(#"{"id":"overlay","icon":"xmark"}"#.utf8)), palette: state.palette)
    overlay.frame = f.shell.overlay.convert(downloads, from: nil)
    overlay.onClick = { clicks.append($0.id) }
    f.shell.overlay.addSubview(overlay)
    try click(CGPoint(x: downloads.midX, y: downloads.midY))
    #expect(clicks == ["overlay"])
    #expect(actions == [.toggleDownloads])
    overlay.removeFromSuperview()
    clicks.removeAll()
    peek.isHidden = true
    let field = try #require(ToolbarWebKitPillTests.fieldIn(f.toolbar))
    try click(field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
    #expect(clicks == ["url"])
    if reactOnTop { #expect(f.shell.slotUnderPointer(at: field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)) != .react) }
    peek.setEnabled(false)
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

@MainActor
struct ToolbarSeparatorTests {
  @Test(arguments: [false, true], [false, true])
  func separatorReachesBothCardEdgesWithoutBottomCornerClipping(reactOnTop: Bool, autoHide: Bool) throws {
    let f = ToolbarResizeTests.Fixture(bare: autoHide, reactOnTop: reactOnTop)
    defer { f.window.close() }
    var state = f.toolbar.state!
    state.bare = autoHide
    state.windowToolbar = true
    state.hairline = !autoHide
    state.palette.background = "#FFFFFF"
    state.palette.divider = "#FF0000"
    state.stripes = nil
    state.left = []
    state.right = []
    state.url = nil
    f.toolbar.update(state)
    let strip = AutoHideStripView(frame: .zero)
    strip.reduceMotion = true
    if autoHide {
      strip.set(style: AutoHideStripStyle(card: CSSColor("#FFFFFF")!, band: nil, divider: CSSColor("#FF0000")!,
        secondary: CSSColor("#000000")!, host: "example.com", hasPage: true), mode: .shown, shownTop: 41)
      f.toolbar.onGeometryChange = { [weak toolbar = f.toolbar, weak strip] in
        if let toolbar, let strip { toolbar.placeBackdrop(strip) }
      }
    }
    for variant in ["sidebar", "caption", "hidden", "top", "icon"] {
      f.shell.update {
        $0.sidebarSide = variant == "caption" ? .right : .left
        $0.addressBarInSidebar = variant == "caption"
        $0.dock = variant == "hidden" ? 0 : 1
        $0.topTabs = variant == "top"
        $0.sidebarWidth = variant == "icon" ? 42 : 190
      }
      f.shell.setSidebarWidth(variant == "icon" ? 42 : 190, animated: false)
      f.shell.registerToolbar(f.toolbar, owner: f.owner)
      let clip = try #require(f.toolbar.superview)
      let clipLayer = try #require(clip.layer)
      #expect(clipLayer.masksToBounds)
      #expect(!clipLayer.maskedCorners.contains(.layerMinXMaxYCorner))
      #expect(!clipLayer.maskedCorners.contains(.layerMaxXMaxYCorner))
      f.toolbar.layoutSubtreeIfNeeded()
      strip.layoutSubtreeIfNeeded()
      let separator = try #require((autoHide ? strip.layer : f.toolbar.layer)?.sublayers?[1])
      #expect(separator.isHidden == (variant == "icon"))
      if variant == "icon" { continue }
      let separatorView: NSView = autoHide ? strip : f.toolbar
      let separatorRect = separatorView.convert(separator.frame, to: f.shell)
      #expect(separatorRect.minX == f.shell.frames.card.minX)
      #expect(separatorRect.maxX == f.shell.frames.card.maxX)
      f.shell.displayIfNeeded()
      CATransaction.flush()
      let scale = f.window.backingScaleFactor
      #expect(separator.frame.height == 1 / scale)
      #expect(separator.frame.maxY == separatorView.bounds.maxY)
      #expect(separator.cornerRadius == 0 && separator.mask == nil)
    }
  }
}
