import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct TabPickersTests {
  static let rows: [TabSearchState.Row] = [
    .init(kind: "tab", id: "gmail", title: "Inbox (3) - Gmail", url: "https://mail.google.com/mail/u/0/", host: "mail.google.com"),
    .init(kind: "tab", id: "github", title: "GitHub · solara", url: "https://github.com/andrewbenson/solara", host: "github.com"),
    .init(kind: "tab", id: "hn", title: "Hacker News", url: "https://news.ycombinator.com/", host: "news.ycombinator.com"),
    .init(kind: "tab", id: "blank", title: "New Tab", url: ""),
    .init(kind: "tab", id: "docs", title: "Google Docs", url: "https://docs.google.com/document/d/x", host: "docs.google.com"),
  ]

  static func state(open: [TabSearchState.Row] = rows, closed: [TabSearchState.Row] = []) -> TabSearchState {
    TabSearchState(open: open, closed: closed, dark: true, theme: ["panel": "#2A2A2A", "panelBorder": "rgba(255,255,255,0.1)", "panelShadowOpacity": "0.5", "rowSelected": "rgba(255,255,255,0.22)"])
  }

  @Test func rankingMatchesKnownQueries() {
    let expected: [String: [String]] = [
      "gm": ["gmail", "github", "docs"], "git": ["github"], "news": ["hn", "github"], "doc": ["docs"], "goo": ["docs", "gmail", "github"],
      "zz": [], "hn": ["hn", "github", "docs"], "mail": ["gmail"],
    ]
    for (query, ids) in expected { #expect(TabSearchMetrics.rank(query, Self.rows).map(\.id) == ids, "\(query)") }
  }

  @Test func anEmptyQueryShowsEveryOpenTabAndEightClosedOnes() {
    let closed = (0..<12).map { TabSearchState.Row(kind: "closed", id: "c\($0)", title: "Closed \($0)", url: "https://c\($0).example/", host: "c\($0).example") }
    let sections = TabSearchMetrics.sections("  ", Self.state(closed: closed))
    #expect(sections.map(\.title) == ["Open Tabs", "Recently Closed"])
    #expect(sections[0].rows.count == 5)
    #expect(sections[1].rows.map(\.id) == (0..<8).map { "c\($0)" })
    #expect(TabSearchMetrics.sections("closed", Self.state(closed: closed))[1].rows.count == 8)
  }

  @Test func thePanelUsesItsExpectedFrame() {
    #expect(TabSearchMetrics.frame(windowWidth: 1200, height: 300) == CGRect(x: 320, y: 56, width: 560, height: 300))
    #expect(TabSearchMetrics.frame(windowWidth: 500, height: 300) == CGRect(x: 12, y: 56, width: 476, height: 300))
    let many = [TabSearchSection(title: "Open Tabs", rows: Array(repeating: Self.rows[0], count: 40))]
    #expect(TabSearchMetrics.panelHeight(many) == CGFloat(50 + 1 + 420 + 6))
    #expect(TabSearchMetrics.scrollOffset(selecting: 3) == 0)
    #expect(TabSearchMetrics.scrollOffset(selecting: 12) == CGFloat(4 * 36))
  }

  @Test func arrowsClampEnterChoosesAndEscapeCloses() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let view = TabSearchPanelView(favicons: SidebarFavicons())
    view.frame = window.contentView!.bounds
    window.contentView!.addSubview(view)
    var events: [TabSearchEvent] = []
    view.onEvent = { events.append($0) }
    view.open(Self.state())
    #expect(view.shownRows.count == 5)
    let field = view.subviews.first!.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    let editor = NSTextView()
    _ = view.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
    #expect(view.selectedIndex == 0)
    for _ in 0..<9 { _ = view.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))) }
    #expect(view.selectedIndex == 4)
    _ = view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(events == [.close, .choose(kind: "tab", id: "docs")])
    view.open(Self.state())
    #expect(view.selectedIndex == 0 && view.query.isEmpty)
    events = []
    _ = view.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(events == [.close])
  }

  @Test func theSwitcherWindowFollowsTheFocusAndUsesItsExpectedFrame() {
    #expect(TabSwitcherMetrics.shown(index: 1, count: 4) == 0..<4)
    #expect(TabSwitcherMetrics.shown(index: 10, count: 20) == 6..<15)
    #expect(TabSwitcherMetrics.shown(index: 19, count: 20) == 11..<20)
    let frame = TabSwitcherMetrics.frame(windowWidth: 1200, windowHeight: 800, rows: 4)
    #expect(frame.minX == 400 && frame.width == 400)
    #expect(frame.minY == CGFloat(259))
    #expect(TabSwitcherMetrics.frame(windowWidth: 1200, windowHeight: 300, rows: 9).minY == 40)
  }

  @Test func switcherRowsReportAbsoluteIndices() {
    let ids = (0..<12).map { "t\($0)" }
    let rows = Dictionary(uniqueKeysWithValues: ids.map { ($0, TabSwitcherState.Row(id: $0, title: $0, url: "https://\($0).example/", display: "\($0).example")) })
    let view = TabSwitcherPanelView(favicons: SidebarFavicons())
    var events: [TabSwitcherEvent] = []
    view.onEvent = { events.append($0) }
    view.set(TabSwitcherState(ids: ids, index: 8, rows: rows, dark: false, theme: [:]), windowSize: CGSize(width: 1200, height: 800))
    #expect(view.shownIds == Array(ids[3..<12]))
    view.layoutSubtreeIfNeeded()
    let row = view.subviews.compactMap { $0 as? TabSwitcherRowView }[2]
    row.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    #expect(events == [.commit(5)])
  }

  @Test(arguments: [false, true]) func searchSurfaceReusesOneGlassAndRestoresTheOriginalPlate(dark: Bool) throws {
    let view = TabSearchSurfaceView(frame: CGRect(x: 0, y: 0, width: 560, height: 477))
    let fill = NSColor(white: dark ? 0.16 : 1, alpha: 1)
    let border = NSColor(white: dark ? 1 : 0, alpha: 0.1)
    let theme = NewTabTheme(dark: dark, tokens: [:])
    view.paint(fill: fill, border: border, shadowOpacity: 0.5, glassTheme: theme, reduceTransparency: false)
    view.layoutSubtreeIfNeeded()
    let glass = try #require(view.subviews.compactMap { $0 as? NewTabGlassSurface }.first)
    let plate = try #require(view.layer?.sublayers?.compactMap { $0 as? SurfaceLayer }.first)
    #expect(view.usesGlass && plate.isHidden && !glass.isHidden)
    #expect(glass.glass.frame == view.bounds)
    #expect(glass.glass.cornerRadius == NewTabLayout.barRadius)
    #expect(glass.glass.tintColor == theme.ntpBarSolid.ns.withAlphaComponent(0.12))
    view.paint(fill: fill, border: border, shadowOpacity: 0.5, glassTheme: theme, reduceTransparency: true)
    #expect(!view.usesGlass && !plate.isHidden && glass.isHidden)
    #expect(plate.fill == fill && plate.borderTint == border && plate.glowOpacity == 0.5)
    #expect(plate.radius == TabSearchMetrics.radius)
    view.paint(fill: fill, border: border, shadowOpacity: 0.5, glassTheme: theme, reduceTransparency: false)
    #expect(view.subviews.compactMap { $0 as? NewTabGlassSurface }.count == 1)
    #expect(view.subviews.first === glass)
  }

  @Test func onlySearchTabsOptsIntoGlass() {
    func effects(_ view: NSView) -> [NSGlassEffectView] {
      (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap(effects)
    }
    let search = TabSearchPanelView(favicons: SidebarFavicons())
    search.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    search.set(Self.state())
    #expect(effects(search).count == (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 1))
    let switcher = TabSwitcherPanelView(favicons: SidebarFavicons())
    switcher.set(TabSwitcherState(ids: ["tab"], index: 0, rows: ["tab": .init(id: "tab", title: "Tab", url: "", display: "")], dark: true, theme: [:]), windowSize: CGSize(width: 1200, height: 800))
    #expect(effects(switcher).isEmpty)
  }

  @Test func aHiddenSearchOwnsItsMaterialBeforeTheFirstOpen() {
    func effects(_ view: NSView) -> [NSGlassEffectView] {
      (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap(effects)
    }
    let view = TabSearchPanelView(favicons: SidebarFavicons())
    view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    view.layoutSubtreeIfNeeded()
    #expect(view.isHidden)
    #expect(view.state == nil && !view.typing)
    #expect(effects(view).count == (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 1))
  }

  @Test func preparationKeepsFocusAndReopeningReusesTheMaterialWithAFreshQuery() throws {
    func effects(_ view: NSView) -> [NSGlassEffectView] {
      (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap(effects)
    }
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = TabSearchPanelView(favicons: SidebarFavicons())
    view.frame = window.contentView!.bounds
    window.contentView!.addSubview(view)
    window.makeFirstResponder(window)
    view.prepare(dark: true)
    #expect(window.firstResponder === window)
    #expect(view.isHidden && view.state == nil && !view.typing)
    #expect(view.panelFrame == CGRect(x: 320, y: 56, width: 560, height: 477))
    let material = effects(view).first
    var events: [TabSearchEvent] = []
    view.onEvent = { events.append($0) }
    view.open(Self.state())
    #expect(view.typing)
    let field = try #require(view.subviews.first!.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    field.stringValue = "gm"
    view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    _ = view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
    #expect(view.query == "gm" && view.selectedIndex == 1)
    view.hide()
    #expect(view.isHidden && !view.typing && events.isEmpty)
    #expect(effects(view).first === material)
    view.open(Self.state())
    #expect(!view.isHidden && view.query.isEmpty && view.selectedIndex == 0)
    #expect(view.shownRows.count == 5)
    #expect(effects(view).first === material)
    #expect(view.typing)
    var next = Self.state()
    next.openId = 7
    view.open(next)
    #expect(view.typing && !view.isHidden && view.openId == 7 && events.isEmpty)
    view.hide()
    #expect(view.state == nil && view.query.isEmpty && events.isEmpty)
  }

}
