import AppKit
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

  @Test func updatePillSitsAboveTheFooterRow() {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    let view = SidebarChromeView(frame: host.bounds)
    host.addSubview(view)
    view.update(state(update: SidebarUpdatePillState(text: "New Solara Version Available")))
    #expect(view.footerHeight == 79, "footer \(view.footerHeight)")
    #expect(view.updatePill.frame == NSRect(x: 8, y: 600 - 41 - 8 - 30, width: 204, height: 30))
    #expect(view.updatePill.text == "New Solara Version Available")
    #expect(view.hitTest(NSPoint(x: 100, y: 600 - 41 - 20)) === view.updatePill)
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

  @Test func headerControlsSitWhereRNPutsThem() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    #expect(view.headerHeight == 46)
    #expect(view.footerHeight == 41)
    #expect(view.indicator.frame.minX == 84 && view.indicator.frame.minY == 10.5)
    #expect(view.headerDownloads.frame == NSRect(x: 220 - 7 - 34, y: 10, width: 34, height: 34))
    #expect(view.footerDownloads.isHidden)
    #expect(view.resize.frame == NSRect(x: 216, y: 46, width: 4, height: 554))
  }

  @Test func addressModeMovesDownloadsToFooter() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(addressBar: true, dots: 0))
    #expect(view.headerHeight == 80)
    #expect(view.footerHeight == 41)
    #expect(view.indicator.isHidden && view.headerDownloads.isHidden)
    #expect(view.footerDownloads.frame == NSRect(x: 6, y: 600 - 5 - 34, width: 34, height: 34))
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
    #expect(rects[0] == [92, 564, 12, 28])
    view.setPagerPosition(0.5)
    let opacities = (view.describe()["dots"] as! [[String: Any]]).map { $0["opacity"] as! Double }
    #expect(abs(opacities[0] - 0.525) < 1e-6 && abs(opacities[1] - 0.525) < 1e-6 && abs(opacities[2] - 0.2) < 1e-6)
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
