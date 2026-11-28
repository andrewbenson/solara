import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct WindowShellModalAccessibilityTests {
  @Test func commandPanelAndGuestModalKeepIndependentOwnership() {
    let shell = WindowShellView(windowId: "w")
    shell.setCommandPanelModal(shown: true)
    #expect(shell.modalShown)
    shell.setModal("mainRoot", shown: true)
    shell.setCommandPanelModal(shown: false)
    #expect(shell.modalShown)
    shell.setCommandPanelModal(shown: true)
    shell.setModal("mainRoot", shown: false)
    #expect(shell.modalShown)
    shell.setCommandPanelModal(shown: false)
    #expect(!shell.modalShown)
  }

  @Test func titlebarButtonsLeaveTheWindowTreeDuringAModalAndReturnAfterIt() {
    let shell = WindowShellView(windowId: "w")
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    shell.mount(.react, root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(shell)
    let cells = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0)?.cell }
    let zoomChild = window.standardWindowButton(.zoomButton)?.accessibilityChildren()?.first as? NSObject
    #expect(cells.count == 3)
    #expect(zoomChild != nil)
    #expect(cells.allSatisfy { reachable($0, from: window) })
    #expect(shell.accessibilityReach()["titlebar"] == 3)
    #expect(zoomChild.map { reachable($0, from: window) } == true)
    shell.setModal("mainRoot", shown: true)
    #expect(cells.allSatisfy { !reachable($0, from: window) })
    #expect(shell.accessibilityReach()["titlebar"] == nil)
    #expect(zoomChild.map { !reachable($0, from: window) } == true)
    shell.removeFromSuperview()
    #expect(cells.allSatisfy { reachable($0, from: window) })
    window.contentView?.addSubview(shell)
    #expect(cells.allSatisfy { !reachable($0, from: window) })
    shell.setModal("mainRoot", shown: false)
    #expect(cells.allSatisfy { reachable($0, from: window) })
    #expect(shell.accessibilityReach()["titlebar"] == 3)
    #expect(zoomChild.map { reachable($0, from: window) } == true)
  }

  @Test func aModalKeepsTheOverlayReachableAndHidesTheLayersUnderTheMainRoot() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
    let root = NSView(frame: shell.bounds)
    shell.mount(.react, root)
    let card = NSButton(title: "Card", target: nil, action: nil)
    card.frame = NSRect(x: 200, y: 200, width: 100, height: 30)
    shell.card.addSubview(card)
    let panel = NSButton(title: "Panel", target: nil, action: nil)
    panel.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
    shell.overlay.addSubview(panel)
    let window = NSWindow(contentRect: shell.frame, styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    #expect(reachable(card.cell!, from: window))
    #expect(reachable(panel.cell!, from: window))
    shell.setCommandPanelModal(shown: true)
    #expect(!reachable(card.cell!, from: window))
    #expect(reachable(panel.cell!, from: window))
    #expect(shell.accessibilityReach()["overlay"] != nil)
    #expect(shell.accessibilityReach()["card"] == nil)
    shell.setCommandPanelModal(shown: false)
    #expect(reachable(card.cell!, from: window))
  }

  private func reachable(_ target: NSObject, from window: NSWindow) -> Bool {
    var queue: [Any] = window.accessibilityChildren() ?? []
    while !queue.isEmpty {
      let element = queue.removeFirst()
      if let object = element as? NSObject, object === target { return true }
      queue += (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
    }
    return false
  }
}
