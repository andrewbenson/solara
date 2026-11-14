import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct ToolTourTests {
  static let stops: [String: ToolTourStop] = [
    "commandBar": ToolTourStop(id: "commandBar", title: "", body: "", anchored: true, placement: .below, radius: 20, pad: 6),
    "tabs": ToolTourStop(id: "tabs", title: "", body: "", anchored: true, placement: .right, radius: 10, pad: 4),
    "sidebar": ToolTourStop(id: "sidebar", title: "", body: "", anchored: true, placement: .below, radius: 9, pad: 3),
    "split": ToolTourStop(id: "split", title: "", body: "", anchored: true, placement: .inside, radius: 10, pad: -10),
    "done": ToolTourStop(id: "done", title: "", body: "", anchored: false),
    "bare": ToolTourStop(id: "bare", title: "", body: "", anchored: true),
  ]

  @Test func geometryMatchesTheRNFunctions() {
    #expect(RNCases.all.count > 300)
    for c in RNCases.all {
      let stop = Self.stops[c.stop]
      let hole = ToolTourLayout.spotlight(stop, target: c.target, size: c.size)
      let card = ToolTourLayout.placeCard(stop, spot: hole, size: c.size, height: c.height)
      let got = [hole.rect.minX, hole.rect.minY, hole.rect.width, hole.rect.height, hole.radius]
      #expect(zip(got, c.hole).allSatisfy { abs($0 - $1) < 0.0001 }, "\(c.stop) \(c.size) \(String(describing: c.target)) hole \(got) vs \(c.hole)")
      #expect(abs(card.x - c.card[0]) < 0.0001 && abs(card.y - c.card[1]) < 0.0001, "\(c.stop) \(c.size) \(String(describing: c.target)) card \(card) vs \(c.card)")
    }
  }

  static func state(session: Int, active: Bool = true, index: Int = 0, target: CGRect? = nil, dark: Bool = true, video: Bool = false) -> String {
    let stops = TourFixture.stops.map { s -> [String: Any] in
      var json: [String: Any] = ["id": s.id, "title": s.title, "body": s.body, "anchored": s.anchored, "placement": s.placement.rawValue]
      if let r = s.radius { json["radius"] = r }
      if let p = s.pad { json["pad"] = p }
      return json
    }
    var state: [String: Any] = ["session": session, "active": active, "index": index, "stops": active ? stops : [], "dark": dark, "video": video]
    if let target { state["target"] = ["x": target.minX, "y": target.minY, "width": target.width, "height": target.height] }
    let data = try! JSONSerialization.data(withJSONObject: state)
    return String(decoding: data, as: UTF8.self)
  }

  @Test func anOlderSessionNeverBringsTheTourBack() {
    let model = ToolTourModel()
    model.apply(Self.state(session: 2))
    #expect(model.visible)
    model.apply(Self.state(session: 2, active: false))
    #expect(!model.visible)
    model.apply(Self.state(session: 1))
    #expect(!model.visible)
    model.apply(Self.state(session: 3))
    #expect(model.visible)
  }

  @Test func clicksPassOnlyThroughTheHoleWhileShown() {
    let model = ToolTourModel()
    model.size = CGSize(width: 1360, height: 860)
    model.apply(Self.state(session: 1, target: CGRect(x: 447, y: 331, width: 651, height: 112)))
    #expect(model.passesThrough(CGPoint(x: 700, y: 380)))
    #expect(!model.passesThrough(CGPoint(x: 100, y: 100)))
    model.apply(Self.state(session: 1, index: 3, target: CGRect(x: 190, y: 47, width: 1163, height: 806)))
    model.cardHeight = 169
    let card = model.cardOrigin
    #expect(!model.passesThrough(CGPoint(x: card.x + 250, y: card.y + 140)))
    #expect(model.passesThrough(CGPoint(x: card.x - 20, y: card.y - 20)))
    model.apply(Self.state(session: 1, index: 4))
    #expect(!model.passesThrough(CGPoint(x: 680, y: 430)))
    model.apply(Self.state(session: 1, active: false))
    #expect(model.passesThrough(CGPoint(x: 100, y: 100)))
  }

  #if SOLARA_PROBES
  @Test func measuredControlsBelongToTheCurrentStopAndSession() {
    let model = ToolTourModel()
    let old = CGRect(x: 10, y: 20, width: 50, height: 28)
    let fresh = CGRect(x: 40, y: 60, width: 50, height: 28)
    model.apply(Self.state(session: 1))
    model.recordControlFrame("Next", frame: old, session: 1, index: 0)
    #expect(model.controlFrames["Next"] == old)
    model.apply(Self.state(session: 1, index: 1))
    #expect(model.controlFrames["Next"] == nil)
    model.recordControlFrame("Next", frame: old, session: 1, index: 0)
    #expect(model.controlFrames["Next"] == nil)
    model.recordControlFrame("Next", frame: fresh, session: 1, index: 1)
    #expect(model.controlFrames["Next"] == fresh)
    model.apply(Self.state(session: 2))
    #expect(model.controlFrames.isEmpty)
    model.recordControlFrame("Next", frame: old, session: 1, index: 0)
    #expect(model.controlFrames.isEmpty)
  }
  #endif

  @Test func theRingPulsesBetweenTheRNOpacities() {
    #expect(abs(TourRing.opacity(at: 0) - 0.45) < 0.0001)
    #expect(abs(TourRing.opacity(at: 1.1) - 1) < 0.0001)
    #expect(abs(TourRing.opacity(at: 2.2) - 0.45) < 0.0001)
    #expect(abs(TourRing.opacity(at: 0.55) - 0.725) < 0.0001)
  }

  @Test func eachButtonSendsItsCommand() {
    let model = ToolTourModel()
    var sent: [String] = []
    model.send = { sent.append($0) }
    model.apply(Self.state(session: 1, index: 4, video: true))
    #expect(model.last)
    model.send("next")
    #expect(sent == ["next"])
  }

  @Test func rendersEveryStepOverTheRNBackdrop() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["SOLARA_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }), let backdrop = env["TOUR_BACKDROP"].flatMap({ NSImage(contentsOfFile: $0) }) else { return }
    let size = NSSize(width: 1360, height: 860)
    let targets: [CGRect?] = [
      CGRect(x: 446.5, y: 331, width: 652, height: 112), CGRect(x: 7, y: 70, width: 177, height: 34), CGRect(x: 196, y: 12, width: 30, height: 30),
      CGRect(x: 190, y: 47, width: 1163, height: 806), nil,
    ]
    for (index, target) in targets.enumerated() {
      let host = ToolTourHost()
      host.model.apply(Self.state(session: 1, index: index, target: target))
      try await render(host, backdrop: backdrop, size: size, to: directory.appendingPathComponent("step\(index).png"))
    }
  }

  func render(_ host: ToolTourHost, backdrop: NSImage, size: NSSize, to url: URL) async throws {
    _ = NSApplication.shared
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    let image = NSImageView(frame: root.bounds)
    image.image = backdrop
    image.imageScaling = .scaleAxesIndependently
    root.addSubview(image)
    host.frame = root.bounds
    root.addSubview(host)
    let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.colorSpace = .sRGB
    window.contentView = root
    for _ in 0..<20 {
      root.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      spin()
    }
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    window.contentView = nil
    window.close()
  }

  func spin() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}

