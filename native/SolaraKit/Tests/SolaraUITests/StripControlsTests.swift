import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct StripControlsTests {
  @Test(arguments: [CGFloat(0), 1, 8, 31, 32, 42, 83, 84])
  func aSingleProfileLeavesNoCaptionSlotInAnEmptyOrNarrowStrip(width: CGFloat) {
    let view = StripControlsView(frame: CGRect(x: 0, y: 0, width: width, height: 34))
    view.docked = true
    for fullscreen in [false, true] {
      view.windowFullscreen = fullscreen
      view.update(StripControlsState(title: "Personal", incognito: false, profiles: 1,
        nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
      view.layoutSubtreeIfNeeded()
      #expect(view.indicator.isHidden)
      #expect(view.profileSlotWidth == 0)
      #expect(view.dockedLayout.pageWidth == 0)
      #expect(view.dockedLayout.strip.size.width >= 0)
      #expect(view.downloads.frame.minX >= 0)
    }
  }

  @Test func theIndicatorShowsWithTwoProfilesOrIncognito() {
    #expect(!StripControlsLayout.indicator(textWidth: 60, incognito: false, profiles: 1).shown)
    #expect(StripControlsLayout.indicator(textWidth: 60, incognito: true, profiles: 1).shown)
    #expect(StripControlsLayout.indicator(textWidth: 60, incognito: false, profiles: 2) == StripIndicatorLayout(shown: true, showName: true, width: 78))
  }

  @Test func aLongNameIsCutAtTheRoomAndANarrowRoomShowsTheIcon() {
    #expect(StripControlsLayout.indicator(textWidth: 300, incognito: false, profiles: 2).width == 140)
    #expect(StripControlsLayout.indicator(textWidth: 300, room: 60, incognito: false, profiles: 2) == StripIndicatorLayout(shown: true, showName: false, width: 32))
    #expect(!StripControlsLayout.indicator(textWidth: 300, room: 20, incognito: false, profiles: 2).shown)
  }

  @Test func theControlsAreTheIndicatorAGapAndTheDownloadsBox() {
    #expect(StripControlsLayout.width(indicator: 0) == 34)
    #expect(StripControlsLayout.width(indicator: 78) == 114)
  }

  @Test func theDownloadsButtonSitsAtTheRightAndShowsOpenAsPressed() {
    let view = StripControlsView(frame: NSRect(x: 0, y: 0, width: 992, height: 34.5))
    var actions: [StripControlAction] = []
    view.onAction = { actions.append($0) }
    view.update(StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: true, downloadsTooltip: "Downloads"), theme: [:])
    #expect(view.downloads.frame.maxX == 992)
    #expect(view.indicator.frame.maxX < view.downloads.frame.minX)
    #expect(view.downloads.active)
    #expect(view.downloads.toolTip == nil)
    view.downloads.onPress?()
    view.indicator.press(SidebarClickMods(NSEvent.ModifierFlags()))
    #expect(actions == [.toggleDownloads, .profileMenu])
  }

  @Test func voiceOverReadsTheProfileAndTheDownloadsButtonAsButtons() {
    let view = StripControlsView(frame: NSRect(x: 0, y: 0, width: 992, height: 34.5))
    view.update(StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: true, downloadsTooltip: nil), theme: [:])
    #expect(view.indicator.isAccessibilityElement())
    #expect(view.indicator.accessibilityRole() == .button)
    #expect(view.indicator.accessibilityLabel() == "Work")
    #expect(view.downloads.accessibilityLabel() == "Downloads")
    #expect(view.downloads.accessibilityValue() == nil)
  }

  @Test func theDownloadsButtonSitsWhereYogaRoundsItsCentredQuarterPointOnlyWhenTheIndicatorShows() {
    let view = StripControlsView(frame: NSRect(x: 0, y: 0, width: 992, height: 34.5))
    view.update(StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    #expect(view.downloads.frame.minY == 0.5)
    view.update(StripControlsState(title: "Work", incognito: false, profiles: 1, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    #expect(view.downloads.frame.minY == 0)
    #expect(view.width == 34)
  }
}

@Suite struct StripNameWidthTests {
  @Test func theNameIsMeasuredAsRNsOnLayoutReportsItThenRoundedUp() {
    #expect(StripControlsLayout.measuredLikeYoga(54.834) == 56)
    #expect(StripControlsLayout.measuredLikeYoga(54.3) == 55)
    #expect(StripControlsLayout.measuredLikeYoga(55) == 56)
  }
}

@MainActor @Suite struct StripPeekRowTests {
  @Test func theProfilePrecedesTabsAndDownloadsKeepTheirRightInset() {
    let frames = StripPeekRow.frames(width: 1187, profileSlot: 84)
    #expect(frames.strip == CGRect(x: 92, y: 0, width: 1011, height: 42))
    #expect(frames.controls == CGRect(x: 0, y: 4, width: 1179, height: 34.5))
    #expect(StripPeekRow.frames(width: 1187, profileSlot: 0).strip.minX == 8)
    #expect(StripPeekRow.frames(width: 1187, profileSlot: 0).strip.width == 1095)
  }

  @Test func aOneLetterNameReservesTheIslandWhileNoNameReservesNothing() {
    let view = StripControlsView(frame: CGRect(x: 0, y: 0, width: 992, height: 34.5))
    view.leadingInset = 8
    view.profileCoveredByIsland = true
    view.update(StripControlsState(title: "A", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    #expect(view.profileSlotWidth == 84)
    #expect(view.indicator.frame.minX == 8)
    #expect(view.indicator.frame.maxX <= 84)
    #expect(view.downloads.frame.maxX == 992)
    for count in [0, 1] {
      view.update(StripControlsState(title: "", incognito: false, profiles: count, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
      #expect(view.profileSlotWidth == 0)
      #expect(view.indicator.isHidden)
    }
  }

  @Test func theWindowedProfileSitsAfterLightsAndBeforeTheFirstTab() {
    let view = StripControlsView(frame: CGRect(x: 0, y: 0, width: 992, height: 34.5))
    view.leadingInset = 86
    view.update(StripControlsState(title: "A", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    let tabStart = view.leadingInset + view.profileSlotWidth
    #expect(view.indicator.frame.minX == 86)
    #expect(view.indicator.frame.maxX < tabStart)
    #expect(tabStart == view.indicator.frame.maxX + 8)
    #expect(view.profileSlotWidth < 84)
    #expect(view.hitTest(CGPoint(x: 500, y: 17)) == nil)
    #expect(view.hitTest(CGPoint(x: 165, y: 17)) == nil)
  }

  @Test func dockedControlsReserveTheMeasuredProfileAndProtectOnlyTheFullscreenName() {
    for fullscreen in [false, true] {
      for (profileWidth, windowedSlot, fullscreenSlot): (CGFloat, CGFloat, CGFloat) in [(0, 0, 0), (26, 34, 84), (78, 86, 86), (140, 148, 148)] {
        let geometry = TopStripLeadingLayout(width: 1000, profileWidth: profileWidth, windowFullscreen: fullscreen)
        let leading: CGFloat = fullscreen ? 8 : 86
        let slot = fullscreen ? fullscreenSlot : windowedSlot
        #expect(geometry.profile.minX == leading)
        #expect(geometry.leading == leading + slot)
        #expect(geometry.pageWidth == 1000 - leading - slot - 84)
        #expect(geometry.strip.minX == leading + slot - StripMetrics.flare)
        #expect(geometry.strip.maxX == 931)
        #expect(geometry.downloads.maxX == 992)
        #expect(geometry.profile.midY == ShellMetrics.topStripLightsCenter.y)
        #expect(geometry.downloads.midY == ShellMetrics.topStripLightsCenter.y)
      }
    }
  }

  @Test func theSameShortNameExpandsOnlyWhenTheIslandCoversItAndRestoresOnExit() {
    let view = StripControlsView(frame: CGRect(x: 0, y: 0, width: 1000, height: 42))
    view.docked = true
    view.update(StripControlsState(title: "A", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    let windowedSlot = view.profileSlotWidth
    #expect(windowedSlot == view.profileWidth + 8)
    #expect(windowedSlot < 84)
    #expect(view.dockedLayout.leading == 86 + windowedSlot)
    view.windowFullscreen = true
    #expect(view.profileSlotWidth == 84)
    #expect(view.dockedLayout.leading == 92)
    view.windowFullscreen = false
    #expect(view.profileSlotWidth == windowedSlot)
    #expect(view.dockedLayout.leading == 86 + windowedSlot)
  }

  @Test func thePeekExplicitlyReservesTheIslandForShortNames() {
    let row = StripPeekRow(strip: TopStripView(windowId: "profile-slot"))
    defer { row.strip.stop() }
    row.frame = CGRect(x: 0, y: 0, width: 1000, height: 42)
    row.controls.update(StripControlsState(title: "A", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    row.layout()
    #expect(row.controls.profileSlotWidth == 84)
    #expect(row.strip.frame.minX == 92)
    #expect(row.pageWidth == 824)
  }

  @Test func captionAlignedRowsCentreBothControlsOnTheLightsWithoutChangingInsets() {
    let view = StripControlsView(frame: CGRect(x: 0, y: 3.75, width: 992, height: 34.5))
    view.leadingInset = 86
    view.captionAligned = true
    for count in [1, 2] {
      view.update(StripControlsState(title: "A", incognito: false, profiles: count, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
      #expect(view.indicator.frame.midY + view.frame.minY == ShellMetrics.topStripLightsCenter.y)
      #expect(view.downloads.frame.midY + view.frame.minY == ShellMetrics.topStripLightsCenter.y)
      #expect(view.downloads.frame.maxX == 992)
      #expect(view.profileSlotWidth == (count == 2 ? view.profileWidth + 8 : 0))
    }
  }

  @Test func aLongNameTruncatesBeforeTheTabLosesItsMinimumWidthAndRecoversOnResize() {
    let view = StripControlsView(frame: CGRect(x: 0, y: 0, width: 992, height: 34.5))
    view.leadingInset = 86
    view.update(StripControlsState(title: String(repeating: "Wide profile ", count: 20), incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    #expect(view.indicator.frame.width == 140)
    view.setFrameSize(CGSize(width: 392, height: 34.5))
    #expect(view.indicator.frame.width == 126)
    #expect(400 - 86 - view.profileSlotWidth - 84 == 96)
    #expect(view.downloads.frame.maxX == 392)
    view.setFrameSize(CGSize(width: 992, height: 34.5))
    #expect(view.indicator.frame.width == 140)
  }
}

@MainActor @Suite struct StripDropGlowTests {
  @Test func theGlowSitsFourPointsOutsideTheStripAndHugsTheItems() {
    let frame = StripDropGlowMetrics.frame(width: 1280, left: 86, right: 128)
    #expect(frame == CGRect(x: 82, y: 4, width: 1280 - 82 - 124, height: 34))
  }

  @Test func theGlowTakesNoMouse() {
    let glow = StripDropGlow(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
    #expect(glow.hitTest(NSPoint(x: 50, y: 17)) == nil)
  }

  @Test func overFlipsTheTargetOnceAndLeavingFlipsItBack() {
    let glow = StripDropGlow(frame: .zero)
    #expect(!glow.over)
    glow.set(over: true, accent: "#3478F6", dark: true)
    #expect(glow.over)
    glow.set(over: true, accent: "#3478F6", dark: true)
    glow.set(over: false, accent: "#3478F6", dark: true)
    #expect(!glow.over)
  }

  @Test func leavingBetweenFramesTurnsBackFromWhereTheGlowIsNow() {
    let glow = StripDropGlow(frame: .zero)
    glow.set(over: true, accent: "#3478F6", dark: true)
    Thread.sleep(forTimeInterval: StripDropGlowMetrics.duration / 2)
    glow.set(over: false, accent: "#3478F6", dark: true)
    #expect(glow.value > 0.5 && glow.value < 1)
  }
}
