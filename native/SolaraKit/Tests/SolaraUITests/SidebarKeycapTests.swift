import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarKeycapTests {
  @Test(arguments: ["⌃", "⌥", "⇧", "⌘", "1", "3", "9", "K", "F12"])
  func keycapGlyphsSitInTheMiddleOfTheirCap(key: String) {
    let cap = SidebarKeycap(frame: NSRect(x: 0, y: 0, width: SidebarDotTooltipMetrics.keycapWidth(key), height: SidebarDotTooltipMetrics.keycapHeight))
    cap.font = .systemFont(ofSize: SidebarDotTooltipMetrics.keycapFont, weight: .semibold)
    cap.stringValue = key
    let glyph = cap.glyphRect
    #expect(glyph.width > 0 && glyph.height > 0)
    #expect(abs(glyph.midX - cap.bounds.midX) <= 0.5)
    #expect(abs(glyph.midY - cap.bounds.midY) <= 0.5)
    #expect(cap.bounds.contains(glyph))
  }
}
