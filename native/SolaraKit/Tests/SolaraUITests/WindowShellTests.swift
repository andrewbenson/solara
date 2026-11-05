import AppKit
import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

struct WindowShellMotionTests {
  let dia: [(Double, Double)] = [
    (0.0337, 0.303), (0.0629, 0.616), (0.0837, 0.805), (0.1212, 0.968), (0.1379, 1.011), (0.1629, 1.011), (0.1837, 1.003),
    (0.0263, 0.246), (0.0596, 0.524), (0.0805, 0.8), (0.1055, 0.951), (0.1305, 1.008), (0.1555, 1.011), (0.1805, 1.003),
    (0.0324, 0.316), (0.0657, 0.586), (0.0949, 0.846), (0.1032, 0.973), (0.1365, 1.011), (0.1532, 1.011), (0.1782, 1.005),
  ]

  @Test func springFollowsDiasMeasuredMotion() {
    let rms = (dia.reduce(0) { $0 + pow(DockMotion.springAt($1.0) - $1.1, 2) } / Double(dia.count)).squareRoot()
    #expect(rms < 0.04)
    #expect(DockMotion.springAt(0.1) > 0.88)
    let peak = (0..<60).map { DockMotion.springAt(Double($0) / 120) }.max()!
    #expect(peak > 1.005 && peak < 1.03)
    #expect(abs(DockMotion.springAt(0.3) - 1) < 0.003)
  }

  @Test func reactNativesSpringParametersAreTheSameSpring() {
    let spring = ShellSpring.dock
    let omega = spring.stiffness.squareRoot()
    #expect(abs(omega - 2 * .pi / 0.215) < 1e-9)
    #expect(abs(spring.dampingCoefficient / (2 * omega) - 0.79) < 1e-9)
  }

  @Test func springRunMatchesTheAnalyticCurveAndRestsOnReactNativesFrame() {
    let run = SpringRun(from: 0, to: 1)
    for t in stride(from: 0.0, through: 0.3, by: 0.01) {
      #expect(abs(run.sample(t).value - DockMotion.springAt(t)) < 1e-9)
    }
    #expect(framesToRest(SpringRun(from: 0, to: 1), hz: 60) == 20)
    #expect(framesToRest(SpringRun(from: 1, to: 0), hz: 60) == 20)
    #expect(framesToRest(SpringRun(from: 0, to: 1), hz: 120) == 40)
    #expect(SpringRun(from: 0, to: 1).sample(1).value == 1)
  }

  @Test func aSpringStartedWithVelocityKeepsIt() {
    let first = SpringRun(from: 0, to: 1)
    let mid = first.sample(0.05)
    let back = SpringRun(from: mid.value, to: 0, initialVelocity: mid.velocity)
    let step = back.sample(1.0 / 120).value
    #expect(step > mid.value, "still moving the way it was going on the first frame")
    #expect(back.sample(2).value == 0)
  }

  @Test func arcsHideIsAHundredMillisecondEaseOut() {
    let hide = TimedRun(from: 1, to: 0, duration: DockMotion.arcHideMs / 1000, ease: .outCubic)
    #expect(hide.sample(0).value == 1)
    #expect(abs(hide.sample(0.05).value - (1 - DockMotion.easeOutCubic(0.5))) < 1e-12)
    #expect(hide.sample(0.1).done)
    #expect(DockMotion.easeInOutCubic(0) == 0)
    #expect(DockMotion.easeInOutCubic(0.5) == 0.5)
    #expect(DockMotion.easeInOutCubic(1) == 1)
    let peak = (0..<60).map { DockMotion.springAt(Double($0) / 120, .arcPeek) }.max()!
    #expect(peak > 1.01 && peak < 1.03)
  }

