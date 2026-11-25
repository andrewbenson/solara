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

  @Test(arguments: [false, true])
  func closedRightSidebarPreservesItsSideAndHiddenFrame(rail: Bool) throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarOpen = false
    state.windows["w"]?.sidebarPosition = "right"
    state.windows["w"]?.sidebarIconsOnly = rail
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let presentation = DockedLayoutInput(size: bounds.size, dock: 0, away: true)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: presentation))
    #expect(input.layout.sidebarSide == .right)
    #expect(input.presentation.sidebarSide == .right)
    #expect(input.layout.dock == 0 && input.presentation.dock == 0)
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(try #require(snapshot.anchors["sidebar"]).minX >= 1000)
    #expect(snapshot.frames.sidebarShift > 0)
    let legacy = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, sidebarPositionAllowed: false))
    #expect(legacy.layout.sidebarSide == .left && legacy.presentation.sidebarSide == .left)
    state.windows["w"]?.tabLayout = "top"
    let top = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(top.layout.sidebarSide == .left && top.presentation.sidebarSide == .left)
    #expect(WindowLayoutSnapshot.of(top, generation: 2).frames.sidebar == nil)
  }

  @Test func topTabsClosedMovesTheStripAboveTheWindow() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    state.windows["w"]?.sidebarOpen = false
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700)))
    #expect(input.layout.dock == 0)
    #expect(input.presentation.dock == 0)
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(try #require(snapshot.frames.topStrip).maxY <= 0)
    #expect(snapshot.frames.card.minY == ShellMetrics.cardTop)
    #expect(snapshot.toolbars["a"]?.minY == ShellMetrics.cardTop)
  }

  @Test func topTabsPreservesDockMotionAndResetsOnlySidebarPeekAndRail() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    state.windows["w"]?.sidebarOpen = false
    var presentation = DockedLayoutInput(size: .zero, dock: 0.37, peeking: true, peekSlide: 0.6, away: true)
    presentation.railProgress = 0.8
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), presentation: presentation))
    #expect(input.layout.dock == 0)
    #expect(input.presentation.dock == 0.37)
    #expect(input.presentation.away)
    #expect(!input.presentation.peeking)
    #expect(input.presentation.peekSlide == 0)
    #expect(input.presentation.railProgress == nil)
  }

  @Test func topTabsOpenKeepsTheStripDocked() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700)))
    #expect(input.layout.dock == 1)
    #expect(input.presentation.dock == 1)
    #expect(WindowLayoutSnapshot.of(input, generation: 1).frames.topStrip?.minY == 0)
  }

  @Test(arguments: [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 6, height: 6),
    CGSize(width: 7, height: 7), CGSize(width: 31, height: 31), CGSize(width: 32, height: 32),
    CGSize(width: 41, height: 41), CGSize(width: 42, height: 42), CGSize(width: 83, height: 47),
    CGSize(width: 84, height: 48), CGSize(width: 160, height: 100)])
  func smallWindowsKeepPageAndToolbarExtentsNonnegative(size: CGSize) throws {
    for (layout, rail) in [("sidebar", false), ("sidebar", true), ("top", false)] {
      for fullscreen in [false, true] {
        for address in ["toolbar", "sidebar"] {
          var state = try projectionState()
          state.windows["w"]?.tabLayout = layout
          state.windows["w"]?.sidebarIconsOnly = rail
          state.settings["addressBar"] = JSONValue.string(address)
          for panel: CGFloat in [0, 300] {
            for dock: CGFloat in [0, 0.5, 1] {
              let presentation = DockedLayoutInput(size: size, dock: dock, sidebarWidth: rail ? 42 : 190,
                peeking: true, peekSlide: 0.5, sidePanel: panel, railProgress: rail ? dock : 0)
              let input = try #require(WindowLayoutInput(state: state, windowId: "w",
                bounds: CGRect(origin: .zero, size: size), presentation: presentation, windowFullscreen: fullscreen))
              let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
              let band = snapshot.residualURLBand(tabId: "a", trailingReservation: 84)
              let rects = Array(snapshot.anchors.values) + Array(snapshot.pages.values)
                + Array(snapshot.pageViewports.values) + Array(snapshot.toolbars.values) + [band].compactMap { $0 }
              #expect(rects.allSatisfy {
                $0.origin.x.isFinite && $0.origin.y.isFinite && $0.size.width.isFinite && $0.size.height.isFinite
                  && $0.size.width >= 0 && $0.size.height >= 0
              })
              #expect(snapshot.stripAvailableWidth >= 0)
              #expect(input.stripProfileSlotWidth == 0)
              if size.width == 0 { #expect(snapshot.stripAvailableWidth == 0) }
            }
          }
        }
      }
    }
  }

  @Test func projectionResolvesDefaultsAndWindowOverrides() throws {
    var state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let first = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(first.profileId == "default" && first.selectedTabId == "a")
    #expect(WindowLayoutSnapshot.of(first, generation: 1).anchors["window"] == bounds)
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
    #expect(address.sidebarHeader?.height == 80 && address.sidebarFooter?.height == 40)
    #expect(address.sidebarHeader == CGRect(x: 0, y: 0, width: 190, height: 80))
    #expect(address.pages["a"]?.minY == address.panes["a"]?.minY)
    state.windows["w"]?.sidebarIconsOnly = true
    let rail = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 2)
    #expect(rail.input.layout.sidebarWidth == CGFloat(SidebarRail.width))
    #expect(!rail.input.layout.addressBarInSidebar)
    #expect(rail.sidebarHeader?.height == 0 && rail.sidebarFooter?.height == 80)
    state.windows["w"]?.tabLayout = "top"
    let top = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 3)
    #expect(top.sidebarHeader == nil && top.frames.topStrip?.height == 42)
    #expect(top.stripAvailableWidth == 1000 - 86 - top.input.stripProfileSlotWidth - 84)
  }

  @Test(arguments: [false, true], [false, true])
  func railHeaderStartsBelowTheToolbarBand(fullscreen: Bool, incognito: Bool) throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    state.windows["w"]?.incognito = incognito
    let input = try #require(WindowLayoutInput(state: state, windowId: "w",
      bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), windowFullscreen: fullscreen))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    let sidebar = try #require(snapshot.frames.sidebar)
    let top: CGFloat = fullscreen ? 47 : 32
    #expect(snapshot.sidebarHeader == CGRect(x: sidebar.minX, y: sidebar.minY + top,
      width: sidebar.width, height: incognito ? SidebarChromeMetrics.railHeader : 0))
    if !fullscreen && !incognito {
      #expect(snapshot.sidebarHeader == CGRect(x: 0, y: 32, width: 42, height: 0))
    }
  }

  @Test func savedWidthsUseTheRailThatTheSidebarDraws() throws {
    var state = try projectionState()
    state.settings["addressBar"] = "sidebar"
    state.settings["sidebarIconsOnly"] = true
    state.windows["w"]?.sidebarIconsOnly = false
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for (width, rail) in [(42.0, true), (42.5, true), (42.5001, false), (84.0, false), (240.0, false)] {
      state.windows["w"]?.sidebarWidth = width
      let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
      #expect(input.layout.addressBarInSidebar == !rail)
      #expect(input.layout.sidebarWidth == CGFloat(rail ? 42 : width))
      #expect(input.sidebarHeaderHeight == (rail ? 0 : 80))
      state.windows["w"]?.sidebarOpen = false
      let hidden = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
      #expect(hidden.layout.addressBarInSidebar)
      state.windows["w"]?.sidebarOpen = true
    }
  }

  @Test func horizontalProfileSlotProtectsTheFullscreenIslandOnlyWhenANameShows() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    state.profiles["default"]?.name = "A"
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for fullscreen in [false, true] {
      let hidden = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, stripProfileWidth: 8, windowFullscreen: fullscreen))
      #expect(hidden.stripProfileSlotWidth == 0)
      #expect(WindowLayoutSnapshot.of(hidden, generation: 1).stripAvailableWidth == (fullscreen ? 908 : 830))
      state.profileOrder.append("work")
      let shown = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, stripProfileWidth: 8, windowFullscreen: fullscreen))
      #expect(shown.stripProfileSlotWidth == (fullscreen ? 84 : 34))
      #expect(WindowLayoutSnapshot.of(shown, generation: 1).stripAvailableWidth == (fullscreen ? 824 : 796))
      state.profileOrder.removeLast()
    }
  }

  @Test func aSpacesChangeMovesTheProfileWithoutAStoreRevision() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    state.profileOrder.append("work")
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let windowed = try #require(WindowLayoutInput(state: state, windowId: "w", storeRevision: 1, bounds: bounds, stripProfileWidth: 8, windowFullscreen: false))
    let fullscreen = try #require(WindowLayoutInput(state: state, windowId: "w", storeRevision: 1, bounds: bounds, stripProfileWidth: 8, windowFullscreen: true))
    #expect(!windowed.hasSameLayout(as: fullscreen))
    #expect(WindowLayoutSnapshot.of(windowed, generation: 1).stripAvailableWidth == 796)
    #expect(WindowLayoutSnapshot.of(fullscreen, generation: 2).stripAvailableWidth == 824)
  }

  @Test func horizontalNameGivesItsRoomToTheMinimumTabBeforeTruncatingTheStrip() throws {
    var state = try projectionState()
    state.windows["w"]?.tabLayout = "top"
    state.profileOrder.append("work")
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, stripProfileWidth: 300))
    #expect(input.stripProfileSlotWidth == 134)
    #expect(WindowLayoutSnapshot.of(input, generation: 1).stripAvailableWidth == 96)
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
    #expect(first.toolbars["a"] == CGRect(x: 0, y: 0, width: 1000, height: 32))
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
      #expect(rail.frames.card == CGRect(x: dock == 1 ? 42 : 7, y: 0, width: dock == 1 ? 951 : 986, height: 693))
      #expect(rail.content == CGRect(x: dock == 1 ? 84 : 7, y: 6, width: dock == 1 ? 909 : 986, height: 687))
      #expect(rail.anchors["content"] == rail.content)
      #expect(rail.contentPanes["a"] == rail.content)
    }
    state.windows["w"]?.tabLayout = "top"
    let top = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 3)
    #expect(top.content == top.frames.card)
    let fullscreen = DockedLayoutInput(size: bounds.size, dock: 1, fullscreen: true)
    let full = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: fullscreen, pageFacts: ["a": WindowLayoutPageFacts(fullscreen: true)])), generation: 4)
    #expect(full.content == bounds && full.frames.card == bounds)
  }

  @Test func railURLBandFollowsThePresentedToolbarAsItSpansTheWindow() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for progress: CGFloat in [0.25, 0.5, 0.75, 1] {
      let presentation = DockedLayoutInput(size: bounds.size, dock: 1, sidebarWidth: 190 + (42 - 190) * progress, railProgress: progress)
      let snapshot = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: presentation)), generation: 1)
      let row = try #require(snapshot.toolbars["a"])
      let band = try #require(snapshot.residualURLBand(tabId: "a", trailingReservation: 12))
      #expect(band.maxX == bounds.maxX - 12 - ShellMetrics.cardInset * (1 - progress))
      #expect(band.minX >= ShellMetrics.railToolbarLeadingInset + ShellMetrics.breadcrumbX - 8)
      #expect(band.minY == row.minY && band.height == row.height)
      if progress == 0.5 { #expect(band == CGRect(x: 236, y: 3, width: 748.5, height: 36.5)) }
      if progress == 1 { #expect(band == CGRect(x: 236, y: 0, width: 752, height: 32)) }
      state.windows["w"]?.activeTabIds["default"] = "b"
      let selected = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, presentation: presentation)), generation: 2)
      #expect(selected.residualURLBand(tabId: "b", trailingReservation: 12) == band)
      state.windows["w"]?.activeTabIds["default"] = "a"
    }
  }

  @Test func residualURLBandPreservesTheConsumerContractAcrossRailSplitsAndTopTabs() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarIconsOnly = true
    let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    let rail = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 1)
    #expect(rail.residualURLBand(tabId: "a", trailingReservation: 12) == CGRect(x: 236, y: 0, width: 1032, height: 32))
    #expect(rail.frames.page == CGRect(x: 42, y: 32, width: 1231, height: 761))
    state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    let split = WindowLayoutSnapshot.of(try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds)), generation: 2)
    #expect(split.residualURLBand(tabId: "a", trailingReservation: 68) == CGRect(x: 236, y: 0, width: 976, height: 32))
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

  @Test func fullscreenURLBandFollowsTheIslandsLiveReservation() throws {
    var state = try projectionState()
    state.windows["w"]?.sidebarOpen = false
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds, windowFullscreen: true))
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    let resting = try #require(snapshot.residualURLBand(tabId: "a", trailingReservation: 12))
    for reveal: CGFloat in [0, 0.5, 1, 0] {
      let inset = input.layout.trafficLightsLeadingInset(at: snapshot.frames.card.minX, reveal: reveal)
      let band = try #require(snapshot.residualURLBand(tabId: "a", trailingReservation: 12, trafficLightsInset: inset))
      #expect(band.minX == resting.minX + inset)
      #expect(band.maxX == resting.maxX)
    }
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

  @Test func guestAnchorPublicationsIgnoreTourMotionAndRevisionOnlyChanges() throws {
    let state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let input = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: 10, bounds: bounds))
    let first = WindowAnchorBatch(snapshot: .of(input, generation: 1), anchors: ["tour:tabs": CGRect(x: 10, y: 100, width: 170, height: 30)])
    let restamped = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: 11, bounds: bounds))
    let moved = WindowAnchorBatch(snapshot: .of(restamped, generation: 2), anchors: ["tour:tabs": CGRect(x: 10, y: 50, width: 170, height: 30)])
    #expect(first.hasSameGuestProjection(as: moved))
    #expect(moved.anchors["tour:tabs"]?.minY == 50)
    let resized = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: 12, bounds: bounds.insetBy(dx: 1, dy: 0)))
    #expect(!first.hasSameGuestProjection(as: WindowAnchorBatch(snapshot: .of(resized, generation: 3))))
    let url = WindowAnchorBatch(snapshot: .of(restamped, generation: 3), anchors: ["url": CGRect(x: 200, y: 6, width: 300, height: 41)])
    #expect(!first.hasSameGuestProjection(as: url))
    let peek = WindowAnchorBatch(snapshot: .of(restamped, generation: 3), anchors: ["peekPopover:zoom": CGRect(x: 700, y: 8, width: 236, height: 0)])
    #expect(!first.hasSameGuestProjection(as: peek))
    var switched = state
    switched.windows["w"]?.activeTabIds["default"] = "b"
    let selected = try #require(WindowLayoutInput(state: switched, windowId: "w", windowGeneration: 4, storeRevision: 12, bounds: bounds))
    #expect(first.hasSameGuestProjection(as: WindowAnchorBatch(snapshot: .of(selected, generation: 3))))
  }

  @Test func guestAnchorCallsWaitForReplacementToolbarStateAcrossTabActions() throws {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    for reservation: CGFloat in [12, 46] {
      for (action, count) in [("open", 20), ("close", 20), ("switchTabs", 13)] {
        var state = try projectionState()
        let input = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, bounds: bounds))
        let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
        let url = try #require(snapshot.residualURLBand(tabId: "a", trailingReservation: reservation))
        var sent = WindowAnchorBatch(snapshot: snapshot, anchors: ["url": url])
        var calls = 0
        for step in 0..<count {
          let tabId = step.isMultiple(of: 2) ? "b" : "a"
          state.windows["w"]?.activeTabIds["default"] = tabId
          let next = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: step + 1, bounds: bounds))
          let snapshot = WindowLayoutSnapshot.of(next, generation: UInt64(step + 2))
          let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 803, height: 41))
          func publish(_ batch: WindowAnchorBatch, toolbarReady: Bool? = nil) {
            let ready = toolbarReady ?? (toolbar.state != nil && toolbar.window != nil && toolbar.window === window)
            if batch.shouldSendGuestProjection(after: sent, toolbarReady: ready) { calls += 1; sent = batch }
          }
          publish(WindowAnchorBatch(snapshot: snapshot))
          window.contentView = toolbar
          let pending = WindowAnchorBatch(snapshot: snapshot, anchors: ["url": try #require(snapshot.residualURLBand(tabId: tabId, trailingReservation: CGFloat(toolbar.state?.geometry.urlRight ?? 12)))])
          let pendingReady = toolbar.state != nil && toolbar.window != nil && toolbar.window === window
          publish(pending, toolbarReady: pendingReady)
          window.contentView = nil
          var toolbarState = ToolbarWebKitPillTests.state(extensions: "")
          toolbarState.geometry.urlRight = Double(reservation)
          toolbar.update(toolbarState)
          publish(WindowAnchorBatch(snapshot: snapshot))
          window.contentView = toolbar
          publish(pending, toolbarReady: pendingReady)
          publish(WindowAnchorBatch(snapshot: snapshot, anchors: ["url": try #require(snapshot.residualURLBand(tabId: tabId, trailingReservation: CGFloat(toolbar.state?.geometry.urlRight ?? 12)))]))
        }
        #expect(calls == 0, "\(action) sent \(calls) redundant guest anchor calls")
        let changed = WindowAnchorBatch(snapshot: snapshot, anchors: ["url": url.insetBy(dx: 1, dy: 0)])
        #expect(!changed.shouldSendGuestProjection(after: sent, toolbarReady: false))
        #expect(changed.shouldSendGuestProjection(after: sent, toolbarReady: true))
        #expect(!changed.shouldSendGuestProjection(after: changed, toolbarReady: true))
        #expect(!sent.shouldSendGuestProjection(after: nil, toolbarReady: false))
        #expect(sent.shouldSendGuestProjection(after: nil, toolbarReady: true))
        let resizedInput = try #require(WindowLayoutInput(state: state, windowId: "w", windowGeneration: 4, storeRevision: count + 1, bounds: bounds.insetBy(dx: 10, dy: 0)))
        let resized = WindowAnchorBatch(snapshot: .of(resizedInput, generation: UInt64(count + 2)), anchors: ["url": url])
        #expect(!resized.shouldSendGuestProjection(after: sent, toolbarReady: false))
        #expect(resized.shouldSendGuestProjection(after: sent, toolbarReady: true))
        #expect(!resized.shouldSendGuestProjection(after: resized, toolbarReady: true))
      }
    }
  }

  @Test func guestAnchorCallsDoNotWaitForAToolbarInSidebarOrEmptyWindows() throws {
    var state = try projectionState()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    state.settings["addressBar"] = "sidebar"
    let sidebar = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(WindowAnchorBatch(snapshot: .of(sidebar, generation: 1)).shouldSendGuestProjection(after: nil, toolbarReady: false))
    state.settings["addressBar"] = "toolbar"
    state.windows["w"]?.activeTabIds = [:]
    let empty = try #require(WindowLayoutInput(state: state, windowId: "w", bounds: bounds))
    #expect(WindowAnchorBatch(snapshot: .of(empty, generation: 1)).shouldSendGuestProjection(after: nil, toolbarReady: false))
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

  @Test func fixedViewportCreatesOnlyVisibleSidebarRows() throws {
    for total in [200, 2000] {
      NativeWorkCounters.reset()
      let windowId = "eager-\(total)"
      let tabs = (0..<total).map { "\"t\($0)\":{\"id\":\"t\($0)\",\"windowId\":\"\(windowId)\",\"profileId\":\"p\",\"url\":\"https://fixture.test/\($0)\",\"title\":\"Tab \($0)\"}" }.joined(separator: ",")
      let ids = (0..<total).map { "\"t\($0)\"" }.joined(separator: ",")
      let json = "{\"windows\":{\"\(windowId)\":{\"id\":\"\(windowId)\",\"profileId\":\"p\",\"tabIds\":[\(ids)],\"activeTabIds\":{\"p\":\"t0\"}}},\"tabs\":{\(tabs)}}"
      let state = try BrowserState(stateJSON: try JSONValue.parse(json).object ?? [:])
      let sidebar = SidebarView(windowId: windowId, virtualizesRows: true)
      sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      let group = try #require((NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == windowId && $0["kind"] as? String == "sidebar.tab.full" })
      let realized = sidebar.views.values.filter { $0 is TabRowView }.count
      #expect(realized > 0 && realized < 20)
      #expect(group["created"] as? Int == realized)
      #expect(group["live"] as? Int == realized)
      #expect(sidebar.pageLayout.items.filter { if case .tab = $0.kind { true } else { false } }.count == total)
      let views = sidebar.views
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      #expect(views.allSatisfy { sidebar.views[$0.key] === $0.value })
      #expect(sidebar.pageLayout.docked)
    }
  }
  #endif
}
