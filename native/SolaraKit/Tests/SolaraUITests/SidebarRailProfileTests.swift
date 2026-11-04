import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailProfileTests {
  func state(count: Int, rail: Bool = true, icon: String? = "🧭") -> SidebarChromeState {
    let profiles = (0..<count).map { index -> [String: Any] in
      var profile: [String: Any] = ["id": "p\(index)", "name": "Profile \(index)", "slot": index]
      if index == 2, let icon { profile["icon"] = icon }
      return profile
    }
    let json: [String: Any] = [
      "controls": ["title": "Profile 2", "incognito": false, "profiles": count, "nameColor": "#000000", "downloadsOpen": false],
      "downloads": true, "addressBar": true, "dark": false, "theme": [:], "dots": profiles,
      "savedWidth": 240, "iconsOnly": rail, "dropOver": false, "currentProfileId": "p2",
    ]
    return SidebarChromeState.decode(String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)!
  }

  func switcher(_ view: SidebarChromeView) -> NSView? {
    view.profileSwitcher
  }

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  @Test func fittingRailDotsStayInsideFooterInsets() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(count: 2))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.count == 2)
    #expect(dots.allSatisfy { $0.frame.minX >= 6 && $0.frame.maxX <= 36 })
    #expect(switcher(view) == nil || switcher(view)!.isHidden)
  }

  @Test func overflowingRailDotsBecomeACentredAccessibleProfileButton() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(count: 8))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.allSatisfy { $0.frame.minX >= 6 && $0.frame.maxX <= 36 })
    #expect(dots.isEmpty)
    guard let button = switcher(view) else {
      Issue.record("Missing current-profile overflow button")
      return
    }
    #expect(!button.isHidden)
    #expect(button.frame == NSRect(x: 7, y: 664, width: 28, height: 28))
    #expect(button.toolTip == "Profile 2")
    #expect(descendants(button).compactMap { $0 as? StripLabel }.contains { $0.stringValue == "🧭" })
    #expect(button.layer?.cornerRadius == 14)
  }

  @Test func railProfileFitUsesAvailableWidth() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 72, height: 700))
    view.update(state(count: 6))
    #expect(view.subviews.compactMap { $0 as? SidebarProfileDot }.allSatisfy { $0.isHidden })
    #expect(switcher(view)?.isHidden == false)
  }

  @Test func profilePopoverListsEveryProfileChecksCurrentAndSendsDotAction() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    defer { view.profilePopover.close() }
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(state(count: 8))
    guard let button = switcher(view) else {
      Issue.record("Missing profile switcher")
      return
    }
    #expect(button.accessibilityPerformPress())
    guard let body = view.profilePopover.contentViewController?.view else {
      Issue.record("Missing native profile popover content")
      return
    }
    let rows = descendants(body).compactMap { $0 as? NSButton }
    #expect(rows.map(\.title) == (0..<8).map { "Profile \($0)" })
    #expect(rows.filter { $0.state == .on }.map(\.title) == ["Profile 2"])
    #expect(rows.allSatisfy { $0.image != nil })
    #expect(sendSidebarRailButtonAction(rows.last))
    #expect(actions == [.switchProfile("p7")])
    view.update(state(count: 2))
    let dot = view.subviews.compactMap { $0 as? SidebarProfileDot }.first!
    #expect(dot.accessibilityPerformPress())
    #expect(actions == [.switchProfile("p7"), .switchProfile("p0")])
  }

  @Test func profileButtonFallsBackToCurrentInitial() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(count: 8, icon: nil))
    guard let button = switcher(view) else {
      Issue.record("Missing profile switcher")
      return
    }
    #expect(descendants(button).compactMap { $0 as? StripLabel }.contains { $0.stringValue == "P" })
  }

  @Test func profileSymbolIconFallsBackToCurrentInitial() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    let next = state(count: 8, icon: "symbol:briefcase")
    view.update(next)
    let button = switcher(view)!
    #expect(descendants(button).compactMap { $0 as? StripLabel }.contains { $0.stringValue == "P" })
    #expect(SidebarRailProfileButton.icon(next.dots[2]) == "P")
  }

  @Test func fullWidthKeepsAllDotsAndTheirOriginalLayout() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    view.update(state(count: 8, rail: false))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.count == 8)
    #expect(dots.map(\.frame) == (0..<8).map { NSRect(x: 72 + 12 * CGFloat($0), y: 664, width: 12, height: 28) })
    #expect(switcher(view) == nil || switcher(view)!.isHidden)
  }
}
