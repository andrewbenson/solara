import CoreGraphics
import Testing

@testable import SolaraUI

@Suite struct SidebarDragModelTests {
  private let grid = CGRect(x: 6, y: 54, width: 178, height: 41)

  @Test func balancedPinSlotsAndHeightFollowTheBalancedGrid() {
    #expect(PinZone.slot(grid: grid, count: 4, x: 155, y: 74, balanced: true) == 1)
    #expect(PinZone.slot(grid: grid, count: 4, x: 30, y: 120, balanced: true) == 2)
    #expect(PinZone.slot(grid: grid, count: 4, x: 155, y: 120, balanced: true) == 3)
    #expect(PinZone.slot(grid: grid, count: 5, x: 155, y: 74, balanced: true) == 2)
    #expect(PinZone.slot(grid: grid, count: 5, x: 155, y: 160, balanced: true) == 4)
    #expect(PinZone.height(4, 178, true) == 88)
    #expect(PinZone.height(9, 400, true) == 135)
  }

  @Test func pinSlotUnderThePointerIsItsIndexAfterTheDrop() {
    for (count, x, y, expected) in [(3, 30.0, 74.0, 0), (3, 95, 74, 1), (3, 155, 74, 2), (3, 155, 105, 2), (4, 155, 74, 2), (4, 30, 120, 3), (4, 155, 120, 3), (4, -40, 10, 0)] {
      #expect(PinZone.slot(grid: grid, count: count, x: CGFloat(x), y: CGFloat(y), balanced: false) == expected)
    }
  }

  @Test func sidewaysDraggingBelowPinsStaysOnTheSameRowsSlots() {
    let slots = [30.0, 60, 95, 120, 155].map { PinZone.slot(grid: grid, count: 3, x: CGFloat($0), y: 105, balanced: false) }
    #expect(slots == [0, 0, 1, 1, 2])
  }

  @Test func pinZoneReachesTheListWithoutBoundaryFlipFlops() {
    #expect(PinZone.hysteresis == 6)
    #expect(PinZone.over(105, listTop: 117, wasOver: false))
    #expect(!PinZone.over(115, listTop: 117, wasOver: false))
    #expect(PinZone.over(115, listTop: 117, wasOver: true))
    #expect(PinZone.over(122, listTop: 117, wasOver: true))
    #expect(!PinZone.over(124, listTop: 117, wasOver: true))
    var over = true
    var flips: [Int] = []
    for y in [110, 116, 119, 121, 118, 122, 117, 115, 112, 110] {
      let next = PinZone.over(CGFloat(y), listTop: 117, wasOver: over)
      if next != over { flips.append(y) }
      over = next
    }
    #expect(flips.isEmpty)
  }

  @Test func pinGridHeightUsesItsRowCountAfterTheDrop() {
    for (count, expected) in [(3, 41.0), (4, 88), (2, 41), (0, 41), (7, 135)] {
      #expect(PinZone.height(count, 178, false) == CGFloat(expected))
    }
  }
}