  @Test func trafficLightsGoWithTheSidebar() {
    #expect(DockMotion.lightsCenter(offset: 0) == nil)
    #expect(DockMotion.lightsCenter(offset: 0.2) == nil)
    #expect(DockMotion.lightsCenter(offset: 95) == CGPoint(x: 25 - 95, y: 27))
    let p = ShellMetrics.peekOrigin
    #expect(DockMotion.lightsCenter(offset: -p.x, down: p.y) == CGPoint(x: 25 + p.x, y: 27 + p.y))
    for width in [160.0, 190, 400] {
      #expect(DockMotion.lightsCenter(offset: width)!.x + 46 + 7 < 0)
    }
    let arc = ShellMetrics.arcLightsCenter
    #expect(arc == CGPoint(x: 25, y: 24))
    #expect(DockMotion.lightsCenter(offset: 0, base: arc) == CGPoint(x: 25, y: 24))
    #expect(DockMotion.lightsCenter(offset: 95, base: arc) == CGPoint(x: 25 - 95, y: 24))
  }

  @Test func cardLeftRunsFromTheInsetToTheSidebarsWidth() {
    #expect(DockMotion.cardLeft(dock: 1, width: 190, inset: 7) == 190)
    #expect(DockMotion.cardLeft(dock: 0, width: 190, inset: 7) == 7)
    #expect(DockMotion.cardLeft(dock: 0.5, width: 190, inset: 7) == 98.5)
  }

  @Test func peekPanelCoversTheCardsRoundedCorners() {
    let p = ShellMetrics.peekOrigin
    let height: CGFloat = 860
    let panel = (left: p.x, top: p.y, bottom: height - ShellMetrics.peekBottom, r: ShellMetrics.peekRadius)
    let card = (left: ShellMetrics.cardInset, top: ShellMetrics.cardTop, bottom: height - ShellMetrics.cardInset, r: ShellMetrics.cardRadius)
    #expect(panel.left <= card.left && panel.top <= card.top && panel.bottom >= card.bottom)
    let corners = [
      ((panel.left + panel.r, panel.top + panel.r), (card.left + card.r, card.top + card.r)),
      ((panel.left + panel.r, panel.bottom - panel.r), (card.left + card.r, card.bottom - card.r)),
    ]
    for ((ax, ay), (bx, by)) in corners {
      #expect(hypot(ax - bx, ay - by) + card.r <= panel.r - 0.5)
    }
  }

  func framesToRest(_ run: SpringRun, hz: Double) -> Int {
    var n = 0
    while !run.sample(Double(n) / hz).done { n += 1 }
    return n
  }
}

struct WindowShellGeometryTests {
  @Test func toolbarButtonsDontMoveWithTheSidebar() {
    let g = ToolbarGeometry.of(sidebarButton: true)
    #expect([g.sidebarButton, g.back, g.forward, g.reload] == [21, 56, 92, 127])
    #expect(g.urlLeft == 145)
    let bare = ToolbarGeometry.of(sidebarButton: false)
    #expect([bare.back, bare.forward, bare.reload, bare.urlLeft] == [21, 57, 92, 110])
    #expect(ToolbarGeometry.none.urlLeft == 8)
  }

  @Test func twoPanesSplitTheWidthLessTheGap() {
    let split = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let g = ShellGeometry.split(split, width: 1001, height: 700)
    #expect(g.panes["a"] == CGRect(x: 0, y: 0, width: 497, height: 700))
    #expect(g.panes["b"] == CGRect(x: 504, y: 0, width: 497, height: 700))
    #expect(g.dividers == [SplitDivider(kind: .root(index: 0), rect: CGRect(x: 497, y: 0, width: 7, height: 700), vertical: true)])
  }

  @Test func aStackedSlotCutsItsOwnAxis() {
    let split = SplitView(
      id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: "horizontal", sizes: [0.4, 0.6], stack: SplitStack(index: 1, sizes: [0.25, 0.75]))
    let g = ShellGeometry.split(split, width: 1007, height: 607)
    #expect(g.panes["a"] == CGRect(x: 0, y: 0, width: 400, height: 607))
    #expect(g.panes["b"] == CGRect(x: 407, y: 0, width: 600, height: 150))
    #expect(g.panes["c"] == CGRect(x: 407, y: 157, width: 600, height: 450))
    #expect(g.dividers.count == 2)
    #expect(g.dividers[0] == SplitDivider(kind: .root(index: 0), rect: CGRect(x: 400, y: 0, width: 7, height: 607), vertical: true))
    #expect(g.dividers[1] == SplitDivider(kind: .stack, rect: CGRect(x: 407, y: 150, width: 600, height: 7), vertical: false))
  }

