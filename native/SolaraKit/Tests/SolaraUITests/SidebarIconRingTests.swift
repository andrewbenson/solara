import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarIconRingTests {
  private func state(active: String) throws -> BrowserState {
    var tabs: [String: Any] = [:]
    for (id, pinned) in [("p1", true), ("p2", true), ("t1", false)] {
      tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://\(id).example/", "title": id, "pinned": pinned]
    }
    let root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ["p1", "p2", "t1"], "activeTabIds": ["p": active]]],
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private static func picture(_ colors: [NSColor]) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      for (i, color) in colors.enumerated() {
        color.setFill()
        NSRect(x: 0, y: CGFloat(i) * rect.height / CGFloat(colors.count), width: rect.width, height: rect.height / CGFloat(colors.count)).fill()
      }
      return true
    }
  }

  private func mounted(active: String, ring: Bool, colors: [NSColor]) async throws -> (NSWindow, SidebarView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.favicons.loader = { _ in Self.picture(colors) }
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
    window.contentView = sidebar
    var host = SidebarHostState(profileId: "p")
    host.iconRing = ring
    let state = try state(active: active)
    sidebar.update(state: state, host: host)
    for _ in 0..<20 {
      try await Task.sleep(nanoseconds: 20_000_000)
      sidebar.update(state: state, host: host)
    }
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func ring(_ tile: NSView) -> IconRingView? {
    func find(_ view: NSView) -> IconRingView? {
      for sub in view.subviews {
        if let ring = sub as? IconRingView { return ring }
        if let found = find(sub) { return found }
      }
      return nil
    }
    return find(tile)
  }

  @Test func aOneColourIconGetsATintedGlassRingOnTheActiveTileOnly() async throws {
    let (window, sidebar) = try await mounted(active: "p1", ring: true, colors: [.systemBlue])
    _ = window
    let active = try #require(sidebar.views["tile:p1"])
    let shown = try #require(ring(active))
    #expect(!shown.isHidden)
    #expect(shown.glass && shown.tintedRim)
    #expect(!shown.drawsTemplateIcon)
    #expect(shown.frame == active.bounds)
    #expect(glassTile(active).map { !$0.flat && $0.crisp } == true)
    let inactive = try #require(sidebar.views["tile:p2"])
    #expect(ring(inactive)?.isHidden ?? true)
    #expect(glassTile(inactive).map { $0.flat && !$0.raisedSelection } == true)
    let other = try #require(sidebar.views["t:t1"])
    #expect(ring(other)?.isHidden ?? true)
  }

  private func glassTile(_ tile: NSView) -> SidebarGlassTile? {
    func find(_ view: NSView) -> SidebarGlassTile? {
      for sub in view.subviews {
        if let glass = sub as? SidebarGlassTile { return glass }
        if let found = find(sub) { return found }
      }
      return nil
    }
    return find(tile)
  }

  @Test func anInvalidatedFaviconReloadsTheActiveRing() async throws {
    let (window, sidebar) = try await mounted(active: "p1", ring: true, colors: [.systemBlue])
    _ = window
    let active = try #require(sidebar.views["tile:p1"])
    let shown = try #require(ring(active))
    #expect(!shown.isHidden)
    sidebar.favicons.forget(url: "https://p1.example/")
    var host = SidebarHostState(profileId: "p")
    host.iconRing = true
    sidebar.update(state: try state(active: "p1"), host: host)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while shown.isHidden && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!shown.isHidden)
  }

  @Test func aManyColourIconGetsTheBlurredRing() async throws {
    let (window, sidebar) = try await mounted(active: "p2", ring: true, colors: [.systemRed, .systemGreen, .systemBlue, .systemYellow])
    _ = window
    let tile = try #require(sidebar.views["tile:p2"])
    let shown = try #require(ring(tile))
    #expect(shown.theme == .blur)
  }

  @Test func withTheSettingOffEveryTileStaysRaisedGlass() async throws {
    let (window, sidebar) = try await mounted(active: "p1", ring: false, colors: [.systemBlue])
    _ = window
    let tile = try #require(sidebar.views["tile:p1"])
    #expect(ring(tile)?.isHidden ?? true)
    #expect(glassTile(tile).map { !$0.flat && $0.raisedSelection && !$0.crisp } == true)
    let inactive = try #require(sidebar.views["tile:p2"])
    #expect(glassTile(inactive).map { !$0.flat } == true)
  }

  @Test func themesMatchTheShellsRules() throws {
    let white = try #require(Self.picture([.white]).cgImage(forProposedRect: nil, context: nil, hints: nil))
    guard case .template(let fill, let stroke)? = IconRingTheme.generate(white) else {
      Issue.record("white icon should be a template")
      return
    }
    #expect(fill.components?.first == 0)
    #expect(stroke != nil)
  }
}
