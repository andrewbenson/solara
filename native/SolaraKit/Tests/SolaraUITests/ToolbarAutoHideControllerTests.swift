import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct ToolbarAutoHideControllerTests {
  @Test(arguments: [false, true])
  func hoverTimelineRejectsRetiredPresentation(nativeLayout: Bool) throws {
    let controller = ToolbarAutoHideController(windowId: "w", windowGeneration: nativeLayout ? 2 : 1)
    let page = PageRegistration(tabID: "a", registrationGeneration: 1)
    controller.register(page)
    controller.present(["a"])
    #expect(controller.noteScroll(page, state: "down"))
    let target = try #require(controller.actionTarget("a"))
    #expect(controller.apply(.peek(true), from: target))
    #expect(controller.facts["a"]?.peek == true)
    controller.present(["b"])
    controller.present(["a"])
    #expect(!controller.apply(.reveal, from: target))
    #expect(controller.facts["a"]?.scrolledDown == false)
    let replacement = PageRegistration(tabID: "a", registrationGeneration: 2)
    let previous = try #require(controller.actionTarget("a"))
    controller.register(replacement)
    #expect(!controller.apply(.peek(true), from: previous))
    let final = try #require(controller.actionTarget("a"))
    controller.stop()
    #expect(!controller.apply(.reveal, from: final))
  }

  @Test func pointerDeadlinesKeepTheFirstEntryAndCancelOnExit() {
    var hover = ToolbarAutoHideHover()
    hover.update(mode: .collapsed, inside: true, at: 0)
    hover.update(mode: .collapsed, inside: true, at: 0.1)
    #expect(hover.take(at: 0.149) == nil)
    #expect(hover.take(at: 0.15) == .peek(true))
    hover.update(mode: .peek, inside: false, at: 1)
    hover.update(mode: .peek, inside: true, at: 1.2)
    #expect(hover.take(at: 1.25) == nil)
    hover.update(mode: .peek, inside: false, at: 2)
    #expect(hover.take(at: 2.249) == nil)
    #expect(hover.take(at: 2.25) == .peek(false))
  }

  @Test func modePreservesTheExistingTruthTable() {
    let base = ToolbarAutoHideInput(enabled: true, hasPage: true, scrolledDown: true, peek: false, needsBar: false)
    #expect(base.mode == .collapsed)
    var input = base
    input.peek = true
    #expect(input.mode == .peek)
    input.needsBar = true
    #expect(input.mode == .shown)
    input = base
    input.enabled = false
    #expect(input.mode == .shown)
    input = base
    input.hasPage = false
    #expect(input.mode == .shown)
    input = base
    input.scrolledDown = false
    #expect(input.mode == .shown)
  }

  @Test func pageReportsRevealsAndPeeks() throws {
    let controller = ToolbarAutoHideController(windowId: "w", windowGeneration: 7)
    let registration = PageRegistration(tabID: "a", registrationGeneration: 1)
    controller.register(registration)
    #expect(controller.noteScroll(registration, state: "down"))
    #expect(controller.facts["a"]?.scrolledDown == true)
    #expect(!controller.noteScroll(registration, state: "sideways"))
    #expect(controller.facts["a"]?.scrolledDown == true)
    #expect(controller.setPeek(registration, on: true))
    #expect(controller.facts["a"]?.peek == true)
    #expect(controller.noteScroll(registration, state: "down"))
    #expect(controller.facts["a"]?.peek == false)
    #expect(controller.noteScroll(registration, state: "up"))
    #expect(controller.facts["a"]?.scrolledDown == false)
    #expect(controller.noteScroll(registration, state: "down"))
    #expect(controller.noteScroll(registration, state: "top"))
    #expect(controller.facts["a"]?.scrolledDown == false)
    #expect(controller.noteScroll(registration, state: "down"))
    #expect(controller.setPeek(registration, on: true))
    controller.reveal(tabId: "a")
    #expect(controller.facts["a"]?.scrolledDown == false)
    #expect(controller.facts["a"]?.peek == false)
    controller.retain(tabIds: [])
    #expect(controller.facts.isEmpty)
  }

  @Test func replacementCloseAndStopRejectRetiredPageFacts() {
    let controller = ToolbarAutoHideController(windowId: "w", windowGeneration: 7)
    let old = PageRegistration(tabID: "a", registrationGeneration: 1)
    let current = PageRegistration(tabID: "a", registrationGeneration: 2)
    controller.register(old)
    #expect(controller.noteScroll(old, state: "down"))
    #expect(controller.setFullscreen(old, on: true))
    controller.register(current)
    #expect(controller.facts["a"]?.fullscreen == false)
    #expect(controller.facts["a"]?.scrolledDown == false)
    #expect(!controller.noteScroll(old, state: "down"))
    #expect(!controller.setFullscreen(old, on: true))
    controller.retire(old)
    #expect(controller.facts["a"] != nil)
    controller.retire(current)
    #expect(controller.facts.isEmpty)
    controller.register(current)
    controller.stop()
    controller.register(old)
    #expect(!controller.noteScroll(current, state: "down"))
    #expect(controller.facts.isEmpty)
  }

  @Test func scrollThenCommandOrFindThenSwitchKeepsCurrentNativeHold() throws {
    var state = try fixture()
    let controller = ToolbarAutoHideController(windowId: "w", windowGeneration: 7)
    let a = PageRegistration(tabID: "a", registrationGeneration: 1)
    let b = PageRegistration(tabID: "b", registrationGeneration: 2)
    controller.register(a)
    controller.register(b)
    #expect(controller.noteScroll(a, state: "down"))
    #expect(controller.noteScroll(b, state: "down"))
    #expect(try snapshot(state, facts: controller.facts).toolbarModes["a"] == .collapsed)
    state.windowUi["w"] = WindowUi(json: ["panel": ["open": true]])
    let command = try snapshot(state, facts: controller.facts)
    #expect(command.toolbarModes["a"] == .shown)
    #expect(command.toolbarModes["b"] == .shown)
    state.windows["w"]?.activeTabIds["p"] = "b"
    state.windowUi["w"] = WindowUi()
    state.find["a"] = FindState(json: ["open": true])
    let switched = try snapshot(state, facts: controller.facts)
    #expect(switched.toolbarModes["a"] == .shown)
    #expect(switched.toolbarModes["b"] == .collapsed)
    #expect(switched.pages["a"]?.minY == switched.panes["a"]!.minY + 41)
    #expect(switched.pages["b"]?.minY == switched.panes["b"]!.minY + 20)
  }

  @Test func featureHoldsRevealOnlyTheirCurrentPane() throws {
    let state = try fixture()
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
      pageFacts: ["a": WindowLayoutPageFacts(scrolledDown: true), "b": WindowLayoutPageFacts(scrolledDown: true)], toolbarHolds: ["b", "missing"]))
    let value = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(value.toolbarModes["a"] == .collapsed)
    #expect(value.toolbarModes["b"] == .shown)
    #expect(input.toolbarHolds == ["b"])
  }

  @Test func fullscreenInEitherSplitPanePreservesSiblingAndExitsAfterClose() throws {
    for id in ["a", "b"] {
      var state = try fixture()
      let controller = ToolbarAutoHideController(windowId: "w", windowGeneration: 7)
      let registration = PageRegistration(tabID: id, registrationGeneration: 1)
      controller.register(registration)
      #expect(controller.setFullscreen(registration, on: true))
      let fullscreen = try snapshot(state, facts: controller.facts)
      #expect(fullscreen.fullscreenTabId == id)
      #expect(fullscreen.panes.count == 2)
      #expect(fullscreen.pages[id] == fullscreen.frames.card)
      let other = id == "a" ? "b" : "a"
      #expect(fullscreen.panes[other] != nil)
      #expect(fullscreen.toolbars[id]?.height == 0)
      state.tabs[id] = nil
      state.windows["w"]?.tabIds.removeAll { $0 == id }
      state.windows["w"]?.activeTabIds["p"] = other
      state.splits["s"] = nil
      let closed = try snapshot(state, facts: controller.facts)
      #expect(closed.fullscreenTabId == nil)
      #expect(!closed.input.layout.fullscreen)
    }
  }

  @Test func fullscreenInstallationKeepsSiblingPageAndNewerFieldResponder() throws {
    let state = try fixture()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    let panes = SplitPanesView(windowId: "w")
    window.contentView?.addSubview(panes)
    defer { panes.stop() }
    panes.install(try snapshot(state, facts: [:]), state: state)
    let a = try #require(panes.container("a"))
    let b = try #require(panes.container("b"))
    let page = NSView()
    a.addSubview(page)
    let field = ToolbarPresentationFocusView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    b.addSubview(field)
    #expect(window.makeFirstResponder(field))
    let full = try snapshot(state, facts: ["a": WindowLayoutPageFacts(fullscreen: true)])
    panes.install(full, state: state)
    #expect(panes.container("a") === a)
    #expect(panes.container("b") === b)
    #expect(page.superview === a)
    #expect(window.firstResponder === field)
    panes.install(try snapshot(state, facts: [:], width: 1200), state: state)
    #expect(panes.container("b") === b)
    #expect(window.firstResponder === field)
  }

  @Test func closingTheLastFullscreenTabClearsThePreviousPresentationSample() throws {
    var state = try fixture()
    state.tabs = Table<Tab>()
    state.windows["w"]?.tabIds = []
    state.windows["w"]?.activeTabIds = [:]
    state.splits["s"] = nil
    let size = CGSize(width: 1000, height: 700)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(origin: .zero, size: size),
      presentation: DockedLayoutInput(size: size, dock: 1, fullscreen: true)))
    #expect(!input.layout.fullscreen)
    #expect(!input.presentation.fullscreen)
    #expect(WindowLayoutSnapshot.of(input, generation: 1).frames.card != CGRect(origin: .zero, size: size))
  }

  @Test func peekFullscreenWinsAndRetainsUnderlyingSplit() throws {
    var state = try fixture()
    state.peeks["w"] = Peek(tabId: "c", sourceId: "a", sourcePage: "https://a.test", from: nil)
    let facts = ["a": WindowLayoutPageFacts(fullscreen: true), "c": WindowLayoutPageFacts(fullscreen: true)]
    let value = try snapshot(state, facts: facts)
    #expect(value.fullscreenTabId == "c")
    #expect(Set(value.panes.keys) == ["a", "b", "c"])
    #expect(value.pages["c"] == value.frames.card)
    let panes = SplitPanesView(windowId: "w")
    let overlays = PaneOverlaysView(windowId: "w")
    defer { panes.stop(); overlays.stop() }
    panes.install(value, state: state)
    overlays.install(value, state: state)
    #expect(panes.container("c") == nil)
    #expect(panes.container("a") != nil && panes.container("b") != nil)
    #expect(overlays.container("c", layer: .native)?.bounds.size == value.pages["c"]?.size)
    state.peeks["w"] = nil
    #expect(try snapshot(state, facts: facts).fullscreenTabId == "a")
  }

  @Test func resizeMidTransitionUsesOnePageAndOverlayTop() throws {
    let state = try fixture()
    let facts = ["a": WindowLayoutPageFacts(registration: "1", top: 29, band: 38, scrolledDown: true)]
    for width: CGFloat in [1000, 600, 1200] {
      let value = try snapshot(state, facts: facts, width: width)
      #expect(value.pages["a"]?.minY == value.panes["a"]!.minY + 67)
      #expect(value.anchors["page:a"] == value.pages["a"])
      #expect(value.toolbarModes["a"] == .collapsed)
    }
  }

  @Test func bookmarksAndEmptyPagePolicyAreNative() throws {
    var state = try fixture()
    state.splits["s"] = nil
    state.settings.values["bookmarksBar"] = .string("always")
    let facts = ["a": WindowLayoutPageFacts(scrolledDown: true)]
    let collapsed = try snapshot(state, facts: facts)
    #expect(collapsed.shownTops["a"] == 71)
    #expect(collapsed.pages["a"]?.minY == collapsed.panes["a"]!.minY + 20)
    state.tabs["a"]?.url = ""
    let empty = try snapshot(state, facts: facts)
    #expect(empty.toolbarModes["a"] == .shown)
    #expect(empty.pages["a"]?.minY == empty.panes["a"]!.minY + 71)
    state.windows["w"]?.incognito = true
    #expect(try snapshot(state, facts: facts).shownTops["a"] == 41)
  }

  @Test(arguments: [CGFloat(41), CGFloat(71)], [CGFloat(0), CGFloat(38)])
  func toolbarMotionResizesTheRendererOncePerHideAndShow(shownTop: CGFloat, band: CGFloat) throws {
    var state = try fixture()
    if shownTop == 71 {
      state.splits["s"] = nil
      state.settings["bookmarksBar"] = "always"
    }
    let panes = SplitPanesView(windowId: "w")
    let overlays = PaneOverlaysView(windowId: "w")
    let page = ToolbarResizeCountingPage()
    let pool = TabViewPool(make: { id, _ in id == "a" ? page : nil }, schedule: { $0() })
    defer { pool.update([]); panes.stop(); overlays.stop() }
    func install(top: CGFloat, down: Bool) throws {
      let value = try snapshot(state, facts: ["a": WindowLayoutPageFacts(top: top, band: band, scrolledDown: down)])
      panes.install(value, state: state)
      overlays.install(value, state: state)
      pool.reconcile()
      let slot = try #require(panes.container("a"))
      let overlay = try #require(overlays.container("a", layer: .native))
      #expect(slot.convert(slot.bounds, to: panes).minY == overlay.convert(overlay.bounds, to: overlays).minY)
      let leaf = try #require(panes.sample()["a"] as? [String: Any])
      let overlaySample = try #require(overlays.sample()["a"] as? [String: Any])
      let leafWindow = try #require(leaf["window"] as? [Double])
      let overlayWindow = try #require(overlaySample["window"] as? [Double])
      #expect(leafWindow == overlayWindow)
      let viewportFrame = try #require(leaf["viewport"] as? [Double])
      let visibleFrame = try #require(leaf["page"] as? [Double])
      #expect(viewportFrame[3] >= visibleFrame[3])
      #expect(page.view.superview === slot)
      #expect(pool.page("a") === page)
    }
    panes.install(try snapshot(state, facts: ["a": WindowLayoutPageFacts(band: band)]), state: state)
    overlays.install(try snapshot(state, facts: ["a": WindowLayoutPageFacts(band: band)]), state: state)
    pool.update([TabViewWanted(tabId: "a", windowId: "w", shown: .pane)])
    page.counted.sizes = []
    for fraction: CGFloat in [1, 0.75, 0.5, 0.25, 0] { try install(top: 20 + (shownTop - 20) * fraction, down: true) }
    #expect(page.counted.sizes.count == 1)
    let tallHeight = page.view.bounds.height
    page.counted.sizes = []
    for fraction: CGFloat in [0, 0.25, 0.5, 0.75] {
      try install(top: 20 + (shownTop - 20) * fraction, down: false)
      #expect(page.view.bounds.height == tallHeight)
    }
    try install(top: shownTop, down: false)
    #expect(page.counted.sizes.count == 1)
    #expect(page.view.bounds.height == tallHeight - (shownTop - 20))
  }

  @Test func reversalReducedMotionAndDisablingKeepTheRendererViewportStable() throws {
    var state = try fixture()
    let panes = SplitPanesView(windowId: "w")
    let page = ToolbarResizeCountingPage()
    let pool = TabViewPool(make: { id, _ in id == "a" ? page : nil }, schedule: { $0() })
    defer { pool.update([]); panes.stop() }
    func install(top: CGFloat?, down: Bool) throws {
      panes.install(try snapshot(state, facts: ["a": WindowLayoutPageFacts(top: top, scrolledDown: down)]), state: state)
      pool.reconcile()
    }
    try install(top: 41, down: false)
    pool.update([TabViewWanted(tabId: "a", windowId: "w", shown: .pane)])
    page.counted.sizes = []
    for (top, down) in [(CGFloat(31), true), (35, false), (28, true), (20, true)] { try install(top: top, down: down) }
    #expect(page.counted.sizes.count == 1)
    let tall = page.view.bounds.size
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    strip.reduceMotion = true
    let style = AutoHideStripStyle(card: try #require(CSSColor("#FFFFFF")), band: nil,
      divider: try #require(CSSColor("#00000020")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    strip.set(style: style, mode: .shown, shownTop: 41)
    page.counted.sizes = []
    try install(top: strip.presentationTop, down: false)
    #expect(page.counted.sizes.count == 1)
    #expect(page.view.bounds.height == tall.height - 21)
    strip.set(style: style, mode: .collapsed, shownTop: 41)
    try install(top: strip.presentationTop, down: true)
    #expect(page.view.bounds.size == tall)
    page.counted.sizes = []
    state.settings["hideToolbarWhileScrolling"] = false
    try install(top: nil, down: true)
    try install(top: nil, down: true)
    #expect(page.counted.sizes.count == 1)
    #expect(page.view.bounds.height == tall.height - 21)
    let fullscreen = try snapshot(state, facts: ["a": WindowLayoutPageFacts(fullscreen: true, top: 20, scrolledDown: true)])
    #expect(fullscreen.pageViewports["a"] == fullscreen.pages["a"])
  }

  @Test func spacesFullscreenAndTransitionDoNotBecomeRendererFullscreen() throws {
    var state = try fixture()
    state.windows["w"]?.fullScreen = 1
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), windowTransitioning: true))
    let value = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(input.windowFullscreen)
    #expect(input.windowFullscreenTransition)
    #expect(value.fullscreenTabId == nil)
    #expect(!input.layout.fullscreen)
    #expect(value.toolbars["a"]?.height == 41)
  }

  private func fixture() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"settings":{"hideToolbarWhileScrolling":true,"bookmarksBar":"never"},"windows":{"w":{"id":"w","profileId":"p","sidebarOpen":true,"tabIds":["a","b","c"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.test"},"b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.test"},"c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.test"}},"splits":{"s":{"id":"s","windowId":"w","tabIds":["a","b"],"orientation":"horizontal","sizes":[0.5,0.5]}}}"#).object ?? [:])
  }

  private func snapshot(_ state: BrowserState, facts: [String: WindowLayoutPageFacts], width: CGFloat = 1000) throws -> WindowLayoutSnapshot {
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: width, height: 700), pageFacts: facts))
    return .of(input, generation: 1)
  }
}

@MainActor
private final class ToolbarPresentationFocusView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class ToolbarResizeCountingView: NSView {
  var sizes: [CGSize] = []
  override func setFrameSize(_ newSize: NSSize) {
    if newSize != frame.size { sizes.append(newSize) }
    super.setFrameSize(newSize)
  }
}

@MainActor
private final class ToolbarResizeCountingPage: TabPoolPage {
  let counted = ToolbarResizeCountingView(frame: .zero)
  var view: NSView { counted }
  func setShown(_ shown: Bool) {}
  func focus() {}
  func retire() { view.removeFromSuperview() }
}