  @Test func verticalSplitsStackTopToBottomAndMismatchedSizesShareEvenly() {
    let split = SplitView(id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: "vertical", sizes: [1])
    let g = ShellGeometry.split(split, width: 800, height: 614)
    #expect(g.panes["a"] == CGRect(x: 0, y: 0, width: 800, height: 200))
    #expect(g.panes["b"] == CGRect(x: 0, y: 207, width: 800, height: 200))
    #expect(g.panes["c"] == CGRect(x: 0, y: 414, width: 800, height: 200))
    #expect(g.dividers.map(\.vertical) == [false, false])
  }

  @Test func resizeKeepsBothPanesAtLeastTheMinimum() {
    let total = 1007.0
    let grown = ShellGeometry.resize([0.5, 0.5], 0, delta: 100, total: total)
    #expect(abs(grown[0] - 0.6) < 1e-12 && abs(grown[1] - 0.4) < 1e-12)
    let clamped = ShellGeometry.resize([0.5, 0.5], 0, delta: 10_000, total: total)
    #expect(abs(clamped[1] * 1000 - 220) < 1e-9)
    let small = ShellGeometry.resize([0.1, 0.9], 0, delta: -50, total: total)
    #expect(abs(small[0] - 0.1) < 1e-12, "a pane already under the minimum holds its size")
  }

  @Test func dockedCardRunsFromTheInsetToTheSidebar() {
    let size = CGSize(width: 1360, height: 860)
    let open = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1))
    #expect(open.card == CGRect(x: 190, y: 6, width: 1163, height: 847))
    #expect(open.sidebar == CGRect(x: 0, y: 0, width: 190, height: 860))
    #expect(open.sidebarShift == 0)
    #expect(open.lights == nil)
    let closed = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, away: true))
    #expect(closed.card == CGRect(x: 7, y: 6, width: 1346, height: 847))
    #expect(closed.sidebar?.minX == -10_000)
    #expect(closed.lights == CGPoint(x: 25 - 190, y: 27))
    let half = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0.5, sidebarWidth: 240))
    #expect(half.card.minX == 123.5)
    #expect(half.sidebarShift == -120)
    #expect(half.lights == CGPoint(x: 25 - 120, y: 27))
  }

  @Test func theAddressBarInTheSidebarRaisesTheLights() {
    let size = CGSize(width: 1360, height: 860)
    #expect(DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, addressBarInSidebar: true)).lights == CGPoint(x: 25, y: 24))
  }

  @Test func thePeekPanelSlidesInFromPastTheEdge() {
    let size = CGSize(width: 1360, height: 860)
    let out = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, peeking: true, peekSlide: 1))
    #expect(out.sidebar == CGRect(x: 5, y: 5, width: 190, height: 850))
    #expect(out.sidebarShift == 0)
    #expect(out.lights == CGPoint(x: 30, y: 32))
    let start = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, peeking: true, peekSlide: 0))
    #expect(abs(start.sidebarShift + 202) < 1e-9, "\(start.sidebarShift + 202)")
    #expect(out.card == CGRect(x: 7, y: 6, width: 1346, height: 847), "the card stays put under the peek")
  }

  @Test func topTabsInsetTheCardUnderTheStrip() {
    let size = CGSize(width: 1200, height: 800)
    let open = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, topTabs: true))
    #expect(open.card == CGRect(x: 6, y: 42, width: 1188, height: 752))
    #expect(open.topStrip == CGRect(x: 0, y: 0, width: 1200, height: 42))
    #expect(open.sidebar == nil)
    let hidden = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 0, topTabs: true))
    #expect(hidden.card.minY == 6)
    #expect(hidden.topStrip?.minY == -42)
  }

  @Test func fullscreenGivesTheCardTheWholeWindow() {
    let size = CGSize(width: 1200, height: 800)
    let f = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, fullscreen: true))
    #expect(f.card == CGRect(origin: .zero, size: size))
    #expect(f.sidebar == nil)
    #expect(f.lights == nil)
    let arc = DockedLayoutFrames.of(DockedLayoutInput(size: size, dock: 1, fullscreen: true, addressBarInSidebar: true))
    #expect(arc.lights == CGPoint(x: 25, y: 24), "RN still places Arc's lights in full screen")
  }
}

