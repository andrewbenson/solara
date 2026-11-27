import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct WindowLayoutControllerTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse("{\"windows\":{\"w\":{\"id\":\"w\",\"profileId\":\"default\",\"sidebarOpen\":true,\"tabIds\":[\"a\"],\"activeTabIds\":{\"default\":\"a\"}}},\"tabs\":{\"a\":{\"id\":\"a\",\"windowId\":\"w\",\"profileId\":\"default\"}}}").object ?? [:])
  }

  @Test func restoringVisiblePanesWakesThemWithoutChangingSelection() throws {
    let store = Store(state: try state())
    let b = try #require(store.dispatch(Command("newTab", ["w", ["background": true]])).result?.string)
    let c = try #require(store.dispatch(Command("newTab", ["w", ["background": true]])).result?.string)
    try store.dispatch(Command("createSplit", [JSONValue(["a", b])]))
    try store.dispatch(Command("activate", ["a"]))
    try store.dispatch(Command("updateTab", [.string(b), ["url": "https://example.com/b", "navigation": .null, "unloaded": true]]))
    try store.dispatch(Command("updateTab", [.string(c), ["url": "https://example.com/c", "navigation": .null, "unloaded": true]]))
    let split = Splits.splitOf(store.state, "a")
    #expect(store.state.tabs[b].map(needsPage) == true)

    try store.dispatch(Command("prepareVisiblePanePages", [JSONValue(["w"])]))

    #expect(store.state.activeTabId("w") == "a")
    #expect(Splits.splitOf(store.state, "a") == split)
    #expect(store.state.tabs[b].map(needsPage) == false)
    #expect(store.state.tabs[c].map(needsPage) == true)
  }

  @Test func startsOnceAndStopsWithoutDestroyingRetainedPages() throws {
    let shell = WindowShellView(windowId: "w")
    let page = NSView()
    shell.cardPage.addSubview(page)
    let controller = WindowLayoutController(shell: shell, generation: 1, store: Store(state: try state()))
    var applies = 0
    var stops = 0
    controller.onState = { _, _ in applies += 1 }
    controller.onStop = { stops += 1 }
    controller.start()
    controller.start()
    #expect(controller.subscriptionCount == 1)
    FrameUpdates.flush()
    #expect(applies == 1)
    controller.stop()
    controller.stop()
    #expect(controller.subscriptionCount == 0 && stops == 1)
    #expect(shell.cardPage.subviews.first === page)
  }

  @Test func hostBeforeStateWaitsForPresenceAndThenEndsOnRemoval() throws {
    let controller = WindowLayoutController(shell: WindowShellView(windowId: "w"), generation: 2, store: Store())
    var removals = 0
    var revisions: [Int] = []
    controller.onState = { _, revision in revisions.append(revision) }
    controller.onRemoved = { removals += 1 }
    controller.start()
    FrameUpdates.flush()
    #expect(removals == 0 && revisions.isEmpty)
    controller.receive(try state(), revision: 1, generation: 2)
    FrameUpdates.flush()
    #expect(revisions == [1] && removals == 0)
    controller.receive(BrowserState(), revision: 2, generation: 2)
    FrameUpdates.flush()
    #expect(removals == 1 && controller.stopped)
  }

  @Test func reloadRejectsLateOldGenerationAndOldClose() throws {
    let lifetimes = ShellLifetimes<WindowLayoutController> { $0.stop() }
    let store = Store(state: try state())
    let old = WindowLayoutController(shell: WindowShellView(windowId: "w"), generation: 3, store: store)
    let current = WindowLayoutController(shell: WindowShellView(windowId: "w"), generation: 4, store: store)
    var oldApplies = 0
    var newApplies = 0
    old.onState = { _, _ in oldApplies += 1 }
    current.onState = { _, _ in newApplies += 1 }
    old.start()
    lifetimes.adopt("w", old)
    current.start()
    lifetimes.adopt("w", current)
    old.receive(try state(), revision: 50, generation: 3)
    current.receive(try state(), revision: 50, generation: 3)
    lifetimes.end("w", ifHost: old)
    FrameUpdates.flush()
    #expect(old.stopped && oldApplies == 0 && old.subscriptionCount == 0)
    #expect(lifetimes.host("w") === current && newApplies == 1)
    lifetimes.end("w", ifHost: current)
    #expect(current.stopped && current.subscriptionCount == 0)
  }

  @Test func retainedLastWindowAndModeSwitchesKeepChromeAndPageIdentity() throws {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let sidebar = NSView(), strip = NSView(), page = NSView()
    shell.mount(.sidebar, sidebar)
    shell.mount(.topStrip, strip)
    shell.cardPage.addSubview(page)
    var state = try state()
    let controller = WindowLayoutController(shell: shell, generation: 5, store: Store(state: state))
    controller.onState = { state, revision in
      if let input = WindowLayoutInput(state: state, windowId: "w", storeRevision: revision, bounds: shell.bounds) {
        shell.update { $0 = input.layout }
      }
    }
    controller.start()
    FrameUpdates.flush()
    for revision in 1...8 {
      state.windows["w"]?.tabLayout = revision.isMultiple(of: 2) ? "top" : "sidebar"
      controller.receive(state, revision: revision, generation: 5)
      FrameUpdates.flush()
    }
    shell.removeFromSuperview()
    #expect(!controller.stopped && controller.subscriptionCount == 1)
    #expect(shell.view(in: .sidebar) === sidebar && shell.view(in: .topStrip) === strip)
    #expect(shell.cardPage.subviews.first === page)
    #expect(shell.subviews.filter { $0 === sidebar }.count == 1)
    controller.stop()
  }

  @Test func stopRejectsQueuedCommitsAndCannotBeRestarted() throws {
    let controller = WindowLayoutController(shell: WindowShellView(windowId: "w"), generation: 6, store: Store(state: try state()))
    var revisions: [Int] = []
    controller.onState = { _, revision in revisions.append(revision) }
    controller.start()
    controller.receive(try state(), revision: 10, generation: 6)
    controller.stop()
    controller.start()
    controller.receive(try state(), revision: 11, generation: 6)
    FrameUpdates.flush()
    #expect(revisions.isEmpty && controller.subscriptionCount == 0)
  }

  @Test func stopCancelsMotionWhileTheWindowAndPagesStayAttached() throws {
    let shell = WindowShellView(windowId: "w")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    let page = NSView()
    shell.cardPage.addSubview(page)
    let controller = WindowLayoutController(shell: shell, generation: 9, store: Store(state: try state()))
    controller.start()
    shell.setSidebarWidth(260, animated: true)
    shell.setSidePanelRoom(300, open: true, animated: true)
    controller.stop()
    #expect(!shell.widthMoving && !shell.sidePanelMoving)
    #expect(shell.window === window && shell.cardPage.subviews.first === page)
    window.contentView = nil
    window.close()
  }

  @Test func layoutPublicationBelongsToTheControllerGeneration() throws {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let controller = WindowLayoutController(shell: shell, generation: 8, store: Store(state: try state()))
    controller.start()
    let input = try #require(WindowLayoutInput(state: state(), windowId: "w", windowGeneration: 8, storeRevision: 1, bounds: shell.bounds))
    #expect(controller.apply(input: input))
    #expect(controller.anchors.current?.generation == 1)
    #expect(shell.frames.card == WindowLayoutSnapshot.of(input, generation: 1).frames.card)
    #expect(!controller.apply(input: input))
    let foreign = try #require(WindowLayoutInput(state: state(), windowId: "w", windowGeneration: 7, storeRevision: 2, bounds: shell.bounds))
    #expect(!controller.apply(input: foreign))
    controller.receive(try state(), revision: 3, generation: 8)
    #expect(!controller.apply(input: input))
    controller.stop()
    #expect(controller.anchors.current == nil)
    #expect(!controller.apply(input: input))
  }

  @Test func revisionsAreMonotonicAndQueuedUpdatesCoalesce() throws {
    let controller = WindowLayoutController(shell: WindowShellView(windowId: "w"), generation: 7, store: Store())
    var revisions: [Int] = []
    controller.onState = { _, revision in revisions.append(revision) }
    controller.start()
    controller.receive(try state(), revision: 4, generation: 7)
    controller.receive(try state(), revision: 3, generation: 7)
    controller.receive(try state(), revision: 4, generation: 7)
    FrameUpdates.flush()
    #expect(revisions == [4])
    controller.stop()
  }

  @Test(arguments: [false, true])
  func nativeLayoutKeepsToolbarAboveEarlierBackgroundsAndBelowItsOverlayPeek(windowToolbar: Bool) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let fixture = ToolbarResizeTests.Fixture(bare: !windowToolbar, reactOnTop: true)
    fixture.window.alphaValue = 0
    fixture.window.level = NSWindow.Level(rawValue: -1_000_000)
    fixture.window.orderBack(nil)
    defer { fixture.window.close() }
    let shell = fixture.shell
    var toolbarState = fixture.toolbar.state!
    toolbarState.windowToolbar = windowToolbar
    toolbarState.geometry.urlRight = 8
    fixture.toolbar.update(toolbarState)
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"toolbar-resize":{"id":"toolbar-resize","profileId":"default","sidebarOpen":false,"tabLayout":"top","tabIds":["a"],"activeTabIds":{"default":"a"}}},"tabs":{"a":{"id":"a","windowId":"toolbar-resize","profileId":"default"}}}"#).object ?? [:])
    let controller = WindowLayoutController(shell: shell, generation: 10, store: Store(state: state))
    controller.start()
    defer { controller.stop() }
    let input = try #require(WindowLayoutInput(state: state, windowId: shell.windowId, windowGeneration: 10, storeRevision: 1, bounds: shell.bounds))
    #expect(controller.apply(input: input))
    let root = try #require(shell.view(in: .react))
    let background = NSView(frame: root.bounds)
    root.addSubview(background, positioned: .below, relativeTo: fixture.owner)
    let peek = StripPeekView(frame: shell.overlay.bounds)
    peek.peek.schedule = { _, run in run(); return nil }
    let row = StripPeekRow(strip: TopStripView(windowId: shell.windowId))
    row.controls.update(StripControlsState(title: "Default", incognito: false, profiles: 1, nameColor: "#000000", downloadsOpen: false, downloadsTooltip: "Downloads"), theme: [:])
    peek.content = row
    shell.overlay.addSubview(peek)
    defer { peek.stop() }
    peek.setEnabled(true)
    peek.peek.show()
    peek.pin(1)
    peek.layoutSubtreeIfNeeded()
    let clip = try #require(fixture.toolbar.superview)
    #expect(clip.superview === fixture.owner)
    #expect(fixture.toolbarRect.minX == shell.frames.card.minX)
    var actions: [StripControlAction] = []
    var clicks: [String] = []
    row.controls.onAction = { actions.append($0) }
    fixture.toolbar.onClick = { clicks.append($0.id) }
    func click(_ point: CGPoint) throws {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        fixture.window.sendEvent(event)
      }
    }
    let downloads = try #require(row.controls.downloadsRect)
    try click(CGPoint(x: downloads.midX, y: downloads.midY))
    #expect(actions == [.toggleDownloads])
    #expect(clicks.isEmpty)
    peek.isHidden = true
    let field = try #require(ToolbarWebKitPillTests.fieldIn(fixture.toolbar))
    try click(field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
    #expect(clicks == ["url"])
  }
}
