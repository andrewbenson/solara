import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct BookmarksBarLinkDropTests {
  private func board(_ values: [(NSPasteboard.PasteboardType, String)]) -> NSPasteboard {
    let board = NSPasteboard.withUniqueName()
    board.declareTypes(values.map(\.0), owner: nil)
    for (type, value) in values { board.setString(value, forType: type) }
    return board
  }

  @Test func urlNamesAndWebURLTitlesArePreserved() {
    let url = "https://example.test/path"
    let named = board([(.URL, url), (BookmarksBarLinkDrop.urlName, "A title")])
    defer { named.releaseGlobally() }
    #expect(BookmarksBarLinkDrop.links(named) == [.init(url: url, title: "A title")])
    let web = NSPasteboard.withUniqueName()
    defer { web.releaseGlobally() }
    web.declareTypes([BookmarksBarLinkDrop.webURLsWithTitles], owner: nil)
    web.setPropertyList([[url, "http://second.test/"], ["First", "Second"]], forType: BookmarksBarLinkDrop.webURLsWithTitles)
    #expect(BookmarksBarLinkDrop.links(web) == [.init(url: url, title: "First"), .init(url: "http://second.test/", title: "Second")])
  }

  @Test func plainTextRequiresACompleteWebURL() {
    let text = board([(.string, "  https://example.test/path\n")])
    defer { text.releaseGlobally() }
    #expect(BookmarksBarLinkDrop.links(text) == [.init(url: "https://example.test/path", title: "")])
    for raw in ["javascript:alert(1)", "data:text/html,hello", "file:///tmp/a", "ftp://example.test", "hello", "example.test", "https://", "https:///path"] {
      let rejected = board([(.string, raw)])
      #expect(BookmarksBarLinkDrop.links(rejected).isEmpty)
      rejected.releaseGlobally()
    }
  }

  @Test func explicitRefusedURLsAndFilesNeverFallBackToText() {
    for type in [NSPasteboard.PasteboardType.URL, .fileURL] {
      let rejected = board([(type, "file:///tmp/a"), (.string, "https://example.test/")])
      #expect(BookmarksBarLinkDrop.links(rejected).isEmpty)
      rejected.releaseGlobally()
    }
  }

  @Test func filesWithWebURLRepresentationsAreRefused() {
    let rejected = board([(.fileURL, "file:///tmp/example.webloc")])
    defer { rejected.releaseGlobally() }
    rejected.addTypes([BookmarksBarLinkDrop.webURLsWithTitles], owner: nil)
    rejected.setPropertyList([["https://example.test/"], ["Example"]], forType: BookmarksBarLinkDrop.webURLsWithTitles)
    #expect(BookmarksBarLinkDrop.links(rejected).isEmpty)
  }

  @Test func tabsResolveCurrentURLsAndTitlesInPayloadOrder() {
    let tabs = ["a": BookmarksBarDroppedLink(url: "https://a.test/", title: "A"), "b": .init(url: "http://b.test/", title: "B"), "file": .init(url: "file:///tmp/a", title: "File")]
    #expect(BookmarksBarLinkDrop.tabs(["b", "missing", "file", "a"], resolve: { tabs[$0] }) == [tabs["b"]!, tabs["a"]!])
  }

  @Test func destinationUsesVisibleMidpointsAndAppendsPastOverflow() {
    let items = [BookmarksBarItem(id: "a", kind: .url, title: "A"), .init(id: "folder", kind: .folder, title: "Folder"), .init(id: "hidden", kind: .folder, title: "Hidden")]
    let visible = [BookmarksBarLayout.Placement(index: 0, frame: CGRect(x: 8, y: 3, width: 100, height: 24)), .init(index: 1, frame: CGRect(x: 108, y: 3, width: 100, height: 24))]
    let snapshot = BookmarksBarSnapshot(profileId: "p", items: items, otherId: "other", hasOther: true, hideBookmarksBarImport: true, theme: [:], barId: "bar")
    func target(_ x: CGFloat, _ folderId: String? = nil) -> BookmarksBarLinkDrop.Destination? {
      BookmarksBarLinkDrop.destination(snapshot: snapshot, visible: visible, x: x, folderId: folderId)
    }
    #expect(target(8)?.index == 0)
    #expect(target(110)?.index == 1)
    #expect(target(133)?.index == 1)
    #expect(target(134)?.parentId == "folder")
    #expect(target(158)?.index == nil)
    #expect(target(183)?.parentId == "bar")
    #expect(target(400)?.index == 3)
    #expect(target(400, "other")?.parentId == "other")
    #expect(target(400, "other")?.index == nil)
    #expect(target(400, "hidden") == nil)
    #expect(target(400, "a") == nil)
    #expect(target(.nan) == nil)
  }
}