@MainActor
struct WindowShellViewTests {
  @Test func slotsStackInOrderWhateverOrderTheyMountIn() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let react = NSView(), backdrop = NSView(), sidebar = NSView()
    shell.mount(.react, react)
    shell.mount(.backdrop, backdrop)
    shell.mount(.sidebar, sidebar)
    #expect(shell.subviews == [shell.hiddenPages, backdrop, react, shell.card, shell.sidePanelClip, sidebar, shell.overlay])
    #expect(react.frame == shell.bounds)
    #expect(backdrop.frame == shell.bounds)
    #expect(sidebar.frame == CGRect(x: 0, y: 0, width: 190, height: 700))
    let replacement = NSView()
    shell.mount(.backdrop, replacement)
    #expect(shell.subviews[1] === replacement)
    #expect(backdrop.superview == nil)
    shell.mount(.sidebar, nil)
    #expect(sidebar.superview == nil)
  }

  @Test func theCardPageSitsInsideTheCardsRoundedClipWhichSpansTheWholeCard() throws {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.layoutSubtreeIfNeeded()
    var clip: NSView? = shell.cardPage.superview
    while let view = clip, view !== shell, !(view.layer?.masksToBounds == true && (view.layer?.cornerRadius ?? 0) > 0) { clip = view.superview }
    let rounded = try #require(clip.flatMap { $0 === shell ? nil : $0 }, "nothing rounds the card page's bottom corners")
    #expect(rounded.layer?.cornerRadius == ShellMetrics.cardRadius)
    #expect(rounded.layer?.cornerCurve == .continuous)
    #expect(rounded.convert(rounded.bounds, to: shell) == shell.frames.card)
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell).maxY == shell.frames.card.maxY)
    shell.cardPageFrame = CGRect(x: 0, y: 0, width: shell.frames.card.width, height: shell.frames.card.height)
    #expect(shell.cardPage.convert(shell.cardPage.bounds, to: shell) == shell.frames.card)
  }

  @Test func theCardStyleFillsAndRoundsTheClipAndFullscreenSquaresIt() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    #expect(shell.cardClip.layer?.backgroundColor == nil)
    let card = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 0.5)
    shell.cardStyle = CardStyle(fill: card, radius: ShellMetrics.cardRadius)
    #expect(shell.cardClip.layer?.backgroundColor == card.cgColor)
    #expect(shell.cardClip.layer?.cornerRadius == 10)
    shell.cardStyle = CardStyle(fill: nil, radius: 0)
    #expect(shell.cardClip.layer?.backgroundColor == nil)
    #expect(shell.cardClip.layer?.cornerRadius == 0)
    #expect(shell.hitTest(NSPoint(x: 500, y: 400)) == nil)
  }

  @Test func theReactRootOnTopStacksAboveEveryNativeLayerButTheOverlay() {
    let shell = WindowShellView(windowId: "w", reactOnTop: true)
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let react = NSView(), backdrop = NSView(), sidebar = NSView(), peek = NSView(), strip = NSView(), split = NSView()
    shell.mount(.react, react)
    shell.mount(.sidebar, sidebar)
    shell.mount(.backdrop, backdrop)
    shell.mount(.topStrip, strip)
    shell.mount(.peek, peek)
    shell.mount(.splitChrome, split)
    #expect(shell.subviews == [shell.hiddenPages, backdrop, shell.card, shell.sidePanelClip, split, peek, sidebar, strip, react, shell.overlay])
    shell.mount(.react, nil)
    let replacement = NSView()
    shell.mount(.react, replacement)
    #expect(shell.subviews == [shell.hiddenPages, backdrop, shell.card, shell.sidePanelClip, split, peek, sidebar, strip, replacement, shell.overlay])
  }

  @Test func theReactRootStaysAboveTheBackdropOnlyByDefault() {
    for mounts in [[WindowShellView.Slot.react, .sidebar, .backdrop, .topStrip, .peek, .splitChrome], [.splitChrome, .peek, .topStrip, .backdrop, .sidebar, .react]] {
      let shell = WindowShellView(windowId: "w")
      shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
      var views: [WindowShellView.Slot: NSView] = [:]
      for slot in mounts {
        views[slot] = NSView()
        shell.mount(slot, views[slot])
      }
      #expect(shell.subviews == [shell.hiddenPages, views[.backdrop]!, views[.react]!, shell.card, shell.sidePanelClip, views[.splitChrome]!, views[.peek]!, views[.sidebar]!, views[.topStrip]!, shell.overlay])
    }
  }

  @Test func aPassThroughReactRootOnTopLetsTheLayersUnderItTakeThePointer() {
    let shell = WindowShellView(windowId: "w", reactOnTop: true)
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let react = PassThroughRoot()
    let button = NSView(frame: CGRect(x: 500, y: 330, width: 100, height: 40))
    react.addSubview(button)
    shell.mount(.react, react)
    let sidebar = NSView()
    shell.mount(.sidebar, sidebar)
    let page = NSView(frame: shell.card.bounds)
    shell.card.addSubview(page)
    #expect(shell.hitTest(NSPoint(x: 100, y: 300)) === sidebar)
    #expect(shell.hitTest(NSPoint(x: 600, y: 200)) === page)
    #expect(shell.hitTest(NSPoint(x: 550, y: 350)) === button)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 100, y: 300)) == .sidebar)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 600, y: 200)) == .card)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 550, y: 350)) == .react)
    page.removeFromSuperview()
    #expect(shell.slotUnderPointer(at: NSPoint(x: 600, y: 200)) == nil)
  }

  #if DEBUG
  @Test func movingFromTheReactRootOnTopToAnEmptySpotInItTellsHover() {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let shell = WindowShellView(windowId: "w", reactOnTop: true)
    window.contentView = shell
    let react = PassThroughRoot()
    react.addSubview(NSView(frame: CGRect(x: 500, y: 330, width: 100, height: 40)))
    shell.mount(.react, react)
    shell.card.addSubview(NSView(frame: shell.card.bounds))
    var posts = 0
    let token = NotificationCenter.default.addObserver(forName: WindowShellView.hoverCoverChanged, object: shell, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    let move = { (x: CGFloat) in
      shell.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 350), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
    }
    let frame = { shell.devPointerFrame() }
    move(550)
    #expect(posts == 1)
    move(560)
    frame()
    #expect(posts == 1)
    move(700)
    #expect(posts == 1)
    frame()
    #expect(posts == 2)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 700, y: 350)) == .card)
    move(550)
    frame()
    #expect(posts == 3)
    frame()
    move(700)
    #expect(posts == 4)
  }
  #endif

  @Test func framesFollowTheDockAndReportOnlyChanges() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    var reported: [CGRect] = []
    shell.onFrames = { reported.append($0.card) }
    let card = shell.card
    shell.update { $0.dock = 0 }
    shell.update { $0.dock = 0 }
    #expect(card.frame == CGRect(x: 7, y: 6, width: 986, height: 687))
    #expect(reported == [CGRect(x: 7, y: 6, width: 986, height: 687)])
    shell.setFrameSize(NSSize(width: 1100, height: 700))
    #expect(card.frame.width == 1086)
    #expect(reported.count == 2)
  }

  @Test func theReactRootStaysClearOverTheNativeBackdrop() {
    let shell = WindowShellView(windowId: "w")
    let react = FilledView()
    react.backgroundColor = .windowBackgroundColor
    shell.mount(.react, react)
    #expect(react.backgroundColor == nil)
    shell.setValue(NSColor.windowBackgroundColor, forKey: "backgroundColor")
    #expect(react.backgroundColor == nil)
    #expect(shell.backgroundColor == .windowBackgroundColor)
    shell.setValue(nil, forKey: "backgroundColor")
    #expect(shell.backgroundColor == nil)
  }

  @Test func theShellItselfTakesNoClicks() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(shell.hitTest(NSPoint(x: 10, y: 10)) == nil)
    let react = NSView()
    shell.mount(.react, react)
    #expect(shell.hitTest(NSPoint(x: 10, y: 10)) === react)
  }
}

