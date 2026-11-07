import AppKit
import Foundation
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct HeavyTabPolicyTests {
  private func cpu(_ cpuMs: Double, at elapsedMs: Double, id: String = "m1") -> TabCPUSample {
    TabCPUSample(cpuMs: cpuMs, elapsedMs: elapsedMs, measurementId: id)
  }

  private func feed(_ policy: inout HeavyTabPolicy, percents: [Double], from start: Double = 0, cpuStart: Double = 0, id: String = "m1") -> (Double, Double) {
    var elapsed = start
    var used = cpuStart
    for percent in percents {
      elapsed += 15_000
      used += 15_000 * percent / 100
      policy.ingest("a", cpu: cpu(used, at: elapsed, id: id), memoryBytes: nil)
    }
    return (elapsed, used)
  }

  @Test func cpuAboveHalfACoreForFourIntervalsIsHeavy() {
    var policy = HeavyTabPolicy()
    policy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    _ = feed(&policy, percents: [80, 80, 80])
    #expect(policy.heavy["a"] == nil)
    _ = feed(&policy, percents: [80], from: 45_000, cpuStart: 36_000)
    #expect(policy.heavy["a"] == .cpu)
  }

  @Test func exactlyHalfACoreIsNotHigh() {
    var policy = HeavyTabPolicy()
    policy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    _ = feed(&policy, percents: [50, 50, 50, 50, 50])
    #expect(policy.heavy["a"] == nil)
  }

  @Test func aLowIntervalRestartsTheWindowAndTwoLowIntervalsClearIt() {
    var policy = HeavyTabPolicy()
    policy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    var (elapsed, used) = feed(&policy, percents: [80, 80, 80, 10])
    (elapsed, used) = feed(&policy, percents: [80, 80, 80], from: elapsed, cpuStart: used)
    #expect(policy.heavy["a"] == nil)
    (elapsed, used) = feed(&policy, percents: [80], from: elapsed, cpuStart: used)
    #expect(policy.heavy["a"] == .cpu)
    (elapsed, used) = feed(&policy, percents: [10], from: elapsed, cpuStart: used)
    #expect(policy.heavy["a"] == .cpu)
    _ = feed(&policy, percents: [10], from: elapsed, cpuStart: used)
    #expect(policy.heavy["a"] == nil)
  }

  @Test func aNewMeasurementIdentityOrAMissingSampleClearsAtOnce() {
    var policy = HeavyTabPolicy()
    policy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    let (elapsed, used) = feed(&policy, percents: [80, 80, 80, 80])
    #expect(policy.heavy["a"] == .cpu)
    policy.ingest("a", cpu: cpu(used + 1_000, at: elapsed + 15_000, id: "m2"), memoryBytes: nil)
    #expect(policy.heavy["a"] == nil)
    var other = HeavyTabPolicy()
    other.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    _ = feed(&other, percents: [80, 80, 80, 80])
    other.ingest("a", cpu: nil, memoryBytes: nil)
    #expect(other.heavy["a"] == nil)
  }

  @Test func aStaleIntervalOrACounterGoingBackwardsIsNotARate() {
    var policy = HeavyTabPolicy()
    policy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    policy.ingest("a", cpu: cpu(60_000, at: 60_000), memoryBytes: nil)
    _ = feed(&policy, percents: [80, 80, 80], from: 60_000, cpuStart: 60_000)
    #expect(policy.heavy["a"] == nil)
    var backwards = HeavyTabPolicy()
    backwards.ingest("a", cpu: cpu(5_000, at: 0), memoryBytes: nil)
    backwards.ingest("a", cpu: cpu(1_000, at: 15_000), memoryBytes: nil)
    _ = feed(&backwards, percents: [80, 80, 80], from: 15_000, cpuStart: 1_000)
    #expect(backwards.heavy["a"] == nil)
  }

  @Test func memoryAbove800MiBForTwoSamplesIsHeavyAndTwoBelowClearIt() {
    var policy = HeavyTabPolicy()
    let high = SidebarTabMemory.highBytes + 1
    policy.ingest("a", cpu: nil, memoryBytes: high)
    #expect(policy.heavy["a"] == nil)
    policy.ingest("a", cpu: nil, memoryBytes: high)
    #expect(policy.heavy["a"] == .memory)
    policy.ingest("a", cpu: nil, memoryBytes: SidebarTabMemory.highBytes)
    #expect(policy.heavy["a"] == .memory)
    policy.ingest("a", cpu: nil, memoryBytes: SidebarTabMemory.highBytes)
    #expect(policy.heavy["a"] == nil)
    policy.ingest("a", cpu: nil, memoryBytes: high)
    policy.ingest("a", cpu: nil, memoryBytes: high)
    policy.ingest("a", cpu: nil, memoryBytes: nil)
    #expect(policy.heavy["a"] == nil)
  }

  @Test func aSkippedMemorySampleChangesNothingAndAStaleGapKeepsTheBadge() {
    var policy = HeavyTabPolicy()
    let high = SidebarTabMemory.highBytes + 1
    policy.ingest("a", cpu: nil, memory: .sampled(high))
    policy.ingest("a", cpu: nil, memory: .skipped)
    policy.ingest("a", cpu: nil, memory: .sampled(high))
    #expect(policy.heavy["a"] == .memory)
    policy.ingest("a", cpu: nil, memory: .skipped)
    #expect(policy.heavy["a"] == .memory)
    var cpuPolicy = HeavyTabPolicy()
    cpuPolicy.ingest("a", cpu: cpu(0, at: 0), memoryBytes: nil)
    let (elapsed, used) = feed(&cpuPolicy, percents: [80, 80, 80, 80])
    #expect(cpuPolicy.heavy["a"] == .cpu)
    cpuPolicy.ingest("a", cpu: cpu(used + 100_000, at: elapsed + 600_000), memoryBytes: nil)
    #expect(cpuPolicy.heavy["a"] == .cpu)
  }

  @Test func retainingDropsTabsThatAreGone() {
    var policy = HeavyTabPolicy()
    let high = SidebarTabMemory.highBytes + 1
    for id in ["a", "b"] { for _ in 0..<2 { policy.ingest(id, cpu: nil, memoryBytes: high) } }
    policy.retain(["b"])
    #expect(policy.heavy == ["b": .memory])
  }
}