enum TourFixture {
  static let stops: [ToolTourStop] = [
    ToolTourStop(
      id: "commandBar", title: "Search or go anywhere",
      body: "Type a question, an address or the name of an open tab. ⌘L brings the command bar up from any page, and ⌘T opens a new tab.", anchored: true,
      placement: .below, radius: 20, pad: 6),
    ToolTourStop(
      id: "tabs", title: "Your tabs live in the sidebar",
      body: "New tabs land here. Drag them to reorder or group them; right-click one to pin it, so it's always a click away.", anchored: true, placement: .right,
      radius: 10, pad: 4),
    ToolTourStop(
      id: "sidebar", title: "Room to focus", body: "⌘S hides the sidebar. Move the pointer to the window's left edge to peek at your tabs while it's hidden.",
      anchored: true, placement: .below, radius: 9, pad: 3),
    ToolTourStop(
      id: "split", title: "Two pages, side by side",
      body: "Drag a tab onto the page to split the window, or press ⌃⇧=. ⌃⇧] and ⌃⇧[ move between the panes.", anchored: true, placement: .inside, radius: 10,
      pad: -10),
    ToolTourStop(
      id: "done", title: "You're all set", body: "Everything else is in the menu bar and in Settings (⌘,). You can take this tour again from the Help menu.",
      anchored: false),
  ]
}
