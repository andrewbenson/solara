import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarSelectionGlassTests {
  private func state(active: String, tabs: [String] = ["a", "b", "c"]) -> BrowserState {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = tabs
    window.activeTabIds[profile] = active
    state.windows["w"] = window
    state.windowOrder = ["w"]
    for id in tabs { state.tabs[id] = Tab(id: id, windowId: "w", profileId: profile, url: "", now: 0) }
    return state
  }

  private func context(_ state: BrowserState, selection: [String] = [], previous: SidebarContext? = nil) -> SidebarContext {
    var host = SidebarHostState(profileId: BrowserState.defaultProfile.id)
    host.selection = selection
    return SidebarContext(state: state, host: host, windowId: "w", favicons: SidebarFavicons(), previous: previous)
  }

  private func row(_ id: String, at y: CGFloat, in parent: NSView, _ context: SidebarContext) -> TabRowView {
    let row = TabRowView(frame: CGRect(x: 0, y: y, width: 200, height: 34))
    parent.addSubview(row)
    bind(row, id, context)
    return row
  }

  private func bind(_ row: TabRowView, _ id: String, _ context: SidebarContext) {
    row.update(SidebarItem(kind: .tab(id), frame: row.frame, region: .scroll, groups: [], section: .list), context)
    row.layoutSubtreeIfNeeded()
  }

  private func withTransparency<T>(reduced: Bool, _ body: () throws -> T) rethrows -> T {
    SidebarDisplayOptions.reducesTransparencyOverride = reduced
    defer { SidebarDisplayOptions.reducesTransparencyOverride = nil }
    return try body()
  }

  @Test func oneGlassMovesToTheNewActiveRow() throws {
    try withTransparency(reduced: false) {
      let first = context(state(active: "a"))
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
      let a = row("a", at: 0, in: parent, first)
      let b = row("b", at: 36, in: parent, first)
      let glass = try #require(first.selectionGlass.existing)
      #expect(glass.superview === a.body)
      let next = context(state(active: "b"), previous: first)
      bind(a, "a", next)
      bind(b, "b", next)
      #expect(next.selectionGlass.existing === glass)
      #expect(glass.superview === b.body)
    }
  }

  @Test func clearingARowsIdentityLetsTheGlassGo() throws {
    try withTransparency(reduced: false) {
      let first = context(state(active: "a"))
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      let a = row("a", at: 0, in: parent, first)
      let glass = try #require(first.selectionGlass.existing)
      #expect(glass.superview === a.body)
      a.clearIdentity()
      #expect(glass.superview == nil)
    }
  }

  @Test func aRowBoundToAMissingTabLetsTheGlassGo() throws {
    try withTransparency(reduced: false) {
      let first = context(state(active: "a"))
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      let a = row("a", at: 0, in: parent, first)
      let glass = try #require(first.selectionGlass.existing)
      #expect(glass.superview === a.body)
      bind(a, "gone", first)
      #expect(glass.superview == nil)
    }
  }

  @Test func inactiveRowsNeverMakeAGlass() {
    withTransparency(reduced: false) {
      let only = context(state(active: "x", tabs: ["a", "b"]))
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      _ = row("a", at: 0, in: parent, only)
      _ = row("b", at: 36, in: parent, only)
      #expect(only.selectionGlass.existing == nil)
    }
  }

  @Test func washFollowsTheActiveRowsMultiSelection() throws {
    try withTransparency(reduced: false) {
      let selected = context(state(active: "a"), selection: ["a", "b"])
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      let a = row("a", at: 0, in: parent, selected)
      let glass = try #require(selected.selectionGlass.existing)
      glass.layoutSubtreeIfNeeded()
      #expect(glass.wash.isHidden == false)
      #expect(glass.wash.backgroundColor == selected.palette.multiSelected.cgColor)
      #expect(glass.wash.borderColor == selected.palette.multiSelectedStroke.cgColor)
      #expect(glass.wash.borderWidth == 0.5)
      let plain = context(state(active: "a"), previous: selected)
      bind(a, "a", plain)
      glass.layoutSubtreeIfNeeded()
      #expect(glass.wash.isHidden)
      #expect(glass.wash.backgroundColor == nil)
      #expect(glass.wash.borderWidth == 0)
    }
  }

  @Test func theGlassMovesBetweenPlainAndSelectedActiveRowsWithoutAStaleWash() throws {
    try withTransparency(reduced: false) {
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
      let first = context(state(active: "a"))
      let a = row("a", at: 0, in: parent, first)
      let b = row("b", at: 36, in: parent, first)
      let c = row("c", at: 72, in: parent, first)
      let glass = try #require(first.selectionGlass.existing)
      glass.layoutSubtreeIfNeeded()
      #expect(glass.superview === a.body && glass.wash.isHidden)
      let second = context(state(active: "b"), selection: ["b", "c"], previous: first)
      for (view, id) in [(a, "a"), (b, "b"), (c, "c")] { bind(view, id, second) }
      glass.layoutSubtreeIfNeeded()
      #expect(glass.superview === b.body && !glass.wash.isHidden)
      let third = context(state(active: "a"), previous: second)
      for (view, id) in [(a, "a"), (b, "b"), (c, "c")] { bind(view, id, third) }
      glass.layoutSubtreeIfNeeded()
      #expect(glass.superview === a.body && glass.wash.isHidden)
      #expect(third.selectionGlass.existing === glass)
    }
  }

  @Test func theGlassRowDrawsNoPlateBorderUnderItsWash() throws {
    try withTransparency(reduced: false) {
      let selected = context(state(active: "a"), selection: ["a", "b"])
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      let a = row("a", at: 0, in: parent, selected)
      #expect(a.surface.border == 0)
      #expect(a.surface.fill == .clear)
      #expect(a.surface.borderTint == nil)
      #expect(a.surface.borderColors.isEmpty)
    }
  }

  @Test func reducedTransparencyShowsTheMultiSelectionOnTheSolidPlate() throws {
    try withTransparency(reduced: true) {
      let selected = context(state(active: "a"), selection: ["a", "b"])
      #expect(selected.reducesTransparency)
      let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      let a = row("a", at: 0, in: parent, selected)
      #expect(selected.selectionGlass.existing == nil)
      let palette = selected.palette
      #expect(a.surface.fill == SelectedTabTint.over(palette.multiSelected, palette.selectedTint))
      #expect(a.surface.border == 0.5)
      #expect(a.surface.borderTint == palette.multiSelectedStroke)
      #expect(a.surface.borderColors.isEmpty)
      let plain = context(state(active: "a"), previous: selected)
      bind(a, "a", plain)
      #expect(a.surface.fill == palette.selectedTint)
      #expect(a.surface.borderTint == nil)
      #expect(a.surface.borderColors == palette.selectedBorder)
    }
  }

  @Test func anAccessibilityDisplayChangeRepaintsTheActiveRow() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    SidebarDisplayOptions.reducesTransparencyOverride = false
    defer { SidebarDisplayOptions.reducesTransparencyOverride = nil }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let sidebar = SidebarView(windowId: "w")
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    sidebar.update(state: state(active: "a"), host: SidebarHostState(profileId: BrowserState.defaultProfile.id))
    sidebar.layoutSubtreeIfNeeded()
    let a = try #require(sidebar.views.values.compactMap { $0 as? TabRowView }.first { $0.tabId == "a" })
    let glass = try #require(sidebar.context?.selectionGlass.existing)
    #expect(glass.superview === a.body)
    func settle(_ done: () -> Bool) async {
      for _ in 0..<100 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    SidebarDisplayOptions.reducesTransparencyOverride = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    await settle { glass.superview == nil }
    #expect(sidebar.context?.reducesTransparency == true)
    #expect(glass.superview == nil)
    #expect(a.surface.fill == sidebar.context?.palette.selectedTint)
    SidebarDisplayOptions.reducesTransparencyOverride = false
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    await settle { glass.superview === a.body }
    #expect(glass.superview === a.body)
    #expect(a.surface.fill == .clear)
  }

  @Test func theRimScaleFallsBackBeforeAWindowAndFollowsItAfter() {
    let glass = SidebarSelectionGlass(frame: CGRect(x: 0, y: 0, width: 200, height: 34))
    #expect(glass.window == nil)
    #expect(glass.rimScale == (NSScreen.main?.backingScaleFactor ?? 1))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    window.contentView = NSView(frame: window.contentLayoutRect)
    window.contentView?.addSubview(glass)
    #expect(glass.rimScale == window.backingScaleFactor)
  }
}

