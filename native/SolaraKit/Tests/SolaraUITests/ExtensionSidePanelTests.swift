import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ExtensionSidePanelTests {
  @Test func rubberBandMatchesRN() {
    #expect(SidePanelMetrics.rubberBand(400) == 400)
    #expect(abs(SidePanelMetrics.rubberBand(690) - (600 + 36 * (1 - exp(-1)))) < 1e-9)
    #expect(abs(SidePanelMetrics.rubberBand(230) - (320 - 36 * (1 - exp(-1)))) < 1e-9)
    #expect(SidePanelMetrics.rubberBand(10_000) <= 636)
    #expect(SidePanelMetrics.clamp(700) == 600)
    #expect(SidePanelMetrics.clamp(100) == 320)
  }

  @Test func framesMatchRNHeader() {
    let f = SidePanelFrames(bounds: CGRect(x: 0, y: 0, width: 369, height: 700), width: 360, hasIcon: true)
    #expect(f.panel == CGRect(x: 9, y: 0, width: 360, height: 700))
    #expect(f.grip == CGRect(x: 6, y: 0, width: 7, height: 700))
    #expect(f.icon == CGRect(x: 12, y: 12, width: 16, height: 16))
    #expect(f.close == CGRect(x: 325, y: 5, width: 30, height: 30))
    #expect(f.menu == CGRect(x: 287, y: 5, width: 30, height: 30))
    #expect(f.title == CGRect(x: 36, y: 0, width: 243, height: 40))
    #expect(f.hairline == CGRect(x: 0, y: 40, width: 360, height: 1))
    #expect(f.content == CGRect(x: 0, y: 41, width: 360, height: 659))
    let bare = SidePanelFrames(bounds: CGRect(x: 0, y: 0, width: 360, height: 700), width: 360, hasIcon: false)
    #expect(bare.icon == nil)
    #expect(bare.title.minX == 12)
  }

  @Test func gripAndPanelTakeHitsAndTheRoomBesideDoesNot() {
    let view = ExtensionSidePanelView(frame: CGRect(x: 0, y: 0, width: 369, height: 700))
    view.set(title: "Ext", icon: nil, width: 360, look: SidePanelLook(card: .white, text: .black, icon: .black, hover: .gray, pressed: .darkGray, hairline: .lightGray, radius: 10))
    view.layoutSubtreeIfNeeded()
    #expect(view.hitTest(CGPoint(x: 8, y: 300)) is SidePanelGrip)
    #expect(view.hitTest(CGPoint(x: 2, y: 300)) == nil)
    #expect(view.hitTest(CGPoint(x: 200, y: 300)) === view.content)
  }

  @Test func nativeEmptyAndLoadingFillIsWhiteInBothThemes() throws {
    let view = ExtensionSidePanelView(frame: CGRect(x: 0, y: 0, width: 366, height: 700))
    for card in [NSColor.white.withAlphaComponent(0.7), NSColor(calibratedWhite: 18.0 / 255, alpha: 0.5)] {
      view.set(title: "Extension", icon: nil, width: 360, look: SidePanelLook(card: card, text: .black, icon: .black, hover: .gray, pressed: .darkGray, hairline: .lightGray, radius: 10))
      view.layoutSubtreeIfNeeded()
      let fill = try #require(view.content.layer?.backgroundColor)
      #expect(fill == NSColor.white.cgColor)
      #expect(view.content.frame == CGRect(x: 0, y: 41, width: 360, height: 659))
      #expect(view.content.subviews.isEmpty)
      let panel = try #require(view.subviews.first)
      #expect(panel.layer?.backgroundColor == card.cgColor)
      let radius = try #require(panel.layer?.cornerRadius)
      #expect(radius == CGFloat(10))
      #expect(panel.layer?.masksToBounds == true)
    }
  }

  @Test func iconRemovalRestoresTheNativeTitleInset() {
    let view = ExtensionSidePanelView(frame: CGRect(x: 0, y: 0, width: 326, height: 30))
    let look = SidePanelLook(card: .white, text: .black, icon: .black, hover: .gray, pressed: .darkGray, hairline: .lightGray, radius: 10)
    view.set(title: "Extension", icon: NSImage(size: CGSize(width: 16, height: 16)), width: 320, look: look)
    #expect(view.frames.title.minX == 36)
    view.set(title: "Extension", icon: nil, width: 320, look: look)
    view.layoutSubtreeIfNeeded()
    #expect(view.frames.title.minX == 12)
    #expect(view.frames.content.height == 0)
    #expect(view.frames.close == CGRect(x: 285, y: 5, width: 30, height: 30))
  }
}
