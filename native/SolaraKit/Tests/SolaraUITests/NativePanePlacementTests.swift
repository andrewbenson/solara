import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct NativePanePlacementTests {
  @Test func slotPublicationWaitsForTheCompleteInstallation() {
    let slots = TabSlots()
    let a = NSView(), b = NSView()
    var seen: [Set<TabSlotKey>] = []
    let observer = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: slots, queue: nil) { _ in
      MainActor.assumeIsolated { seen.append(slots.keys) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    slots.performBatch {
      slots.set(.pane("w", "a"), container: a)
      slots.performBatch { slots.set(.pane("w", "b"), container: b) }
      #expect(seen.isEmpty)
    }
    #expect(seen == [Set([.pane("w", "a"), .pane("w", "b")])])
  }

  @Test func placementAndOldOwnerTeardownPreserveTheReplacementRegistration() throws {
    let state = try fixture()
    let first = SplitPanesView(windowId: "pane-placement")
    let second = SplitPanesView(windowId: "pane-placement")
    let snapshot = try snapshot(state, width: 1000)
    first.install(snapshot, state: state)
    let old = try #require(first.container("a"))
    let page = NSView()
    old.addSubview(page)
    let resized = try self.snapshot(state, width: 1200)
    first.install(resized, state: state)
    #expect(first.container("a") === old)
    #expect(old.subviews.first === page)
    second.install(resized, state: state)
    let replacement = try #require(second.container("a"))
    #expect(replacement !== old)
    first.stop()
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) === replacement)
    #expect(page.superview === old)
    second.stop()
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) == nil)
  }

  @Test func layoutMovesThePooledPageWithoutReplacingItsRegistrationOrSession() throws {
    let registry = PageRegistry()
    let view = SplitPanesView(windowId: "pane-placement")
    var state = try fixture()
    let pool = TabViewPool(make: { id, _ in RegisteredPlacementPage(id, registry: registry) }, schedule: { $0() })
    defer { view.stop(); pool.update([]) }
    view.install(try snapshot(state, width: 1000), state: state)
    pool.update([TabViewWanted(tabId: "a", windowId: "pane-placement", shown: .pane, identity: "chromium|p")])
    let first = try #require(pool.page("a") as? RegisteredPlacementPage)
    let registration = first.registration
    let descriptor = try #require(registry.descriptor(registration))
    for width: CGFloat in [800, 1000, 1200] {
      state.splits["s"]?.orientation = width == 1000 ? "vertical" : "horizontal"
      view.install(try snapshot(state, width: width), state: state)
      pool.reconcile()
      #expect(pool.page("a") === first)
      #expect(registry.descriptor(registration)?.registration == descriptor.registration)
      #expect(registry.descriptor(registration)?.sessionGeneration == descriptor.sessionGeneration)
      #expect(first.view.superview === view.container("a"))
      #expect(first.focused == 0)
    }
  }

  #if SOLARA_PROBES
  @Test func ownerStopEndsToastAndNoticeAnimationLinks() {
    let before = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? 0
    let chrome = SplitChromeView(windowId: "pane-placement")
    chrome.setToast(SplitToastSpec(id: 1, title: "Pane limit"))
    chrome.setNotice(SplitToastSpec(id: 2, title: "Session unavailable"))
    #expect((NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? 0) > before)
    chrome.stop()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == before)
  }
  #endif

  @Test func dividerResizePreservesTheMinimumWhenThereIsEnoughRoom() {
    let sizes = ShellGeometry.resize([0.5, 0.5], 0, delta: -1000, total: 1007)
    #expect(abs(sizes[0] * 1000 - ShellMetrics.minPane) < 0.001)
    #expect(abs(sizes.reduce(0, +) - 1) < 0.001)
  }

  @Test func installedShareBandShowsWithoutALegacyHeightFeed() throws {
    let state = try fixture()
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let clip = NSView()
    defer { overlays.stop() }
    overlays.setBand(clip, tabId: "a")
    overlays.install(try snapshot(state, width: 1000), state: state)
    #expect(clip.frame.height == 38)
    #expect(!clip.isHidden)
  }

  @Test func poolPreparationInstallsPendingNativeSlotsBeforePlanningPlacement() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let token = NSObject()
    let value = try snapshot(state, width: 1000)
    let oldCard = NSView()
    TabSlots.shared.set(.card("pane-placement"), container: oldCard)
    var pending: [@MainActor () -> Void] = []
    let pool = TabViewPool(make: { id, _ in RegisteredPlacementPage(id, registry: PageRegistry()) }, schedule: { pending.append($0) })
    pool.preparePlacement = { FrameUpdates.flush() }
    defer { view.stop(); overlays.stop(); pool.update([]); pool.reconcile(); TabSlots.shared.remove(.card("pane-placement"), container: oldCard) }
    FrameUpdates.schedule(token) {
      TabSlots.shared.performBatch {
        PaneOverlays.shared.performBatch {
          view.install(value, state: state)
          overlays.install(value, state: state)
        }
      }
    }
    pool.update([TabViewWanted(tabId: "a", windowId: "pane-placement", shown: .pane)])
    let work = pending
    pending = []
    work.forEach { $0() }
    #expect(pool.page("a")?.view.superview === view.container("a"))
    #expect(pool.page("a")?.view.superview !== oldCard)
    #expect(overlays.container("a", layer: .native)?.bounds.size == view.container("a")?.bounds.size)
  }

  @Test func aStoppedPaneOwnerRejectsQueuedInstallation() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let value = try snapshot(state, width: 1000)
    view.install(value, state: state)
    overlays.install(value, state: state)
    view.stop()
    overlays.stop()
    view.install(value, state: state)
    overlays.install(value, state: state)
    #expect(view.container("a") == nil)
    #expect(overlays.container("a", layer: .native) == nil)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) == nil)
  }

  @Test func aBorrowerSurfaceRejectsThePreviousHolderAfterHandoff() {
    #expect(FrozenPageIdentity.admits(tabId: "copy", copyId: "copy", holder: "source", copyHolder: "source"))
    #expect(!FrozenPageIdentity.admits(tabId: "copy", copyId: "copy", holder: nil, copyHolder: nil))
    #expect(FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: nil, copyHolder: "source"))
    #expect(FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: "copy", copyHolder: nil))
    #expect(!FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: nil, copyHolder: "other"))
  }

  @Test func geometryInstallsPageAndOverlayFromTheSameSnapshot() throws {
    var state = try fixture()
    let panes = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    defer { panes.stop(); overlays.stop() }
    for orientation in ["horizontal", "vertical"] {
      for ids in [["a", "b"], ["a", "b", "c"]] {
        for stack in [false, true] where !stack || ids.count == 3 {
          state.splits["s"] = SplitView(id: "s", windowId: "pane-placement", tabIds: ids, orientation: orientation,
            sizes: stack ? [0.4, 0.6] : Array(repeating: 1 / Double(ids.count), count: ids.count),
            stack: stack ? SplitStack(index: 1, sizes: [0.4, 0.6]) : nil)
          for size in [CGSize(width: 8, height: 700), CGSize(width: 1000, height: 8), CGSize(width: 1000, height: 700)] {
            let value = try snapshot(state, width: size.width, height: size.height)
            panes.install(value, state: state)
            overlays.install(value, state: state)
            for id in ids {
              if value.pages[id] == nil {
                #expect(panes.container(id) == nil)
                continue
              }
              let page = try #require(panes.container(id))
              let overlay = try #require(overlays.container(id, layer: .native))
              let expected = try #require(value.pages[id]).offsetBy(dx: -value.frames.card.minX, dy: -value.frames.card.minY)
              #expect(page.convert(page.bounds, to: panes) == expected)
              #expect(overlay.convert(overlay.bounds, to: overlays) == expected)
              #expect(page.bounds.width >= 0 && page.bounds.height >= 0)
            }
          }
        }
      }
    }
  }

  @Test func installedRightSidebarCaptionKeepsPageAndOverlayTogether() throws {
    var state = try fixture()
    state.windows["pane-placement"]?.sidebarPosition = "right"
    state.settings["addressBar"] = "sidebar"
    let panes = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    defer { panes.stop(); overlays.stop() }
    for orientation in ["horizontal", "vertical"] {
      state.splits["s"]?.orientation = orientation
      let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement",
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
        pageFacts: ["a": WindowLayoutPageFacts(registration: "a", top: 0, band: 38),
          "b": WindowLayoutPageFacts(registration: "b", top: 0)]))
      let value = WindowLayoutSnapshot.of(input, generation: 1)
      panes.install(value, state: state)
      overlays.install(value, state: state)
      let firstPane = try #require(value.panes["a"])
      let firstPage = try #require(value.pages["a"])
      #expect(firstPage.minY == firstPane.minY + ShellMetrics.toolbarHeight + 38)
      for id in ["a", "b"] {
        let page = try #require(panes.container(id))
        let overlay = try #require(overlays.container(id, layer: .native))
        let expected = try #require(value.pages[id]).offsetBy(dx: -value.frames.card.minX, dy: -value.frames.card.minY)
        #expect(page.convert(page.bounds, to: panes) == expected)
        #expect(overlay.convert(overlay.bounds, to: overlays) == expected)
      }
    }
  }

  private func fixture() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"pane-placement":{"id":"pane-placement","profileId":"p","sidebarOpen":true,"tabIds":["a","b","c"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"pane-placement","profileId":"p"},"b":{"id":"b","windowId":"pane-placement","profileId":"p"},"c":{"id":"c","windowId":"pane-placement","profileId":"p"}},"splits":{"s":{"id":"s","windowId":"pane-placement","tabIds":["a","b"],"orientation":"horizontal","sizes":[0.5,0.5]}}}"#).object ?? [:])
  }

  private func snapshot(_ state: BrowserState, width: CGFloat, height: CGFloat = 700) throws -> WindowLayoutSnapshot {
    let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement", bounds: CGRect(x: 0, y: 0, width: width, height: height),
      pageFacts: ["a": WindowLayoutPageFacts(registration: "a-registered", top: 71, band: 38), "b": WindowLayoutPageFacts(registration: "b-registered", top: 41)]))
    return .of(input, generation: 1)
  }
}

