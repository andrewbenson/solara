import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct DeveloperStripesTests {
  static let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../apps/browser/assets/developer-stripes-light.png").standardized
  static let darkAsset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../apps/browser/assets/developer-stripes-dark@2x.png").standardized

  static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
    Int(((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
  }

  static func onShare(_ rep: NSBitmapImageRep, row: Int) -> Double {
    let on = (0..<rep.pixelsWide).filter { alpha(rep, $0, row) >= 4 }.count
    return Double(on) / Double(rep.pixelsWide)
  }

  @Test(arguments: [CGFloat(1), 2, 3])
  func thePatternFillsTheWholeHeightAtEveryScale(scale: CGFloat) throws {
    let ink = try #require(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 5.0 / 255))
    let image = try #require(DeveloperStripes.image(size: CGSize(width: 512, height: 41), scale: scale, ink: ink))
    #expect(image.width == Int(512 * scale))
    #expect(image.height == Int(41 * scale))
    let rep = NSBitmapImageRep(cgImage: image)
    for row in [0, rep.pixelsHigh / 2, rep.pixelsHigh - 1] {
      #expect(abs(Self.onShare(rep, row: row) - 0.5) < 0.05)
    }
    let s = Int(scale)
    let bottom = rep.pixelsHigh - 1
    #expect(Self.alpha(rep, bottom + 2 * s, bottom) == 5)
    #expect(Self.alpha(rep, bottom + 20 * s, bottom) == 0)
    #expect(Self.alpha(rep, 0, 0) == 5)
    #expect(Self.alpha(rep, 18 * s, 0) == 0)
  }

  @Test func theInkComesFromTheAsset() throws {
    let light = try #require(NSImage(contentsOf: Self.asset), "copy apps/browser/assets next to native/SolaraKit")
    let dark = try #require(NSImage(contentsOf: Self.darkAsset))
    let white = try #require(DeveloperStripes.ink(of: light)?.components)
    let black = try #require(DeveloperStripes.ink(of: dark)?.components)
    #expect(white[0] > 0.99 && abs(white[3] - 5.0 / 255) < 0.002)
    #expect(black[0] < 0.01 && abs(black[3] - 5.0 / 255) < 0.002)
  }

  static func rendered(_ layer: CALayer, _ area: CGRect, scale: CGFloat) throws -> NSBitmapImageRep {
    let width = Int(area.width * scale), height = Int(area.height * scale)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: scale, y: scale)
    layer.render(in: context)
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
  }

  @Test func theLayerFillsTheBandAtOneAndTwoTimesWhicheverArrivesFirst() throws {
    try #require(FileManager.default.fileExists(atPath: Self.asset.path), "copy apps/browser/assets next to native/SolaraKit")
    let stripes = DeveloperStripes()
    stripes.show(Self.asset.path)
    #expect(!stripes.shown)
    let steps: [(CGRect, CGFloat)] = [
      (CGRect(x: 0, y: 0, width: 640, height: 41), 1),
      (CGRect(x: 0, y: 0, width: 640, height: 41), 2),
      (CGRect(x: 0, y: 0, width: 3100, height: 64), 2),
      (CGRect(x: 0, y: 0, width: 3100, height: 64), 1),
    ]
    for (area, scale) in steps {
      stripes.fit(area, scale: scale)
      #expect(stripes.shown)
      #expect(stripes.layer.contentsScale == scale)
      #expect(stripes.layer.frame.width >= area.width && stripes.layer.frame.height >= area.height)
      let rep = try Self.rendered(stripes.layer, area, scale: scale)
      for row in [0, rep.pixelsHigh / 2, rep.pixelsHigh - 1] {
        #expect(abs(Self.onShare(rep, row: row) - 0.5) < 0.05, "row \(row) at \(scale)x in \(area.size)")
      }
    }
    stripes.show(nil)
    #expect(!stripes.shown && stripes.layer.contents == nil)
  }

  static func stripesLayer(_ toolbar: ToolbarView) throws -> CALayer {
    let surface = try #require(toolbar.layer?.sublayers?.first)
    return try #require(surface.sublayers?[2])
  }

  static func expectCovers(_ layer: CALayer, _ bounds: CGRect, scale: CGFloat) throws {
    #expect(!layer.isHidden)
    #expect(layer.contentsScale == scale)
    #expect(layer.frame.minX <= bounds.minX && layer.frame.minY <= bounds.minY)
    #expect(layer.frame.maxX >= bounds.maxX && layer.frame.maxY >= bounds.maxY)
    let contents = layer.contents as! CGImage
    #expect(CGFloat(contents.width) == layer.frame.width * scale)
    #expect(CGFloat(contents.height) == layer.frame.height * scale)
  }

  static func expectStripedTopToBottom(_ view: NSView) throws {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    for row in [1, rep.pixelsHigh / 2, rep.pixelsHigh - 2] {
      var shades = Set<Int>()
      for x in 0..<min(rep.pixelsWide, 400) {
        if let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) { shades.insert(Int((c.redComponent * 255).rounded())) }
      }
      #expect(shades.count > 1, "row \(row) of \(rep.pixelsHigh) is plain")
    }
  }

  @Test func theToolbarStripesFillTheBandWhenTheWindowArrivesLateAndAfterAResize() throws {
    try #require(FileManager.default.fileExists(atPath: Self.asset.path), "copy apps/browser/assets next to native/SolaraKit")
    let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 803, height: 41))
    var state = ToolbarWebKitPillTests.state(extensions: "")
    state.height = 41
    state.palette.background = "#202030"
    state.stripes = Self.asset.path
    toolbar.update(state)
    toolbar.layoutSubtreeIfNeeded()
    let layer = try Self.stripesLayer(toolbar)
    try Self.expectCovers(layer, toolbar.bounds, scale: 2)

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    window.contentView = root
    root.addSubview(toolbar)
    toolbar.layoutSubtreeIfNeeded()
    try Self.expectCovers(layer, toolbar.bounds, scale: window.backingScaleFactor)
    try Self.expectStripedTopToBottom(toolbar)

    toolbar.setFrameSize(NSSize(width: 3100, height: 64))
    toolbar.layoutSubtreeIfNeeded()
    try Self.expectCovers(layer, toolbar.bounds, scale: window.backingScaleFactor)
    try Self.expectStripedTopToBottom(toolbar)

    state.stripes = nil
    toolbar.update(state)
    toolbar.layoutSubtreeIfNeeded()
    #expect(layer.isHidden && layer.contents == nil)
    window.close()
  }

  @Test func theAutoHideStripesFillTheBandAfterAResize() throws {
    try #require(FileManager.default.fileExists(atPath: Self.asset.path), "copy apps/browser/assets next to native/SolaraKit")
    let strip = AutoHideStripView(frame: CGRect(x: 0, y: 0, width: 640, height: 41))
    var style = AutoHideStripStyle(card: try #require(CSSColor("#202020")), band: nil, divider: try #require(CSSColor("rgba(0,0,0,0.1)")), secondary: try #require(CSSColor("#00000080")), host: "example.com", hasPage: true)
    style.stripes = Self.asset.path
    strip.set(style: style, mode: .shown, shownTop: 41)
    strip.layout()
    #expect(strip.stripesShown)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    window.contentView = root
    root.addSubview(strip)
    strip.setFrameSize(NSSize(width: 2900, height: 41))
    strip.layoutSubtreeIfNeeded()
    try Self.expectStripedTopToBottom(strip)
    window.close()
  }
}
