import CoreGraphics
import Testing

@testable import SolaraUI

@Suite struct SidebarRailGeometryTests {
  private let size = CGSize(width: 1200, height: 800)

  @Test func theRailAndPageShareTheCardBelowTheToolbar() {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: 42))
    #expect(frames.card == CGRect(x: 42, y: 0, width: 1151, height: 793))
    #expect(frames.sidebar == CGRect(x: 0, y: 0, width: 42, height: 800))
    #expect(frames.page == CGRect(x: 42, y: 32, width: 1151, height: 761))
    #expect(frames.sidebarShift == 0)
    #expect(frames.lights == CGPoint(x: 25, y: 16))
    #expect(frames.topStrip == nil)
    #expect(frames.lights!.y == frames.page.minY - frames.lights!.y)
    #expect(frames.page.minY == ShellMetrics.railToolbarHeight)
  }

  @Test func theToolbarHoldsAllThreeLightsBeforeItsFirstButton() throws {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: 42))
    let lights = try #require(frames.lights)
    let top = frames.card.minY
    let firstButtonLeft = ShellMetrics.toolbarIconCenters[0] - 15 + ShellMetrics.railToolbarLeadingInset
    #expect(lights.y - ShellMetrics.trafficLightSize / 2 >= top)
    #expect(lights.y + ShellMetrics.trafficLightSize / 2 <= top + ShellMetrics.railToolbarHeight)
    #expect(lights.x + 2 * ShellMetrics.trafficLightPitch + ShellMetrics.trafficLightSize / 2 < firstButtonLeft)
    #expect(firstButtonLeft - (lights.x + 2 * ShellMetrics.trafficLightPitch + ShellMetrics.trafficLightSize / 2) == 19)
    #expect(firstButtonLeft + 15 == 112)
  }

  @Test func theBandFadesIntoTheFrameTintOverTwoHundredPointsAtBothEnds() {
    let stops = ShellMetrics.railBandStops(width: 1200)
    #expect(stops.clearUntil == 40)
    #expect(stops.fullFrom == 240)
    #expect(stops.fullUntil == 993)
    #expect(stops.clearFrom == 1193)
    let mask = ShellMetrics.railBandMask(width: 1200, edge: 0)
    #expect(mask.count >= 2 * 8)
    #expect(zip(mask, mask.dropFirst()).allSatisfy { $0.location <= $1.location })
    #expect(mask.first { $0.location == 140 }?.alpha == 0.5)
    #expect(mask.filter { $0.location <= 40 }.allSatisfy { $0.alpha == 0 })
    #expect(mask.filter { $0.location >= 240 && $0.location <= 993 }.allSatisfy { $0.alpha == 1 })
    #expect(mask.filter { $0.location >= 1193 }.allSatisfy { $0.alpha == 0 })
    let rise = mask.filter { $0.location > 40 && $0.location < 240 }.map(\.alpha)
    #expect(rise.first! < 0.05 && rise.last! > 0.95)
    let narrow = ShellMetrics.railBandStops(width: 300)
    #expect(narrow.clearUntil <= narrow.fullFrom && narrow.fullFrom <= narrow.fullUntil && narrow.fullUntil <= narrow.clearFrom)
  }

  @Test(arguments: [false, true]) func lightsMoveContinuouslyBetweenFullSidebarAndRail(_ addressBar: Bool) {
    var previous: CGPoint?
    for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
      let width = 240 + (42 - 240) * progress
      let input = DockedLayoutInput(size: size, dock: 1, sidebarWidth: width, addressBarInSidebar: addressBar, railProgress: progress)
      let frames = DockedLayoutFrames.of(input)
      let point = frames.lights ?? ShellMetrics.lightsCenter
      let start = ShellMetrics.lightsCenter
      #expect(abs(point.x - (start.x + (ShellMetrics.railLightsCenter.x - start.x) * progress)) < 0.001)
      #expect(abs(point.y - (start.y + (ShellMetrics.railLightsCenter.y - start.y) * progress)) < 0.001)
      if let previous { #expect(hypot(point.x - previous.x, point.y - previous.y) <= abs(ShellMetrics.lightsCenter.y - ShellMetrics.railLightsCenter.y) / 4) }
      previous = point
    }
  }

  @Test(arguments: [CGFloat(160), 190, 240, 400]) func fullSidebarFramesStayUnchanged(_ width: CGFloat) {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: width))
    #expect(frames.card == CGRect(x: width, y: 6, width: size.width - width - 7, height: 787))
    #expect(frames.sidebar == CGRect(x: 0, y: 0, width: width, height: 800))
    #expect(frames.page == CGRect(x: width, y: 47, width: size.width - width - 7, height: 746))
    #expect(frames.sidebarShift == 0)
    #expect(frames.lights == nil)
  }

  @Test func aHiddenRailLeavesTheCardAndToolbarLightsInPlace() {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, sidebarWidth: 42, away: true))
    #expect(frames.card == CGRect(x: 7, y: 0, width: 1186, height: 793))
    #expect(frames.page == CGRect(x: 7, y: 32, width: 1186, height: 761))
    #expect(frames.lights == ShellMetrics.railLightsCenter)
  }

  @Test func peekingARailStaysUnderTheToolbar() {
    for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
      let frames = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, sidebarWidth: 42, peeking: true, peekSlide: progress))
      #expect(frames.card == CGRect(x: 7, y: 0, width: 1186, height: 793))
      #expect(frames.sidebar == CGRect(x: 0, y: 0, width: 42, height: 800))
      #expect(frames.sidebarShift == -42 * (1 - progress))
      #expect(frames.page.minX == 7)
      #expect(frames.page.maxX == frames.card.maxX)
      #expect(frames.lights == ShellMetrics.railLightsCenter)
    }
  }

  @Test(arguments: [false, true]) func hiddenSidebarAddressUsesAChromeRowAboveTheCard(_ fullscreen: Bool) {
    let input = DockedLayoutInput(size: size, dock: 0, addressBarInSidebar: true, windowFullscreen: fullscreen)
    let frames = DockedLayoutFrames.of(input)
    #expect(input.chromeNavigationRow)
    #expect(frames.card.minY == ShellMetrics.cardTop + ShellMetrics.toolbarHeight)
    #expect(frames.page == frames.card)
    #expect((frames.lights ?? ShellMetrics.lightsCenter) == ShellMetrics.lightsCenter)
    #expect(input.trafficLightsLeadingInset(at: 0, reveal: 1) > ShellMetrics.railLightsTrailing)
    if fullscreen { #expect(input.trafficLightsLeadingInset(at: 0, reveal: 0) == 0) }
  }

  @Test(arguments: [false, true]) func hiddenSidebarChromeIgnoresTheLegacySidebarHeaderLightCenter(_ fullscreen: Bool) {
    var input = DockedLayoutInput(size: size, dock: 0, addressBarInSidebar: true, windowFullscreen: fullscreen)
    let center = DockMotion.sidebarLightsCenter(input, base: ShellMetrics.arcLightsCenter) ?? ShellMetrics.lightsCenter
    #expect(center == ShellMetrics.lightsCenter)
    input.peeking = true
    input.peekSlide = 1
    let peekCenter = DockMotion.sidebarLightsCenter(input, base: ShellMetrics.arcLightsCenter)
    #expect(peekCenter?.y == ShellMetrics.arcLightsCenter.y + ShellMetrics.peekOrigin.y)
  }

  @Test(arguments: [false, true]) func sidebarAddressLeavesNoToolbarBandInTheCard(_ fullscreen: Bool) {
    let input = DockedLayoutInput(size: size, dock: 1, addressBarInSidebar: true, windowFullscreen: fullscreen)
    let frames = DockedLayoutFrames.of(input)
    #expect(!input.chromeNavigationRow)
    #expect(frames.card.minY == ShellMetrics.cardTop)
    #expect(frames.page == frames.card)
    #expect((frames.lights ?? ShellMetrics.lightsCenter) == ShellMetrics.lightsCenter)
  }

  @Test func fullscreenCaptionReservationCanUseEitherOwnerChoice() {
    for side in [SidebarSide.left, .right] {
      for hidden in [false, true] {
        let input = DockedLayoutInput(size: size, dock: hidden ? 0 : 1, sidebarWidth: 42, sidebarSide: side, windowFullscreen: true)
        let full = input.trafficLightsLeadingInset(at: 6, reveal: 1, reserve: true)
        #expect(full > 0)
        for reveal: CGFloat in [0, 0.25, 0.5, 1] {
          #expect(input.trafficLightsLeadingInset(at: 6, reveal: reveal, reserve: true) == full)
          #expect(input.trafficLightsLeadingInset(at: 6, reveal: reveal, reserve: false) == full * reveal)
        }
      }
    }
  }

  @Test(arguments: [false, true]) func rightSidebarAddressPutsTheCardBelowTheThinLightsRow(_ fullscreen: Bool) {
    let input = DockedLayoutInput(size: size, dock: 1, addressBarInSidebar: true, sidebarSide: .right, windowFullscreen: fullscreen)
    let frames = DockedLayoutFrames.of(input)
    #expect(input.chromeCaptionRow)
    #expect(!input.chromeNavigationRow)
    #expect(frames.card.minY == ShellMetrics.cardTop + ShellMetrics.toolbarHeight)
    #expect(frames.page == frames.card)
  }

  @Test func topTabsAndFullscreenIgnoreRailGeometry() {
    for fullscreen in [false, true] {
      let rail = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: 42, topTabs: true, fullscreen: fullscreen))
      let full = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: 240, topTabs: true, fullscreen: fullscreen))
      #expect(rail == full)
    }
    let fullscreen = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidebarWidth: 42, fullscreen: true))
    #expect(fullscreen.card == CGRect(origin: .zero, size: size))
    #expect(fullscreen.sidebar == nil)
    #expect(fullscreen.page == CGRect(x: 0, y: 41, width: 1200, height: 759))
    #expect(fullscreen.lights == nil)
  }
}
