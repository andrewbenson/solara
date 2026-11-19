import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@Suite(.serialized)
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

  @Test func capsuleMatchesRexWithoutMovingTheRevealedButtons() {
    let shown = placement()
    #expect(shown.frame == CGRect(x: 8, y: 10.5, width: 80, height: 33))
    let expectedButtons = [CGFloat(10), 33, 56].map { CGRect(x: $0, y: 9.5, width: 14, height: 14) }
    #expect(shown.buttonFrames == expectedButtons)
    #expect(shown.frame!.height / 2 == 16.5)
    #expect(shown.buttonFrames[0].minX == 10)
    #expect(shown.frame!.width - shown.buttonFrames[2].maxX == 10)
    for (index, button) in shown.buttonFrames.enumerated() {
      #expect(shown.frame!.minX + button.midX == 25 + CGFloat(index) * 23)
      #expect(shown.frame!.minY + button.midY == 27)
      #expect(button.minY == 9.5)
      #expect(shown.frame!.height - button.maxY == 9.5)
    }
  }

  @Test func enteringWithAClosedSidebarUsesTheLiveLightsAnchor() {
    for offset in [CGPoint(x: -190, y: 0), CGPoint(x: 0, y: -190)] {
      let captured = windowedButtons.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
      let shown = FullScreenIslandPlacement(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: captured)
      #expect(shown.frame == CGRect(x: 8, y: 10.5, width: 80, height: 33))
      #expect(shown.buttonFrames == placement().buttonFrames)
    }
  }

  @Test func islandSlidesFromAboveTheTopEdgeUsingTheToolbarRevealProgress() {
    for header in [CGRect(x: 0, y: 6, width: 190, height: 42), CGRect(x: 0, y: 6, width: 56, height: 42), CGRect(x: 0, y: 0, width: 1000, height: 42)] {
      for menuBottom: CGFloat in [0, 24, 26, 37] {
        let center = CGPoint(x: 25, y: header.midY)
        let start = placement(reveal: 0, menuBottom: menuBottom, center: center)
        #expect(start.slideOffset == -(header.midY + 16.5))
        for progress: CGFloat in [0.1, 0.25, 0.5, 0.75, 1] {
          let shown = placement(reveal: progress, menuBottom: menuBottom, center: center)
          let offset = -(header.midY + 16.5) * (1 - progress)
          #expect(abs(shown.slideOffset - offset) < 0.0001)
          #expect(abs(shown.frame!.midY - (header.midY + menuBottom * progress + offset)) < 0.0001)
          #expect(shown.frame!.size == CGSize(width: 80, height: 33))
          #expect(shown.frame!.minX + shown.buttonFrames[0].midX == 25)
        }
        let end = placement(reveal: 1, menuBottom: menuBottom, center: center)
        #expect(end.slideOffset == 0)
        #expect(end.frame!.midY == header.midY + menuBottom)
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
    owner.appearance = NSAppearance(named: .aqua)
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
        #expect(glass.frame == CGRect(x: 8, y: 10.5 + menuBottom, width: 80, height: 33))
        #expect(glass.cornerRadius == 16.5)
        let buttons = glass.contentView!.subviews.compactMap { $0 as? NSButton }
        let centers = buttons.map { glass.frame.minX + $0.frame.midX }
        #expect(centers == [25, 48, 71])
        let aligned = buttons.allSatisfy { $0.frame.midY == 16.5 }
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
  @MainActor @Test func darkMaterialKeepsALightRimAcrossSidebarAndProfileFills() throws {
    let island = FullScreenIslandView(frame: .zero)
    let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
    let layer = try #require(glass.contentView?.layer)
    let fillColor = try #require(layer.backgroundColor)
    let rimColor = try #require(layer.borderColor)
    let fill = try #require(NSColor(cgColor: fillColor)?.usingColorSpace(.sRGB))
    let rim = try #require(NSColor(cgColor: rimColor)?.usingColorSpace(.sRGB))
    let channels = [fill.redComponent, fill.greenComponent, fill.blueComponent]
    let rimChannels = [rim.redComponent, rim.greenComponent, rim.blueComponent]
    #expect(abs(fill.alphaComponent - 0.9) < 0.0001)
    for (actual, expected) in zip(channels, [CGFloat(34), 52, 72]) {
      #expect(abs(actual * 255 - expected) < 0.01)
    }
    for (actual, expected) in zip(rimChannels, [CGFloat(57), 74, 93]) {
      #expect(abs(actual * 255 - expected) < 0.01)
    }
    let backgrounds: [[CGFloat]] = [[3, 12, 22], [0, 0, 0], [255, 255, 255], [255, 80, 150], [150, 80, 220], [40, 190, 200]]
    for (index, background) in backgrounds.enumerated() {
      let composite = zip(channels, background).map { pair in pair.0 * fill.alphaComponent + pair.1 / 255 * (1 - fill.alphaComponent) }
      for (edge, face) in zip(rimChannels, composite) { #expect(edge > face) }
      if index == 0 {
        for (actual, expected) in zip(composite, [CGFloat(31), 48, 67]) {
          #expect(abs(actual * 255 - expected) < 1)
        }
      }
    }
    #expect(glass.appearance?.name == .darkAqua)
    #expect(glass.style == .clear)
  }

  @MainActor @Test func minimizeUsesTheSystemDisabledStateOnlyInFullscreen() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for (topTabs, width) in [(false, CGFloat(190)), (false, CGFloat(42)), (true, CGFloat(190))] {
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.alphaValue = 0
      let parent = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
      window.contentView = parent
      let shell = WindowShellView(windowId: "island-buttons")
      shell.frame = parent.bounds
      parent.addSubview(shell)
      shell.update {
        $0.dock = 1
        $0.topTabs = topTabs
        $0.sidebarWidth = width
      }
      let island = FullScreenIslandView(frame: .zero)
      parent.addSubview(island)
      defer {
        island.removeFromSuperview()
        shell.stopLayoutMotion()
        window.contentView = nil
        window.close()
      }
      let values = windowedButtons.map { NSValue(rect: $0) }
      let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
      let buttons = try #require(glass.contentView).subviews.compactMap { $0 as? NSButton }
      #expect(buttons.count == 3)
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for fullscreen in [false, true, false] {
          for reveal: CGFloat in [0, 0.25, 1, 0] {
            island.update(fullscreen: fullscreen, page: false, reveal: reveal, menuBottom: 26,
              closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(buttons[0].isEnabled)
            #expect(buttons[1].isEnabled == !fullscreen)
            #expect(buttons[2].isEnabled)
          }
        }
      }
    }
  }

  @MainActor @Test func iconsRailKeepsMinimizeDisabledWhenCaptionPlacementReentersTheIsland() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let parent = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    window.contentView = parent
    let shell = WindowShellView(windowId: "island-icons")
    shell.frame = parent.bounds
    parent.addSubview(shell)
    shell.update {
      $0.dock = 1
      $0.topTabs = false
    }
    shell.setSidebarWidth(SidebarRail.width, animated: false)
    let react = FlippedContainerView()
    shell.mount(.react, react)
    let owner = FlippedContainerView(frame: shell.frames.card)
    react.addSubview(owner)
    let toolbar = ToolbarView(frame: owner.bounds)
    owner.addSubview(toolbar)
    let toolbarJSON = """
      {"tabId":"a","height":41,"bare":false,"focused":true,"windowToolbar":true,
       "palette":\(ToolbarWebKitPillTests.palette),"accent":"#80506A",
       "geometry":{"back":38,"forward":70,"reload":102,"urlLeft":130,"urlRight":8},
       "left":[],"url":{"host":"example.com","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false},
       "right":[],"rightInset":8,"hairline":false}
      """
    toolbar.update(try #require(ToolbarState.decode(toolbarJSON)))
    shell.registerToolbar(toolbar, owner: owner)
    let dock = SidebarDock(shell: shell, state: SidebarDockState(width: Double(SidebarRail.width)))
    let island = FullScreenIslandView(frame: .zero)
    parent.addSubview(island)
    defer {
      dock.onLights = { _ in }
      dock.stop()
      shell.unregisterToolbar(toolbar)
      island.removeFromSuperview()
      shell.stopLayoutMotion()
      window.contentView = nil
      window.close()
    }
    let values = windowedButtons.map { NSValue(rect: $0) }
    let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
    let buttons = try #require(glass.contentView).subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 3)
    var updatingCaption = false
    var nestedCaptionUpdates = 0
    let updateCaption: (CGPoint?) -> Void = { center in
      if updatingCaption { nestedCaptionUpdates += 1 }
      island.update(fullscreen: shell.input.windowFullscreen, page: false, reveal: 0, menuBottom: 26,
        closeCenter: center ?? CGPoint(x: 25, y: 27), windowedButtons: values)
    }
    for fullscreen in [true, false, true] {
      dock.onLights = updateCaption
      for reveal: CGFloat in [1, 0.25, 0] {
        updatingCaption = true
        island.update(fullscreen: fullscreen, page: false, reveal: reveal, menuBottom: 26,
          closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
        updatingCaption = false
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(shell.toolbarSitsOnFrame(toolbar) == !fullscreen)
        #expect(shell.input.windowFullscreen == fullscreen)
        #expect(buttons.map(\.isEnabled) == [true, !fullscreen, true])
      }
    }
    #expect(nestedCaptionUpdates >= 3)
    #expect(!window.styleMask.contains(.fullScreen))
  }

  #if DEBUG
  @MainActor @Test func aSidebarRowUnderTheIslandRejectsTrackingHoverAndRecoversWhenItHides() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    let sidebar = SidebarView(windowId: "hover-island")
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
    root.addSubview(sidebar)
    defer {
      sidebar.stop()
      window.contentView = nil
      window.close()
    }
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"hover-island":{"id":"hover-island","profileId":"p","tabIds":["a"],"activeTabIds":{"p":"a"}}},"windowOrder":["hover-island"],"tabs":{"a":{"id":"a","windowId":"hover-island","profileId":"p","url":"https://a.example/","title":"Under island"}}}"#).object ?? [:])
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    let row = try #require(sidebar.views["t:a"] as? SidebarRowView)
    let rowRect = row.convert(row.bounds, to: root)
    let center = CGPoint(x: rowRect.minX + 17, y: rowRect.midY)
    let point = root.convert(center, to: nil)
    let screen = window.convertPoint(toScreen: point)
    NotificationCenter.default.post(name: DevPointer.changed, object: NSValue(point: screen))
    defer { NotificationCenter.default.post(name: DevPointer.changed, object: nil) }
    #expect(row.hovered)
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    defer { island.removeFromSuperview() }
    let values = windowedButtons.map { NSValue(rect: $0) }
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: center, windowedButtons: values)
    #expect(FullScreenIslandCoverage.contains(point, in: window))
    #expect(!row.hovered)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    row.mouseEntered(with: entered)
    #expect(!row.hovered)
    #expect(sidebar.hoverKey == nil)
    island.update(fullscreen: true, page: false, reveal: 0, menuBottom: 0,
      closeCenter: center, windowedButtons: values)
    #expect(!FullScreenIslandCoverage.contains(point, in: window))
    #expect(row.hovered)
    row.mouseEntered(with: entered)
    #expect(row.hovered)
    #expect(sidebar.hoverKey == "t:a")
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: center, windowedButtons: values)
    #expect(!row.hovered)
    island.removeFromSuperview()
    #expect(!FullScreenIslandCoverage.contains(point, in: window))
    #expect(row.hovered)
  }
  #endif

  @MainActor @Test func hoveringAnyTrafficLightRollsOverEveryEnabledButtonUntilTheGroupExits() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    defer { island.removeFromSuperview() }
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: CGPoint(x: 25, y: 27), windowedButtons: windowedButtons.map { NSValue(rect: $0) })
    let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
    let group = try #require(glass.contentView as? FullScreenIslandButtonsView)
    #expect(!group.responds(to: NSSelectorFromString("_mouseInGroup:")))
    group.clearRollover()
    let buttons = group.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 3)
    for button in buttons {
      let rect = button.convert(button.bounds, to: nil)
      let point = CGPoint(x: rect.midX, y: rect.midY)
      let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
      let rest = try fullScreenTestButtonPixels(group, buttons: buttons)
      group.mouseEntered(with: entered)
      let hovered = try fullScreenTestButtonPixels(group, buttons: buttons)
      for (before, after) in zip(rest, hovered) {
        #expect(zip(before, after).filter { pair in
          (zip(pair.0, pair.1).map { $0.0 - $0.1 }.max() ?? 0) > 0.08
        }.count >= 6)
      }
      #expect(group.groupHovered)
      #expect(buttons.map { group.mouseInGroup($0) } == [true, false, true])
      #expect(!buttons[1].isEnabled)
      let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: CGPoint(x: 500, y: 400), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
      group.mouseExited(with: exited)
      let left = try fullScreenTestButtonPixels(group, buttons: buttons)
      for (before, after) in zip(rest, left) {
        #expect(zip(before, after).allSatisfy { pair in zip(pair.0, pair.1).allSatisfy { abs($0.0 - $0.1) < 0.02 } })
      }
      #expect(!group.groupHovered)
      #expect(buttons.allSatisfy { !group.mouseInGroup($0) })
    }
  }

  @MainActor @Test func everyTrafficLightDrawsItsHoverGlyphInAnInactiveFullscreenCapsule() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    defer { island.removeFromSuperview() }
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: CGPoint(x: 25, y: 27), windowedButtons: windowedButtons.map { NSValue(rect: $0) })
    let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
    let group = try #require(glass.contentView as? FullScreenIslandButtonsView)
    let buttons = group.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 3)
    func image() throws -> NSBitmapImageRep {
      root.layoutSubtreeIfNeeded()
      group.displayIfNeeded()
      let bitmap = try #require(group.bitmapImageRepForCachingDisplay(in: group.bounds))
      group.cacheDisplay(in: group.bounds, to: bitmap)
      return bitmap
    }
    func core(_ image: NSBitmapImageRep, button: NSButton) throws -> [[CGFloat]] {
      let scale = CGFloat(image.pixelsWide) / group.bounds.width
      var colors: [[CGFloat]] = []
      for y in -4...4 {
        for x in -4...4 {
          let color = try #require(image.colorAt(x: Int((button.frame.midX + CGFloat(x)) * scale),
            y: Int((button.frame.midY + CGFloat(y)) * scale))?.usingColorSpace(.sRGB))
          colors.append([color.redComponent, color.greenComponent, color.blueComponent])
        }
      }
      return colors
    }
    group.clearRollover()
    let rest = try image()
    let point = group.convert(CGPoint(x: 17, y: 16.5), to: nil)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    group.mouseEntered(with: entered)
    #expect(group.groupHovered)
    let hovered = try image()
    for (index, button) in buttons.enumerated() {
      let before = try core(rest, button: button)
      let after = try core(hovered, button: button)
      let darkened = zip(before, after).filter { pair in
        (zip(pair.0, pair.1).map { $0.0 - $0.1 }.max() ?? 0) > 0.08
      }.count
      #expect(darkened >= 6, "Traffic light \(index) has a visible glyph in its rendered centre; darkened pixels: \(darkened)")
    }
    #expect(!buttons[1].isEnabled)
    let minimize = try core(rest, button: buttons[1])[40]
    #expect((minimize.max() ?? 0) - (minimize.min() ?? 0) < 0.12)
    group.clearRollover()
    let left = try image()
    for button in buttons {
      let before = try core(rest, button: button)
      let after = try core(left, button: button)
      #expect(zip(before, after).allSatisfy { pair in zip(pair.0, pair.1).allSatisfy { abs($0.0 - $0.1) < 0.02 } })
    }
  }

  #if DEBUG
  @MainActor @Test func theSidebarProfileMenuBehindTheIslandNeverKeepsItsHoverHighlight() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    let chrome = SidebarChromeView(frame: CGRect(x: 0, y: 0, width: 190, height: 500))
    root.addSubview(chrome)
    chrome.update(SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: nil),
      downloads: false, addressBar: false, dark: true, theme: ["tabHover": "#ff0000", "tabPressed": "#0000ff"], dots: [], savedWidth: 190,
      windowFullscreen: true))
    chrome.layoutSubtreeIfNeeded()
    let profile = chrome.indicator
    #expect(!profile.isHiddenOrHasHiddenAncestor)
    let plate = try #require(profile.layer?.sublayers?.first { $0.cornerRadius == 10 })
    let point = root.convert(CGPoint(x: 25, y: 27), to: nil)
    #expect(profile.bounds.contains(profile.convert(point, from: nil)))
    NotificationCenter.default.post(name: DevPointer.changed, object: NSValue(point: window.convertPoint(toScreen: point)))
    defer { NotificationCenter.default.post(name: DevPointer.changed, object: nil) }
    #expect(profile.hovered)
    let profileFill0 = try #require(plate.backgroundColor)
    #expect(profileFill0.alpha == 1)
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    defer { island.removeFromSuperview() }
    let values = windowedButtons.map { NSValue(rect: $0) }
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
    #expect(FullScreenIslandCoverage.contains(point, in: window))
    #expect(!profile.hovered)
    let profileFill1 = try #require(plate.backgroundColor)
    #expect(profileFill1.alpha == 0)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    chrome.mouseEntered(with: entered)
    let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
    chrome.mouseMoved(with: moved)
    #expect(!profile.hovered)
    let profileFill2 = try #require(plate.backgroundColor)
    #expect(profileFill2.alpha == 0)
    island.update(fullscreen: true, page: false, reveal: 0, menuBottom: 0,
      closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
    #expect(!FullScreenIslandCoverage.contains(point, in: window))
    #expect(profile.hovered)
    let profileFill3 = try #require(plate.backgroundColor)
    #expect(profileFill3.alpha == 1)
    island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
      closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
    #expect(!profile.hovered)
    island.removeFromSuperview()
    #expect(!FullScreenIslandCoverage.contains(point, in: window))
    #expect(profile.hovered)
    let profileFill4 = try #require(plate.backgroundColor)
    #expect(profileFill4.alpha == 1)
  }
  #endif

  @MainActor @Test func closingAWindowWithTheIslandShowingTearsDownWithoutStaleCoverage() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for detachesContent in [true, false] {
      weak var closedWindow: NSWindow?
      weak var closedIsland: FullScreenIslandView?
      weak var closedSidebar: SidebarView?
      try autoreleasepool {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = root
        let sidebar = SidebarView(windowId: "close-island")
        sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
        root.addSubview(sidebar)
        let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"close-island":{"id":"close-island","profileId":"p","tabIds":["a"],"activeTabIds":{"p":"a"},"fullScreen":1}},"windowOrder":["close-island"],"tabs":{"a":{"id":"a","windowId":"close-island","profileId":"p","url":"https://a.example/","title":"Closing"}}}"#).object ?? [:])
        sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
        sidebar.layoutSubtreeIfNeeded()
        let island = FullScreenIslandView(frame: .zero)
        root.addSubview(island)
        island.update(fullscreen: true, page: false, reveal: 1, menuBottom: 0,
          closeCenter: CGPoint(x: 25, y: 27), windowedButtons: windowedButtons.map { NSValue(rect: $0) })
        let point = root.convert(CGPoint(x: 25, y: 27), to: nil)
        #expect(FullScreenIslandCoverage.contains(point, in: window))
        window.close()
        if detachesContent {
          window.contentView = nil
          #expect(!FullScreenIslandCoverage.contains(point, in: window))
          #expect(island.window == nil)
        }
        sidebar.stop()
        closedWindow = window
        closedIsland = island
        closedSidebar = sidebar
      }
      #expect(closedWindow == nil)
      #expect(closedIsland == nil)
      #expect(closedSidebar == nil)
    }
  }

  @MainActor @Test func thePinnedDockPlateKeepsItsClicksOnlyInFullscreen() throws {
    let profile = BrowserState.defaultProfile.id
    var state = BrowserState()
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b", "c"]
    window.activeTabIds[profile] = "c"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    for (index, id) in window.tabIds.enumerated() {
      var tab = Tab(id: id, windowId: "w", profileId: profile, url: "https://\(id).example/", now: Double(index))
      tab.pinned = id != "c"
      state.tabs[id] = tab
    }
    let geometry = StripDragGeometry(["a", "b"].map { StripDragSlot(tabIds: [$0], width: StripMetrics.pinnedCell) }, gap: StripMetrics.pinnedSpacing)
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: StripMetrics.itemHeight))
    let dock = StripDockView(frame: CGRect(x: 0, y: 0, width: StripMetrics.dockWidth(2), height: StripMetrics.itemHeight))
    container.addSubview(dock)
    let favicons = SidebarFavicons()
    let host = StripHostState(profileId: profile)
    let windowed = StripContext(state: state, host: host, windowId: "w", favicons: favicons, previous: nil)
    dock.update(cells: ["a", "b"], members: [:], geometry: geometry, windowed)
    let cell = try #require(dock.cell("a"))
    let onCell = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
    let gaps = stride(from: CGFloat(0.5), to: StripMetrics.dockWidth(2), by: 0.5).map { CGPoint(x: $0, y: 0.25) }
      .filter { point in dock.subviews.allSatisfy { !$0.frame.contains(point) } }
    let gap = try #require(gaps.first)
    #expect(dock.hitTest(gap) == nil)
    #expect(dock.hitTest(onCell).map { $0 === cell || $0.isDescendant(of: cell) } == true)
    state.windows["w"]?.fullScreen = 1
    let fullscreen = StripContext(state: state, host: host, windowId: "w", favicons: favicons, previous: windowed)
    dock.update(cells: ["a", "b"], members: [:], geometry: geometry, fullscreen)
    #expect(dock.hitTest(gap) === dock)
    #expect(dock.hitTest(onCell).map { $0 === cell || $0.isDescendant(of: cell) } == true)
    state.windows["w"]?.fullScreen = nil
    dock.update(cells: ["a", "b"], members: [:], geometry: geometry, StripContext(state: state, host: host, windowId: "w", favicons: favicons, previous: fullscreen))
    #expect(dock.hitTest(gap) == nil)
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
        #expect(glass.frame.midY == shell.fullScreenHeaderRect.midY + shell.fullScreenStripOffset - (shell.fullScreenHeaderRect.midY + 16.5) * 0.5)
        #expect(glass.alphaValue == 1)
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

