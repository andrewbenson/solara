import AppKit
import Testing
@testable import SolaraUI

@MainActor
private final class PoolFrameEntryView: NSView {
  var entries: [(NSView, NSRect, NSView.AutoresizingMask, Bool)] = []
  var windowEntries: [(NSWindow, NSRect, Bool)] = []
  var resized: [NSSize] = []

  override func setFrameSize(_ newSize: NSSize) {
    resized.append(newSize)
    super.setFrameSize(newSize)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if let superview { entries.append((superview, frame, autoresizingMask, isHiddenOrHasHiddenAncestor)) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { windowEntries.append((window, frame, isHiddenOrHasHiddenAncestor)) }
  }
}

private final class PoolFlippedFrameContainer: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
struct TabViewPoolFrameTests {
  @Test func aNewShownPageStartsHiddenAtItsFinalViewportWithOneResize() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { _ in view }
    rig.card.frame = NSRect(x: 0, y: 0, width: 200, height: 260)
    rig.slots.set(.card("w1"), container: rig.card)
    view.resized.removeAll()
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card)])
    rig.turn()
    let initial = try #require(view.entries.first)
    let shown = try #require(view.entries.first { $0.0 === rig.card })
    let windowEntry = try #require(view.windowEntries.first)
    #expect(initial.0 === rig.hiddenBox)
    #expect(initial.1 == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(initial.2.isEmpty)
    #expect(initial.3)
    #expect(shown.1 == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(shown.2 == [.width, .height])
    #expect(!shown.3)
    #expect(windowEntry.2)
    #expect(view.windowEntries.allSatisfy { $0.1 == NSRect(x: 0, y: 0, width: 200, height: 260) })
    #expect(view.resized == [NSSize(width: 200, height: 260)])
    rig.window.close()
  }

  @Test func aWarmPageWithoutAVisibleDestinationStartsInTheSizedHiddenContainer() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { _ in view }
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .none, warm: true)])
    rig.turn()
    let hidden = try #require(view.windowEntries.first)
    #expect(hidden.0 === rig.window)
    #expect(hidden.1 == NSRect(x: 0, y: 0, width: 400, height: 300))
    #expect(view.superview === rig.hiddenBox)
    #expect(view.isHiddenOrHasHiddenAncestor)
    #expect(rig.made["a"]?.shownLog.contains(true) == false)
    rig.window.close()
  }

  @Test func aDestinationRemovedDuringPageCreationFallsBackToHiddenStorage() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let view = PoolFrameEntryView(frame: .zero)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pageView = { _ in
      rig.slots.remove(.card("w1"), container: rig.card)
      return view
    }
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card)])
    rig.turn()
    let hidden = try #require(view.windowEntries.first)
    #expect(hidden.0 === rig.window)
    #expect(hidden.1 == NSRect(x: 0, y: 0, width: 400, height: 300))
    #expect(view.superview === rig.hiddenBox)
    #expect(view.isHiddenOrHasHiddenAncestor)
    rig.window.close()
  }

  @Test func aPageEnteringANarrowerSlotHasTheFinalViewportAtAttachment() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { _ in view }
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card)])
    rig.turn()
    view.entries.removeAll()
    let pane = NSView(frame: NSRect(x: 80, y: 20, width: 200, height: 260))
    rig.window.contentView?.addSubview(pane)
    rig.slots.set(.card("w1"), container: pane)
    rig.turn()
    let entry = try #require(view.entries.first { $0.0 === pane })
    #expect(entry.1 == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(view.superview === pane)
    #expect(rig.pool.page("a") === rig.made["a"])
    rig.window.close()
  }

  @Test func movingBetweenWindowsKeepsTheNewViewportAcrossFlippedContainers() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { _ in view }
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card)])
    rig.turn()
    view.entries.removeAll()
    view.windowEntries.removeAll()
    let destination = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 240),
      styleMask: [.titled], backing: .buffered, defer: true)
    destination.isReleasedWhenClosed = false
    let container = PoolFlippedFrameContainer(frame: NSRect(x: 10, y: 5, width: 180, height: 210))
    destination.contentView?.addSubview(container)
    rig.slots.set(.card("w2"), container: container)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w2", shown: .card)])
    rig.turn()
    let entry = try #require(view.windowEntries.first { $0.0 === destination })
    #expect(entry.1 == NSRect(x: 0, y: 0, width: 180, height: 210))
    #expect(view.frame == NSRect(x: 0, y: 0, width: 180, height: 210))
    #expect(view.superview === container)
    #expect(view.window === destination)
    destination.close()
    rig.window.close()
  }
  @Test func aParkedNativePageKeepsItsViewportThroughHiddenResizeUntilShown() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let views = ["a": PoolFrameEntryView(frame: .zero), "b": PoolFrameEntryView(frame: .zero)]
    rig.pageView = { views[$0]! }
    rig.card.frame = NSRect(x: 0, y: 0, width: 400, height: 259)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .none)])
    rig.turn()
    let a = try #require(views["a"])
    a.resized.removeAll()
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .none),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .card)])
    rig.turn()
    #expect(a.frame == NSRect(x: 0, y: 0, width: 400, height: 259))
    #expect(a.autoresizingMask.isEmpty)
    #expect(a.resized.isEmpty)
    rig.hiddenBox.setFrameSize(NSSize(width: 500, height: 400))
    #expect(a.frame == NSRect(x: 0, y: 0, width: 400, height: 259))
    #expect(a.resized.isEmpty)
    let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 480))
    replacement.isHidden = true
    rig.window.contentView?.addSubview(replacement)
    rig.pool.hiddenContainer = { _ in replacement }
    rig.pool.setNeedsReconcile()
    rig.turn()
    #expect(a.superview === replacement)
    #expect(a.frame == NSRect(x: 0, y: 0, width: 400, height: 259))
    #expect(a.resized.isEmpty)
    rig.card.frame = NSRect(x: 0, y: 0, width: 600, height: 450)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .none)])
    rig.turn()
    #expect(a.resized == [NSSize(width: 600, height: 450)])
    #expect(a.frame == NSRect(x: 0, y: 0, width: 600, height: 450))
    #expect(a.autoresizingMask == [.width, .height])
    rig.window.close()
  }

  @Test func releasingADrawHoldParksTheLastNativeViewport() throws {
    let rig = TabViewPoolHoldTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    rig.card.frame = NSRect(x: 0, y: 0, width: 400, height: 259)
    let a = try rig.showDrawn("a", others: ["b"])
    rig.show("b", others: ["a"])
    #expect(rig.pool.heldTabIds == ["a"])
    #expect(a.view.superview === rig.card)
    let b = try #require(rig.made["b"])
    b.draw()
    #expect(rig.pool.heldTabIds.isEmpty)
    #expect(a.view.superview === rig.hiddenBox)
    #expect(a.view.frame == NSRect(x: 0, y: 0, width: 400, height: 259))
    #expect(a.view.autoresizingMask.isEmpty)
    #expect(a.holdLog == [true, false])
    rig.window.close()
  }

  @Test func defaultPlacementKeepsTheLegacyHiddenSizing() throws {
    let rig = TabViewPoolTests.Rig()
    rig.card.frame = NSRect(x: 0, y: 0, width: 400, height: 259)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .none)])
    rig.turn()
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .none),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .card)])
    rig.turn()
    let a = try #require(rig.made["a"])
    #expect(a.view.frame == NSRect(x: 0, y: 0, width: 400, height: 300))
    #expect(a.view.autoresizingMask == [.width, .height])
    rig.hiddenBox.setFrameSize(NSSize(width: 500, height: 400))
    #expect(a.view.frame.size == NSSize(width: 500, height: 400))
    rig.window.close()
  }

  @Test func splitPagesKeepTheirOwnViewportWhenParked() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    let left = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 259))
    let right = NSView(frame: NSRect(x: 180, y: 0, width: 220, height: 259))
    rig.window.contentView?.addSubview(left)
    rig.window.contentView?.addSubview(right)
    rig.slots.set(.pane("w1", "a"), container: left)
    rig.slots.set(.pane("w1", "b"), container: right)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .pane),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .pane)])
    rig.turn()
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .none),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .card)])
    rig.turn()
    let a = try #require(rig.made["a"])
    #expect(a.view.superview === rig.hiddenBox)
    #expect(a.view.frame.size == NSSize(width: 180, height: 259))
    #expect(a.view.autoresizingMask.isEmpty)
    rig.window.close()
  }

  @Test func aLaterCreationRemovingTheInitialTargetParksTheNewPage() throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    rig.card.frame = NSRect(x: 0, y: 0, width: 200, height: 260)
    rig.slots.set(.card("w1"), container: rig.card)
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { id in
      if id == "b" { rig.slots.remove(.card("w1"), container: rig.card) }
      return id == "a" ? view : NSView(frame: .zero)
    }
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .none)])
    rig.turn()
    let initial = try #require(view.entries.first)
    #expect(initial.0 === rig.hiddenBox)
    #expect(initial.1 == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(initial.3)
    #expect(view.superview === rig.hiddenBox)
    #expect(view.frame == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(view.isHiddenOrHasHiddenAncestor)
    rig.window.close()
  }

  @Test(arguments: [false, true])
  func aLaterCreationReplacingOrResizingTheInitialTargetUsesTheCurrentViewport(replaces: Bool) throws {
    let rig = TabViewPoolTests.Rig()
    rig.pool.nativePlacement = { _ in true }
    rig.card.frame = NSRect(x: 0, y: 0, width: 200, height: 260)
    rig.slots.set(.card("w1"), container: rig.card)
    let replacement = replaces ? NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 270)) : rig.card
    if replaces { rig.window.contentView?.addSubview(replacement) }
    let view = PoolFrameEntryView(frame: .zero)
    rig.pageView = { id in
      if id == "b" {
        replacement.frame = NSRect(x: 0, y: 0, width: 250, height: 270)
        rig.slots.set(.card("w1"), container: replacement)
      }
      return id == "a" ? view : NSView(frame: .zero)
    }
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w1", shown: .card),
      TabViewWanted(tabId: "b", windowId: "w1", shown: .none)])
    rig.turn()
    let initial = try #require(view.entries.first)
    let final = try #require(view.entries.last)
    #expect(initial.0 === rig.hiddenBox)
    #expect(initial.1 == NSRect(x: 0, y: 0, width: 200, height: 260))
    #expect(initial.3)
    #expect(final.0 === replacement)
    #expect(final.1 == NSRect(x: 0, y: 0, width: 250, height: 270))
    #expect(view.superview === replacement)
    #expect(view.frame == NSRect(x: 0, y: 0, width: 250, height: 270))
    rig.window.close()
  }

}
