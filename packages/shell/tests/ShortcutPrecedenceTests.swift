import XCTest
@testable import SolaraShellCore

final class ShortcutPrecedenceTests: XCTestCase {
  func standard(_ id: String, _ command: String? = nil) -> ShortcutPrecedence {
    ShortcutPrecedence.standard(shortcutId: id, command: command ?? id)
  }

  func testTabAndProfileNavigationGoesToSolaraFirst() {
    for id in ["nextTab", "previousTab", "newTab", "closeTab", "reopenClosedTab", "newWindow", "newIncognitoWindow", "selectLastTab", "nextProfile", "previousProfile"] {
      XCTAssertEqual(standard(id), .solara, id)
    }
    XCTAssertEqual(standard("selectTab:3", "selectTab"), .solara)
    XCTAssertEqual(standard("tabSwitcher:forward", "tabSwitcher"), .solara)
    XCTAssertEqual(standard("switchProfile:p-work", "switchProfile"), .solara)
    XCTAssertEqual(standard("newWindow:p-work", "newWindow"), .solara)
  }

  func testQuitAndCloseWindowGoToSolaraFirst() {
    XCTAssertEqual(ShortcutPrecedence.standard(shortcutId: "std:quit:", command: nil), .solara)
    XCTAssertEqual(ShortcutPrecedence.standard(shortcutId: "std:closeWindow:", command: nil), .solara)
  }

  func testKeysAppsReuseAreShared() {
    for id in ["toggleSidebar", "findInPage", "findNext", "findPrevious", "useSelectionForFind", "jumpToSelection", "focusCommandBar", "togglePinnedRow"] {
      XCTAssertEqual(standard(id), .both, id)
    }
  }

  func testEverythingElseKeepsGoingToTheWebsiteFirst() {
    for id in ["back", "forward", "reload", "print", "openFile", "zoomIn", "devTools", "searchTabs", "copyUrl"] {
      XCTAssertEqual(standard(id), .website, id)
    }
    for id in ["std:copy:", "std:paste:", "std:cut:", "std:selectAll:", "std:undo:", "std:redo:", "std:hide:"] {
      XCTAssertEqual(ShortcutPrecedence.standard(shortcutId: id, command: nil), .website, id)
    }
  }

  func testTheOldReservedShortcutsStaySolaraWhateverIsChosen() {
    let chosen = ["nextTab": "website", "closeTab": "both", "newWindow": "website", "std:quit:": "website", "std:closeWindow:": "both", "tabSwitcher:forward": "website"]
    for (id, command) in [("nextTab", "nextTab"), ("closeTab", "closeTab"), ("newWindow", "newWindow"), ("tabSwitcher:forward", "tabSwitcher")] {
      XCTAssertTrue(ShortcutPrecedence.isFixed(shortcutId: id, command: command), id)
      XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: id, command: command, chosen: chosen), .solara, id)
    }
    for id in ["std:quit:", "std:closeWindow:"] {
      XCTAssertTrue(ShortcutPrecedence.isFixed(shortcutId: id, command: nil), id)
      XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: id, command: nil, chosen: chosen), .solara, id)
    }
    XCTAssertFalse(ShortcutPrecedence.isFixed(shortcutId: "nextProfile", command: "nextProfile"))
    XCTAssertFalse(ShortcutPrecedence.isFixed(shortcutId: "std:copy:", command: nil))
  }

  func testAChoiceOverridesTheStandard() {
    let chosen = ["nextProfile": "website", "findInPage": "solara", "back": "both"]
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "nextProfile", command: "nextProfile", chosen: chosen), .website)
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "findInPage", command: "findInPage", chosen: chosen), .solara)
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "back", command: "back", chosen: chosen), .both)
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "previousProfile", command: "previousProfile", chosen: chosen), .solara)
  }

  func testAChoiceIsPerShortcutNotPerCommand() {
    let chosen = ["selectTab:3": "website"]
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "selectTab:3", command: "selectTab", chosen: chosen), .website)
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "selectTab:4", command: "selectTab", chosen: chosen), .solara)
  }

  func testAnUnknownChoiceFallsBackToTheStandard() {
    let chosen = ["nextProfile": "sometimes"]
    XCTAssertEqual(ShortcutPrecedence.resolve(shortcutId: "nextProfile", command: "nextProfile", chosen: chosen), .solara)
  }
}
