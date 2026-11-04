import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarRailPeekTests {
  private func hiddenRail() -> SidebarDockTests.Rig {
    let window = BrowserWindow(id: "w1", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    let settings = Settings.defaults.merging(["sidebarWidth": 260, "sidebarIconsOnly": true])
    let width = SidebarRail.effectiveWidth(window, settings)
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
    #expect(rig.dock.panel.convert(rig.dock.panel.bounds, to: rig.shell) == CGRect(x: 0, y: 47, width: 42, height: 753))
    #expect(rig.column.frame.width == 42)
    #expect(rig.dock.watchingHold == 42 + ShellMetrics.holdSlack)
    #expect(rig.lights.last == ShellMetrics.railLightsCenter)
    #expect(rig.shell.frames.page.minX == 42)
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
    #expect(rig.column.frame.width == 42)
    #expect(rig.shell.frames.card.minX == 0)
    #expect(rig.dock.state.width == 42)
    #expect(rig.lights.last == ShellMetrics.railLightsCenter)
    #expect(rig.shell.frames.page.minX == 42)
  }

  @Test func dockingAndUndockingNeverMoveRailLightsOutOfTheToolbar() {
    let rig = hiddenRail()
    defer { rig.dock.stop() }
    rig.set { $0.open = true }
    for _ in 0..<60 {
      rig.dock.step(by: 1.0 / 60)
      #expect(rig.lights.last == ShellMetrics.railLightsCenter)
    }
    rig.set { $0.open = false }
    for _ in 0..<60 {
      rig.dock.step(by: 1.0 / 60)
      #expect(rig.lights.last == ShellMetrics.railLightsCenter)
    }
    #expect(rig.shell.frames.page.minX == 7)
    #expect(rig.shell.input.away)
  }
}
