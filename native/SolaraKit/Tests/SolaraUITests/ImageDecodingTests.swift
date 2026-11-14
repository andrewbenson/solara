import AppKit
import Foundation
import Testing

@testable import SolaraUI

struct ImageDecodingTests {
  func png(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemOrange.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
  }

  @Test func aLargeFaviconIsDecodedSmallOffTheMainThread() async throws {
    let image = try #require(await ImageDecoding.decoded(png(512)))
    let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(max(cg.width, cg.height) <= ImageDecoding.faviconPixels)
    #expect(image.size == NSSize(width: 512, height: 512))
  }

  @Test func aSmallFaviconKeepsItsPixels() throws {
    let image = try #require(ImageDecoding.decodedNow(png(32)))
    let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(cg.width == 32)
    #expect(image.size == NSSize(width: 32, height: 32))
  }

  @Test func aMultiSizeIconKeepsTheFrameNearestTheDrawnSize() {
    #expect(ImageDecoding.frame(widths: [16, 32, 48, 256]) == 1)
    #expect(ImageDecoding.frame(widths: [256, 48, 16]) == 1)
    #expect(ImageDecoding.frame(widths: [16, 24]) == 1)
    #expect(ImageDecoding.frame(widths: [0, 64]) == 1)
    #expect(ImageDecoding.frame(widths: [0]) == nil)
  }

  @Test func garbageDecodesToNothing() {
    #expect(ImageDecoding.decodedNow(Data("not an image".utf8)) == nil)
    #expect(ImageDecoding.decodedNow(Data()) == nil)
    #expect(!ImageDecoding.isImage(Data("not an image".utf8)))
    #expect(ImageDecoding.isImage(png(16)))
  }
}
