import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarViewTests {
  @Test func unpinnedPopupUsesThePanesSyntheticAnchor() {
    let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 300, height: 42))
    var state = ToolbarWebKitPillTests.state(extensions: "")
    state.inSplit = true
    toolbar.update(state)
    toolbar.layoutSubtreeIfNeeded()
    #expect(toolbar.extensionAnchor("unpinned", fallback: false) == nil)
    let anchor = toolbar.extensionAnchor("unpinned", fallback: true)
    #expect(anchor?.maxX == 292)
    #expect(anchor?.size == CGSize(width: 28, height: 28))
  }

  @Test func exactAnchorWinsOverOverflow() {
    let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 300, height: 42))
    toolbar.update(ToolbarWebKitPillTests.state(extensions:
      #"{"id":"ext:a","icon":"puzzlepiece","anchor":"a"},{"id":"ext-overflow","icon":"ellipsis","anchor":"*"}"#))
    toolbar.layoutSubtreeIfNeeded()
    let exact = toolbar.extensionAnchor("a", fallback: true)
    let overflow = toolbar.extensionAnchor("other", fallback: true)
    #expect(exact != nil && overflow != nil && exact != overflow)
    #expect(toolbar.extensionAnchor("a", fallback: false) == exact)
  }

  @Test func reboundButtonsActOnTheNewTabAndRetiredButtonsDoNothing() throws {
    let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 300, height: 42))
    var state = ToolbarWebKitPillTests.state(extensions: #"{"id":"ext:a","icon":"puzzlepiece","anchor":"a"}"#)
    var targets: [String] = []
    toolbar.onClick = { [weak toolbar] _ in targets.append(toolbar?.state?.tabId ?? "") }
    toolbar.update(state)
    let first = try #require(toolbar.subviews.flatMap(\.subviews).compactMap { $0 as? ToolbarButtonView }.first)
    toolbar.clearPresentation()
    state.tabId = "replacement"
    toolbar.update(state)
    let replacement = try #require(toolbar.subviews.flatMap(\.subviews).compactMap { $0 as? ToolbarButtonView }.first)
    let click = ToolbarClick(id: "ext:a", kind: .menu)
    first.onClick(click)
    replacement.onClick(click)
    #expect(first !== replacement)
    #expect(targets == ["replacement"])
  }

}