@MainActor
struct BookmarksBarLinkDropViewTests {
  private func view() -> BookmarksBarView {
    let view = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    view.frame = CGRect(x: 0, y: 0, width: 500, height: 30)
    view.update(BookmarksBarSnapshot(profileId: "profile", items: [.init(id: "a", kind: .url, title: "A"), .init(id: "folder", kind: .folder, title: "Folder")], otherId: "other", hasOther: true, hideBookmarksBarImport: true, theme: [:], barId: "bar"))
    return view
  }

  @Test func simulatedLinksUseTheSingleHostedEventAndFolderAppendPath() throws {
    #if DEBUG
    let view = view()
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let payload = #"{"items":[{"url":"https://example.test/","title":"Example"}]}"#
    let inserted = view.devDrop(x: 8, folderId: nil, payload: payload)
    #expect(inserted["accepted"] as? Bool == true)
    #expect(inserted["parentId"] as? String == "bar")
    #expect(inserted["index"] as? Int == 0)
    try #require(events.count == 1)
    #expect(events[0].0 == "dropLinks")
    #expect(events[0].1["profileId"] as? String == "profile")
    #expect(events[0].1["items"] as? [[String: String]] == [["url": "https://example.test/", "title": "Example"]])
    for folderId in ["folder", "other"] {
      let result = view.devDrop(x: 8, folderId: folderId, payload: payload)
      #expect(result["accepted"] as? Bool == true)
      #expect(result["parentId"] as? String == folderId)
      #expect(result["index"] is NSNull)
    }
    #expect(events.count == 3)
    #endif
  }

