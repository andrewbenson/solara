import Foundation
import Testing
@testable import SolaraUI

struct BookmarksBarLayoutTests {
  @Test func exactFitNeedsNoOverflowButton() {
    let result = BookmarksBarLayout(itemWidths: [60, 80], width: 156, hasOther: false)
    #expect(result.visible.map(\.index) == [0, 1])
    #expect(result.visible.map(\.frame) == [CGRect(x: 8, y: 3, width: 60, height: 24), CGRect(x: 68, y: 3, width: 80, height: 24)])
    #expect(result.overflowIndexes.isEmpty)
    #expect(result.overflowFrame == nil)
  }

  @Test func overflowReservesItsOwnWidthBeforeChoosingTheVisiblePrefix() {
    let result = BookmarksBarLayout(itemWidths: [60, 80], width: 155, hasOther: false)
    #expect(result.visible.map(\.index) == [0])
    #expect(result.overflowIndexes == [1])
    #expect(result.overflowFrame == CGRect(x: 119, y: 3, width: 28, height: 24))
  }

  @Test func aFirstItemThatDoesNotFitKeepsAllFollowingItemsInOverflow() {
    let result = BookmarksBarLayout(itemWidths: [110, 10], width: 116, hasOther: false)
    #expect(result.visible.isEmpty)
    #expect(result.overflowIndexes == [0, 1])
    #expect(result.overflowFrame == CGRect(x: 80, y: 3, width: 28, height: 24))
  }

  @Test func otherBookmarksReserves150PointsAtTheTrailingEdge() {
    let result = BookmarksBarLayout(itemWidths: [90, 90], width: 346, hasOther: true)
    #expect(result.visible.map(\.index) == [0, 1])
    #expect(result.overflowIndexes.isEmpty)
    #expect(result.dividerFrame == CGRect(x: 194, y: 8, width: 1, height: 14))
    #expect(result.otherFrame == CGRect(x: 201, y: 3, width: 137, height: 24))
    let overflowing = BookmarksBarLayout(itemWidths: [90, 90], width: 345, hasOther: true)
    #expect(overflowing.visible.map(\.index) == [0])
    #expect(overflowing.overflowIndexes == [1])
    #expect(overflowing.overflowFrame?.maxX == overflowing.contentFrame.maxX)
    #expect(overflowing.overflowFrame!.maxX < overflowing.dividerFrame!.minX)
  }

  @Test func emptyBarsHaveNoOverflowAndKeepRoomForOtherBookmarks() {
    let empty = BookmarksBarLayout(itemWidths: [], width: 400, hasOther: false)
    #expect(empty.visible.isEmpty)
    #expect(empty.overflowIndexes.isEmpty)
    #expect(empty.overflowFrame == nil)
    #expect(empty.otherFrame == nil)
    #expect(empty.contentFrame == CGRect(x: 8, y: 3, width: 384, height: 24))
    let other = BookmarksBarLayout(itemWidths: [], width: 400, hasOther: true)
    #expect(other.contentFrame.width == 234)
    #expect(other.otherFrame != nil)
  }

  @Test func measuredLongItemsAreCappedBeforeFitting() {
    let result = BookmarksBarLayout(itemWidths: [1200, 30], width: 236, hasOther: false)
    #expect(result.visible.map(\.frame.width) == [190, 30])
    #expect(result.overflowIndexes.isEmpty)
  }

  @Test func tinyAndNegativeWidthsProduceNoNegativeFrames() {
    for width in [-10.0, 0, 8, 16, 30, 78] {
      for hasOther in [false, true] {
        let result = BookmarksBarLayout(itemWidths: [60, 70], width: width, hasOther: hasOther)
        #expect(result.visible.isEmpty)
        #expect(result.overflowIndexes == [0, 1])
        for frame in [result.contentFrame, result.overflowFrame, result.otherFrame, result.dividerFrame].compactMap({ $0 }) {
          #expect(frame.width >= 0)
          #expect(frame.maxX <= max(8, width - 8))
        }
      }
    }
  }

  @Test func exactOverflowBoundaryKeepsTheLastWholeItem() {
    let result = BookmarksBarLayout(itemWidths: [70, 100], width: 114, hasOther: false)
    #expect(result.visible.map(\.index) == [0])
    #expect(result.overflowFrame?.minX == result.visible.last?.frame.maxX)
  }
}
