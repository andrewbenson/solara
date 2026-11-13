import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct SidebarInkTests {
  static func white(_ color: NSColor) -> Bool { (color.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.9 }

  @Test func darkInkTurnsTheSidebarsOwnGlyphsDark() {
    var host = SidebarHostState(profileId: "p", dark: true)
    let plain = SidebarPalette(host)
    #expect(plain.lightInk)
    #expect([plain.groupTitle, plain.newTabLabel, plain.newTabIcon, plain.noGroupIcon].allSatisfy(Self.white))
    host.theme = ["ink": "dark", "textPrimary": "#000000", "tabSelectedText": "#FFFFFF"]
    let inked = SidebarPalette(host)
    #expect(inked.dark)
    #expect(!inked.lightInk)
    #expect(![inked.groupTitle, inked.newTabLabel, inked.newTabIcon, inked.noGroupIcon].contains(where: Self.white))
    #expect(!Self.white(inked.textPrimary))
    #expect(Self.white(inked.selectedText))
    #expect(inked.selected == plain.selected)
    #expect(inked.groupFill == plain.groupFill)
  }

  @Test func inkOnlyMattersInDarkMode() {
    var host = SidebarHostState(profileId: "p", dark: false)
    host.theme = ["ink": "dark"]
    let palette = SidebarPalette(host)
    #expect(!palette.lightInk)
    #expect(!Self.white(palette.groupTitle))
  }
}
