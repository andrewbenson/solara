import AppKit
import Foundation
import Testing
@testable import SolaraUI

@Suite struct ProfileWarmupTests {
  @Test func historyKeepsTheMostRecentSwitchFirstWithoutDuplicates() {
    var history = ProfileWarmHistory()
    let first = history.switched(to: "work")
    #expect(first)
    history.switched(to: "default")
    history.switched(to: "home")
    history.switched(to: "work")
    #expect(history.recent == ["work", "home", "default"])
    let repeated = !history.switched(to: "work")
    #expect(repeated)
    for n in 0..<12 { history.switched(to: "p\(n)") }
    #expect(history.recent.count == ProfileWarmHistory.limit)
    #expect(history.recent.first == "p11")
  }

  @Test func historyForgetsDeletedProfilesAndRoundTrips() throws {
    var history = ProfileWarmHistory(recent: ["a", "b", "a", "c"])
    #expect(history.recent == ["a", "b", "c"])
    let dropped = history.keepOnly(["a", "c"])
    #expect(dropped)
    #expect(history.recent == ["a", "c"])
    let unchanged = !history.keepOnly(["a", "c", "d"])
    #expect(unchanged)
    let data = try JSONEncoder().encode(history)
    #expect(try JSONDecoder().decode(ProfileWarmHistory.self, from: data) == history)
  }

  @Test func theIdleTargetIsTheMostRecentProfileNoWindowShows() {
    let engines = ["default": "", "work": "work", "home": "home-data", "spare": "spare"]
    let target = ProfileWarmup.idleTarget(recent: ["default", "home", "work"], engines: engines, shownEngines: [""], loadAll: false, lowPower: false)
    #expect(target == "home-data")
    let skipsShown = ProfileWarmup.idleTarget(recent: ["home", "work"], engines: engines, shownEngines: ["", "home-data"], loadAll: false, lowPower: false)
    #expect(skipsShown == "work")
    let skipsDeleted = ProfileWarmup.idleTarget(recent: ["gone", "work"], engines: engines, shownEngines: [""], loadAll: false, lowPower: false)
    #expect(skipsDeleted == "work")
  }

  @Test func theIdleWarmUpLoadsNothingWithoutHistoryOnLowPowerOrWhenEveryProfileLoads() {
    let engines = ["default": "", "work": "work"]
    let noHistory = ProfileWarmup.idleTarget(recent: [], engines: engines, shownEngines: [""], loadAll: false, lowPower: false)
    #expect(noHistory == nil)
    let onlyShown = ProfileWarmup.idleTarget(recent: ["default"], engines: engines, shownEngines: [""], loadAll: false, lowPower: false)
    #expect(onlyShown == nil)
    let lowPower = ProfileWarmup.idleTarget(recent: ["work"], engines: engines, shownEngines: [""], loadAll: false, lowPower: true)
    #expect(lowPower == nil)
    let loadAll = ProfileWarmup.idleTarget(recent: ["work"], engines: engines, shownEngines: [""], loadAll: true, lowPower: false)
    #expect(loadAll == nil)
  }

  @Test func idleScheduleWaitsForLaunchSettledAndTenQuietSecondsThenFiresOnce() {
    var schedule = IdleWarmSchedule(startedAt: 100)
    #expect(schedule.check(now: 103, inputIdleSeconds: 3600, launchSettled: true) == .wait(7))
    #expect(schedule.check(now: 110, inputIdleSeconds: 3600, launchSettled: false) == .wait(1))
    #expect(schedule.check(now: 111, inputIdleSeconds: 4, launchSettled: true) == .wait(6))
    #expect(schedule.check(now: 117, inputIdleSeconds: 9.5, launchSettled: true) == .wait(1))
    #expect(schedule.check(now: 118, inputIdleSeconds: 10, launchSettled: true) == .warm)
    #expect(schedule.done)
    #expect(schedule.check(now: 200, inputIdleSeconds: 3600, launchSettled: true) == nil)
  }

  @Test func hoverStartsOnlyAfterTheDebounceAndARepeatKeepsTheTimer() {
    var debounce = ProfileIntentDebounce()
    guard case .schedule(let due) = debounce.hover("work", now: 10) else {
      Issue.record("hover did not schedule")
      return
    }
    #expect(abs(due - 10.15) < 1e-9)
    #expect(debounce.fire(now: 10.1) == nil)
    #expect(debounce.hover("work", now: 10.12) == .keep)
    #expect(debounce.fire(now: 10.15) == "work")
    #expect(debounce.fire(now: 10.3) == nil)
  }

  @Test func passingOverProfilesStartsNoneAndLeavingCancels() {
    var debounce = ProfileIntentDebounce()
    _ = debounce.hover("a", now: 0)
    _ = debounce.hover("b", now: 0.05)
    _ = debounce.hover("c", now: 0.1)
    #expect(debounce.fire(now: 0.15) == nil)
    #expect(debounce.hover(nil, now: 0.21) == .cancel)
    #expect(debounce.fire(now: 1) == nil)
    #expect(debounce.pending == nil)
    #expect(debounce.hover("c", now: 2) == .schedule(2 + ProfileIntentDebounce.delay))
    #expect(debounce.fire(now: 2.15) == "c")
  }

  @Test func historyLivesInTheDataFolder() {
    let support = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
    let scratch = ProfileWarmup.historyURL(environment: ["SOLARA_DATA_DIR": "/tmp/scratch/"], applicationSupport: support, bundleId: "b")
    #expect(scratch?.path == "/tmp/scratch/profile-warmup.json")
    let installed = ProfileWarmup.historyURL(environment: [:], applicationSupport: support, bundleId: "network.benson.solara")
    #expect(installed?.path == "/Users/x/Library/Application Support/network.benson.solara/profile-warmup.json")
    #expect(ProfileWarmup.historyURL(environment: [:], applicationSupport: nil, bundleId: nil) == nil)
  }

  @MainActor @Test func hoveringFooterDotsAndRailRowsReportsTheProfileUnderThePointer() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: 3, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: true, addressBar: true, dark: false, theme: [:],
      dots: [SidebarChromeDot(id: "p1", name: "Work", slot: 0), SidebarChromeDot(id: "p2", name: "Home", slot: 1), SidebarChromeDot(id: "p3", name: "Spare", slot: 2)],
      savedWidth: 240, iconsOnly: false, update: nil))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }
    dots[1].setHovered(true)
    #expect(actions.last == .profileIntent("p2"))
    dots[2].setHovered(true)
    dots[1].setHovered(false)
    #expect(actions.last == .profileIntent("p3"))
    dots[2].setHovered(false)
    #expect(actions.last == .profileIntent(nil))
    dots[2].setHovered(true)
    dots[0].setHovered(true)
    dots[2].setHovered(false)
    #expect(actions.suffix(3) == [.profileIntent("p3"), .profileIntent("p1"), .profileIntent("p1")])
    #expect(!actions.contains { if case .switchProfile = $0 { true } else { false } })
  }
}
