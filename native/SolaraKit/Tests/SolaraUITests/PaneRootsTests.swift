import AppKit
import Testing
@testable import SolaraUI

@MainActor
final class FakeClock {
  var pending: [(at: TimeInterval, run: @MainActor () -> Void, id: Int)] = []
  var now: TimeInterval = 0
  var cancels = true
  private var next = 0

  func schedule(_ delay: TimeInterval, _ run: @escaping @MainActor () -> Void) -> (() -> Void) {
    next += 1
    let id = next
    pending.append((now + delay, run, id))
    return { [weak self] in
      guard let self, self.cancels else { return }
      self.pending.removeAll { $0.id == id }
    }
  }

  func advance(_ seconds: TimeInterval) {
    now += seconds
    let due = pending.filter { $0.at <= now }
    pending.removeAll { $0.at <= now }
    for item in due { item.run() }
  }
}

@MainActor
struct PaneRootsTests {
  final class Harness {
    let clock = FakeClock()
    var containers: [String: NSView] = [:]
    var made: [String] = []
    var roots: PaneRoots!

    @MainActor init() {
      roots = PaneRoots(
        windowId: "w",
        makeRoot: { [unowned self] tabId in
          self.made.append(tabId)
          return NSView()
        },
        container: { [unowned self] tabId in self.containers[tabId] },
        schedule: { [unowned self] delay, run in self.clock.schedule(delay, run) }
      )
    }

    @MainActor func slot(_ tabId: String, _ frame: CGRect = CGRect(x: 0, y: 41, width: 800, height: 600)) -> NSView {
      let view = NSView(frame: frame)
      containers[tabId] = view
      return view
    }
  }

  @Test func aVisibleTabGetsAHiddenRootThatShowsOnceItsContentAppears() throws {
    let h = Harness()
    let slot = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    #expect(root.superview === slot)
    #expect(root.frame == slot.bounds)
    #expect(root.autoresizingMask == [.width, .height])
    #expect(root.isHidden)
    h.roots.contentAppeared("a", root: root)
    #expect(!root.isHidden)
  }

  @Test func eachShowAndHideIsReportedOnceWithTheRoot() throws {
    let h = Harness()
    _ = h.slot("a")
    var seen: [Bool] = []
    h.roots.onShown = { tabId, root, shown in
      #expect(tabId == "a")
      #expect(root === h.roots.root("a"))
      seen.append(shown)
    }
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    #expect(seen.isEmpty)
    h.roots.contentAppeared("a", root: root)
    h.roots.update(visible: ["a"], open: ["a"])
    h.roots.update(visible: [], open: ["a"])
    h.roots.update(visible: [], open: ["a"])
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(seen == [true, false, true])
  }

  @Test func theRootSitsBelowNativeOverlaysInItsSlot() throws {
    let h = Harness()
    let slot = h.slot("a")
    let sadTab = NSView()
    slot.addSubview(sadTab)
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(slot.subviews.first === h.roots.root("a"))
    #expect(slot.subviews.last === sadTab)
  }

