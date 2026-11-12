import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PrivacySiteModel {
  @ObservationIgnored let services: PrivacyServices
  @ObservationIgnored let onChanged: () async -> Void
  let profile: String
  let origin: String
  var settings: [SiteSettingType: SiteSettingState]?
  var status = ""

  static let labels: [(SiteSettingType, String)] = [
    (.popups, "Pop-ups and redirects"),
    (.camera, "Camera"),
    (.microphone, "Microphone"),
    (.location, "Location"),
    (.notifications, "Notifications"),
    (.sound, "Sound"),
    (.autoplay, "Autoplay"),
    (.javascript, "JavaScript"),
    (.images, "Images"),
    (.clipboard, "Clipboard"),
    (.automaticDownloads, "Automatic downloads"),
    (.cookies, "Cookies"),
    (.midi, "MIDI devices"),
    (.windowManagement, "Window management"),
    (.localFonts, "Fonts"),
    (.storageAccess, "Embedded content"),
    (.fileSystem, "File editing"),
  ]

  static let valueOptions = [
    SettingOption(SiteSettingValue.default.rawValue, "Default"),
    SettingOption(SiteSettingValue.allow.rawValue, "Allow"),
    SettingOption(SiteSettingValue.block.rawValue, "Block"),
    SettingOption(SiteSettingValue.ask.rawValue, "Ask"),
  ]

  init(services: PrivacyServices, profile: String, origin: String, onChanged: @escaping () async -> Void) {
    self.services = services
    self.profile = profile
    self.origin = origin
    self.onChanged = onChanged
  }

  var rows: [(type: SiteSettingType, label: String, state: SiteSettingState)] {
    guard let settings else { return [] }
    return Self.labels.compactMap { type, label in settings[type].map { (type, label, $0) } }
  }

  static func shownValue(_ state: SiteSettingState) -> SiteSettingValue { state.isDefault ? .default : state.value }

  static func defaultNote(_ state: SiteSettingState) -> String? { state.isDefault ? "Default (\(state.value.rawValue))" : nil }

  static func clearedText(_ result: ClearSiteDataResult) -> String {
    guard let cookies = result.cookies else { return "Site data cleared." }
    return "Cleared \(cookies) cookie\(cookies == 1 ? "" : "s") and site data."
  }

  func load() async {
    if let next = await services.siteSettings(profile: profile, origin: origin) { settings = next }
  }

  func set(_ type: SiteSettingType, _ value: SiteSettingValue) async {
    await services.setSiteSetting(profile: profile, origin: origin, type: type, value: value)
    await load()
    await onChanged()
  }

  func reset() async {
    await services.resetSiteSettings(profile: profile, origin: origin)
    await load()
    await onChanged()
  }

  func clearData() async {
    status = Self.clearedText(await services.clearSiteData(profile: profile, origin: origin))
  }
}

enum PrivacyImages {
  static func dataURI(_ uri: String?) -> NSImage? {
    guard let uri, uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
    let header = uri[..<comma]
    let payload = String(uri[uri.index(after: comma)...])
    let data = header.hasSuffix(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.flatMap { $0.data(using: .utf8) }
    return data.flatMap(NSImage.init(data:))
  }

}

struct PrivacyIconRow<Icon: View, Control: View>: View {
  let title: String
  var description: String? = nil
  @ViewBuilder let icon: Icon
  @ViewBuilder let control: Control

  var body: some View {
    LabeledContent {
      control
    } label: {
      HStack(spacing: 12) {
        icon
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let description {
            Text(description)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

struct PrivacyPlaceholderRow: View {
  var body: some View {
    LabeledContent {
      EmptyView()
    } label: {
      Text(" ")
      Text(" ")
    }
  }
}

struct PrivacySheetFooter: View {
  let note: String
  let done: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Text(note)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Done", action: done)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }
}

struct PrivacySheetHeader: View {
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline)
      if let subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.top, 20)
  }
}

struct FilterListsSheet: View {
  @Environment(\.settingsContext) private var context
  @Environment(\.dismiss) private var dismiss
  let model: PrivacyPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    let lists = model.blocker?.lists ?? []
    VStack(spacing: 0) {
      PrivacySheetHeader(title: "Advanced Ad Block Settings", subtitle: "Block common components found across the web by using additional rules and filters.")
      Form {
        ForEach(BlockerCategory.all) { category in
          let inCategory = lists.filter { $0.category == category.id }
          if !inCategory.isEmpty {
            Section(category.section) {
              ForEach(inCategory) { list in
                Toggle(isOn: Binding(get: { list.enabled }, set: { on in Task { await model.setList(list, on: on) } })) {
                  Text(list.title)
                  Text(PrivacyPaneModel.listDescription(list))
                }
                .toggleStyle(.checkbox)
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(height: 420)
      PrivacySheetFooter(
        note: (model.blocker?.version).flatMap { $0.isEmpty ? nil : "Blocking by uBlock Origin \($0), included with \(app). Chromium lists update automatically. WebKit lists update with \(app)." } ?? ""
      ) { dismiss() }
    }
    .frame(width: 500)
  }
}

struct SiteSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: PrivacySiteModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        SettingsFavicon(url: model.origin, profile: model.profile, size: 20)
        Text(PrivacyPaneModel.withoutScheme(model.origin))
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      Form {
        Section {
          ForEach(model.rows, id: \.type) { row in
            SettingRow(title: row.label, description: PrivacySiteModel.defaultNote(row.state)) {
              Picker("", selection: Binding(
                get: { PrivacySiteModel.shownValue(row.state).rawValue },
                set: { raw in
                  guard let value = SiteSettingValue(rawValue: raw) else { return }
                  Task { await model.set(row.type, value) }
                }
              )) {
                ForEach(PrivacySiteModel.valueOptions, id: \.value) { Text($0.title).tag($0.value) }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(minWidth: 100)
              .fixedSize()
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(height: 380)
      HStack(spacing: 8) {
        Button("Reset Permissions") { Task { await model.reset() } }
          .fixedSize()
        Button("Clear Site Data") { Task { await model.clearData() } }
          .fixedSize()
        Text(model.status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Done") { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
    .frame(width: 460)
    .task { await model.load() }
  }
}
