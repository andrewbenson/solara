import Testing

@testable import SolaraUI

@Suite struct SidebarRailSnapTests {
  typealias Snap = SidebarResizeMath.Snap

  @Test func aFullSidebarDragsAsBeforeAboveTheSnapPoint() {
    #expect(SidebarResizeMath.snap(pointer: 300, fromRail: false, saved: 190) == Snap(width: 300, rail: false))
    #expect(SidebarResizeMath.snap(pointer: 140, fromRail: false, saved: 190) == Snap(width: SidebarResizeMath.rubberBand(140), rail: false))
  }

  @Test func draggingPastTheMinimumIntoTheBandSnapsToTheRail() {
    #expect(SidebarResizeMath.snap(pointer: SidebarResizeMath.snapIn - 0.5, fromRail: false, saved: 190) == Snap(width: SidebarRail.width, rail: true))
    #expect(SidebarResizeMath.snap(pointer: 20, fromRail: false, saved: 190) == Snap(width: SidebarRail.width, rail: true))
    #expect(!SidebarResizeMath.snap(pointer: SidebarResizeMath.snapIn + 0.5, fromRail: false, saved: 190).rail)
  }

  @Test func theSnapPointSitsInsideTheRubberBand() {
    #expect(SidebarResizeMath.snapIn == 78)
    #expect(SidebarResizeMath.snapOut == 68)
    #expect(SidebarResizeMath.snapIn < SidebarChromeMetrics.minWidth)
    #expect(SidebarResizeMath.snapIn > SidebarRail.width)
    #expect(SidebarResizeMath.snapOut > SidebarRail.width)
    #expect(SidebarResizeMath.snapOut < SidebarResizeMath.snapIn)
  }

  @Test func theRailHoldsUntilTheSnapOutPoint() {
    #expect(SidebarResizeMath.snap(pointer: SidebarRail.width + 10, fromRail: true, saved: 240) == Snap(width: SidebarRail.width, rail: true))
    #expect(SidebarResizeMath.snap(pointer: SidebarResizeMath.snapOut - 0.5, fromRail: true, saved: 240).rail)
  }

  @Test func draggingOutOfTheRailRestoresTheLastFullWidth() {
    #expect(SidebarResizeMath.snap(pointer: SidebarResizeMath.snapOut + 0.5, fromRail: true, saved: 240) == Snap(width: 240, rail: false))
    #expect(SidebarResizeMath.snap(pointer: 200, fromRail: true, saved: 240) == Snap(width: 240, rail: false))
    #expect(SidebarResizeMath.snap(pointer: 300, fromRail: true, saved: 240) == Snap(width: 300, rail: false))
    #expect(SidebarResizeMath.snap(pointer: 600, fromRail: true, saved: 240) == Snap(width: SidebarResizeMath.rubberBand(600), rail: false))
  }

  @Test func aSavedWidthOutsideTheLimitsComesBackClamped() {
    #expect(SidebarResizeMath.snap(pointer: 120, fromRail: true, saved: 90) == Snap(width: SidebarChromeMetrics.minWidth, rail: false))
  }
}
