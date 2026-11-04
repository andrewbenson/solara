import AppKit
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailPopoverTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"""
      {"windows":{"w":{"id":"w","profileId":"p","tabIds":["t1","t2","t3"],"activeTabIds":{"p":"t1"}}},
       "windowOrder":["w"],
       "tabs":{"t1":{"id":"t1","windowId":"w","profileId":"p","url":"https://one.example/","title":"One"},
               "t2":{"id":"t2","windowId":"w","profileId":"p","url":"https://two.example/","title":"Two"},
               "t3":{"id":"t3","windowId":"w","profileId":"p","url":"https://three.example/","title":"Three"}},
       "groups":{"g":{"id":"g","windowId":"w","name":"Work","tabIds":["t2","t3"],"collapsed":true}}}
      """#).object ?? [:])
  }

  private func mounted(renaming: String? = nil) throws -> (NSWindow, SidebarView) {
    let browser = try state()
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 42, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    window.orderBack(nil)
    let sidebar = SidebarView(windowId: "w")
    window.contentView = sidebar
    var host = SidebarHostState(profileId: "p")
    host.renaming = renaming
    sidebar.update(state: browser, host: host)
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func close(_ window: NSWindow, sidebar: SidebarView) {
    for row in sidebar.views.values.compactMap({ $0 as? RailIconView }) {
      row.popover?.close(commitRename: false)
    }
    window.close()
  }

  private func reflectedPopover(_ value: Any, depth: Int = 0) -> NSPopover? {
    if let popover = value as? NSPopover { return popover }
    guard depth < 4 else { return nil }
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
      for child in current.children where child.label == "popover" || current.displayStyle == .optional {
        if let found = reflectedPopover(child.value, depth: depth + 1) { return found }
      }
      mirror = current.superclassMirror
    }
    return nil
  }

  private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { all(type, in: $0) }
  }

  @Test func railTabRenameUsesTheInlineRenameCallback() throws {
    let (window, sidebar) = try mounted(renaming: "tab:t1")
    defer { close(window, sidebar: sidebar) }
    var renamed: [String] = []
    sidebar.onAction = { if case .renamed(let kind, let id, let text) = $0 { renamed.append("\(kind):\(id):\(text ?? "cancel")") } }
    let row = try #require(sidebar.views["t:t1"])
    let popover = try #require(reflectedPopover(row))
    let content = try #require(popover.contentViewController?.view)
    let field = try #require(all(SidebarRenameField.self, in: content).first)
    #expect(field.stringValue == "One")
    field.stringValue = "Renamed"
    #expect(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(renamed == ["tab:t1:Renamed"])
  }

  @Test func railGroupRenameEscapeCancels() throws {
    let (window, sidebar) = try mounted(renaming: "group:g")
    defer { close(window, sidebar: sidebar) }
    var renamed: [String?] = []
    sidebar.onAction = { if case .renamed(let kind, let id, let text) = $0, kind == "group", id == "g" { renamed.append(text) } }
    let row = try #require(sidebar.views["gh:g"])
    let popover = try #require(reflectedPopover(row))
    let content = try #require(popover.contentViewController?.view)
    let field = try #require(all(SidebarRenameField.self, in: content).first)
    #expect(field.stringValue == "Work")
    #expect(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(renamed.count == 1)
    #expect(renamed.first! == nil)
  }

  @Test func clickingRailGroupShowsItsMembersAndChoosingOneActivatesIt() throws {
    let (window, sidebar) = try mounted()
    defer { close(window, sidebar: sidebar) }
    var clicked: [String] = []
    sidebar.onAction = { if case .click(let id, _) = $0 { clicked.append(id) } }
    let row = try #require(sidebar.views["gh:g"] as? SidebarRowView)
    row.click(SidebarClickMods([]), count: 1)
    let popover = try #require(reflectedPopover(row))
    let content = try #require(popover.contentViewController?.view)
    #expect(popover.isShown)
    #expect(popover.behavior == .transient)
    let rows = all(SidebarRailPopoverRowView.self, in: content)
    #expect(rows.map(\.tabId) == ["t2", "t3"])
    #expect(rows.map { $0.accessibilityLabel() } == ["Two", "Three"])
    #expect(clicked.isEmpty)
    let last = try #require(rows.last)
    #expect(last.accessibilityPerformPress())
    #expect(clicked == ["t3"])
    #expect(!popover.isShown)
  }

  @Test func railContentsEscapeClosesThePopover() throws {
    let (window, sidebar) = try mounted()
    defer { close(window, sidebar: sidebar) }
    let row = try #require(sidebar.views["gh:g"] as? SidebarRowView)
    row.click(SidebarClickMods([]), count: 1)
    let popover = try #require(reflectedPopover(row))
    #expect(popover.isShown)
    let content = try #require(popover.contentViewController?.view)
    content.cancelOperation(nil)
    #expect(!popover.isShown)
  }

  @Test func railRenameClickAwayCommitsTheTypedNameOnce() throws {
    let (window, sidebar) = try mounted(renaming: "tab:t1")
    defer { close(window, sidebar: sidebar) }
    var renamed: [String?] = []
    sidebar.onAction = { if case .renamed(_, _, let text) = $0 { renamed.append(text) } }
    let row = try #require(sidebar.views["t:t1"])
    let popover = try #require(reflectedPopover(row))
    let content = try #require(popover.contentViewController?.view)
    let field = try #require(all(SidebarRenameField.self, in: content).first)
    field.stringValue = "Kept"
    #expect(popover.isShown)
    popover.performClose(nil)
    popover.performClose(nil)
    #expect(renamed == ["Kept"])
  }

  @Test func clickingRailLiveFolderShowsAllItemsAndUsesTheLiveRowOpenAction() throws {
    let browser = try state()
    let host = SidebarHostState(profileId: "p")
    let context = SidebarContext(state: browser, host: host, windowId: "w", favicons: SidebarFavicons())
    let live = try #require(SidebarLive.decode(#"""
      {"folders":{"f":{"id":"f","profileId":"p","kind":"documents","name":"Documents","icon":null,"collapsed":true,
        "sources":["notion"],"filters":{"authored":true,"reviewRequests":true},"groupStacks":false,"showCompleted":false,"createdAt":1}},
       "folderOrder":["f"],"items":{"f":[
        {"id":"a","source":"notion","url":"https://one.example/","title":"First document","subtitle":"","icon":null,"updatedAt":1},
        {"id":"b","source":"notion","url":"https://two.example/","title":"Second document","subtitle":"","icon":null,"updatedAt":1}]}}
      """#))
    context.live = SidebarLiveBlocks(SidebarLive(state: live), state: browser, windowId: "w", profileId: "p")
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 42, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    window.orderBack(nil)
    let row = RailLiveFolderView(frame: NSRect(x: 6, y: 25, width: 30, height: 30))
    defer { row.popover?.close(commitRename: false); window.close() }
    window.contentView?.addSubview(row)
    row.update(SidebarItem(kind: .live("livefolder|f"), frame: row.frame, region: .scroll, groups: [], section: .pinned), context)
    row.layoutSubtreeIfNeeded()
    var opened: [String] = []
    context.send = { if case .live(let action, let folder, let id, _) = $0 { opened.append("\(action):\(folder):\(id ?? "")") } }
    row.click(SidebarClickMods([]), count: 1)
    let popover = try #require(reflectedPopover(row))
    let content = try #require(popover.contentViewController?.view)
    #expect(popover.isShown)
    #expect(popover.behavior == .transient)
    let rows = all(SidebarRailPopoverRowView.self, in: content)
    #expect(rows.map(\.tabId) == ["a", "b"])
    #expect(rows.map { $0.accessibilityLabel() } == ["First document", "Second document"])
    #expect(opened.isEmpty)
    let first = try #require(rows.first)
    #expect(first.accessibilityPerformPress())
    #expect(opened == ["open:f:a"])
    #expect(!popover.isShown)
  }

}
