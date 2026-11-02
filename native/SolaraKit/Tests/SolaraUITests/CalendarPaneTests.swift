import AppKit
import Foundation
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeCalendarServices: CalendarServices {
  var state = CalendarPaneState(
    access: .fullAccess,
    calendars: [
      SystemCalendarInfo(id: "work", title: "Work", color: "#1BADF8", account: "owner@hill.com", owned: true),
      SystemCalendarInfo(id: "home", title: "Home", color: "#63DA38", account: "iCloud", owned: true),
      SystemCalendarInfo(id: "holidays", title: "US Holidays", color: "#CC73E1", account: "Subscribed Calendars", owned: false),
    ],
    options: LiveCalendarOptions(hiddenCalendarIds: ["holidays"])
  )
  var calls: [String] = []
  var alertPermission = true
  let changes = AsyncStream<CalendarPaneState>.makeStream()

  func calendarState() async -> CalendarPaneState { state }
  func calendarChanges() -> AsyncStream<CalendarPaneState> { changes.stream }
  func refreshCalendar() async { calls.append("refresh") }
  func connectCalendar() async { calls.append("connect") }
  func requestCalendarAlertPermission() async -> Bool { calls.append("alertPermission"); return alertPermission }
  func updateCalendarOptions(_ change: LiveCalendarOptionChange) { calls.append("\(change)") }
  func setCalendarHidden(_ id: String, hidden: Bool) { calls.append("hide \(id) \(hidden)") }
  func openCalendarPrivacySettings() { calls.append("privacy") }
}

@MainActor
enum LiveSettingsWait {
  static func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

@MainActor
struct CalendarPaneTests {
  static func loaded(_ services: FakeCalendarServices = FakeCalendarServices()) async -> (SettingsContext, FakeSettingsStore, CalendarPaneModel, FakeCalendarServices) {
    let (context, store) = SettingsFixture.context()
    let model = CalendarPaneModel(services: services)
    context.panes[.calendar] = model
    await model.prepare(SettingsPlace(pane: .calendar))
    return (context, store, model, services)
  }

  @Test func accessDescriptionFollowsAuthorization() async {
    let (_, _, model, _) = await Self.loaded()
    #expect(model.accessDescription(appName: "Solara") == "Connected · 3 calendars")
    let first = model.calendars[0]
    model.state?.calendars = [first]
    #expect(model.accessDescription(appName: "Solara") == "Connected · 1 calendar")
    model.state?.access = .fixture
    #expect(model.connected)
    #expect(model.accessDescription(appName: "Solara") == "Development build: using calendar-fixture.json")
    model.state?.access = .restricted
    #expect(model.denied && !model.connected)
    #expect(model.accessDescription(appName: "Solara") == "Allow Solara in System Settings › Privacy & Security › Calendars.")
    model.state?.access = .writeOnly
    #expect(!model.denied && !model.connected)
    #expect(model.accessDescription(appName: "Solara") == "Not connected")
  }

  @Test func calendarsSplitByOwnership() async {
    let (_, _, model, _) = await Self.loaded()
    #expect(model.owned.map(\.id) == ["work", "home"])
    #expect(model.others.map(\.id) == ["holidays"])
    #expect(!model.isVisible(model.others[0]))
  }

  @Test func togglesAndPickersReachTheLiveStore() async {
    let (_, _, model, services) = await Self.loaded()
    model.setVisible(model.calendars[0], false)
    #expect(model.options.hiddenCalendarIds == ["holidays", "work"])
    model.setVisible(model.calendars[2], true)
    #expect(model.options.hiddenCalendarIds == ["work"])
    model.update(.alertLead("never"))
    model.update(.showPreview(false))
    #expect(model.options.alertLead == "never")
    #expect(!model.options.showPreview)
    model.connect()
    await model.refresh()
    await LiveSettingsWait.until { services.calls.contains("connect") }
    #expect(services.calls.contains("hide work true"))
    #expect(services.calls.contains("hide holidays false"))
    #expect(services.calls.contains("\(LiveCalendarOptionChange.alertLead("never"))"))
    #expect(services.calls.contains("\(LiveCalendarOptionChange.showPreview(false))"))
    #expect(services.calls.contains("connect"))
    #expect(services.calls.contains("refresh"))
  }

  @Test func onlyTurningOnAlertsRequestsNotificationPermission() async {
    let (_, _, model, services) = await Self.loaded()
    model.update(.alertLead("5"))
    model.update(.alertCondition("always"))
    await model.refresh()
    model.setAlertsEnabled(false)
    #expect(!services.calls.contains("alertPermission"))
    model.setAlertsEnabled(true)
    await LiveSettingsWait.until { model.options.alertLead == "5" }
    #expect(services.calls.filter { $0 == "alertPermission" }.count == 1)
    model.setAlertsEnabled(false)
    services.alertPermission = false
    model.setAlertsEnabled(true)
    await LiveSettingsWait.until { model.alertPermissionUnavailable }
    #expect(model.options.alertLead == "never")
  }

  @Test func alertLeadsMatchTheEngine() {
    #expect(CalendarAlertLeads.options.map(\.value) == ["never", "start", "1", "2", "3", "5", "10"])
    #expect(CalendarAlertLeads.options.filter(\.separatorBefore).map(\.value) == ["start"])
  }

  @Test func engineChangesReplaceTheState() async {
    let (_, _, model, services) = await Self.loaded()
    var next = services.state
    next.access = .denied
    next.calendars = []
    services.changes.continuation.yield(next)
    await LiveSettingsWait.until { model.denied }
    #expect(model.denied)
    #expect(model.calendars.isEmpty)
  }

  @Test func swatchColorsParseHex() {
    let orange = CalendarSwatch.components("#FF8000").map { [$0.0, $0.1, $0.2] }
    let short = CalendarSwatch.components("#abc").map { [$0.0, $0.1, $0.2] }
    let expectedOrange: [Double] = [1, 128.0 / 255, 0]
    let expectedShort: [Double] = [0xAA / 255.0, 0xBB / 255.0, 0xCC / 255.0]
    #expect(orange == expectedOrange)
    #expect(short == expectedShort)
    #expect(CalendarSwatch.components("nope") == nil)
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersCalendar() async throws {
    let (context, store, model, _) = await Self.loaded()
    store.values["autoGroupMeetingTabs"] = .bool(true)
    try await Snapshot.renderPanes(context, [.calendar])
    model.state = CalendarPaneState(access: .denied, calendars: [], options: LiveCalendarOptions(alertLead: "never"))
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .calendar)], named: { _ in "calendar-denied" })
    model.state = CalendarPaneState(access: .notDetermined, calendars: [], options: LiveCalendarOptions())
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .calendar)], named: { _ in "calendar-notConnected" })
    model.state = CalendarPaneState(access: .fullAccess, calendars: [], options: LiveCalendarOptions())
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .calendar)], named: { _ in "calendar-empty" })
  }
}
