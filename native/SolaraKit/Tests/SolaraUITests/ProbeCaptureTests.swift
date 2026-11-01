#if SOLARA_PROBES
import AppKit
import QuartzCore
import SolaraProbes
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ProbeCaptureTests {
  @Test func ordinaryLayoutAndDisplayLeaveParticipantsAlone() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    var applied = 0
    ProbeCapture.shared.register(fixture.root) { _ in
      applied += 1
      return {}
    }
    let before = fixture.layers()
    fixture.root.needsLayout = true
    fixture.root.layoutSubtreeIfNeeded()
    fixture.root.displayIfNeeded()
    #expect(applied == 0)
    #expect(!fixture.glass.isHidden)
    #expect(fixture.mark.offsets == MarkIntroPlayer().offsets)
    before.forEach { $0.expectRestored() }
  }

  @Test(arguments: [false, true])
  func captureSubstitutesAndRestoresExactly(hidden: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.seedTransforms()
    fixture.glass.isHidden = hidden
    let before = fixture.layers()
    let offsets = fixture.mark.offsets
    let tileLayers = fixture.tile.layer?.sublayers ?? []
    let alpha = fixture.window.alphaValue
    let key = fixture.window.isKeyWindow
    let actionsDisabled = CATransaction.disableActions()
    try ProbeCapture.shared.withPreparedWindow(fixture.window) {
      #expect(CATransaction.disableActions())
      #expect(fixture.glass.isHidden)
      #expect(fixture.mark.offsets == .rest)
      for layer in fixture.mark.layer?.sublayers ?? [] {
        #expect(CATransform3DIsIdentity(layer.transform))
      }
      let added = (fixture.tile.layer?.sublayers ?? []).filter { layer in !tileLayers.contains { $0 === layer } }
      let fill = try #require(added.first)
      #expect(added.count == 1)
      #expect(fill.frame == fixture.tile.bounds)
      #expect(fill.cornerRadius == fixture.tile.radius)
      #expect(fill.backgroundColor == fixture.tile.tint?.cgColor)
      #expect(fill.isHidden == hidden)
      #expect(fixture.window.alphaValue == alpha)
      #expect(fixture.window.isKeyWindow == key)
    }
    #expect(fixture.glass.isHidden == hidden)
    #expect(fixture.mark.offsets == offsets)
    before.forEach { $0.expectRestored() }
    #expect(CATransaction.disableActions() == actionsDisabled)
    #expect(fixture.window.alphaValue == alpha)
    #expect(fixture.window.isKeyWindow == key)
  }

  @Test func visibleGlassGetsAVisibleFill() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let before = fixture.layers()
    let existing = fixture.tile.layer?.sublayers ?? []
    let result: Data? = try ProbeCapture.shared.withPreparedWindow(fixture.window) {
      let fill = try #require(fixture.tile.layer?.sublayers?.first)
      #expect(!existing.contains { $0 === fill })
      #expect(!fill.isHidden)
      #expect(fill.backgroundColor == fixture.tile.tint?.cgColor)
      return nil
    }
    #expect(result == nil)
    #expect(!fixture.glass.isHidden)
    before.forEach { $0.expectRestored() }
  }

  @Test(arguments: [false, true])
  func aLaterFailureRestoresParticipants(renderFails: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.seedTransforms()
    let before = fixture.layers()
    let offsets = fixture.mark.offsets
    var events: [String] = []
    ProbeCapture.shared.register(fixture.root) { [weak fixture] _ in
      guard let fixture else { return {} }
      #expect(fixture.glass.isHidden)
      #expect(fixture.mark.offsets == .rest)
      events.append("first")
      return { events.append("restoreFirst") }
    }
    ProbeCapture.shared.register(fixture.root) { _ in
      events.append("second")
      if !renderFails { throw Failure.stopped }
      return { events.append("restoreSecond") }
    }
    ProbeCapture.shared.register(fixture.root) { _ in
      events.append("third")
      return { events.append("restoreThird") }
    }
    #expect(throws: Failure.stopped) {
      try ProbeCapture.shared.withPreparedWindow(fixture.window) {
        events.append("render")
        throw Failure.stopped
      }
    }
    #expect(events == (renderFails
      ? ["first", "second", "third", "render", "restoreThird", "restoreSecond", "restoreFirst"]
      : ["first", "second", "restoreFirst"]))
    #expect(!fixture.glass.isHidden)
    #expect(fixture.mark.offsets == offsets)
    before.forEach { $0.expectRestored() }
  }

  @Test func onlyTheCapturedWindowIsPreparedEvenAfterAMove() throws {
    let first = try Fixture()
    let second = try Fixture()
    defer { first.close(); second.close() }
    let follower = NSView()
    let detached = NSView()
    first.root.addSubview(follower)
    var followed = 0
    var detachedApplied = 0
    ProbeCapture.shared.register(follower) { _ in
      followed += 1
      return {}
    }
    ProbeCapture.shared.register(detached) { _ in
      detachedApplied += 1
      return {}
    }
    let beforeFirst = first.layers()
    let beforeSecond = second.layers()
    let firstOffsets = first.mark.offsets
    let secondOffsets = second.mark.offsets
    try ProbeCapture.shared.withPreparedWindow(first.window) {
      #expect(first.glass.isHidden)
      #expect(first.mark.offsets == .rest)
      #expect(!second.glass.isHidden)
      #expect(second.mark.offsets == secondOffsets)
      beforeSecond.forEach { $0.expectRestored() }
      #expect(followed == 1)
    }
    second.root.addSubview(follower)
    try ProbeCapture.shared.withPreparedWindow(first.window) {
      #expect(followed == 1)
      #expect(!second.glass.isHidden)
      beforeSecond.forEach { $0.expectRestored() }
    }
    try ProbeCapture.shared.withPreparedWindow(second.window) {
      #expect(followed == 2)
      #expect(second.glass.isHidden)
      #expect(!first.glass.isHidden)
      #expect(first.mark.offsets == firstOffsets)
      beforeFirst.forEach { $0.expectRestored() }
    }
    #expect(detachedApplied == 0)
    #expect(!first.glass.isHidden && !second.glass.isHidden)
    beforeFirst.forEach { $0.expectRestored() }
    beforeSecond.forEach { $0.expectRestored() }
  }

  @Test func layoutAndDisplayPrecedePreparationAndRendering() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let root = CaptureContent(frame: fixture.root.bounds)
    fixture.window.contentView = root
    let registry = ProbeCapture()
    registry.register(root) { root in
      #expect(!root.needsLayout)
      #expect(CATransaction.disableActions())
      root.events.append("prepare")
      return { root.events.append("restore") }
    }
    root.events.removeAll()
    root.needsLayout = true
    try registry.withPreparedWindow(fixture.window) { root.events.append("render") }
    #expect(root.events.first == "layout")
    #expect(Array(root.events.suffix(4)) == ["display", "prepare", "render", "restore"])
  }

  @Test func registrationsDoNotRetainTheirViews() throws {
    let registry = ProbeCapture()
    weak var released: NSView?
    var applied = 0
    do {
      let view = NSView()
      released = view
      registry.register(view) { _ in
        applied += 1
        return {}
      }
    }
    #expect(released == nil)
    let fixture = try Fixture()
    defer { fixture.close() }
    try registry.withPreparedWindow(fixture.window) {}
    #expect(applied == 0)
  }

  private enum Failure: Error { case stopped }

  @MainActor
  private final class Fixture {
    let window: NSPanel
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let tile = SidebarGlassTile(frame: NSRect(x: 0, y: 0, width: 72, height: 41))
    let hero = NewTabHeroView(frame: NSRect(x: 100, y: 0, width: 700, height: 600))
    let glass: NSGlassEffectView
    let mark: MarkView

    init() throws {
      _ = NSApplication.shared
      glass = try #require(tile.subviews.compactMap { $0 as? NSGlassEffectView }.first)
      mark = try #require(hero.subviews.compactMap { $0 as? MarkView }.first)
      window = NSPanel(contentRect: root.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      root.wantsLayer = true
      root.addSubview(tile)
      root.addSubview(hero)
      tile.tint = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.3)
      tile.radius = 9
      tile.raisedSelection = true
      tile.outlineColor = .orange
      window.contentView = root
      root.layoutSubtreeIfNeeded()
      root.displayIfNeeded()
      mark.apply(MarkIntroPlayer().offsets)
      tile.layer?.backgroundColor = NSColor.purple.cgColor
      let extra = CALayer()
      extra.backgroundColor = NSColor.green.cgColor
      tile.layer?.addSublayer(extra)
    }

    func seedTransforms() {
      for (index, layer) in (mark.layer?.sublayers ?? []).enumerated() {
        layer.transform = CATransform3DMakeRotation(CGFloat(index + 1) / 10, 0, 1, 0)
      }
    }

    func layers() -> [LayerState] {
      [tile.layer, mark.layer].compactMap { $0 }.flatMap(LayerState.tree)
    }

    func close() {
      window.contentView = nil
      window.close()
    }
  }

  private final class CaptureContent: NSView {
    var events: [String] = []

    override func layout() {
      super.layout()
      events.append("layout")
    }

    override func displayIfNeeded() {
      super.displayIfNeeded()
      events.append("display")
    }
  }

  private struct LayerState {
    let layer: CALayer
    let hidden: Bool
    let transform: CATransform3D
    let fill: CGColor?
    let radius: CGFloat
    let sublayers: [CALayer]

    init(_ layer: CALayer) {
      self.layer = layer
      hidden = layer.isHidden
      transform = layer.transform
      fill = layer.backgroundColor
      radius = layer.cornerRadius
      sublayers = layer.sublayers ?? []
    }

    static func tree(_ layer: CALayer) -> [LayerState] {
      [LayerState(layer)] + (layer.sublayers ?? []).flatMap(tree)
    }

    func expectRestored() {
      #expect(layer.isHidden == hidden)
      #expect(CATransform3DEqualToTransform(layer.transform, transform))
      #expect(layer.backgroundColor == fill)
      #expect(layer.cornerRadius == radius)
      #expect((layer.sublayers ?? []).map(ObjectIdentifier.init) == sublayers.map(ObjectIdentifier.init))
    }
  }
}
#endif
