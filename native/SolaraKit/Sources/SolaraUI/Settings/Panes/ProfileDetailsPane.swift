import SwiftUI

struct ProfileDetailsPane: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: ProfilesPaneModel
  let profileId: String
  @State private var name = ""
  @FocusState private var nameFocused: Bool
  @State private var pickingFromBadge = false
  @State private var pickingFromRow = false

  var body: some View {
    if let profile = model.profile(profileId) {
      content(profile)
    }
  }

  @ViewBuilder
  private func content(_ profile: ProfileSummary) -> some View {
    let isDefault = model.defaultProfileId == profileId
    let only = model.profiles.count <= 1
    let shared = model.sharedWith(profileId)
    let sharing = shared.count > 1
    SettingsForm {
      Section {
        VStack(spacing: 10) {
          Button { pickingFromBadge = true } label: {
            ProfileBadge(profile: profile, size: 64)
          }
          .buttonStyle(.plain)
          .fixedSize()
          .help("Change Icon")
          .popover(isPresented: $pickingFromBadge, arrowEdge: .bottom) {
            ProfileIconPicker(profileId: profileId, current: profile.icon) { pick($0, from: $pickingFromBadge) }
          }
          Text(model.services.stats(profileId: profileId).text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .listRowBackground(Color.clear)
      }

      SettingsSection("Profile") {
        SettingRow(title: "Name", description: RowDescription.none) {
          TextField("", text: $name)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .frame(width: 220)
            .focused($nameFocused)
            .onSubmit(commitName)
        }
        SettingRow(title: "Icon", description: .text(ProfileIcons.title(profile.icon))) {
          Button("Change…") { pickingFromRow = true }
            .popover(isPresented: $pickingFromRow, arrowEdge: .bottom) {
              ProfileIconPicker(profileId: profileId, current: profile.icon) { pick($0, from: $pickingFromRow) }
            }
        }
      }

      ThemeSection(model: model, profile: profile)

      SettingsSection("Data") {
        if sharing {
          LabeledContent {
            EmptyView()
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              ProfileColorStack(colors: shared.compactMap { model.profile($0)?.accent }, size: 14)
              VStack(alignment: .leading) {
                Text("Shared data")
                Text("Shares browsing data with \(ProfileNames.listOf(shared.compactMap { model.profile($0)?.name })). Tabs stay separate.")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        SettingRow(
          title: "Make Default Profile",
          description: .text(isDefault ? "New windows already open with this profile." : "Open new windows with this profile.")
        ) {
          Button("Make Default") { model.setDefault(profileId) }
            .disabled(isDefault)
        }
        SettingRow(
          title: "Clear Browsing Data",
          description: .text(sharing ? "History, cookies, site data and cached files, for every profile that shares them." : "History, cookies, site data and cached files for this profile.")
        ) {
          Button("Clear…") { model.clearingProfileId = profileId }
        }
        SettingRow(
          title: "Delete Selected Profile",
          description: .text(only ? "You can't delete your only profile." : sharing ? "Removes its tabs. The data it shares stays." : "Removes its tabs, history, bookmarks and site data.")
        ) {
          Button("Delete…", role: .destructive) {
            Task { await model.requestDelete(profileId, fromDetails: true) }
          }
          .disabled(only)
        }
      }
    }
    .onAppear { name = profile.name }
    .onChange(of: profile.name) { _, next in if !nameFocused { name = next } }
    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    .sheet(item: Binding(get: { model.clearingProfileId.map(ClearingProfile.init) }, set: { model.clearingProfileId = $0?.id })) { clearing in
      ClearBrowsingDataSheet(model: model, profileId: clearing.id) { model.clearingProfileId = nil }
    }
    .profileDeleteAlert(model: model)
  }

  private func pick(_ event: SidebarIconPickerView.Event, from shown: Binding<Bool>) {
    if case .choose(let icon) = event { model.setIcon(profileId, icon) }
    shown.wrappedValue = false
  }

  private func commitName() {
    if let next = model.updateName(profileId, name) { name = next }
  }
}

struct ClearingProfile: Identifiable {
  let id: String
}
