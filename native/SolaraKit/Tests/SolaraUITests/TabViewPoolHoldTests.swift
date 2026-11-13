import AppKit
import Testing
@testable import SolaraUI

@MainActor
final class HoldFocusView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class HoldingPage: TabPoolPage {
  let view: NSView = HoldFocusView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
  var focused = 0
  var shownLog: [Bool] = []
  var holdLog: [Bool] = []
  var drawn: [@MainActor (Bool) -> Void] = []
  var retired = false
  func setShown(_ shown: Bool) { shownLog.append(shown) }
  func focus() { focused += 1 }
  func retire() {
    retired = true
    view.removeFromSuperview()
  }
  var holdsUntilDrawn: Bool { true }
  func hold(_ held: Bool) { holdLog.append(held) }
  func whenDrawn(_ done: @escaping @MainActor (Bool) -> Void) { drawn.append(done) }
  func draw(_ result: Bool = true) {
    let callbacks = drawn
    drawn = []
    callbacks.forEach { $0(result) }
  }
}

@MainActor
struct TabViewPoolHoldTests {
  @MainActor final class Rig {
    let slots = TabSlots()
    var made: [String: HoldingPage] = [:]
    var pending: [@MainActor () -> Void] = []
    var timers: [(TimeInterval, @MainActor () -> Void)] = []
    var pool: TabViewPool!
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    let card = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    let hiddenBox = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    init() {
      window.isReleasedWhenClosed = false
      hiddenBox.isHidden = true
      for view in [card, pane, hiddenBox] { window.contentView!.addSubview(view) }
      pool = TabViewPool(slots: slots, make: { [unowned self] id, _ in
        let page = HoldingPage()
        self.made[id] = page
        return page
      }, schedule: { [unowned self] work in self.pending.append(work) }, after: { [unowned self] delay, work in self.timers.append((delay, work)) })
      pool.hiddenContainer = { [unowned self] w in w == "w1" ? self.hiddenBox : nil }
      slots.set(.card("w1"), container: card)
    }

    func turn() {
      let work = pending
      pending = []
      work.forEach { $0() }
    }

    func fireTimers() {
      let fired = timers
      timers = []
      fired.forEach { $0.1() }
    }

    var profiles: [String: String] = [:]

    func wanted(_ id: String, _ how: TabViewWanted.Shown) -> TabViewWanted {
      TabViewWanted(tabId: id, windowId: "w1", shown: how, profileId: profiles[id] ?? "p1")
    }

    func show(_ shown: String, others: [String], _ how: TabViewWanted.Shown = .card) {
      pool.update([wanted(shown, how)] + others.map { wanted($0, .none) })
      turn()
    }

    func showDrawn(_ shown: String, others: [String]) throws -> HoldingPage {
      show(shown, others: others)
      let page = try #require(made[shown])
      page.draw()
      return page
    }

    func top(_ container: NSView) -> NSView? { container.subviews.last }
  }

