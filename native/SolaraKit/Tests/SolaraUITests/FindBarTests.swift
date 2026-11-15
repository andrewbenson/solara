import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized) struct FindBarTests {
  private func state(query: String = "needle", count: Int? = 3, replace: Bool = false, focus: Int = 0) throws -> FindBarState {
    let data = try JSONSerialization.data(withJSONObject: [
      "query": query, "count": count.map { $0 as Any } ?? NSNull(), "active": 2, "replace": replace,
      "note": NSNull(), "noteError": false, "focusRequest": focus, "previousTooltip": "Previous (⇧⌘G)",
      "nextTooltip": "Next (⌘G)", "dark": false, "theme": [:] as [String: String],
    ])
    return try JSONDecoder().decode(FindBarState.self, from: data)
  }

  private func view(_ state: FindBarState) -> FindBarView {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let view = FindBarView(frame: NSRect(x: 0, y: 0, width: 340, height: state.replace ? 79 : 40))
    view.update(state)
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func panel() -> FindBarTestPanel {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let panel = FindBarTestPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    return panel
  }

  private func otherField(in panel: NSPanel) throws -> NSTextField {
    let other = NSTextField(frame: NSRect(x: 0, y: 90, width: 200, height: 24))
    panel.contentView?.addSubview(other)
    #expect(panel.makeFirstResponder(other))
    return other
  }

  private func field(_ view: FindBarView, _ label: String) throws -> NSTextField {
    try #require(view.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
  }

  private func labels(_ view: FindBarView) -> [String] {
    view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.isHidden }.map(\.stringValue)
  }

  private func nextMainTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test func matchCountsAndNoResultsUseNativeLabels() throws {
    let bar = view(try state())
    #expect(labels(bar) == ["2", "3"])
    let buttons = bar.subviews.compactMap { $0 as? ToolbarButtonView }
    #expect(buttons.map { $0.accessibilityLabel() } == ["Previous (⇧⌘G)", "Next (⌘G)", "Done (Esc)"])
    #expect(buttons.allSatisfy { $0.state.enabled != false })
    bar.update(try state(count: 0))
    #expect(labels(bar) == ["No results"])
    #expect(buttons.filter { $0.state.enabled == false }.map { $0.state.id } == ["previous", "next"])
    bar.update(try state(count: nil))
    #expect(labels(bar).isEmpty)
    bar.update(try state(query: "", count: 0))
    #expect(labels(bar).isEmpty)
  }

  @Test func nativeFieldsKeepQueryReplacementAndEscapeActionsDistinct() throws {
    let bar = view(try state(replace: true))
    #expect(bar.height == 79)
    let query = try field(bar, "Find on Page")
    let replacement = try field(bar, "Replace")
    #expect(!replacement.isHidden)
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    query.stringValue = "changed"
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: query))
    replacement.stringValue = "replacement"
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: replacement))
    let editor = NSTextView()
    #expect(bar.control(query, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(bar.control(replacement, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(bar.control(replacement, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(events == [.query("changed"), .replacement("replacement"), .step(backwards: false), .replace(all: false), .close])
    events.removeAll()
    editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!bar.control(query, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(!bar.control(query, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(events.isEmpty)
  }

  @Test func countUpdatesDoNotRetakeTheResponderOrActivateAWindow() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    let bar = view(try state())
    panel.contentView?.addSubview(bar)
    let other = NSTextField(frame: NSRect(x: 0, y: 90, width: 200, height: 24))
    panel.contentView?.addSubview(other)
    let keyWindow = NSApp.keyWindow
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    await nextMainTurn()
    let query = try field(bar, "Find on Page")
    let editor = try #require(query.currentEditor())
    #expect(panel.firstResponder === editor)
    #expect(editor.selectedRange == NSRange(location: 0, length: 6))
    #expect(events == [.focused])
    #expect(NSApp.keyWindow === keyWindow)
    #expect(panel.makeFirstResponder(other))
    let responder = panel.firstResponder
    bar.update(try state(count: 9, focus: 1))
    await nextMainTurn()
    #expect(panel.firstResponder === responder)
    #expect(events == [.focused])
    #expect(NSApp.keyWindow === keyWindow)
  }

  @Test func detachedFocusRequestCanRetryAfterAttachment() async throws {
    let panel = panel()
    defer { panel.close() }
    let bar = view(try state())
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    await nextMainTurn()
    #expect(events.isEmpty)
    panel.contentView?.addSubview(bar)
    await nextMainTurn()
    let query = try field(bar, "Find on Page")
    #expect(query.currentEditor() != nil)
    #expect(events == [.focused])
  }

  @Test func hidingTheHostCancelsQueuedFocus() async throws {
    let panel = panel()
    defer { panel.close() }
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
    panel.contentView?.addSubview(host)
    let bar = view(try state())
    host.addSubview(bar)
    _ = try otherField(in: panel)
    let responder = panel.firstResponder
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    host.isHidden = true
    await nextMainTurn()
    #expect(panel.firstResponder === responder)
    #expect(events.isEmpty)
  }

  @Test func clearingTheRequestCancelsQueuedFocus() async throws {
    let panel = panel()
    defer { panel.close() }
    let bar = view(try state())
    panel.contentView?.addSubview(bar)
    _ = try otherField(in: panel)
    let responder = panel.firstResponder
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    bar.update(try state(focus: 0))
    await nextMainTurn()
    #expect(panel.firstResponder === responder)
    #expect(events.isEmpty)
  }

  @Test func newerQueuedFocusSupersedesTheOlderRequest() async throws {
    let panel = panel()
    defer { panel.close() }
    let bar = view(try state())
    panel.contentView?.addSubview(bar)
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    bar.update(try state(focus: 2))
    await nextMainTurn()
    let query = try field(bar, "Find on Page")
    #expect(query.currentEditor() != nil)
    #expect(events == [.focused])
  }

  @Test func refusedFocusDoesNotClaimTheResponder() async throws {
    let panel = panel()
    defer { panel.close() }
    let bar = view(try state())
    panel.contentView?.addSubview(bar)
    _ = try otherField(in: panel)
    let responder = panel.firstResponder
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    panel.refusesFirstResponder = true
    bar.update(try state(focus: 1))
    await nextMainTurn()
    #expect(panel.firstResponder === responder)
    #expect(events.isEmpty)
    panel.refusesFirstResponder = false
    bar.update(try state(focus: 1))
    await nextMainTurn()
    let query = try field(bar, "Find on Page")
    #expect(query.currentEditor() != nil)
    #expect(events == [.focused])
  }

  @Test func reusingACancelledRequestDoesNotRunItsOlderCallback() async throws {
    let panel = panel()
    defer { panel.close() }
    let bar = view(try state())
    panel.contentView?.addSubview(bar)
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    bar.update(try state(focus: 1))
    bar.update(try state(focus: 0))
    bar.update(try state(focus: 1))
    await nextMainTurn()
    #expect(events == [.focused])
  }

  @Test func accessibilityPressRoutesFindAndReplacementActions() throws {
    let bar = view(try state(replace: true))
    var events: [FindBarEvent] = []
    bar.onEvent = { events.append($0) }
    let buttons = bar.subviews.compactMap { $0 as? ToolbarButtonView }
    for button in buttons {
      #expect(button.isAccessibilityEnabled())
      #expect(button.accessibilityPerformPress())
    }
    let replaceButtons = bar.subviews.compactMap { $0 as? FindTextButton }
    for button in replaceButtons {
      #expect(button.isAccessibilityEnabled())
      #expect(button.accessibilityPerformPress())
    }
    #expect(events == [.step(backwards: true), .step(backwards: false), .close, .replace(all: false), .replace(all: true)])
    events.removeAll()
    bar.update(try state(query: "", count: 0, replace: true))
    for button in buttons where button.state.id != "done" {
      #expect(!button.isAccessibilityEnabled())
      #expect(!button.accessibilityPerformPress())
    }
    for button in replaceButtons {
      #expect(!button.isAccessibilityEnabled())
      #expect(!button.accessibilityPerformPress())
    }
    #expect(events.isEmpty)
    bar.update(try state(replace: true))
    bar.isHidden = true
    for button in buttons { #expect(!button.accessibilityPerformPress()) }
    for button in replaceButtons { #expect(!button.accessibilityPerformPress()) }
    #expect(events.isEmpty)
  }

  @Test func removingTheViewReleasesPendingFocusWork() async throws {
    let panel = panel()
    defer { panel.close() }
    weak var released: FindBarView?
    var events: [FindBarEvent] = []
    try autoreleasepool {
      let bar = view(try state())
      released = bar
      panel.contentView?.addSubview(bar)
      bar.onEvent = { events.append($0) }
      bar.update(try state(focus: 1))
      bar.removeFromSuperview()
    }
    #expect(released == nil)
    await nextMainTurn()
    #expect(released == nil)
    #expect(events.isEmpty)
  }
}

@MainActor
private final class FindBarTestPanel: NSPanel {
  var refusesFirstResponder = false

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if refusesFirstResponder { return false }
    return super.makeFirstResponder(responder)
  }
}
