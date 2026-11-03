import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct SidebarRenameFieldTests {
  func editing() -> (NSWindow, SidebarRenameField, () -> [String?]) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = SidebarRenameField(initial: "Tab", placeholder: "Tab", font: .systemFont(ofSize: 13), color: .labelColor)
    field.frame = NSRect(x: 10, y: 150, width: 200, height: 20)
    window.contentView?.addSubview(field)
    var done: [String?] = []
    field.onDone = { done.append($0) }
    field.begin()
    field.stringValue = "Renamed"
    return (window, field, { done })
  }

  func press(_ window: NSWindow, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }

  @Test func aClickElsewhereInTheWindowKeepsTheTypedName() {
    let (window, field, done) = editing()
    field.clickedAway(press(window, at: NSPoint(x: 100, y: 40)))
    #expect(done() == ["Renamed"])
    field.clickedAway(press(window, at: NSPoint(x: 100, y: 40)))
    #expect(done() == ["Renamed"])
  }

  @Test func aClickInsideTheFieldKeepsEditing() {
    let (window, field, done) = editing()
    field.clickedAway(press(window, at: NSPoint(x: 50, y: 160)))
    #expect(done().isEmpty)
  }

  @Test func aClickInAnotherWindowLeavesItAlone() {
    let (window, field, done) = editing()
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    field.clickedAway(press(other, at: NSPoint(x: 20, y: 20)))
    #expect(done().isEmpty)
  }
}
