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

  @Test func malformedStatesCannotDrawAnUnboundedIcon() {
    #expect(FaviconState.decode("{}") == nil)
    #expect(FaviconState.decode("{\"mode\":\"image\",\"url\":\"\",\"size\":0,\"dark\":false,\"textSecondary\":\"#000\",\"token\":1}") == nil)
  }
}