  @Test func theLeavingPageStaysAboveUntilTheNextOneHasDrawn() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    let b = try #require(rig.made["b"])
    #expect(a.view.superview === rig.card)
    rig.show("b", others: ["a"])
    #expect(a.view.superview === rig.card)
    #expect(b.view.superview === rig.card)
    #expect(rig.top(rig.card) === a.view)
    #expect(a.holdLog == [true])
    #expect(a.shownLog.last == false && b.shownLog.last == true)
    #expect(rig.pool.heldTabIds == ["a"])
    #expect(rig.timers.map(\.0) == [TabViewPool.holdLimit])
    b.draw()
    #expect(a.holdLog == [true, false])
    #expect(a.view.superview === rig.hiddenBox)
    #expect(rig.top(rig.card) === b.view)
    #expect(rig.pool.heldTabIds.isEmpty)
    rig.fireTimers()
    #expect(a.holdLog == [true, false])
    #expect(a.view.superview === rig.hiddenBox)
  }

  @Test func theLimitEndsAHoldWhenNothingDraws() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds == ["a"])
    rig.fireTimers()
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    #expect(a.holdLog == [true, false])
  }

  @Test func aPageThatHasNotDrawnSinceItWasShownIsNeverHeld() throws {
    let rig = Rig()
    rig.show("a", others: ["b"])
    let a = try #require(rig.made["a"])
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    #expect(a.holdLog.isEmpty)
  }

  @Test func aClosedPageRetiresAtOnce() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    rig.pool.update([rig.wanted("b", .card)])
    rig.turn()
    #expect(a.retired)
    #expect(a.view.superview == nil)
    #expect(rig.pool.heldTabIds.isEmpty)
  }

  @Test func closingTheHeldTabEndsItsHoldAndRetiresIt() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds == ["a"])
    rig.pool.update([rig.wanted("b", .card)])
    rig.turn()
    #expect(a.retired)
    #expect(a.holdLog == [true, false])
    #expect(rig.pool.heldTabIds.isEmpty)
  }

  @Test func switchingBackToTheHeldPageShowsItAndHoldsNothingThatHasNotDrawn() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    let b = try #require(rig.made["b"])
    rig.show("b", others: ["a"])
    rig.show("a", others: ["b"])
    #expect(a.holdLog == [true, false])
    #expect(a.shownLog.last == true)
    #expect(a.view.superview === rig.card)
    #expect(rig.top(rig.card) === a.view)
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(b.view.superview === rig.hiddenBox)
    b.draw()
    rig.fireTimers()
    #expect(rig.top(rig.card) === a.view)
  }

  @Test func switchingBackAfterTheNextPageDrewHoldsIt() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    let b = try #require(rig.made["b"])
    rig.show("b", others: ["a"])
    b.draw()
    rig.show("a", others: ["b"])
    #expect(rig.pool.heldTabIds == ["b"])
    #expect(rig.top(rig.card) === b.view)
  }

  @Test func aLaterHoldStacksOnlyTheNewLeavingPage() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b", "c"])
    let b = try #require(rig.made["b"])
    rig.show("b", others: ["a", "c"])
    #expect(rig.pool.heldTabIds == ["a"])
    b.draw()
    rig.fireTimers()
    rig.show("c", others: ["a", "b"])
    #expect(rig.pool.heldTabIds == ["b"])
    #expect(a.view.superview === rig.hiddenBox)
    let c = try #require(rig.made["c"])
    #expect(rig.card.subviews.filter { $0 === a.view || $0 === b.view || $0 === c.view }.map { ObjectIdentifier($0) } == [ObjectIdentifier(c.view), ObjectIdentifier(b.view)])
  }

  @Test func aSwitchAwayFromTheIncomingPageEndsTheHold() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b", "c"])
    rig.show("b", others: ["a", "c"])
    #expect(rig.pool.heldTabIds == ["a"])
    rig.show("c", others: ["a", "b"])
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    let c = try #require(rig.made["c"])
    #expect(rig.top(rig.card) === c.view)
  }

  @Test func aProfileSwitchNeverHoldsAndEndsARunningHold() throws {
    let rig = Rig()
    rig.profiles = ["a": "p1", "b": "p1", "x": "p2"]
    let a = try rig.showDrawn("a", others: ["b", "x"])
    rig.show("x", others: ["a", "b"])
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    let x = try #require(rig.made["x"])
    x.draw()
    rig.show("a", others: ["b", "x"])
    a.draw()
    rig.show("b", others: ["a", "x"])
    #expect(rig.pool.heldTabIds == ["a"])
    rig.profiles["b"] = "p2"
    rig.pool.update([rig.wanted("b", .card), rig.wanted("a", .none), rig.wanted("x", .none)])
    rig.turn()
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    rig.profiles["b"] = "p1"
    rig.show("a", others: ["b", "x"])
    a.draw()
    rig.show("b", others: ["a", "x"])
    #expect(rig.pool.heldTabIds == ["a"])
    rig.pool.update([rig.wanted("a", .none), rig.wanted("b", .none), rig.wanted("x", .none)])
    rig.turn()
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
  }

  @Test func aClickOnTheHeldPageEndsTheHoldAndIsDropped() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds == ["a"])
    #expect(rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: NSPoint(x: 250, y: 50)))
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    #expect(!rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: NSPoint(x: 250, y: 50)))
  }

  @Test func aKeyEndsTheHoldAndGoesThrough() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
    other.isReleasedWhenClosed = false
    #expect(!rig.pool.inputArrived(.keyDown, window: other, at: .zero))
    #expect(rig.pool.heldTabIds == ["a"])
    #expect(!rig.pool.inputArrived(.keyDown, window: rig.window, at: .zero))
    #expect(rig.pool.heldTabIds.isEmpty)
  }

  @Test func theHeldPageGivesUpKeyFocusToTheIncomingPage() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    let b = try #require(rig.made["b"])
    #expect(rig.window.makeFirstResponder(a.view))
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds == ["a"])
    #expect(rig.window.firstResponder !== a.view)
    rig.turn()
    #expect(b.focused == 1)
  }

  @Test func focusTheAppMovesDuringAHoldStaysWhereTheAppPutIt() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b"])
    let b = try #require(rig.made["b"])
    let field = HoldFocusView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    rig.window.contentView!.addSubview(field)
    #expect(rig.window.makeFirstResponder(a.view))
    rig.show("b", others: ["a"])
    #expect(rig.window.makeFirstResponder(field))
    rig.turn()
    #expect(b.focused == 0)
    #expect(rig.window.firstResponder === field)
  }

  @Test func anEngineNoDoesNotCountAsDrawn() throws {
    let rig = Rig()
    rig.show("a", others: ["b"])
    let a = try #require(rig.made["a"])
    a.draw(false)
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
  }

  @Test func aClickOnChromeOverTheCardKeepsItsClick() throws {
    let rig = Rig()
    let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
    rig.window.contentView!.addSubview(chrome)
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(!rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: NSPoint(x: 50, y: 50)))
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(!rig.pool.inputArrived(.leftMouseUp, window: rig.window, at: NSPoint(x: 50, y: 50)))
  }

  @Test func theRestOfADroppedGestureIsDroppedToo() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    let at = NSPoint(x: 250, y: 50)
    #expect(rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: at))
    #expect(rig.pool.inputArrived(.leftMouseDragged, window: rig.window, at: at))
    #expect(rig.pool.inputArrived(.leftMouseUp, window: rig.window, at: at))
    #expect(!rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: at))
    rig.made["b"]?.draw()
    rig.made["a"]?.draw()
    rig.show("a", others: ["b"])
    #expect(rig.pool.heldTabIds == ["b"])
    #expect(rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, phase: .began))
    #expect(rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, phase: .changed))
    #expect(rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, phase: .ended))
    #expect(rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, momentum: .began))
    #expect(rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, momentum: .ended))
    #expect(!rig.pool.inputArrived(.scrollWheel, window: rig.window, at: at, phase: .began))
  }

  @Test func aDroppedPressWhoseWindowClosesStopsDropping() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    let at = NSPoint(x: 250, y: 50)
    #expect(rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: at))
    #expect(rig.pool.isDroppingAGesture)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: rig.window)
    #expect(!rig.pool.isDroppingAGesture)
    #expect(!rig.pool.inputArrived(.leftMouseUp, window: rig.window, at: at))
  }

  @Test func aDroppedPressStopsWhenInputArrivesInAnotherWindow() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    let at = NSPoint(x: 250, y: 50)
    #expect(rig.pool.inputArrived(.leftMouseDown, window: rig.window, at: at))
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
    other.isReleasedWhenClosed = false
    #expect(!rig.pool.inputArrived(.leftMouseDragged, window: other, at: .zero))
    #expect(!rig.pool.isDroppingAGesture)
  }

  @Test func theDeferredFocusSkipsAPageThatIsNoLongerShown() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b", "c"])
    let b = try #require(rig.made["b"])
    #expect(rig.window.makeFirstResponder(a.view))
    rig.pool.update([rig.wanted("b", .card), rig.wanted("a", .none), rig.wanted("c", .none)])
    let pending = rig.pending
    rig.pending = []
    pending.forEach { $0() }
    #expect(rig.pool.heldTabIds == ["a"])
    rig.pool.update([rig.wanted("c", .card), rig.wanted("a", .none), rig.wanted("b", .none)])
    rig.pool.reconcile()
    rig.turn()
    rig.turn()
    #expect(b.focused == 0)
  }

  @Test func aPressThatStartedBeforeTheHoldNeitherEndsItNorIsDropped() throws {
    let rig = Rig()
    _ = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(!rig.pool.inputArrived(.leftMouseUp, window: rig.window, at: NSPoint(x: 250, y: 50)))
    #expect(rig.pool.heldTabIds == ["a"])
  }

  @Test func aReconcileDuringAHoldKeepsTheHeldPageInPlace() throws {
    let rig = Rig()
    let a = try rig.showDrawn("a", others: ["b", "c"])
    rig.show("b", others: ["a", "c"])
    rig.pool.setNeedsReconcile()
    rig.turn()
    #expect(a.view.superview === rig.card)
    #expect(rig.pool.heldTabIds == ["a"])
  }

  @Test func noHoldOutsideTheCardOrWithoutAnIncomingPage() throws {
    let rig = Rig()
    rig.slots.set(.pane("w1", "a"), container: rig.pane)
    rig.slots.set(.pane("w1", "b"), container: rig.pane)
    rig.show("a", others: ["b"], .pane)
    rig.made["a"]?.draw()
    rig.show("b", others: ["a"], .pane)
    #expect(rig.pool.heldTabIds.isEmpty)
    let other = Rig()
    _ = try other.showDrawn("a", others: ["b"])
    other.pool.update([other.wanted("a", .none), other.wanted("b", .none)])
    other.turn()
    #expect(other.pool.heldTabIds.isEmpty)
    #expect(other.made["a"]?.view.superview === other.hiddenBox)
  }
}
