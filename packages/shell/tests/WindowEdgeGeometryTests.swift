import Foundation
import XCTest
@testable import SolaraShellCore

final class WindowEdgeGeometryTests: XCTestCase {
  func testRevealAndHoldReflectAtEitherPhysicalEdge() {
    let frame = CGRect(x: 100, y: 80, width: 800, height: 600)
    for right in [false, true] {
      let x: (CGFloat) -> CGFloat = { right ? frame.maxX - $0 : frame.minX + $0 }
      XCTAssertTrue(WindowEdgeGeometry.inside(CGPoint(x: x(3), y: 300), window: frame, hold: 8, right: right))
      XCTAssertFalse(WindowEdgeGeometry.inside(CGPoint(x: x(9), y: 300), window: frame, hold: 8, right: right))
      XCTAssertTrue(WindowEdgeGeometry.inside(CGPoint(x: x(180), y: 300), window: frame, hold: 202, right: right))
      XCTAssertFalse(WindowEdgeGeometry.inside(CGPoint(x: x(3), y: 700), window: frame, hold: 202, right: right))
    }
  }

  func testOutsideReachStopsAtTheDisplayAndDoesNotCrossTheWindow() {
    let frame = CGRect(x: 100, y: 80, width: 800, height: 600)
    let screen = CGRect(x: 90, y: 0, width: 820, height: 900)
    for right in [false, true] {
      let x: (CGFloat) -> CGFloat = { right ? frame.maxX - $0 : frame.minX + $0 }
      XCTAssertTrue(WindowEdgeGeometry.outside(CGPoint(x: x(-6), y: 300), window: frame, screen: screen, reach: 24, right: right))
      XCTAssertFalse(WindowEdgeGeometry.outside(CGPoint(x: x(-12), y: 300), window: frame, screen: screen, reach: 24, right: right))
      XCTAssertFalse(WindowEdgeGeometry.outside(CGPoint(x: x(1), y: 300), window: frame, screen: screen, reach: 24, right: right))
      XCTAssertFalse(WindowEdgeGeometry.outside(CGPoint(x: x(-2), y: 79), window: frame, screen: screen, reach: 24, right: right))
    }
  }
}
