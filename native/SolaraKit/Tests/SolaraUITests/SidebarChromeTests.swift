import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
struct SidebarChromeTests {
  func state(addressBar: Bool = false, downloads: Bool = true, dots: Int = 3, profiles: Int = 3, update: SidebarUpdatePillState? = nil) -> SidebarChromeState {
    SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: profiles, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: downloads, addressBar: addressBar, dark: false, theme: [:],
      dots: (0..<dots).map { SidebarChromeDot(id: "p\($0)", name: "P\($0)", slot: $0 < 2 ? Double($0) : nil) }, savedWidth: 220, update: update)
  }

  @Test func unusedProfileIconPickerIsNotAllocatedDuringChromeLifecycle() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    #expect((view.iconPopover as ProfileIconPopover?) == nil)
    view.update(state())
    #expect((view.iconPopover as ProfileIconPopover?) == nil)
    view.viewDidMoveToWindow()
    #expect((view.iconPopover as ProfileIconPopover?) == nil)
  }

  @Test func profileIconPickerIsCreatedOnlyForAnExistingProfileAndReused() throws {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    view.showIconPicker("missing")
    #expect((view.iconPopover as ProfileIconPopover?) == nil)
    view.showIconPicker("p0")
    let picker = try #require(view.iconPopover as ProfileIconPopover?)
    view.showIconPicker("p1")
    #expect(view.iconPopover === picker)
    view.viewDidMoveToWindow()
    #expect(view.iconPopover === picker)
  }

  @Test func updatePillSitsAboveTheFooterRow() {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    let view = SidebarChromeView(frame: host.bounds)
    host.addSubview(view)
    view.update(state(update: SidebarUpdatePillState(text: "New Solara Version Available")))
    #expect(view.footerHeight == 78, "footer \(view.footerHeight)")
    #expect(view.updatePill.frame == NSRect(x: 8, y: 600 - 40 - 8 - 30, width: 204, height: 30))
    #expect(view.updatePill.text == "New Solara Version Available")
    #expect(view.hitTest(NSPoint(x: 100, y: 600 - 40 - 20)) === view.updatePill)
  }

  @Test func updatePillAloneKeepsItsOwnBand() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(downloads: false, dots: 0, update: SidebarUpdatePillState(text: "New Solara Version Available")))
    #expect(view.footerHeight == 38)
    #expect(view.updatePill.frame.maxY == 592)
    view.update(state(downloads: false, dots: 0))
    #expect(view.footerHeight == 0)
    #expect(view.updatePill.isHidden)
  }

  @Test func updatePillPressInstalls() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    var actions: [SidebarChromeAction] = []
    view.onAction = { actions.append($0) }
    view.update(state(update: SidebarUpdatePillState(text: "New Solara Version Available")))
    #expect(view.updatePill.accessibilityPerformPress())
    #expect(actions == [.installUpdate])
  }

  @Test func chromeDecodesWithAndWithoutUpdate() {
    let base = ##"{"controls":{"title":"W","incognito":false,"profiles":1,"nameColor":"#000","downloadsOpen":false,"downloadsTooltip":"D"},"downloads":false,"addressBar":false,"dark":true,"theme":{},"dots":[],"savedWidth":190,"dropOver":false"##
    #expect(SidebarChromeState.decode(base + "}")?.update == nil)
    #expect(SidebarChromeState.decode(base + #","update":null}"#)?.update == nil)
    #expect(SidebarChromeState.decode(base + #","update":{"text":"New","tooltip":"t"}}"#)?.update == SidebarUpdatePillState(text: "New", tooltip: "t"))
  }

  @Test func rubberBandMatchesRN() {
    #expect(SidebarResizeMath.rubberBand(300) == 300)
    #expect(abs(SidebarResizeMath.rubberBand(490) - (400 + 36 * (1 - exp(-1)))) < 1e-9)
    #expect(abs(SidebarResizeMath.unstretch(SidebarResizeMath.rubberBand(450)) - 450) < 1e-6)
    #expect(SidebarResizeMath.clamp(120) == 160)
    #expect(abs(SidebarResizeMath.backOut(0)) < 1e-9 && SidebarResizeMath.backOut(1) == 1)
    #expect(SidebarResizeMath.backOut(0.6) > 1)
    #expect(SidebarResizeMath.live(200.26) == 200.5)
  }

  @Test func headerProfileSitsEightPointsAfterGreenAtTheLightsCenter() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    #expect(view.headerHeight == 46)
    #expect(view.footerHeight == 40)
    let greenTrailing = ShellMetrics.lightsCenter.x + 2 * ShellMetrics.trafficLightPitch + ShellMetrics.trafficLightSize / 2
    #expect(view.indicator.frame.minX + view.indicator.leadingPadding == greenTrailing + 8)
    #expect(view.indicator.frame.midY == ShellMetrics.lightsCenter.y)
    #expect(view.headerDownloads.frame == NSRect(x: 220 - 7 - 34, y: 10, width: 34, height: 34))
    #expect(view.footerDownloads.isHidden)
    #expect(view.resize.frame == NSRect(x: 216, y: 46, width: 4, height: 554))
  }

  @Test func profileLabelTracksTheCaptionLineBeforeTheNextLayoutPass() throws {
    let host = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 190, height: 80))
    let indicator = StripProfileIndicator(frame: .zero)
    host.addSubview(indicator)
    let label = try #require(indicator.subviews.compactMap { $0 as? StripLabel }.first)
    for width in [CGFloat(60), 90, 150] {
      indicator.frame = CGRect(x: 6, y: SidebarChromeMetrics.controlTop, width: width, height: StripControlsLayout.height)
      let name = label.convert(label.bounds, to: host)
      #expect(abs(name.midY - ShellMetrics.lightsCenter.y) <= 0.5)
      #expect(label.frame.width == width - 2 * StripControlsLayout.pad)
    }
  }

  @Test(arguments: ["Test", "Personal", "A long profile name", ""], [CGFloat(160), 190, 220])
  func windowedProfilePillClearsActualLightsWithoutMovingItsContents(_ title: String, _ width: CGFloat) throws {
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    WindowCaptionLayout.configure(window)
    let host = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
    window.contentView = host
    let view = SidebarChromeView(frame: CGRect(x: 0, y: 0, width: width, height: 650))
    host.addSubview(view)
    defer { window.contentView = nil; window.close() }
    var next = state()
    next.controls.title = title
    next.theme = ["tabHover": "#ff0000", "tabPressed": "#0000ff"]
    view.update(next)
    view.layoutSubtreeIfNeeded()
    WindowCaptionLayout.position(in: window, center: CGPoint(x: 25, y: 27))
    let label = try #require(view.indicator.subviews.compactMap { $0 as? StripLabel }.first)
    let symbol = try #require(view.indicator.subviews.compactMap { $0 as? SymbolView }.first)
    let before = StripControlsLayout.indicator(textWidth: StripControlsLayout.nameWidth(title), room: width - 77 - 7 - 36,
      incognito: false, profiles: 3)
    let nameFrame = CGRect(x: 86, y: 10, width: before.width - 18, height: 34)
    let symbolFrame = CGRect(x: 77 + (before.width - 16) / 2, y: 19, width: 16, height: 16)
    #expect(label.isHidden == !before.showName)
    #expect(!view.indicator.isHidden)
    #expect(label.convert(label.bounds, to: host) == nameFrame)
    #expect(symbol.convert(symbol.bounds, to: host) == symbolFrame)
    let plate = try #require(view.indicator.layer?.sublayers?.first { $0.cornerRadius == 10 })
    for pressed in [false, true] {
      view.indicator.hovered = true
      view.indicator.pressed = pressed
      let pill = view.indicator.convert(plate.frame, to: host)
      #expect(pill.minX == 82)
      #expect(plate.backgroundColor == SidebarPalette.parse(next.theme[pressed ? "tabPressed" : "tabHover"])?.cgColor)
      #expect(pill.maxX == 77 + before.width)
      for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(kind))
        let light = button.convert(button.bounds, to: host)
        #expect(!pill.intersects(light))
        #expect(pill.minX - light.maxX >= 4)
      }
      #expect(label.convert(label.bounds, to: host) == nameFrame)
      #expect(symbol.convert(symbol.bounds, to: host) == symbolFrame)
    }
  }

  @Test(arguments: ["Test", ""])
  func profilePillPaddingResetsAcrossFullscreenAndSideChanges(_ title: String) throws {
    let view = SidebarChromeView(frame: CGRect(x: 0, y: 0, width: 220, height: 650))
    var next = state()
    next.controls.title = title
    view.update(next)
    view.layoutSubtreeIfNeeded()
    let label = try #require(view.indicator.subviews.compactMap { $0 as? StripLabel }.first)
    let original = label.convert(label.bounds, to: view)
    let originalPill = view.indicator.frame
    for right in [false, true, false] {
      for fullscreen in [false, true, false] {
        next.sidebarPosition = right ? "right" : "left"
        next.windowFullscreen = fullscreen
        view.update(next)
        view.layoutSubtreeIfNeeded()
        let leadingAtEdge = right || fullscreen
        let room: CGFloat = leadingAtEdge ? 171 : 100
        let before = StripControlsLayout.indicator(textWidth: StripControlsLayout.nameWidth(title), room: room,
          incognito: false, profiles: 3)
        let expected = CGRect(x: leadingAtEdge ? 15 : 86, y: 10, width: before.width - 18, height: 34)
        #expect(label.convert(label.bounds, to: view) == expected)
        #expect(view.indicator.frame.minX == (leadingAtEdge ? 6 : 82))
        if !leadingAtEdge {
          #expect(label.convert(label.bounds, to: view) == original)
          #expect(view.indicator.frame == originalPill)
        }
      }
    }
  }

  @Test(arguments: ["Test", "Personal", ""])
  func fullscreenIslandOwnsRevealedLightHitsAndClearsTheProfilePaint(_ title: String) throws {
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let root = FlippedContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
    window.contentView = root
    let shell = WindowShellView(windowId: "profile-island")
    defer { shell.stopLayoutMotion() }
    shell.frame = root.bounds
    root.addSubview(shell)
    shell.update { $0.sidebarWidth = 220 }
    shell.mount(.backdrop, FullScreenBackdropFixture(colors: [.systemPink, .white]))
    let chrome = SidebarChromeView(frame: .zero)
    shell.mount(.sidebar, chrome)
    var next = state(downloads: false)
    next.controls.title = title
    next.theme = ["tabHover": "#ff0000", "tabPressed": "#0000ff"]
    chrome.update(next)
    root.layoutSubtreeIfNeeded()
    let label = try #require(chrome.indicator.subviews.compactMap { $0 as? StripLabel }.first)
    let original = label.fullScreenRect(label.bounds, to: root)
    #expect(original.minX == 86)
    let plate = try #require(chrome.indicator.layer?.sublayers?.first { $0.cornerRadius == 10 })
    let island = FullScreenIslandView(frame: .zero)
    root.addSubview(island)
    defer { island.removeFromSuperview() }
    let values = [CGFloat(18), 41, 64].map { NSValue(rect: CGRect(x: $0, y: 20, width: 14, height: 14)) }
    let frame = try #require(root.superview)
    for menuBottom: CGFloat in [0, 24] {
      next.windowFullscreen = true
      chrome.update(next)
      for reveal: CGFloat in [0, 1] {
        island.update(fullscreen: true, page: false, reveal: reveal, menuBottom: menuBottom,
          closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
        root.layoutSubtreeIfNeeded()
        #expect(label.fullScreenRect(label.bounds, to: root) == original.offsetBy(dx: -71, dy: menuBottom * reveal))
        #expect(island.isHidden == (reveal == 0))
        if reveal == 0 {
          let point = chrome.indicator.fullScreenRect(chrome.indicator.bounds, to: nil)
          let screen = window.convertPoint(toScreen: CGPoint(x: point.midX, y: point.midY))
          NotificationCenter.default.post(name: DevPointer.fullScreenChanged, object: NSValue(point: screen), userInfo: ["window": window])
          #expect(chrome.indicator.hovered)
          continue
        }
        let glass = try #require(island.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        let buttons = try #require(glass.contentView).subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3)
        for button in buttons {
          let light = button.convert(button.bounds, to: nil)
          let point = CGPoint(x: light.midX, y: light.midY)
          let hit = try #require(frame.hitTest(point))
          #expect(hit === button || hit.isDescendant(of: button))
          chrome.indicator.hovered = true
          NotificationCenter.default.post(name: DevPointer.fullScreenChanged,
            object: NSValue(point: window.convertPoint(toScreen: point)), userInfo: ["window": window])
          #expect(!chrome.indicator.hovered)
        }
        let zoom = try #require(buttons.last)
        let light = zoom.convert(zoom.bounds, to: nil)
        let point = CGPoint(x: light.midX, y: light.midY)
        if !chrome.indicator.bounds.contains(chrome.indicator.fullScreenPoint(point)) {
          chrome.indicator.pressed = true
          let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
          chrome.indicator.mouseDragged(with: drag)
          #expect(!chrome.indicator.pressed)
        }
        let fill = try #require(plate.backgroundColor)
        #expect(fill.alpha == 0)
        if menuBottom > 0 {
          let pill = chrome.indicator.fullScreenRect(chrome.indicator.bounds, to: root)
          let cover = try #require(island.subviews.compactMap { $0 as? FullScreenIslandScrim }.first {
            !$0.isHidden && $0.fullScreenRect($0.bounds, to: root).contains(pill)
          })
          #expect(root.subviews.last === island)
          #expect(cover.alphaValue == 1)
        }
      }
      next.windowFullscreen = false
      chrome.update(next)
      island.update(fullscreen: false, page: false, reveal: 0, menuBottom: menuBottom,
        closeCenter: CGPoint(x: 25, y: 27), windowedButtons: values)
      root.layoutSubtreeIfNeeded()
      #expect(label.fullScreenRect(label.bounds, to: root) == original)
    }
  }

  @Test func fullscreenProfileUsesTheSidebarLeadingInsetAndRestoresOnExit() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 160, height: 600))
    var next = state()
    view.update(next)
    #expect(!view.indicator.isHidden)
    next.windowFullscreen = true
    view.update(next)
    #expect(view.indicator.frame.minX == SidebarMetrics.inset)
    #expect(view.indicator.frame.minX + StripControlsLayout.pad == 15)
    #expect(view.indicator.frame.midY == ShellMetrics.lightsCenter.y)
    #expect(!view.indicator.isHidden)
    #expect(view.indicator.frame.maxX <= view.headerDownloads.frame.minX - StripControlsLayout.gap)
    next.windowFullscreen = false
    view.update(next)
    #expect(view.indicator.frame.minX == 82)
    #expect(view.indicator.frame.midY == 27)
  }

  @Test func legacyFullscreenProfileFollowsItsWindowWithoutAFeedUpdate() {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 600),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    window.contentView = host
    let view = SidebarChromeView(frame: host.bounds)
    host.addSubview(view)
    view.update(state())
    #expect(view.state?.windowFullscreen == nil)
    #expect(view.indicator.frame.minX == 82)
    view.setWindowFullscreen(true, in: window)
    #expect(view.indicator.frame.minX == SidebarMetrics.inset)
    view.setWindowFullscreen(false, in: window)
    #expect(view.indicator.frame.minX == 82)
    view.removeFromSuperview()
    view.setWindowFullscreen(true, in: window)
    #expect(view.indicator.frame.minX == 82)
    window.contentView = nil
  }

  @Test func addressModeMovesDownloadsToFooter() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(addressBar: true, dots: 0))
    #expect(view.headerHeight == 80)
    #expect(view.footerHeight == 40)
    #expect(view.indicator.isHidden && view.headerDownloads.isHidden)
    #expect(view.footerDownloads.frame == NSRect(x: 6, y: 600 - 3 - 34, width: 34, height: 34))
  }

  @Test func noFooterWithoutDotsOrFooterDownloads() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(downloads: false, dots: 0))
    #expect(view.footerHeight == 0)
    #expect(view.headerDownloads.isHidden)
  }

  @Test func dotsCenterAndFollowThePager() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    let info = view.describe()["dots"] as! [[String: Any]]
    let rects = info.map { $0["rect"] as! [Double] }
    #expect(rects[0] == [70, 568, 24, 24])
    view.setPagerPosition(0.5)
    let opacities = (view.describe()["dots"] as! [[String: Any]]).map { $0["opacity"] as! Double }
    #expect(abs(opacities[0] - 0.825) < 1e-6 && abs(opacities[1] - 0.825) < 1e-6 && abs(opacities[2] - 0.65) < 1e-6)
  }

  func restoredState(_ profileId: String) -> SidebarChromeState {
    var next = state(dots: 4, profiles: 4)
    next.dots = (0..<4).map { SidebarChromeDot(id: "p\($0)", name: "P\($0)", slot: Double($0)) }
    next.currentProfileId = profileId
    return next
  }

  func dotOpacities(_ view: SidebarChromeView) -> [Double] {
    (view.describe()["dots"] as! [[String: Any]]).map { $0["opacity"] as! Double }
  }

  @Test(arguments: ["p1", "p3"])
  func restoredProfileIsSelectedBeforeAnyPagerEvent(profileId: String) {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(restoredState(profileId))
    let expected = profileId == "p1" ? [0.65, 1, 0.65, 0.65] : [0.65, 0.65, 0.65, 1]
    for (actual, wanted) in zip(dotOpacities(view), expected) { #expect(abs(actual - wanted) < 1e-6) }
  }

  @Test func restoredSelectionCanArriveAfterEmptyChrome() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(dots: 0, profiles: 0))
    view.update(restoredState("p1"))
    for (actual, wanted) in zip(dotOpacities(view), [0.65, 1, 0.65, 0.65]) { #expect(abs(actual - wanted) < 1e-6) }
  }

  @Test func earlySwipePositionSurvivesInitialStateAndThemeUpdate() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.setPagerPosition(1.5)
    var next = restoredState("p1")
    view.update(next)
    for (actual, wanted) in zip(dotOpacities(view), [0.65, 0.825, 0.825, 0.65]) { #expect(abs(actual - wanted) < 1e-6) }
    next.dark = true
    next.currentProfileId = "p2"
    view.update(next)
    for (actual, wanted) in zip(dotOpacities(view), [0.65, 0.825, 0.825, 0.65]) { #expect(abs(actual - wanted) < 1e-6) }
  }

  @Test func passesThroughBelowTheHeader() {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    let view = SidebarChromeView(frame: host.bounds)
    host.addSubview(view)
    view.update(state(downloads: false))
    #expect(view.hitTest(NSPoint(x: 20, y: 20)) === view)
    #expect(view.hitTest(NSPoint(x: 20, y: 300)) == nil)
    #expect(view.hitTest(NSPoint(x: 20, y: 590)) === view)
    #expect(view.hitTest(NSPoint(x: 218, y: 300)) === view.resize)
  }
}

extension SidebarChromeTests {
  @Test func sidebarChromeScopesDownloadsToItsProfileAndPrivateSession() throws {
    let fixture = #"{"profiles":{"default":{"id":"default","name":"Personal"},"work":{"id":"work","name":"Work","directory":"Work"}},"windows":{"normal":{"id":"normal","profileId":"default"},"private":{"id":"private","profileId":"incognito:private@default","incognito":true},"work":{"id":"work","profileId":"incognito:work@work","incognito":true}},"downloads":[{"id":"private-download","offTheRecord":true,"profile":"","state":"complete"}]}"#
    let state = try BrowserState(stateJSON: try #require(JSONValue.parse(fixture).object))
    #expect(!state.hasSidebarDownloads("normal"))
    #expect(state.hasSidebarDownloads("private"))
    #expect(!state.hasSidebarDownloads("work"))
  }
}