@MainActor
func fullScreenTestButtonPixels(_ group: NSView, buttons: [NSButton]) throws -> [[[CGFloat]]] {
  group.window?.contentView?.layoutSubtreeIfNeeded()
  group.displayIfNeeded()
  let bitmap = try #require(group.bitmapImageRepForCachingDisplay(in: group.bounds))
  group.cacheDisplay(in: group.bounds, to: bitmap)
  let scale = CGFloat(bitmap.pixelsWide) / group.bounds.width
  return try buttons.map { button in
    var colors: [[CGFloat]] = []
    for y in -4...4 {
      for x in -4...4 {
        let color = try #require(bitmap.colorAt(x: Int((button.frame.midX + CGFloat(x)) * scale),
          y: Int((button.frame.midY + CGFloat(y)) * scale))?.usingColorSpace(.sRGB))
        colors.append([color.redComponent, color.greenComponent, color.blueComponent])
      }
    }
    return colors
  }
}

@MainActor
private final class IslandPointerWindow: NSWindow {
  var pointer = NSPoint.zero
  override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@MainActor
@Suite(.serialized)
struct FullScreenIslandPointerRegressionTests {
  @Test func anotherWindowsIslandDoesNotClearHover() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let other = NSPanel(contentRect: CGRect(x: 800, y: 0, width: 600, height: 500),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    other.isReleasedWhenClosed = false
    defer { window.contentView = nil; other.contentView = nil; window.close(); other.close() }
    let surface = SidebarHoverSurfaceView()
    surface.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
    window.contentView = surface
    var hovered = false
    surface.onPointer = { hovered = $0 }
    let point = window.convertPoint(toScreen: NSPoint(x: 200, y: 200))
    NotificationCenter.default.post(name: DevPointer.fullScreenChanged, object: NSValue(point: point), userInfo: ["window": window])
    #expect(hovered)
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    other.contentView = root
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    #expect(hovered)
    island.removeFromSuperview()
    #expect(hovered)
  }