@Suite struct TabCPUReplyTests {
  @Test func decodesTheContractAndSkipsBadRows() {
    let rows: [[String: Any]] = [
      ["tabId": 17, "cpuMs": 1234.5, "elapsedMs": 10_000.0, "measurementId": "p1", "source": "attribution", "at": 1_794_000_000_000.0],
      ["tabId": 18.0, "cpuMs": 0, "elapsedMs": 0, "measurementId": "p2", "source": "attribution", "at": 1.0],
      ["tabId": 19.5, "cpuMs": 1, "elapsedMs": 1, "measurementId": "p3", "source": "attribution", "at": 1.0],
      ["tabId": 20, "cpuMs": -1, "elapsedMs": 1, "measurementId": "p4", "source": "attribution", "at": 1.0],
      ["tabId": 21, "cpuMs": 1, "elapsedMs": 1, "measurementId": "", "source": "attribution", "at": 1.0],
      ["tabId": 22, "cpuMs": 1, "elapsedMs": 1, "measurementId": "p6", "source": "footprint", "at": 1.0],
      ["tabId": true, "cpuMs": 1, "elapsedMs": 1, "measurementId": "p7", "source": "attribution", "at": 1.0],
    ]
    let decoded = TabCPUReply.decode(["tabs": rows])
    #expect(decoded == [17: TabCPUSample(cpuMs: 1234.5, elapsedMs: 10_000, measurementId: "p1"), 18: TabCPUSample(cpuMs: 0, elapsedMs: 0, measurementId: "p2")])
    #expect(TabCPUReply.decode(["error": "the engine has no ac_tabs_cpu"]) == nil)
    #expect(TabCPUReply.decode([:]) == nil)
    #expect(TabCPUReply.decode(["tabs": []]) == [:])
  }
}

