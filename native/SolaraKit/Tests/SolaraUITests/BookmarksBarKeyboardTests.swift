import AppKit
import Testing
@testable import SolaraUI

struct BookmarksBarKeyboardTests {
  private let controls = ["first", "folder", "overflow", "other"]

  @Test func unmodifiedKeysMapToTheirBarActions() {
    let cases: [(String, BookmarksBarKeyboard.Action)] = [
      ("Left", .previous), ("Right", .next), ("Home", .first), ("End", .last),
      ("Return", .press([])), ("Space", .press([])), ("Escape", .page),
      ("ContextMenu", .contextMenu), ("Tab", .unhandled), ("Unknown", .unhandled),
    ]
    for (key, expected) in cases {
      #expect(BookmarksBarKeyboard.action(key: key, modifiers: [], kind: .link) == expected)
    }
  }

  @Test func downOpensOnlyControlsWithBookmarkMenus() {
    for kind in [BookmarksBarKeyboard.Kind.folder, .overflow, .other] {
      #expect(BookmarksBarKeyboard.action(key: "Down", modifiers: [], kind: kind) == .menu)
    }
    for kind in [BookmarksBarKeyboard.Kind.link, .importButton] {
      #expect(BookmarksBarKeyboard.action(key: "Down", modifiers: [], kind: kind) == .unhandled)
    }
  }

  @Test func commandReturnUsesTheCommandClickFlagsOnlyForLinks() {
    #expect(BookmarksBarKeyboard.action(key: "Return", modifiers: .command, kind: .link) == .press(.command))
    for kind in [BookmarksBarKeyboard.Kind.folder, .overflow, .other, .importButton] {
      #expect(BookmarksBarKeyboard.action(key: "Return", modifiers: .command, kind: kind) == .unhandled)
    }
    #expect(BookmarksBarKeyboard.action(key: "Return", modifiers: [.command, .shift], kind: .link) == .unhandled)
    #expect(BookmarksBarKeyboard.action(key: "Space", modifiers: .command, kind: .link) == .unhandled)
  }

  @Test func shiftF10OpensContextMenusWithoutSwallowingOtherShortcuts() {
    #expect(BookmarksBarKeyboard.action(key: "F10", modifiers: .shift, kind: .link) == .contextMenu)
    #expect(BookmarksBarKeyboard.action(key: "F10", modifiers: [], kind: .folder) == .unhandled)
    #expect(BookmarksBarKeyboard.action(key: "F10", modifiers: [.shift, .command], kind: .link) == .unhandled)
    for key in ["Left", "Right", "Home", "End", "Down", "Space", "Return", "Escape", "ContextMenu"] {
      #expect(BookmarksBarKeyboard.action(key: key, modifiers: .option, kind: .folder) == .unhandled)
      #expect(BookmarksBarKeyboard.action(key: key, modifiers: .control, kind: .link) == .unhandled)
    }
  }

  @Test func hardwareFlagsDoNotChangeKeyboardMeaning() {
    #expect(BookmarksBarKeyboard.action(key: "Right", modifiers: [.numericPad, .function], kind: .link) == .next)
    #expect(BookmarksBarKeyboard.action(key: "Return", modifiers: [.capsLock, .command], kind: .link) == .press(.command))
    #expect(BookmarksBarKeyboard.action(key: "F10", modifiers: [.shift, .function], kind: .folder) == .contextMenu)
  }

  @Test func arrowsTraverseVisibleItemsThenOverflowAndOtherWithoutWrapping() {
    #expect(BookmarksBarKeyboard.destination(for: .next, focusedId: "folder", controlIds: controls) == "overflow")
    #expect(BookmarksBarKeyboard.destination(for: .next, focusedId: "overflow", controlIds: controls) == "other")
    #expect(BookmarksBarKeyboard.destination(for: .previous, focusedId: "other", controlIds: controls) == "overflow")
    #expect(BookmarksBarKeyboard.destination(for: .previous, focusedId: "overflow", controlIds: controls) == "folder")
    #expect(BookmarksBarKeyboard.destination(for: .previous, focusedId: "first", controlIds: controls) == "first")
    #expect(BookmarksBarKeyboard.destination(for: .next, focusedId: "other", controlIds: controls) == "other")
  }

  @Test func homeAndEndJumpToTheEdgesAndAnEmptyBarHasNoDestination() {
    #expect(BookmarksBarKeyboard.destination(for: .first, focusedId: "folder", controlIds: controls) == "first")
    #expect(BookmarksBarKeyboard.destination(for: .last, focusedId: "folder", controlIds: controls) == "other")
    #expect(BookmarksBarKeyboard.destination(for: .next, focusedId: "missing", controlIds: controls) == nil)
    #expect(BookmarksBarKeyboard.destination(for: .first, focusedId: "folder", controlIds: []) == nil)
    #expect(BookmarksBarKeyboard.destination(for: .page, focusedId: "folder", controlIds: controls) == nil)
  }

  @Test func fullKeyboardAccessAndVisibilityBothGateKeyViews() {
    #expect(BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: true, visible: true))
    #expect(!BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: false, visible: true))
    #expect(!BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: true, visible: false))
    #expect(!BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: false, visible: false))
  }

  @Test func snapshotRepairKeepsStableIdsDespiteInsertionAndReordering() {
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "folder", previousIds: controls, controlIds: ["new", "other", "folder", "overflow"]) == "folder")
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: nil, previousIds: controls, controlIds: controls) == nil)
  }

  @Test func removedOrOverflowedItemsRepairToTheNearestRemainingPosition() {
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "folder", previousIds: controls, controlIds: ["first", "overflow", "other"]) == "overflow")
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "other", previousIds: controls, controlIds: ["first", "folder"]) == "folder")
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "first", previousIds: controls, controlIds: ["overflow", "other"]) == "overflow")
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "folder", previousIds: controls, controlIds: []) == nil)
    #expect(BookmarksBarKeyboard.repairedFocus(focusedId: "missing", previousIds: controls, controlIds: controls) == nil)
  }
}
