import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarViewportTests {
  static func state(_ total: Int, profile: String = "p") throws -> BrowserState {
    let ids = (0..<total).map { "t\($0)" }
    let tabs = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
      (id, ["id": id, "windowId": "w", "profileId": profile, "url": "https://fixture.test/\(index)", "title": "Tab \(index)"])
    })
    let root: [String: Any] = ["tabs": tabs, "profileOrder": [profile], "windows": ["w": ["id": "w", "profileId": profile, "tabIds": ids, "activeTabIds": [profile: "t0"]]]]
    return try BrowserState(stateJSON: JSONValue.parse(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self)).object ?? [:])
  }

  static func sidebar(_ total: Int, width: CGFloat = 190) throws -> SidebarView {
    let view = SidebarView(windowId: "w", virtualizesRows: true)
    view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
    view.update(state: try state(total), host: SidebarHostState(profileId: "p"))
    view.layoutSubtreeIfNeeded()
    return view
  }

  @Test func fixedViewportRealizesTheSameRowsForTwoHundredAndTwoThousandTabs() throws {
    let small = try Self.sidebar(200)
    let large = try Self.sidebar(2000)
    #expect(small.views.count == large.views.count)
    #expect(large.views.count < 20)
    #expect(large.pageLayout.items.count > 2000)
    #expect(large.views.allSatisfy { key, view in
      guard let item = large.pageLayout.items.first(where: { $0.key == key }) else { return false }
      return item.region != .scroll || view.frame.intersects(large.scroll.contentView.bounds)
    })
  }

  @Test func scrollingRecyclesTheSameAllocationIdentitiesAndClearsOldBindings() throws {
    let view = try Self.sidebar(2000)
    let before = Set(view.views.values.map(ObjectIdentifier.init))
    view.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 3400))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.scroll.contentView)
    #expect(view.views["t:t0"] == nil)
    let after = Set(view.views.values.map(ObjectIdentifier.init))
    #expect(!before.intersection(after).isEmpty)
    #expect(after.count < 20)
    for case let row as SidebarRowView in view.views.values {
      #expect(row.item?.key != "t:t0")
      #expect(!row.retired && !row.hovered && !row.pressed)
      #expect(row.alphaValue == 1)
    }
  }

  @Test func hideAndStopReleaseRowsAndShowRebuildsOnlyTheViewport() throws {
    let view = try Self.sidebar(2000)
    view.isHidden = true
    #expect(view.views.isEmpty)
    view.isHidden = false
    #expect(!view.views.isEmpty && view.views.count < 20)
    view.stop()
    #expect(view.views.isEmpty)
  }
}

@MainActor
@Suite(.serialized)
struct SidebarViewportClipTests {
  @Test func ancestorClipRestrictsRowsAndShrinkingViewportDropsSurplus() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 190, height: 150))
    parent.wantsLayer = true
    parent.layer?.masksToBounds = true
    parent.addSubview(sidebar)
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.views.count < 7)
    parent.frame.size.height = 80
    sidebar.frame.size.height = 80
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.views.count < 5)
  }

  @Test func settledPresentationUsesTheSameCoordinatesAsTheLogicalTarget() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    for item in sidebar.pageLayout.items where sidebar.views[item.key] != nil {
      #expect(sidebar.presentationFrame(item) == sidebar.modelFrame(item))
    }
  }

  #if SOLARA_PROBES
  @Test func realizationProbeMeasuresTheActualBoundCellFrameIndependently() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let row = try #require(sidebar.views["t:t0"])
    row.frame.origin.y += 5
    let report = sidebar.probeRealization()
    let logical = try #require((report["logical"] as? [[String: Any]])?.first { $0["key"] as? String == "t:t0" }?["frame"] as? [CGFloat])
    let actual = try #require((report["bound"] as? [[String: Any]])?.first { $0["key"] as? String == "t:t0" }?["frame"] as? [CGFloat])
    #expect(actual[1] == logical[1] + 5)
  }
  #endif

  @Test func railUsesTheSameViewportBound() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000, width: CGFloat(SidebarRail.width))
    #expect(sidebar.views.count < 20)
    #expect(sidebar.views["t:t1999"] == nil)
  }
}

