import AppKit
import SolaraEngine
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct BookmarkCatalogPageTests {
  @Test func largeFolderOnlyRealizesRowsNearTheViewport() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = largeFolder()
    let host = NSHostingView(rootView: BookmarksPageView(model: model, favicons: nil))
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    defer { panel.close() }
    for _ in 0..<5 {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.ids.count == 3000)
    #expect(!model.rowFrames.isEmpty)
    #expect(model.rowFrames.count < 100)
  }

  @Test func draggingSelectedRowsKeepsVisibleOrderAndExcludesHiddenRows() {
    let model = largeFolder()
    model.selected = ["b2999", "hidden", "b1", "b0"]
    model.beginDrag("b1")
    #expect(model.dragging == ["b0", "b1", "b2999"])
    model.beginDrag("b2")
    #expect(model.dragging == ["b2"])
    model.selected = model.ids
    model.beginDrag("b2999")
    #expect(model.dragging == model.ids)
  }

  @Test func draggingIgnoresFramesOutsideTheCurrentListing() {
    let model = largeFolder()
    model.rowFrames = ["hidden": CGRect(x: 0, y: 0, width: 500, height: 36), "b2": CGRect(x: 0, y: 36, width: 500, height: 36)]
    model.beginDrag("b1")
    #expect(model.dropFor(CGPoint(x: 5, y: 5)) == nil)
    #expect(model.dropFor(CGPoint(x: 5, y: 38)) == .at(parentId: "bar", index: 2))
    #expect(model.dropFor(CGPoint(x: 5, y: 70)) == .at(parentId: "bar", index: 3))
  }

  @Test(arguments: [false, true])
  func dragGestureKeepsTheMovingRowAliveWhileTheDropIndicatorChanges(afterRestore: Bool) async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = largeFolder(5)
    let host = NSHostingView(rootView: BookmarksPageView(model: model, favicons: nil))
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    panel.alphaValue = 0
    panel.orderBack(nil)
    defer { panel.close() }
    for _ in 0..<5 {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    if afterRestore {
      let saved = model.nodes
      model.nodes = model.nodes.filter { ["bar", "other", "b4"].contains($0.key) }
      model.nodes["bar"]?.children = ["b4"]
      for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
      model.nodes = saved
      for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    let from = try #require(model.rowFrames["b0"])
    let to = try #require(model.rowFrames["b2"])
    var events: [BookmarksPageEvent] = []
    model.onEvent = { events.append($0) }
    var dragStates: [[String]] = []
    let start = CGPoint(x: from.minX + 120, y: 700 - from.midY)
    let end = CGPoint(x: to.minX + 120, y: 700 - (to.minY + to.height * 0.8))
    for step in 0...13 {
      let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 13 ? .leftMouseUp : .leftMouseDragged
      let fraction = CGFloat(min(step, 12)) / 12
      let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
      let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(step) * 0.016, windowNumber: panel.windowNumber, context: nil, eventNumber: step, clickCount: 1, pressure: step == 13 ? 0 : 1))
      DispatchQueue.main.asyncAfter(deadline: .now() + (step == 0 ? 0 : 0.15 + Double(step) * 0.016)) {
        dragStates.append(model.dragging)
        panel.sendEvent(event)
        dragStates.append(model.dragging)
      }
    }
    try await Task.sleep(for: .milliseconds(700))
    #expect(dragStates.contains(["b0"]))
    #expect(events == [.move(["b0"], .at(parentId: "bar", index: 3), listed: ["b0", "b1", "b2", "b3", "b4"])])
  }

  @Test func movingRowsCannotCoverTheDestinationHitTarget() throws {
    let model = largeFolder(5)
    let destination = CGRect(x: 0, y: 72, width: 500, height: 36)
    model.rowFrames = ["b0": destination, "b2": destination]
    let moving = try #require(model.rowFrames.first?.key)
    model.beginDrag(moving)
    let expectedIndex = moving == "b0" ? 3 : 1
    #expect(model.dropFor(CGPoint(x: 120, y: 100)) == .at(parentId: "bar", index: expectedIndex))
    model.selected = ["b0", "b2"]
    model.beginDrag(moving)
    #expect(model.dropFor(CGPoint(x: 120, y: 100)) == .at(parentId: "bar", index: expectedIndex))
  }

  @Test func multiRowDropPreservesVisibleOrderAcrossTheInsertionPoint() throws {
    let model = largeFolder(6)
    let listed = model.ids
    let moving = ["b0", "b2", "b4"]
    let mutations = try #require(BookmarkPageEdits.moves(moving, to: .at(parentId: "bar", index: 4), listed: listed))
    var result = listed
    for mutation in mutations {
      let id = try #require(mutation.args.first?.string)
      result.removeAll { $0 == id }
      let index = try #require(mutation.args[2].number)
      result.insert(id, at: Int(index))
    }
    #expect(result == ["b1", "b3", "b0", "b2", "b4", "b5"])
  }

  @Test func undoRefusalRenewsExpiryAndOldCompletionsCannotReplaceNewUndo() throws {
    let model = BookmarksPageModel()
    let first = model.recordRemoval(["places": [["id": "a"]]], now: .zero)
    let pending = try #require(model.beginUndo(now: .seconds(7)))
    #expect(model.beginUndo(now: .seconds(7)) == nil)
    model.expireUndo(now: .seconds(8))
    #expect(model.undoCount == 1)
    model.finishUndo(pending, restored: false, now: .seconds(9))
    #expect(model.undoCount == 1)
    let retry = try #require(model.beginUndo(now: .seconds(10)))
    #expect(retry.removed == pending.removed)
    #expect(first != model.recordRemoval(["places": [["id": "b"], ["id": "c"]]], now: .seconds(11)))
    model.finishUndo(retry, restored: true, now: .seconds(12))
    #expect(model.undoCount == 2)
    model.expireUndo(now: .seconds(19))
    #expect(model.undoCount == nil)
  }

  private func largeFolder(_ count: Int = 3000) -> BookmarksPageModel {
    let model = BookmarksPageModel()
    let ids = (0..<count).map { "b\($0)" }
    var nodes = Dictionary(uniqueKeysWithValues: ids.map { id in
      (id, BookmarkNode(id: id, kind: "url", parentId: "bar", title: id, url: "https://fixture.test/\(id)"))
    })
    nodes["bar"] = BookmarkNode(id: "bar", kind: "folder", parentId: nil, title: "Bookmarks Bar", children: ids)
    nodes["other"] = BookmarkNode(id: "other", kind: "folder", parentId: nil, title: "Other Bookmarks", children: [])
    model.apply(snapshot: BookmarkSnapshot(roots: BookmarkRoots(bar: "bar", other: "other"), nodes: nodes, ready: true, revision: 1))
    return model
  }

  @Test func pageReadsTreeAndKeepsSelectionOnlyForLiveNodes() {
    let model = BookmarksPageModel()
    let roots = BookmarkRoots(bar: "bar@default", other: "other@default")
    let bar = BookmarkNode(id: roots.bar, kind: "folder", parentId: nil, title: "Bookmarks Bar", children: ["a"])
    let other = BookmarkNode(id: roots.other, kind: "folder", parentId: nil, title: "Other Bookmarks", children: [])
    let link = BookmarkNode(id: "a", kind: "url", parentId: roots.bar, title: "A", url: "https://a.example/", favicon: "data:image/png;base64,a")
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: bar, other.id: other, link.id: link], ready: false))
    #expect(model.nodes.isEmpty)
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: bar, other.id: other, link.id: link], ready: true, revision: 1))
    #expect(model.folderId == roots.bar)
    #expect(model.ids == ["a"])
    #expect(model.nodes["a"]?.url == "https://a.example/")
    #expect(model.nodes["a"]?.favicon == "data:image/png;base64,a")
    model.selected = ["a"]
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: BookmarkNode(id: bar.id, kind: "folder", parentId: nil, title: bar.title, children: []), other.id: other], ready: true, revision: 2))
    #expect(model.selected.isEmpty)
    #expect(model.ids.isEmpty)
  }
}
