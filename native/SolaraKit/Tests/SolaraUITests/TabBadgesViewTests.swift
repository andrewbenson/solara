import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct TabBadgesViewTests {
  private func badges(in view: TabBadgesView) -> [CornerBadge] {
    view.subviews.compactMap { $0 as? CornerBadge }.filter { !$0.isHidden }
  }

  @Test func pipSitsTopTrailingAThirdOutsideTheIcon() throws {
    let view = TabBadgesView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    view.set(pip: true, capture: nil, iconSize: 16, badge: .gray, badgeGlyph: .white)
    let shown = badges(in: view)
    #expect(shown.count == 1)
    #expect(shown[0].badgeFrame == CGRect(x: 16 - 12 + 4, y: -4, width: 12, height: 12))
    #expect(shown[0].plate.cornerRadius == 6)
  }

  @Test func screenCaptureSitsBottomTrailingInRed() throws {
    let view = TabBadgesView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    view.set(pip: false, capture: .screen, iconSize: 16, badge: .gray, badgeGlyph: .white)
    let shown = try #require(badges(in: view).first)
    #expect(shown.badgeFrame == CGRect(x: 8, y: 8, width: 12, height: 12))
    #expect(shown.plate.backgroundColor == MediaTokens.captureRed.cgColor)
  }

  @Test func cameraIsARingedDotAQuarterOutside() throws {
    let view = TabBadgesView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    view.set(pip: false, capture: .camera, iconSize: 16, badge: .gray, badgeGlyph: .white)
    let shown = try #require(badges(in: view).first)
    #expect(shown.badgeFrame == CGRect(x: 16 - 7 + 1.75, y: 16 - 7 + 1.75, width: 7, height: 7))
    #expect(shown.plate.borderWidth == 1)
    view.set(pip: false, capture: .camera, iconSize: 10, badge: .gray, badgeGlyph: .white)
    #expect(try #require(badges(in: view).first).badgeFrame.width == 6)
  }

  @Test func bothShowTogetherAndClearingHidesThem() {
    let view = TabBadgesView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    view.set(pip: true, capture: .screen, iconSize: 16, badge: .gray, badgeGlyph: .white)
    #expect(badges(in: view).count == 2)
    #expect(!view.isEmpty)
    view.set(pip: false, capture: nil, iconSize: 16, badge: .gray, badgeGlyph: .white)
    #expect(badges(in: view).isEmpty)
    #expect(view.isEmpty)
  }

  @Test func badgesFollowTheIconWhenItResizes() throws {
    let view = TabBadgesView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    view.set(pip: false, capture: .screen, iconSize: 16, badge: .gray, badgeGlyph: .white)
    view.setFrameSize(CGSize(width: 20, height: 20))
    #expect(try #require(badges(in: view).first).badgeFrame.origin == CGPoint(x: 12, y: 12))
  }

  @Test func aChipKeepsFourCharactersAndAMinimumWidth() {
    let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    let short = CornerBadgeSpec(shape: .chip(text: "1", font: font, color: .white, minWidth: 13, radius: 3), fill: .red, corner: .bottomTrailing, size: 11, outset: CGPoint(x: -1, y: -3))
    #expect(short.frame(in: CGSize(width: 28, height: 28), scale: 2) == CGRect(x: 28 - 13 - 1, y: 28 - 11 - 3, width: 13, height: 11))
    let long = CornerBadgeSpec(shape: .chip(text: "123456", font: font, color: .white, minWidth: 13, radius: 3), fill: .red, corner: .bottomTrailing, size: 11, outset: .zero)
    let four = CornerBadgeSpec(shape: .chip(text: "1234", font: font, color: .white, minWidth: 13, radius: 3), fill: .red, corner: .bottomTrailing, size: 11, outset: .zero)
    #expect(long.frame(in: CGSize(width: 28, height: 28), scale: 2) == four.frame(in: CGSize(width: 28, height: 28), scale: 2))
  }
}