  #if SOLARA_PROBES
  @Test func realFullscreenNotificationsDoNotFreezeSidebarPointer() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = IslandPointerWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = root
    let sidebar = SidebarView(windowId: "pointer-regression")
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
    root.addSubview(sidebar)
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"pointer-regression":{"id":"pointer-regression","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"a"}}},"windowOrder":["pointer-regression"],"tabs":{"a":{"id":"a","windowId":"pointer-regression","profileId":"p","url":"https://a.example/","title":"A"},"b":{"id":"b","windowId":"pointer-regression","profileId":"p","url":"https://b.example/","title":"B"}}}"#).object ?? [:])
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    func center(_ key: String) throws -> NSPoint {
      let row = try #require(sidebar.views[key] as? SidebarRowView)
      return row.convert(NSPoint(x: 30, y: row.bounds.midY), to: nil)
    }
    window.pointer = try center("t:a")
    NotificationCenter.default.post(name: DevPointer.fullScreenChanged,
      object: NSValue(point: window.convertPoint(toScreen: window.pointer)), userInfo: ["window": window])
    #expect(sidebar.hoverKey == "t:a")
    window.pointer = try center("t:b")
    sidebar.probeScroll(to: 0)
    #expect(sidebar.hoverKey == "t:b")
  }
  #endif
}
