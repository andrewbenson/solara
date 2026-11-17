import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

#if DEBUG || SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct PanePlacementInvalidationTests {
  @Test func equivalentRevisionsKeepPlacementCleanAndPreserveHosts() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "placement-invalidation")
    defer { view.stop() }
    view.install(try snapshot(state, revision: 1), state: state)
    let page = try #require(view.container("a"))
    let toolbar = try #require(view.toolbar("a"))
    let frame = page.frame
    let layouts = view.placementLayoutPasses
    #expect(layouts > 0)
    view.install(try snapshot(state, revision: 2), state: state)
    #expect(view.placementLayoutPasses == layouts)
    #expect(view.container("a") === page)
    #expect(view.toolbar("a") === toolbar)
    #expect(page.frame == frame)
    #expect(TabSlots.shared.container(for: .card("placement-invalidation")) === page)
  }

  @Test func equivalentPlacementStillFlushesDirtyToolbarContent() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "placement-invalidation")
    defer { view.stop() }
    view.install(try snapshot(state, revision: 1), state: state)
    let toolbar = try #require(view.toolbar("a"))
    let layouts = view.placementLayoutPasses
    toolbar.needsLayout = true
    view.install(try snapshot(state, revision: 2), state: state)
    #expect(!toolbar.needsLayout)
    #expect(view.placementLayoutPasses == layouts)
  }

  @Test func changedBoundsAndPageInsetsUpdateTheExistingContainer() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "placement-invalidation")
    defer { view.stop() }
    view.install(try snapshot(state, revision: 1), state: state)
    let page = try #require(view.container("a"))
    let toolbar = try #require(view.toolbar("a"))
    let layouts = view.placementLayoutPasses
    let next = try snapshot(state, revision: 2, width: 850, pageTop: 112)
    view.install(next, state: state)
    #expect(view.placementLayoutPasses > layouts)
    #expect(view.container("a") === page)
    #expect(view.toolbar("a") === toolbar)
    let expected = try #require(next.pageViewports["a"])
    #expect(page.convert(page.bounds, to: view) == expected.offsetBy(dx: -next.frames.card.minX, dy: -next.frames.card.minY))
    #expect(page.bounds.size == expected.size)
  }

  @Test func equivalentPlacementRefreshesEdgeTintWithoutReplacingHosts() throws {
    let state = try fixture()
    let shell = WindowShellView(windowId: "placement-invalidation")
    let view = SplitPanesView(windowId: "placement-invalidation")
    shell.card.addSubview(view)
    defer { view.stop(); shell.stopLayoutMotion() }
    shell.cardEdgeTint = .systemRed
    view.install(try snapshot(state, revision: 1), state: state)
    let page = try #require(view.container("a"))
    let toolbar = try #require(view.toolbar("a"))
    let edges = view.subviews.compactMap { $0 as? CardEdgeView }
    #expect(edges.count == 2)
    #expect(edges.allSatisfy { $0.tint == .systemRed })
    let frame = page.frame
    let layouts = view.placementLayoutPasses
    for tint in [NSColor.systemBlue, nil] {
      shell.cardEdgeTint = tint
      view.install(try snapshot(state, revision: 2), state: state)
      #expect(edges.allSatisfy { $0.tint == tint })
      #expect(view.placementLayoutPasses == layouts)
      #expect(view.container("a") === page)
      #expect(view.toolbar("a") === toolbar)
      #expect(page.frame == frame)
    }
  }

  @Test func equivalentPlacementDefersGuestLayoutAndFlushesNativeToolbar() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "placement-invalidation")
    defer { view.stop() }
    view.install(try snapshot(state, revision: 1), state: state)
    let page = try #require(view.container("a"))
    let toolbar = try #require(view.toolbar("a"))
    let guest = PlacementLayoutGuest()
    page.addSubview(guest)
    page.layoutSubtreeIfNeeded()
    let layouts = guest.layouts
    guest.needsLayout = true
    toolbar.needsLayout = true
    view.install(try snapshot(state, revision: 2), state: state)
    #expect(guest.layouts == layouts)
    #expect(guest.needsLayout)
    #expect(!toolbar.needsLayout)
  }

  @Test func equivalentOverlayPlacementDefersRNLayoutAndFlushesNativeContent() throws {
    let state = try fixture()
    let view = PaneOverlaysView(windowId: "placement-invalidation")
    defer { view.stop() }
    view.install(try snapshot(state, revision: 1), state: state)
    let rn = try #require(view.container("a", layer: .rn))
    let native = try #require(view.container("a", layer: .native))
    let guest = PlacementLayoutGuest()
    let control = PlacementLayoutGuest()
    rn.addSubview(guest)
    native.addSubview(control)
    view.layoutSubtreeIfNeeded()
    let layouts = [guest.layouts, control.layouts]
    guest.needsLayout = true
    control.needsLayout = true
    view.install(try snapshot(state, revision: 2), state: state)
    #expect(guest.layouts == layouts[0])
    #expect(guest.needsLayout)
    #expect(control.layouts == layouts[1] + 1)
    #expect(!control.needsLayout)
  }

  private func fixture() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"placement-invalidation":{"id":"placement-invalidation","profileId":"p","sidebarOpen":true,"tabIds":["a"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"placement-invalidation","profileId":"p","url":"https://example.test"}}}"#).object ?? [:])
  }

  private func snapshot(_ state: BrowserState, revision: Int, width: CGFloat = 1000, pageTop: Double = 71) throws -> WindowLayoutSnapshot {
    let input = try #require(WindowLayoutInput(state: state, windowId: "placement-invalidation", storeRevision: revision,
      bounds: CGRect(x: 0, y: 0, width: width, height: 700),
      pageFacts: ["a": WindowLayoutPageFacts(registration: "page-a", top: pageTop, band: 38)]))
    return .of(input, generation: UInt64(revision))
  }
}
@MainActor
private final class PlacementLayoutGuest: NSView {
  var layouts = 0
  override func layout() {
    super.layout()
    layouts += 1
  }
}
#endif
