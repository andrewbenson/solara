import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarDockTests {
  @MainActor final class Rig {
    let shell = WindowShellView(windowId: "w")
    let column = FlippedContainerView()
    let dock: SidebarDock
    var watches: [CGFloat?] = []
    var lights: [CGPoint?] = []
    var moving: [Bool] = []
    var peeks: [Bool] = []
    var timers: [() -> Void] = []

    init(_ state: SidebarDockState = SidebarDockState()) {
      shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
      shell.mount(.sidebar, column)
      dock = SidebarDock(shell: shell, state: state)
      dock.reduceMotion = { false }
      dock.column = { [column] in column }
      dock.onWatch = { [unowned self] in self.watches.append($0) }
      dock.onLights = { [unowned self] in self.lights.append($0) }
      dock.onDock = { [unowned self] _, moving in if self.moving.last != moving { self.moving.append(moving) } }
      dock.onPeek = { [unowned self] live, _ in self.peeks.append(live) }
      useManualTimers()
      dock.start()
    }

    func useManualTimers() {
      dock.peek.schedule = { [unowned self] _, run in
        self.timers.append(run)
        return NSObject()
      }
      dock.peek.cancel = { _ in }
    }

    func fireTimers() {
      let pending = timers
      timers = []
      for run in pending { run() }
    }

    func settle() {
      for _ in 0..<240 where dock.moving || dock.sliding { dock.step(by: 1.0 / 60) }
    }

    func set(_ change: (inout SidebarDockState) -> Void) {
      var next = dock.state
      change(&next)
      dock.apply(next)
    }
  }

  @Test(arguments: [false, true], ["left", "right"])
  func openingDeliversTheInitialLightsAfterTheCallbackIsConnected(open: Bool, side: String) {
    var state = SidebarDockState()
    state.open = open
    state.sidebarPosition = side
    let rig = Rig(state)
    #expect(rig.lights.count == 1)
    #expect(rig.lights.first == .some(rig.shell.frames.lights))
    rig.dock.stop()
  }

  @Test func closingSpringsTheDockToZeroAndLeavesTheSidebarAway() {
    let rig = Rig()
    #expect(rig.shell.input.dock == 1)
    rig.set { $0.open = false }
    #expect(rig.dock.moving)
    #expect(rig.moving == [true])
    rig.dock.step(by: 1.0 / 60)
    let mid = rig.shell.input.dock
    #expect(mid > 0 && mid < 1)
    rig.settle()
    #expect(rig.shell.input.dock == 0)
    #expect(rig.shell.input.away)
    #expect(rig.moving.last == false)
    #expect(rig.watches.last == ShellMetrics.edgeStripWidth)
  }

  @Test func reduceMotionJumps() {
    let rig = Rig()
    rig.dock.reduceMotion = { true }
    rig.set { $0.open = false }
    #expect(!rig.dock.moving)
    #expect(rig.shell.input.dock == 0)
    #expect(rig.shell.input.away)
  }

  @Test func theEdgePeeksTheColumnInsideThePanelAndHandsItBack() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    #expect(rig.dock.peek.live)
    #expect(rig.peeks == [true])
    #expect(rig.column.superview === rig.dock.panel.clip)
    #expect(rig.shell.view(in: .sidebar) === rig.dock.panel)
    #expect(rig.shell.input.peeking)
    #expect(!rig.shell.input.away)
    rig.settle()
    #expect(rig.dock.slideValue == 1)
    #expect(rig.dock.panel.frame.minX == ShellMetrics.peekOrigin.x)
    #expect(rig.dock.panel.frame.minY == ShellMetrics.peekOrigin.y)
    #expect(rig.watches.last == ShellMetrics.peekOrigin.x + ShellMetrics.sidebarWidth + ShellMetrics.holdSlack)
    rig.dock.edge(over: false)
    rig.fireTimers()
    rig.settle()
    #expect(!rig.dock.peek.live)
    #expect(rig.shell.view(in: .sidebar) === rig.column)
    #expect(rig.column.superview === rig.shell)
    #expect(rig.dock.panel.superview == nil)
    #expect(rig.shell.input.away)
    #expect(rig.watches.last == ShellMetrics.edgeStripWidth)
  }

  @Test func aHeldPeekStaysUntilTheHoldEnds() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    rig.settle()
    rig.set { $0.held = true }
    rig.dock.edge(over: false)
    rig.fireTimers()
    rig.settle()
    #expect(rig.dock.peek.live)
    rig.set { $0.held = false }
    rig.fireTimers()
    rig.settle()
    #expect(!rig.dock.peek.live)
  }

  @Test func openingWhilePeekingInArcJumpsAndReturnsTheColumn() {
    let rig = Rig(SidebarDockState(arc: true))
    rig.useManualTimers()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    rig.settle()
    rig.set { $0.open = true }
    #expect(!rig.dock.moving)
    #expect(rig.shell.input.dock == 1)
    #expect(rig.shell.view(in: .sidebar) === rig.column)
    #expect(!rig.shell.input.peeking)
    rig.settle()
    #expect(!rig.dock.peek.live)
    #expect(rig.shell.view(in: .sidebar) === rig.column)
  }

  @Test func theNonArcPanelFadesWithTheSlide() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    rig.dock.step(by: 1.0 / 60)
    let alpha = rig.dock.panel.alphaValue
    #expect(alpha > 0 && alpha < 1)
    rig.settle()
    #expect(rig.dock.panel.alphaValue == 1)
  }

  @Test func lightsStayOnTheToolbarCenterLineWhileTheSidebarHides() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    #expect(rig.lights.last == .some(nil))
    rig.set { $0.open = true }
    rig.settle()
    #expect(rig.lights.last == .some(nil))
  }

  @Test func stopHandsTheColumnBackAndStopsWatching() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    rig.dock.stop()
    #expect(rig.shell.view(in: .sidebar) === rig.column)
    #expect(!rig.shell.input.peeking)
    #expect(rig.shell.input.peekSlide == 0)
    #expect(rig.watches.last == .some(nil))
    #expect(rig.lights.last == .some(nil))
  }

  @Test func aColumnTakenAwayMidPeekIsNotHandedBack() {
    let rig = Rig()
    rig.set { $0.open = false }
    rig.settle()
    rig.dock.edge(over: true)
    #expect(rig.column.superview === rig.dock.panel.clip)
    rig.column.removeFromSuperview()
    rig.dock.stop()
    #expect(rig.shell.view(in: .sidebar) == nil)
    #expect(rig.column.superview == nil)
    #expect(!rig.shell.input.peeking)
  }

  @Test func fullScreenNeverWatchesOrPeeks() {
    let rig = Rig()
    rig.set {
      $0.open = false
      $0.fullscreen = true
    }
    rig.settle()
    #expect(rig.dock.watchingHold == nil)
    rig.dock.edge(over: true)
    #expect(!rig.dock.peek.live)
  }
}