@MainActor
private final class RegisteredPlacementPage: TabPoolPage {
  let view = NSView()
  let registration: PageRegistration
  let registry: PageRegistry
  var focused = 0
  init(_ id: String, registry: PageRegistry) {
    self.registry = registry
    registration = registry.register(tabID: id, engine: .chromium, host: .pooled, sessionGeneration: "session-" + id) { _, finish in finish(.success(.null)) }
  }
  func setShown(_ shown: Bool) {}
  func focus() { focused += 1 }
  func retire() { registry.retire(registration); view.removeFromSuperview() }
}

@MainActor
@Suite(.serialized)
struct PaneGuestLifetimeTests {
  @Test func retirementWaitsForThePortalsMatchingRelease() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let generation = guest.generation
    guest.announce(generation: generation)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: generation + 1)
    #expect(ends == 0)
    guest.release(generation: generation)
    guest.release(generation: generation)
    #expect(ends == 1)
  }

  @Test func anOldPortalCleanupCannotReleaseTheReshownTarget() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.setShown(false)
    guest.setShown(true)
    let current = guest.generation
    guest.announce(generation: current)
    #expect(current > old)
    guest.release(generation: old)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: current)
    #expect(ends == 1)
    guest.setShown(true)
    #expect(!guest.shown)
  }

  @Test func reshowingWithoutPublicationKeepsTheOldPortalsReleaseObligation() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.announce(generation: old)
    guest.setShown(false)
    guest.setShown(true)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: old)
    #expect(ends == 1)
  }

  @Test func aNewLeaseRearmsAnEpochAfterThePreviousOwnersRelease() {
    let guest = PaneGuestLifetime()
    var announcements = PaneGuestAnnouncements()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let generation = guest.generation
    let oldLease = announcements.acquire(generation)
    guest.announce(generation: generation)
    if announcements.reject(generation, ticket: oldLease) { guest.release(generation: generation) }
    let newLease = announcements.acquire(generation)
    guest.announce(generation: generation)
    if announcements.reject(generation, ticket: oldLease) { guest.release(generation: generation) }
    guest.retire()
    #expect(ends == 0)
    if announcements.reject(generation, ticket: newLease) { guest.release(generation: generation) }
    #expect(ends == 1)
  }

  @Test func eachAnnouncedEpochNeedsItsOwnReleaseBeforeTheRootCanEnd() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.announce(generation: old)
    guest.setShown(false)
    guest.setShown(true)
    let current = guest.generation
    guest.announce(generation: current)
    guest.retire()
    guest.release(generation: current)
    #expect(ends == 0)
    guest.release(generation: old)
    #expect(ends == 1)
  }

  @Test func aNeverAnnouncedTargetRetiresWithoutAPortalRelease() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    guest.retire()
    #expect(ends == 1)
  }

  @Test func aReleasedHiddenTargetEndsWithoutWaitingOnHostStop() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    guest.setShown(false)
    guest.release(generation: guest.generation)
    #expect(ends == 0)
    guest.retire()
    guest.retire()
    #expect(ends == 1)
  }
}

