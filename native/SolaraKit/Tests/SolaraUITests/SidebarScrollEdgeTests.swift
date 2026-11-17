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