  @Test func tabZoneUsesWindowCoordinatesAndConsumesCopiesWithoutChangingTheSession() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = view()
    view.frame.origin = CGPoint(x: 0, y: 100)
    window.contentView?.addSubview(view)
    view.resolveTab = { id in id == "tab" ? .init(url: "https://tab.test/", title: "Current tab") : .init(url: "file:///tmp/a", title: "Local file") }
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let zone = BookmarksBarTabDropZone(view: view)
    let session = TabDragSession(tabIds: ["tab"], sourceWindow: "source")
    let point = view.convert(CGPoint(x: 8, y: 15), to: nil)
    let windowPoint = CGPoint(x: point.x, y: 200 - point.y)
    #expect(zone.aim(session, at: windowPoint) == .bookmarks)
    #expect(zone.drop(session, .bookmarks))
    zone.clear()
    try #require(events.count == 1)
    #expect(events[0].0 == "dropLinks")
    #expect(events[0].1["items"] as? [[String: String]] == [["url": "https://tab.test/", "title": "Current tab"]])
    #expect(session.tabIds == ["tab"])
    #expect(session.sourceWindow == "source")
    let refused = TabDragSession(tabIds: ["file"], sourceWindow: "source")
    #expect(zone.aim(refused, at: windowPoint) == .bookmarks)
    #expect(!zone.drop(refused, .bookmarks))
    zone.clear()
    #expect(events.count == 1)
    #expect(zone.aim(session, at: CGPoint(x: -1, y: 0)) == nil)
  }

  @Test func tabZoneRejectsCoveringSiblingsAndClearsThePreviousDestination() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let view = view()
    view.frame.origin = CGPoint(x: 0, y: 100)
    content.addSubview(view)
    view.resolveTab = { _ in .init(url: "https://tab.test/", title: "Current tab") }
    var events: [String] = []
    view.onAction = { name, _ in events.append(name) }
    let zone = BookmarksBarTabDropZone(view: view)
    defer { zone.clear() }
    let session = TabDragSession(tabIds: ["tab"], sourceWindow: "source")
    let point = view.convert(CGPoint(x: 8, y: 15), to: nil)
    let windowPoint = CGPoint(x: point.x, y: 200 - point.y)
    #expect(zone.aim(session, at: windowPoint) == .bookmarks)
    let cover = NSView(frame: view.frame)
    content.addSubview(cover, positioned: .above, relativeTo: view)
    let hitPoint = content.superview?.convert(point, from: nil) ?? point
    try #require(content.hitTest(hitPoint) === cover)
    #expect(zone.aim(session, at: windowPoint) == nil)
    #expect(!zone.drop(session, .bookmarks))
    #expect(events.isEmpty)
    cover.isHidden = true
    #expect(zone.aim(session, at: windowPoint) == .bookmarks)
    #expect(zone.drop(session, .bookmarks))
    #expect(events == ["dropLinks"])
  }

  @Test func tabZoneRejectsClippedPointsAndClearsThePreviousDestination() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let clip = NSClipView(frame: CGRect(x: 0, y: 100, width: 250, height: 30))
    window.contentView?.addSubview(clip)
    let view = view()
    clip.documentView = view
    view.resolveTab = { _ in .init(url: "https://tab.test/", title: "Current tab") }
    let zone = BookmarksBarTabDropZone(view: view)
    defer { zone.clear() }
    let session = TabDragSession(tabIds: ["tab"], sourceWindow: "source")
    func aim(_ x: CGFloat) -> TabDropAim? {
      let point = view.convert(CGPoint(x: x, y: 15), to: nil)
      return zone.aim(session, at: CGPoint(x: point.x, y: 200 - point.y))
    }
    #expect(aim(200) == .bookmarks)
    try #require(view.bounds.contains(CGPoint(x: 300, y: 15)))
    try #require(!view.visibleRect.contains(CGPoint(x: 300, y: 15)))
    #expect(aim(300) == nil)
    #expect(!zone.drop(session, .bookmarks))
  }

  @Test func tabZoneHitTestsContentSuperviewCoordinatesAndAcceptsDescendants() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    content.bounds = CGRect(x: 200, y: 40, width: 250, height: 100)
    let view = view()
    view.frame.origin = CGPoint(x: 220, y: 80)
    content.addSubview(view)
    view.layoutSubtreeIfNeeded()
    view.resolveTab = { _ in .init(url: "https://tab.test/", title: "Current tab") }
    let descendant = try #require(view.subviews.compactMap { $0 as? BookmarksBarButton }.first { $0.controlId == "a" })
    let local = view.convert(CGPoint(x: descendant.bounds.midX, y: descendant.bounds.midY), from: descendant)
    let point = view.convert(local, to: nil)
    let parent = try #require(content.superview)
    try #require(content.hitTest(parent.convert(point, from: nil)) === descendant)
    try #require(content.hitTest(content.convert(point, from: nil)) !== descendant)
    let zone = BookmarksBarTabDropZone(view: view)
    defer { zone.clear() }
    let session = TabDragSession(tabIds: ["tab"], sourceWindow: "source")
    #expect(zone.aim(session, at: CGPoint(x: point.x, y: content.bounds.height - point.y)) == .bookmarks)
    #expect(zone.drop(session, .bookmarks))
  }

  @Test func simulatedTabsKeepPayloadOrderAndRefusedInputsEmitNothing() {
    #if DEBUG
    let view = view()
    view.resolveTab = { id in .init(url: "https://\(id).test/", title: id.uppercased()) }
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    let tabs = view.devDrop(x: 8, folderId: nil, payload: #"{"tabIds":["b","a"]}"#)
    #expect(tabs["items"] as? [[String: String]] == [["url": "https://b.test/", "title": "B"], ["url": "https://a.test/", "title": "A"]])
    for payload in [#"{"text":"hello"}"#, #"{"text":"javascript:alert(1)"}"#, #"{"items":[{"url":"file:///tmp/a","title":"File"}]}"#] {
      #expect(view.devDrop(x: 8, folderId: nil, payload: payload)["accepted"] as? Bool == false)
    }
    #expect(view.devDrop(x: -1, folderId: nil, payload: #"{"text":"https://example.test/"}"#)["accepted"] as? Bool == false)
    #expect(view.devDrop(x: 8, folderId: "a", payload: #"{"text":"https://example.test/"}"#)["accepted"] as? Bool == false)
    view.isHidden = true
    #expect(view.devDrop(x: 8, folderId: nil, payload: #"{"text":"https://example.test/"}"#)["accepted"] as? Bool == false)
    #expect(events.count == 1)
    #endif
  }
}
