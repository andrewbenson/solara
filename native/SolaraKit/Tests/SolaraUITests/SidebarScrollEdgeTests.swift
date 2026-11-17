import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarScrollEdgeTests {
  func sidebar(_ total: Int, virtualizesRows: Bool, width: Double = 190) throws -> SidebarView {
    let view = SidebarView(windowId: "w", virtualizesRows: virtualizesRows)
    view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
    view.update(state: try SidebarViewportTests.state(total), host: SidebarHostState(profileId: "p"))
    view.layoutSubtreeIfNeeded()
    return view
  }

  func fading(_ view: SidebarView) -> Bool { view.clip.layer?.mask === view.bottomFade }

  func expectFadeFitsClip(_ view: SidebarView) {
    let height = view.clip.bounds.height
    #expect(view.bottomFade.frame == view.clip.bounds)
    let locations = (view.bottomFade.locations ?? []).map(\.doubleValue)
    #expect(locations.count == 4)
    #expect(locations.first == 0)
    #expect(locations.last == 1)
    #expect(abs(locations[1] - Double((height - SidebarMetrics.bottomFadeHeight) / height)) < 1e-9)
    #expect(locations[2] == 1)
  }

  @Test(arguments: [false, true], [24.0, 40.0, 78.0])
  func fadeCrossesTheLiveProfileBar(virtualizesRows: Bool, barHeight: Double) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    view.bottomBarHeight = barHeight
    view.layoutSubtreeIfNeeded()
    #expect(fading(view))
    #expect(view.clip.frame.maxY == view.bounds.maxY)
    #expect(view.bottomFade.frame == view.clip.bounds)
    let locations = try #require(view.bottomFade.locations).map(\.doubleValue)
    let opaqueY = view.clip.frame.minY + locations[1] * view.clip.bounds.height
    let clearY = view.clip.frame.minY + locations[2] * view.clip.bounds.height
    #expect(abs(opaqueY - (400 - barHeight)) < 1e-9)
    #expect(abs(clearY - (400 - barHeight / 2)) < 1e-9)
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 100))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    let moved = try #require(view.bottomFade.locations).map(\.doubleValue)
    #expect(abs(view.clip.frame.minY + moved[1] * view.clip.bounds.height - opaqueY) < 1e-9)
    #expect(abs(view.clip.frame.minY + moved[2] * view.clip.bounds.height - clearY) < 1e-9)
  }

  @Test(arguments: [false, true], [24.0, 40.0, 78.0])
  func lastRowClearsTheBarAtMaximumScroll(virtualizesRows: Bool, barHeight: Double) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    view.bottomBarHeight = barHeight
    view.layoutSubtreeIfNeeded()
    let document = try #require(view.scroll.documentView)
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: document.frame.maxY - view.scroll.contentView.bounds.height))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    let last = try #require(view.frameOf("t199"))
    #expect(last.maxY <= 400 - barHeight)
    #expect(last.minY >= view.clip.frame.minY)
    #expect(last.maxY <= view.pageLayout.scrollBottom)
    #expect(!fading(view))
  }

  @Test(arguments: [false, true])
  func selectingTheLastRowRevealsItAboveTheDockAndBar(virtualizesRows: Bool) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    view.bottomBarHeight = 40
    var state = try SidebarViewportTests.state(200)
    state.windows["w"]?.activeTabIds["p"] = "t199"
    view.update(state: state, host: SidebarHostState(profileId: "p"))
    let last = try #require(view.frameOf("t199"))
    #expect(last.maxY <= view.pageLayout.scrollBottom)
    #expect(last.minY >= view.clip.frame.minY)
    let document = try #require(view.scroll.documentView)
    #expect(view.scroll.contentView.bounds.maxY <= document.frame.maxY)
  }

  @Test func accessibilityRevealKeepsTheLastRowAboveTheDockAndBar() throws {
    let view = try sidebar(200, virtualizesRows: true)
    defer { view.stop() }
    view.bottomBarHeight = 40
    #expect(view.revealLogical("t:t199"))
    let last = try #require(view.frameOf("t199"))
    #expect(last.maxY <= view.pageLayout.scrollBottom)
    #expect(last.minY >= view.clip.frame.minY)
    let document = try #require(view.scroll.documentView)
    #expect(view.scroll.contentView.bounds.maxY <= document.frame.maxY)
  }

  @Test func rowsBehindTheBarDoNotReceiveHover() throws {
    let view = try sidebar(200, virtualizesRows: false)
    defer { view.stop() }
    view.bottomBarHeight = 40
    let row = try #require(view.views["t:t0"] as? SidebarRowView)
    view.pointerEntered(row, at: view.convert(CGPoint(x: 50, y: 380), to: nil))
    #expect(view.hoverKey == nil)
    #expect(!row.hovered)
  }

  @Test func profileIconOwnsClicksOverTheExtendedList() throws {
    let host = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 190, height: 400))
    let view = try sidebar(200, virtualizesRows: false)
    let chrome = SidebarChromeView(frame: host.bounds)
    var state = SidebarChromeTests().state()
    state.currentProfileId = "p0"
    chrome.update(state)
    view.bottomBarHeight = chrome.footerHeight
    host.addSubview(view)
    host.addSubview(chrome)
    host.layoutSubtreeIfNeeded()
    defer { view.stop() }
    let icon = try #require(chrome.profileRow.subviews.compactMap { $0 as? SidebarProfileDot }.first { $0.profileId == "p1" })
    #expect(!icon.selected)
    #expect(!icon.isHiddenOrHasHiddenAncestor)
    #expect(!icon.bounds.isEmpty)
    let point = icon.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: host)
    #expect(point.y >= chrome.frame.maxY - chrome.footerHeight)
    #expect(point.y < chrome.frame.maxY)
    let hitPoint = icon.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: host.superview)
    let hit = try #require(host.hitTest(hitPoint))
    #expect(hit === icon)
    #expect(!hit.isDescendant(of: view))
    #expect(view.clip.frame.maxY > point.y)
    var actions: [SidebarChromeAction] = []
    chrome.onAction = { actions.append($0) }
    let location = icon.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
      timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    hit.mouseDown(with: down)
    hit.mouseUp(with: up)
    #expect(actions.filter { if case .switchProfile = $0 { true } else { false } } == [.switchProfile(icon.profileId)])
  }

  @Test(arguments: [false, true], [190.0, SidebarRail.width])
  func overflowingListFadesItsOwnRowsAtTheBottom(virtualizesRows: Bool, width: Double) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows, width: width)
    defer { view.stop() }
    #expect(fading(view))
    expectFadeFitsClip(view)
    #expect(view.bottomFade.startPoint == CGPoint(x: 0.5, y: 0))
    #expect(view.bottomFade.endPoint == CGPoint(x: 0.5, y: 1))
    let alphas = try #require(view.bottomFade.colors as? [CGColor]).map(\.alpha)
    #expect(alphas == [1, 1, 0, 0])
    #expect(!view.clip.subviews.contains { $0 is NSVisualEffectView })
  }

  @Test(arguments: [false, true], [190.0, SidebarRail.width])
  func fittingListIsNotFaded(virtualizesRows: Bool, width: Double) throws {
    let view = try sidebar(1, virtualizesRows: virtualizesRows, width: width)
    defer { view.stop() }
    #expect(!fading(view))
  }

  @Test(arguments: [false, true])
  func reachingTheEndClearsTheFadeAndScrollingBackRestoresIt(virtualizesRows: Bool) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    let document = try #require(view.scroll.documentView)
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: document.frame.maxY - view.scroll.contentView.bounds.height))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    #expect(!fading(view))
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 100))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    #expect(fading(view))
    expectFadeFitsClip(view)
  }

  @Test(arguments: [false, true])
  func resizingAndRemovingRowsRecomputesTheFade(virtualizesRows: Bool) throws {
    let view = try sidebar(20, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    for width in [SidebarRail.width, 260.0, SidebarRail.width] {
      view.setFrameSize(CGSize(width: width, height: 240))
      view.layoutSubtreeIfNeeded()
      #expect(view.clip.bounds.width == view.bounds.width)
      #expect(fading(view))
      expectFadeFitsClip(view)
    }
    view.setFrameSize(CGSize(width: view.frame.width, height: 1400))
    view.layoutSubtreeIfNeeded()
    #expect(!fading(view))
    view.setFrameSize(CGSize(width: view.frame.width, height: 240))
    view.layoutSubtreeIfNeeded()
    #expect(fading(view))
    view.update(state: try SidebarViewportTests.state(1), host: SidebarHostState(profileId: "p"))
    #expect(!fading(view))
  }
}
