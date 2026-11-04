import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailTileTests {
  private func context() throws -> SidebarContext {
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"b"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"Pinned","pinned":true},"b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"Tab"}}}"#).object ?? [:])
    return SidebarContext(state: state, host: SidebarHostState(profileId: "p"), windowId: "w", favicons: SidebarFavicons())
  }

  @Test func theTileAndIconAreCenteredInTheRailRow() {
    let row = RailTabView(frame: NSRect(x: 0, y: 0, width: 72, height: 30))
    row.layoutSubtreeIfNeeded()
    #expect(row.glass.frame == CGRect(x: 21, y: 0, width: 30, height: 30))
    #expect(row.icon.frame == CGRect(x: 28, y: 7, width: 16, height: 16))
    #expect(row.glass.radius == 8)
  }

  @Test func pinnedTilesUseTheSameRailTileAsTabs() throws {
    let context = try context()
    let pinned = try #require(SidebarRail.make(.tile("a")) as? RailTabView)
    let tab = try #require(SidebarRail.make(.tab("b")) as? RailTabView)
    let frame = CGRect(x: 0, y: 0, width: 72, height: 30)
    for (view, kind) in [(pinned, SidebarItemKind.tile("a")), (tab, SidebarItemKind.tab("b"))] {
      view.frame = frame
      view.update(SidebarItem(kind: kind, frame: frame, region: .scroll, groups: [], section: .list), context)
      view.layoutSubtreeIfNeeded()
      #expect(view.glass.frame == CGRect(x: 21, y: 0, width: 30, height: 30))
      #expect(view.icon.frame == CGRect(x: 28, y: 7, width: 16, height: 16))
    }
    #expect(pinned.tabId == "a")
    #expect(tab.tabId == "b")
  }

  @Test func pinnedFoldersUseTheSquareRailTileAndKeepFolderActions() throws {
    let context = try context()
    let row = try #require(SidebarRail.make(.folder("f")) as? RailIconView)
    row.frame = CGRect(x: 0, y: 0, width: 72, height: 30)
    row.update(SidebarItem(kind: .folder("f"), frame: row.frame, region: .fixed, groups: [], section: .tiles), context)
    row.layoutSubtreeIfNeeded()
    #expect(row.glass.frame == CGRect(x: 21, y: 0, width: 30, height: 30))
    #expect(row.icon.frame == CGRect(x: 28, y: 7, width: 16, height: 16))
    #expect(!row.icon.isHidden)
    var actions: [String] = []
    context.send = {
      if case .folder(let id) = $0 { actions.append("folder:\(id)") }
      if case .folderMenu(let id) = $0 { actions.append("menu:\(id)") }
    }
    row.click(SidebarClickMods([]), count: 1)
    row.contextMenu()
    #expect(actions == ["folder:f", "menu:f"])
  }

  @Test func theCloseBadgeStraddlesTheTilesTopRightCorner() {
    #expect(SidebarRail.closeFrame(around: CGRect(x: 21, y: 0, width: 30, height: 30)) == CGRect(x: 42, y: -5, width: 14, height: 14))
  }

  @Test func hoveringATabPlacesItsCloseBadgeAtTheTileCorner() throws {
    let context = try context()
    let row = RailTabView(frame: NSRect(x: 0, y: 0, width: 72, height: 30))
    row.update(SidebarItem(kind: .tab("b"), frame: row.frame, region: .scroll, groups: [], section: .list), context)
    #expect(row.subviews.compactMap { $0 as? SidebarIconButton }.isEmpty)
    row.hovered = true
    row.layoutSubtreeIfNeeded()
    let close = try #require(row.subviews.compactMap { $0 as? SidebarIconButton }.first)
    #expect(close.frame == CGRect(x: 42, y: -5, width: 14, height: 14))
    #expect(close.radius == 7)
    var closed: [String] = []
    context.send = { if case .close(let id) = $0 { closed.append(id) } }
    close.onPress?()
    #expect(closed == ["b"])
  }

  @Test func theWholeCloseBadgeReceivesHitsAboveTheRailRow() throws {
    let context = try context()
    let parent = SidebarLayer(frame: NSRect(x: 0, y: 0, width: 72, height: 100))
    let row = RailTabView(frame: NSRect(x: 0, y: 32, width: 72, height: 30))
    parent.addSubview(row)
    row.update(SidebarItem(kind: .tab("b"), frame: row.frame, region: .scroll, groups: [], section: .list), context)
    row.hovered = true
    row.layoutSubtreeIfNeeded()
    let close = try #require(row.subviews.compactMap { $0 as? SidebarIconButton }.first)
    close.alphaValue = 1
    #expect(row.hitTest(CGPoint(x: 49, y: 29)) === close)
    #expect(row.hitTest(CGPoint(x: 49, y: 35)) === close)
    row.hovered = false
    #expect(row.hitTest(CGPoint(x: 49, y: 29)) == nil)
  }

  @Test func railTabsHaveNoRestingFillAndUseHoverAndPressedFills() throws {
    let context = try context()
    let row = RailTabView(frame: NSRect(x: 0, y: 0, width: 72, height: 30))
    row.update(SidebarItem(kind: .tile("a"), frame: row.frame, region: .fixed, groups: [], section: .tiles), context)
    #expect(row.glass.flat)
    #expect(row.glass.tint == NSColor.clear)
    row.hovered = true
    #expect(row.glass.tint == context.palette.hover)
    row.pressed = true
    #expect(row.glass.tint == context.palette.pressed)
    row.pressed = false
    row.hovered = false
    #expect(row.glass.tint == NSColor.clear)
  }

  @Test func pressedFillOverridesAnActiveTabsGlassSelection() throws {
    let context = try context()
    let row = RailTabView(frame: NSRect(x: 0, y: 0, width: 72, height: 30))
    row.update(SidebarItem(kind: .tab("b"), frame: row.frame, region: .scroll, groups: [], section: .list), context)
    #expect(!row.glass.flat)
    #expect(row.glass.raisedSelection)
    row.pressed = true
    #expect(row.glass.flat)
    #expect(!row.glass.raisedSelection)
    #expect(row.glass.tint == context.palette.pressed)
  }

  @Test func theNewTabUsesTheSameSquareTileFrame() throws {
    let context = try context()
    let row = RailNewTabView(frame: NSRect(x: 0, y: 0, width: 72, height: 30))
    row.update(SidebarItem(kind: .newTab, frame: row.frame, region: .scroll, groups: [], section: .list), context)
    row.layoutSubtreeIfNeeded()
    let plate = try #require(row.body.layer?.sublayers?.first)
    #expect(plate.frame == CGRect(x: 21, y: 0, width: 30, height: 30))
    #expect(plate.cornerRadius == 8)
    #expect(row.body.subviews.first?.frame == CGRect(x: 28, y: 7, width: 16, height: 16))
  }

  @Test func pinnedRailTilesKeepTheirDoubleClickMiddleClickAndMenuActions() throws {
    let context = try context()
    let row = try #require(SidebarRail.make(.tile("a")) as? RailTabView)
    row.update(SidebarItem(kind: .tile("a"), frame: .zero, region: .fixed, groups: [], section: .tiles), context)
    var actions: [String] = []
    context.send = {
      switch $0 {
      case .click(let id, _): actions.append("click:\(id)")
      case .tileDoubleClick(let id): actions.append("double:\(id)")
      case .middleClick(let id): actions.append("middle:\(id)")
      case .tabMenu(let id): actions.append("menu:\(id)")
      default: break
      }
    }
    row.click(SidebarClickMods([]), count: 2)
    row.middleClick()
    row.contextMenu()
    #expect(actions == ["click:a", "double:a", "middle:a", "menu:a"])
  }
}
