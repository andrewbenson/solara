import AppKit
import Testing
import SolaraModel
@testable import SolaraUI

@MainActor
struct UnreadBadgeViewTests {
  @Test func countsCapAtNinetyNine() {
    #expect(UnreadBadgeLayout.text(.count(1)) == "1")
    #expect(UnreadBadgeLayout.text(.count(99)) == "99")
    #expect(UnreadBadgeLayout.text(.count(100)) == "99+")
    #expect(UnreadBadgeLayout.text(.count(Int.max)) == "99+")
    #expect(UnreadBadgeLayout.text(.dot) == nil)
  }

  @Test func aBooleanUnreadIsADot() {
    #expect(UnreadBadgeLayout.size(.dot) == CGSize(width: 6, height: 6))
    #expect(UnreadBadgeLayout.size(.count(1)).height == 14)
    #expect(UnreadBadgeLayout.size(.count(99)).width >= UnreadBadgeLayout.size(.count(1)).width)
    #expect(UnreadBadgeLayout.size(.count(100)).width >= UnreadBadgeLayout.size(.count(99)).width)
  }

  @Test func aBadgeNeverInterceptsTabClicks() {
    let view = UnreadBadgeView()
    view.set(.count(3))
    view.frame = CGRect(origin: .zero, size: UnreadBadgeLayout.size(.count(3)))
    view.layoutSubtreeIfNeeded()
    #expect(!view.isHidden)
    #expect(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil)
    view.set(nil)
    #expect(view.isHidden)
  }

  @Test func theNativeViewLaysItsPlateAndTextInsideTheBadge() {
    let view = UnreadBadgeView()
    view.set(.count(100))
    view.frame = CGRect(origin: .zero, size: UnreadBadgeLayout.size(.count(100)))
    view.layoutSubtreeIfNeeded()
    let label = view.label
    let plate = view.plate
    #expect(label.stringValue == "99+")
    #expect(label.frame.midX == view.bounds.midX)
    #expect(label.frame.midY == view.bounds.midY)
    #expect(plate.frame == view.bounds)
    #expect(plate.cornerRadius == 7)
    view.set(.dot)
    view.frame.size = UnreadBadgeLayout.size(.dot)
    view.layoutSubtreeIfNeeded()
    #expect(label.isHidden)
    #expect(plate.frame == view.bounds)
    #expect(plate.cornerRadius == 3)
  }

  @Test func tileBadgesStayInsideTheirTile() {
    for width in [CGFloat(36), 41, 60] {
      for status in [TabUnreadStatus.dot, .count(1), .count(99), .count(100)] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: 41)
        let frame = UnreadBadgeLayout.cornerFrame(status, in: bounds)
        #expect(bounds.contains(frame))
        #expect(frame.maxX == bounds.maxX - 3)
        #expect(frame.minY == bounds.minY + 3)
      }
    }
  }

  @Test func aMountedTilePlacesUnreadAtTheTopTrailingCorner() throws {
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"b"}}},"windowOrder":["w"],"tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"about:blank","title":"(3) Inbox","pinned":true},"b":{"id":"b","windowId":"w","profileId":"p","url":"about:blank","title":"Control"}}}"#).object ?? [:])
    let context = SidebarContext(state: state, host: SidebarHostState(profileId: "p"), windowId: "w", favicons: SidebarFavicons())
    let tile = TileView(frame: CGRect(x: 0, y: 0, width: 126, height: 41))
    tile.update(SidebarItem(kind: .tile("a"), frame: tile.frame, region: .fixed, groups: [], section: .tiles), context)
    tile.layoutSubtreeIfNeeded()
    let badge = try #require(tile.body.subviews.compactMap { $0 as? UnreadBadgeView }.first)
    #expect(badge.status == .count(3))
    let frame = badge.convert(badge.bounds, to: tile)
    #expect(frame.minY == 3)
    #expect(frame.maxX == tile.bounds.maxX - 3)
  }

  @Test func aRowReservesTheSameSpaceAcrossHover() {
    for status in [TabUnreadStatus.dot, .count(1), .count(100)] {
      let resting = UnreadBadgeLayout.rowSlot(status, affordance: 0)
      let hovering = UnreadBadgeLayout.rowSlot(status, affordance: 22)
      let loading = UnreadBadgeLayout.rowSlot(status, affordance: 14)
      #expect(resting == hovering)
      #expect(resting == loading)
      let frame = UnreadBadgeLayout.trailingFrame(status, in: CGRect(x: 0, y: 0, width: 178, height: 34))
      #expect(frame.minX >= 178 - 6 - resting)
      #expect(frame.maxX == CGFloat(178 - 6))
      #expect(frame.midY == 17)
    }
  }

  @Test func settingIsEnabledForExistingProfiles() {
    #expect(SolaraModel.Settings.hydrated(from: nil).bool("showUnreadBadges"))
    #expect(SettingsIndex(appName: "Solara").entry("tabs.showUnreadBadges")?.pane == .tabs)
  }
}
