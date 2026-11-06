import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarBadgeChipTests {
  static func button(_ json: String) throws -> ToolbarButtonView {
    let state = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(json.utf8))
    let button = ToolbarButtonView(state: state, palette: ToolbarPressTests.palette)
    button.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
    button.layoutSubtreeIfNeeded()
    button.apply()
    return button
  }

  static func chip(in button: ToolbarButtonView) -> CornerBadge? {
    button.subviews.compactMap { $0 as? CornerBadge }.first
  }

  static func previousFrame(text: String, in box: CGSize, scale: CGFloat) -> CGRect {
    let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    let textWidth = NSAttributedString(string: String(text.prefix(4)), attributes: [.font: font]).size().width
    let w = max(13, ceil((textWidth + 5) * scale) / scale)
    return CGRect(x: box.width - 1 - w, y: box.height - 3 - 11, width: w, height: 11)
  }

  @Test(arguments: ["3", "12", "99+", "12345", "NEW"])
  func theChipSitsWhereTheHandDrawnChipDid(text: String) throws {
    let button = try Self.button(##"{"id":"ext","icon":"puzzlepiece","badge":{"text":"\##(text)","color":"#D93025","textColor":"#FFFFFF"}}"##)
    let chip = try #require(Self.chip(in: button))
    #expect(chip.badgeFrame == Self.previousFrame(text: text, in: button.bounds.size, scale: 2))
    #expect(chip.frame.origin.x == chip.frame.origin.x.rounded(.down) && chip.frame.origin.y == chip.frame.origin.y.rounded(.down))
    guard case .chip(let shown, _, _, let minWidth, let radius)? = chip.spec?.shape else { Issue.record("not a chip"); return }
    #expect(shown == text && minWidth == 13 && radius == 3)
    #expect(chip.plate.cornerRadius == 3)
    #expect(chip.hitTest(NSPoint(x: chip.frame.midX, y: chip.frame.midY)) == nil)
  }

  @Test func anEmptyOrMissingBadgeRemovesTheChip() throws {
    let button = try Self.button(##"{"id":"ext","icon":"puzzlepiece","badge":{"text":"7","color":"#D93025","textColor":"#FFFFFF"}}"##)
    #expect(Self.chip(in: button) != nil)
    button.state.badge?.text = ""
    #expect(Self.chip(in: button) == nil)
    button.state.badge = ToolbarBadgeState(text: "8", color: "#D93025", textColor: "#FFFFFF")
    #expect(Self.chip(in: button) != nil)
    button.state.badge = nil
    #expect(Self.chip(in: button) == nil)
  }
}
