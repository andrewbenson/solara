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

  @Test(arguments: [false, true], [190.0, SidebarRail.width])
  func overflowingListSoftensOnlyItsBottom(virtualizesRows: Bool, width: Double) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows, width: width)
    defer { view.stop() }
    let edge = view.bottomEdge
    #expect(!edge.isHidden)
    #expect(edge.isFlipped)
    #expect(edge.state == .followsWindowActiveState)
    #expect(edge.frame == CGRect(x: 0, y: view.clip.bounds.maxY - 28, width: width, height: 28))
    #expect(edge.superview === view.scroll.superview)
    let children = view.clip.subviews
    let edgeIndex = try #require(children.firstIndex(of: edge))
    let scrollIndex = try #require(children.firstIndex(of: view.scroll))
    #expect(edgeIndex > scrollIndex)
    #expect(edge.hitTest(CGPoint(x: width / 2, y: edge.frame.midY)) == nil)
    let mask = try #require(edge.layer?.mask as? CAGradientLayer)
    #expect(mask.frame == edge.bounds)
    #expect(mask.startPoint == CGPoint(x: 0.5, y: 0))
    #expect(mask.endPoint == CGPoint(x: 0.5, y: 1))
    let colors = try #require(mask.colors as? [CGColor])
    #expect(colors.first?.alpha == 0)
    #expect(colors.last?.alpha == 1)
  }

  @Test(arguments: [false, true], [190.0, SidebarRail.width])
  func fittingListHasNoEdge(virtualizesRows: Bool, width: Double) throws {
    let view = try sidebar(1, virtualizesRows: virtualizesRows, width: width)
    defer { view.stop() }
    #expect(view.bottomEdge.isHidden)
  }

  @Test(arguments: [false, true])
  func reachingTheEndClearsTheEdgeAndScrollingBackRestoresIt(virtualizesRows: Bool) throws {
    let view = try sidebar(200, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    let document = try #require(view.scroll.documentView)
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: document.frame.maxY - view.scroll.contentView.bounds.height))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    #expect(view.bottomEdge.isHidden)
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 100))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    #expect(!view.bottomEdge.isHidden)
    #expect(view.clip.convert(view.bottomEdge.frame, to: view).maxY == view.pageLayout.scrollBottom)
  }

  @Test(arguments: [false, true])
  func resizingAndRemovingRowsRecomputesTheEdge(virtualizesRows: Bool) throws {
    let view = try sidebar(20, virtualizesRows: virtualizesRows)
    defer { view.stop() }
    for width in [SidebarRail.width, 260.0, SidebarRail.width] {
      let size = CGSize(width: width, height: 240)
      view.setFrameSize(size)
      #expect(view.frame.size == size, "Requested frame: \(size), actual frame: \(view.frame), bounds: \(view.bounds)")
      view.layoutSubtreeIfNeeded()
      #expect(abs(view.bounds.width - width) <= width.ulp * 16, "Requested width: \(width), frame: \(view.frame), bounds: \(view.bounds)")
      #expect(view.clip.bounds.width == view.bounds.width)
      #expect(view.scroll.frame.width == view.clip.bounds.width)
      #expect(!view.bottomEdge.isHidden)
      #expect(view.bottomEdge.frame.width == view.clip.bounds.width)
      #expect(view.bottomEdge.frame.minX == view.clip.bounds.minX)
      #expect(view.bottomEdge.frame.maxX == view.clip.bounds.maxX)
      #expect(view.clip.convert(view.bottomEdge.frame, to: view).maxY == view.pageLayout.scrollBottom)
      let mask = try #require(view.bottomEdge.layer?.mask as? CAGradientLayer)
      #expect(mask.frame == view.bottomEdge.bounds)
    }
    view.setFrameSize(CGSize(width: view.frame.width, height: 1400))
    view.layoutSubtreeIfNeeded()
    #expect(view.bottomEdge.isHidden)
    view.setFrameSize(CGSize(width: view.frame.width, height: 240))
    view.layoutSubtreeIfNeeded()
    #expect(!view.bottomEdge.isHidden)
    view.update(state: try SidebarViewportTests.state(1), host: SidebarHostState(profileId: "p"))
    #expect(view.bottomEdge.isHidden)
  }

  @Test func profileAppearanceAndTintFollowHostUpdates() throws {
    let view = try sidebar(200, virtualizesRows: false)
    defer { view.stop() }
    var host = SidebarHostState(profileId: "p", dark: false)
    host.theme["backdropTint"] = "#E07040"
    view.updateHost(host)
    #expect(view.bottomEdge.appearance?.name == .aqua)
    let lightTint = try #require(view.bottomEdge.layer?.sublayers?.last?.backgroundColor)
    host.dark = true
    host.theme["backdropTint"] = "#4050D0"
    view.updateHost(host)
    #expect(view.bottomEdge.appearance?.name == .darkAqua)
    let darkTint = try #require(view.bottomEdge.layer?.sublayers?.last?.backgroundColor)
    #expect(lightTint != darkTint)
    #expect(view.bottomEdge.blendingMode == .withinWindow)
  }
}
