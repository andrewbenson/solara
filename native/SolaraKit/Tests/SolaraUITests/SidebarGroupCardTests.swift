import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarGroupCardTests {
  private func state(_ titles: [String]) -> SidebarGroupCardState {
    let now = Date().timeIntervalSince1970 * 1000
    let rows = titles.enumerated().map { i, title in
      SidebarGroupCardState.Row(id: "t\(i)", title: title, url: "https://\(title.lowercased()).example/", usedAt: now - Double(i) * 120_000, favicon: nil, icon: nil, profileId: "p")
    }
    return SidebarGroupCardState(groupId: "g", rows: rows, anchor: [8, 100, 184, 34], windowHeight: 800, dark: true, theme: [:])
  }

  @Test func theHeightCountsUpToSevenRows() {
    let m = SidebarGroupCardMetrics.self
    #expect(m.height(0) == 44 + m.separator + 8 + 44)
    #expect(m.height(3) == 44 + m.separator + 8 + 3 * 44)
    #expect(m.height(20) == m.height(7))
  }

  @Test func itOpensRightOfTheRowAndStaysInTheWindow() {
    let m = SidebarGroupCardMetrics.self
    #expect(m.origin(anchor: CGRect(x: 8, y: 100, width: 184, height: 34), height: 200, windowHeight: 800) == CGPoint(x: 200, y: 94))
    #expect(m.origin(anchor: CGRect(x: 8, y: 700, width: 184, height: 34), height: 200, windowHeight: 800).y == 592)
  }

  @Test func searchRanksLikeRN() {
    let rows = state(["Mail", "Calendar", "Maps"]).rows
    #expect(SidebarGroupCardMetrics.matching("", rows).map(\.id) == ["t0", "t1", "t2"])
    #expect(SidebarGroupCardMetrics.matching("cal", rows).map(\.id) == ["t1"])
    #expect(SidebarGroupCardMetrics.matching("ma", rows).map(\.id).first == "t0")
  }

  @Test func agoReadsLikeRN() {
    let now = 1_000_000_000_000.0
    #expect(SidebarGroupCardMetrics.ago(now - 30_000, now: now) == "just now")
    #expect(SidebarGroupCardMetrics.ago(now - 60_000, now: now) == "1 minute ago")
    #expect(SidebarGroupCardMetrics.ago(now - 3 * 3_600_000, now: now) == "3 hours ago")
    #expect(SidebarGroupCardMetrics.ago(now - 86_400_000, now: now) == "yesterday")
    #expect(SidebarGroupCardMetrics.ago(now - 14 * 86_400_000, now: now) == "2 weeks ago")
  }

  @Test func arrowsMoveTheSelectionAndReturnChoosesIt() {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    var events: [SidebarGroupCardEvent] = []
    card.onEvent = { events.append($0) }
    card.set(state(["A", "B", "C"]))
    card.layoutSubtreeIfNeeded()
    let text = NSTextView()
    let field = NSTextField()
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(events == [.choose("t2")])
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(events.last == .close)
  }

  @Test func endingHoverRestoresTheOriginalFieldAndSelection() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let origin = NSTextField(string: "Original text selection")
    origin.frame = NSRect(x: 20, y: 20, width: 250, height: 24)
    root.addSubview(origin)
    #expect(window.makeFirstResponder(origin))
    let editor = try #require(origin.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 4, length: 7))
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    root.addSubview(card)
    card.set(state(["A", "B"]))
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    card.mouseEntered(with: event)
    let search = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    #expect((window.firstResponder as? NSTextView)?.delegate === search)
    card.live = false
    #expect((window.firstResponder as? NSTextView)?.delegate === origin)
    #expect((origin.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 4, length: 7))
  }

  @Test func detachingReturnsFocusWithoutReclaimingItFromAnotherControl() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let origin = NSTextField(string: "Origin")
    let next = NSTextField(string: "Next")
    origin.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
    next.frame = NSRect(x: 20, y: 60, width: 200, height: 24)
    root.addSubview(origin)
    root.addSubview(next)
    #expect(window.makeFirstResponder(origin))
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    root.addSubview(card)
    card.set(state(["A"]))
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    card.mouseEntered(with: event)
    card.removeFromSuperview()
    #expect((window.firstResponder as? NSTextView)?.delegate === origin)
    root.addSubview(card)
    card.live = true
    card.mouseEntered(with: event)
    #expect(window.makeFirstResponder(next))
    card.live = false
    #expect((window.firstResponder as? NSTextView)?.delegate === next)
    card.removeFromSuperview()
  }

  @Test func groupRowsExposeButtonsAndTheSearchHasAnAccessibleLabel() throws {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    card.set(state(["First", "Second"]))
    let field = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    #expect(field.accessibilityLabel() == "Search Tabs")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let rows = descendants(card).filter { $0.accessibilityRole() == .button }
    #expect(rows.map { $0.accessibilityLabel() } == ["First", "Second"])
    var events: [SidebarGroupCardEvent] = []
    card.onEvent = { events.append($0) }
    #expect(rows[1].accessibilityPerformPress())
    #expect(events == [.choose("t1")])
    #expect(rows.allSatisfy { $0.acceptsFirstResponder && !$0.acceptsFirstMouse(for: nil) })
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    rows[0].keyDown(with: space)
    #expect(events.last == .choose("t0"))
  }

  @Test func tabTraversesNativeRowsAndEscapeRestoresTheSavedFieldSelection() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let origin = NSTextField(string: "Saved selection")
    origin.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
    root.addSubview(origin)
    #expect(window.makeFirstResponder(origin))
    (origin.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 4))
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    root.addSubview(card)
    card.set(state(["A", "B"]))
    var events: [SidebarGroupCardEvent] = []
    card.onEvent = { events.append($0) }
    let pointer = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    card.mouseEntered(with: pointer)
    let search = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    let editor = try #require(search.currentEditor())
    let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    editor.keyDown(with: tab)
    let first = try #require(window.firstResponder as? GroupCardRowView)
    #expect(first.accessibilityLabel() == "A")
    first.keyDown(with: tab)
    let second = try #require(window.firstResponder as? GroupCardRowView)
    #expect(second.accessibilityLabel() == "B")
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    second.keyDown(with: escape)
    #expect(events.contains(.close))
    #expect((origin.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 4))
    #expect((window.firstResponder as? NSTextView)?.delegate === origin)
    events.removeAll()
    card.mouseEntered(with: pointer)
    let nextEditor = try #require(search.currentEditor())
    nextEditor.keyDown(with: tab)
    let chosen = try #require(window.firstResponder as? GroupCardRowView)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    chosen.keyDown(with: enter)
    #expect(events.contains(.choose("t0")))
    #expect(events.contains(.focusPage))
  }

  @Test func leavingARowReleasesTheHoverHoldAndAllowsSearchToFocusAgain() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let outside = NSTextField(string: "Outside")
    outside.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
    root.addSubview(outside)
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    root.addSubview(card)
    card.set(state(["A", "B"]))
    var events: [SidebarGroupCardEvent] = []
    card.onEvent = { events.append($0) }
    let pointer = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    card.mouseEntered(with: pointer)
    let search = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    search.stringValue = "A"
    card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let row = try #require(descendants(card).first { $0 is GroupCardRowView })
    #expect(window.makeFirstResponder(row))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(events.last == .hold(true))
    #expect(window.makeFirstResponder(outside))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(events.last == .hold(false))
    card.mouseEntered(with: pointer)
    #expect((window.firstResponder as? NSTextView)?.delegate === search)
    card.live = false
  }
}
