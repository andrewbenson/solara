import AppKit
import Testing
@testable import SolaraUI

struct BookmarksBarNavigationTests {
  @MainActor private func bar(width: CGFloat = 400) -> BookmarksBarView {
    let view = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    view.frame = CGRect(x: 0, y: 0, width: width, height: 30)
    view.update(snapshot())
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func snapshot() -> BookmarksBarSnapshot {
    let items = [
      BookmarksBarItem(id: "a", kind: .url, title: "", url: "https://example.test/path"),
      BookmarksBarItem(id: "f", kind: .folder, title: "Folder", children: [BookmarksBarItem(id: "child", kind: .url, title: "Child", url: "https://child.test")]),
    ] + (0..<20).map { BookmarksBarItem(id: "long-\($0)", kind: .url, title: "Long bookmark \($0)", url: "https://overflow.test/\($0)") }
    return BookmarksBarSnapshot(profileId: "p", items: items, otherId: "other-root", hasOther: true, hideBookmarksBarImport: false, theme: [:])
  }

  @Test @MainActor func keysUseExistingPressCallbacksAndMenus() {
    let view = bar(width: 650)
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let moved = view.devKey(key: "Right", id: "a", flags: [], fullKeyboardAccess: true)
    #expect(moved["focusedId"] as? String == "f")
    _ = view.devKey(key: "Return", id: "a", flags: [], fullKeyboardAccess: true)
    #expect(events.last?.0 == "press")
    #expect(events.last?.1["id"] as? String == "a")
    #expect(events.last?.1["metaKey"] as? Bool == false)
    _ = view.devKey(key: "Return", id: "a", flags: .command, fullKeyboardAccess: true)
    #expect(events.last?.1["metaKey"] as? Bool == true)
    let down = view.devKey(key: "Down", id: "f", flags: [], fullKeyboardAccess: true)
    let menu = down["menu"] as? [String: Any]
    #expect(menu?["trigger"] as? String == "folder")
    #expect(menu?["highlightedId"] as? String == "open:child")
    #expect(view.devMenu(trigger: "open", id: nil).first?["title"] as? String == "Child")
    #expect(events.count == 2)
    let context = view.devKey(key: "F10", id: "a", flags: .shift, fullKeyboardAccess: true)
    #expect((context["menu"] as? [String: Any])?["trigger"] as? String == "item")
    let escaped = view.devKey(key: "Escape", id: "f", flags: [], fullKeyboardAccess: true)
    #expect(escaped["focusedId"] is NSNull)
  }

  @Test @MainActor func simulatedAccessGateRejectsKeysAndRemovesEveryKeyView() {
    let view = bar()
    var pressed = false
    view.onAction = { _, _ in pressed = true }
    let result = view.devKey(key: "Return", id: "a", flags: [], fullKeyboardAccess: false)
    #expect(result["accepted"] as? Bool == false)
    #expect(result["focusedId"] is NSNull)
    #expect(result["keyViews"] as? [String] == [])
    #expect(!pressed)
  }

  @Test @MainActor func accessibilityReportsActualButtonsInVisualOrder() throws {
    let view = bar(width: 650)
    let tree = view.devAccessibility()
    #expect(tree["role"] as? String == "AXToolbar")
    #expect(tree["label"] as? String == "Bookmarks bar")
    let children = try #require(tree["children"] as? [[String: Any]])
    #expect(children.prefix(2).compactMap { $0["id"] as? String } == ["a", "f"])
    #expect(children.suffix(2).compactMap { $0["id"] as? String } == ["overflow", "other"])
    #expect(children.allSatisfy { $0["role"] as? String == "AXButton" })
    #expect(children[0]["label"] as? String == "example.test")
    #expect(children[0]["help"] as? String == "https://example.test/path")
    #expect(children[1]["label"] as? String == "Folder")
    #expect(children[1]["roleDescription"] as? String == "folder")
    #expect(children[1]["actions"] as? [String] == ["AXPress", "AXShowMenu"])
    #expect(children.last?["label"] as? String == "Other Bookmarks")
    let buttons = view.accessibilityChildren()?.compactMap { $0 as? NSView } ?? []
    #expect(buttons.count == children.count)
    #expect(buttons.map { $0.accessibilityLabel() ?? "" } == children.compactMap { $0["label"] as? String })
  }

  @Test @MainActor func importAccessibilityUsesVisibleTitleAndTooltip() throws {
    let view = bar()
    var empty = snapshot()
    empty.items = []
    view.update(empty)
    view.layoutSubtreeIfNeeded()
    let children = try #require(view.devAccessibility()["children"] as? [[String: Any]])
    #expect(children.compactMap { $0["id"] as? String } == ["import", "other"])
    #expect(children.first?["label"] as? String == "Import bookmarks")
    #expect(children.first?["help"] as? String == "Add bookmarks from another browser")
  }

  @MainActor private func window() -> (NSWindow, BookmarksBarView, BookmarksBarExternalKeyView, BookmarksBarExternalKeyView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 200))
    window.contentView = root
    let before = BookmarksBarExternalKeyView()
    before.frame = CGRect(x: 0, y: 150, width: 100, height: 24)
    root.addSubview(before)
    let view = bar(width: 650)
    view.frame.origin = CGPoint(x: 0, y: 90)
    root.addSubview(view)
    let after = BookmarksBarExternalKeyView()
    after.frame = CGRect(x: 0, y: 20, width: 100, height: 24)
    root.addSubview(after)
    view.layoutSubtreeIfNeeded()
    return (window, view, before, after)
  }

  @MainActor private func controls(_ view: BookmarksBarView, access: Bool) -> [BookmarksBarButton] {
    let buttons = view.subviews.compactMap { $0 as? BookmarksBarButton }
    for button in buttons { button.devFullKeyboardAccess = access }
    return (view.accessibilityChildren() ?? []).compactMap { $0 as? BookmarksBarButton }
  }

  @MainActor private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }

  @Test @MainActor func appKitGateTabTraversalAndEscapeUseRealResponders() throws {
    let (window, view, before, after) = window()
    defer { window.close() }
    let buttons = controls(view, access: true)
    let first = try #require(buttons.first)
    let last = try #require(buttons.last)
    #expect(window.firstResponder === window)
    #expect(buttons.allSatisfy { $0.acceptsFirstResponder && $0.canBecomeKeyView })
    #expect(window.makeFirstResponder(before))
    window.selectNextKeyView(before)
    #expect(window.firstResponder === first)
    for (button, next) in zip(buttons, buttons.dropFirst()) {
      button.keyDown(with: try key(48, in: window))
      #expect(window.firstResponder === next)
    }
    last.keyDown(with: try key(48, in: window))
    #expect(window.firstResponder === after)
    window.selectPreviousKeyView(after)
    #expect(window.firstResponder === last)
    #expect(window.makeFirstResponder(first))
    first.keyDown(with: try key(48, flags: .shift, in: window))
    #expect(window.firstResponder === before)
    var pageFocus = 0
    view.onFocusPage = { pageFocus += 1 }
    #expect(window.makeFirstResponder(first))
    first.keyDown(with: try key(53, in: window))
    #expect(window.firstResponder === window)
    #expect(pageFocus == 1)
    _ = controls(view, access: false)
    #expect(buttons.allSatisfy { !$0.acceptsFirstResponder && !$0.canBecomeKeyView })
    window.makeFirstResponder(first)
    #expect(window.firstResponder !== first)
  }

  @Test @MainActor func actualKeysRepairFocusByIdentityAndLeaveAnEmptyBar() throws {
    let (window, view, before, after) = window()
    defer { window.close() }
    var buttons = controls(view, access: true)
    let first = try #require(buttons.first)
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let folder = try #require(buttons.first { $0.controlId == "f" })
    #expect(window.makeFirstResponder(first))
    #expect(window.performKeyEquivalent(with: try key(36, flags: .command, in: window)))
    #expect(events.last?.0 == "press")
    #expect(events.last?.1["metaKey"] as? Bool == true)
    first.keyDown(with: try key(124, in: window))
    #expect(window.firstResponder === folder)
    var reordered = snapshot()
    reordered.items.swapAt(0, 1)
    view.update(reordered)
    buttons = controls(view, access: true)
    #expect((window.firstResponder as? BookmarksBarButton)?.controlId == "f")
    reordered.items.removeFirst()
    view.update(reordered)
    #expect((window.firstResponder as? BookmarksBarButton)?.controlId == "a")
    view.setFrameSize(CGSize(width: 170, height: 30))
    view.layoutSubtreeIfNeeded()
    #expect((window.firstResponder as? BookmarksBarButton)?.controlId == "overflow")
    var pageFocus = 0
    view.onFocusPage = { pageFocus += 1 }
    var empty = reordered
    empty.items = []
    empty.hasOther = false
    empty.hideBookmarksBarImport = true
    view.update(empty)
    #expect(window.firstResponder === window)
    #expect(pageFocus == 1)
    #expect(window.makeFirstResponder(before))
    window.selectNextKeyView(before)
    #expect(window.firstResponder === after)
    window.selectPreviousKeyView(after)
    #expect(window.firstResponder === before)
    #expect(view.accessibilityHelp() == "For quick access, place your bookmarks here on the bookmarks bar.")
    view.update(snapshot())
    #expect(window.firstResponder === before)
  }

  @Test @MainActor func detachingTheBarPreservesAnUpdatedExternalKeyLoop() {
    for empty in [false, true] {
      let (window, view, before, after) = window()
      defer { window.close() }
      _ = controls(view, access: true)
      if empty {
        var state = snapshot()
        state.items = []
        state.hasOther = false
        state.hideBookmarksBarImport = true
        view.update(state)
      }
      let inserted = BookmarksBarExternalKeyView()
      inserted.frame = CGRect(x: 0, y: 40, width: 100, height: 24)
      window.contentView?.addSubview(inserted)
      before.nextKeyView = inserted
      inserted.nextKeyView = after
      view.removeFromSuperview()
      #expect(before.nextKeyView === inserted)
      #expect(inserted.nextKeyView === after)
    }
  }

  @Test @MainActor func appKitContextMenuActionUsesTheExistingContextCallback() {
    let button = BookmarksBarButton()
    var contexts = 0
    button.onContext = { contexts += 1 }
    button.showContextMenuForSelection(nil)
    #expect(contexts == 1)
  }

}


@MainActor
private final class BookmarksBarExternalKeyView: NSView {
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
}
