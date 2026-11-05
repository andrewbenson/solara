import AppKit
import Testing
@testable import SolaraUI

struct SidePanelSlotGeometryTests {
  @Test func sidebarReservesAStripBesideTheCard() {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: CGSize(width: 1360, height: 860), dock: 1, sidePanel: 366))
    #expect(frames.card == CGRect(x: 190, y: 6, width: 797, height: 847))
    #expect(frames.sidePanel == CGRect(x: 987, y: 6, width: 366, height: 847))
  }

  @Test func topTabsReserveTheStripBelowTheTabBar() {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: CGSize(width: 1200, height: 800), dock: 1, topTabs: true, sidePanel: 366))
    #expect(frames.card == CGRect(x: 6, y: 42, width: 822, height: 752))
    #expect(frames.sidePanel == CGRect(x: 828, y: 42, width: 366, height: 752))
  }

  @Test func railReservesAFullHeightStrip() {
    let frames = DockedLayoutFrames.of(DockedLayoutInput(size: CGSize(width: 1360, height: 860), dock: 1, sidePanel: 366, railProgress: 1))
    #expect(frames.card == CGRect(x: 0, y: 0, width: 994, height: 860))
    #expect(frames.sidePanel == CGRect(x: 994, y: 0, width: 366, height: 860))
  }

  @Test func fullscreenAndNonpositiveRoomHaveNoSidePanelSlot() {
    let size = CGSize(width: 1200, height: 800)
    let fullscreen = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, fullscreen: true, sidePanel: 366))
    #expect(fullscreen.card == CGRect(origin: .zero, size: size))
    #expect(fullscreen.sidePanel == nil)
    for room: CGFloat in [0, -1] {
      #expect(DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, sidePanel: room)).sidePanel == nil)
    }
  }
}

struct SidePanelSettleEaseTests {
  @Test func outBackMatchesReactNativeAtEndpointsAndOvershoots() {
    let run = TimedRun(from: 0, to: 1, duration: 0.26, ease: .outBack(1.2))
    #expect(run.sample(0).value == 0)
    #expect(abs(run.sample(0.13).value - 1.025) < 1e-12)
    #expect(run.sample(0.2).value > 1)
    #expect(run.sample(0.26).value == 1)
    #expect(run.sample(0.26).done)
    let descending = TimedRun(from: 636, to: 600, duration: 0.26, ease: .outBack(1.2))
    #expect(descending.sample(0.13).value < 600)
    #expect(descending.sample(1).value == 600)
  }

  @Test func rewrittenFormMatchesTheBackEaseAcrossTheCurve() {
    let overshoot = 1.2
    let run = TimedRun(from: 0, to: 1, duration: 1, ease: .outBack(overshoot))
    for step in 0...100 {
      let u = Double(step) / 100
      let t = 1 - u
      let reference = 1 - t * t * ((overshoot + 1) * t - overshoot)
      #expect(abs(run.sample(u).value - reference) < 1e-12, "u = \(u)")
    }
  }
}

@MainActor
struct SidePanelSlotMotionTests {
  @Test func theShellOwnsAndClipsTheSlotAboveTheCard() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    shell.mount(.splitChrome, NSView())
    shell.setSidePanelRoom(366, open: true, animated: false)
    #expect(shell.view(in: .sidePanel) === shell.sidePanelClip)
    #expect(shell.sidePanelClip.layer?.masksToBounds == true)
    #expect(shell.sidePanelClip.frame == shell.frames.sidePanel)
    #expect(shell.subviews.firstIndex(of: shell.sidePanelClip)! == shell.subviews.firstIndex(of: shell.card)! + 1)
    #expect(!shell.sidePanelClip.isHidden)
    shell.setSidePanelRoom(366, open: false, animated: false)
    #expect(shell.sidePanelClip.isHidden)
    #expect(!shell.sidePanelMoving)
  }

  #if DEBUG
  @Test func openAndCloseSettleWithoutAnIdleDisplayLink() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var settled: [CGFloat] = []
    shell.onSidePanelSettle = { settled.append($0) }
    shell.setSidePanelRoom(366, open: true, animated: true)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      #expect(shell.sidePanelMoving)
      shell.devStepSidePanel(by: 0.1)
      #expect(shell.input.sidePanel > 0 && shell.input.sidePanel < 366)
    }
    shell.devStepSidePanel(by: 0.2)
    #expect(shell.input.sidePanel == 366)
    #expect(!shell.devSidePanelLinkRunning)
    shell.setSidePanelRoom(366, open: false, animated: true)
    shell.devStepSidePanel(by: 0.2)
    #expect(shell.input.sidePanel == 0)
    #expect(!shell.devSidePanelLinkRunning)
    #expect(settled == [366, 0])
  }

  @Test func aWidthChangeWhileOpenAppliesAtOnceAndStopsTheRun() {
    let shell = WindowShellView(windowId: "w")
    shell.setSidePanelRoom(366, open: true, animated: true)
    shell.devStepSidePanel(by: 0.05)
    shell.setSidePanelRoom(426, open: true, animated: true)
    #expect(shell.input.sidePanel == 426)
    #expect(!shell.sidePanelMoving)
    #expect(!shell.devSidePanelLinkRunning)
  }

  @Test func detachingStopsTheRunAndSettlesAtItsTarget() {
    let shell = WindowShellView(windowId: "w")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(shell)
    shell.setSidePanelRoom(366, open: true, animated: true)
    shell.removeFromSuperview()
    #expect(!shell.sidePanelMoving)
    #expect(!shell.devSidePanelLinkRunning)
    #expect(shell.input.sidePanel == 366)
  }
  #endif
}