@MainActor
@Suite(.serialized)
struct SidebarProfileViewportTests {
  @Test func hiddenAndAlmostFullyClippedProfilesHaveNoRowTrees() async throws {
    var state = try SidebarViewportTests.state(2000)
    state.profileOrder = ["p", "q"]
    for index in 1000..<2000 { state.tabs["t\(index)"]?.profileId = "q" }
    state.windows["w"]?.activeTabIds["q"] = "t1000"
    var host = SidebarHostState(profileId: "p")
    host.pages = ["p", "q"].map { SidebarPageLook(profileId: $0, dark: true, theme: [:], border: [], glow: host.glow, tidy: false, incognito: false) }
    let pager = SidebarPagerView(windowId: "w", virtualizesRows: true)
    pager.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    pager.update(state: state, host: host)
    try await Task.sleep(for: .milliseconds(350))
    #expect(pager.subviews.compactMap { $0 as? SidebarView }.count == 1)
    pager.setPagerPosition(0.99)
    let pages = pager.subviews.compactMap { $0 as? SidebarView }
    let outgoing = try #require(pages.first { $0.context?.host.profileId == "p" })
    let incoming = try #require(pages.first { $0.context?.host.profileId == "q" })
    #expect(outgoing.views.isEmpty, "frame=\(outgoing.frame) bounds=\(outgoing.bounds) parent=\(pager.bounds) clip=\(outgoing.effectiveClip) first=\(outgoing.pageLayout.items.first.map { outgoing.modelFrame($0) } as Any) presentation=\(outgoing.pageLayout.items.first.flatMap { outgoing.presentationFrame($0) } as Any)")
    #expect(!incoming.views.isEmpty && incoming.views.count < 20)
    pager.setPagerPosition(1)
    #expect(outgoing.isHidden && outgoing.views.isEmpty)
    pager.setPagerPosition(0)
    #expect(incoming.isHidden && incoming.views.isEmpty)
    #expect(!outgoing.views.isEmpty && outgoing.views.count < 20)
    pager.stop()
    #expect(outgoing.views.isEmpty && incoming.views.isEmpty)
  }

  @Test func selectingTheLastLogicalTabRevealsAndRealizesItInTheSameTurn() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    var next = try SidebarViewportTests.state(2000)
    next.windows["w"]?.activeTabIds["p"] = "t1999"
    sidebar.update(state: next, host: SidebarHostState(profileId: "p"))
    let row = try #require(sidebar.views["t:t1999"] as? SidebarRowView)
    #expect(row.item?.frame.intersects(sidebar.scroll.contentView.bounds) == true)
    #expect(sidebar.views["t:t0"] == nil)
    #expect(sidebar.views.count < 20)
  }
}

#if SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct SidebarReusePlateauTests {
  @Test func repeatedDownAndUpScrollingPlateausAllocationsAndBoundsEveryReuseBin() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    var allocations = Set<String>()
    for _ in 0..<4 {
      for offset: CGFloat in [0, 3400, 19000, 45000, 73000, 45000, 19000, 3400, 0] {
        sidebar.probeScroll(to: offset)
        let report = sidebar.probeRealization()
        let bound = report["bound"] as? [[String: Any]] ?? []
        #expect(bound.count > 0 && bound.count < 20)
        for row in bound { allocations.insert(try #require(row["allocationId"] as? String)) }
        let bins = report["reuse"] as? [[String: Any]] ?? []
        #expect(bins.allSatisfy { ($0["count"] as? Int ?? 100) <= ($0["highWater"] as? Int ?? 0) })
      }
    }
    #expect(allocations.count < 25)
    sidebar.frame.size.height = 80
    sidebar.layoutSubtreeIfNeeded()
    let shrunk = sidebar.probeRealization()["reuse"] as? [[String: Any]] ?? []
    #expect(shrunk.allSatisfy { ($0["highWater"] as? Int ?? 100) < 5 })
    sidebar.stop()
    #expect((sidebar.probeRealization()["reuse"] as? [[String: Any]] ?? []).isEmpty)
  }
}
#endif

@MainActor
@Suite(.serialized)
struct SidebarProfileReturnBindingTests {
  @Test func expandedGroupReturnDropsTheLastCellAfterPlacementMovesItPastTheClip() throws {
    var state = try SidebarViewportTests.state(2000)
    state.groups["g"] = TabGroup(id: "g", windowId: "w", profileId: "p", name: "Group", icon: nil, color: nil, collapsed: true, pinned: false, tabIds: ["t3", "t4", "t5"], createdAt: 1)
    state.tabs["t2"] = nil
    state.windows["w"]?.tabIds.removeAll { $0 == "t2" }
    var look = SidebarHostState(profileId: "p")
    look.addressBar = true
    look.newTabAtTop = true
    for x: CGFloat in [0, 1090] {
      let host = SidebarLayer(frame: CGRect(x: 0, y: 0, width: 1280, height: 744))
      let sidebar = SidebarView(windowId: "w", virtualizesRows: true)
      sidebar.frame = CGRect(x: x, y: 0, width: 190, height: 744)
      host.addSubview(sidebar)
      sidebar.update(state: state, host: look)
      sidebar.layoutSubtreeIfNeeded()
      defer { sidebar.stop() }
      let row = try #require(sidebar.views["t:t19"] as? SidebarRowView)
      #expect(sidebar.presentationRect(of: row) == CGRect(x: 6, y: 660, width: 178, height: 34))
      let stable = try #require(sidebar.views["t:t0"])
      var expanded = state
      expanded.groups["g"]?.collapsed = false
      sidebar.update(state: expanded, host: look)
      let item = try #require(sidebar.pageLayout.items.first { $0.key == "t:t19" })
      #expect(sidebar.modelFrame(item) == CGRect(x: 6, y: 770, width: 178, height: 34))
      #expect(sidebar.regionClip(item) == CGRect(x: 0, y: 5, width: 190, height: 739))
      #expect(sidebar.views[item.key] == nil)
      #expect(row.item == nil && row.superview == nil)
      #expect(sidebar.views["t:t0"] === stable)
    }
  }
}