@MainActor
struct SelectedTabTintTests {
  @Test func darkTintIsLighterThanTheSidebarAndTheHover() {
    let sidebar = NSColor(srgbRed: 0.08, green: 0.085, blue: 0.09, alpha: 1)
    let amount = SelectedTabTint.whiteAmount(over: sidebar, hover: NSColor.white.withAlphaComponent(0.16), dark: true)
    let selected = SelectedTabTint.mix(sidebar, .white, amount)
    let hovered = SelectedTabTint.mix(sidebar, .white, 0.16)
    #expect(SelectedTabTint.lightness(selected) - SelectedTabTint.lightness(sidebar) >= SelectedTabTint.lift - 0.01)
    #expect(SelectedTabTint.lightness(selected) - SelectedTabTint.lightness(hovered) >= SelectedTabTint.aboveHover - 0.01)
  }

  @Test func lightTintKeepsTheWhiteFloor() {
    let amount = SelectedTabTint.whiteAmount(over: NSColor(white: 0.93, alpha: 1), hover: NSColor.white.withAlphaComponent(0.55), dark: false)
    #expect(amount >= SelectedTabTint.lightFloor - 0.001)
  }

  @Test func overCompositesTopOnBottom() {
    let result = SelectedTabTint.over(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5), NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
    #expect(abs(result.alphaComponent - 0.75) < 0.0001)
    #expect(abs(result.redComponent - 2.0 / 3.0) < 0.0001)
  }
}