  @Test func aTabLeavingViewKeepsItsRootForTheGraceThenLosesIt() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a", "b"])
    let root = try #require(h.roots.root("a"))
    h.roots.contentAppeared("a", root: root)
    h.roots.update(visible: ["b"], open: ["a", "b"])
    #expect(root.isHidden)
    #expect(h.roots.isRetiring("a"))
    h.clock.advance(0.9)
    #expect(h.roots.root("a") === root)
    h.clock.advance(0.2)
    #expect(h.roots.root("a") == nil)
    #expect(root.superview == nil)
  }

  @Test func comingBackWithinTheGraceKeepsTheSameRoot() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    h.roots.contentAppeared("a", root: root)
    h.roots.update(visible: [], open: ["a"])
    h.clock.advance(0.5)
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(!root.isHidden)
    #expect(!h.roots.isRetiring("a"))
    h.clock.advance(2)
    #expect(h.roots.root("a") === root)
    #expect(h.made == ["a"])
  }

  @Test func aClosedTabLosesItsRootAtOnce() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    h.roots.update(visible: ["a"], open: [])
    #expect(h.roots.root("a") == nil)
    #expect(root.superview == nil)
  }

  @Test func aTabClosedDuringItsGraceGoesAtOnceAndTheTimerDoesNothing() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    h.roots.update(visible: [], open: ["a"])
    h.roots.update(visible: [], open: [])
    #expect(h.roots.root("a") == nil)
    #expect(h.clock.pending.isEmpty)
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let fresh = try #require(h.roots.root("a"))
    h.clock.advance(5)
    #expect(h.roots.root("a") === fresh)
  }

  @Test func aNewSlotForTheTabTakesTheSameRoot() throws {
    let h = Harness()
    let first = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    let second = h.slot("a", CGRect(x: 0, y: 41, width: 400, height: 600))
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(root.superview === second)
    #expect(first.subviews.isEmpty)
    #expect(root.frame == second.bounds)
    #expect(h.made == ["a"])
  }

  @Test func aVisibleTabPreparesItsRootBeforeTheSlotArrives() throws {
    let h = Harness()
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    #expect(root.superview == nil)
    #expect(root.isHidden)
    #expect(h.roots.isRetiring("a"))
    h.roots.contentAppeared("a", root: root)
    #expect(root.isHidden)
    let slot = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(h.roots.root("a") === root)
    #expect(root.superview === slot)
    #expect(root.frame == slot.bounds)
    #expect(!root.isHidden)
    #expect(!h.roots.isRetiring("a"))
    #expect(h.made == ["a"])
    h.clock.advance(2)
    #expect(h.roots.root("a") === root)
  }

  @Test func aPreparedRootStillWaitsForItsOwnContentAfterTheSlotArrives() throws {
    let h = Harness()
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    let slot = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(root.superview === slot)
    #expect(root.isHidden)
    h.roots.contentAppeared("a", root: root)
    #expect(!root.isHidden)
  }

  @Test func closingOrStoppingADetachedPreparedRootEndsItOnce() throws {
    let h = Harness()
    var ended: [String] = []
    h.roots.onEnd = { tabId, _ in ended.append(tabId) }
    h.roots.update(visible: ["a", "b"], open: ["a", "b"])
    let a = try #require(h.roots.root("a"))
    let b = try #require(h.roots.root("b"))
    h.roots.update(visible: [], open: ["b"])
    #expect(h.roots.root("a") == nil)
    h.roots.contentAppeared("a", root: a)
    h.roots.stop()
    h.roots.contentAppeared("b", root: b)
    h.clock.advance(2)
    #expect(h.roots.tabIds.isEmpty)
    #expect(ended.sorted() == ["a", "b"])
    #expect(a.isHidden && b.isHidden)
  }

  @Test func aPreparedRootWhoseSlotNeverArrivesEndsAfterTheGrace() throws {
    let h = Harness()
    var ended = 0
    h.roots.onEnd = { _, _ in ended += 1 }
    h.roots.update(visible: ["a"], open: ["a"])
    let old = try #require(h.roots.root("a"))
    h.clock.advance(1.1)
    #expect(h.roots.root("a") == nil)
    #expect(ended == 1)
    let slot = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let fresh = try #require(h.roots.root("a"))
    h.roots.contentAppeared("a", root: old)
    #expect(fresh !== old)
    #expect(fresh.superview === slot)
    #expect(fresh.isHidden)
  }

  @Test func aStaleAppearanceFromAnEndedRootShowsNothing() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let old = try #require(h.roots.root("a"))
    h.roots.update(visible: [], open: [])
    h.roots.update(visible: ["a"], open: ["a"])
    let fresh = try #require(h.roots.root("a"))
    h.roots.contentAppeared("a", root: old)
    #expect(fresh.isHidden)
  }

  @Test func anAppearanceDuringTheGraceStaysHidden() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    h.roots.update(visible: [], open: ["a"])
    h.roots.contentAppeared("a", root: root)
    #expect(root.isHidden)
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(!root.isHidden)
  }

  @Test func stoppingEndsEveryRootAndIgnoresLaterUpdates() {
    let h = Harness()
    _ = h.slot("a")
    _ = h.slot("b")
    h.roots.update(visible: ["a"], open: ["a", "b"])
    h.roots.update(visible: ["b"], open: ["a", "b"])
    h.roots.stop()
    #expect(h.roots.tabIds.isEmpty)
    #expect(h.clock.pending.isEmpty)
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(h.roots.tabIds.isEmpty)
  }

  @Test func everyEndedRootIsReportedOnce() throws {
    let h = Harness()
    _ = h.slot("a")
    _ = h.slot("b")
    var ended: [String] = []
    h.roots.onEnd = { tabId, _ in ended.append(tabId) }
    h.roots.update(visible: ["a", "b"], open: ["a", "b"])
    h.roots.update(visible: ["b"], open: ["a", "b"])
    h.clock.advance(1.5)
    h.roots.update(visible: ["b"], open: [])
    h.roots.stop()
    #expect(ended == ["a", "b"])
  }

  @Test func aSlotThatGoesAwayRetiresTheRootInsteadOfKeepingItVisible() throws {
    let h = Harness()
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    h.containers["a"] = nil
    h.roots.update(visible: ["a"], open: ["a"])
    #expect(root.isHidden)
    #expect(h.roots.isRetiring("a"))
    h.clock.advance(1.1)
    #expect(h.roots.root("a") == nil)
  }

  @Test func anOldGraceTimerCantEndALaterRetireEarly() throws {
    let h = Harness()
    h.clock.cancels = false
    _ = h.slot("a")
    h.roots.update(visible: ["a"], open: ["a"])
    let root = try #require(h.roots.root("a"))
    h.roots.update(visible: [], open: ["a"])
    h.clock.advance(0.6)
    h.roots.update(visible: ["a"], open: ["a"])
    h.roots.update(visible: [], open: ["a"])
    h.clock.advance(0.6)
    #expect(h.roots.root("a") === root)
    h.clock.advance(0.5)
    #expect(h.roots.root("a") == nil)
  }

  @Test func anEndedRootIsFreedOnceItsOwnersLetGo() async {
    let h = Harness()
    _ = h.slot("a")
    weak var freed: NSView?
    var ended = 0
    h.roots.onEnd = { _, _ in ended += 1 }
    do {
      h.roots.update(visible: ["a"], open: ["a"])
      freed = h.roots.root("a")
      h.roots.update(visible: [], open: [])
    }
    try? await Task.sleep(nanoseconds: 10_000_000)
    #expect(ended == 1)
    #expect(freed == nil)
  }

  @Test func theGraceTimerOutlivingItsOwnerDoesNothing() {
    let clock = FakeClock()
    let slot = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    var roots: PaneRoots? = PaneRoots(windowId: "w", makeRoot: { _ in NSView() }, container: { _ in slot }, schedule: { clock.schedule($0, $1) })
    roots?.update(visible: ["a"], open: ["a"])
    roots?.update(visible: [], open: ["a"])
    roots = nil
    clock.advance(2)
    #expect(slot.subviews.count == 1)
  }
}
