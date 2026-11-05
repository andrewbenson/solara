import Foundation

public struct BookmarksBarLayout: Equatable, Sendable {
  public struct Placement: Equatable, Sendable {
    public var index: Int
    public var frame: CGRect
  }

  public var visible: [Placement]
  public var overflowIndexes: [Int]
  public var overflowFrame: CGRect?
  public var otherFrame: CGRect?
  public var dividerFrame: CGRect?
  public var contentFrame: CGRect

  public init(itemWidths: [CGFloat], width: CGFloat, hasOther: Bool) {
    let innerWidth = max(0, width - 16)
    let reserved = hasOther ? min(150, innerWidth) : 0
    let available = innerWidth - reserved
    contentFrame = CGRect(x: 8, y: 3, width: available, height: 24)
    let widths = itemWidths.map { min(190, max(0, $0)) }
    let overflowing = widths.reduce(0, +) > available
    let overflowWidth: CGFloat = overflowing ? min(28, available) : 0
    let budget = available - overflowWidth
    var x: CGFloat = 8
    visible = []
    for (index, itemWidth) in widths.enumerated() {
      guard x - 8 + itemWidth <= budget else { break }
      visible.append(Placement(index: index, frame: CGRect(x: x, y: 3, width: itemWidth, height: 24)))
      x += itemWidth
    }
    overflowIndexes = Array(visible.count..<widths.count)
    overflowFrame = overflowing && overflowWidth > 0 ? CGRect(x: 8 + available - overflowWidth, y: 3, width: overflowWidth, height: 24) : nil
    if hasOther, reserved > 13 {
      let start = 8 + available
      dividerFrame = CGRect(x: start + 6, y: 8, width: 1, height: 14)
      otherFrame = CGRect(x: start + 13, y: 3, width: reserved - 13, height: 24)
    }
  }
}
