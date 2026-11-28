import SwiftUI

enum ClearDataRange: String, CaseIterable, Hashable, Sendable {
  case hour
  case day
  case week
  case month
  case all

  var title: String {
    switch self {
    case .hour: "Last hour"
    case .day: "Last 24 hours"
    case .week: "Last 7 days"
    case .month: "Last 4 weeks"
    case .all: "All time"
    }
  }

  var duration: TimeInterval? {
    switch self {
    case .hour: 3_600
    case .day: 86_400
    case .week: 7 * 86_400
    case .month: 28 * 86_400
    case .all: nil
    }
  }

  func since(_ now: Date) -> Date? { duration.map { now.addingTimeInterval(-$0) } }
}

struct ClearBrowsingDataSheet: View {
  let model: ProfilesPaneModel
  let profileId: String
  let close: () -> Void
  @State private var range = ClearDataRange.hour
  @State private var history = true
  @State private var siteData = true
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Clear Browsing Data")
        .font(.system(size: 15, weight: .semibold))
      if model.profiles.count > 1 {
        Text("From your \(model.profile(profileId)?.name ?? "") profile")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      }
      HStack(spacing: 10) {
        Text("Time range")
        Picker("", selection: $range) {
          ForEach(ClearDataRange.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 150)
        .fixedSize()
      }
      .padding(.top, 16)
      VStack(alignment: .leading, spacing: 12) {
        option($history, title: "Browsing history", subtitle: "Clears the pages you visited from History and the command bar.")
        option($siteData, title: "Cookies, site data and cached files", subtitle: "Signs you out of most sites.")
      }
      .padding(.top, 16)
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
        Button("Clear Data") {
          busy = true
          Task {
            await model.clearData(profileId: profileId, range: range, history: history, siteData: siteData)
            busy = false
            close()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(busy || (!history && !siteData))
      }
      .padding(.top, 22)
    }
    .padding(20)
    .frame(width: 440, alignment: .leading)
  }

  private func option(_ value: Binding<Bool>, title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(title, isOn: value)
        .toggleStyle(.checkbox)
      Text(subtitle)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
    }
  }
}

@MainActor
protocol CreateProfileSource: AnyObject {
  var profiles: [ProfileSummary] { get }
  func create(name: String, color: ProfileColorValue, shareWith: String?) -> String
}

extension CreateProfileSource {
  func profile(_ id: String) -> ProfileSummary? { profiles.first { $0.id.utf16.elementsEqual(id.utf16) } }

  func dataGroups() -> [(dataId: String, profileIds: [String])] {
    var groups: [(dataId: String, profileIds: [String])] = []
    for profile in profiles {
      if let index = groups.firstIndex(where: { $0.dataId == profile.dataGroup }) {
        groups[index].profileIds.append(profile.id)
      } else {
        groups.append((profile.dataGroup, [profile.id]))
      }
    }
    return groups
  }
}

extension ProfilesPaneModel: CreateProfileSource {}

struct CreateProfileSheet: View {
  let model: any CreateProfileSource
  let close: () -> Void
  @State private var name: String
  @State private var color: ProfileColorValue
  @State private var share: Bool
  @State private var shareWith: String
  @FocusState private var nameFocused: Bool

  init(model: any CreateProfileSource, current: String, presetName: String = "", presetShareWith: String? = nil, close: @escaping () -> Void) {
    self.model = model
    self.close = close
    _name = State(initialValue: presetName)
    _color = State(initialValue: ProfileColorValue.unused(by: model.profiles))
    _share = State(initialValue: presetShareWith != nil)
    _shareWith = State(initialValue: presetShareWith ?? current)
  }

  init(model: ProfilesPaneModel, close: @escaping () -> Void) {
    self.init(model: model, current: model.defaultProfileId, close: close)
  }

  var body: some View {
    let groups = model.dataGroups()
    let single = groups.count == 1
    let selected = groups.first { $0.profileIds.contains(shareWith) } ?? groups.first
    VStack(alignment: .leading, spacing: 0) {
      Text("Create a Profile")
        .font(.system(size: 15, weight: .semibold))
      Text("Profiles separate your logins, cookies, passwords, extensions, history and bookmarks.")
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
      TextField("Profile name", text: $name)
        .textContentType(.solaraPlainText)
        .textFieldStyle(.roundedBorder)
        .focused($nameFocused)
        .onSubmit { submit(selected?.profileIds.first) }
        .padding(.top, 16)
      HStack(spacing: 7) {
        ForEach(ProfileColorValue.allCases, id: \.self) { option in
          Button {
            color = option
          } label: {
            ThemeSwatchRing(selected: color == option, ring: Color(themeHex: option.swatch), size: 22) {
              Circle().fill(Color(themeHex: option.swatch))
            }
          }
          .buttonStyle(.plain)
          .help(option.name)
        }
      }
      .padding(.top, 12)
      GroupBox {
        VStack(alignment: .leading, spacing: 0) {
          Toggle(isOn: $share) {
            Text(single ? "Share data with current profile" : "Share data with another profile")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .toggleStyle(.switch)
          if share {
            Text(single
              ? "Shares browsing data with your current profile. Tabs stay separate."
              : "Shares browsing data with a profile you choose. Tabs stay separate.")
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 6)
          }
          if share && !single {
            Picker("", selection: Binding(get: { selected?.dataId ?? "" }, set: { id in
              if let group = groups.first(where: { $0.dataId == id }), let first = group.profileIds.first { shareWith = first }
            })) {
              ForEach(groups, id: \.dataId) { group in
                HStack(spacing: 10) {
                  ProfileColorStack(colors: group.profileIds.compactMap { model.profile($0)?.color.swatch })
                  Text(ProfileNames.ampersand(group.profileIds.compactMap { model.profile($0)?.name }))
                    .lineLimit(1)
                }
                .tag(group.dataId)
              }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .padding(.top, 10)
          }
        }
        .padding(4)
      }
      .padding(.top, 16)
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
        Button("Create Profile") { submit(selected?.profileIds.first) }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: 420, alignment: .leading)
    .onAppear { DispatchQueue.main.async { nameFocused = true } }
  }

  private func submit(_ groupHead: String?) {
    _ = model.create(name: name, color: color, shareWith: share ? groupHead : nil)
    close()
  }
}
