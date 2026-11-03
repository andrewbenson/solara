import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
private final class EscapeDragBridge: SidebarDragBridge {
  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {}
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {}
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) { done(false) }
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) {}
  func escapeCapture(_ on: Bool) {}
  func haptic() {}
  func closeFolderPanel(windowId: String) {}
  func changed(windowId: String) {}
}

@MainActor
@Suite(.serialized) struct SidebarDragEscapeTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"""
      {"profileOrder":["p"],"windowOrder":["w"],
       "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"a"}}},
       "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"},
               "b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"B"}}}
      """#).object ?? [:])
  }

  private func window() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  private func mounted() throws -> (NSWindow, SidebarView) {
    let window = window()
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
    window.contentView?.addSubview(sidebar)
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func dragging(_ sidebar: SidebarView) throws -> SidebarDragController {
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:b"]?.frame)
    controller.begin("t:b", CGPoint(x: source.midX, y: source.midY))
    #expect(controller.active)
    return controller
  }

  private func key(_ code: UInt16, _ chars: String, in window: NSWindow?, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
  }

  private func withBridge(_ run: () throws -> Void) rethrows {
    SidebarDragHub.bridge = EscapeDragBridge()
    defer { SidebarDragHub.bridge = nil }
    try run()
  }

  @Test func escapeIsCapturedOnlyInTheDraggingSidebarsWindowOrWithNoWindow() throws {
    try withBridge {
      let (source, sidebar) = try mounted()
      let other = window()
      defer { source.close(); other.close() }
      #expect(!SidebarDragHub.capturesEscape(in: source))
      let controller = try dragging(sidebar)
      #expect(SidebarDragHub.capturesEscape(in: source))
      #expect(!SidebarDragHub.capturesEscape(in: other))
      #expect(SidebarDragHub.capturesEscape(in: nil))
      controller.end(commit: false)
      #expect(!SidebarDragHub.capturesEscape(in: source))
    }
  }

  @Test func theCaptureCancelsOnEveryPlainEscapeButSwallowsOnlyTheDragWindows() throws {
    try withBridge {
      let (source, sidebar) = try mounted()
      let other = window()
      defer { source.close(); other.close() }
      let controller = try dragging(sidebar)
      defer { controller.end(commit: false) }
      var cancels = 0
      #expect(SidebarDragHub.escapeCaptureSwallows(try key(53, "\u{1b}", in: source)) { cancels += 1 })
      #expect(cancels == 1)
      #expect(!SidebarDragHub.escapeCaptureSwallows(try key(53, "\u{1b}", in: other)) { cancels += 1 })
      #expect(cancels == 2)
      #expect(SidebarDragHub.escapeCaptureSwallows(try key(53, "\u{1b}", in: nil)) { cancels += 1 })
      #expect(cancels == 3)
      #expect(!SidebarDragHub.escapeCaptureSwallows(try key(53, "\u{1b}", in: source, flags: .command)) { cancels += 1 })
      #expect(!SidebarDragHub.escapeCaptureSwallows(try key(0, "a", in: source)) { cancels += 1 })
      #expect(cancels == 3)
    }
  }
}
