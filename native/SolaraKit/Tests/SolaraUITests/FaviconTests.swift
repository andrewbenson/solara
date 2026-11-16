import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct FaviconTests {
  private func state(_ mode: String, size: Int = 16, dark: Bool = false, initial: String = "É") -> FaviconState {
    FaviconState.decode("{\"mode\":\"\(mode)\",\"url\":\"https://xn--test.invalid\",\"size\":\(size),\"dark\":\(dark),\"textSecondary\":\"#00000080\",\"initial\":\"\(initial)\",\"token\":1}")!
  }

  @Test func fallbackReusesSidebarTileGeometryAndTheAdaptersDisplayInitial() {
    let view = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    view.update(state("fallback"), image: nil)
    let icon = view.subviews.first!
    let tile = icon.layer!.sublayers!.first!
    #expect(tile.frame == CGRect(x: 1, y: 1, width: 14, height: 14))
    #expect(abs(tile.cornerRadius - 4.48) < 0.001)
    #expect(!tile.isHidden)
    #expect(icon.subviews.first is DrawnLetterView)
    #expect(view.hitTest(NSPoint(x: 8, y: 8)) == nil)
    #expect(!view.isAccessibilityElement())
  }

  @Test func blankFallbackUsesTheSidebarGlobeAndLargeSizesKeepTheirRadius() {
    let view = FaviconView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    view.update(state("fallback", size: 24, initial: ""), image: nil)
    #expect(view.subviews.first!.subviews.first is SymbolView)
    view.update(state("image", size: 24), image: NSImage(size: NSSize(width: 24, height: 24)))
    let image = view.subviews.first!.layer!.sublayers!.last!
    #expect(image.frame.size == CGSize(width: 24, height: 24))
    #expect(image.cornerRadius == 4)
    #expect(view.hasImage)
  }

  @Test func marksRetainAppearanceOpacityAndDoNotPickUpFaviconClipping() {
    let view = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    let image = NSImage(size: NSSize(width: 16, height: 16))
    for dark in [false, true] {
      view.update(state("newTab", dark: dark), image: image)
      let layer = view.subviews.first!.layer!.sublayers!.last!
      #expect(abs(layer.opacity - (dark ? 0.28 : 0.3)) < 0.0001)
      #expect(layer.cornerRadius == 0)
    }
    view.update(nil, image: nil)
    #expect(view.isHidden && !view.hasImage && view.state == nil)
  }

  @Test func newTabMarkIsAvailableBeforeAnyHostFeed() throws {
    let favicons = SidebarFavicons()
    let mark = try #require(favicons.newTabMark)
    #expect(mark.isTemplate)
    #expect(mark.size == NSSize(width: 16, height: 16))
    let bitmap = try #require(mark.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && bitmap.bitmapData != nil, "Bundled new-tab mark must have a nonempty bitmap")
    #expect((0..<bitmap.pixelsHigh).contains { y in
      (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
    })
  }

  @Test func newTabTabsDrawTheBundledMarkInEveryAppearanceAndProfileTint() throws {
    let favicons = SidebarFavicons()
    var loads = 0
    favicons.loader = { _ in loads += 1; return nil }
    let icon = TabIconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    icon.favicons = favicons
    for dark in [false, true] {
      for color in ProfileColorValue.allCases {
        var host = SidebarHostState(profileId: color.rawValue, dark: dark)
        host.theme = ["accent": color.swatch, "textSecondary": color.swatch]
        icon.set(TabIconSpec(url: "", favicon: nil, customIcon: nil, profileId: color.rawValue), palette: SidebarPalette(host))
        icon.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        icon.needsLayout = true
        icon.layoutSubtreeIfNeeded()
        let layer = try #require(icon.layer)
        let image = try #require(layer.sublayers?.last)
        #expect(image.contents != nil && !image.isHidden)
        try #require(icon.bounds.width > 0 && icon.bounds.height > 0, "New-tab icon must be laid out before rendering")
        for scale in [CGFloat(1), CGFloat(2)] {
          let width = Int(icon.bounds.width * scale), height = Int(icon.bounds.height * scale)
          try #require(width > 0 && height > 0, "New-tab icon render must have positive pixel dimensions")
          let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
          let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.scaleBy(x: scale, y: scale)
          layer.render(in: context)
          let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
          try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && bitmap.bitmapData != nil, "Rendered new-tab icon must have a nonempty bitmap")
          #expect(bitmap.pixelsWide == width && bitmap.pixelsHigh == height)
          let pixels = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
          }.filter { $0.alphaComponent > 0.1 }
          try #require(!pixels.isEmpty, "New-tab icon must draw visible ink at \(scale)x, dark=\(dark), profile=\(color.rawValue)")
          let ink: CGFloat = dark ? 1 : 0
          #expect(pixels.allSatisfy { abs($0.redComponent - ink) < 0.01 && abs($0.greenComponent - ink) < 0.01 && abs($0.blueComponent - ink) < 0.01 })
        }
        #expect(image.frame.size == CGSize(width: 16, height: 16))
        #expect(abs(image.opacity - (dark ? 0.28 : 0.3)) < 0.0001)
        #expect(image.cornerRadius == 0)
      }
    }
    #expect(loads == 0)
  }

  @Test func newTabMarkOverridesAndReusedIconsKeepDrawing() throws {
    let favicons = SidebarFavicons()
    let icon = TabIconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    let palette = SidebarPalette(SidebarHostState(profileId: "default"))
    let spec = TabIconSpec(url: "", favicon: nil, customIcon: nil, profileId: "default")
    icon.favicons = favicons
    icon.set(spec, palette: palette)
    let first = try #require(icon.layer?.sublayers?.last?.contents) as AnyObject
    favicons.newTabMark = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      return true
    }
    icon.set(spec, palette: palette)
    let overridden = try #require(icon.layer?.sublayers?.last?.contents) as AnyObject
    #expect(first !== overridden)
    icon.clearBinding()
    favicons.newTabMark = nil
    icon.set(spec, palette: palette)
    #expect(icon.layer?.sublayers?.last?.contents != nil)
    #expect(icon.layer?.sublayers?.last?.isHidden == false)
  }

  @Test func hostedNewTabUsesTheBundledMarkWithoutAnImageURI() throws {
    let view = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    for dark in [false, true] {
      view.update(state("newTab", dark: dark), image: nil)
      let image = try #require(view.subviews.first?.layer?.sublayers?.last)
      #expect(image.contents != nil && !image.isHidden)
      #expect(view.hasImage)
      #expect(abs(image.opacity - (dark ? 0.28 : 0.3)) < 0.0001)
    }
  }

  @Test func malformedStatesCannotDrawAnUnboundedIcon() {
    #expect(FaviconState.decode("{}") == nil)
    #expect(FaviconState.decode("{\"mode\":\"image\",\"url\":\"\",\"size\":0,\"dark\":false,\"textSecondary\":\"#000\",\"token\":1}") == nil)
  }
}
