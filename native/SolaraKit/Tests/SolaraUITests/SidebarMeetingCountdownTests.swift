import AppKit
import SolaraLive
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarMeetingCountdownTests {
  private let minute = 60_000.0

  private func meeting(endingIn minutes: Double?, ended: Bool = false) -> MeetingGroup {
    let now = Date().timeIntervalSince1970 * 1000
    return MeetingGroup(
      groupId: "g1", callTabId: "t4", occurrence: nil, title: "Standup", start: now - 20 * minute,
      end: minutes.map { now + $0 * minute }, endedAt: ended ? now : nil)
  }

  private func state() throws -> BrowserState {
    let ids = ["t1", "t2", "t3", "t4", "t5"]
    var tabs: [String: Any] = [:]
    for id in ids { tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://\(id).example/", "title": id] }
    let root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ids, "activeTabIds": ["p": "t1"]]],
      "groups": ["g1": ["id": "g1", "windowId": "w", "name": "Standup", "tabIds": ["t4", "t5"], "collapsed": false]],
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func header(with group: MeetingGroup?) throws -> (NSWindow, SidebarView, NSView) {
    var live = LiveState()
    if let group { live.meetingGroups[group.groupId] = group }
    SidebarLiveFeed.shared.apply(live)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
    window.contentView = sidebar
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar, try #require(sidebar.views["gh:g1"]))
  }

  private func countdownLabel(in view: NSView) -> NSTextField? {
    for sub in view.subviews {
      if let field = sub as? NSTextField, !(field is FadeLabel), field.font?.pointSize == 11 { return field }
      if let found = countdownLabel(in: sub) { return found }
    }
    return nil
  }

  private func fadeLabel(in view: NSView) -> FadeLabel? {
    for sub in view.subviews {
      if let label = sub as? FadeLabel { return label }
      if let found = fadeLabel(in: sub) { return found }
    }
    return nil
  }

  @Test func theLabelReadsLikeRNs() {
    let now = 1_000_000_000.0
    #expect(SidebarMeetingCountdown.timeRemaining(end: now + 4.2 * minute, now: now) == "5 min left")
    #expect(SidebarMeetingCountdown.timeRemaining(end: now + 75 * minute, now: now) == "1 hr 15 min left")
    #expect(SidebarMeetingCountdown.timeRemaining(end: now - minute, now: now) == "Ending now")
    let far = MeetingGroup(groupId: "g", callTabId: "t", occurrence: nil, title: "", start: nil, end: now + 30 * minute, endedAt: nil)
    #expect(SidebarMeetingCountdown(far, now: now).label == nil)
    let near = MeetingGroup(groupId: "g", callTabId: "t", occurrence: nil, title: "", start: nil, end: now + 1.5 * minute, endedAt: nil)
    #expect(SidebarMeetingCountdown(near, now: now).label == "2 min left")
    #expect(SidebarMeetingCountdown(near, now: now).urgent)
    let ended = MeetingGroup(groupId: "g", callTabId: "t", occurrence: nil, title: "", start: nil, end: now + minute, endedAt: now)
    #expect(SidebarMeetingCountdown(ended, now: now).label == nil)
  }

  @Test func nativeUrgencyColorsAndWiggleMatchBothAppearances() throws {
    for (dark, red, green, blue) in [(false, 0xD1, 0x24, 0x2F), (true, 0xE5, 0x53, 0x4B)] {
      let color = try #require(SidebarMeetingCountdown.nowColor(dark: dark).usingColorSpace(.sRGB))
      #expect(abs(color.redComponent - CGFloat(red) / 255) < 0.0001)
      #expect(abs(color.greenComponent - CGFloat(green) / 255) < 0.0001)
      #expect(abs(color.blueComponent - CGFloat(blue) / 255) < 0.0001)
      #expect(color.alphaComponent == 1)
    }
    let animation = SidebarMeetingCountdown.wiggle(around: CGSize(width: 180, height: 22))
    #expect(abs(animation.duration - 0.59) < 0.0001)
    #expect(animation.values?.count == 7)
    #expect(animation.keyTimes?.first == 0)
    #expect(animation.keyTimes?.last == 1)
  }

  @Test func eachMarkWigglesOnceAndPassedMarksNever() {
    var done = Set<String>()
    #expect(SidebarMeetingCountdown.dueWiggles(groupId: "g", minutesLeft: 4.5, done: &done))
    #expect(!SidebarMeetingCountdown.dueWiggles(groupId: "g", minutesLeft: 4.4, done: &done))
    #expect(SidebarMeetingCountdown.dueWiggles(groupId: "g", minutesLeft: 1.9, done: &done))
    var late = Set<String>()
    #expect(!SidebarMeetingCountdown.dueWiggles(groupId: "h", minutesLeft: 3.5, done: &late))
  }

  @Test func aMeetingGroupEndingSoonShowsItsCountdownInTheHeader() throws {
    let (window, _, row) = try header(with: meeting(endingIn: 4.5))
    _ = window
    let label = try #require(countdownLabel(in: row))
    #expect(label.stringValue == "5 min left")
    #expect(!label.isHidden)
    #expect(label.convert(label.bounds, to: row).maxX <= row.bounds.width - 6)
    let title = try #require(fadeLabel(in: row))
    #expect(title.convert(title.bounds, to: label.superview).maxX <= label.frame.minX)
    SidebarLiveFeed.shared.apply(LiveState())
  }

  @Test func noCountdownWithoutAMeetingOrBeforeTheLastTenMinutes() throws {
    for group in [nil, meeting(endingIn: 25), meeting(endingIn: 3, ended: true)] {
      let (window, _, row) = try header(with: group)
      _ = window
      let label = countdownLabel(in: row)
      #expect(label == nil || label!.isHidden)
    }
    SidebarLiveFeed.shared.apply(LiveState())
  }
}