@MainActor
struct WindowShellMountTests {
  @Test func aViewThatMovedAwayIsNotPulledOutOfItsNewParent() {
    let shell = WindowShellView(windowId: "w")
    let other = NSView()
    let moving = NSView()
    shell.mount(.peek, moving)
    other.addSubview(moving)
    shell.mount(.peek, NSView())
    #expect(moving.superview === other)
  }

  @Test func aViewMountedInASecondSlotLeavesTheFirst() {
    let shell = WindowShellView(windowId: "w")
    let view = NSView()
    shell.mount(.peek, view)
    shell.mount(.topStrip, view)
    #expect(shell.view(in: .peek) == nil)
    #expect(shell.slot(of: view) == .topStrip)
    shell.mount(.peek, NSView())
    #expect(view.superview === shell)
  }

  @Test func mountsAndMovesTellHoverTheCoverChanged() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    var posts = 0
    let token = NotificationCenter.default.addObserver(forName: WindowShellView.hoverCoverChanged, object: shell, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    shell.mount(.sidebar, NSView())
    #expect(posts == 1)
    shell.update { $0.dock = 0 }
    #expect(posts == 2)
    shell.mount(.sidebar, nil)
    #expect(posts == 3)
  }

  @Test func theSlotUnderThePointerIsTheTopmostOneHit() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let react = NSView()
    shell.mount(.react, react)
    shell.mount(.sidebar, NSView())
    #expect(shell.slotUnderPointer(at: NSPoint(x: 100, y: 300)) == .sidebar)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 600, y: 300)) == .react)
    shell.card.addSubview(NSView(frame: shell.card.bounds))
    #expect(shell.slotUnderPointer(at: NSPoint(x: 600, y: 300)) == .card)
  }

  @Test func pagesWithNoSlotParkOutOfSightAtTheCardsSize() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.mount(.react, NSView())
    shell.mount(.sidebar, NSView())
    #expect(shell.hiddenPages.isHidden)
    #expect(shell.hiddenPages.frame == shell.card.frame)
    #expect(shell.subviews.first === shell.hiddenPages)
    #expect(shell.slot(of: shell.hiddenPages) == nil)
    let page = NSView(frame: shell.hiddenPages.bounds)
    shell.hiddenPages.addSubview(page)
    #expect(shell.hitTest(NSPoint(x: 400, y: 300)) !== page)
  }

  @Test func theOverlayIsAShellOwnedContainerOnTop() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.mount(.sidebar, NSView())
    #expect(shell.view(in: .overlay) === shell.overlay)
    #expect(shell.subviews.last === shell.overlay)
    #expect(shell.overlay.frame == shell.bounds)
    #expect(shell.hitTest(NSPoint(x: 600, y: 300)) == nil)
    let card = NSView(frame: CGRect(x: 10, y: 325, width: 50, height: 50))
    shell.overlay.addSubview(card)
    #expect(shell.slotUnderPointer(at: NSPoint(x: 30, y: 350)) == .overlay)
  }

  #if DEBUG
  @Test func thePointerSlotIsTheLayerTheShellLastResolvedAndReadingItLooksNothingUp() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.mount(.sidebar, NSView())
    #expect(shell.pointerSlot == nil)
    shell.devNotePointer(NSPoint(x: 30, y: 350))
    #expect(shell.pointerSlot == .sidebar)
    shell.devResetPointerStats()
    for _ in 0..<40 { #expect(shell.pointerSlot == .sidebar) }
    #expect(shell.devPointerLookups == 0)
    shell.devNotePointer(nil)
    #expect(shell.pointerSlot == nil)
  }

  @Test func aCoverArrivingUnderAStillPointerMovesThePointerSlotBeforeHoverHears() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.mount(.sidebar, NSView())
    shell.devNotePointer(NSPoint(x: 30, y: 350))
    var seen: [WindowShellView.Slot?] = []
    let token = NotificationCenter.default.addObserver(forName: WindowShellView.hoverCoverChanged, object: shell, queue: nil) { _ in
      MainActor.assumeIsolated { seen.append(shell.pointerSlot) }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let cover = NSView(frame: CGRect(x: 10, y: 325, width: 50, height: 50))
    shell.overlay.addSubview(cover)
    shell.coverChanged()
    cover.removeFromSuperview()
    shell.coverChanged()
    #expect(seen == [.overlay, .sidebar])
  }
  #endif

  @Test func theOverlayTellsHoverOncePerTurnWhenAChildComesGoesMovesOrHides() async {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    var posts = 0
    let token = NotificationCenter.default.addObserver(forName: WindowShellView.hoverCoverChanged, object: shell, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    let nextTurn = { try? await Task.sleep(nanoseconds: 20_000_000) }
    let card = NSView(frame: CGRect(x: 190.5, y: 40, width: 280, height: 120))
    shell.overlay.addSubview(card)
    card.frame.origin.y = 60
    #expect(posts == 0)
    await nextTurn()
    #expect(posts == 1)
    card.frame.origin.y = 80
    await nextTurn()
    #expect(posts == 2)
    card.isHidden = true
    await nextTurn()
    #expect(posts == 3)
    card.isHidden = false
    card.frame.origin.y = 90
    await nextTurn()
    #expect(posts == 4)
    card.removeFromSuperview()
    await nextTurn()
    #expect(posts == 5)
    card.isHidden = true
    await nextTurn()
    #expect(posts == 5)
  }

  @Test func emptyNativeLayersLetTheReactRootTakeThePointer() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let react = NSView()
    shell.mount(.react, react)
    shell.mount(.splitChrome, SplitChromeView(windowId: "w"))
    shell.mount(.peek, PeekOverlayView(frame: .zero))
    shell.mount(.topStrip, TopStripView(windowId: "w"))
    shell.update { $0.topTabs = true }
    let panes = SplitPanesView(windowId: "w")
    panes.frame = shell.card.bounds
    shell.card.addSubview(panes)
    for point in [NSPoint(x: 600, y: 20), NSPoint(x: 600, y: 300), NSPoint(x: 100, y: 300)] {
      let hit = shell.hitTest(point)
      #expect(hit == nil || hit === react, "an empty native layer took \(point): \(String(describing: hit))")
    }
  }

  @Test func aShellGoesAwayWithAChildInItsOverlay() async {
    weak var gone: WindowShellView?
    var posts = 0
    let token = NotificationCenter.default.addObserver(forName: WindowShellView.hoverCoverChanged, object: nil, queue: nil) { note in
      if (note.object as? WindowShellView)?.windowId == "freed" { posts += 1 }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let kept = NSView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
    do {
      let shell = WindowShellView(windowId: "freed")
      shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
      shell.overlay.addSubview(NSView(frame: CGRect(x: 10, y: 10, width: 50, height: 50)))
      shell.overlay.addSubview(kept)
      gone = shell
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(gone == nil)
    #expect(kept.superview == nil)
    posts = 0
    kept.frame.origin.y = 80
    kept.isHidden = true
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(posts == 0)
  }

  @Test func theShellGatesHover() {
    #expect(WindowShellView(windowId: "w").responds(to: NSSelectorFromString("solara_gatesHover")))
  }

  @Test func theCardIsAShellOwnedContainer() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    #expect(shell.view(in: .card) === shell.card)
    #expect(shell.card.frame == CGRect(x: 190, y: 6, width: 803, height: 687))
    #expect(shell.card.isFlipped)
    #expect(shell.hitTest(NSPoint(x: 400, y: 300)) == nil)
    let page = NSView(frame: shell.card.bounds)
    shell.card.addSubview(page)
    #expect(shell.hitTest(NSPoint(x: 400, y: 300)) === page)
  }

  @Test func aForeignOverlayAddedByTheEngineStaysOnTop() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.mount(.react, NSView())
    let pip = NSView(frame: shell.bounds)
    shell.addSubview(pip)
    let sidebar = NSView()
    shell.mount(.sidebar, sidebar)
    shell.mount(.splitChrome, NSView())
    #expect(shell.subviews.last === pip)
    #expect(shell.subviews.firstIndex(of: sidebar)! < shell.subviews.firstIndex(of: pip)!)
  }

  @Test func theWindowIsReportedWhenTheShellMovesInAndOut() {
    let shell = WindowShellView(windowId: "w")
    var seen: [Bool] = []
    shell.onWindow = { seen.append($0 != nil) }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(shell)
    shell.removeFromSuperview()
    #expect(seen == [true, false])
  }
}

