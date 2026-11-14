import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct WindowLayoutContractTests {
  @Test func placementKeepsPageAndGuestIdentityAcrossLayoutModes() {
    let shell = WindowShellView(windowId: "contract")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let page = NSView(), sidebar = NSView(), strip = NSView()
    shell.cardPage.addSubview(page)
    shell.mount(.sidebar, sidebar)
    shell.mount(.topStrip, strip)
    #expect(shell.frames.card == CGRect(x: 190, y: 6, width: 803, height: 687))
    #expect(shell.frames.sidebar == CGRect(x: 0, y: 0, width: 190, height: 700))
    shell.update { $0.topTabs = true }
    #expect(sidebar.isHidden)
    #expect(!strip.isHidden)
    #expect(shell.cardPage.subviews.first === page)
    shell.update { $0.fullscreen = true }
    #expect(sidebar.isHidden && strip.isHidden)
    #expect(shell.cardPage.subviews.first === page)
    shell.update { $0.fullscreen = false; $0.topTabs = false; $0.dock = 0 }
    #expect(shell.view(in: .sidebar) === sidebar)
    #expect(shell.view(in: .topStrip) === strip)
    #expect(shell.cardPage.subviews.first === page)
    #expect(shell.subviews.filter { $0 === sidebar }.count == 1)
  }

  private func projectionState() throws -> BrowserState {
    var state = try BrowserState(stateJSON: JSONValue.parse("{\"windows\":{\"w\":{\"id\":\"w\",\"profileId\":\"default\",\"sidebarOpen\":true,\"tabIds\":[\"a\",\"b\",\"c\"],\"activeTabIds\":{\"default\":\"a\"}}},\"tabs\":{\"a\":{\"id\":\"a\",\"windowId\":\"w\",\"profileId\":\"default\"},\"b\":{\"id\":\"b\",\"windowId\":\"w\",\"profileId\":\"default\"},\"c\":{\"id\":\"c\",\"windowId\":\"w\",\"profileId\":\"default\"}}}").object ?? [:])
    state.profiles["default"] = BrowserState.defaultProfile
    state.profileOrder = ["default"]
    return state
  }

  @Test func projectionResolvesDefaultsAndWindowOverrides() throws {
    var state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let first = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(first.profileId == "default" && first.selectedTabId == "a")
    #expect(first.layout.sidebarWidth == 190 && !first.layout.topTabs)
    #expect(WindowLayoutSnapshot.of(first, generation: 1).frames.card == CGRect(x: 190, y: 6, width: 803, height: 687))
    state.settings["tabLayout"] = "top"
    state.settings["sidebarWidth"] = 250
    #expect(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)).layout.topTabs)
    state.windows["w"]?.tabLayout = "sidebar"
    state.windows["w"]?.sidebarWidth = 220
    let overridden = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(!overridden.layout.topTabs && overridden.layout.sidebarWidth == 220)
    #expect(WindowLayoutInput(state: state, windowId: "missing", bounds: bounds) == nil)
  }

  @Test func projectionComputesAddressRailAndTopChrome() throws {
    var state = try projectionState()
    state.settings["addressBar"] = "sidebar"
    state.profileOrder.append("work")
    state.downloads = [Download(json: ["id": "d"])]
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let address = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 1)
    #expect(address.sidebarHeader?.height == 80 && address.sidebarFooter?.height == 41)
    #expect(address.pages["a"]?.minY == address.panes["a"]?.minY)
    state.windows["w"]?.sidebarIconsOnly = true
    let rail = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 2)
    #expect(rail.input.layout.sidebarWidth == CGFloat(SidebarRail.width))
    #expect(!rail.input.layout.addressBarInSidebar)
    #expect(rail.sidebarHeader?.height == 36 && rail.sidebarFooter?.height == 82)
    state.windows["w"]?.tabLayout = "top"
    let top = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 3)
    #expect(top.sidebarHeader == nil && top.frames.topStrip?.height == 42)
    #expect(top.stripAvailableWidth == 1000 - 86 - max(84, StripControlsLayout.width(indicator: StripControlsLayout.indicator(textWidth: top.input.profileNameWidth, incognito: false, profiles: 2).width) + 14))
  }

  @Test func projectionPreservesSplitStackAndNativePresentation() throws {
    var state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for orientation in ["horizontal", "vertical"] {
      state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: orientation, sizes: [0.6, 0.4], stack: SplitStack(index: 0, sizes: [0.3, 0.7]))
      let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
      let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
      let expected = SplitLayout.panes(split: input.split, activeId: "a", fullscreenTab: nil, bounds: snapshot.frames.card)
      #expect(snapshot.panes == expected.panes)
      #expect(snapshot.panes.count == 3)
    }
    let sample = DockedLayoutInput(size: bounds.size, dock: 0.37, peeking: true, peekSlide: 0.6)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: sample))
    #expect(input.layout.dock == 1 && input.presentation.dock == 0.37)
    #expect(WindowLayoutSnapshot.of(input, generation: 2).frames == DockedLayoutFrames.of(sample))
  }

  @Test func projectionClampsSmallBoundsAndKeepsExistingRoundingAtEveryScale() throws {
    let state = try projectionState()
    for size in [CGSize.zero, CGSize(width: 8, height: 9), CGSize(width: 1000.5, height: 700.25)] {
      var snapshots: [WindowLayoutSnapshot] = []
      for scale: CGFloat in [1, 2] {
        let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(origin: .zero, size: size), backingScale: scale))
        let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
        #expect(snapshot.frames.card.width >= 0 && snapshot.frames.card.height >= 0)
        #expect(snapshot.pages.values.allSatisfy { $0.width >= 0 && $0.height >= 0 })
        snapshots.append(snapshot)
      }
      #expect(snapshots[0].frames == snapshots[1].frames)
    }
  }

  @Test func nativePageTopUsesRailFractionAndUnrelatedRevisionKeepsLayout() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let facts = ["a": WindowLayoutPageFacts(registration: "page-1", top: 41)]
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", storeRevision: 1, bounds: bounds, pageFacts: facts))
    let later = try #require(WindowLayoutInput(state: state, windowId: "w", storeRevision: 2, bounds: bounds, pageFacts: facts))
    #expect(input != later && input.hasSameLayout(as: later))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(snapshot.pages["a"]?.minY == snapshot.panes["a"]?.minY)
    #expect(snapshot.logicalFrames == DockedLayoutFrames.of(input.layout))
    let anchors = WindowAnchors(windowId: "w", windowGeneration: 1)
    #expect(anchors.publish(WindowAnchorBatch(snapshot: snapshot)))
    let original = anchors.current
    for _ in 0..<10 { #expect(anchors.current == original) }
    #expect(anchors.current?.generation == 1)
    #expect(anchors.restamp(later))
    #expect(anchors.current?.storeRevision == 2 && anchors.current?.generation == 1)
    #expect(!anchors.restamp(input))
    let resized = try #require(WindowLayoutInput(state: state, windowId: "w", storeRevision: 3, bounds: bounds.insetBy(dx: 1, dy: 0), pageFacts: facts))
    #expect(!anchors.restamp(resized))
    anchors.stop()
    #expect(!anchors.restamp(later))
  }

  @Test func selectedRailToolbarUsesTheWindowBandAndProfileSelectionIsNative() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let first = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 1)
    #expect(first.toolbars["a"] == CGRect(x: 0, y: 0, width: 1000, height: 47))
    #expect(first.toolbars["b"]?.height == 0)
    #expect(first.contentPanes["a"] == CGRect(x: 84, y: 6, width: 451, height: 687))
    #expect(first.contentPanes["b"] == CGRect(x: 542, y: 6, width: 451, height: 687))
    state.windows["w"]?.activeTabIds["default"] = "b"
    let selected = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 2)
    #expect(selected.input.selectedTabId == "b" && selected.panes == first.panes)
    #expect(selected.toolbars["b"] == first.toolbars["a"])
    #expect(selected.toolbars["a"]?.height == 0)
    state.windows["w"]?.profileId = "work"
    state.windows["w"]?.activeTabIds["work"] = "c"
    state.tabs["c"]?.profileId = "work"
    let profile = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(profile.profileId == "work" && profile.selectedTabId == "c" && profile.split == nil)
  }

  @Test func contentAnchorPreservesLegacyPaddingInsideTheVisualRailCard() throws {
    var state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let regular = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 1)
    #expect(regular.content == regular.frames.card)
    state.windows["w"]?.sidebarIconsOnly = true
    for dock: CGFloat in [0, 1] {
      let sample = DockedLayoutInput(size: bounds.size, dock: dock, sidebarWidth: CGFloat(SidebarRail.width), railProgress: 1)
      let rail = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: sample)), generation: 2)
      #expect(rail.frames.card == bounds)
      #expect(rail.content == CGRect(x: dock == 1 ? 84 : 7, y: 6, width: dock == 1 ? 909 : 986, height: 687))
      #expect(rail.anchors["content"] == rail.content)
      #expect(rail.contentPanes["a"] == rail.content)
    }
    state.windows["w"]?.tabLayout = "top"
    let top = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 3)
    #expect(top.content == top.frames.card)
    let fullscreen = DockedLayoutInput(size: bounds.size, dock: 1, fullscreen: true)
    let full = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: fullscreen)), generation: 4)
    #expect(full.content == bounds && full.frames.card == bounds)
  }

  @Test func residualURLBandPreservesTheConsumerContractAcrossRailSplitsAndTopTabs() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    let rail = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 1)
    #expect(rail.residualURLBand(tabId: "a", trailingReservation: 12) == CGRect(x: 229, y: 6, width: 1032, height: 41))
    #expect(rail.frames.page == CGRect(x: 42, y: 47, width: 1231, height: 746))
    state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let split = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 2)
    #expect(split.residualURLBand(tabId: "a", trailingReservation: 68) == CGRect(x: 229, y: 6, width: 378, height: 41))
    #expect(split.residualURLBand(tabId: "b", trailingReservation: 68) == CGRect(x: 792, y: 6, width: 413, height: 41))
    state.splits["s"] = nil
    state.windows["w"]?.tabLayout = "top"
    let top = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 3)
    #expect(top.residualURLBand(tabId: "a", trailingReservation: 12) == CGRect(x: 116, y: 42, width: 1146, height: 41))
    state.windows["w"]?.tabLayout = "sidebar"
    let fullscreen = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, pageFacts: ["a": WindowLayoutPageFacts(fullscreen: true)])), generation: 4)
    #expect(fullscreen.residualURLBand(tabId: "a", trailingReservation: 12) == CGRect(x: 145, y: 0, width: 1123, height: 41))
    state.windows["w"]?.sidebarIconsOnly = false
    state.settings["addressBar"] = "sidebar"
    let address = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 4)
    #expect(address.residualURLBand(tabId: "a", trailingReservation: 12) == nil)
    #expect(address.residualURLBand(tabId: "missing", trailingReservation: 12) == nil)
  }

  @Test func nativeBandsFollowToolbarPresentationWithoutMovingChromeOrContentAnchors() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for fraction: CGFloat in [0, 0.5, 1] {
      let sample = DockedLayoutInput(size: bounds.size, dock: 1, sidebarWidth: CGFloat(SidebarRail.width), railProgress: fraction)
      let baseInput = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: sample, pageFacts: ["a": WindowLayoutPageFacts(top: 41)]))
      let bandInput = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: sample, pageFacts: ["a": WindowLayoutPageFacts(top: 41, band: 38)]))
      #expect(!baseInput.hasSameLayout(as: bandInput))
      let base = WindowLayoutSnapshot.of(baseInput, generation: 1)
      let band = WindowLayoutSnapshot.of(bandInput, generation: 2)
      let pane = try #require(band.panes["a"])
      let page = try #require(band.pages["a"])
      #expect(page.minY == pane.minY + 41 * (1 - fraction) + 38)
      let basePage = try #require(base.pages["a"])
      #expect(page.height == basePage.height - 38)
      #expect(band.frames == base.frames && band.content == base.content && band.toolbars == base.toolbars)
    }
    state.windows["w"]?.sidebarIconsOnly = false
    state.settings["addressBar"] = "sidebar"
    let hidden = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, pageFacts: ["a": WindowLayoutPageFacts(top: 0, band: 38)])), generation: 3)
    #expect(try #require(hidden.pages["a"]).minY == hidden.frames.card.minY + 38)
    let negative = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, pageFacts: ["a": WindowLayoutPageFacts(top: 0, band: -38)])), generation: 4)
    #expect(negative.pages["a"] == negative.panes["a"])
    let small = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 20), pageFacts: ["a": WindowLayoutPageFacts(top: 0, band: 38)])), generation: 5)
    #expect(small.pages["a"]?.height == 0)
    let fullscreen = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, pageFacts: ["a": WindowLayoutPageFacts(fullscreen: true, top: 0, band: 38)])), generation: 6)
    #expect(fullscreen.pages["a"] == bounds)
  }

  @Test func anchorsRejectStaleRevisionGenerationReplacementAndStop() throws {
    let state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: 10, bounds: bounds))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 3)
    let anchors = WindowAnchors(windowId: "w", windowGeneration: 4)
    let batch = WindowAnchorBatch(snapshot: snapshot, anchors: ["url": CGRect(x: 200, y: 6, width: 300, height: 41), "urlField": CGRect(x: 200, y: 11, width: 300, height: 28)])
    #expect(anchors.publish(batch))
    #expect(!anchors.publish(batch))
    #expect(anchors.current?.anchors["url"]?.minY == 6 && anchors.current?.anchors["urlField"]?.minY == 11)
    #expect(!anchors.publish(WindowAnchorBatch(snapshot: .of(input, generation: 2))))
    let stale = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: 9, bounds: bounds))
    #expect(!anchors.publish(WindowAnchorBatch(snapshot: .of(stale, generation: 4))))
    let replacement = WindowAnchors(windowId: "w", windowGeneration: 5)
    #expect(!replacement.publish(batch))
    anchors.stop()
    #expect(anchors.current == nil)
    #expect(!anchors.publish(WindowAnchorBatch(snapshot: .of(input, generation: 5))))
  }

  @Test func endpointComparisonRequiresEveryAnchorAndHonorsHalfPointThreshold() throws {
    let input = try #require(WindowLayoutInput(state: projectionState(), windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700)))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(snapshot.endpointError(observed: [:], names: ["card"]) == nil)
    #expect(snapshot.endpointError(observed: ["card": snapshot.frames.card.offsetBy(dx: 0.5, dy: 0)], names: ["card"]) == 0.5)
    #expect(try #require(snapshot.endpointError(observed: ["card": snapshot.frames.card.offsetBy(dx: 0.501, dy: 0)], names: ["card"])) > 0.5)
  }

  #if SOLARA_PROBES
  private final class LinkTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {}
  }

  @Test func activeLinkGaugeFollowsPauseResumeResetAndInvalidation() {
    let view = NSView(), target = LinkTarget()
    let link = view.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
    let baseline = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? -1
    NativeWorkCounters.link(link)
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline + 1)
    link.isPaused = true
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
    NativeWorkCounters.reset()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
    link.isPaused = false
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline + 1)
    NativeWorkCounters.unlink(link)
    link.invalidate()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
  }

  @Test func resetPreservesLiveIdentityAndAggregatesEveryScope() throws {
    NativeWorkCounters.reset()
    let first = NSView(), second = NSView()
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    NativeWorkCounters.bind(second, windowId: "counter-b", profileId: "q", kind: "tile")
    let before = NativeWorkCounters.snapshot()
    #expect(before["version"] as? Int == 1)
    let rows = try #require(before["rows"] as? [String: Int])
    #expect(rows["created"] == 2)
    #expect(rows["bound"] == 3)
    #expect(rows["reused"] == 1)
    let groups = try #require(before["groups"] as? [[String: Any]])
    for field in ["created", "bound", "reused", "live"] {
      #expect(groups.reduce(0) { $0 + ($1[field] as? Int ?? -1) } == rows[field])
    }
    NativeWorkCounters.reset()
    let after = try #require(NativeWorkCounters.snapshot()["rows"] as? [String: Int])
    #expect(after["created"] == 0 && after["bound"] == 0 && after["reused"] == 0)
    #expect(after["live"] == rows["live"])
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    #expect((NativeWorkCounters.snapshot()["rows"] as? [String: Int])?["reused"] == 1)
  }

  @Test func liveRowsIncludeDetachedObjectsAndDisappearAtDeallocation() throws {
    NativeWorkCounters.reset()
    var view: NSView? = NSView()
    NativeWorkCounters.bind(view!, windowId: "detached", profileId: "p", kind: "tab")
    func count() -> Int {
      (NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == "detached" }?["live"] as? Int ?? 0
    }
    #expect(count() == 1)
    NativeWorkCounters.reset()
    #expect(count() == 1)
    view = nil
    #expect(count() == 0)
  }

  @Test func fixedViewportCurrentlyCreatesEverySidebarRow() throws {
    for total in [200, 2000] {
      NativeWorkCounters.reset()
      let windowId = "eager-\(total)"
      let tabs = (0..<total).map { "\"t\($0)\":{\"id\":\"t\($0)\",\"windowId\":\"\(windowId)\",\"profileId\":\"p\",\"url\":\"https://fixture.test/\($0)\",\"title\":\"Tab \($0)\"}" }.joined(separator: ",")
      let ids = (0..<total).map { "\"t\($0)\"" }.joined(separator: ",")
      let json = "{\"windows\":{\"\(windowId)\":{\"id\":\"\(windowId)\",\"profileId\":\"p\",\"tabIds\":[\(ids)],\"activeTabIds\":{\"p\":\"t0\"}}},\"tabs\":{\(tabs)}}"
      let state = try BrowserState(stateJSON: try JSONValue.parse(json).object ?? [:])
      let sidebar = SidebarView(windowId: windowId)
      sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      let group = try #require((NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == windowId && $0["kind"] as? String == "sidebar.tab.full" })
      #expect(group["created"] as? Int == total)
      #expect(group["live"] as? Int == total)
      #expect(sidebar.pageLayout.items.filter { if case .tab = $0.kind { true } else { false } }.count == total)
      let views = sidebar.views
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      #expect(views.allSatisfy { sidebar.views[$0.key] === $0.value })
      #expect(sidebar.pageLayout.docked)
    }
  }
  #endif
}
