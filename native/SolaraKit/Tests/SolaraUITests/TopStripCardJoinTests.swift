import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct TopStripCardJoinTests {
  enum Placement: CaseIterable, Sendable {
    case legacy, legacyReactOnTop, native, nativeReactOnTop

    var nativePanes: Bool { self == .native || self == .nativeReactOnTop }
    var reactOnTop: Bool { self == .legacyReactOnTop || self == .nativeReactOnTop }
  }

  private func state(normalPage: Bool) throws -> BrowserState {
    let url = normalPage ? "https://example.com/" : ""
    return try BrowserState(stateJSON: JSONValue.parse("""
      {"settings":{"tabLayout":"top","bookmarksBar":"never"},"profileOrder":["personal","test"],"windowOrder":["join"],
       "windows":{"join":{"id":"join","profileId":"personal","tabIds":["personal-tab","test-tab"],
         "activeTabIds":{"personal":"personal-tab","test":"test-tab"}}},
       "tabs":{"personal-tab":{"id":"personal-tab","windowId":"join","profileId":"personal","url":"\(url)","title":"Personal"},
               "test-tab":{"id":"test-tab","windowId":"join","profileId":"test","url":"\(url)","title":"Test"}}}
      """).object ?? [:])
  }

  private func selectedChip(in view: NSView) -> StripTabChip? {
    if let chip = view as? StripTabChip, chip.accessibleSelected == true { return chip }
    return view.subviews.compactMap { selectedChip(in: $0) }.first
  }

  private func expectColor(_ actual: NSColor, _ expected: NSColor) {
    #expect(abs(actual.redComponent - expected.redComponent) < 0.005)
    #expect(abs(actual.greenComponent - expected.greenComponent) < 0.005)
    #expect(abs(actual.blueComponent - expected.blueComponent) < 0.005)
    #expect(abs(actual.alphaComponent - expected.alphaComponent) < 0.005)
  }

  @Test(arguments: [false, true], Placement.allCases)
  func switchingProfilesBothWaysKeepsTheSelectedNewTabOrPageJoinedToTheCard(normalPage: Bool, placement: Placement) throws {
    let shell = WindowShellView(windowId: "join", reactOnTop: placement.reactOnTop)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 220), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    shell.appearance = NSAppearance(named: .aqua)
    shell.update { $0.topTabs = true }
    let stripSlot = FlippedContainerView()
    let strip = TopStripView(windowId: "join")
    strip.takesDrops = false
    shell.mount(.topStrip, stripSlot)
    stripSlot.addSubview(strip)
    strip.frame = CGRect(x: 180, y: 0, width: 700, height: 42)
    let backdrop = ToolbarBackdropView(frame: CGRect(x: 0, y: 0, width: shell.frames.card.width, height: 41))
    shell.cardClip.addSubview(backdrop)
    let panes = SplitPanesView(windowId: "join")
    if placement.nativePanes {
      panes.pagesPooled = true
      panes.onCardStyle = { [weak shell] in shell?.cardStyle = $0 }
      shell.card.addSubview(panes)
    }
    defer {
      strip.stop()
      panes.stop()
      shell.stopLayoutMotion()
      window.contentView = nil
      window.close()
    }
    var state = try state(normalPage: normalPage)
    let card = normalPage ? "#FFFFFF" : "#FFFFFFB3"
    let looks = ["personal", "test"].map { id in
      SidebarPageLook(profileId: id, dark: false,
        theme: ["card": card, "windowTint": id == "personal" ? "#D9AEB8" : "#9EBBD0"],
        border: [], glow: SidebarGlow(color: "#FFFFFF26", opacity: 1, radius: 15), tidy: false, incognito: false)
    }
    for profile in ["personal", "test", "personal", "test", "personal"] {
      state.windows["join"]?.profileId = profile
      let look = try #require(looks.first { $0.profileId == profile })
      var host = StripHostState(profileId: profile, dark: false)
      host.theme = look.theme
      host.pages = looks
      host.pageWidth = 670
      shell.layer?.backgroundColor = CSSColor(look.theme["windowTint"]!)!.cg
      shell.cardEdgeTint = CSSColor(look.theme["windowTint"]!)!.ns
      shell.cardStyle = CardStyle(fill: CSSColor(card)!.ns, radius: 10)
      backdrop.update(ToolbarBackdropState(tabId: "\(profile)-tab", background: nil, divider: "#0000000D", hairline: normalPage, stripes: nil))
      strip.update(state: state, host: host)
      for fullscreen in [false, true, false] {
        shell.applyFullScreenReveal(fullscreen: fullscreen, page: false, reveal: 0, menuBottom: 26)
        if placement.nativePanes {
          panes.cardColor = CSSColor(card)!.ns
          let input = try #require(WindowLayoutInput(state: state, windowId: "join", bounds: shell.bounds, windowFullscreen: fullscreen))
          let snapshot = WindowLayoutSnapshot.of(input, generation: 1)
          #expect(snapshot.frames.card == shell.frames.card)
          panes.install(snapshot, state: state)
          let pane = try #require(panes.container("\(profile)-tab")?.superview)
          if backdrop.superview !== pane { pane.addSubview(backdrop) }
        }
        shell.layoutSubtreeIfNeeded()
        shell.displayIfNeeded()
        CATransaction.flush()
        let current = try #require(strip.current)
        let chip = try #require(selectedChip(in: current))
        #expect(chip.accessibleName == (profile == "personal" ? "Personal" : "Test"))
        let center = chip.convert(CGPoint(x: chip.bounds.midX, y: 41), to: shell)
        #expect(abs(center.y + 1 - shell.frames.card.minY) < 0.005)
        let layer = try #require(shell.layer)
        let edges = [shell.cardRim] + panes.subviews.compactMap { $0 as? CardEdgeView }.filter { $0.part == .rim }
        let rims = try edges.map { try #require($0.layer) }
        for scale: CGFloat in [1, 2] {
          let actual = try DeveloperStripesTests.rendered(layer, shell.bounds, scale: scale)
          let hidden = rims.map(\.isHidden)
          for rim in rims { rim.isHidden = true }
          let reference = try DeveloperStripesTests.rendered(layer, shell.bounds, scale: scale)
          for (rim, hidden) in zip(rims, hidden) { rim.isHidden = hidden }
          let masks = rims.map(\.mask)
          for rim in rims { rim.mask = nil }
          let crossed = try DeveloperStripesTests.rendered(layer, shell.bounds, scale: scale)
          for (rim, mask) in zip(rims, masks) { rim.mask = mask }
          let seamX = Int(center.x * scale)
          let seamY = actual.pixelsHigh - 1 - Int(shell.frames.card.minY * scale)
          let clear = try #require(actual.colorAt(x: seamX, y: seamY)?.usingColorSpace(.sRGB))
          let stroke = try #require(crossed.colorAt(x: seamX, y: seamY)?.usingColorSpace(.sRGB))
          if !fullscreen { #expect(abs(clear.redComponent - stroke.redComponent) > 0.005) }
          for dx: CGFloat in [-30, 0, 30] {
            for dy: CGFloat in [0.25, 0.75, 1.25] {
              let x = Int((center.x + dx) * scale)
              let y = actual.pixelsHigh - 1 - Int((shell.frames.card.minY + dy) * scale)
              let pixel = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
              let expected = try #require(reference.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
              expectColor(pixel, expected)
              #expect(pixel.alphaComponent > 0.99)
            }
          }
        }
      }
    }
  }

  @Test func onlyTheStraightTopRimDisappearsAndSidebarModeRestoresIt() throws {
    let shell = WindowShellView(windowId: "rim-modes")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.appearance = NSAppearance(named: .aqua)
    shell.cardEdgeTint = CSSColor("#D9AEB8")!.ns
    defer { shell.stopLayoutMotion() }
    for topTabs in [true, false, true, false] {
      shell.update { $0.topTabs = topTabs }
      let rim = try #require(shell.cardRim.layer)
      let bitmap = try DeveloperStripesTests.rendered(rim, shell.cardRim.bounds, scale: 2)
      let center = bitmap.pixelsWide / 2
      let top = bitmap.pixelsHigh - 1
      let topAlpha = bitmap.colorAt(x: center, y: top)?.alphaComponent ?? 0
      if topTabs { #expect(topAlpha < 0.005) } else { #expect(topAlpha > 0.02) }
      #expect((bitmap.colorAt(x: 0, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.02)
      #expect((bitmap.colorAt(x: center, y: 0)?.alphaComponent ?? 0) > 0.02)
      let corner = (1..<20).contains { x in
        (1..<20).contains { y in (bitmap.colorAt(x: x, y: top - y)?.alphaComponent ?? 0) > 0.02 }
      }
      #expect(corner)
    }
  }

  @Test(arguments: ["horizontal", "vertical"])
  func actualSplitPanesKeepTheirCompleteBordersUnderTopTabs(orientation: String) throws {
    var state = try state(normalPage: true)
    state.tabs["test-tab"]?.profileId = "personal"
    state.splits["pair"] = SplitView(id: "pair", windowId: "join", tabIds: ["personal-tab", "test-tab"],
      orientation: orientation, sizes: [0.5, 0.5])
    let shell = WindowShellView(windowId: "join")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    shell.appearance = NSAppearance(named: .aqua)
    shell.update { $0.topTabs = true }
    shell.cardEdgeTint = CSSColor("#D9AEB8")!.ns
    let panes = SplitPanesView(windowId: "join")
    shell.card.addSubview(panes)
    defer { panes.stop(); shell.stopLayoutMotion() }
    let input = try #require(WindowLayoutInput(state: state, windowId: "join", bounds: shell.bounds))
    panes.install(.of(input, generation: 1), state: state)
    let rims = panes.subviews.compactMap { $0 as? CardEdgeView }.filter { $0.part == .rim }
    #expect(rims.count == 2)
    for rim in rims {
      let bitmap = try DeveloperStripesTests.rendered(try #require(rim.layer), rim.bounds, scale: 2)
      let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 1))
      #expect(pixel.alphaComponent > 0.02)
    }
  }
}
