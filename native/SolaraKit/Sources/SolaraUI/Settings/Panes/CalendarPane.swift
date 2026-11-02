import AppKit
import Observation
import SwiftUI

public enum CalendarAccess: String, Sendable {
  case fullAccess
  case writeOnly
  case denied
  case restricted
  case notDetermined
  case fixture
}

public struct SystemCalendarInfo: Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var color: String
  public var account: String
  public var owned: Bool

  public init(id: String, title: String, color: String, account: String, owned: Bool) {
    self.id = id
    self.title = title
    self.color = color
    self.account = account
    self.owned = owned
  }
}

public struct LiveCalendarOptions: Sendable, Equatable {
  public var alertLead: String
  public var alertCondition: String
  public var showPreview: Bool
  public var showTimeToNext: Bool
  public var hiddenCalendarIds: [String]

  public init(alertLead: String = "1", alertCondition: String = "always", showPreview: Bool = true, showTimeToNext: Bool = true, hiddenCalendarIds: [String] = []) {
    self.alertLead = alertLead
    self.alertCondition = alertCondition
    self.showPreview = showPreview
    self.showTimeToNext = showTimeToNext
    self.hiddenCalendarIds = hiddenCalendarIds
  }
}

public enum LiveCalendarOptionChange: Sendable, Equatable {
  case alertLead(String)
  case alertCondition(String)
  case showPreview(Bool)
  case showTimeToNext(Bool)
}

public struct CalendarPaneState: Sendable, Equatable {
  public var access: CalendarAccess
  public var calendars: [SystemCalendarInfo]
  public var options: LiveCalendarOptions

  public init(access: CalendarAccess, calendars: [SystemCalendarInfo], options: LiveCalendarOptions) {
    self.access = access
    self.calendars = calendars
    self.options = options
  }
}

@MainActor
public protocol CalendarServices: AnyObject {
  func calendarState() async -> CalendarPaneState
  func calendarChanges() -> AsyncStream<CalendarPaneState>
  func refreshCalendar() async
  func connectCalendar() async
  func requestCalendarAlertPermission() async -> Bool
  func updateCalendarOptions(_ change: LiveCalendarOptionChange)
  func setCalendarHidden(_ id: String, hidden: Bool)
  func openCalendarPrivacySettings()
}

enum CalendarAlertLeads {
  static let options: [SettingOption] = [
    SettingOption("never", "Never"),
    SettingOption("start", "At Meeting Start", separatorBefore: true),
    SettingOption("1", "One Minute Before"),
    SettingOption("2", "Two Minutes Before"),
    SettingOption("3", "Three Minutes Before"),
    SettingOption("5", "Five Minutes Before"),
    SettingOption("10", "Ten Minutes Before"),
  ]

  static let conditions: [SettingOption] = [
    SettingOption("always", "Always"),
    SettingOption("activeOnly", "Only When Active"),
  ]
}

@MainActor
@Observable
public final class CalendarPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: CalendarServices
  @ObservationIgnored private var listening: Task<Void, Never>?
  var state: CalendarPaneState?
  var alertPermissionUnavailable = false
  private var alertChange = 0
  private var lastAlertLead = "1"

  public init(services: CalendarServices) {
    self.services = services
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { state != nil }

  public func prepare(_ place: SettingsPlace) async {
    listen()
    if state == nil { state = await services.calendarState() }
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(CalendarPane(model: self))
  }

  private func listen() {
    guard listening == nil else { return }
    let changes = services.calendarChanges()
    listening = Task { [weak self] in
      for await next in changes {
        guard let self else { return }
        self.state = next
      }
    }
  }

  var access: CalendarAccess { state?.access ?? .notDetermined }
  var calendars: [SystemCalendarInfo] { state?.calendars ?? [] }
  var options: LiveCalendarOptions { state?.options ?? LiveCalendarOptions() }
  var connected: Bool { access == .fullAccess || access == .fixture }
  var denied: Bool { access == .denied || access == .restricted }
  var owned: [SystemCalendarInfo] { calendars.filter(\.owned) }
  var others: [SystemCalendarInfo] { calendars.filter { !$0.owned } }

  func accessDescription(appName: String) -> String {
    if access == .fixture { return "Development build: using calendar-fixture.json" }
    if connected { return "Connected · \(calendars.count == 1 ? "1 calendar" : "\(calendars.count) calendars")" }
    if denied { return "Allow \(appName) in System Settings › Privacy & Security › Calendars." }
    return "Not connected"
  }

  func isVisible(_ calendar: SystemCalendarInfo) -> Bool { !options.hiddenCalendarIds.contains(calendar.id) }

  func setVisible(_ calendar: SystemCalendarInfo, _ visible: Bool) {
    var ids = options.hiddenCalendarIds.filter { $0 != calendar.id }
    if !visible { ids.append(calendar.id) }
    state?.options.hiddenCalendarIds = ids
    services.setCalendarHidden(calendar.id, hidden: !visible)
  }

  func update(_ change: LiveCalendarOptionChange) {
    switch change {
    case .alertLead(let value):
      if options.alertLead != "never" { lastAlertLead = options.alertLead }
      state?.options.alertLead = value
    case .alertCondition(let value): state?.options.alertCondition = value
    case .showPreview(let value): state?.options.showPreview = value
    case .showTimeToNext(let value): state?.options.showTimeToNext = value
    }
    services.updateCalendarOptions(change)
  }

  func setAlertsEnabled(_ enabled: Bool) {
    alertChange += 1
    let change = alertChange
    alertPermissionUnavailable = false
    if !enabled {
      if options.alertLead != "never" { lastAlertLead = options.alertLead }
      update(.alertLead("never"))
      return
    }
    guard options.alertLead == "never" else { return }
    Task {
      let granted = await services.requestCalendarAlertPermission()
      guard change == alertChange else { return }
      alertPermissionUnavailable = !granted
      if granted { update(.alertLead(lastAlertLead)) }
    }
  }

  func connect() {
    Task { await services.connectCalendar() }
  }

  func refresh() async {
    await services.refreshCalendar()
  }
}

