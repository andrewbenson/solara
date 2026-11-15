import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct LaunchWorkSchedulerTests {
  final class Clock { var now = 0.0 }

  func ready(_ scheduler: LaunchWorkScheduler, _ window: LaunchWorkScheduler.Window) {
    for stage in LaunchWorkScheduler.Prerequisite.allCases { _ = scheduler.reach(stage, window: window) }
  }

  @Test func prerequisitesRequireGuestAndChromeCommitInOrder() {
    let scheduler = LaunchWorkScheduler(clock: { 0 })
    let window = scheduler.begin(windowId: "a", generation: 1)
    var runs = 0
    scheduler.enqueue(id: "job") { _ in runs += 1; return true }
    #expect(!scheduler.reach(.chromeCommit, window: window))
    for stage in [LaunchWorkScheduler.Prerequisite.store, .owner, .slots] { #expect(scheduler.reach(stage, window: window)) }
    #expect(!scheduler.idleOpportunity())
    #expect(!scheduler.reach(.chromeCommit, window: window))
    #expect(scheduler.reach(.guest, window: window))
    #expect(!scheduler.idleOpportunity())
    #expect(scheduler.reach(.chromeCommit, window: window))
    #expect(scheduler.idleOpportunity())
    #expect(runs == 1)
  }

  @Test func eachOpportunityRunsOneBoundedChunkAndDemandPromotes() {
    let clock = Clock()
    let scheduler = LaunchWorkScheduler(clock: { clock.now })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    var order: [String] = []
    scheduler.enqueue(id: "high", priority: 5) { deadline in
      #expect(deadline == clock.now + 0.002)
      order.append("high")
      return order.count > 2
    }
    let low = scheduler.enqueue(id: "low") { _ in order.append("low"); return true }
    #expect(scheduler.idleOpportunity())
    #expect(order == ["high"])
    scheduler.promote(low)
    #expect(scheduler.idleOpportunity())
    #expect(order == ["high", "low"])
    #expect(scheduler.idleOpportunity())
    #expect(order == ["high", "low", "high"])
  }

  @Test func expiredDeadlinesPreventStarvationAndChunksYieldFairly() {
    let clock = Clock()
    let scheduler = LaunchWorkScheduler(clock: { clock.now })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    var order: [String] = []
    scheduler.enqueue(id: "high", priority: 100, deadline: 30) { _ in order.append("high"); return false }
    scheduler.enqueue(id: "old", deadline: 1) { _ in order.append("old"); return true }
    #expect(scheduler.idleOpportunity())
    clock.now = 2
    #expect(scheduler.idleOpportunity())
    #expect(order == ["high", "old"])
  }

  @Test func inputAndResizePauseEvenExpiredAndDemandedJobs() {
    let scheduler = LaunchWorkScheduler(clock: { 100 })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    var runs = 0
    let token = scheduler.enqueue(id: "job", deadline: 0) { _ in runs += 1; return true }
    scheduler.promote(token)
    scheduler.paused = true
    #expect(!scheduler.idleOpportunity())
    #expect(runs == 0)
    scheduler.paused = false
    #expect(scheduler.idleOpportunity())
  }

  @Test func closeReopenAndReplacementFenceScopedJobsAndStaleCommits() {
    let scheduler = LaunchWorkScheduler(clock: { 0 })
    let old = scheduler.begin(windowId: "a", generation: 1)
    ready(scheduler, old)
    var runs = 0
    scheduler.enqueue(id: "old", window: old) { _ in runs += 1; return false }
    #expect(scheduler.idleOpportunity())
    let replacement = scheduler.begin(windowId: "a", generation: 2)
    #expect(!scheduler.reach(.chromeCommit, window: old))
    ready(scheduler, replacement)
    #expect(!scheduler.idleOpportunity())
    #expect(runs == 1)
    scheduler.end(old)
    #expect(scheduler.hasReadyWindow)
    scheduler.end(replacement)
    #expect(!scheduler.hasReadyWindow)
    #expect(scheduler.cancelled == 1)
  }

  @Test func callbackCancellationAndQuitCannotReinsertAChunk() {
    let scheduler = LaunchWorkScheduler(clock: { 0 })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    scheduler.enqueue(id: "quit") { _ in scheduler.quit(); return false }
    #expect(scheduler.idleOpportunity())
    #expect(scheduler.pending == 0)
    #expect(!scheduler.hasReadyWindow)
    scheduler.enqueue(id: "late") { _ in Issue.record("quit work ran"); return true }
    #expect(!scheduler.idleOpportunity())
  }

  @Test func scopedJobWaitsForItsOwnWindowAndDoesNotRequestIdleWakeups() {
    let scheduler = LaunchWorkScheduler(clock: { 0 })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    let pending = scheduler.begin(windowId: "b", generation: 2)
    var runs = 0
    scheduler.enqueue(id: "b", window: pending) { _ in runs += 1; return true }
    #expect(!scheduler.runnable)
    #expect(!scheduler.idleOpportunity())
    #expect(runs == 0)
    ready(scheduler, pending)
    #expect(scheduler.runnable)
    #expect(scheduler.idleOpportunity())
    #expect(runs == 1)
  }

  @Test func lostInputReleaseAndClosedResizeCannotStarveWork() {
    let clock = Clock()
    let input = LaunchWorkInteraction(clock: { clock.now })
    input.hold("key.1", window: 1, active: true)
    #expect(input.paused)
    clock.now = 1
    #expect(input.paused)
    input.deactivate()
    clock.now = 2
    #expect(!input.paused)
    input.hold("mouse.0", window: 2, active: true)
    input.resize(window: 2, active: true)
    clock.now = 3
    #expect(input.paused)
    input.close(window: 2)
    clock.now = 4
    #expect(!input.paused)
    input.hold("gesture", window: 3, active: true)
    input.close(window: 2)
    clock.now = 5
    #expect(input.paused)
    input.hold("gesture", window: 3, active: false)
    clock.now = 6
    #expect(!input.paused)
  }

  @Test func repeatedExpiredChunksYieldToOtherExpiredJobs() {
    let scheduler = LaunchWorkScheduler(clock: { 0 })
    ready(scheduler, scheduler.begin(windowId: "a", generation: 1))
    var order: [String] = []
    scheduler.enqueue(id: "first", priority: 100, deadline: 0) { _ in order.append("first"); return false }
    scheduler.enqueue(id: "second", deadline: 0) { _ in order.append("second"); return true }
    #expect(scheduler.idleOpportunity())
    #expect(scheduler.idleOpportunity())
    #expect(order == ["first", "second"])
  }

  @Test func retainedHideClearsOnlyItsGenerationAndReopenDoesNotRestoreLostHolds() {
    let clock = Clock()
    let input = LaunchWorkInteraction(clock: { clock.now })
    input.register(windowId: "retained", generation: 1, number: 11)
    input.register(windowId: "other", generation: 2, number: 22)
    input.hold("key.1", window: 11, active: true)
    input.resize(window: 11, active: true)
    clock.now = 1
    #expect(input.paused)
    input.setRetained(windowId: "retained", generation: 1, on: true)
    input.setRetained(windowId: "retained", generation: 1, on: false)
    clock.now = 2
    #expect(!input.paused)
    input.hold("mouse.0", window: 22, active: true)
    input.hold("key.1", window: 11, active: true)
    input.setRetained(windowId: "retained", generation: 1, on: true)
    clock.now = 3
    #expect(input.paused)
    input.hold("mouse.0", window: 22, active: false)
    clock.now = 4
    #expect(!input.paused)
    input.register(windowId: "retained", generation: 3, number: 33)
    input.hold("key.3", window: 33, active: true)
    input.resize(window: 33, active: true)
    input.endOwner(windowId: "retained", generation: 1)
    input.setRetained(windowId: "retained", generation: 1, on: true)
    clock.now = 5
    #expect(input.paused)
    input.setRetained(windowId: "retained", generation: 3, on: true)
    clock.now = 6
    #expect(!input.paused)
  }

  @Test func emptyReactAppContainerDoesNotProveRequiredGuestMounted() {
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let appContainer = NSView(frame: root.bounds)
    root.addSubview(appContainer)
    #expect(!LaunchGuestReadiness.contains(in: root, windowId: "w1"))
    let guest = NSView(frame: root.bounds)
    guest.setAccessibilityIdentifier("solara-window-guest.w1")
    appContainer.addSubview(guest)
    #expect(LaunchGuestReadiness.contains(in: root, windowId: "w1"))
    #expect(!LaunchGuestReadiness.contains(in: root, windowId: "w2"))
    guest.removeFromSuperview()
    #expect(!LaunchGuestReadiness.contains(in: root, windowId: "w1"))
  }

  @Test func requiredGuestNeedsNativeLayoutAndVisibleAncestor() {
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let container = NSView(frame: root.bounds)
    let guest = NSView(frame: .zero)
    guest.setAccessibilityIdentifier("solara-window-guest.w1")
    root.addSubview(container)
    container.addSubview(guest)
    #expect(!LaunchGuestReadiness.contains(in: root, windowId: "w1"))
    guest.frame = root.bounds
    #expect(LaunchGuestReadiness.contains(in: root, windowId: "w1"))
    container.isHidden = true
    #expect(!LaunchGuestReadiness.contains(in: root, windowId: "w1"))
    container.isHidden = false
    root.alphaValue = 0
    #expect(LaunchGuestReadiness.contains(in: root, windowId: "w1"))
  }
}
