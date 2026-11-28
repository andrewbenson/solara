import SolaraModel
import XCTest
@testable import SolaraUI

final class OmniboxCommandShortcutTests: XCTestCase {
  func testLiveBindingsAreAuthoritativeOverStoredDefaults() {
    let snapshot = CommandShortcutSnapshot(resolvedHints: [
      JSKey("focusCommandBar"): "⌃F5",
      JSKey("switchProfile:e\u{301}"): "⌃2",
      JSKey("std:copy:"): "⌘C",
    ])
    XCTAssertNil(snapshot.hint("newTab"))
    XCTAssertEqual(snapshot.hint("focusCommandBar"), "⌃F5")
    XCTAssertNil(snapshot.hint("switchProfile:é"))
    XCTAssertEqual(snapshot.hint("switchProfile:e\u{301}"), "⌃2")
    XCTAssertEqual(snapshot.hint("std:copy:"), "⌘C")
  }

  func testNewSnapshotDropsRemovedProfilesAndBindings() {
    let before = CommandShortcutSnapshot(resolvedHints: [JSKey("switchProfile:work"): "⌃2", JSKey("findNext"): "⌘G"])
    let after = CommandShortcutSnapshot(resolvedHints: [JSKey("findInPage"): "⌘G"])
    XCTAssertEqual(before.hint("findNext"), "⌘G")
    XCTAssertNil(after.hint("findNext"))
    XCTAssertNil(after.hint("switchProfile:work"))
    XCTAssertEqual(after.hint("findInPage"), "⌘G")
  }
}
