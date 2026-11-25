import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct FullScreenLayoutMatrixTests {
  enum Layout: String, CaseIterable, Sendable {
    case top, topN, sideT, sideTn, sideS, icon, right, rightN, rightS, rightI, hiddenT, hiddenS

    var topTabs: Bool { self == .top || self == .topN }
    var named: Bool { self == .sideT || self == .top || self == .right }
    var icons: Bool { self == .icon || self == .rightI }
    var hidden: Bool { self == .hiddenT || self == .hiddenS }
    var rightSidebar: Bool { self == .right || self == .rightN || self == .rightS || self == .rightI }
    var sidebarAddress: Bool { self == .sideS || self == .rightS || self == .hiddenS }
    var leftSidebar: Bool { self == .sideT || self == .sideTn || self == .sideS }
    var reservesCaption: Bool { icons || hidden || rightSidebar }
  }

  enum Presentation: String, CaseIterable, Sendable {
    case win, ar, at, nr, nt

    var fullscreen: Bool { self != .win }
    var revealed: Bool { self == .at || self == .nt }
    var menuBottom: CGFloat { self == .ar || self == .at ? 26 : 0 }
    var offset: CGFloat { self == .at ? menuBottom : 0 }
  }

  struct Case: Sendable, CustomStringConvertible {
    let layout: Layout
    let presentation: Presentation
    var description: String { "\(layout.rawValue)/\(presentation.rawValue)" }
    var scrims: Int {
      guard presentation.revealed else { return 0 }
      if layout == .topN { return 1 }
      return layout.leftSidebar && presentation == .at ? 2 : 0
    }
  }

  nonisolated static var cases: [Case] {
    Layout.allCases.flatMap { layout in Presentation.allCases.map { Case(layout: layout, presentation: $0) } }
  }

  private func makeState(_ layout: Layout) throws -> BrowserState {
    var state = try BrowserState(stateJSON: JSONValue.parse(#"""
      {"profileOrder":["default"],"windowOrder":["matrix"],
       "windows":{"matrix":{"id":"matrix","profileId":"default","sidebarOpen":true,"tabIds":["a","b","c"],"activeTabIds":{"default":"a"}}},
       "tabs":{"a":{"id":"a","windowId":"matrix","profileId":"default","url":"https://a.example/","title":"A"},
               "b":{"id":"b","windowId":"matrix","profileId":"default","url":"https://b.example/","title":"B"},
               "c":{"id":"c","windowId":"matrix","profileId":"default","url":"https://c.example/","title":"C"}}}
      """#).object ?? [:])
    state.profiles["default"] = BrowserState.defaultProfile
    if layout.named { state.profileOrder.append("work") }
    state.settings["tabLayout"] = layout.topTabs ? "top" : "sidebar"
    state.settings["sidebarIconsOnly"] = .bool(layout.icons)
    state.settings["sidebarPosition"] = layout.rightSidebar ? "right" : "left"
    state.settings["addressBar"] = layout.sidebarAddress ? "sidebar" : "toolbar"
    state.settings["bookmarksBar"] = "never"
    state.windows["matrix"]?.sidebarOpen = !layout.hidden
    return state
  }

  private func toolbarState(sidebarButton: Bool) throws -> ToolbarState {
    let geometry = ToolbarGeometry.of(sidebarButton: sidebarButton)
    let buttons = sidebarButton ? #"{"id":"sidebar","icon":"sidebar.left"},"# : ""
    let json = """
      {"tabId":"a","height":41,"bare":false,"focused":true,"windowToolbar":true,
       "palette":\(ToolbarWebKitPillTests.palette),"accent":"#80506A",
       "geometry":{"back":\(geometry.back),"forward":\(geometry.forward),"reload":\(geometry.reload),"urlLeft":\(geometry.urlLeft),"urlRight":8},
       "left":[\(buttons){"id":"back","icon":"chevron.left"},{"id":"forward","icon":"chevron.right"},{"id":"reload","icon":"arrow.clockwise"}],
       "url":{"host":"example.com","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false},"right":[],"rightInset":8,"hairline":false}
      """
    var decoded = try #require(ToolbarState.decode(json))
    decoded.geometry.sidebarButton = geometry.sidebarButton.map(Double.init)
    return decoded
  }

  private func addressState() throws -> SidebarAddressBarState {
    let json = """
      {"palette":\(ToolbarWebKitPillTests.palette),"accent":"#80506A",
       "look":{"resting":"#FFFFFF40","stroke":"#00000010","hover":"#FFFFFF60","placeholder":"#00000060","prompt":"#00000080"},
       "buttons":[{"id":"sidebar","icon":"sidebar.left"},{"id":"back","icon":"chevron.left"},{"id":"forward","icon":"chevron.right"},{"id":"reload","icon":"arrow.clockwise"}],
       "url":{"host":"example.com","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false},"extensions":[]}
      """
    return try #require(SidebarAddressBarState.decode(json))
  }

  private func buttonFrames(in view: NSView, to root: NSView, presented: Bool) -> [String: CGRect] {
    Dictionary(uniqueKeysWithValues: ToolbarWebKitPillTests.buttons(in: view).filter { !$0.isHiddenOrHasHiddenAncestor }.map {
      ($0.state.id, presented ? $0.fullScreenRect($0.bounds, to: root) : $0.convert($0.bounds, to: root))
    })
  }

  @Test func independentSettingsResolveToTheTwelveMatrixRows() throws {
    var resolved: Set<Layout> = []
    for top in [false, true] {
      for mode in 0...2 {
        for right in [false, true] {
          for address in [false, true] {
            for name in [false, true] {
              let layout: Layout
              if top { layout = name ? .top : .topN }
              else if mode == 2 { layout = address ? .hiddenS : .hiddenT }
              else if mode == 1 { layout = right ? .rightI : .icon }
              else if address { layout = right ? .rightS : .sideS }
              else if right { layout = name ? .right : .rightN }
              else { layout = name ? .sideT : .sideTn }
              resolved.insert(layout)
              var state = try makeState(layout)
              state.profileOrder = name ? ["default", "work"] : ["default"]
              state.settings["tabLayout"] = top ? "top" : "sidebar"
              state.settings["sidebarIconsOnly"] = .bool(mode == 1)
              state.settings["sidebarPosition"] = right ? "right" : "left"
              state.settings["addressBar"] = address ? "sidebar" : "toolbar"
              state.windows["matrix"]?.sidebarOpen = mode != 2
              let input = try #require(WindowLayoutInput(state: state, windowId: "matrix", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700)))
              #expect(input.layout.topTabs == layout.topTabs)
              #expect(input.layout.addressBarInSidebar == layout.sidebarAddress)
              let actualName = input.profileCount > 1 && (input.layout.topTabs
                || input.layout.dock > 0 && !SidebarRail.contains(width: Double(input.layout.sidebarWidth)) && !input.layout.addressBarInSidebar)
              #expect(actualName == layout.named)
              #expect((input.layout.sidebarSide == .right) == (!top && right))
              if top { #expect(input.layout.dock == (mode == 2 ? 0 : 1)) }
              if !top {
                #expect((input.layout.dock == 0) == layout.hidden)
                #expect((input.layout.sidebarSide == .right) == (!top && right))
                #expect(SidebarRail.contains(width: Double(input.layout.sidebarWidth)) == layout.icons)
              }
            }
          }
        }
      }
    }
    #expect(resolved == Set(Layout.allCases))
    #expect(resolved.count * Presentation.allCases.count == 60)
  }

  @Test(arguments: [false, true]) func hiddenSidebarAddressIgnoresItsRememberedIconMode(_ icons: Bool) throws {
    var state = try makeState(.hiddenS)
    state.settings["sidebarIconsOnly"] = .bool(icons)
    state.settings["sidebarPosition"] = "right"
    let input = try #require(WindowLayoutInput(state: state, windowId: "matrix", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700)))
    #expect(input.layout.chromeNavigationRow)
    #expect(input.layout.sidebarSide == .right)
    #expect(input.layout.inset.top == ShellMetrics.cardTop + ShellMetrics.toolbarHeight)
  }

  @Test(arguments: [false, true]) func horizontalTabsPreserveHiddenDockAndDiscardSidebarPeekPresentation(_ named: Bool) throws {
    var state = try makeState(named ? .top : .topN)
    state.windows["matrix"]?.sidebarOpen = false
    state.settings["sidebarIconsOnly"] = .bool(true)
    state.settings["sidebarPosition"] = "right"
    state.settings["addressBar"] = "sidebar"
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let stale = DockedLayoutInput(size: bounds.size, dock: 0, sidebarWidth: 42, peeking: true,
      peekSlide: 0.5, addressBarInSidebar: true, away: true, railProgress: 1, sidebarSide: .right)
    let input = try #require(WindowLayoutInput(state: state, windowId: "matrix", bounds: bounds, presentation: stale))
    #expect(input.layout.dock == 0 && input.presentation.dock == 0)
    #expect(!input.presentation.peeking && input.presentation.away)
    #expect(input.presentation.peekSlide == 0 && input.presentation.railProgress == nil)
    #expect(input.presentation.sidebarSide == .left && !input.presentation.addressBarInSidebar)
    let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
    #expect(snapshot.frames.topStrip == CGRect(x: 0, y: -42, width: 1000, height: 42))
    #expect(snapshot.frames.card.minY == ShellMetrics.cardTop)
  }

  @Test(arguments: cases)
  func everyLayoutAndStateUsesTheSameCaptionAndContentContract(_ entry: Case) throws {
    #expect(Self.cases.count == 60)
    for nativeLayout in [false, true] where !entry.layout.rightSidebar || nativeLayout {
      for reactOnTop in [false, true] {
        try verify(entry, nativeLayout: nativeLayout, reactOnTop: reactOnTop)
      }
    }
  }

  private func verify(_ entry: Case, nativeLayout: Bool, reactOnTop: Bool) throws {
    for dark in [false, true] {
      let state = try makeState(entry.layout)
      let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
      let input = try #require(WindowLayoutInput(state: state, windowId: "matrix", bounds: bounds,
        sidebarPositionAllowed: nativeLayout, windowFullscreen: entry.presentation.fullscreen))
      #expect(input.layout.topTabs == entry.layout.topTabs)
      #expect(input.layout.addressBarInSidebar == entry.layout.sidebarAddress)
      #expect((input.layout.sidebarSide == .right) == entry.layout.rightSidebar)
      #expect((input.layout.dock == 0) == entry.layout.hidden)
      let window = NSWindow(contentRect: bounds,
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer {
        window.contentView = nil
        window.close()
      }
      WindowCaptionLayout.configure(window)
      let root = FlippedContainerView(frame: bounds)
      root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = root
      let shell = WindowShellView(windowId: "matrix", reactOnTop: reactOnTop)
      defer { shell.stopLayoutMotion() }
      shell.frame = bounds
      shell.update { $0 = input.layout }
      root.addSubview(shell)
      let backdrop = MatrixSidebarFill(dark: dark)
      shell.mount(.backdrop, backdrop)
      let tint = MatrixSidebarFill(dark: dark, tint: true)
      tint.alphaValue = 0.35
      shell.mount(.tint, tint)
      let react = FlippedContainerView()
      shell.mount(.react, react)
      let chrome = SidebarChromeView(frame: .zero)
      let chromeState = SidebarChromeState(
        controls: StripControlsState(title: "Personal", incognito: false, profiles: state.profileOrder.count,
          nameColor: "#80506A", downloadsOpen: false, downloadsTooltip: "Downloads"),
        downloads: false, addressBar: entry.layout.sidebarAddress, dark: dark, theme: [:], dots: [], savedWidth: 190,
        iconsOnly: entry.layout.icons, sidebarPosition: entry.layout.rightSidebar ? "right" : "left", windowFullscreen: entry.presentation.fullscreen)
      chrome.update(chromeState)
      let sidebarColumn = FlippedContainerView()
      let sidebarList = FlippedContainerView()
      sidebarList.wantsLayer = true
      let sidebarRows = SidebarView(windowId: "matrix")
      defer { sidebarRows.stop() }
      sidebarList.addSubview(sidebarRows)
      sidebarColumn.addSubview(sidebarList)
      sidebarColumn.addSubview(chrome)
      let placeSidebar = {
        let top = chrome.sidebarListTopInset(max(0, chrome.headerHeight - SidebarMetrics.glowRoom))
        sidebarList.frame = CGRect(x: 0, y: top, width: sidebarColumn.bounds.width,
          height: max(0, sidebarColumn.bounds.height - top - chrome.footerHeight))
        let lift = entry.layout.icons ? SidebarRail.listLift(addressBar: entry.layout.sidebarAddress) : 0
        sidebarRows.frame = CGRect(x: 0, y: -lift, width: sidebarList.bounds.width, height: sidebarList.bounds.height + lift)
        let chromeTop = entry.layout.icons ? chrome.toolbarBandBottom : 0
        chrome.frame = CGRect(x: 0, y: chromeTop, width: sidebarColumn.bounds.width, height: max(0, sidebarColumn.bounds.height - chromeTop))
        sidebarList.layer?.masksToBounds = chrome.reservesFullScreenCaption || entry.layout.named || lift > 0
        sidebarRows.layoutSubtreeIfNeeded()
      }
      chrome.onFullScreenPresentationChange = placeSidebar
      defer { chrome.onFullScreenPresentationChange = nil }
      if !entry.layout.hidden && !entry.layout.topTabs { shell.mount(.sidebar, sidebarColumn) }
      placeSidebar()
      var sidebarHost = SidebarHostState(profileId: "default")
      sidebarHost.newTabAtTop = true
      sidebarHost.addressBar = entry.layout.sidebarAddress
      sidebarRows.update(state: state, host: sidebarHost)
      sidebarRows.layoutSubtreeIfNeeded()
      chrome.layoutSubtreeIfNeeded()
      let address = SidebarAddressBarView(frame: .zero)
      if entry.layout.sidebarAddress {
        address.update(try addressState())
        if entry.layout.hidden {
          address.navigationOnly = true
          shell.mount(.navigation, address)
        } else {
          address.frame = chrome.addressSlot.bounds
          address.autoresizingMask = [.width, .height]
          chrome.addressSlot.addSubview(address)
        }
        address.layoutSubtreeIfNeeded()
      }
      let row = FlippedContainerView()
      let controls = StripControlsView(frame: .zero)
      let strip = TopStripView(windowId: "matrix")
      defer { strip.stop() }
      if entry.layout.topTabs {
        shell.mount(.topStrip, row)
        controls.docked = true
        controls.windowFullscreen = entry.presentation.fullscreen
        controls.frame = row.bounds
        controls.update(chromeState.controls, theme: [:])
        row.addSubview(strip)
        row.addSubview(controls)
        controls.layoutSubtreeIfNeeded()
        strip.frame = controls.dockedLayout.strip
        var host = StripHostState(profileId: "default", dark: dark)
        host.pageWidth = Double(controls.dockedLayout.pageWidth)
        strip.update(state: state, host: host)
      }
      let owner = FlippedContainerView(frame: CGRect(x: shell.frames.card.minX, y: shell.frames.card.minY,
        width: shell.frames.card.width, height: ShellMetrics.toolbarHeight))
      let toolbar = ToolbarView(frame: owner.bounds)
      if !entry.layout.sidebarAddress {
        react.addSubview(owner)
        owner.addSubview(toolbar)
        toolbar.update(try toolbarState(sidebarButton: !entry.layout.topTabs))
        shell.registerToolbar(toolbar, owner: owner)
        toolbar.layoutSubtreeIfNeeded()
      }
      if entry.layout.icons && entry.presentation == .win {
        let row = toolbar.convert(toolbar.bounds, to: root)
        #expect(row.minY == 0 && row.height == ShellMetrics.railToolbarHeight)
        #expect(shell.frames.page.minY == row.maxY)
        #expect(shell.frames.lights?.y == row.midY)
        for rect in buttonFrames(in: toolbar, to: root, presented: false).values { #expect(abs(rect.midY - row.midY) <= 0.5) }
      }
      let navInSidebar = input.layout.addressBarInSidebar && input.layout.dock > 0
      let navigation: NSView = navInSidebar ? chrome : input.layout.chromeNavigationRow ? address : toolbar
      shell.fullScreenProfileNameShown = entry.layout.named && !entry.layout.rightSidebar
      let center = entry.layout.topTabs ? ShellMetrics.topStripLightsCenter : shell.frames.lights ?? ShellMetrics.lightsCenter
      WindowCaptionLayout.position(in: window, center: center)
      let windowedButtons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind in
        let button = try #require(window.standardWindowButton(kind))
        return button.convert(button.bounds, to: root)
      }
      let island = FullScreenIslandView(frame: .zero)
      root.addSubview(island)
      let values = windowedButtons.map { NSValue(rect: $0) }
      island.update(fullscreen: entry.presentation.fullscreen, page: false, reveal: 0,
        menuBottom: entry.presentation.menuBottom, closeCenter: center, windowedButtons: values)
      navigation.layoutSubtreeIfNeeded()
      let page = shell.cardPage.convert(shell.cardPage.bounds, to: root)
      let restingControls = buttonFrames(in: navigation, to: root, presented: true)
      let modelControls = buttonFrames(in: navigation, to: root, presented: false)
      let restingTopInset = shell.fullScreenTopInsetFrame
      let restingSurface = shell.cardClip.frame
      island.update(fullscreen: entry.presentation.fullscreen, page: false, reveal: entry.presentation.revealed ? 1 : 0,
        menuBottom: entry.presentation.menuBottom, closeCenter: center, windowedButtons: values)
      navigation.layoutSubtreeIfNeeded()
      let toolbarControls = buttonFrames(in: navigation, to: root, presented: true)
      #expect(!toolbarControls.isEmpty)
      if navInSidebar {
        #expect(!address.navigationOnly)
        #expect(address.isDescendant(of: chrome.addressSlot))
        #expect(toolbarControls["back"] != nil)
        #expect(toolbarControls["forward"] != nil)
      }
      #expect(shell.cardPage.convert(shell.cardPage.bounds, to: root) == page)
      let captionRowX = input.layout.chromeNavigationRow ? 0 : shell.toolbarRowFrame.minX
      let movesAside = entry.layout.reservesCaption && !navInSidebar && entry.presentation.fullscreen && !DockedLayoutInput.reserveFullScreenCaptionSpace
      let leadingShift = movesAside && entry.presentation.revealed ? input.layout.trafficLightsLeadingInset(at: captionRowX, reveal: 1) : 0
      let currentModels = buttonFrames(in: navigation, to: root, presented: false)
      for (id, rect) in modelControls {
        let shifts = ["sidebar", "back", "forward", "reload"].contains(id)
        #expect(currentModels[id] == rect.offsetBy(dx: shifts ? leadingShift : 0, dy: 0))
      }
      #expect(shell.fullScreenStripOffset == entry.presentation.offset)
      for (id, rect) in restingControls {
        let shifts = ["sidebar", "back", "forward", "reload"].contains(id)
        #expect(toolbarControls[id] == rect.offsetBy(dx: shifts ? leadingShift : 0, dy: entry.presentation.offset))
      }
      #expect(shell.fullScreenTopInsetFrame == restingTopInset.offsetBy(dx: 0, dy: entry.presentation.offset))
      #expect(shell.cardClip.frame.minY == restingSurface.minY + entry.presentation.offset)
      if entry.layout == .rightS { #expect(shell.frames.card.minY == ShellMetrics.cardTop + ShellMetrics.toolbarHeight) }
      #expect(shell.fullScreenTopInsetFrame.height == ShellMetrics.cardTop)
      if !entry.layout.sidebarAddress && !entry.layout.topTabs {
        let rowFrame = toolbar.fullScreenRect(toolbar.bounds, to: root)
        let cardTop = shell.cardClip.convert(shell.cardClip.bounds, to: root).minY
        let chromeRow = input.layout.chromeToolbarRow
        #expect(abs(cardTop - (chromeRow ? rowFrame.maxY : rowFrame.minY)) <= 0.5)
      }
      if entry.layout.reservesCaption && !navInSidebar && entry.presentation.fullscreen {
        let resting = try #require(restingControls["sidebar"])
        let leading = try #require(toolbarControls["sidebar"])
        let reservation = input.layout.trafficLightsLeadingInset(at: captionRowX, reveal: 1)
        if DockedLayoutInput.reserveFullScreenCaptionSpace {
          #expect(resting.minX >= ShellMetrics.railLightsTrailing + 4)
        } else {
          let box = input.layout.chromeNavigationRow ? SidebarHeaderMetrics.plate : 30
          #expect(resting.minX == captionRowX + ToolbarGeometry.of(sidebarButton: true).sidebarButton! - box / 2)
          #expect(leading.minX == resting.minX + (entry.presentation.revealed ? reservation : 0))
        }
        if entry.presentation.revealed { #expect(leading.minX >= ShellMetrics.railLightsTrailing + 4) }
      }
      let scrims = island.subviews.compactMap { $0 as? FullScreenIslandScrim }.filter { !$0.isHidden && !island.isHidden }
      #expect(scrims.count == entry.scrims)
      for scrim in scrims {
        let right = try #require(scrim.layer?.mask as? CAGradientLayer)
        let bottom = try #require(right.mask as? CAGradientLayer)
        #expect(right.frame == scrim.bounds)
        #expect(bottom.frame == scrim.bounds)
        #expect(try fullScreenTestColor(right.colors?.last).alpha == 0)
        #expect(try fullScreenTestColor(bottom.colors?.last).alpha == 0)
        #expect(scrim.hitTest(.zero) == nil)
        let image = try fullScreenTestImage(scrim.layer?.sublayers?.first?.contents)
        let actual = NSBitmapImageRep(cgImage: image)
        let expectedFill = FlippedContainerView(frame: shell.bounds)
        expectedFill.appearance = root.appearance
        root.addSubview(expectedFill)
        let expectedBase = MatrixSidebarFill(dark: dark)
        let expectedTint = MatrixSidebarFill(dark: dark, tint: true)
        expectedTint.alphaValue = tint.alphaValue
        for source in [expectedBase, expectedTint] {
          source.frame = expectedFill.bounds
          expectedFill.addSubview(source)
          source.layoutSubtreeIfNeeded()
        }
        let expected = try #require(expectedFill.bitmapImageRepForCachingDisplay(in: expectedFill.bounds))
        expectedFill.cacheDisplay(in: expectedFill.bounds, to: expected)
        for (x, y) in [(20, 20), (100, 70)] {
          let sampled = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          let fill = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          #expect(abs(sampled.redComponent - fill.redComponent) <= 0.005, "expected \(fill), sampled \(sampled)")
          #expect(abs(sampled.greenComponent - fill.greenComponent) <= 0.005, "expected \(fill), sampled \(sampled)")
          #expect(abs(sampled.blueComponent - fill.blueComponent) <= 0.005, "expected \(fill), sampled \(sampled)")
        }
        expectedFill.removeFromSuperview()
      }
      let shown = entry.presentation == .win || entry.presentation.revealed
      #expect(island.isHidden == !entry.presentation.revealed)
      if shown {
        let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        let lights = try #require(glass.contentView).subviews.compactMap { $0 as? NSButton }
        #expect(lights.count == 3)
        #expect(lights.map(\.isEnabled) == [true, entry.presentation == .win, true])
        if entry.presentation.revealed {
          #expect(glass.frame.size == CGSize(width: 80, height: 33))
          #expect(glass.cornerRadius == 16.5)
          #expect(glass.alphaValue == 1)
          #expect(lights.map(\.frame) == [CGFloat(10), 33, 56].map { CGRect(x: $0, y: 9.5, width: 14, height: 14) })
          let material = try #require(glass.contentView?.layer)
          #expect(material.cornerRadius == 16.5)
          #expect(material.borderWidth == 1 / max(1, window.backingScaleFactor))
          let fillColor = try #require(material.backgroundColor)
          let rimColor = try #require(material.borderColor)
          let fill = try #require(NSColor(cgColor: fillColor)?.usingColorSpace(.sRGB))
          let rim = try #require(NSColor(cgColor: rimColor)?.usingColorSpace(.sRGB))
          #expect(abs(fill.alphaComponent - 0.9) < 0.0001)
          #expect(rim.redComponent > fill.redComponent && rim.greenComponent > fill.greenComponent && rim.blueComponent > fill.blueComponent)
        }
        let caption = entry.presentation == .win ? windowedButtons.reduce(CGRect.null) { $0.union($1) }
          : island.convert(glass.frame, to: root)
        let aligned: CGFloat
        if entry.layout.topTabs {
          aligned = row.fullScreenRect(row.bounds, to: root).midY
        } else {
          aligned = try #require(toolbarControls["back"]).midY
        }
        #expect(abs(caption.midY - aligned) <= 0.5)
        for (id, rect) in toolbarControls {
          let covered = entry.layout == .sideS && entry.presentation.revealed && id == "sidebar"
          #expect(rect.intersects(caption) == covered)
          if covered {
            #expect(rect.intersection(caption).width == 2)
            #expect(!rect.insetBy(dx: 8, dy: 8).intersects(caption))
          }
        }
        if entry.presentation.fullscreen && !entry.layout.topTabs && !entry.layout.hidden && !entry.layout.named && !entry.layout.sidebarAddress {
          #expect(sidebarRows.views["newTab"] != nil)
          for (key, view) in sidebarRows.views where !view.isHiddenOrHasHiddenAncestor {
            let frame = view.fullScreenRect(view.bounds, to: root)
            #expect(!frame.intersects(caption), "\(entry): sidebar control \(key) overlaps caption \(frame), \(caption)")
          }
          for button in [chrome.headerProfile, chrome.headerDownloads, chrome.footerDownloads] where !button.isHiddenOrHasHiddenAncestor {
            #expect(!button.fullScreenRect(button.bounds, to: root).intersects(caption))
          }
        }
        if entry.layout.topTabs {
          let pageView = try #require(strip.current)
          for id in ["a", "b", "c"] {
            let local = try #require(pageView.frameOf("t:\(id)"))
            let tab = pageView.fullScreenRect(local, to: root)
            let covered = entry.layout == .topN && entry.presentation.revealed && id == "a"
            #expect(tab.intersects(caption) == covered)
          }
        }
        if entry.layout.named {
          let indicator = entry.layout.topTabs ? controls.indicator : chrome.indicator
          let label = try #require(indicator.subviews.compactMap { $0 as? StripLabel }.first)
          let name = label.fullScreenRect(label.bounds, to: root)
          #expect(abs(name.midY - caption.midY) <= 0.5)
          #expect(name.intersects(caption) == (entry.presentation.revealed && !entry.layout.rightSidebar))
        }
      }
      if movesAside {
        for reveal: CGFloat in [0.5, 0] {
          island.update(fullscreen: true, page: false, reveal: reveal,
            menuBottom: entry.presentation.menuBottom, closeCenter: center, windowedButtons: values)
          navigation.layoutSubtreeIfNeeded()
          let controls = buttonFrames(in: navigation, to: root, presented: true)
          let shift = input.layout.trafficLightsLeadingInset(at: captionRowX, reveal: reveal)
          let offset = entry.presentation.menuBottom * reveal
          for (id, rect) in restingControls {
            let shifts = ["sidebar", "back", "forward", "reload"].contains(id)
            let expected = rect.offsetBy(dx: shifts ? shift : 0, dy: offset)
            let actual = try #require(controls[id])
            #expect(abs(actual.minX - expected.minX) <= 0.5)
            #expect(actual.minY == expected.minY && actual.size == expected.size)
          }
          if !entry.layout.sidebarAddress {
            let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
            let band = try #require(snapshot.residualURLBand(tabId: "a", trailingReservation: 8,
              trafficLightsInset: shell.trafficLightsLeadingInset(for: toolbar)))
            let live = try #require(toolbar.layoutAnchors["url"])
            let field = try #require(toolbar.layoutAnchors["urlField"])
            #expect(band.offsetBy(dx: 0, dy: offset) == toolbar.fullScreenRect(live, to: root))
            #expect(field.minX == live.minX && field.width == live.width)
          }
          #expect(shell.cardPage.convert(shell.cardPage.bounds, to: root) == page)
        }
      }
      shell.unregisterToolbar(toolbar)
      island.removeFromSuperview()
    }
  }
}

@MainActor
private final class MatrixSidebarFill: NSView {
  private let gradient = CAGradientLayer()
  override var isFlipped: Bool { true }

  init(dark: Bool, tint: Bool = false) {
    super.init(frame: .zero)
    wantsLayer = true
    gradient.colors = (tint ? [NSColor.systemPink, NSColor.systemPurple]
      : dark ? [NSColor(srgbRed: 0.29, green: 0.16, blue: 0.23, alpha: 1), .black]
      : [NSColor(srgbRed: 0.91, green: 0.78, blue: 0.84, alpha: 1), .white]).map(\.cgColor)
    gradient.startPoint = .zero
    gradient.endPoint = CGPoint(x: 1, y: 1)
    layer?.addSublayer(gradient)
  }

  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    gradient.frame = bounds
  }
}