@MainActor
@Suite(.serialized) struct HeavyTabMonitorTests {
  private final class Rig {
    var tick: (@MainActor () -> Void)?
    var replies: [@MainActor (HeavyTabSamples?) -> Void] = []
    var asked: [(ids: [String], memory: Bool)] = []
    let center = NotificationCenter()
  }

  private func monitor(_ rig: Rig, active: Bool = true, candidates: @escaping @MainActor () -> [String] = { ["a", "b"] }) -> HeavyTabMonitor {
    HeavyTabMonitor(
      sample: { ids, memory, reply in rig.asked.append((ids, memory)); rig.replies.append(reply) },
      candidates: candidates,
      schedule: { interval, fire in
        #expect(interval == HeavyTabPolicy.intervalMs)
        rig.tick = fire
        return { rig.tick = nil }
      },
      initiallyActive: active, notificationCenter: rig.center)
  }

  @Test func oneSampleAtATimeAndMemoryOnlyEveryFourthTick() {
    defer { HeavyTabs.publish([:]) }
    let rig = Rig()
    let heavy = monitor(rig)
    heavy.start()
    rig.tick?()
    rig.tick?()
    #expect(rig.asked.map(\.memory) == [true])
    let high = HeavyTabSamples(cpu: [:], memoryBytes: ["a": SidebarTabMemory.highBytes + 1])
    rig.replies[0](high)
    for index in 1..<4 {
      rig.tick?()
      rig.replies[index](HeavyTabSamples(cpu: [:], memoryBytes: nil))
    }
    #expect(rig.asked.map(\.memory) == [true, false, false, false])
    #expect(HeavyTabs.current.isEmpty)
    rig.tick?()
    #expect(rig.asked.last?.memory == true)
    rig.replies[4](high)
    #expect(HeavyTabs.current == ["a": .memory])
    heavy.stop()
    #expect(HeavyTabs.current.isEmpty)
    #expect(rig.tick == nil)
  }

  @Test func nothingIsSampledWhileSolaraIsInTheBackgroundAndActivationSamplesAtOnce() {
    defer { HeavyTabs.publish([:]) }
    let rig = Rig()
    let heavy = monitor(rig, active: false)
    heavy.start()
    rig.tick?()
    rig.tick?()
    #expect(rig.asked.isEmpty)
    rig.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(rig.asked.count == 1)
    #expect(rig.asked.first?.memory == true)
    rig.replies[0](nil)
    rig.center.post(name: NSApplication.didResignActiveNotification, object: nil)
    rig.tick?()
    #expect(rig.asked.count == 1)
    heavy.stop()
    rig.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(rig.asked.count == 1)
  }

  @Test func capsHowManyTabsOneSampleAsksFor() {
    let rig = Rig()
    let heavy = monitor(rig, candidates: { (0..<100).map { "t\($0)" } })
    heavy.start()
    rig.tick?()
    #expect(rig.asked.first?.ids.count == HeavyTabMonitor.maxTabs)
    heavy.stop()
  }
}

@MainActor
@Suite struct HeavyTabCardTests {
  private func state(sleeping: Bool = false) throws -> SidebarTabCardState {
    let value: [String: Any] = [
      "tabId": "a", "title": "Example", "host": "example.com", "sleeping": sleeping,
      "buttons": [["action": "pin", "icon": "pin", "label": "Pin"]],
      "anchor": [8, 100, 184, 34], "sidebarWidth": 200, "windowHeight": 800,
      "look": ["fill": "#262626", "border": "#404040", "primary": "#FFFFFF", "secondary": "#FFFFFF99",
               "tertiary": "#FFFFFF59", "hover": "#FFFFFF1A", "pressed": "#FFFFFF2E", "shadowOpacity": 0.5],
    ]
    return try #require(SidebarTabCardState.decode(value))
  }

