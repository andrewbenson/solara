import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct FullScreenStripTests {
  private func close(_ fixture: ToolbarResizeTests.Fixture) {
    fixture.shell.unregisterToolbar(fixture.toolbar)
    fixture.shell.stopLayoutMotion()
    fixture.window.contentView = nil
    fixture.window.close()
  }

  func chrome(icons: Bool) -> SidebarChromeView {
    let chrome = SidebarChromeView()
    chrome.update(SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: false, addressBar: false, dark: false, theme: [:], dots: [], savedWidth: 190, iconsOnly: icons, windowFullscreen: true))
    return chrome
  }

  @Test func allLayoutsTranslateOnlyTheStripLayersAndKeepTheirPageAndListFrames() {
    for layout in 0...2 {
      let fixture = ToolbarResizeTests.Fixture(bare: false)
      defer { close(fixture) }
      let shell = fixture.shell
      shell.update { input in
        input.topTabs = layout == 2
      }
      shell.setSidebarWidth(layout == 1 ? CGFloat(SidebarRail.width) : 190, animated: false)
      let sidebar = FlippedContainerView()
      let list = FlippedContainerView(frame: CGRect(x: 0, y: 47, width: layout == 1 ? 56 : 190, height: 600))
      let header = chrome(icons: layout == 1)
      sidebar.addSubview(list)
      sidebar.addSubview(header)
      shell.mount(.sidebar, sidebar)
      let row = FlippedContainerView()
      let tab = NSView(frame: CGRect(x: 100, y: 4, width: 120, height: 30))
      row.addSubview(tab)
      shell.mount(.topStrip, row)
      fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
      shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 26)
      header.frame = sidebar.bounds
      header.layoutSubtreeIfNeeded()
      let frames = shell.frames
      let page = shell.cardPage.frame
      let viewport = fixture.owner.frame
      let listFrame = list.frame
      let toolbar = fixture.toolbar.frame
      let tabRow = row.frame
      var publications = 0
      shell.onFrames = { _ in publications += 1 }
      for reveal: CGFloat in [0, 0.1, 0.5, 1, 0.65, 0] {
        shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 26)
        let amount = reveal * 26
        #expect(shell.fullScreenStripOffset == amount)
        #expect(shell.frames == frames)
        #expect(shell.cardPage.frame == page)
        #expect(fixture.owner.frame == viewport)
        #expect(list.frame == listFrame)
        #expect(fixture.toolbar.frame == toolbar)
        #expect(row.frame == tabRow)
        #expect(row.layer?.transform.m42 == amount)
        #expect(fixture.toolbar.superview?.layer?.transform.m42 == amount)
        #expect(header.fullScreenHeaderOffset == amount)
      }
      #expect(publications == 0)
      #expect(shell.frames.card.maxX == shell.bounds.maxX - 6)
      #expect(shell.frames.card.maxY == shell.bounds.maxY - 6)
      #expect(shell.frames.card.minY == (layout == 2 ? 42 : 6))
      #expect(shell.fullScreenHeaderRect.midY == (layout == 2 ? 21 : 27))
      if layout == 1 { #expect(shell.frames.sidebar?.width == 56) }
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 0)
      #expect(shell.fullScreenStripOffset == 0)
      #expect(shell.frames == frames)
      shell.applyFullScreenReveal(fullscreen: false, page: false, reveal: 1, menuBottom: 26)
      #expect(shell.fullScreenStripOffset == 0)
      #expect(header.fullScreenHeaderOffset == 0)
      #expect(row.layer?.transform.m42 == 0)
      #expect(shell.frames == DockedLayoutFrames.of(shell.input))
      shell.unregisterToolbar(fixture.toolbar)
    }
  }

  @Test func revealMovesTheSixPointInsetAndRoundedCardTopWithTheToolbar() {
    for topTabs in [false, true] {
      let fixture = ToolbarResizeTests.Fixture(bare: false)
      defer { close(fixture) }
      let shell = fixture.shell
      shell.update { $0.topTabs = topTabs }
      fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
      shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 26)
      let surface = shell.cardClip.frame
      let page = shell.cardPage.frame
      let toolbar = fixture.toolbar.fullScreenRect(fixture.toolbar.bounds, to: shell)
      let inset = shell.fullScreenTopInsetFrame
      for reveal: CGFloat in [0.1, 0.5, 1, 0.25, 0] {
        shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 26)
        let amount = reveal * 26
        #expect(shell.cardClip.frame.minY == surface.minY + amount)
        #expect(shell.cardClip.frame.maxY == surface.maxY)
        #expect(shell.cardClip.bounds.minY == surface.minY + amount)
        #expect(shell.cardRim.edgeRect.minY == surface.minY + amount)
        #expect(shell.cardShadow.edgeRect.minY == surface.minY + amount)
        #expect(shell.fullScreenTopInsetFrame == inset.offsetBy(dx: 0, dy: amount))
        #expect(shell.fullScreenTopInsetFrame.height == 6)
        let actualToolbar = fixture.toolbar.fullScreenRect(fixture.toolbar.bounds, to: shell)
        let expectedToolbar = toolbar.offsetBy(dx: 0, dy: amount)
        #expect(abs(actualToolbar.minX - expectedToolbar.minX) < 1e-9)
        #expect(abs(actualToolbar.minY - expectedToolbar.minY) < 1e-9)
        #expect(abs(actualToolbar.width - expectedToolbar.width) < 1e-9 && abs(actualToolbar.height - expectedToolbar.height) < 1e-9)
        #expect(shell.cardPage.frame == page)
      }
      shell.unregisterToolbar(fixture.toolbar)
    }
  }

  @Test func iconAndHiddenSidebarsReserveTheirLeadingSpaceAndSlideVerticallyWithTheMenu() {
    for width: CGFloat in [42, 190] {
      for hidden in [false, true] where hidden || width == 42 {
        let fixture = ToolbarResizeTests.Fixture(bare: false)
        defer { close(fixture) }
        let shell = fixture.shell
        shell.setSidebarWidth(width, animated: false)
        shell.update { $0.dock = hidden ? 0 : 1 }
        fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
        shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
        shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 26)
        let toolbar = fixture.toolbar.fullScreenRect(fixture.toolbar.bounds, to: shell)
        let surface = shell.cardClip.frame
        for reveal: CGFloat in [0.1, 0.5, 1, 0] {
          shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 26)
          let amount = reveal * 26
          #expect(shell.fullScreenStripOffset == amount)
          let actualToolbar = fixture.toolbar.fullScreenRect(fixture.toolbar.bounds, to: shell)
          let expectedToolbar = toolbar.offsetBy(dx: 0, dy: amount)
          #expect(abs(actualToolbar.minX - expectedToolbar.minX) < 1e-9)
          #expect(abs(actualToolbar.minY - expectedToolbar.minY) < 1e-9)
          #expect(abs(actualToolbar.width - expectedToolbar.width) < 1e-9 && abs(actualToolbar.height - expectedToolbar.height) < 1e-9)
          #expect(shell.cardClip.frame.minY == surface.minY + amount)
          #expect(shell.cardClip.frame.maxY == surface.maxY)
        }
        shell.unregisterToolbar(fixture.toolbar)
      }
    }
  }

  @Test func retiredStripAndSidebarDoNotKeepTheirRevealOffsets() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    let row = FlippedContainerView()
    shell.update { $0.topTabs = true }
    shell.mount(.topStrip, row)
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0.5, menuBottom: 26)
    #expect(row.layer?.transform.m42 == 13)
    shell.mount(.topStrip, nil)
    #expect(row.layer?.transform.m42 == 0)
    shell.update { $0.topTabs = false }
    let header = chrome(icons: false)
    shell.mount(.sidebar, header)
    #expect(header.fullScreenHeaderOffset == 13)
    shell.mount(.sidebar, nil)
    #expect(header.fullScreenHeaderOffset == 0)
  }

  @Test func translatedControlCoordinatesWorkAcrossFlippedAndUnflippedViews() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    let sidebar = FlippedContainerView()
    let header = chrome(icons: false)
    sidebar.addSubview(header)
    shell.mount(.sidebar, sidebar)
    header.frame = sidebar.bounds
    header.layoutSubtreeIfNeeded()
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0.5, menuBottom: 26)
    for flipped in [false, true] {
      let child: NSView = flipped ? FlippedContainerView() : NSView()
      child.frame = CGRect(x: 20, y: 10, width: 30, height: 30)
      header.fullScreenHeader.addSubview(child)
      let center = CGPoint(x: child.bounds.midX, y: child.bounds.midY)
      let model = child.convert(center, to: shell)
      let visual = CGPoint(x: model.x, y: model.y + 13)
      #expect(child.fullScreenPoint(visual, from: shell) == center)
      #expect(child.fullScreenPoint(center, from: child) == center)
      let modelRect = child.convert(child.bounds, to: shell)
      #expect(child.fullScreenRect(child.bounds, to: shell) == modelRect.offsetBy(dx: 0, dy: 13))
      #expect(child.fullScreenRect(child.bounds, to: child) == child.bounds)
      child.removeFromSuperview()
    }
  }

  @Test func sidebarAddressAnchorsFollowRevealWhileTheFieldFrameStaysFixed() throws {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    shell.update { $0.addressBarInSidebar = true }
    let header = chrome(icons: false)
    var state = try #require(header.state)
    state.addressBar = true
    header.update(state)
    shell.mount(.sidebar, header)
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 26)
    header.layoutSubtreeIfNeeded()
    let bars = SidebarAddressBars()
    let bar = bars.view(shell.windowId)
    let json = """
      {"palette":\(ToolbarWebKitPillTests.palette),"accent":"#D37B8B",
       "look":{"resting":"#FFFFFF","stroke":"#FFFFFF","hover":"#FFFFFF","placeholder":"#000000","prompt":"Search"},
       "buttons":[],"extensions":[{"id":"ext:sample","icon":"puzzlepiece","anchor":"sample"}]}
      """
    bars.set(shell.windowId, json: json)
    var published: [[String: CGRect]] = []
    bars.onAnchors = { windowId, anchors in
      #expect(windowId == shell.windowId)
      published.append(anchors)
    }
    header.addressSlot.addSubview(bar)
    bar.frame = header.addressSlot.bounds
    bar.layoutSubtreeIfNeeded()
    let initial = try #require(published.last)
    let field = try #require(initial["field"])
    let accessory = try #require(initial["sample"])
    let frame = bar.fieldFrame
    for reveal: CGFloat in [0.5, 1, 0.25, 0] {
      published.removeAll()
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 26)
      let anchors = try #require(published.last)
      #expect(anchors["field"] == field.offsetBy(dx: 0, dy: reveal * 26))
      #expect(anchors["sample"] == accessory.offsetBy(dx: 0, dy: reveal * 26))
      #expect(bar.fieldFrame == frame)
    }
  }

  @Test func shiftedTabControlsReceiveHitsOnlyAtTheirPresentedPositions() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    shell.update { $0.topTabs = true }
    let row = FlippedContainerView()
    let button = NSButton(frame: CGRect(x: 100, y: 4, width: 120, height: 30))
    row.addSubview(button)
    shell.mount(.topStrip, row)
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 26)
    #expect(shell.hitTest(shell.convert(CGPoint(x: 160, y: 45), to: shell.superview)) === button)
    #expect(shell.hitTest(shell.convert(CGPoint(x: 160, y: 19), to: shell.superview)) !== button)
    #expect(button.frame == CGRect(x: 100, y: 4, width: 120, height: 30))
    shell.applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
    #expect(shell.hitTest(shell.convert(CGPoint(x: 160, y: 19), to: shell.superview)) === button)
  }

  @Test func translatedToolbarsRemainInteractiveWithEitherReactStack() {
    for reactOnTop in [false, true] {
      let fixture = ToolbarResizeTests.Fixture(bare: false, reactOnTop: reactOnTop)
      defer { close(fixture) }
      let shell = fixture.shell
      fixture.toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
      shell.registerToolbar(fixture.toolbar, owner: fixture.owner)
      let button = NSButton(frame: CGRect(x: 20, y: 4, width: 20, height: 10))
      fixture.toolbar.addSubview(button)
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 26)
      let source = button.convert(CGPoint(x: 10, y: 5), to: shell)
      #expect(shell.hitTest(shell.convert(CGPoint(x: source.x, y: source.y + 26), to: shell.superview)) === button)
      #expect(shell.hitTest(shell.convert(source, to: shell.superview)) !== button)
      shell.unregisterToolbar(fixture.toolbar)
    }
  }

  @Test func nativePaneToolbarsAtTheTopMoveAcrossThePageWhileLowerRowsStayPut() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    shell.unregisterToolbar(fixture.toolbar)
    let toolbar = #"""
      {"tabId":"a","height":41,"bare":false,"focused":true,"accent":"#3478F6",
       "palette":{"text":"#000000","secondary":"#00000080","icon":"#000000D4","iconDisabled":"#0000006E","hover":"#0000000D","pressed":"#0000001A","pill":"#0000000A","divider":"#0000001A"},
       "geometry":{"back":21,"forward":57,"reload":92,"urlLeft":110,"urlRight":8},
       "left":[],"url":null,"right":[],"rightInset":8,"hairline":false}
      """#
    let leaves = [CGRect(x: 0, y: 0, width: 390, height: 300), CGRect(x: 397, y: 0, width: 390, height: 300), CGRect(x: 0, y: 307, width: 390, height: 300)].map { frame in
      let leaf = SplitLeafView(frame: frame)
      leaf.setToolbar(toolbar)
      shell.card.addSubview(leaf)
      leaf.needsLayout = true
      leaf.layoutSubtreeIfNeeded()
      return leaf
    }
    let buttons = leaves.map { leaf in
      let button = NSButton(frame: CGRect(x: 20, y: 4, width: 20, height: 10))
      leaf.toolbar.addSubview(button)
      return button
    }
    let pages = leaves.map { $0.page.frame }
    let panes = leaves.map(\.frame)
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 0, menuBottom: 26)
    for reveal: CGFloat in [0, 0.5, 1, 0.25, 0] {
      shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: reveal, menuBottom: 26)
      let currentPanes = leaves.map(\.frame)
      let currentPages = leaves.map { $0.page.frame }
      #expect(currentPanes == panes)
      #expect(currentPages == pages)
      #expect(leaves[0].toolbar.layer?.transform.m42 == reveal * 26)
      #expect(leaves[1].toolbar.layer?.transform.m42 == reveal * 26)
      #expect(leaves[2].toolbar.layer?.transform.m42 == 0)
    }
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 26)
    for index in 0...1 {
      let model = buttons[index].convert(CGPoint(x: 10, y: 5), to: shell)
      #expect(shell.hitTest(shell.convert(CGPoint(x: model.x, y: model.y + 26), to: shell.superview)) === buttons[index])
      #expect(shell.hitTest(shell.convert(model, to: shell.superview)) !== buttons[index])
      #expect(leaves[index].layer?.masksToBounds == true)
      #expect(leaves[index].bounds.height > leaves[index].toolbar.frame.maxY + 26)
    }
    shell.applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
    let restored = leaves.allSatisfy { $0.toolbar.layer?.transform.m42 == 0 }
    #expect(restored)
  }

  @Test func switchingIconAndFullSidebarsInSpacesDoesNotAnimateAcrossTheSavedRailWidth() {
    let fixture = ToolbarResizeTests.Fixture(bare: false)
    defer { close(fixture) }
    let shell = fixture.shell
    shell.update {
      $0.sidebarWidth = CGFloat(SidebarRail.width)
      $0.windowFullscreen = true
    }
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 26)
    #expect(shell.frames.sidebar?.width == 56)
    shell.update { $0.sidebarWidth = 190 }
    #expect(!shell.widthMoving)
    #expect(shell.frames.sidebar?.width == 190)
    #expect(shell.frames.card.minX == 190)
    shell.setSidebarWidth(CGFloat(SidebarRail.width), animated: true)
    #expect(!shell.widthMoving)
    #expect(shell.frames.sidebar?.width == 56)
    #expect(shell.frames.card.minX == 56)
    #expect(shell.fullScreenStripOffset == 26)
  }

  @Test func rendererFullscreenAndExitClearEveryTranslation() {
    let shell = WindowShellView(windowId: "w")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let row = FlippedContainerView()
    shell.mount(.topStrip, row)
    shell.update { $0.topTabs = true }
    shell.applyFullScreenReveal(fullscreen: true, page: false, reveal: 1, menuBottom: 26)
    #expect(row.layer?.transform.m42 == 26)
    shell.applyFullScreenReveal(fullscreen: true, page: true, reveal: 1, menuBottom: 26)
    #expect(row.layer?.transform.m42 == 0)
    #expect(shell.fullScreenStripOffset == 0)
    shell.applyFullScreenReveal(fullscreen: false, page: false, reveal: 0, menuBottom: 0)
    #expect(shell.frames.card.minY == 42)
    #expect(shell.frames.card.maxX == 994)
  }
}
