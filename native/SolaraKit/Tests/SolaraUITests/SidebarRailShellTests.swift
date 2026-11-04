import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarRailShellTests {
  @Test func theRailSharesTheCardsRoundedClipAndLeavesTheToolbarAboveIt() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.update { $0.sidebarWidth = 42 }
    let sidebar = FlippedContainerView()
    shell.mount(.sidebar, sidebar)
    shell.layoutSubtreeIfNeeded()
    #expect(sidebar.superview === shell.cardClip)
    #expect(sidebar.convert(sidebar.bounds, to: shell) == CGRect(x: 0, y: 47, width: 42, height: 753))
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 42, y: 47, width: 1151, height: 746))
    #expect(shell.cardClip.layer?.masksToBounds == true)
    #expect(shell.cardClip.layer?.cornerRadius == 0)
    #expect(shell.cardPage.layer?.cornerRadius == ShellMetrics.cardRadius)
    #expect(shell.cardPage.layer?.borderWidth == 0)
    #expect(shell.cardClip.layer?.backgroundColor.map { $0.alpha } ?? 0 == 0)
  }

  #if DEBUG
  @Test func thePointerOverTheRailInsideTheCardIsTheSidebars() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.update { $0.sidebarWidth = 42 }
    shell.mount(.sidebar, NSView())
    shell.mount(.splitChrome, FlippedContainerView())
    shell.mount(.peek, FlippedContainerView())
    shell.layoutSubtreeIfNeeded()
    #expect(shell.slotUnderPointer(at: NSPoint(x: 28, y: 100)) == .sidebar)
    shell.devNotePointer(NSPoint(x: 28, y: 100))
    #expect(shell.pointerSlot == .sidebar)
  }

  @Test func aViewInsideTheRailBelongsToTheSidebarSlotNotTheCard() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let column = NSView()
    let row = NSView()
    column.addSubview(row)
    shell.mount(.sidebar, column)
    shell.layoutSubtreeIfNeeded()
    #expect(shell.slot(containing: row) == .sidebar)
    shell.update { $0.sidebarWidth = 42 }
    shell.layoutSubtreeIfNeeded()
    #expect(column.superview === shell.cardClip)
    #expect(shell.slot(containing: row) == .sidebar)
    #expect(shell.slot(containing: shell.cardPage) == .card)
  }
  #endif

  @Test func thePageOverrideCannotCoverTheRail() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.update { $0.sidebarWidth = 42 }
    shell.cardPageFrame = CGRect(origin: .zero, size: shell.frames.card.size)
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == CGRect(x: 42, y: 47, width: 1151, height: 746))
  }

  @Test func snapAnimationsUseTheSameProgressForWidthAndLightsInBothDirections() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    for target: CGFloat in [42, 190] {
      let width = shell.input.sidebarWidth
      let rail = shell.railFraction
      let lights = shell.frames.lights ?? ShellMetrics.lightsCenter
      shell.setSidebarWidth(target, animated: true)
      #expect(shell.input.sidebarWidth == width)
      #expect(shell.railFraction == rail)
      #expect((shell.frames.lights ?? ShellMetrics.lightsCenter) == lights)
      var previous = lights
      for _ in 0..<120 where shell.widthMoving {
        shell.stepWidth(by: 1.0 / 120)
        let point = shell.frames.lights ?? ShellMetrics.lightsCenter
        #expect(abs(point.x - previous.x) < 3)
        #expect(abs(point.y - previous.y) < 3)
        previous = point
      }
      #expect(!shell.widthMoving)
      #expect(shell.input.sidebarWidth == target)
      #expect(shell.railFraction == (target == 42 ? 1 : 0))
    }
  }

  @Test func movingTheRailInsideTheCardKeepsTheResizeGestureAlive() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let shell = WindowShellView(windowId: "w")
    window.contentView = shell
    let sidebar = SidebarChromeView()
    shell.mount(.sidebar, sidebar)
    let handle = sidebar.resize
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 188, y: 400), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    handle.mouseDown(with: event)
    #expect(handle.dragging)
    shell.setSidebarWidth(42, animated: true)
    for _ in 0..<30 { shell.stepWidth(by: 1.0 / 60) }
    #expect(sidebar.superview === shell.cardClip)
    #expect(handle.dragging)
    shell.setSidebarWidth(190, animated: true)
    for _ in 0..<30 { shell.stepWidth(by: 1.0 / 60) }
    #expect(sidebar.superview === shell)
    #expect(handle.dragging)
  }

  private func toolbar() throws -> ToolbarView {
    let json = #"""
      {"tabId":"a","height":41,"bare":false,"focused":true,"accent":"#3478F6",
       "palette":{"text":"#000000","secondary":"#00000080","icon":"#000000D4","iconDisabled":"#0000006E","hover":"#0000000D","pressed":"#0000001A","pill":"#0000000A","divider":"#0000001A"},
       "geometry":{"back":21,"forward":57,"reload":92,"urlLeft":110,"urlRight":8},
       "left":[{"id":"back","icon":"chevron.left"}],"url":null,"right":[],"rightInset":8,"hairline":false}
      """#
    let toolbar = ToolbarView()
    toolbar.update(try #require(ToolbarState.decode(json)))
    return toolbar
  }

  @Test func theNativeToolbarSpansTheCardAndItsFirstButtonClearsTheLights() throws {
    let shell = WindowShellView(windowId: "w", reactOnTop: true)
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let react = NSView()
    shell.mount(.react, react)
    let owner = FlippedContainerView(frame: CGRect(x: 190, y: 6, width: 1003, height: 41))
    shell.addSubview(owner)
    let toolbar = try toolbar()
    owner.addSubview(toolbar)
    shell.registerToolbar(toolbar, owner: owner)
    shell.update { $0.sidebarWidth = 42 }
    shell.layoutSubtreeIfNeeded()
    #expect(toolbar.isDescendant(of: shell.overlay))
    #expect(toolbar.superview?.layer?.masksToBounds == true)
    #expect(toolbar.superview?.layer?.cornerRadius == 0)
    #expect(toolbar.frame == CGRect(x: 0, y: 0, width: 1200, height: 47))
    let button = try #require(toolbar.subviews.flatMap(\.subviews).compactMap { $0 as? ToolbarButtonView }.first)
    #expect(button.frame.minX == 97)
    let point = button.convert(CGPoint(x: 15, y: 15), to: shell.superview)
    #expect(shell.hitTest(point) === button)
    shell.setModal("dialog", shown: true)
    #expect(toolbar.isHiddenOrHasHiddenAncestor)
    #expect(shell.hitTest(point) !== button)
    shell.setModal("dialog", shown: false)
    #expect(shell.hitTest(point) === button)
    shell.update { $0.sidebarWidth = 190 }
    shell.layoutSubtreeIfNeeded()
    #expect(toolbar.superview === owner)
    #expect(button.frame.minX == 6)
  }

  @Test func aRemovedToolbarOwnerCannotLeaveItsToolbarOverThePage() throws {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.update { $0.sidebarWidth = 42 }
    var owner: NSView? = FlippedContainerView()
    shell.addSubview(try #require(owner))
    let toolbar = try toolbar()
    owner?.addSubview(toolbar)
    shell.registerToolbar(toolbar, owner: try #require(owner))
    #expect(toolbar.isDescendant(of: shell.overlay))
    owner?.removeFromSuperview()
    owner = nil
    shell.layout()
    #expect(!toolbar.isDescendant(of: shell))
    #expect(toolbar.windowShell == nil)
  }

  @Test func fullSidebarKeepsItsParentAndPageFrame() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let sidebar = FlippedContainerView()
    shell.mount(.sidebar, sidebar)
    shell.layoutSubtreeIfNeeded()
    #expect(sidebar.superview === shell)
    #expect(sidebar.frame == CGRect(x: 0, y: 0, width: 190, height: 800))
    #expect(shell.cardPage.frame == CGRect(x: 0, y: 41, width: 1003, height: 746))
  }
}
