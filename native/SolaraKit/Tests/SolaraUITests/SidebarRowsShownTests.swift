import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRowsShownTests {
  private func state(_ ids: [String], pinned: Set<String> = []) throws -> BrowserState {
    let tabs = ids.map { #""\#($0)":{"id":"\#($0)","windowId":"w","profileId":"p","url":"https://\#($0).example/","title":"\#($0)","pinned":\#(pinned.contains($0))}"# }.joined(separator: ",")
    let order = ids.map { #""\#($0)""# }.joined(separator: ",")
    let json = #"{"windows":{"w":{"id":"w","profileId":"p","tabIds":[\#(order)],"activeTabIds":{"p":"a"}}},"windowOrder":["w"],"tabs":{\#(tabs)}}"#
    return try BrowserState(stateJSON: JSONValue.parse(json).object ?? [:])
  }

  @Test func rowsShownPostsOnlyWhenTheRowsChange() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    defer { window.close() }
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
    window.contentView?.addSubview(sidebar)
    var posts = 0
    let observer = NotificationCenter.default.addObserver(forName: SidebarView.rowsShown, object: sidebar, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let host = SidebarHostState(profileId: "p")
    sidebar.update(state: try state(["a", "b"]), host: host)
    #expect(posts == 0)
    sidebar.update(state: try state(["a", "b"]), host: host)
    #expect(posts == 0)
    sidebar.update(state: try state(["a", "b", "c"]), host: host)
    #expect(posts == 1)
    sidebar.update(state: try state(["a", "c", "b"]), host: host)
    #expect(posts == 2)
    sidebar.update(state: try state(["a", "c", "b"], pinned: ["b"]), host: host)
    #expect(posts == 3)
  }
}
