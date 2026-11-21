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

  @Test(arguments: ["🧭", "symbol:star.fill", ""]) func swipeOpacityDoesNotInvalidateProfileArtwork(icon: String) throws {
    let dot = SidebarProfileDot(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    dot.icon = icon
    dot.opacity = 0.65
    dot.layoutSubtreeIfNeeded()
    let emoji = try #require(descendants(dot).compactMap { $0 as? SidebarProfileEmoji }.first)
    emoji.needsDisplay = false
    dot.selected = false
    dot.opacity = 0.8
    #expect(dot.glyph.alphaValue == 0.8)
    #expect(!dot.glyph.needsLayout)
    #expect(!emoji.needsDisplay)
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: false))
    dot.selected = true
    dot.layoutSubtreeIfNeeded()
    emoji.needsDisplay = false
    dot.opacity = 0.7
    #expect(dot.glyph.alphaValue == 1)
    #expect(!dot.glyph.needsLayout)
    #expect(!emoji.needsDisplay)
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: true))
    dot.selected = false
    #expect(dot.glyph.alphaValue == 0.7)
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: false))
  }

  @Test func profileHighlightTracksTheDragBeforeTheCommittedProfileChanges() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false)
    next.currentProfileId = "p0"
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    let frames = dots.map(\.frame)
    for (position, selected) in [(0.0, ["p0"]), (0.38, ["p0"]), (0.4, []), (0.6, []), (0.62, ["p1"]), (0.8, ["p1"])] {
      view.setPagerPosition(position)
      #expect(dots.filter(\.selected).map(\.profileId) == selected)
      #expect(dots.map(\.frame) == frames)
    }
  }

  @Test func profileHighlightFollowsTheSpringAfterCommit() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false)
    next.currentProfileId = "p0"
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    view.setPagerPosition(0.5)
    next.currentProfileId = "p1"
    view.update(next)
    #expect(dots.filter(\.selected).isEmpty)
    for position in [0.65, 0.9, 1.0] {
      view.setPagerPosition(position)
      #expect(dots.filter(\.selected).map(\.profileId) == ["p1"])
    }
  }

  @Test func cancelledSwipeReturnsTheHighlightWithTheSpring() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false)
    next.currentProfileId = "p0"
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    for (position, selected) in [(0.0, ["p0"]), (0.4, []), (0.7, ["p1"]), (0.5, []), (0.3, ["p0"]), (0.05, ["p0"]), (0.0, ["p0"])] {
      view.setPagerPosition(position)
      #expect(dots.filter(\.selected).map(\.profileId) == selected)
    }
    #expect(dots[0].glyph.alphaValue == 1)
    #expect(dots[1].glyph.alphaValue == 0.65)
  }

  @Test func selectionBoundariesIgnoreHoverAndProfilesWithoutPagerSlots() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false)
    next.currentProfileId = "p0"
    next.dots[2].slot = nil
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    #expect(dots.filter(\.selected).map(\.profileId) == ["p0"])
    dots[2].setHovered(true)
    for position in [5.0 / 13, 8.0 / 13] {
      view.setPagerPosition(position)
      #expect(dots.filter(\.selected).isEmpty)
    }
    view.setPagerPosition(0.7)
    dots[0].setHovered(true)
    #expect(dots.filter(\.selected).map(\.profileId) == ["p1"])
    #expect(!dots[2].selected)
  }

  @Test(arguments: [1, 2, 8, 12]) func railAlwaysHasOneCurrentProfileButton(count: Int) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(count: count))
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
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

  @Test func fullWidthHasTwentyFourPointButtonsAndFourPointGaps() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 8, rail: false)
    next.dots[0].icon = "symbol:star.fill"
    next.downloads = false
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }.filter { !$0.isHidden }
    #expect(dots.count == 8)
    #expect(!view.profileScroll.solaraOwnsHorizontalScrolling)
    #expect(dots.map { $0.convert($0.bounds, to: view) } == (0..<8).map { NSRect(x: 10 + 28 * CGFloat($0), y: 668, width: 24, height: 24) })
    #expect(view.profileSwitcher.isHidden)
    #expect(view.footerHeight == 40)
    #expect(dots[0].glyph.value == "symbol:star.fill")
    #expect(dots[2].glyph.value == "🧭")
    #expect(dots[2].accessibilityLabel() == "Profile 2")
    #expect(dots[2].accessibilityValue() as? NSNumber == NSNumber(value: true))
    #expect(dots[0].accessibilityValue() as? NSNumber == NSNumber(value: false))
  }

  @Test(arguments: [CGFloat(160), 190]) func fullWidthOverflowScrollsWithoutShrinkingOrReplacingIcons(width: CGFloat) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
    var next = state(count: 12, rail: false)
    next.dots[0].icon = "symbol:star.fill"
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    #expect(dots.count == 12)
    #expect(dots.allSatisfy { !$0.isHidden && $0.frame.size == NSSize(width: 24, height: 24) })
    #expect(view.profileSwitcher.isHidden)
    #expect(view.bounds.contains(view.profileScroll.frame))
    #expect(!view.profileScroll.frame.intersects(view.footerDownloads.frame))
    #expect(view.profileScroll.documentVisibleRect.contains(dots[2].frame))
    #expect(view.profileScroll.solaraOwnsHorizontalScrolling)
    for index in 1..<dots.count { #expect(dots[index].frame.minX - dots[index - 1].frame.maxX == 4) }
    next.currentProfileId = "p11"
    view.update(next)
    #expect(view.profileScroll.documentVisibleRect.contains(dots[11].frame))
    #expect(view.profileScroll.solaraOwnsHorizontalScrolling)
    #expect(dots[0].glyph.value == "symbol:star.fill")
    #expect(dots[2].glyph.value == "🧭")
    next.currentProfileId = "p0"
    view.update(next)
    #expect(view.profileScroll.documentVisibleRect.contains(dots[0].frame))
    #expect(view.profileScroll.solaraOwnsHorizontalScrolling)
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    #expect(dots[0].accessibilityPerformPress())
    #expect(actions == [.switchProfile("p0")])
    view.setFrameSize(NSSize(width: 400, height: 700))
    view.layoutSubtreeIfNeeded()
    #expect(view.profileScroll.documentVisibleRect.contains(dots[0].frame))
  }

  @Test(arguments: [false, true]) func fittingProfileBarLeavesPaddingAndGapsToTheSidebar(translated: Bool) {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
    let view = SidebarChromeView(frame: NSRect(x: translated ? 510 : 0, y: translated ? 57 : 0, width: 240, height: 700))
    host.addSubview(view)
    var next = state(count: 3, rail: false)
    next.downloads = false
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    #expect(!view.profileScroll.solaraOwnsHorizontalScrolling)
    let first = dots[0].convert(dots[0].bounds, to: view)
    let last = dots[2].convert(dots[2].bounds, to: view)
    for x in [view.profileScroll.frame.minX + 1, first.maxX + 2, last.maxX + 1] {
      let point = view.convert(NSPoint(x: x, y: first.midY), to: host)
      #expect(view.hitTest(point) === view)
    }
    for dot in dots {
      #expect(dot.bounds.size == NSSize(width: 24, height: 24))
      for x in [CGFloat(0.5), 12, 23.5] {
        for y in [CGFloat(0.5), 12, 23.5] {
          #expect(view.hitTest(dot.convert(NSPoint(x: x, y: y), to: host)) === dot)
        }
      }
    }
  }

  @Test(arguments: [false, true]) func overflowingProfileBarKeepsScrollHitsAtBothEdges(translated: Bool) throws {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
    let view = SidebarChromeView(frame: NSRect(x: translated ? 510 : 0, y: translated ? 57 : 0, width: 160, height: 700))
    host.addSubview(view)
    var next = state(count: 12, rail: false)
    next.downloads = false
    let dots = { descendants(view).compactMap { $0 as? SidebarProfileDot } }
    for profile in ["p0", "p11"] {
      next.currentProfileId = profile
      view.update(next)
      let scroll = view.profileScroll
      #expect(scroll.solaraOwnsHorizontalScrolling)
      let viewport = scroll.convert(scroll.bounds, to: view)
      for x in [viewport.minX + 0.5, viewport.maxX - 0.5] {
        let hit = try #require(view.hitTest(view.convert(NSPoint(x: x, y: viewport.midY), to: host)))
        #expect(hit === scroll || hit.isDescendant(of: scroll))
      }
      var gaps = 0
      for dot in dots().dropLast() {
        let rect = dot.convert(dot.bounds, to: view)
        let point = NSPoint(x: rect.maxX + 2, y: rect.midY)
        guard viewport.contains(point) else { continue }
        let hit = try #require(view.hitTest(view.convert(point, to: host)))
        #expect(hit === scroll || hit.isDescendant(of: scroll))
        #expect(!(hit is SidebarProfileDot))
        gaps += 1
      }
      #expect(gaps > 0)
      let selected = try #require(dots().first { $0.profileId == profile })
      #expect(view.hitTest(selected.convert(NSPoint(x: 12, y: 12), to: host)) === selected)
      for x in [CGFloat(4), 154] {
        #expect(view.hitTest(view.convert(NSPoint(x: x, y: viewport.midY), to: host)) === view)
      }
    }
  }

  func channels(_ color: NSColor) -> [CGFloat] {
    let rgb = color.usingColorSpace(.sRGB)!
    return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
  }

  func composite(_ foreground: NSColor, over background: NSColor) -> [CGFloat] {
    zip(channels(foreground), channels(background)).map { $0 * foreground.alphaComponent + $1 * (1 - foreground.alphaComponent) }
  }

  func luminance(_ channels: [CGFloat]) -> CGFloat {
    let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }

  @Test(arguments: [false, true]) func allProfileTintsHaveLighterSelectionAndStableSlots(dark: Bool) throws {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    for color in ProfileColorValue.allCases {
      let tint = try #require(SidebarPalette.parse(color.swatch))
      let background = NSColor(srgbRed: dark ? 0.06 : 0.78, green: dark ? 0.05 : 0.78, blue: dark ? 0.05 : 0.78, alpha: 1)
        .blended(withFraction: dark ? 0.3 : 0.15, of: tint)!
      var next = state(count: 3, rail: false, icon: "symbol:briefcase.fill")
      next.dark = dark
      next.theme["windowTint"] = "#" + channels(background).map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
      next.dots = next.dots.map { var dot = $0; dot.color = color.swatch; return dot }
      view.update(next)
      let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
      #expect(dots.map { $0.convert($0.bounds, to: view) } == (0..<3).map { NSRect(x: 80 + 28 * CGFloat($0), y: 668, width: 24, height: 24) })
      for dot in dots where !dot.selected {
        let rendered = composite(dot.ink.withAlphaComponent(0.65), over: SidebarPalette.parse(next.theme["windowTint"])!)
        let back = luminance(channels(SidebarPalette.parse(next.theme["windowTint"])!))
        let mark = luminance(rendered)
        #expect((max(mark, back) + 0.05) / (min(mark, back) + 0.05) >= 3)
      }
      let selected = dots[2]
      #expect(selected.selected)
      #expect(selected.glyph.alphaValue == 1)
      let fill = NSColor(cgColor: try #require(selected.layer?.backgroundColor))!
      #expect(abs(fill.alphaComponent - (dark ? 0.16 : 0.55)) < 1e-6)
      let composited = composite(fill, over: background)
      #expect(zip(composited, channels(background)).allSatisfy { $0 >= $1 })
      #expect(luminance(composited) > luminance(channels(background)))
      #expect(composite(fill, over: .white).allSatisfy { abs($0 - 1) < 1e-6 })
      #expect(selected.layer?.borderWidth == 0.5)
      #expect(selected.layer?.cornerRadius == 6)
    }
  }

  @Test(arguments: [false, true], ["symbol:briefcase.fill", "🧭", "A", ""]) func everyGlyphUsesOneOpacityAndKeepsItsIdentity(dark: Bool, icon: String) throws {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false, icon: icon)
    next.dark = dark
    next.currentProfileId = "p0"
    view.update(next)
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    let dot = dots[2]
    let original = dot.frame
    #expect(dot.glyph.value == (icon.isEmpty ? nil : icon))
    #expect(dot.glyph.subviews.compactMap { $0 as? SidebarProfileEmoji }.allSatisfy { $0.color == dot.ink })
    #expect(abs(dot.glyph.alphaValue - 0.65) < 1e-6)
    #expect(!dot.selected)
    dot.setHovered(true)
    #expect(abs(dot.glyph.alphaValue - 0.85) < 1e-6)
    #expect(!dot.selected)
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: false))
    #expect(dot.glyph.value == (icon.isEmpty ? nil : icon))
    #expect(dot.frame == original)
    let hoverFill = NSColor(cgColor: try #require(dot.layer?.backgroundColor))!
    #expect(abs(hoverFill.alphaComponent - (dark ? 0.09 : 0.30)) < 1e-6)
    dot.setHovered(false)
    next.currentProfileId = "p2"
    view.update(next)
    #expect(dot.selected)
    #expect(dot.glyph.alphaValue == 1)
    #expect(dot.frame == original)
    #expect(dot.glyph.value == (icon.isEmpty ? nil : icon))
    #expect(dot.accessibilityLabel() == "Profile 2")
    #expect(dot.accessibilityHelp() == "⌃3")
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: true))
    dot.setHovered(true)
    #expect(dot.glyph.alphaValue == 1)
    #expect(dot.accessibilityValue() as? NSNumber == NSNumber(value: true))
  }

  @Test(arguments: [false, true], [false, true]) func pressKeepsIdentityAndUsesFullOpacity(dark: Bool, selected: Bool) throws {
    let dot = SidebarProfileDot(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    dot.dark = dark
    dot.icon = "🧭"
    dot.selected = selected
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    dot.mouseDown(with: event)
    #expect(dot.glyph.alphaValue == 1)
    #expect(dot.glyph.value == "🧭")
    #expect(dot.selected == selected)
    #expect(dot.frame.size == NSSize(width: 24, height: 24))
    let fill = NSColor(cgColor: try #require(dot.layer?.backgroundColor))!
    let expected = dark ? (selected ? 0.24 : 0.20) : (selected ? 0.75 : 0.65)
    #expect(abs(Double(fill.alphaComponent) - expected) < 1e-6)
    var menus = 0
    dot.onMenu = { menus += 1 }
    #expect(dot.accessibilityPerformShowMenu())
    #expect(menus == 1)
  }

  @Test(arguments: [false, true]) func starUsesTheSameSizeAndNeutralInk(dark: Bool) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    var next = state(count: 3, rail: false, icon: "symbol:star.fill")
    next.dark = dark
    view.update(next)
    view.layoutSubtreeIfNeeded()
    let dots = descendants(view).compactMap { $0 as? SidebarProfileDot }
    let star = dots[2]
    #expect(star.frame.size == dots[0].frame.size)
    #expect(star.glyph.alphaValue == 1)
    #expect(star.ink == SidebarPalette.parse(dark ? "#F5F2F7" : "#302938"))
    #expect(SidebarChromeMetrics.dotCell == 28)
    #expect(SidebarChromeMetrics.dot == 5)
    #expect(SidebarChromeMetrics.profileGlyph == 13)
    #expect(star.glyph.subviews.allSatisfy { $0.frame.size == NSSize(width: 16, height: 16) })
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
    #expect(pill.frame.width > 150 && pill.frame.height == SidebarDotTooltipMetrics.height)
    #expect(root.bounds.contains(pill.frame))
    #expect(pill.subviews.allSatisfy { pill.bounds.contains($0.frame) })
    rail.update(state(count: 4))
    #expect(descendants(rail).compactMap { $0 as? SidebarProfileDot }.count == 4)
    pill.hide()
  }

  @Test(arguments: [CGFloat(160), 400], [false, true])
  func profileTooltipsStayAboveTheBarInsideEitherSideOfTheWindow(width: CGFloat, flipped: Bool) {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let contentBounds = NSRect(x: 0, y: 0, width: 900, height: 700)
    let root: NSView = flipped ? FlippedContainerView(frame: contentBounds) : NSView(frame: contentBounds)
    window.contentView = root
    for right in [false, true] {
      let sidebar = SidebarChromeView(frame: NSRect(x: right ? 900 - width : 0, y: 0, width: width, height: 700))
      root.addSubview(sidebar)
      defer { sidebar.removeFromSuperview() }
      var next = state(count: 3, rail: false)
      next.downloads = false
      sidebar.update(next)
      let dots = descendants(sidebar).compactMap { $0 as? SidebarProfileDot }
      let pill = SidebarDotTooltip()
      sidebar.addSubview(pill)
      defer { pill.hide(); pill.removeFromSuperview() }
      for index in [0, dots.count - 1] {
        let dot = dots[index]
        #expect(!dot.isHidden)
        let name = index == 0 ? "Personal" : "A very long profile name that must fit inside the sidebar"
        pill.show(name, shortcut: "⌃\(index + 1)", above: dot)
        pill.appear(name)
        let frame = pill.convert(pill.bounds, to: sidebar)
        #expect(!pill.isHidden)
        #expect(pill.text == name)
        #expect(pill.shortcut == "⌃\(index + 1)")
        #expect(root.bounds.contains(pill.frame))
        #expect(sidebar.bounds.contains(frame))
        #expect(frame.maxY <= sidebar.bounds.maxY - SidebarChromeMetrics.footer - 4)
        let centered = dot.convert(dot.bounds, to: sidebar).midX - frame.width / 2
        #expect(abs(frame.minX - max(4, min(centered, width - frame.width - 4))) <= 0.5)
        #expect(pill.subviews.allSatisfy { pill.bounds.contains($0.frame) })
      }
    }
  }

  @Test(arguments: [false, true]) func theProfileTooltipIsCompactGlassAndASolidPillUnderReduceTransparency(dark: Bool) throws {
    func glass(_ view: NSView) -> [NSGlassEffectView] { (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap(glass) }
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let root = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView = root
    let sidebar = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    root.addSubview(sidebar)
    var next = state(count: 3, rail: false)
    next.dark = dark
    sidebar.update(next)
    let dot = try #require(descendants(sidebar).compactMap { $0 as? SidebarProfileDot }.first)
    let pill = SidebarDotTooltip()
    sidebar.addSubview(pill)
    defer { pill.hide(); pill.removeFromSuperview() }
    pill.forcedReduceTransparency = false
    pill.look(dark: dark, panel: .white, border: .gray)
    pill.show("Work", shortcut: "⌃2", above: dot)
    pill.appear("Work")
    let material = try #require(glass(pill).first)
    #expect(pill.usesGlass && !material.isHiddenOrHasHiddenAncestor)
    #expect(pill.frame.height == 23 && material.cornerRadius == 11.5 && material.frame.size == pill.bounds.size)
    #expect(material.appearance?.name == (dark ? .darkAqua : .aqua))
    #expect(pill.layer?.sublayers?.filter { $0.cornerRadius >= 11 }.count == 2)
    #expect(pill.layer?.sublayers?.filter { $0.cornerRadius >= 11 }.allSatisfy(\.isHidden) == true)
    #expect(pill.keycapViews.count == 2 && pill.keycapViews.allSatisfy { $0.frame.height == 16 })
    let reused = pill.keycapViews
    pill.hide()
    pill.forcedReduceTransparency = true
    pill.show("Personal", shortcut: "⌃1", above: dot)
    pill.appear("Personal")
    #expect(!pill.usesGlass && material.isHiddenOrHasHiddenAncestor)
    #expect(pill.layer?.sublayers?.filter { $0.cornerRadius >= 11 }.allSatisfy { !$0.isHidden } == true)
    #expect(zip(reused, pill.keycapViews).allSatisfy { $0 === $1 })
    #expect(glass(pill).count == 1)
  }

  @Test(arguments: [false, true], [CGFloat(2), 1]) func everyProfileIconIsWholeOrOutOfViewAtEveryWidth(downloads: Bool, scale: CGFloat) {
    let window = PinnedScalePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.pinnedScale = scale
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let root = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView = root
    var failures: [String] = []
    for count in 3...6 {
      for selected in [0, count - 1] {
        var next = state(count: count, rail: false)
        next.downloads = downloads
        next.currentProfileId = "p\(selected)"
        let widths = Array(Int(SidebarChromeMetrics.minWidth)...Int(SidebarChromeMetrics.maxWidth)).map { CGFloat($0) } + (scale == 2 ? [160.5, 161.25, 163.5, 175.75, 190.5, 213.5] : [])
        for width in widths {
          let sidebar = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
          root.addSubview(sidebar)
          defer { sidebar.removeFromSuperview() }
          sidebar.update(next)
          sidebar.layoutSubtreeIfNeeded()
          let visible = sidebar.profileScroll.convert(sidebar.profileScroll.contentView.frame, to: sidebar)
          let dots = descendants(sidebar).compactMap { $0 as? SidebarProfileDot }.sorted { $0.frame.minX < $1.frame.minX }
          guard dots.count == count else { failures.append("w\(width) c\(count): \(dots.count) dots"); continue }
          var shown = 0
          for dot in dots {
            let frame = dot.convert(dot.bounds, to: sidebar)
            let whole = visible.insetBy(dx: -0.01, dy: -0.01).contains(frame)
            let outside = frame.maxX <= visible.minX + 0.01 || frame.minX >= visible.maxX - 0.01
            if whole { shown += 1 }
            if !whole && !outside { failures.append("w\(width) c\(count) d\(downloads) sel\(selected): \(dot.profileId) \(frame) cut by \(visible)") }
            if whole && !sidebar.bounds.insetBy(dx: SidebarChromeMetrics.profileInset - 0.01, dy: 0).contains(frame) { failures.append("w\(width): \(dot.profileId) outside the bar") }
          }
          if let current = dots.first(where: { $0.profileId == "p\(selected)" }), !visible.insetBy(dx: -0.01, dy: -0.01).contains(current.convert(current.bounds, to: sidebar)) {
            failures.append("w\(width) c\(count) d\(downloads): the current profile p\(selected) is not whole")
          }
          let pitch = dots[1].frame.minX - dots[0].frame.minX
          let fits = SidebarChromeMetrics.dotCell * CGFloat(count) - 4 <= visible.width + 0.01
          if fits, abs(pitch - SidebarChromeMetrics.dotCell) > 0.01 { failures.append("w\(width) c\(count): the pitch changed although the row fits") }
          if pitch < SidebarChromeMetrics.profileButton + SidebarChromeMetrics.minDotGap - 0.01 || pitch > SidebarChromeMetrics.dotCell + 0.01 { failures.append("w\(width) c\(count): pitch \(pitch)") }
          if shown < count, abs(pitch - SidebarChromeMetrics.dotCell) > 0.01 { failures.append("w\(width) c\(count): a scrolling row must keep the 28 pt pitch") }
          for pair in zip(dots, dots.dropFirst()) where abs(pair.1.frame.minX - pair.0.frame.minX - pitch) > 0.01 {
            failures.append("w\(width) c\(count): uneven pitch at \(pair.1.profileId)")
          }
          if shown == 0 { failures.append("w\(width) c\(count): no whole icon") }
          let available = width - (downloads ? SidebarChromeMetrics.inset + SidebarChromeMetrics.downloadsBox + SidebarChromeMetrics.profileInset : SidebarChromeMetrics.profileInset) - SidebarChromeMetrics.profileInset
          if shown < count, (SidebarChromeMetrics.profileButton + SidebarChromeMetrics.minDotGap) * CGFloat(count - 1) + SidebarChromeMetrics.profileButton <= available {
            failures.append("w\(width) c\(count) d\(downloads): icons hidden although a tighter row fits")
          }
        }
      }
    }
    #expect(failures.isEmpty, "scale \(scale): \(failures.prefix(12).joined(separator: "\n")) (\(failures.count) total)")
  }

  @Test func profileRowScrollStepsSnapToWholeSlots() {
    typealias Step = SidebarProfileScrollStep
    let notch = Step.next(from: 0, travel: nil, delta: -1, precise: false, phase: [], momentum: [], snap: 28, limit: 56)
    #expect(notch.x == 28 && notch.travel == nil)
    let back = Step.next(from: 28, travel: nil, delta: 1, precise: false, phase: [], momentum: [], snap: 28, limit: 56)
    #expect(back.x == 0)
    let fling = Step.next(from: 0, travel: nil, delta: -10, precise: false, phase: [], momentum: [], snap: 28, limit: 56)
    #expect(fling.x == 56)
    let still = Step.next(from: 28, travel: nil, delta: 0, precise: false, phase: [], momentum: [], snap: 28, limit: 56)
    #expect(still.x == 28)
    var step = Step.next(from: 0, travel: nil, delta: 0, precise: true, phase: .began, momentum: [], snap: 28, limit: 56)
    #expect(step.x == 0 && step.travel == 0)
    step = Step.next(from: 0, travel: step.travel, delta: -5, precise: true, phase: .changed, momentum: [], snap: 28, limit: 56)
    #expect(step.x == 0 && step.travel == 5)
    step = Step.next(from: 0, travel: step.travel, delta: -10, precise: true, phase: .changed, momentum: [], snap: 28, limit: 56)
    #expect(step.x == 28 && step.travel == 15)
    step = Step.next(from: 28, travel: step.travel, delta: -20, precise: true, phase: [], momentum: .changed, snap: 28, limit: 56)
    #expect(step.x == 28 && step.travel == 35)
    step = Step.next(from: 28, travel: step.travel, delta: -10, precise: true, phase: [], momentum: .ended, snap: 28, limit: 56)
    #expect(step.x == 56 && step.travel == nil)
    let restarted = Step.next(from: 0, travel: 40, delta: 0, precise: true, phase: .began, momentum: [], snap: 28, limit: 56)
    #expect(restarted.x == 0 && restarted.travel == 0)
    let cancelled = Step.next(from: 28, travel: 30, delta: -4, precise: true, phase: .cancelled, momentum: [], snap: 28, limit: 56)
    #expect(cancelled.x == 28 && cancelled.travel == nil)
    let moved = Step.next(from: 56, travel: 5, delta: 3, precise: true, phase: .changed, momentum: [], snap: 28, limit: 56)
    #expect(moved.x == 56 && moved.travel == 53)
    let phaseless = Step.next(from: 0, travel: 12, delta: -20, precise: true, phase: [], momentum: [], snap: 28, limit: 56)
    #expect(phaseless.x == 28 && phaseless.travel == nil)
    let free = Step.next(from: 10, travel: nil, delta: -3, precise: true, phase: .changed, momentum: [], snap: 0, limit: 56)
    #expect(free.x == 13 && free.travel == nil)
  }

  @Test func shortcutKeycapsKeepRemappedAndDisabledBindings() {
    #expect(SidebarDotTooltip.keys("⌃1") == ["⌃", "1"])
    #expect(SidebarDotTooltip.keys("⌥⇧⌘F12") == ["⌥", "⇧", "⌘", "F12"])
    #expect(SidebarDotTooltip.keys(nil).isEmpty)
    #expect(SidebarDotTooltip.keys("").isEmpty)
  }
}
