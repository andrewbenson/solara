import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarRailChromeTests {
  func state(rail: Bool, update: Bool = false) -> SidebarChromeState {
    SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: true, addressBar: true, dark: false, theme: [:],
      dots: [SidebarChromeDot(id: "p1", name: "Work", slot: 0), SidebarChromeDot(id: "p2", name: "Home", slot: 1)], savedWidth: 240,
      iconsOnly: rail, update: update ? SidebarUpdatePillState(text: "New Solara Version Available", tooltip: "Install update") : nil)
  }

  @Test func railHeaderUsesACentredIconButtonWithoutAnAddressField() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(state(rail: true))
    #expect(view.headerHeight == 36)
    #expect(view.addressSlot.isHidden)
    #expect(view.indicator.isHidden)
    #expect(view.headerDownloads.isHidden)
    #expect(!view.headerProfile.isHidden)
    #expect(view.headerProfile.frame == NSRect(x: 7, y: 4, width: 28, height: 28))
    #expect(view.headerProfile.accessibilityLabel() == "Work")
    #expect(view.headerProfile.accessibilityPerformPress())
    #expect(actions == [.profileMenu])
    #expect(view.resize.frame == NSRect(x: 38, y: 36, width: 4, height: 664))
  }

  @Test func aRailWithNothingInItsHeaderStartsTheTilesUnderTheToolbar() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    var single = state(rail: true)
    single.controls.profiles = 1
    view.update(single)
    #expect(view.headerHeight == 0)
    #expect(view.headerProfile.isHidden)
    var incognito = single
    incognito.controls.incognito = true
    view.update(incognito)
    #expect(view.headerHeight == 36)
    #expect(!view.headerProfile.isHidden)
  }

  @Test func theRailListLiftsItsGlowRoomSoTheFirstTileSitsSixPointsDown() {
    #expect(SidebarRail.listLift(addressBar: false) == SidebarMetrics.glowRoom + SidebarMetrics.listTopGap(addressBar: false) - 6)
    #expect(SidebarRail.listLift(addressBar: false) == 26)
    #expect(SidebarRail.listLift(addressBar: true) == 24)
  }

  @Test func fullWidthKeepsTheRailHeaderButtonHidden() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    view.update(state(rail: false))
    #expect(view.headerHeight == 80)
    #expect(!view.addressSlot.isHidden)
    #expect(view.headerProfile.isHidden)
    #expect(view.resize.frame == NSRect(x: 236, y: 46, width: 4, height: 654))
  }

  @Test func railDownloadsAndDotsHaveSeparateBands() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(rail: true))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }
    #expect(view.footerHeight == 82)
    #expect(view.footerDownloads.frame == NSRect(x: 4, y: 620, width: 34, height: 34))
    #expect(dots.map(\.frame) == [NSRect(x: 9, y: 664, width: 12, height: 28), NSRect(x: 21, y: 664, width: 12, height: 28)])
    #expect(dots.allSatisfy { !$0.frame.intersects(view.footerDownloads.frame) })
  }

  @Test func railUpdatePreservesSeparateFooterBands() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    view.update(state(rail: true, update: true))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }
    #expect(dots.allSatisfy { $0.frame.minY == 664 && !$0.frame.intersects(view.footerDownloads.frame) })
    #expect(view.footerDownloads.frame == NSRect(x: 4, y: 620, width: 34, height: 34))
    #expect(!view.updatePill.frame.intersects(view.footerDownloads.frame))
  }

  @Test func railUpdateIsACentredRoundAccessibleInstallButton() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 42, height: 700))
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(state(rail: true, update: true))
    #expect(view.footerHeight == 124)
    #expect(view.updatePill.frame == NSRect(x: 4, y: 576, width: 34, height: 34))
    #expect(view.bounds.contains(view.updatePill.frame))
    #expect(view.updatePill.toolTip == "New Solara Version Available")
    #expect(view.updatePill.accessibilityLabel() == "New Solara Version Available")
    #expect(view.updatePill.subviews.contains { $0 is NSImageView && !$0.isHidden })
    #expect(view.updatePill.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden })
    #expect(view.updatePill.accessibilityPerformPress())
    #expect(actions == [.installUpdate])
  }

  @Test func fullWidthFooterAndUpdateFramesAreUnchanged() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    view.update(state(rail: false, update: true))
    let dots = view.subviews.compactMap { $0 as? SidebarProfileDot }
    #expect(view.footerHeight == 79)
    #expect(view.footerDownloads.frame == NSRect(x: 6, y: 661, width: 34, height: 34))
    #expect(dots.map(\.frame) == [NSRect(x: 108, y: 664, width: 12, height: 28), NSRect(x: 120, y: 664, width: 12, height: 28)])
    #expect(view.updatePill.frame == NSRect(x: 8, y: 621, width: 224, height: 30))
    #expect(view.updatePill.toolTip == "Install update")
    #expect(view.updatePill.subviews.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isHidden })
  }
}
