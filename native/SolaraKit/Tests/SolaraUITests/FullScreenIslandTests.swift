import AppKit
import Testing
@testable import SolaraUI

struct FullScreenIslandTests {
  let windowedButtons = [CGFloat(18), 41, 64].map { CGRect(x: $0, y: 20, width: 14, height: 14) }

  func placement(fullscreen: Bool = true, page: Bool = false, reveal: CGFloat = 1, menuBottom: CGFloat = 0, center: CGPoint = CGPoint(x: 25, y: 27)) -> FullScreenIslandPlacement {
    FullScreenIslandPlacement(fullscreen: fullscreen, page: page, reveal: reveal, menuBottom: menuBottom, closeCenter: center, windowedButtons: windowedButtons)
  }

  @Test func windowedAndRestingFullscreenNeverShowTheIsland() {
    #expect(placement(fullscreen: false).frame == nil)
    #expect(placement(reveal: 0).frame == nil)
    #expect(placement(page: true).frame == nil)
    #expect(FullScreenIslandPlacement(fullscreen: true, page: false, reveal: 1, menuBottom: 26,
      closeCenter: .zero, windowedButtons: []).frame == nil)
  }

  @Test func neverHideRevealKeepsTheLightsAtTheirWindowedHeaderPosition() {
    for reveal: CGFloat in [0.1, 0.5, 1] {
      let shown = placement(reveal: reveal)
      #expect(shown.frame == CGRect(x: 14, y: 16, width: 68, height: 22))
      let expectedButtons = [CGFloat(11), 34, 57].map { CGRect(x: $0 - 7, y: 4, width: 14, height: 14) }
      #expect(shown.buttonFrames == expectedButtons)
      #expect(shown.frame!.minX + shown.buttonFrames[0].midX == 25)
      #expect(shown.frame!.minY + shown.buttonFrames[0].midY == 27)
    }
  }

  @Test func enteringWithAClosedSidebarUsesTheLiveLightsAnchor() {
    for offset in [CGPoint(x: -190, y: 0), CGPoint(x: 0, y: -190)] {
      let captured = windowedButtons.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
      let shown = FullScreenIslandPlacement(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: captured)
      #expect(shown.frame == CGRect(x: 14, y: 16, width: 68, height: 22))
      #expect(shown.buttonFrames == placement().buttonFrames)
    }
  }

  @Test func islandTracksTheShiftedHeaderThroughoutRevealInEveryLayout() {
    for header in [CGRect(x: 0, y: 6, width: 190, height: 42), CGRect(x: 0, y: 6, width: 56, height: 42), CGRect(x: 0, y: 0, width: 1000, height: 42)] {
      for menuBottom: CGFloat in [0, 24, 26, 37] {
        for progress: CGFloat in [0.1, 0.25, 0.5, 0.75, 1] {
          let shown = placement(reveal: progress, menuBottom: menuBottom, center: CGPoint(x: 25, y: header.midY))
          #expect(shown.frame!.midY == header.midY + menuBottom * progress)
          #expect(shown.frame!.size == CGSize(width: 68, height: 22))
          #expect(shown.frame!.minX + shown.buttonFrames[0].midX == 25)
        }
      }
    }
    #expect(placement(reveal: 2, menuBottom: 26).frame == placement(menuBottom: 26).frame)
    #expect(placement(reveal: -1, menuBottom: 26).frame == nil)
  }

  @Test func scrimsOnlyCoverRevealedFullSidebarAndUnnamedHorizontalHeaders() {
    let header = CGRect(x: 0, y: 6, width: 190, height: 42)
    for offset: CGFloat in [0, 13, 26] {
      for width: CGFloat in [0, 56, 190] {
        let sidebar = CGRect(x: 0, y: 0, width: width, height: 700)
        let backdrop = FullScreenIslandBackdropPlacement(topTabs: false, profileName: true,
          sidebar: sidebar, header: header, offset: offset)
        #expect((backdrop.corner != nil) == (offset > 0 && width > 56))
        #expect((backdrop.edge != nil) == (offset > 0 && width > 56))
        #expect(backdrop.horizontal == nil)
      }
      for named in [false, true] {
        let horizontal = FullScreenIslandBackdropPlacement(topTabs: true, profileName: named,
          sidebar: .zero, header: header, offset: offset)
        #expect(horizontal.corner == nil)
        #expect(horizontal.edge == nil)
        #expect((horizontal.horizontal != nil) == !named)
      }
    }
  }

  @Test func rightSidebarNeverDrawsACornerScrimAtTheCaption() {
    let backdrop = FullScreenIslandBackdropPlacement(topTabs: false, profileName: true,
      sidebar: CGRect(x: 810, y: 0, width: 190, height: 700),
      header: CGRect(x: 0, y: 6, width: 1000, height: 42), offset: 26)
    #expect(backdrop.corner == nil)
    #expect(backdrop.edge == nil)
    #expect(backdrop.horizontal == nil)
  }

  @MainActor @Test func scrimSamplesTheActualBackdropAndMasksEveryOpenEdge() throws {
    for colors in [[NSColor.systemPink, NSColor.white], [NSColor.systemPurple, NSColor.black]] {
      let source = FullScreenBackdropFixture(colors: colors)
      source.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
      source.layoutSubtreeIfNeeded()
      let sample = FullScreenIslandBackdropSample()
      sample.update(source)
      let image = try #require(sample.image)
      let original = try #require(source.bitmapImageRepForCachingDisplay(in: source.bounds))
      source.cacheDisplay(in: source.bounds, to: original)
      #expect(image.width == original.pixelsWide)
      #expect(image.height == original.pixelsHigh)
      let expectedSpace = try #require(original.cgImage?.colorSpace)
      let actualSpace = try #require(image.colorSpace)
      #expect(CFEqual(expectedSpace, actualSpace))
      let captured = NSBitmapImageRep(cgImage: image)
      for (x, y) in [(20, 20), (180, 70), (100, 500)] {
        let expected = try #require(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let actual = try #require(captured.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        #expect(abs(expected.redComponent - actual.redComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
        #expect(abs(expected.greenComponent - actual.greenComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
        #expect(abs(expected.blueComponent - actual.blueComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
      }
      let cachedImage = sample.image
      sample.update(source)
      #expect(sample.image === cachedImage)
      let scrim = FullScreenIslandScrim()
      let parent = FlippedContainerView(frame: source.frame)
      parent.addSubview(source)
      parent.addSubview(scrim)
      scrim.place(CGRect(x: 0, y: 0, width: 220, height: 104), opacity: 1, source: source, sample: sample)
      let mask = try #require(scrim.layer?.mask as? CAGradientLayer)
      let bottom = try #require(mask.mask as? CAGradientLayer)
      #expect(mask.frame == scrim.bounds)
      #expect(bottom.frame == scrim.bounds)
      #expect(mask.endPoint == CGPoint(x: 1, y: 0.5))
      #expect(bottom.endPoint == CGPoint(x: 0.5, y: 1))
      let rightAlpha = try fullScreenTestColor(mask.colors?.last).alpha
      let bottomAlpha = try fullScreenTestColor(bottom.colors?.last).alpha
      #expect(rightAlpha == 0)
      #expect(bottomAlpha == 0)
      #expect(scrim.hitTest(.zero) == nil)
      #expect(try fullScreenTestImage(scrim.layer?.sublayers?.first?.contents) === image)
    }
  }

  @MainActor @Test func horizontalScrimFadesBothOpenRowEdges() throws {
    let source = FullScreenBackdropFixture(colors: [.systemPink, .white])
    source.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let parent = FlippedContainerView(frame: source.frame)
    parent.addSubview(source)
    let sample = FullScreenIslandBackdropSample()
    sample.update(source)
    let scrim = FullScreenIslandScrim(.horizontal)
    parent.addSubview(scrim)
    scrim.place(CGRect(x: 0, y: 26, width: 150, height: 42), opacity: 1, source: source, sample: sample)
    let horizontal = try #require(scrim.layer?.mask as? CAGradientLayer)
    let vertical = try #require(horizontal.mask as? CAGradientLayer)
    #expect(horizontal.frame == scrim.bounds)
    #expect(vertical.frame == scrim.bounds)
    #expect(try fullScreenTestColor(horizontal.colors?.last).alpha == 0)
    #expect(try fullScreenTestColor(vertical.colors?.first).alpha == 0)
    #expect(try fullScreenTestColor(vertical.colors?.last).alpha == 0)
    #expect(vertical.locations == [0, 0.15, 0.65, 1])
  }

  @MainActor @Test func sampledMaterialNeverCreatesAnotherVisualEffectView() throws {
    let source = FullScreenCopyFixture(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
    let parent = FlippedContainerView(frame: source.frame)
    parent.addSubview(source)
    source.layoutSubtreeIfNeeded()
    let sample = FullScreenIslandBackdropSample()
    sample.update(source)
    let image = try #require(sample.image)
    let scrim = FullScreenIslandScrim()
    parent.addSubview(scrim)
    let rect = CGRect(x: 0, y: 0, width: 220, height: 104)
    scrim.place(rect, opacity: 1, source: source, sample: sample)
    #expect(scrim.subviews.isEmpty)
    #expect(try fullScreenTestImage(scrim.layer?.sublayers?.first?.contents) === image)
    let mask = try #require(scrim.layer?.mask as? CAGradientLayer)
    let bottom = try #require(mask.mask as? CAGradientLayer)
    #expect(mask.frame == scrim.bounds)
    #expect(bottom.frame == scrim.bounds)
    #expect(try fullScreenTestColor(mask.colors?.last).alpha == 0)
    #expect(try fullScreenTestColor(bottom.colors?.last).alpha == 0)
    source.fill.gradient.colors = [NSColor.black.cgColor, NSColor.systemPink.cgColor]
    sample.update(source)
    scrim.place(rect, opacity: 1, source: source, sample: sample)
    #expect(sample.image !== image)
    scrim.place(nil, opacity: 0, source: nil, sample: sample)
    sample.clear()
    #expect(scrim.isHidden)
    #expect(scrim.subviews.isEmpty)
    #expect(sample.image == nil)
    #expect(sample.signature.isEmpty)
  }

  @MainActor @Test func samplerUsesTheBackdropRendererWhenAppKitCannotCaptureItsSurface() throws {
    let source = FullScreenImageFixture(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let sample = FullScreenIslandBackdropSample()
    sample.update(source)
    let image = try #require(sample.image)
    let captured = NSBitmapImageRep(cgImage: image)
    let pixel = try #require(captured.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
    #expect(source.captures == 1)
    #expect(pixel.redComponent > 0.9)
    #expect(pixel.greenComponent < 0.1)
    #expect(pixel.blueComponent > 0.9)
    #expect(pixel.alphaComponent == 1)
    sample.update(source)
    #expect(source.captures == 1)
    for opacity: CGFloat in [0.25, 0.4, 0.7, 1] {
      source.alphaValue = opacity
      sample.update(source)
      let image = try #require(sample.image)
      let pixel = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
      #expect(abs(pixel.alphaComponent - opacity) < 0.005)
      #expect(pixel.redComponent > 0.99)
      #expect(pixel.greenComponent < 0.005)
      #expect(pixel.blueComponent > 0.99)
      #expect(source.alphaValue == opacity)
    }
  }

  @MainActor @Test func sampleMatchesTheVisibleSidebarFillOverItsExistingUnderfill() throws {
    for underfill in [NSColor.white, NSColor.black] {
      let owner = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
      owner.wantsLayer = true
      owner.layer?.backgroundColor = underfill.cgColor
      let source = FullScreenBackdropFixture(colors: [NSColor.magenta.withAlphaComponent(0.4), NSColor.systemPurple.withAlphaComponent(0.4)])
      source.frame = owner.bounds
      owner.addSubview(source)
      owner.layoutSubtreeIfNeeded()
      let original = try #require(owner.bitmapImageRepForCachingDisplay(in: owner.bounds))
      owner.cacheDisplay(in: owner.bounds, to: original)
      let sample = FullScreenIslandBackdropSample()
      sample.update([source], in: owner)
      let image = try #require(sample.image)
      let captured = NSBitmapImageRep(cgImage: image)
      for (x, y) in [(20, 20), (180, 70), (100, 250)] {
        let expected = try #require(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let actual = try #require(captured.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        #expect(abs(expected.redComponent - actual.redComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
        #expect(abs(expected.greenComponent - actual.greenComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
        #expect(abs(expected.blueComponent - actual.blueComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
        #expect(actual.alphaComponent == 1)
      }
    }
  }

  @MainActor @Test func sampleIncludesProfileTintAndInvalidatesForThemeAppearanceAndSize() throws {
    let owner = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let base = FullScreenBackdropFixture(colors: [.white, .lightGray])
    let tint = FullScreenBackdropFixture(colors: [.systemPink, .systemPurple])
    for view in [base, tint] {
      view.frame = owner.bounds
      owner.addSubview(view)
      view.layoutSubtreeIfNeeded()
    }
    tint.alphaValue = 0.4
    let sample = FullScreenIslandBackdropSample()
    sample.update([base, tint], in: owner)
    let first = try #require(sample.image)
    let rasterScale = CGFloat(first.width) / sample.bounds.width
    let combined = try #require(owner.bitmapImageRepForCachingDisplay(in: owner.bounds))
    owner.cacheDisplay(in: owner.bounds, to: combined)
    let captured = NSBitmapImageRep(cgImage: first)
    for (x, y) in [(20, 20), (180, 70), (100, 250)] {
      let expected = try #require(combined.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      let actual = try #require(captured.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      #expect(abs(expected.redComponent - actual.redComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
      #expect(abs(expected.greenComponent - actual.greenComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
      #expect(abs(expected.blueComponent - actual.blueComponent) < 0.005, "pixel \(x),\(y): expected \(expected), sampled \(actual)")
    }
    tint.gradient.colors = [NSColor.systemTeal.cgColor, NSColor.black.cgColor]
    sample.update([base, tint], in: owner)
    #expect(sample.image !== first)
    let changed = try #require(sample.image)
    owner.appearance = NSAppearance(named: .darkAqua)
    sample.update([base, tint], in: owner)
    #expect(sample.image !== changed)
    owner.frame.size.width = 500
    sample.update([base, tint], in: owner)
    #expect(sample.bounds.width == 500)
    let resized = try #require(sample.image)
    #expect(resized.width == Int(ceil(sample.bounds.width * rasterScale)))
    #expect(resized.height == Int(ceil(sample.bounds.height * rasterScale)))
  }

  @MainActor @Test func windowedProfileSharesTheLightsRowAndFullscreenRestUsesTheLeadingEdge() {
    let view = SidebarChromeView(frame: CGRect(x: 0, y: 0, width: 190, height: 700))
    var state = SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: false, addressBar: false, dark: false, theme: [:], dots: [], savedWidth: 190)
    view.update(state)
    view.layoutSubtreeIfNeeded()
    let title = view.indicator.subviews.compactMap { $0 as? StripLabel }.first!
    let windowed = title.convert(title.bounds, to: view)
    #expect(windowed.minX == 86)
    #expect(windowed.minX - windowedButtons[2].maxX == 8)
    #expect(windowed.midY == 27)
    state.windowFullscreen = true
    view.update(state)
    view.layoutSubtreeIfNeeded()
    let resting = title.convert(title.bounds, to: view)
    #expect(resting.minX == 15)
    #expect(resting.midY == 27)
    state.windowFullscreen = false
    view.update(state)
    view.layoutSubtreeIfNeeded()
    #expect(title.convert(title.bounds, to: view) == windowed)
  }

  @MainActor @Test func frameViewOverlayPreservesContentAndWindowedLightsForBothCoordinateSystems() {
    for flipped in [false, true] {
      let parent: NSView = flipped
        ? FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        : NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
      parent.bounds.origin = CGPoint(x: 12, y: 19)
      let content = NSView(frame: parent.bounds)
      parent.addSubview(content)
      let standardLights = windowedButtons.map { NSView(frame: $0) }
      standardLights.forEach { parent.addSubview($0) }
      let island = FullScreenIslandView(frame: .zero)
      parent.addSubview(island)
      let values = windowedButtons.map { NSValue(rect: $0) }
      for menuBottom: CGFloat in [0, 24, 37, 0] {
        island.update(fullscreen: true, page: false, reveal: 1, menuBottom: menuBottom, closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
        let glass = island.subviews.compactMap { $0 as? NSGlassEffectView }.first!
        #expect(island.frame == parent.bounds)
        #expect(glass.frame == CGRect(x: 14, y: 16 + menuBottom, width: 68, height: 22))
        #expect(glass.cornerRadius == 11)
        let buttons = glass.contentView!.subviews.compactMap { $0 as? NSButton }
        let centers = buttons.map { glass.frame.minX + $0.frame.midX }
        #expect(centers == [25, 48, 71])
        let aligned = buttons.allSatisfy { $0.frame.midY == 11 }
        #expect(aligned)
        #expect(content.frame == parent.bounds)
        let standardFrames = standardLights.map(\.frame)
        #expect(standardFrames == windowedButtons)
        #expect(island.hitTest(island.convert(CGPoint(x: 500, y: 500), to: parent)) == nil)
      }
      for (fullscreen, page, reveal) in [(true, false, CGFloat(0)), (true, true, CGFloat(1)), (false, false, CGFloat(1))] {
        island.update(fullscreen: fullscreen, page: page, reveal: reveal, menuBottom: 26, closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
        #expect(island.isHidden)
        #expect(content.frame == parent.bounds)
        let standardFrames = standardLights.map(\.frame)
        #expect(standardFrames == windowedButtons)
      }
    }
  }
  @MainActor @Test func nativeScrimsFollowLayoutAndNeverHideHasNoScrim() {
    for (topTabs, width, name, dock) in [(false, CGFloat(190), true, CGFloat(1)), (false, CGFloat(56), true, CGFloat(1)),
      (false, CGFloat(190), true, CGFloat(0)), (true, CGFloat(190), true, CGFloat(1)), (true, CGFloat(190), false, CGFloat(1))] {
      let parent = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
      let shell = WindowShellView(windowId: "island-scrim")
      shell.frame = parent.bounds
      parent.addSubview(shell)
      let source = FullScreenBackdropFixture(colors: [.systemPink, .white])
      shell.mount(.backdrop, source)
      let strip = FlippedContainerView()
      shell.mount(.topStrip, strip)
      shell.update {
        $0.dock = dock
        $0.topTabs = topTabs
        $0.sidebarWidth = width
      }
      shell.fullScreenProfileNameShown = name
      let island = FullScreenIslandView(frame: .zero)
      parent.addSubview(island)
      let values = windowedButtons.map { NSValue(rect: $0) }
      for menuBottom: CGFloat in [0, 26] {
        island.update(fullscreen: true, page: false, reveal: 0.5, menuBottom: menuBottom,
          closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
        let glass = island.subviews.compactMap { $0 as? NSGlassEffectView }.first!
        #expect(glass.frame.midY == shell.fullScreenHeaderRect.midY + shell.fullScreenStripOffset)
        #expect(glass.alphaValue == 0.5)
        let scrims = island.subviews.compactMap { $0 as? FullScreenIslandScrim }
        let visible = scrims.filter { !$0.isHidden }.count
        let expected = topTabs ? (name ? 0 : 1) : menuBottom == 0 || width <= 56 || dock == 0 ? 0 : 2
        #expect(visible == expected)
        let material = island.subviews.contains { $0 is NSVisualEffectView }
        #expect(!material)
      }
      island.update(fullscreen: true, page: false, reveal: 0, menuBottom: 26,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
      #expect(island.isHidden)
      #expect(shell.fullScreenStripOffset == 0)
      island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 26,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
      island.removeFromSuperview()
      #expect(shell.fullScreenStripOffset == 0)
      #expect(!shell.input.windowFullscreen)
      #expect(CATransform3DIsIdentity(strip.layer!.transform))
    }
  }

  @MainActor @Test func horizontalNameDetectionFollowsTheActualLeadingProfileSlot() {
    let parent = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let shell = WindowShellView(windowId: "island-name")
    shell.frame = parent.bounds
    shell.update { $0.topTabs = true }
    parent.addSubview(shell)
    shell.mount(.backdrop, FullScreenBackdropFixture(colors: [.systemPink, .white]))
    let row = FlippedContainerView()
    let controls = StripControlsView()
    controls.update(StripControlsState(title: "A", incognito: false, profiles: 2, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    controls.frame = CGRect(x: 8, y: 4, width: controls.width, height: 34.5)
    row.addSubview(controls)
    shell.mount(.topStrip, row)
    let island = FullScreenIslandView(frame: .zero)
    parent.addSubview(island)
    let values = windowedButtons.map { NSValue(rect: $0) }
    let update = {
      row.layoutSubtreeIfNeeded()
      island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 26,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
    }
    update()
    let scrims = island.subviews.compactMap { $0 as? FullScreenIslandScrim }
    let allHidden = scrims.allSatisfy { $0.isHidden }
    #expect(allHidden)
    controls.frame.origin.x = 800
    update()
    let visibleAway = scrims.filter { !$0.isHidden }.count
    #expect(visibleAway == 1)
    controls.frame.origin.x = 8
    controls.update(StripControlsState(title: "A", incognito: false, profiles: 1, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: nil), theme: [:])
    update()
    let visibleUnnamed = scrims.filter { !$0.isHidden }.count
    #expect(visibleUnnamed == 1)
    island.removeFromSuperview()
  }
}

@MainActor
final class FullScreenBackdropFixture: NSView {
  let gradient = CAGradientLayer()

  init(colors: [NSColor]) {
    super.init(frame: .zero)
    wantsLayer = true
    gradient.colors = colors.map(\.cgColor)
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    layer?.addSublayer(gradient)
  }

  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    gradient.frame = bounds
  }
}

@MainActor
private final class FullScreenCopyFixture: NSView {
  let material = NSVisualEffectView()
  let fill = FullScreenBackdropFixture(colors: [.systemPink, .white])

  override var isFlipped: Bool { true }

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    material.material = .underWindowBackground
    material.blendingMode = .behindWindow
    addSubview(material)
    addSubview(fill)
    needsLayout = true
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    material.frame = bounds
    fill.frame = bounds
    fill.layoutSubtreeIfNeeded()
  }
}

@MainActor
private final class FullScreenImageFixture: NSView {
  private(set) var captures = 0
  @objc var fullScreenBackdropOpacity: CGFloat { alphaValue }

  @objc func fullScreenBackdropImage() -> NSBitmapImageRep? {
    captures += 1
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep, let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    graphics.cgContext.setFillColor(NSColor.magenta.cgColor)
    graphics.cgContext.fill(bounds)
    return rep
  }
}

func fullScreenTestColor(_ value: Any?) throws -> CGColor {
  let value = try #require(value)
  try #require(CFGetTypeID(value as CFTypeRef) == CGColor.typeID)
  return value as! CGColor
}

func fullScreenTestImage(_ value: Any?) throws -> CGImage {
  let value = try #require(value)
  try #require(CFGetTypeID(value as CFTypeRef) == CGImage.typeID)
  return value as! CGImage
}
