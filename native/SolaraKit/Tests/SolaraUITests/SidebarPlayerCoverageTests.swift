import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarPlayerCoverageTests {
  static func playerState() -> MediaPlayerState {
    MediaPlayerState(
      tabId: "t3", title: "A long title for the card", subtitle: "Artist", muted: false, playbackState: "playing", position: 10,
      timestamp: MediaClock.nowMs(), playbackRate: 1, duration: 120, tracks: false, artwork: nil, url: "https://example.test/",
      favicon: nil, profileId: "p", theme: MediaThemeState(dark: true))
  }

  func mount() throws -> (NSWindow, FlippedContainerView, SidebarView, SidebarPlayerView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    let sidebar = SidebarView(windowId: "w", virtualizesRows: false)
    sidebar.frame = CGRect(x: 0, y: 0, width: 220, height: 500)
    root.addSubview(sidebar)
    var host = SidebarHostState(profileId: "p")
    host.player = Self.playerState()
    sidebar.update(state: try SidebarViewportTests.state(200), host: host)
    sidebar.bottomBarHeight = 40
    sidebar.layoutSubtreeIfNeeded()
    let player = try #require(Self.players(in: sidebar).first)
    return (window, root, sidebar, player)
  }

  static func players(in view: NSView) -> [SidebarPlayerView] {
    view.subviews.flatMap { ($0 as? SidebarPlayerView).map { [$0] } ?? [] + players(in: $0) }
  }

  func close(_ window: NSWindow, _ sidebar: SidebarView) {
    NotificationCenter.default.post(name: DevPointer.changed, object: nil)
    sidebar.stop()
    window.contentView = nil
    window.close()
  }

  func rowUnder(_ point: CGPoint, in sidebar: SidebarView) -> SidebarRowView? {
    sidebar.views.values.compactMap { $0 as? SidebarRowView }.first { !$0.isHidden && $0.bounds.contains($0.convert(point, from: sidebar)) }
  }

  func points(_ player: SidebarPlayerView) -> [String: CGPoint] {
    let frames = player.controlFrames
    let art = frames["art"]!, play = frames["play"]!, seek = frames["seek"]!, title = frames["title"]!
    return [
      "empty": CGPoint(x: player.bounds.width - 10, y: SidebarPlayerView.height - 6),
      "title": CGPoint(x: title.midX, y: title.midY),
      "artwork": CGPoint(x: art.midX, y: art.midY),
      "gap": CGPoint(x: (play.maxX + 24 + seek.minX) / 2, y: play.midY),
      "belowArt": CGPoint(x: art.midX, y: art.maxY + 3),
    ]
  }

  func post(_ point: CGPoint, from view: NSView, in window: NSWindow) {
    let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
    NotificationCenter.default.post(name: DevPointer.changed, object: NSValue(point: screen))
  }

  @Test func theCardCoversTheRowsUnderItAndReleasesThemWhenItGoes() throws {
    let (window, root, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    let centre = CGPoint(x: player.bounds.midX, y: SidebarPlayerView.height / 2)
    let inSidebar = sidebar.convert(centre, from: player)
    let row = try #require(rowUnder(inSidebar, in: sidebar))
    let windowPoint = player.convert(centre, to: nil)
    #expect(FullScreenIslandCoverage.contains(windowPoint, in: window))
    #expect(!FullScreenIslandCoverage.contains(windowPoint, in: window, for: player))
    for (name, point) in points(player) {
      post(point, from: player, in: window)
      #expect(!row.hovered, "\(name)")
      #expect(sidebar.hoverKey == nil, "\(name)")
      let under = try #require(rowUnder(sidebar.convert(point, from: player), in: sidebar))
      #expect(!under.hovered, "\(name)")
    }
    #expect(player.cornersShown)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: windowPoint, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    row.mouseEntered(with: entered)
    #expect(!row.hovered)
    sidebar.pointerEntered(row, at: windowPoint)
    #expect(sidebar.hoverKey == nil)
    let above = CGPoint(x: inSidebar.x, y: sidebar.convert(CGPoint.zero, from: player).y - 40)
    let visible = try #require(rowUnder(above, in: sidebar))
    post(above, from: sidebar, in: window)
    #expect(visible.hovered)
    #expect(sidebar.hoverKey != nil)
    post(inSidebar, from: sidebar, in: window)
    #expect(!row.hovered)
    sidebar.update(state: try SidebarViewportTests.state(200), host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    #expect(!FullScreenIslandCoverage.contains(windowPoint, in: window))
    #expect(player.hitTest(sidebar.convert(centre, from: player)) == nil)
  }

  @Test func clicksDragsMenusAndScrollsOnTheCardNeverReachTheRows() throws {
    let (window, root, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    var actions: [SidebarAction] = []
    sidebar.onAction = { actions.append($0) }
    #if DEBUG
    let forwardedBefore = sidebar.scrollsForwarded
    #endif
    var wheels = 0
    for (name, point) in points(player) {
      let hit = try #require(root.hitTest(player.convert(point, to: root.superview)), "\(name)")
      #expect(hit === player || hit.isDescendant(of: player), "\(name) hit \(hit)")
      let location = player.convert(point, to: nil)
      func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1))
      }
      hit.rightMouseDown(with: try mouse(.rightMouseDown))
      hit.rightMouseUp(with: try mouse(.rightMouseUp))
      #expect(hit.menu(for: try mouse(.rightMouseDown)) == nil, "\(name)")
      if name == "empty" || name == "gap" || name == "belowArt" {
        hit.mouseDown(with: try mouse(.leftMouseDown))
        hit.mouseDragged(with: try mouse(.leftMouseDragged))
        hit.mouseUp(with: try mouse(.leftMouseUp))
      }
      let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
      cg.location = window.convertPoint(toScreen: location)
      let wheel = try #require(NSEvent(cgEvent: cg))
      hit.scrollWheel(with: wheel)
      wheels += 1
    }
    let leaked = actions.filter {
      switch $0 {
      case .hover, .scrolled, .media: false
      default: true
      }
    }
    #expect(leaked.isEmpty, "\(leaked)")
    #if DEBUG
    #expect(sidebar.scrollsForwarded - forwardedBefore == wheels)
    #endif
  }

  @Test func aViewDrawnOverTheCardKeepsItsHover() throws {
    let (window, root, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    let overlay = NSView(frame: root.convert(player.bounds, from: player).insetBy(dx: 20, dy: 10))
    root.addSubview(overlay)
    defer { overlay.removeFromSuperview() }
    let centre = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
    let windowPoint = overlay.convert(centre, to: nil)
    #expect(!FullScreenIslandCoverage.contains(windowPoint, in: window))
    overlay.removeFromSuperview()
    #expect(FullScreenIslandCoverage.contains(windowPoint, in: window))
  }

  @Test func enteringThroughACornerHoversOnceThePointerReachesTheCard() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      let location = player.convert(point, to: nil)
      if type == .mouseEntered {
        return try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
      }
      return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }
    player.mouseEntered(with: try event(.mouseEntered, CGPoint(x: 1, y: 1)))
    #expect(!player.cornersShown)
    player.mouseMoved(with: try event(.mouseMoved, CGPoint(x: player.bounds.midX, y: 30)))
    #expect(player.cornersShown)
  }

  @Test func theCloseButtonStaysShownWhenThePointerMovesOntoIt() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    func moved(_ point: CGPoint) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: .mouseMoved, location: player.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }
    player.mouseEntered(with: try moved(CGPoint(x: player.bounds.midX, y: 30)))
    #expect(player.cornersShown)
    let close = try #require(player.controlFrames["close"])
    player.mouseMoved(with: try moved(CGPoint(x: close.midX, y: close.midY)))
    #expect(player.cornersShown)
    let mute = try #require(player.controlFrames["mute"])
    player.mouseMoved(with: try moved(CGPoint(x: mute.midX, y: mute.midY)))
    #expect(player.cornersShown)
  }

  @Test func aPublishWhileThePointerIsOnTheCloseButtonKeepsItShown() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    post(CGPoint(x: player.bounds.midX, y: 30), from: player, in: window)
    #expect(player.cornersShown)
    let close = try #require(player.controlFrames["close"])
    let upperHalf = CGPoint(x: close.midX, y: close.minY + 1)
    #expect(!player.bounds.contains(upperHalf))
    post(upperHalf, from: player, in: window)
    #expect(player.cornersShown)
    post(upperHalf, from: player, in: window)
    #expect(player.cornersShown)
  }

  @Test func aHiddenCardShowsAgainWithItsCornersDown() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    post(CGPoint(x: player.bounds.midX, y: 30), from: player, in: window)
    let close = try #require(player.controlFrames["close"])
    post(CGPoint(x: close.midX, y: close.midY), from: player, in: window)
    #expect(player.cornersShown)
    player.isHidden = true
    player.isHidden = false
    #expect(!player.cornersShown)
  }

  @Test func theCornerButtonsAreBiggerSitCloserToTheCardAndCoverTheRowsTheyOverhang() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    post(CGPoint(x: player.bounds.midX, y: 30), from: player, in: window)
    #expect(player.cornersShown)
    let restingTitle = player.titleWidth
    let close = try #require(player.controlFrames["close"])
    let mute = try #require(player.controlFrames["mute"])
    #expect(close.size == CGSize(width: 20, height: 20))
    #expect(mute.size == CGSize(width: 24, height: 24))
    #expect(player.bounds.contains(mute))
    #expect(mute.minY > SidebarPlayerView.height / 2)
    #expect(close.maxX == player.bounds.width + 2)
    #expect(close.minY == -2)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    player.layoutSubtreeIfNeeded()
    let titleEnd = try #require(player.controlFrames["title"]).minX + player.titleWidth
    #expect(abs(titleEnd - (close.minX - 2)) < 0.5)
    #expect(player.titleWidth < restingTitle)
    let overhang = CGPoint(x: close.midX, y: close.minY + 1)
    #expect(!player.bounds.contains(overhang))
    #expect(FullScreenIslandCoverage.contains(player.convert(overhang, to: nil), in: window))
  }

  @Test func theCornerSliversOfTheCardTakeTheClickInsteadOfTheRowsBehind() throws {
    let (window, root, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    let sliver = CGPoint(x: 1, y: 1)
    let hit = try #require(root.hitTest(player.convert(sliver, to: root.superview)))
    #expect(hit === player)
    #expect(FullScreenIslandCoverage.contains(player.convert(sliver, to: nil), in: window))
  }

  #if DEBUG
  @Test func resizingTheSidebarPublishesCoverageOncePerTurn() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let before = FullScreenIslandCoverage.publishCount
    for width in stride(from: 221.0, through: 240.0, by: 1) {
      sidebar.setFrameSize(CGSize(width: width, height: 500))
      sidebar.layoutSubtreeIfNeeded()
    }
    #expect(player.frame.width > 0)
    #expect(FullScreenIslandCoverage.publishCount - before <= 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(FullScreenIslandCoverage.publishCount - before == 1)
  }

  @Test func theFirstAppearanceFadesIn() throws {
    let (window, _, sidebar, player) = try mount()
    defer { close(window, sidebar) }
    #expect(sidebar.playerFadesIn == 1)
    #expect(!player.isHidden)
  }
  #endif
}
