import XCTest
@testable import SolaraShellCore

final class TabNumberShortcutTests: XCTestCase {
  func testFormatsAppliedDefaultAndRemappedKeys() {
    XCTAssertEqual(TabNumberShortcut.formatted(key: "1", modifiers: ["command"]), "⌘1")
    XCTAssertEqual(TabNumberShortcut.formatted(key: "k", modifiers: ["command", "shift", "control"]), "⌃⇧⌘K")
    XCTAssertEqual(TabNumberShortcut.formatted(key: "\u{F70F}", modifiers: []), "F12")
  }

  func testUnboundShortcutHasNoHint() {
    XCTAssertNil(TabNumberShortcut.formatted(key: "", modifiers: ["command"]))
  }

  func testFormatsNavigationAndEditingKeys() {
    XCTAssertEqual(TabNumberShortcut.formatted(key: "\t", modifiers: ["option", "command"]), "⌥⌘⇥")
    XCTAssertEqual(TabNumberShortcut.formatted(key: "\u{F702}", modifiers: ["control"]), "⌃←")
  }
}
