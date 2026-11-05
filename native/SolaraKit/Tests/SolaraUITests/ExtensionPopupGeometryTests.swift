import CoreGraphics
import Foundation
import Testing
@testable import SolaraUI

struct ExtensionPopupGeometryTests {
  private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

  @Test func alignsToTheAnchorWithASixPointGap() {
    let anchor = CGRect(x: 700, y: 30, width: 28, height: 28)
    let frame = ExtensionPopupGeometry.frame(anchor: anchor, preferred: CGSize(width: 200, height: 80), bounds: bounds)
    #expect(frame == CGRect(x: 527, y: 64, width: 201, height: 81))
    #expect(frame.maxX == anchor.maxX)
    #expect(frame.minY - anchor.maxY == 6)
  }

  @Test func addsTheBorderAfterRoundingAndClampingThePreferredPageSize() {
    #expect(ExtensionPopupGeometry.size(preferred: CGSize(width: 200.1, height: 80.9), bounds: bounds) == CGSize(width: 202, height: 82))
    #expect(ExtensionPopupGeometry.size(preferred: CGSize(width: 0, height: -10), bounds: bounds) == CGSize(width: 26, height: 26))
    #expect(ExtensionPopupGeometry.size(preferred: CGSize(width: 3000, height: 2000), bounds: bounds) == CGSize(width: 801, height: 601))
  }

  @Test func clampsEveryEdgeAndPreservesTheWindowInset() {
    let size = CGSize(width: 200, height: 80)
    for anchor in [CGRect(x: -100, y: -100, width: 28, height: 28), CGRect(x: 1100, y: 900, width: 28, height: 28)] {
      let frame = ExtensionPopupGeometry.frame(anchor: anchor, preferred: size, bounds: bounds)
      #expect(frame.minX >= 8)
      #expect(frame.minY >= 8)
      #expect(frame.maxX <= bounds.maxX - 8)
      #expect(frame.maxY <= bounds.maxY - 8)
    }
  }

  @Test func growthAndShrinkageRecomputeTheRightAlignedFrame() {
    let anchor = CGRect(x: 700, y: 30, width: 28, height: 28)
    let small = ExtensionPopupGeometry.frame(anchor: anchor, preferred: CGSize(width: 40, height: 30), bounds: bounds)
    let large = ExtensionPopupGeometry.frame(anchor: anchor, preferred: CGSize(width: 400, height: 300), bounds: bounds)
    let shrunk = ExtensionPopupGeometry.frame(anchor: anchor, preferred: CGSize(width: 40, height: 30), bounds: bounds)
    #expect(small.maxX == large.maxX)
    #expect(small.minY == large.minY)
    #expect(large.width > small.width)
    #expect(large.height > small.height)
    #expect(shrunk == small)
  }

  @Test func aSmallWindowCapsTheSizeBeforeClampingTheOrigin() {
    let bounds = CGRect(x: 100, y: 50, width: 120, height: 100)
    let frame = ExtensionPopupGeometry.frame(anchor: CGRect(x: 200, y: 130, width: 28, height: 28), preferred: CGSize(width: 800, height: 600), bounds: bounds)
    #expect(frame == CGRect(x: 108, y: 58, width: 104, height: 84))
  }

  @Test func boundsSmallerThanTheInsetNeverProduceNegativeDimensions() {
    for side in [0.0, 8, 16] {
      let bounds = CGRect(x: 0, y: 0, width: side, height: side)
      let frame = ExtensionPopupGeometry.frame(anchor: .zero, preferred: CGSize(width: 800, height: 600), bounds: bounds)
      #expect(frame.width == 0)
      #expect(frame.height == 0)
      #expect(frame.minX >= 0 && frame.maxX <= side)
      #expect(frame.minY >= 0 && frame.maxY <= side)
    }
  }
}
