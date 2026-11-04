import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailPanelTests {
  private func context(width: Double = 280, nested: Bool = false) throws -> SidebarContext {
    let child = nested ? #", "child":{"id":"child","windowId":"w","parentId":"g","name":"Nested","tabIds":["t2"]}"# : ""
    let state = try BrowserState(stateJSON: JSONValue.parse("""
      {"settings":{"sidebarWidth":\(width),"sidebarIconsOnly":true},
       "windows":{"w":{"id":"w","profileId":"p","tabIds":["t2","t3"],"activeTabIds":{"p":"t2"}}},
       "windowOrder":["w"],
       "tabs":{"t2":{"id":"t2","windowId":"w","profileId":"p","url":"https://two.example/","title":"Two","liveItem":{"folderId":"f","itemId":"a"}},
               "t3":{"id":"t3","windowId":"w","profileId":"p","url":"https://three.example/","title":"Three"}},
       "groups":{"g":{"id":"g","windowId":"w","name":"Work","tabIds":["t2","t3"],"collapsed":true}\(child)}}
      """).object ?? [:])
    return SidebarContext(state: state, host: SidebarHostState(profileId: "p"), windowId: "w", favicons: SidebarFavicons())
  }

  private func mount(_ context: SidebarContext) -> (NSWindow, RailGroupView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 84, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    window.orderBack(nil)
    let row = RailGroupView(frame: NSRect(x: 6, y: 300, width: 72, height: 30))
    window.contentView?.addSubview(row)
    row.update(SidebarItem(kind: .groupHeader("g"), frame: row.frame, region: .scroll, groups: [], section: .list), context)
    row.layoutSubtreeIfNeeded()
    return (window, row)
  }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  private func texts(in view: NSView) -> [String] {
    descendants(view).compactMap {
      if let field = $0 as? NSTextField { return field.stringValue }
      return ($0 as? OnboardingTextNSView)?.storage.string
    }
  }

  private func body(_ row: RailGroupView) throws -> NSView {
    try #require(row.popover?.popover.contentViewController?.view)
  }

  private func member(_ name: String, in view: NSView) throws -> NSView {
    try #require(descendants(view).first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == name })
  }

  private func key(_ code: UInt16, _ chars: String) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
  }

  @Test(arguments: [180.0, 280.0, 360.0]) func savedWidthClampsToFolderPanelRange(_ width: Double) throws {
    let context = try context(width: width)
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    row.click(SidebarClickMods([]), count: 1)
    #expect(row.popover?.popover.contentSize.width == CGFloat(min(320, max(200, width))))
  }

  @Test func headerAndRowsUseFolderPanelMetrics() throws {
    let context = try context()
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    row.click(SidebarClickMods([]), count: 1)
    let content = try body(row)
    content.layoutSubtreeIfNeeded()
    #expect(texts(in: content).first == "Work")
    let first = try member("Two", in: content)
    let second = try member("Three", in: content)
    #expect(first.frame.height == FolderPanelMetrics.rowHeight)
    #expect(second.frame.minY - first.frame.minY == FolderPanelMetrics.rowHeight + FolderPanelMetrics.rowGap)
    #expect(first.frame.minX == FolderPanelMetrics.padding + FolderPanelMetrics.border)
    let layers: [CALayer] = descendants(content).flatMap { $0.layer?.sublayers ?? [] }
    let surfaces = layers.compactMap { $0 as? SurfaceLayer }
    let surface = try #require(surfaces.first)
    #expect(surface.radius == 12)
    #expect(surface.border == 0.5)
    #expect(surface.glowRadius == 16)
    #expect(surface.glowOffset == CGSize(width: 0, height: 6))
    #expect(surface.glowOpacity == 0.4)
    #expect(surface.fill == FolderPanelColors(dark: true, tokens: [:]).panel.ns)
    let icons = descendants(first).compactMap { $0 as? TabIconView }
    #expect(icons.first?.frame.size == NSSize(width: 16, height: 16))
  }

  @Test func activeHighlightHoverCloseAndTabMenuUseFullWidthActions() throws {
    let context = try context()
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    var actions: [String] = []
    context.send = {
      if case .close(let id) = $0 { actions.append("close:\(id)") }
      if case .tabMenu(let id) = $0 { actions.append("menu:\(id)") }
    }
    row.click(SidebarClickMods([]), count: 1)
    let first = try member("Two", in: body(row))
    #expect(first.layer?.sublayers?.contains { $0.backgroundColor == context.palette.pinnedSelectedFill.cgColor } == true)
    #expect(descendants(first).compactMap { $0 as? NSButton }.allSatisfy { $0.isHidden })
    first.mouseEntered(with: NSEvent())
    let close = descendants(first).compactMap { $0 as? NSButton }.first { !$0.isHidden }
    #expect(close?.accessibilityLabel() == "Close Tab")
    #expect(sendSidebarRailButtonAction(close))
    first.rightMouseDown(with: NSEvent())
    let full = TabRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
    full.update(SidebarItem(kind: .tab("t2"), frame: full.frame, region: .scroll, groups: [], section: .list), context)
    full.hovered = true
    let fullClose = try #require(descendants(full).compactMap { $0 as? SidebarIconButton }.first { !$0.isHidden && $0.toolTip?.hasPrefix("Close Tab") == true })
    fullClose.onPress?()
    full.contextMenu()
    #expect(actions == ["close:t2", "menu:t2", "close:t2", "menu:t2"])
  }

  @Test func arrowKeysSelectAndReturnUsesClickAction() throws {
    let context = try context()
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    var clicks: [String] = []
    context.send = { if case .click(let id, _) = $0 { clicks.append(id) } }
    row.click(SidebarClickMods([]), count: 1)
    let content = try body(row)
    content.keyDown(with: try key(125, "\u{f701}"))
    let second = try member("Three", in: content)
    #expect(second.layer?.sublayers?.contains { $0.backgroundColor == context.palette.hover.cgColor } == true)
    content.keyDown(with: try key(126, "\u{f700}"))
    #expect(second.layer?.sublayers?.contains { $0.backgroundColor == context.palette.hover.cgColor } != true)
    content.keyDown(with: try key(125, "\u{f701}"))
    content.keyDown(with: try key(36, "\r"))
    #expect(clicks == ["t3"])
    #expect(row.popover?.popover.isShown == false)
  }

  @Test func nestedGroupPushesInPlaceAndBackRestoresHeader() throws {
    let context = try context(nested: true)
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    var clicks: [String] = []
    context.send = { if case .click(let id, _) = $0 { clicks.append(id) } }
    row.click(SidebarClickMods([]), count: 1)
    let popover = try #require(row.popover?.popover)
    let content = try body(row)
    let nested = try member("Nested", in: content)
    #expect(descendants(nested).contains { $0 is SymbolView })
    #expect(nested.accessibilityPerformPress())
    #expect(row.popover?.popover === popover)
    #expect(popover.isShown)
    #expect(texts(in: content).first == "Nested")
    #expect(clicks.isEmpty)
    let back = try member("Back", in: content)
    #expect(sendSidebarRailButtonAction(back as? NSButton))
    #expect(texts(in: content).first == "Work")
    #expect(try member("Nested", in: content).accessibilityPerformPress())
    #expect(try member("Two", in: content).accessibilityPerformPress())
    #expect(clicks == ["t2"])
  }

  @Test func sameIconSecondClickCloses() throws {
    let context = try context()
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    row.click(SidebarClickMods([]), count: 1)
    row.click(SidebarClickMods([]), count: 1)
    #expect(row.popover?.popover.isShown != true)
  }

  @Test func popoverIsRightAnchoredAndTopAlignedWithIcon() throws {
    let context = try context()
    let (window, row) = mount(context)
    defer { row.popover?.close(); window.close() }
    row.click(SidebarClickMods([]), count: 1)
    let popover = try #require(row.popover?.popover)
    let content = try body(row)
    let panel = try #require(content.window)
    let icon = row.body.convert(row.icon.frame, to: nil)
    let iconScreen = window.convertToScreen(icon)
    let contentScreen = panel.convertToScreen(content.convert(content.bounds, to: nil))
    #expect(popover.positioningRect == row.body.convert(row.icon.frame, to: row))
    #expect(contentScreen.minX >= iconScreen.maxX)
    #expect(abs(contentScreen.maxY - iconScreen.maxY) < 1)
  }

  @Test func liveRefreshUnreadCloseAndMenuMatchFullWidthRows() throws {
    let context = try context()
    let live = try #require(SidebarLive.decode(#"""
      {"folders":{"f":{"id":"f","profileId":"p","kind":"documents","name":"Documents","collapsed":true,
        "sources":["notion"],"filters":{"authored":true,"reviewRequests":true},"groupStacks":false,"showCompleted":false,"createdAt":1}},
       "folderOrder":["f"],"unread":{"f":["a"]},"items":{"f":[
        {"id":"a","source":"notion","url":"https://two.example/","title":"Unread document","subtitle":"","updatedAt":1},
        {"id":"b","source":"notion","url":"https://three.example/","title":"Read document","subtitle":"","updatedAt":1}]}}
      """#))
    context.live = SidebarLiveBlocks(SidebarLive(state: live), state: context.state, windowId: "w", profileId: "p")
    let (window, group) = mount(context)
    let row = RailLiveFolderView(frame: group.frame)
    window.contentView?.addSubview(row)
    row.update(SidebarItem(kind: .live("livefolder|f"), frame: row.frame, region: .scroll, groups: [], section: .pinned), context)
    row.layoutSubtreeIfNeeded()
    defer { row.popover?.close(); window.close() }
    var actions: [String] = []
    context.send = { if case .live(let action, let folder, let id, _) = $0 { actions.append("\(action):\(folder):\(id ?? "")") } }
    row.click(SidebarClickMods([]), count: 1)
    let content = try #require(row.popover?.popover.contentViewController?.view)
    content.layoutSubtreeIfNeeded()
    let refresh = descendants(content).first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Refresh" }
    #expect(sendSidebarRailButtonAction(refresh as? NSButton))
    let unread = try member("Unread document", in: content)
    let read = try member("Read document", in: content)
    #expect(descendants(unread).compactMap { $0 as? FadeLabel }.first?.font == NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium))
    #expect(descendants(read).compactMap { $0 as? FadeLabel }.first?.font == NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular))
    #expect(unread.layer?.sublayers?.contains { $0.bounds.size == NSSize(width: 5, height: 5) && !$0.isHidden } == true)
    unread.mouseEntered(with: NSEvent())
    let close = descendants(unread).compactMap { $0 as? NSButton }.first { !$0.isHidden }
    #expect(sendSidebarRailButtonAction(close))
    unread.rightMouseDown(with: NSEvent())
    let header = LiveHeaderView(frame: group.frame)
    header.update(SidebarItem(kind: .live("livefolder|f"), frame: header.frame, region: .scroll, groups: [], section: .pinned), context)
    header.hovered = true
    let fullRefresh = try #require(descendants(header).compactMap { $0 as? SidebarIconButton }.last)
    fullRefresh.onPress?()
    let full = LiveItemRowView(frame: group.frame)
    full.update(SidebarItem(kind: .live(SidebarLiveMetrics.itemKey("f", "a")), frame: full.frame, region: .scroll, groups: [], section: .pinned), context)
    full.hovered = true
    let fullClose = try #require(descendants(full).compactMap { $0 as? SidebarIconButton }.first { !$0.isHidden })
    fullClose.onPress?()
    full.contextMenu()
    #expect(actions == ["refresh:f:", "close:f:t2", "itemMenu:f:a", "refresh:f:", "close:f:t2", "itemMenu:f:a"])
  }

}
