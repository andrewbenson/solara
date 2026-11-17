import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct LiveCardFrameTests {
  private func calendar(_ body: String, dark: Bool) throws -> LiveCardModel.State {
    let model = LiveCardModel()
    model.apply(json: """
      {"card":"calendarPreview","dark":\(dark),"nowColor":"#D1242F","date":"Mon, Nov 16","connected":true,"loading":false,"body":"\(body)","allDay":[],"events":[]}
      """)
    return try #require(model.state)
  }

  @Test func calendarOwnsFillBorderPaddingAndEmptyStatesInBothAppearances() throws {
    for dark in [false, true] {
      for body in ["loading", "error", "none", "noMore", "denied", "signIn", "events"] {
        let card = SidebarCalendarCardView()
        let state = try calendar(body, dark: dark)
        card.set(tabId: "calendar", state: state, look: SidebarSurfaceLook(
          dark: dark, panel: dark ? "#2A2A2A" : "#FFFFFF", panelBorder: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)",
          shadowOpacity: dark ? 0.5 : 0.18))
        card.layoutSubtreeIfNeeded()
        let surface = try #require(card.layer?.sublayers?.compactMap { $0 as? SurfaceLayer }.first)
        let host = try #require(card.subviews.first)
        #expect(card.state == state)
        #expect(card.tabId == "calendar")
        #expect(card.frame.width == 300)
        #expect(card.height >= 25)
        #expect(host.frame == card.bounds.insetBy(dx: 12.5, dy: 12.5))
        #expect(surface.frame == card.bounds)
        #expect(surface.radius == 12)
        #expect(surface.border == 0.5)
        #expect(surface.glowRadius == 16)
        #expect(surface.glowOffset == CGSize(width: 0, height: 6))
        #expect(abs(surface.glowOpacity - (dark ? 0.4 : 0.144)) < 0.0001)
        #expect(!card.acceptsFirstResponder)
      }
    }
  }

  @Test func calendarReplacementKeepsItsNativeBodyAndTracksTheNewTab() throws {
    let card = SidebarCalendarCardView()
    let look = SidebarSurfaceLook(dark: false, panel: "#FFFFFF", panelBorder: "#0000001A", shadowOpacity: 0.18)
    card.set(tabId: "first", state: try calendar("loading", dark: false), look: look)
    let body = try #require(card.subviews.first)
    card.set(tabId: "second", state: try calendar("none", dark: true), look: look)
    #expect(card.tabId == "second")
    #expect(card.state?.body == "none")
    #expect(card.subviews.first === body)
  }

  @Test func meetingReportsHeightFromAnInitiallyOnePointHost() throws {
    let view = MeetingAlertFrameView(frame: CGRect(x: 0, y: 0, width: 300, height: 1))
    var heights: [CGFloat] = []
    view.onHeight = { heights.append($0) }
    view.apply(json: """
      {"card":"meetingAlert","dark":false,"nowColor":"#D1242F","alert":{"id":"first","title":"Standup","color":"#3478F6","joinTitle":"Join Zoom"}}
      """)
    view.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    let motion = try #require(view.subviews.first)
    let body = try #require(motion.subviews.first)
    #expect(view.height > 1)
    #expect(heights.last == view.height)
    #expect(body.frame.width == 300)
    #expect(body.frame.height >= view.height)
    #expect(!view.acceptsFirstResponder)
  }

  @Test func meetingRoundsHeightReportsOnceAndPreservesActions() {
    let view = MeetingAlertFrameView(frame: CGRect(x: 0, y: 0, width: 300, height: 1))
    var heights: [CGFloat] = []
    var events: [LiveCardEvent] = []
    view.onHeight = { heights.append($0) }
    view.onEvent = { events.append($0) }
    view.model.onEvent(.height(123.2))
    #expect(view.height == 124)
    #expect(heights == [124])
    view.model.onEvent(.height(123.3))
    #expect(heights == [124])
    view.model.onEvent(.join("first", all: true))
    view.model.onEvent(.dismiss)
    #expect(events == [.join("first", all: true), .dismiss])
  }

  @Test func meetingReplacementKeepsItsHostAndInvalidStateKeepsTheVisibleCard() throws {
    let view = MeetingAlertFrameView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let motion = try #require(view.subviews.first)
    let host = try #require(motion.subviews.first)
    for (id, dark) in [("first", false), ("second", true)] {
      view.apply(json: """
        {"card":"meetingAlert","dark":\(dark),"nowColor":"#E5534B","alert":{"id":"\(id)","title":"Standup","color":"#3478F6"}}
        """)
      #expect(view.model.state?.alert?.id == id)
      #expect(view.model.state?.dark == dark)
      #expect(motion.subviews.first === host)
    }
    let state = try #require(view.model.state)
    view.apply(json: "invalid")
    #expect(view.model.state == state)
    #expect(motion.subviews.first === host)
  }
}
