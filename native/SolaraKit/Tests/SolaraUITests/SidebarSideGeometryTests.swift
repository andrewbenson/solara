import AppKit
import Testing
import SolaraModel
@testable import SolaraUI

@MainActor
struct SidebarSideGeometryTests {
  @Test func rightSidebarReflectsSpatialFramesAtBothScales() {
    for scale: CGFloat in [1, 2] {
      for width: CGFloat in [42, 190] {
        for dock: CGFloat in [0, 0.5, 1] {
          let left = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: dock, sidebarWidth: width)
          var right = left
          right.sidebarSide = .right
          let a = DockedLayoutFrames.of(left)
          let b = DockedLayoutFrames.of(right)
          #expect(abs(b.card.minX - (1000 - a.card.maxX)) * scale < 0.01)
          #expect(abs(b.page.minX - (1000 - a.page.maxX)) * scale < 0.01)
          #expect(b.sidebar!.minX == 1000 - a.sidebar!.maxX)
          #expect(b.sidebarShift == -a.sidebarShift)
        }
      }
    }
  }

  @Test func rightPeekCoverageFollowsTheVisibleRect() {
    for width: CGFloat in [42, 190] {
      var input = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: 0, sidebarWidth: width, peeking: true, peekSlide: 0.5)
      input.sidebarSide = .right
      let frames = DockedLayoutFrames.of(input)
      let coverage = frames.sidebarCoverage(in: CGRect(origin: .zero, size: input.size))!
      #expect(coverage.minX > 800)
      #expect(coverage.maxX <= 1000)
      #expect(coverage.contains(CGPoint(x: coverage.midX, y: coverage.midY)))
      #expect(!coverage.contains(CGPoint(x: 100, y: 300)))
      #expect(coverage.contains(CGPoint(x: coverage.midX, y: 0)) == SidebarRail.contains(width: Double(width)))
      #expect(!coverage.contains(CGPoint(x: coverage.midX, y: coverage.minY - 1)))
    }
  }

  @Test func rightLightsStayOnThePhysicalLeftDuringMotion() {
    for rail: CGFloat in [42, 190] {
      for dock: CGFloat in [0, 0.5, 1] {
        for slide: CGFloat in [0, 0.5, 1] {
          var input = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: dock, sidebarWidth: rail, peeking: true, peekSlide: slide)
          input.sidebarSide = .right
          #expect((DockMotion.sidebarLightsCenter(input) ?? ShellMetrics.lightsCenter).x == ShellMetrics.lightsCenter.x)
        }
      }
    }
  }

  @Test func fullRightLightsStayCenteredWhileDockingAndPeekWithTheExistingMotionSample() throws {
    var input = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: 0, sidebarSide: .right)
    let hidden = try #require(DockMotion.sidebarLightsCenter(input))
    #expect(hidden.x == 25)
    #expect(hidden.y == ShellMetrics.lightsCenter.y)
    input.dock = 0.5
    #expect(DockMotion.sidebarLightsCenter(input)?.y == ShellMetrics.lightsCenter.y)
    input.dock = 1
    #expect(DockMotion.sidebarLightsCenter(input)?.y == ShellMetrics.lightsCenter.y)
    input.dock = 0
    input.peeking = true
    input.peekSlide = 0
    #expect(DockMotion.sidebarLightsCenter(input)!.y < 0)
    input.peekSlide = 1
    #expect(DockMotion.sidebarLightsCenter(input)?.y == ShellMetrics.lightsCenter.y + ShellMetrics.peekOrigin.y)
    input.sidebarWidth = 42
    input.peekSlide = 0
    #expect(DockMotion.sidebarLightsCenter(input)?.y == ShellMetrics.railLightsCenter.y)
    input.sidebarWidth = 190
    input.fullscreen = true
    #expect(DockMotion.sidebarLightsCenter(input)?.y == ShellMetrics.lightsCenter.y)
  }

  @Test func rightFolderDragFeedbackSnapsToTheBarsRightInset() throws {
    let shell = WindowShellView(windowId: "bookmark-feedback")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.update { $0.sidebarSide = .right }
    let bar = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    bar.frame = CGRect(x: 7, y: 100, width: 803, height: 30)
    shell.overlay.addSubview(bar)
    bar.update(BookmarksBarSnapshot(profileId: "default", items: [BookmarksBarItem(id: "f", kind: .folder, title: "Folder")], hasOther: false, hideBookmarksBarImport: false, theme: [:]))
    bar.layoutSubtreeIfNeeded()
    let button = try #require(bar.subviews.compactMap { $0 as? BookmarksBarButton }.first)
    let original = button.frame
    let down = CGPoint(x: original.midX, y: original.midY)
    let end = bar.convert(CGPoint(x: 900, y: 115), from: shell)
    button.beginPress(at: down, flags: [])
    button.dragPress(to: end)
    #expect(button.highlighted)
    #expect(button.frame.maxX == bar.bounds.maxX - 8)
    #expect(button.frame.width == original.width)
    bar.cancelOperation(nil)
    #expect(button.frame == original)
  }

  @Test func legacyPageSlotKeepsItsNegativeTop() {
    let shell = WindowShellView(windowId: "legacy-negative-top")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.cardPageFrame = CGRect(x: 0, y: -12, width: 803, height: 699)
    #expect(shell.cardPage.frame.minY == -12)
    #expect(shell.cardPage.frame.height == 699)
  }

  @Test func rightPanelSitsBetweenTheSidebarAndUsableContent() {
    for width: CGFloat in [42, 190] {
      var input = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: 1, sidebarWidth: width, sidePanel: 300)
      input.sidebarSide = .right
      let frames = DockedLayoutFrames.of(input)
      #expect(frames.sidePanel!.maxX <= frames.sidebar!.minX)
      #expect(frames.page.maxX <= frames.sidePanel!.minX)
      #expect(frames.card.maxX <= frames.sidePanel!.minX)
      #expect(frames.page.width >= ShellMetrics.minPane)
      input.size.width = 550
      input.sidePanel = 500
      let narrow = DockedLayoutFrames.of(input)
      #expect(narrow.page.width >= ShellMetrics.minPane)
      #expect(narrow.sidePanel!.maxX <= narrow.sidebar!.minX)
    }
  }

  @Test func folderDropCoverageUsesBothAxesOnTheRight() {
    let items = [BookmarksBarItem(id: "folder", kind: .folder, title: "Folder")]
    let visible = [BookmarksBarLayout.Placement(index: 0, frame: CGRect(x: 8, y: 3, width: 100, height: 24))]
    let coverage = CGRect(x: 810, y: 5, width: 190, height: 690)
    let target = { (point: CGPoint) in
      BookmarksBarDropTarget.resolve(id: "folder", items: items, visible: visible, deltaX: 0, pointerX: point.x, sidebarEdge: 900, sidebarCoverage: coverage, pointerY: point.y)
    }
    #expect(target(CGPoint(x: 900, y: 350)) == .sidebar)
    #expect(target(CGPoint(x: 100, y: 350)) != .sidebar)
    #expect(target(CGPoint(x: 900, y: 0)) != .sidebar)
    #expect(target(CGPoint(x: 1000, y: 350)) != .sidebar)
  }

  @Test func rightRailRemainsHittableBesideAnExtensionPanel() {
    let shell = WindowShellView(windowId: "right-rail")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.update { $0.sidebarSide = .right; $0.sidebarWidth = 42; $0.sidePanel = 300 }
    let sidebar = NSView()
    shell.mount(.sidebar, sidebar)
    #expect(sidebar.superview === shell)
    #expect(shell.hitTest(CGPoint(x: 980, y: 300)) === sidebar)
    #expect(shell.frames.sidePanel!.maxX <= sidebar.frame.minX)
  }

  @Test func nativeProjectionPublishesInwardPopoverAndCaptionAnchors() throws {
    var state = BrowserState()
    state.windows["w"] = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    state.windows["w"]?.sidebarPosition = "right"
    state.windows["w"]?.activeTabIds = ["default": "a"]
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "about:blank", now: 0)
    state.settings["addressBar"] = "sidebar"
    let presentation = DockedLayoutInput(size: CGSize(width: 1000, height: 700), dock: 0, peeking: true, peekSlide: 1)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), backingScale: 2, presentation: presentation))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(input.presentation.sidebarSide == .right)
    let legacy = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: input.bounds, presentation: presentation, sidebarPositionAllowed: false))
    #expect(legacy.layout.sidebarSide == .left && legacy.presentation.sidebarSide == .left)
    #expect(WindowLayoutSnapshot.of(legacy, generation: 1).anchors["sidebar"]!.minX == 5)
    #expect(state.windows["w"]?.sidebarPosition == "right")
    let popover = try #require(snapshot.anchors["peekPopover:popups"])
    #expect(popover.maxX <= snapshot.anchors["sidebar"]!.minX - 8)
    #expect(popover.minY == snapshot.contentPanes["a"]!.minY + 8)
    state.settings["addressBar"] = "toolbar"
    let toolbarInput = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: input.bounds))
    let toolbarSnapshot = WindowLayoutSnapshot.of(toolbarInput, generation: 1)
    #expect(toolbarSnapshot.residualURLBand(tabId: "a", trailingReservation: 0)!.minX > ShellMetrics.railLightsTrailing)
  }

  @Test func sideChangesRearmTheWatcherAndEndAnExistingPeek() {
    let rig = SidebarDockTests.Rig(SidebarDockState(open: false, sidebarPosition: "left"))
    defer { rig.dock.stop() }
    rig.dock.edge(over: true)
    rig.settle()
    #expect(rig.dock.peek.live)
    var watches: [(CGFloat?, SidebarSide)] = []
    rig.dock.onWatch = { watches.append(($0, rig.shell.input.sidebarSide)) }
    rig.set { $0.sidebarPosition = "right" }
    #expect(!rig.dock.peek.live)
    #expect(rig.shell.input.sidebarSide == .right)
    #expect(watches.contains { $0.0 == nil })
    #expect(watches.contains { $0.0 == ShellMetrics.edgeStripWidth && $0.1 == .right })
    #expect(watches.last?.0 == ShellMetrics.edgeStripWidth)
    rig.useManualTimers()
    rig.dock.edge(over: true)
    rig.settle()
    #expect(rig.dock.panel.frame.maxX == rig.shell.bounds.maxX - ShellMetrics.peekOrigin.x)
    #expect(watches.last?.0 == ShellMetrics.peekOrigin.x + ShellMetrics.sidebarWidth + ShellMetrics.holdSlack)
  }

  @Test func rightResizeUsesTheInwardHandleAndLeftwardWidthDrag() {
    let shell = WindowShellView(windowId: "right-resize")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.update { $0.sidebarSide = .right; $0.sidebarWidth = 220 }
    let chrome = SidebarChromeView(frame: CGRect(x: 0, y: 0, width: 220, height: 700))
    shell.mount(.sidebar, chrome)
    var state = SidebarChromeTests().state()
    state.sidebarPosition = "right"
    chrome.update(state)
    #expect(chrome.resize.frame.minX == 0)
    var actions: [SidebarChromeAction] = []
    chrome.onAction = { actions.append($0) }
    let event = { (kind: NSEvent.EventType, x: CGFloat) in NSEvent.mouseEvent(with: kind, location: CGPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
    chrome.resize.mouseDown(with: event(.leftMouseDown, 780))
    chrome.resize.mouseDragged(with: event(.leftMouseDragged, 760))
    chrome.resize.mouseUp(with: event(.leftMouseUp, 760))
    #expect(actions.contains(.commitWidth(240)))
    #expect(!chrome.resize.dragging)
  }

  @Test func rightSidebarCaptionHasASeparateRowAboveTheCard() throws {
    var state = BrowserState()
    state.windows["caption"] = BrowserWindow(id: "caption", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    state.windows["caption"]?.activeTabIds = ["default": "a"]
    state.windows["caption"]?.tabIds = ["a"]
    state.tabs["a"] = Tab(id: "a", windowId: "caption", profileId: "default", url: "about:blank", now: 0)
    let shell = WindowShellView(windowId: "caption")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.update { $0.sidebarSide = .right; $0.addressBarInSidebar = true }
    for top: CGFloat in [0, 41, 0, 70] {
      shell.cardPageFrame = CGRect(x: 0, y: top, width: shell.card.bounds.width, height: shell.card.bounds.height - top)
      #expect(shell.cardPage.frame.minY == top)
      #expect(shell.frames.card.minY == ShellMetrics.cardTop + ShellMetrics.toolbarHeight)
    }
    let overlays = PaneOverlaysView(windowId: "caption")
    overlays.frame = shell.card.bounds
    shell.card.addSubview(overlays)
    defer { overlays.removeFromSuperview() }
    overlays.toolbarHeight = 0
    overlays.pageTops = ["a": 0]
    overlays.update(state: state)
    overlays.layoutSubtreeIfNeeded()
    let slot = try #require(overlays.container("a", layer: .native))
    #expect(slot.convert(slot.bounds, to: shell.card).minY == 0)
    shell.cardPageFrame = CGRect(origin: .zero, size: shell.card.bounds.size)
    #expect(shell.cardPage.frame.minY == 0)
    shell.update { $0.sidebarSide = .left }
    overlays.layoutSubtreeIfNeeded()
    #expect(shell.cardPage.frame.minY == 0)
    #expect(slot.convert(slot.bounds, to: shell.card).minY == 0)
  }

  @Test func inwardResizeDeltaAndAttachmentDoNotReverseContents() {
    #expect(SidebarSide.left.widthDelta(20) == 20)
    #expect(SidebarSide.right.widthDelta(-20) == 20)
    let anchor = CGRect(x: 820, y: 100, width: 170, height: 37)
    let origin = SidebarAttachment.origin(anchor: anchor, size: CGSize(width: 280, height: 120), visible: CGRect(x: 0, y: 0, width: 1000, height: 700), side: .right, gap: 8)
    #expect(origin.x == 532)
    #expect(origin.y == 58.5)
    let group = SidebarAttachment.origin(anchor: anchor, size: CGSize(width: 280, height: 200), visible: CGRect(x: 0, y: 0, width: 1000, height: 700), side: .right, preferredY: 94)
    #expect(group.x == 532 && group.y == 94)
    let grown = SidebarAttachment.origin(anchor: anchor, size: CGSize(width: 280, height: 650), visible: CGRect(x: 0, y: 0, width: 1000, height: 700), side: .right, preferredY: 94)
    #expect(grown.y == 42)
  }
}