struct CalendarPane: View {
  @Environment(\.settingsContext) private var context
  let model: CalendarPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    let options = model.options
    SettingsForm {
      SettingsSection(
        "Live Calendar",
        description: "Pin a calendar for previews, meeting countdowns and Join alerts. Events come from the Calendar app's accounts."
      ) {
        SettingRow("calendar.access", description: model.accessDescription(appName: app)) {
          if model.denied {
            Button("Open System Settings") { model.services.openCalendarPrivacySettings() }
          } else if !model.connected {
            Button("Connect Calendar…") { model.connect() }
              .buttonStyle(.borderedProminent)
          }
        }
      }

      SettingsSection("Meeting alerts") {
        Toggle("Enable meeting alerts", isOn: Binding(get: { options.alertLead != "never" }, set: { model.setAlertsEnabled($0) }))
          .toggleStyle(.settingsSwitch)
        if model.alertPermissionUnavailable {
          Text("Allow notifications for this app in System Settings to receive meeting alerts.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        SettingRow("calendar.nextAlert") {
          SettingPicker(CalendarAlertLeads.options, selection: Binding(get: { options.alertLead }, set: { model.update(.alertLead($0)) }))
            .disabled(options.alertLead == "never")
        }
        SettingRow("calendar.alertCondition") {
          SettingPicker(CalendarAlertLeads.conditions, selection: Binding(get: { options.alertCondition }, set: { model.update(.alertCondition($0)) }))
            .disabled(options.alertLead == "never")
        }
      }

      SettingsSection("Pinned calendar") {
        SettingRow("calendar.preview") {
          Toggle("", isOn: Binding(get: { options.showPreview }, set: { model.update(.showPreview($0)) }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
        }
        SettingRow("calendar.timeToNext") {
          Toggle("", isOn: Binding(get: { options.showTimeToNext }, set: { model.update(.showTimeToNext($0)) }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
        }
      }

      SettingsSection("Meetings") {
        SettingToggle("calendar.autoGroup", key: "autoGroupMeetingTabs")
      }

      if !model.calendars.isEmpty {
        SettingsSection("Active calendars", description: "Meetings from unchecked calendars don't show or alert.") {
          if !model.owned.isEmpty {
            CalendarListRows(model: model, title: "My Calendars", calendars: model.owned)
          }
          if !model.others.isEmpty {
            CalendarListRows(model: model, title: "Other Calendars", calendars: model.others)
          }
        }
      } else if model.connected {
        Section {
          Text("No calendars found. Add accounts in the Calendar app.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refresh() }
    }
  }
}

struct CalendarListRows: View {
  let model: CalendarPaneModel
  let title: String
  let calendars: [SystemCalendarInfo]

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
    ForEach(calendars) { calendar in
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 3)
            .fill(CalendarSwatch.color(calendar.color))
            .frame(width: 10, height: 10)
          Toggle(calendar.title, isOn: Binding(get: { model.isVisible(calendar) }, set: { model.setVisible(calendar, $0) }))
            .toggleStyle(.checkbox)
          Spacer(minLength: 0)
        }
        if !calendar.account.isEmpty {
          Text(calendar.account)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
        }
      }
    }
  }
}

enum CalendarSwatch {
  static let fallback = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)

  static func components(_ hex: String) -> (Double, Double, Double)? {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6 || digits.count == 8, let value = UInt64(digits.prefix(6), radix: 16) else { return nil }
    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
  }

  static func color(_ hex: String) -> Color {
    guard let (red, green, blue) = components(hex) else { return fallback }
    return Color(red: red, green: green, blue: blue)
  }
}
