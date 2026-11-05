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

  @Test func buttonsExposeTitlesAndFolderSemanticsAndSendCurrentProfile() throws {
    let view = view()
    let items = [BookmarksBarItem(id: "a", kind: .url, title: "Example", url: "https://example.test/"), BookmarksBarItem(id: "b", kind: .folder, title: "Work")]
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    view.update(snapshot(items))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view).map { $0.accessibilityLabel() } == ["Example", "Work, folder"])
    #expect(buttons(view)[0].accessibilityPerformPress())
    #expect(events.last?.0 == "press")
    #expect(events.last?.1["id"] as? String == "a")
    #expect(events.last?.1["profileId"] as? String == "p")
    #expect(events.last?.1["middle"] as? Bool == false)
    #expect(events.last?.1["ctrlKey"] as? Bool == false)
    view.update(snapshot(items, profileId: "next"))
    view.layoutSubtreeIfNeeded()
    #expect(buttons(view)[1].accessibilityPerformPress())
    #expect(events.last?.1["profileId"] as? String == "next")
    #expect(events.last?.1["id"] as? String == "b")
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
    #expect(buttons(view).map { $0.accessibilityLabel() } == ["More bookmarks", "Other Bookmarks, folder"])
    #expect(buttons(view)[0].accessibilityPerformPress())
    #expect(events.last?.0 == "overflowPress")
    #expect(events.last?.1["ids"] as? [String] == ["0", "1", "2", "3", "4"])
    #expect(buttons(view)[1].accessibilityPerformPress())
    #expect(events.last?.0 == "otherPress")
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
    let other = try #require(buttons(view).first { $0.accessibilityLabel() == "Other Bookmarks, folder" })
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    other.rightMouseDown(with: event)
    #expect(events.last?.0 == "contextMenu")
    #expect(events.last?.1["id"] == nil)
    #expect(events.last?.1["profileId"] as? String == "p")
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
    #expect(events.last?.0 == "contextMenu")
    #expect(events.last?.1["id"] == nil)
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

  private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 12), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    guard type == .otherMouseDown || type == .otherMouseUp else { return event }
    let cg = try #require(event.cgEvent)
    cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    return try #require(NSEvent(cgEvent: cg))
  }
}
