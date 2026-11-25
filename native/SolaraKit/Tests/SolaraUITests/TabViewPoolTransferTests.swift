import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct TabViewPoolTransferTests {
  final class View: NSView {
    var leaving: (() -> Void)?
    override func viewWillMove(toSuperview newSuperview: NSView?) {
      if superview != nil, superview !== newSuperview { leaving?() }
      super.viewWillMove(toSuperview: newSuperview)
    }
  }

  final class Page: TabPoolPage {
    let view: NSView = View(frame: .zero)
    var shown = false
    var painted = false
    var preparation: (() -> Void)?
    var holdsUntilDrawn: Bool { true }
    func setShown(_ shown: Bool) { self.shown = shown }
    func prepareToShow() {
      setShown(true)
      painted = true
      preparation?()
    }
    func focus() {}
    func retire() { view.removeFromSuperview() }
  }

  @Test(arguments: [false, true], [false, true])
  func successorPaintsBeneathOutgoingBeforeTransfer(_ outgoingSortsFirst: Bool, _ destinationReady: Bool) throws {
    let slots = TabSlots()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
    let targetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    targetWindow.isReleasedWhenClosed = false
    defer { window.close(); targetWindow.close() }
    let source = try #require(window.contentView)
    let target = try #require(targetWindow.contentView)
    slots.set(.card("A"), container: source)
    if destinationReady { slots.set(.card("B"), container: target) }
    var pages: [String: Page] = [:]
    let pool = TabViewPool(slots: slots, make: { id, _ in
      let page = Page()
      page.preparation = { [weak page] in
        guard let page else { return }
        #expect(source.subviews.count == 2)
        #expect(source.subviews.last !== page.view)
      }
      pages[id] = page
      return page
    }, schedule: { _ in })
    pool.nativePlacement = { _ in true }
    let outgoing = outgoingSortsFirst ? "a" : "z"
    let next = outgoingSortsFirst ? "z" : "a"
    var initial = [TabViewWanted(tabId: outgoing, windowId: "A", shown: .card)]
    if !outgoingSortsFirst { initial.append(TabViewWanted(tabId: next, windowId: "A", shown: .none)) }
    pool.update(initial)
    pool.reconcile()
    let moved = try #require(pages[outgoing])
    var departures = 0
    (moved.view as? View)?.leaving = {
      departures += 1
      let successor = pages[next]
      #expect(successor?.view.superview === source)
      #expect(successor?.shown == true)
      #expect(successor?.painted == true)
      #expect(successor?.view.frame == source.bounds)
    }
    pool.update([
      TabViewWanted(tabId: outgoing, windowId: "B", shown: .card),
      TabViewWanted(tabId: next, windowId: "A", shown: .card),
    ])
    pool.reconcile()
    #expect(pool.heldTabIds.isEmpty)
    #expect(departures == 1)
    #expect(pages[next]?.view.superview === source)
    #expect(pool.place(next) == .slot(.card("A")))
    if destinationReady { #expect(moved.view.superview === target) }
  }
}
