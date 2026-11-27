import AppKit
import Testing

@testable import SolaraUI

private let flight = DownloadFlight(id: "d1", path: "a.zip", start: CGPoint(x: 600, y: 360), target: CGPoint(x: 24, y: 24))

@MainActor
@Suite struct DownloadMagnetTests {
  @Test func theArcMatchesRNsFiveSteps() {
    let c = DownloadMagnetMotion.centers(flight)
    #expect(c.count == 5)
    #expect(c[0] == CGPoint(x: 600, y: 360))
    #expect(c[4].x == 24 && abs(c[4].y - 24) < 1e-9)
    #expect(abs(c[2].x - 312) < 1e-9)
    #expect(abs(c[2].y - (192 - 90)) < 1e-9)
    #expect(abs(c[1].y - (360 + (24 - 360) * 0.25 - sin(.pi * 0.25) * 90)) < 1e-9)
  }

  @Test func aNewDownloadFliesOnceAndARepeatedStateDoesNothing() {
    let v = DownloadMagnetView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    v.iconFor = { _ in NSImage(size: NSSize(width: 44, height: 44)) }
    v.fly(flight)
    let first = try! #require(v.flightAnimation)
    #expect(first.duration == 0.7)
    #expect(first.animations?.count == 3)
    #expect(v.flying == "d1")
    v.fly(flight)
    #expect(v.flights == 1)
    #expect(v.flying == "d1")
  }

  @Test func theOpacityAndScaleKeyframesAreRNs() {
    #expect(DownloadMagnetMotion.opacityTimes == [0, 0.1, 0.8, 1])
    #expect(DownloadMagnetMotion.opacities == [0, 1, 1, 0])
    #expect(DownloadMagnetMotion.scaleTimes == [0, 0.15, 1])
    #expect(DownloadMagnetMotion.scales == [0.6, 1.1, 0.3])
  }

  @Test func itNeverTakesAClick() {
    let v = DownloadMagnetView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    #expect(v.hitTest(NSPoint(x: 50, y: 50)) == nil)
  }
}
