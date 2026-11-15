import AppKit
import Testing
import SolaraModel
@testable import SolaraUI

@MainActor
struct PeekLifetimeTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse("""
      {"windows":{"w":{"id":"w","profileId":"default","sidebarOpen":true,"tabIds":["source"],"activeTabIds":{"default":"source"}}},"tabs":{"source":{"id":"source","windowId":"w","profileId":"default","url":"https://source.test/path#fragment"},"peek":{"id":"peek","windowId":"w","profileId":"default","url":"https://peek.test/page","title":"Preview"}},"peeks":{"w":{"tabId":"peek","sourceId":"source","sourcePage":"https://source.test/path","from":{"x":120,"y":80}}}}
      """).object ?? [:])
  }

  @Test func nativeProjectionUsesStoreAndCardCoordinates() throws {
    let state = try state()
    let peek = try #require(PeekState.native(state: state, windowId: "w", card: CGRect(x: 100, y: 10, width: 800, height: 600), tokens: [:], dark: false))
    #expect(peek.tabId == "peek" && peek.host == "peek.test" && peek.title == "Preview")
    #expect(peek.from == PeekPoint(x: 20, y: 70))
  }

  @Test func sourceNavigationAndWindowRemovalEndPresentation() throws {
    var state = try state()
    state.tabs["source"]?.url = "https://source.test/other"
    #expect(PeekState.native(state: state, windowId: "w", card: .zero, tokens: [:], dark: false) == nil)
    state = try self.state()
    state.windows.remove(["w"])
    #expect(PeekState.native(state: state, windowId: "w", card: .zero, tokens: [:], dark: false) == nil)
  }

  @Test func dismissalInputsEmitOneIntentWithoutRemovingThePage() {
    let view = PeekOverlayView(frame: .zero)
    view.apply(PeekOverlayViewTests.state())
    let page = NSView()
    view.pageSlot.addSubview(page)
    var events: [PeekEvent] = []
    view.onEvent = { events.append($0) }
    view.cancelOperation(nil)
    #expect(events == [.dismiss])
    #expect(page.superview === view.pageSlot)
    #expect(view.state?.tabId == "t1")
  }

  @Test func closingThenOpeningFencesTheOldCompletion() {
    let lifetime = PeekLifetime()
    lifetime.replace("first")
    let old = lifetime.receipt()
    lifetime.replace(nil)
    lifetime.replace("second")
    #expect(!lifetime.accepts(old))
    #expect(lifetime.accepts(lifetime.receipt()))
  }

  @Test func teardownFencesPromotionWhileOpening() {
    let lifetime = PeekLifetime()
    lifetime.replace("peek")
    let promotion = lifetime.receipt()
    lifetime.replace(nil)
    #expect(!lifetime.accepts(promotion))
  }

  @Test func updatingTheSamePeekPreservesItsReceipt() {
    let lifetime = PeekLifetime()
    lifetime.replace("peek")
    let opening = lifetime.receipt()
    lifetime.replace("peek")
    #expect(lifetime.accepts(opening))
  }

  @Test func promotionCancelledByReplacementSettlesWithoutPromoting() {
    let view = PeekOverlayView(frame: .zero)
    var first = PeekOverlayViewTests.state()
    first.reduceMotion = false
    view.apply(first)
    var results: [Bool] = []
    view.expandToTab { results.append($0) }
    var second = first
    second.tabId = "second"
    view.apply(second)
    view.clear()
    #expect(results == [false])
  }

  @Test func promotionDuringOpeningKeepsThePageSlotAndCompletesOnce() {
    let view = PeekOverlayView(frame: .zero)
    view.apply(PeekOverlayViewTests.state())
    let page = NSView()
    view.pageSlot.addSubview(page)
    var results: [Bool] = []
    view.expandToTab { results.append($0) }
    #expect(results == [true])
    #expect(page.superview === view.pageSlot)
  }

  @Test func pooledPageSurvivesPeekToSplitAndTabPlacement() throws {
    let rig = TabViewPoolHoldTests.Rig()
    let peekSlot = NSView(frame: rig.pane.frame)
    rig.window.contentView?.addSubview(peekSlot)
    rig.slots.set(.peek("w1"), container: peekSlot)
    rig.pool.update([rig.wanted("source", .card), rig.wanted("peek", .peek)])
    rig.turn()
    let page = try #require(rig.made["peek"])
    #expect(page.view.superview === peekSlot)
    rig.slots.set(.pane("w1", "peek"), container: rig.pane)
    rig.pool.update([rig.wanted("source", .card), rig.wanted("peek", .pane)])
    rig.turn()
    #expect(rig.made["peek"] === page)
    #expect(page.view.superview === rig.pane && !page.retired)
    rig.pool.update([rig.wanted("source", .none), rig.wanted("peek", .card)])
    rig.turn()
    #expect(rig.made["peek"] === page)
    #expect(page.view.superview === rig.card && !page.retired)
    rig.pool.update([])
  }

  @Test func delayedMotionRequestCannotTouchAReplacementPeek() {
    let view = PeekOverlayView(frame: .zero)
    view.apply(PeekOverlayViewTests.state())
    let expected = view.state?.tabId
    var next = PeekOverlayViewTests.state()
    next.tabId = "replacement"
    view.apply(next)
    var events: [PeekEvent] = []
    var promoted: [Bool] = []
    view.onEvent = { events.append($0) }
    view.close(expectedTabId: expected)
    view.expandToTab(expectedTabId: expected) { promoted.append($0) }
    #expect(events.isEmpty)
    #expect(promoted == [false])
    view.expandToTab(expectedTabId: "replacement") { promoted.append($0) }
    #expect(promoted == [false, true])
  }

  @Test func revealHoldsReleaseIndependently() {
    let holds = RevealHolds()
    var changes: [Bool] = []
    holds.onChange = { changes.append($0) }
    let menu = holds.acquire()
    let drag = holds.acquire()
    holds.release(menu)
    #expect(holds.held)
    holds.release(menu)
    holds.release(drag)
    #expect(!holds.held)
    #expect(changes == [true, false])
  }

  @Test func cancelledHideCannotCloseANewerReveal() {
    let peek = EdgePeek(enabled: true, arc: false)
    var timers: [@MainActor () -> Void] = []
    var animations: [() -> Void] = []
    peek.schedule = { _, run in timers.append(run); return NSObject() }
    peek.cancel = { _ in }
    peek.animate = { _, _, done in animations.append(done) }
    peek.show()
    peek.hide()
    peek.show()
    timers[0]()
    animations.forEach { $0() }
    #expect(peek.live)
  }

  @Test func stoppedRevealRejectsQueuedCallbacks() {
    let peek = EdgePeek(enabled: true, arc: false)
    var timer: (@MainActor () -> Void)?
    var slides = 0
    peek.schedule = { _, run in timer = run; return NSObject() }
    peek.cancel = { _ in }
    peek.onSlideOut = { slides += 1 }
    peek.show()
    peek.hide()
    peek.stop()
    timer?()
    peek.show()
    #expect(slides == 0)
    #expect(!peek.live)
  }
}
