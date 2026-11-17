import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct FrameLayoutIsolationTests {
  @Test func changedPaneGeometryDoesNotLayoutForeignPageSubtrees() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "frame-isolation")
    defer { view.stop() }
    view.install(try snapshot(state, width: 1000), state: state)
    let page = try #require(view.container("a"))
    let guest = FrameLayoutGuest()
    page.addSubview(guest)
    page.layoutSubtreeIfNeeded()
    let layouts = guest.layouts
    guest.needsLayout = true
    let next = try snapshot(state, width: 850)
    view.install(next, state: state)
    #expect(guest.layouts == layouts)
    #expect(guest.needsLayout)
    #expect(page.bounds.size == next.pageViewports["a"]?.size)
    #expect(view.toolbar("a")?.needsLayout == false)
  }

  @Test func changedOverlayGeometryDoesNotLayoutForeignRNSubtrees() throws {
    let state = try fixture()
    let view = PaneOverlaysView(windowId: "frame-isolation")
    defer { view.stop() }
    view.install(try snapshot(state, width: 1000), state: state)
    let rn = try #require(view.container("a", layer: .rn))
    let native = try #require(view.container("a", layer: .native))
    let guest = FrameLayoutGuest()
    let control = FrameLayoutGuest()
    rn.addSubview(guest)
    native.addSubview(control)
    view.layoutSubtreeIfNeeded()
    let layouts = [guest.layouts, control.layouts]
    guest.needsLayout = true
    control.needsLayout = true
    let next = try snapshot(state, width: 850)
    view.install(next, state: state)
    #expect(guest.layouts == layouts[0])
    #expect(guest.needsLayout)
    #expect(control.layouts == layouts[1] + 1)
    #expect(!control.needsLayout)
    #expect(rn.bounds.size == next.pages["a"]?.size)
  }

  @Test func peekStateUpdatesDoNotLayoutForeignPageOrBackdropSubtrees() {
    let view = PeekOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    var state = PeekOverlayViewTests.state()
    state.reduceMotion = true
    view.apply(state)
    let guests = [FrameLayoutGuest(), FrameLayoutGuest()]
    view.pageSlot.addSubview(guests[0])
    view.backdropSlot.addSubview(guests[1])
    view.layoutSubtreeIfNeeded()
    let layouts = guests.map(\.layouts)
    guests.forEach { $0.needsLayout = true }
    state.title = "Updated title"
    view.apply(state)
    #expect(guests.map(\.layouts) == layouts)
    #expect(guests.allSatisfy { $0.needsLayout })
    #expect(view.pageSlot.bounds.width > 0)
  }

  @Test func changedOverlayGeometryFlushesNativeShareBandControls() throws {
    let state = try fixture()
    let view = PaneOverlaysView(windowId: "frame-isolation")
    let clip = ShareBandClip(frame: .zero)
    defer { view.stop() }
    view.setBand(clip, tabId: "a")
    view.install(try snapshot(state, width: 1000), state: state)
    let control = FrameLayoutGuest()
    clip.bar.addSubview(control)
    clip.layoutSubtreeIfNeeded()
    let layouts = control.layouts
    control.needsLayout = true
    view.install(try snapshot(state, width: 850), state: state)
    #expect(clip.bar.frame.width == clip.bounds.width)
    #expect(control.layouts == layouts + 1)
    #expect(!control.needsLayout)
  }

  @Test func peekResizeFlushesNativeBarControlsWithoutForeignGuests() throws {
    let view = PeekOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    var state = PeekOverlayViewTests.state()
    state.reduceMotion = true
    view.apply(state)
    let bar = try #require(view.pageSlot.superview?.subviews.compactMap { $0 as? PeekBarView }.first)
    let guest = FrameLayoutGuest()
    let control = FrameLayoutGuest()
    view.pageSlot.addSubview(guest)
    bar.addSubview(control)
    view.layoutSubtreeIfNeeded()
    let layouts = [guest.layouts, control.layouts]
    guest.needsLayout = true
    control.needsLayout = true
    view.setFrameSize(CGSize(width: 850, height: 700))
    view.needsLayout = true
    view.layoutNativeContentIfNeeded()
    #expect(guest.layouts == layouts[0])
    #expect(guest.needsLayout)
    #expect(control.layouts == layouts[1] + 1)
    #expect(!control.needsLayout)
    #expect(bar.frame.width == view.pageSlot.superview?.bounds.width)
  }

  @Test func ownedFrameHostsDoNotInstallConstraints() throws {
    let state = try fixture()
    let shell = WindowShellView(windowId: "frame-isolation")
    let panes = SplitPanesView(windowId: "frame-isolation")
    let overlays = PaneOverlaysView(windowId: "frame-isolation")
    let peek = PeekOverlayView(frame: .zero)
    defer { panes.stop(); overlays.stop(); shell.stopLayoutMotion() }
    let placement = try snapshot(state, width: 1000)
    panes.install(placement, state: state)
    overlays.install(placement, state: state)
    let page = try #require(panes.container("a"))
    let rn = try #require(overlays.container("a", layer: .rn))
    let native = try #require(overlays.container("a", layer: .native))
    let hosts = [shell, shell.card, shell.cardPage, shell.cardClip, shell.hiddenPages, shell.overlay,
      panes, page, try #require(page.superview), overlays, rn, native,
      try #require(rn.superview), peek, peek.pageSlot, peek.backdropSlot]
    for host in hosts {
      #expect(!type(of: host).requiresConstraintBasedLayout)
      #expect(host.translatesAutoresizingMaskIntoConstraints)
      #expect(host.constraints.isEmpty)
    }
  }

  @Test func ownedFrameLayoutRetainsReentrantInvalidation() {
    let view = ReinvalidatingFrameView()
    view.needsLayout = true
    view.layoutFrameIfNeeded()
    #expect(view.layouts == 1)
    #expect(view.needsLayout)
    view.layoutFrameIfNeeded()
    #expect(view.layouts == 2)
    #expect(!view.needsLayout)
  }

  @Test func ownedFrameLayoutTracksBoundsMutations() {
    let view = FrameLayoutView(frame: .zero)
    view.layoutFrameIfNeeded()
    #expect(!view.needsLayout)
    view.setFrameSize(CGSize(width: 200, height: 100))
    #expect(view.needsLayout)
    view.layoutFrameIfNeeded()
    #expect(!view.needsLayout)
    view.setBoundsSize(CGSize(width: 100, height: 50))
    #expect(view.needsLayout)
    view.layoutFrameIfNeeded()
    #expect(!view.needsLayout)
    view.setBoundsOrigin(CGPoint(x: 5, y: 7))
    #expect(view.needsLayout)
    view.layoutFrameIfNeeded()
    #expect(!view.needsLayout)
  }

  private func fixture() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"frame-isolation":{"id":"frame-isolation","profileId":"p","sidebarOpen":true,"tabIds":["a"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"frame-isolation","profileId":"p","url":"https://example.test"}}}"#).object ?? [:])
  }

  private func snapshot(_ state: BrowserState, width: CGFloat) throws -> WindowLayoutSnapshot {
    let input = try #require(WindowLayoutInput(state: state, windowId: "frame-isolation", storeRevision: 1,
      bounds: CGRect(x: 0, y: 0, width: width, height: 700),
      pageFacts: ["a": WindowLayoutPageFacts(registration: "page-a", top: 71, band: 38)]))
    return .of(input, generation: 1)
  }
}

@MainActor
private final class FrameLayoutGuest: NSView {
  var layouts = 0
  override func layout() {
    super.layout()
    layouts += 1
  }
}

@MainActor
private final class ReinvalidatingFrameView: FrameLayoutView {
  var layouts = 0
  override func layout() {
    super.layout()
    layouts += 1
    if layouts == 1 { needsLayout = true }
  }
}
