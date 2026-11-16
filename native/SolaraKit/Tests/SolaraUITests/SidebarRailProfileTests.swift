import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailProfileTests {
  func state(count: Int, rail: Bool = true, icon: String? = "🧭") -> SidebarChromeState {
    let profiles = (0..<count).map { index in
      SidebarChromeDot(id: "p\(index)", name: "Profile \(index)", slot: Double(index), icon: index == 2 ? icon : nil,
        shortcut: index < 9 ? "⌃\(index + 1)" : nil, color: "#4691C3")
    }
    return SidebarChromeState(controls: StripControlsState(title: "Profile 2", incognito: false, profiles: count,
      nameColor: "#000000", downloadsOpen: false, downloadsTooltip: nil), downloads: true, addressBar: true, dark: false,
      theme: [:], dots: profiles, savedWidth: 240, iconsOnly: rail, currentProfileId: "p2")
  }

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  @Test(arguments: [1, 2, 8, 12]) func railAlwaysHasOneCurrentProfileButton(count: Int) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(count: count))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.isEmpty)
    #expect(!view.profileSwitcher.isHidden)
    #expect(view.profileSwitcher.frame == NSRect(x: 9, y: 668, width: 24, height: 24))
    #expect(view.headerProfile.isHidden)
    #expect(view.headerHeight == 0)
    #expect(view.profileSwitcher.accessibilityLabel() == (count > 2 ? "Profile 2" : "Profile 0"))
  }

  @Test func currentEmojiSymbolAndEmptyIconAreRendered() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    for icon in ["🧭", "symbol:briefcase.fill", ""] {
      view.update(state(count: 8, icon: icon))
      #expect(view.profileSwitcher.glyph.value == (icon.isEmpty ? nil : icon))
      #expect(view.profileSwitcher.accessibilityValue() as? NSNumber == NSNumber(value: true))
    }
    view.update(state(count: 8, icon: nil))
    #expect(view.profileSwitcher.glyph.value == nil)
    #expect(SidebarChromeMetrics.dot == 5)
    #expect(view.profileSwitcher.layer?.cornerRadius == 6)
  }

  @Test func profilePopoverListsEveryProfileAndManagementActions() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    defer { view.profilePopover.close() }
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(state(count: 8))
    #expect(view.profileSwitcher.accessibilityPerformPress())
    guard let body = view.profilePopover.contentViewController?.view else {
      Issue.record("Missing native profile list")
      return
    }
    let rows = descendants(body).compactMap { $0 as? SidebarRailProfileRow }
    #expect(rows.map(\.title) == (0..<8).map { "Profile \($0)" })
    #expect(rows.filter { $0.state == .on }.map(\.title) == ["Profile 2"])
    #expect(rows[2].accessibilityLabel() == "Profile 2")
    #expect(rows[2].accessibilityHelp() == "⌃3")
    #expect(sendSidebarRailButtonAction(rows.last))
    #expect(actions == [.switchProfile("p7")])
    let manage = descendants(body).compactMap { $0 as? NSButton }.first { $0.title == "Manage Profiles…" }
    #expect(sendSidebarRailButtonAction(manage))
    #expect(actions.last == .manageProfiles)
  }

  @Test func fullWidthHasTwentyFourPointButtonsAndTwoPointGaps() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 8, rail: false)
    next.dots[0].icon = "symbol:star.fill"
    next.downloads = false
    view.update(next)
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.count == 8)
    #expect(dots.map(\.frame) == (0..<8).map { NSRect(x: 17 + 26 * CGFloat($0), y: 668, width: 24, height: 24) })
    #expect(view.profileSwitcher.isHidden)
    #expect(view.footerHeight == 40)
    #expect(dots[0].glyph.value == "symbol:star.fill")
    #expect(dots[2].glyph.value == "🧭")
    #expect(dots[2].accessibilityLabel() == "Profile 2")
    #expect(dots[2].accessibilityValue() as? NSNumber == NSNumber(value: true))
    #expect(dots[0].accessibilityValue() as? NSNumber == NSNumber(value: false))
  }

  @Test(arguments: [CGFloat(160), 190]) func fullWidthOverflowKeepsEveryProfileReachable(width: CGFloat) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
    view.update(state(count: 8, rail: false))
    #expect(view.subviews.compactMap { $0 as? SidebarProfileDot }.allSatisfy { $0.isHidden })
    #expect(!view.profileSwitcher.isHidden)
    #expect(view.bounds.contains(view.profileSwitcher.frame))
    #expect(!view.profileSwitcher.frame.intersects(view.footerDownloads.frame))
    #expect(view.profileSwitcher.accessibilityPerformPress())
    let rows = view.profilePopover.contentViewController.map { descendants($0.view).compactMap { $0 as? SidebarRailProfileRow } } ?? []
    #expect(rows.count == 8)
    view.profilePopover.close()
  }

  @Test(arguments: [false, true]) func allProfileTintsKeepStableGeometry(dark: Bool) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    for color in ProfileColorValue.allCases {
      var next = state(count: 3, rail: false, icon: "symbol:star.fill")
      next.dark = dark
      next.dots = next.dots.map { var dot = $0; dot.color = color.swatch; return dot }
      view.update(next)
      let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }
      #expect(dots.map(\.frame) == (0..<3).map { NSRect(x: 82 + 26 * CGFloat($0), y: 668, width: 24, height: 24) })
      #expect(dots.allSatisfy { $0.ink == SidebarPalette.parse(color.swatch) })
    }
  }

  @Test(arguments: [false, true]) func railHoverPillUsesWindowRoomAndActualShortcut(right: Bool) {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let root = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView = root
    let rail = SidebarChromeView(frame: NSRect(x: right ? 858 : 0, y: 0, width: 42, height: 700))
    root.addSubview(rail)
    rail.update(state(count: 3))
    let pill = SidebarDotTooltip()
    rail.addSubview(pill)
    let name = "Work and side projects"
    pill.show(name, shortcut: "⌥⌘K", above: rail.profileSwitcher)
    pill.appear(name)
    #expect(pill.superview === root)
    #expect(pill.text == name)
    #expect(pill.shortcut == "⌥⌘K")
    #expect(pill.frame.width > 200)
    #expect(root.bounds.contains(pill.frame))
    #expect(pill.subviews.allSatisfy { pill.bounds.contains($0.frame) })
    rail.update(state(count: 4))
    #expect(rail.subviews.compactMap { $0 as? SidebarProfileDot }.count == 4)
    pill.hide()
  }

  @Test func shortcutKeycapsKeepRemappedAndDisabledBindings() {
    #expect(SidebarDotTooltip.keys("⌃1") == ["⌃", "1"])
    #expect(SidebarDotTooltip.keys("⌥⇧⌘F12") == ["⌥", "⇧", "⌘", "F12"])
    #expect(SidebarDotTooltip.keys(nil).isEmpty)
    #expect(SidebarDotTooltip.keys("").isEmpty)
  }
}
