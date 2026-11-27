import Foundation
import Testing
import SolaraModel
@testable import SolaraUI

struct BookmarksBarDropTests {
  private let items = [
    BookmarksBarItem(id: "a", kind: .url, title: "A"),
    BookmarksBarItem(id: "folder", kind: .folder, title: "Folder"),
    BookmarksBarItem(id: "b", kind: .url, title: "B"),
    BookmarksBarItem(id: "hidden", kind: .folder, title: "Hidden"),
  ]
  private var placements: [BookmarksBarLayout.Placement] {
    (0..<3).map { .init(index: $0, frame: CGRect(x: 8 + $0 * 100, y: 3, width: 100, height: 24)) }
  }

  private func target(_ id: String = "a", dx: CGFloat, pointerX: CGFloat = 500, edge: CGFloat? = nil) -> BookmarksBarDropTarget? {
    BookmarksBarDropTarget.resolve(id: id, items: items, visible: placements, deltaX: dx, pointerX: pointerX, sidebarEdge: edge)
  }

  @Test @MainActor func staleOrdersCannotReorderOrAppendLinks() {
    let document: JSONValue = ["nodes": [
      "bar": ["kind": "folder", "children": ["a", "folder", "b"]],
      "folder": ["kind": "folder", "parentId": "bar", "children": []],
      "a": ["kind": "url", "parentId": "bar"],
    ]]
    let plan = BookmarksBarEdits(profile: "p", bar: "bar", other: "other", document: document)
    #expect(plan.move("a", into: nil, index: 1, listed: ["a", "b", "folder"]).isEmpty)
    #expect(plan.move("a", into: "folder", index: nil, listed: ["a", "folder", "b"]).last?.method == "moveBookmark")
    let links = [BookmarksBarDroppedLink(url: "https://example.test", title: "")]
    let edits = plan.drop(links, parent: "bar", index: 2, listed: ["a", "folder", "b"])
    #expect(edits.map(\.method) == ["expectChildren", "addBookmark"])
    #expect(plan.drop(links, parent: "bar", index: 2, listed: ["a", "b", "folder"]).isEmpty)
    #expect(plan.drop(links, parent: "another-window", index: nil, listed: nil).isEmpty)
  }

  @Test @MainActor func tabDropsRequireTheOriginalSourceWindowAndTheTargetProfile() {
    #expect(BookmarksBarEdits.acceptsTab(sourceWindow: "first", targetProfile: "work", tabWindow: "first", tabProfile: "work"))
    #expect(!BookmarksBarEdits.acceptsTab(sourceWindow: "first", targetProfile: "work", tabWindow: "second", tabProfile: "work"))
    #expect(!BookmarksBarEdits.acceptsTab(sourceWindow: "first", targetProfile: "work", tabWindow: "first", tabProfile: "home"))
  }

  @Test func folderTargetUsesOnlyTheStrictMiddleHalf() {
    #expect(target(dx: 75) == .reorder(index: 0, insertionX: 106))
    #expect(target(dx: 75.1) == .folder("folder"))
    #expect(target(dx: 100) == .folder("folder"))
    #expect(target(dx: 124.9) == .folder("folder"))
    #expect(target(dx: 125) == .reorder(index: 1, insertionX: 206))
  }

  @Test func movingRightAdjustsTheIndexExactlyOnce() {
    #expect(target(dx: 180) == .reorder(index: 1, insertionX: 206))
    #expect(target(dx: 300) == .reorder(index: 3, insertionX: 310))
    #expect(target("b", dx: -240) == .reorder(index: 0, insertionX: 6))
  }

  @Test func hiddenFoldersAndTheDraggedFolderAreNotFolderTargets() {
    #expect(target(dx: 300) == .reorder(index: 3, insertionX: 310))
    #expect(target("folder", dx: 0) == .reorder(index: 1, insertionX: 206))
  }

  @Test func sidebarUsesPointerPositionOnlyForFoldersAndHasPrecedence() {
    #expect(target("folder", dx: 0, pointerX: 199, edge: 200) == .sidebar)
    #expect(target("folder", dx: 0, pointerX: 200, edge: 200) == .reorder(index: 1, insertionX: 206))
    #expect(target("folder", dx: 0, pointerX: -1) != .sidebar)
    #expect(target(dx: 100, pointerX: 1, edge: 200) == .folder("folder"))
  }

  @Test func invalidOrHiddenSourcesAndNonfiniteMotionHaveNoTarget() {
    #expect(target("missing", dx: 0) == nil)
    #expect(target("hidden", dx: 0) == nil)
    #expect(target(dx: .infinity) == nil)
    #expect(target(dx: .nan) == nil)
  }
}