@MainActor
struct ShellLifetimesTests {
  final class Host {
    var stops = 0
  }

  @Test func rebuildingAnIdStopsTheOldHost() {
    let lifetimes = ShellLifetimes<Host> { $0.stops += 1 }
    let first = Host(), second = Host()
    lifetimes.adopt("w", first)
    lifetimes.adopt("w", second)
    #expect(first.stops == 1)
    #expect(second.stops == 0)
    #expect(lifetimes.host("w") === second)
  }

  @Test func endingWithAStaleHostLeavesTheNewOne() {
    let lifetimes = ShellLifetimes<Host> { $0.stops += 1 }
    let first = Host(), second = Host()
    lifetimes.adopt("w", first)
    lifetimes.adopt("w", second)
    lifetimes.end("w", ifHost: first)
    #expect(lifetimes.host("w") === second)
    lifetimes.end("w", ifHost: second)
    #expect(lifetimes.host("w") == nil)
    #expect(second.stops == 1)
  }

  @Test func aShellEndsWhenTheStoreDropsItsWindow() {
    var reported: [Set<String>] = []
    let lifetimes = ShellLifetimes<Host> { $0.stops += 1 }
    lifetimes.onIds = { reported.append($0) }
    let kept = Host(), orphan = Host()
    lifetimes.adopt("a", kept)
    lifetimes.adopt("b", orphan)
    lifetimes.prune(keeping: ["a", "b"])
    lifetimes.prune(keeping: ["a", "c"])
    #expect(orphan.stops == 1)
    #expect(kept.stops == 0)
    #expect(lifetimes.ids == ["a"])
    #expect(reported.last == ["a"])
    lifetimes.prune(keeping: ["a"])
    #expect(reported.count == 3)
  }

