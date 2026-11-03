import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarRailPeekTests {
  private func hiddenRail() -> SidebarDockTests.Rig {
    let settings = Settings.defaults.merging(["sidebarWidth": 260, "sidebarIconsOnly": true])
    let width = SidebarRail.effectiveWidth(settings)
    let rig = SidebarDockTests.Rig(SidebarDockState(open: false, width: width))
    rig.shell.update { $0.sidebarWidth = CGFloat(width) }
    return rig
  }

  @Test func aHiddenRailPeeksAtItsEffectiveWidth() {
    let rig = hiddenRail()
    defer { rig.dock.stop() }
    rig.dock.edge(over: true)
    rig.settle()
    rig.shell.layoutSubtreeIfNeeded()
    #expect(rig.dock.peek.live)
    #expect(rig.shell.input.peeking)
    #expect(rig.dock.panel.frame == CGRect(x: 5, y: 5, width: 84, height: 790))
    #expect(rig.column.frame.width == 84)
    #expect(rig.dock.watchingHold == ShellMetrics.peekOrigin.x + 84 + ShellMetrics.holdSlack)
  }

  @Test func dockingThePeekReturnsTheColumnAtRailWidth() {
    let rig = hiddenRail()
    defer { rig.dock.stop() }
    rig.dock.edge(over: true)
    rig.settle()
    rig.set { $0.open = true }
    rig.settle()
    rig.shell.layoutSubtreeIfNeeded()
    #expect(!rig.shell.input.peeking)
    #expect(rig.shell.view(in: .sidebar) === rig.column)
    #expect(rig.column.frame.width == 84)
    #expect(rig.shell.frames.card.minX == 84)
    #expect(rig.dock.state.width == 84)
  }
}
