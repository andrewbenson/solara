import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarClickThroughTests {
  @Test func aClickOnAPassivePartOfARowLandsOnTheRowAndControlsKeepTheirOwn() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    let row = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    host.addSubview(row)
    row.body.frame = row.bounds
    let titleBox = NSView(frame: NSRect(x: 10, y: 4, width: 120, height: 16))
    let inner = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
    titleBox.addSubview(inner)
    let label = NSTextField(labelWithString: "3 min")
    label.frame = NSRect(x: 140, y: 4, width: 40, height: 16)
    let tipped = NSView(frame: NSRect(x: 190, y: 4, width: 16, height: 16))
    tipped.toolTip = "Approved"
    let button = SidebarIconButton(frame: NSRect(x: 220, y: 4, width: 16, height: 16))
    let buttonLabel = NSTextField(labelWithString: "Go")
    let buttonWithLabel = SidebarIconButton(frame: NSRect(x: 250, y: 0, width: 60, height: 24))
    buttonWithLabel.addSubview(buttonLabel)
    buttonLabel.frame = NSRect(x: 10, y: 4, width: 40, height: 16)
    let field = NSTextField(frame: NSRect(x: 320, y: 4, width: 60, height: 16))
    for view in [titleBox, label, tipped, button, buttonWithLabel, field] { row.body.addSubview(view) }
    #expect(row.hitTest(NSPoint(x: 20, y: 10)) === row)
    #expect(row.hitTest(NSPoint(x: 100, y: 10)) === row)
    #expect(row.hitTest(NSPoint(x: 150, y: 10)) === row)
    #expect(row.hitTest(NSPoint(x: 198, y: 10)) === tipped)
    #expect(row.hitTest(NSPoint(x: 228, y: 10)) === button)
    #expect(row.hitTest(NSPoint(x: 270, y: 10)) === buttonLabel)
    #expect(row.hitTest(NSPoint(x: 340, y: 10)) === field)
    #expect(row.hitTest(NSPoint(x: 20, y: 30)) === row)
  }

  @Test func aFolderPanelRowTakesAClickInABackgroundWindow() {
    let row = FolderPanelRow(member: FolderPanelMember(tabId: "t", title: "T", active: false), icon: NSView())
    #expect(row.acceptsFirstMouse(for: nil))
  }
}