  @Test func aHeavyAwakeTabOffersSleepOnlyWhenTheRunnerCan() throws {
    let base = try state()
    #expect(base.offeringSleep(heavy: .cpu, canSleep: true).buttons.last == .sleepHeavy)
    #expect(base.offeringSleep(heavy: .cpu, canSleep: true).offeringSleep(heavy: .cpu, canSleep: true).buttons.filter { $0 == .sleepHeavy }.count == 1)
    #expect(base.offeringSleep(heavy: nil, canSleep: true) == base)
    #expect(base.offeringSleep(heavy: .memory, canSleep: false) == base)
    #expect(try state(sleeping: true).offeringSleep(heavy: .memory, canSleep: true) == state(sleeping: true))
  }

  @Test func theBadgeTakesAFreeCorner() {
    let badges = TabBadgesView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    badges.set(pip: false, capture: nil, heavy: .cpu, iconSize: 16, badge: .gray, badgeGlyph: .white)
    #expect(badges.heavyShown == .cpu)
    #expect(!badges.isEmpty)
    badges.set(pip: false, capture: .camera, heavy: .cpu, iconSize: 16, badge: .gray, badgeGlyph: .white)
    #expect(badges.heavyShown == .cpu)
    badges.set(pip: true, capture: .camera, heavy: .cpu, iconSize: 16, badge: .gray, badgeGlyph: .white)
    #expect(badges.heavyShown == nil)
  }
}

@MainActor
private func badgeViews(in root: NSView) -> [TabBadgesView] {
  root.subviews.flatMap { ($0 as? TabBadgesView).map { [$0] } ?? [] + badgeViews(in: $0) }
}

@MainActor
@Suite(.serialized) struct HeavyTabRefreshTests {
  private func state() throws -> BrowserState {
    let text = #"""
      {"profileOrder": ["p"],
       "windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "b"}}},
       "windowOrder": ["w1"],
       "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/"},
                "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/"}}}
      """#
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  @Test func theSidebarShowsAndDropsTheBadgeWhenTheHeavySetChangesAlone() throws {
    defer { HeavyTabs.publish([:]) }
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
    pager.update(state: try state(), host: SidebarHostState(profileId: "p"))
    pager.layoutSubtreeIfNeeded()
    #expect(badgeViews(in: pager).filter { !$0.isHidden }.isEmpty)
    HeavyTabs.publish(["a": .cpu])
    pager.layoutSubtreeIfNeeded()
    #expect(badgeViews(in: pager).filter { !$0.isHidden }.map(\.heavyShown) == [.cpu])
    HeavyTabs.publish([:])
    pager.layoutSubtreeIfNeeded()
    #expect(badgeViews(in: pager).filter { !$0.isHidden }.isEmpty)
  }

  @Test func theTopStripShowsTheBadgeWhenTheHeavySetChangesAlone() throws {
    defer { HeavyTabs.publish([:]) }
    let strip = TopStripView(windowId: "w1")
    strip.frame = NSRect(x: 0, y: 0, width: 900, height: 44)
    strip.update(state: try state(), host: StripHostState(profileId: "p"))
    strip.layoutSubtreeIfNeeded()
    #expect(badgeViews(in: strip).filter { !$0.isHidden }.isEmpty)
    HeavyTabs.publish(["a": .memory])
    strip.layoutSubtreeIfNeeded()
    #expect(badgeViews(in: strip).filter { !$0.isHidden }.map(\.heavyShown) == [.memory])
  }

  @Test func aSleepingTabNeverCarriesTheBadge() throws {
    defer { HeavyTabs.publish([:]) }
    HeavyTabs.publish(["a": .memory])
    var host = SidebarHostState(profileId: "p")
    host.sleeping = ["a"]
    #expect(SidebarFlags(host).heavy.isEmpty)
    #expect(SidebarFlags(SidebarHostState(profileId: "p")).heavy == ["a": .memory])
  }
}
