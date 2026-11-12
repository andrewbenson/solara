import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct BookmarksBarViewTests {
  private func snapshot(_ items: [BookmarksBarItem], profileId: String = "p", hasOther: Bool = false, hideImport: Bool = false) -> BookmarksBarSnapshot {
    BookmarksBarSnapshot(profileId: profileId, items: items, otherId: hasOther ? "other" : nil, hasOther: hasOther, hideBookmarksBarImport: hideImport, theme: [:])
  }

  private func view(width: CGFloat = 400) -> BookmarksBarView {
    let view = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    view.frame = CGRect(x: 0, y: 0, width: width, height: 30)
    return view
  }

  private func buttons(_ view: BookmarksBarView) -> [NSView] {
    view.subviews.filter { !$0.isHidden && $0.accessibilityRole() == .button }
  }

  @Test func largeBarMaterializesOnlyVisibleButtonsAndKeepsTheOverflowSuffix() {
    let view = view(width: 800)
    let items = (0..<2500).map { BookmarksBarItem(id: "item-\($0)", kind: .url, title: "Bookmark \($0)", url: "https://fixture.example/\($0)") }
    view.update(snapshot(items))
    view.layoutSubtreeIfNeeded()
    #expect(view.subviews.compactMap { $0 as? BookmarksBarButton }.count < 30)
    let initial = view.benchmarkLayout()
    let visible = initial["visible"] as? Int ?? 0
    #expect(visible > 0)
    #expect(initial["overflowCount"] as? Int == items.count - visible)
    #if DEBUG
    #expect(view.devLayout()["overflowIds"] as? [String] == items.dropFirst(visible).map(\.id))
    #endif
    view.setFrameSize(NSSize(width: 1200, height: 30))
    view.layoutSubtreeIfNeeded()
    let wider = view.benchmarkLayout()
    #expect((wider["visible"] as? Int ?? 0) > visible)
    #expect(view.subviews.compactMap { $0 as? BookmarksBarButton }.count < 30)
    #expect(wider["overflowCount"] as? Int == items.count - (wider["visible"] as? Int ?? 0))
    #if DEBUG
    #expect(view.devLayout()["overflowIds"] as? [String] == items.dropFirst(wider["visible"] as? Int ?? 0).map(\.id))
    #endif
    let fullWidths = items.map { BookmarksBarButton.width(forTitle: $0.displayTitle, iconSize: 14) }
    for width in [CGFloat.zero, fullWidths[0] + 44, fullWidths[0] + 43] {
      view.setFrameSize(NSSize(width: width, height: 30))
      view.layoutSubtreeIfNeeded()
      let expected = BookmarksBarLayout(itemWidths: fullWidths, width: width, hasOther: false)
      let state = view.benchmarkLayout()
      #expect(state["visible"] as? Int == expected.visible.count)
      #expect(state["overflowCount"] as? Int == expected.overflowIndexes.count)
      #expect(state["overflowShown"] as? Bool == (expected.overflowFrame != nil))
      #if DEBUG
      #expect(view.devLayout()["overflowIds"] as? [String] == expected.overflowIndexes.map { items[$0].id })
      #endif
    }
  }

  @Test func buttonsExposeTitlesAndFolderSemanticsAndSendCurrentProfile() throws {
    let view = view()
    let items = [BookmarksBarItem(id: "a", kind: .url, title: "Example", url: "https://example.test/"), BookmarksBarItem(id: "b", kind: .folder, title: "Work")]
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot(items))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view).map { $0.accessibilityLabel() } == ["Example", "Work"])
    #expect(buttons(view)[0].accessibilityPerformPress())
    #expect(events.last?.0 == "press")
    #expect(events.last?.1["id"] as? String == "a")
    #expect(events.last?.1["profileId"] as? String == "p")
    #expect(events.last?.1["middle"] as? Bool == false)
    #expect(events.last?.1["ctrlKey"] as? Bool == false)
    view.update(snapshot(items, profileId: "next"))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view)[1].accessibilityPerformPress())
    #expect(events.count == 1)
    #if DEBUG
    #expect(view.devChoose(trigger: "item", id: "b", choiceId: "rename:b")["accepted"] as? Bool == true)
    #expect(events.last?.1["profileId"] as? String == "next")
    #expect(events.last?.1["id"] as? String == "b")
    #endif
  }

  @Test func emptyImportAndHintRespectTheSnapshotPreference() throws {
    let view = view()
    var event = ""
    view.onAction = { name, _ in event = name }
    view.update(snapshot([]))
    view.layoutSubtreeIfNeeded()
    let button = try #require(buttons(view).first)
    #expect(button.accessibilityLabel() == "Import bookmarks")
    #expect(button.accessibilityPerformPress())
    #expect(event == "importPress")
    view.update(snapshot([], hideImport: true))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view).isEmpty)
    #expect(view.subviews.contains { !$0.isHidden && ($0 as? NSTextField)?.stringValue == "For quick access, place your bookmarks here on the bookmarks bar." })
  }

  @Test func overflowContainsOnlyTheHiddenSuffixAndOtherBookmarksIsSeparate() throws {
    let view = view(width: 300)
    let items = (0..<5).map { BookmarksBarItem(id: "\($0)", kind: .url, title: String(repeating: "W", count: 40), url: "https://example.test/") }
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot(items, hasOther: true))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view).map { $0.accessibilityLabel() } == ["More bookmarks", "Other Bookmarks"])
    #expect(buttons(view)[0].accessibilityPerformPress())
    #expect(events.isEmpty)
    #if DEBUG
    #expect(view.devMenu(trigger: "overflow", id: nil).compactMap { $0["choiceId"] as? String } == ["open:0", "open:1", "open:2", "open:3", "open:4"])
    #endif
    #expect(buttons(view)[1].accessibilityPerformPress())
    #expect(events.isEmpty)
    view.update(snapshot([]))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view).map { $0.accessibilityLabel() } == ["Import bookmarks"])
  }

  @Test func otherBookmarksContextOpensTheBarMenuWithoutAnItemId() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot([], hasOther: true))
    view.layoutSubtreeIfNeeded()
    let other = try #require(buttons(view).first { $0.accessibilityLabel() == "Other Bookmarks" })
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    other.rightMouseDown(with: event)
    #expect(events.isEmpty)
    #if DEBUG
    #expect(view.devMenu(trigger: "blank", id: nil).compactMap { $0["title"] as? String } == ["Add Page…", "Add Folder…", "", "Manage Bookmarks", "Show Bookmarks Bar"])
    #endif
  }

  @Test func controlClickOpensTheItemContextWithoutPressingIt() throws {
    let button = BookmarksBarButton()
    button.frame = CGRect(x: 0, y: 0, width: 100, height: 24)
    var presses = 0
    var contexts = 0
    button.onPress = { _, _ in presses += 1 }
    button.onContext = { contexts += 1 }
    button.mouseDown(with: try mouse(.leftMouseDown, flags: [.control]))
    button.mouseUp(with: try mouse(.leftMouseUp, flags: [.control]))
    #expect(contexts == 1)
    #expect(presses == 0)
  }

  @Test func controlClickOnBlankSpaceOpensTheBarMenu() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot([]))
    view.mouseDown(with: try mouse(.leftMouseDown, flags: [.control]))
    #expect(events.isEmpty)
    #if DEBUG
    #expect(view.devMenu(trigger: "blank", id: nil).first?["choiceId"] as? String == "addPage")
    #endif
  }

  @Test func ordinaryAndMiddleClicksPreserveTheirModifiers() throws {
    let button = BookmarksBarButton()
    button.frame = CGRect(x: 0, y: 0, width: 100, height: 24)
    var presses: [(NSEvent.ModifierFlags, Bool)] = []
    button.onPress = { presses.append(($0, $1)) }
    let flags: NSEvent.ModifierFlags = [.command, .shift, .option]
    button.mouseDown(with: try mouse(.leftMouseDown, flags: flags))
    button.mouseUp(with: try mouse(.leftMouseUp, flags: flags))
    #expect(presses.count == 1)
    #expect(presses.first?.0 == flags)
    #expect(presses.first?.1 == false)
    button.otherMouseDown(with: try mouse(.otherMouseDown, flags: flags))
    button.otherMouseUp(with: try mouse(.otherMouseUp, flags: flags))
    #expect(presses.count == 2)
    #expect(presses.last?.0 == flags)
    #expect(presses.last?.1 == true)
  }

  @Test func voiceOverShowMenuUsesTheItemContextPath() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot([BookmarksBarItem(id: "folder", kind: .folder, title: "Work")]))
    view.layoutSubtreeIfNeeded()
    let button = try #require(buttons(view).first)
    #expect(button.accessibilityPerformShowMenu())
    #expect(events.isEmpty)
    #if DEBUG
    #expect(view.devMenu(trigger: "item", id: "folder").contains { $0["choiceId"] as? String == "rename:folder" })
    #endif
  }

  @Test func draggingBeginsOnlyAfterFourHorizontalPointsAndRestoresTheButton() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot([BookmarksBarItem(id: "a", kind: .url, title: "Example")]))
    view.layoutSubtreeIfNeeded()
    let button = try #require(buttons(view).first as? BookmarksBarButton)
    let home = button.frame
    let point = CGPoint(x: home.midX, y: home.midY)
    button.beginPress(at: point, flags: [])
    button.dragPress(to: CGPoint(x: point.x + 4, y: point.y + 80))
    #expect(button.alphaValue == 1)
    #expect(button.frame == home)
    button.dragPress(to: CGPoint(x: point.x + 4.1, y: point.y + 80))
    #expect(button.alphaValue == 0.85)
    #expect(abs(button.frame.minX - home.minX - 4.1) < 0.001)
    #expect(button.frame.minY == home.minY)
    button.endPress(at: CGPoint(x: point.x + 4.1, y: point.y + 80), flags: [], inside: false)
    #expect(events.count == 1)
    #expect(events.first?.0 == "move")
    #expect(events.first?.1["index"] as? Int == 0)
    #expect(button.alphaValue == 1)
    #expect(button.frame == home)
  }

  @Test func layoutPreservesThePointerOffsetDuringAnActiveDrag() throws {
    let view = view()
    view.update(snapshot([BookmarksBarItem(id: "a", kind: .url, title: "Example")]))
    view.layoutSubtreeIfNeeded()
    let source = try #require(buttons(view).first as? BookmarksBarButton)
    let down = CGPoint(x: source.frame.midX, y: source.frame.midY)
    source.beginPress(at: down, flags: [])
    source.dragPress(to: CGPoint(x: down.x + 50, y: down.y))
    let moved = source.frame
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #expect(source.frame == moved)
    #expect(source.alphaValue == 0.85)
    #if DEBUG
    let visible = try #require(view.devLayout()["visible"] as? [[String: Any]])
    let frame = try #require(visible.first?["frame"] as? [String: CGFloat])
    #expect(frame["x"] == moved.minX)
    #endif
    view.cancelOperation(nil)
  }

  @Test func droppingInTheFolderMiddleHighlightsAndMovesIntoIt() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot([BookmarksBarItem(id: "a", kind: .url, title: "Example"), BookmarksBarItem(id: "f", kind: .folder, title: "Folder")]))
    view.layoutSubtreeIfNeeded()
    let source = try #require(buttons(view).first as? BookmarksBarButton)
    let target = try #require(buttons(view).last as? BookmarksBarButton)
    let down = CGPoint(x: source.frame.midX, y: source.frame.midY)
    let end = CGPoint(x: target.frame.midX, y: target.frame.midY)
    source.beginPress(at: down, flags: [])
    source.dragPress(to: end)
    #expect(target.highlighted)
    source.endPress(at: end, flags: [], inside: true)
    #expect(events.count == 1)
    #expect(events.first?.0 == "move")
    #expect(events.first?.1["id"] as? String == "a")
    #expect(events.first?.1["into"] as? String == "f")
    #expect(!target.highlighted)
  }

  @Test func aFolderPastTheSidebarEdgeUsesTheSidebarEvent() throws {
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    var state = snapshot([BookmarksBarItem(id: "f", kind: .folder, title: "Folder")])
    state.sidebarEdge = 12
    state.theme = ["toolbarHover": "#00FF00", "toolbarPressed": "#FF0000"]
    view.update(state)
    view.layoutSubtreeIfNeeded()
    let source = try #require(buttons(view).first as? BookmarksBarButton)
    let down = CGPoint(x: source.frame.midX, y: source.frame.midY)
    let end = CGPoint(x: 11, y: down.y)
    source.beginPress(at: down, flags: [])
    source.dragPress(to: end)
    #expect(source.highlighted)
    #expect(source.layer?.backgroundColor == toolbarColor("#00FF00")?.cgColor)
    source.endPress(at: end, flags: [], inside: false)
    #expect(events.count == 1)
    #expect(events.first?.0 == "folderToSidebar")
    #expect(events.first?.1["id"] as? String == "f")
  }

  @Test func escapeSnapshotChangesAndResizeCancelWithoutWritingOrClicking() throws {
    for cancellation in 0..<3 {
      let view = view()
      var events: [String] = []
      view.onAction = { name, _ in events.append(name) }
      let state = snapshot([BookmarksBarItem(id: "a", kind: .url, title: "Example")])
      view.update(state)
      view.layoutSubtreeIfNeeded()
      let source = try #require(buttons(view).first as? BookmarksBarButton)
      let home = source.frame
      let down = CGPoint(x: home.midX, y: home.midY)
      let end = CGPoint(x: down.x + 50, y: down.y)
      source.beginPress(at: down, flags: [])
      source.dragPress(to: end)
      switch cancellation {
      case 0: view.cancelOperation(nil)
      case 1: view.update(state)
      default: view.setFrameSize(CGSize(width: 500, height: 30))
      }
      source.endPress(at: end, flags: [], inside: true)
      #expect(events.isEmpty)
      #expect(source.frame == home)
      #expect(source.alphaValue == 1)
      #expect(!source.highlighted)
    }
  }

  #if DEBUG
  @Test func debugInputUsesTheSameButtonPathsAndRejectsHiddenItems() throws {
    let view = view(width: 350)
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let items = (0..<10).map { BookmarksBarItem(id: "\($0)", kind: .url, title: "Example") }
    view.update(snapshot(items, hasOther: true))
    let layout = view.devLayout()
    let visible = try #require(layout["visible"] as? [[String: Any]])
    let first = try #require(visible.first?["id"] as? String)
    #expect(view.devInput(action: "press", id: first, flags: [.command, .shift], x: nil))
    #expect(events.last?.1["metaKey"] as? Bool == true)
    #expect(events.last?.1["shiftKey"] as? Bool == true)
    #expect(!view.devInput(action: "press", id: "9", flags: [], x: nil))
    #expect(view.devInput(action: "overflowPress", id: nil, flags: [], x: nil))
    #expect(events.count == 1)
    #expect(!view.devMenu(trigger: "overflow", id: nil).isEmpty)
    #expect(view.devInput(action: "otherPress", id: nil, flags: [], x: nil))
    #expect(events.count == 1)
    #expect(view.devInput(action: "contextMenu", id: first, flags: [], x: nil))
    #expect(events.count == 1)
    #expect(view.devMenu(trigger: "item", id: first).first?["choiceId"] as? String == "tab:\(first)")
    let count = events.count
    #expect(view.devInput(action: "cancelDrag", id: first, flags: [], x: 200))
    #expect(events.count == count)
  }
  #endif

  private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 12), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    guard type == .otherMouseDown || type == .otherMouseUp else { return event }
    let cg = try #require(event.cgEvent)
    cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    return try #require(NSEvent(cgEvent: cg))
  }
}