@Suite struct PaneGuestAnnouncementTests {
  @Test func acquisitionsRemainUniqueAcrossEpochsAndLateReceiptsAreInert() {
    var announcements = PaneGuestAnnouncements()
    let first = announcements.acquire(5)
    let second = announcements.acquire(5)
    let other = announcements.acquire(6)
    #expect(first != second && second != other && first != other)
    let firstReleasedLast = announcements.reject(5, ticket: first)
    let duplicateReleasedLast = announcements.reject(5, ticket: first)
    let wrongEpochReleasedLast = announcements.reject(5, ticket: other)
    #expect(!firstReleasedLast)
    #expect(!duplicateReleasedLast)
    #expect(!wrongEpochReleasedLast)
    #expect(announcements.contains(5))
    let secondReleasedLast = announcements.reject(5, ticket: second)
    #expect(secondReleasedLast)
    #expect(announcements.contains(6))
    let otherReleasedLast = announcements.reject(6, ticket: other)
    #expect(otherReleasedLast)
  }

  @Test func aRejectedOlderPublicationPreservesTheAcceptedOne() {
    var announcements = PaneGuestAnnouncements()
    announcements.announce(7, ticket: 1)
    announcements.announce(7, ticket: 2)
    let olderRejected = announcements.reject(7, ticket: 1)
    #expect(!olderRejected)
    #expect(announcements.contains(7))
    let newerRejected = announcements.reject(7, ticket: 2)
    #expect(newerRejected)
    #expect(!announcements.contains(7))
  }

  @Test func aSynchronousReadCannotBeErasedByAFailedPublication() {
    var announcements = PaneGuestAnnouncements()
    announcements.announce(8, ticket: 0)
    announcements.announce(8, ticket: 4)
    let publicationRejected = announcements.reject(8, ticket: 4)
    #expect(!publicationRejected)
    #expect(announcements.contains(8))
    announcements.remove(8)
    #expect(!announcements.contains(8))
  }
}