  @Test func aShellBuiltBeforeTheStoreHasItsWindowSurvives() {
    let lifetimes = ShellLifetimes<Host> { $0.stops += 1 }
    let early = Host()
    lifetimes.adopt("new", early)
    lifetimes.prune(keeping: ["main"])
    #expect(lifetimes.host("new") === early)
    lifetimes.prune(keeping: ["main", "new"])
    lifetimes.prune(keeping: ["main"])
    #expect(early.stops == 1)
    #expect(lifetimes.host("new") == nil)
  }

  @Test func anIdReusedAfterItEndedStartsFresh() {
    let lifetimes = ShellLifetimes<Host> { $0.stops += 1 }
    let first = Host(), second = Host()
    lifetimes.adopt("w", first)
    lifetimes.prune(keeping: ["w"])
    lifetimes.end("w")
    lifetimes.adopt("w", second)
    lifetimes.prune(keeping: [])
    #expect(lifetimes.host("w") === second)
  }
}

final class FilledView: NSView {
  @objc var backgroundColor: NSColor?
}

@MainActor
@Suite struct DockAnimatorTests {
  @Test func springSettlesOnTargetAndReportsSettle() {
    let animator = DockAnimator(value: 1)
    var settled: Double?
    animator.onSettle = { settled = $0 }
    animator.animate(to: 0, in: NSView())
    var frames = 0
    while animator.moving && frames < 200 {
      animator.step(by: 1.0 / 60)
      frames += 1
    }
    #expect(settled == 0)
    #expect(animator.value == 0)
    #expect(frames == 20)
  }

  @Test func retargetKeepsVelocity() {
    let animator = DockAnimator(value: 1)
    animator.animate(to: 0, in: NSView())
    for _ in 0..<4 { animator.step(by: 1.0 / 60) }
    let mid = animator.value
    animator.animate(to: 1, in: NSView())
    animator.step(by: 1.0 / 60)
    #expect(animator.value < mid)
    animator.stop()
  }

  @Test func timedArcHideIsHundredMilliseconds() {
    let animator = DockAnimator(value: 1)
    animator.animate(to: 0, curve: .timed(duration: DockMotion.arcHideMs / 1000, ease: .outCubic), in: NSView())
    var frames = 0
    while animator.moving && frames < 100 {
      animator.step(by: 1.0 / 60)
      frames += 1
    }
    #expect(frames == 6)
    #expect(animator.value == 0)
  }
}

@MainActor
private final class PassThroughRoot: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
