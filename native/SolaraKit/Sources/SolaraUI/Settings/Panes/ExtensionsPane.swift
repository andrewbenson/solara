import AppKit
import Observation
import SwiftUI

@MainActor
public protocol ExtensionsServices: AnyObject {
  var focusedWindowProfileId: String? { get }
  var ownershipGeneration: Int? { get }
  func listExtensions(profile: String) async throws -> [InstalledExtension]
  func setExtensionEnabled(_ id: String, enabled: Bool, profile: String) async throws
  func uninstallExtension(_ id: String, profile: String) async throws
  func reloadExtension(_ id: String, profile: String) async throws
  func configureExtension(_ id: String, profile: String, options: ExtensionConfiguration) async throws
  func chooseExtensionFolder() async -> String?
  func inspectUnpackedExtension(path: String) async throws -> ExtensionPackage
  func installExtension(path: String, profile: String) async throws
  func extensionChanges() -> AsyncStream<ExtensionsChange>
  func openWebStoreDetail(_ url: String, profile: String)
  func openInNewTab(_ url: String)
}

struct ExtensionRemoval: Identifiable, Equatable {
  let profile: String
  let ext: InstalledExtension

  var id: String { ext.id }
  var title: String { "Remove “\(ext.name)”?" }
  var message: String { ext.fromWebStore ? "Its data and settings will be removed too." : "The extension's folder stays on your Mac." }
}

@MainActor
@Observable
public final class ExtensionsPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: ExtensionsServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored private var loading: [String: Task<[InstalledExtension], Never>] = [:]
  @ObservationIgnored private var trailing: [String: Task<[InstalledExtension], Never>] = [:]
  @ObservationIgnored private var watching: Task<Void, Never>?
  private var generation: Int?
  private var cachedLists: [String: [InstalledExtension]] = [:]
  private var pendingInstall: ExtensionInstallRequest?
  private var pendingRemoval: ExtensionRemoval?

  var lists: [String: [InstalledExtension]] {
    generation == services.ownershipGeneration ? cachedLists : [:]
  }

  var install: ExtensionInstallRequest? {
    get { generation == services.ownershipGeneration ? pendingInstall : nil }
    set { if synchronizeOwnership() != nil { pendingInstall = newValue } }
  }

  var removal: ExtensionRemoval? {
    get { generation == services.ownershipGeneration ? pendingRemoval : nil }
    set { if synchronizeOwnership() != nil { pendingRemoval = newValue } }
  }

  public init(services: ExtensionsServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  isolated deinit {
    watching?.cancel()
  }

  private func synchronizeOwnership() -> Int? {
    let current = services.ownershipGeneration
    if generation != current {
      generation = current
      cachedLists.removeAll()
      loading.removeAll()
      trailing.removeAll()
      pendingInstall = nil
      pendingRemoval = nil
    }
    return current
  }

  func profileId(for place: SettingsPlace) -> String {
    let known = Set(store.profiles.map(\.id))
    if let chosen = place.profileId, known.contains(chosen) { return chosen }
    if let focused = services.focusedWindowProfileId, known.contains(focused) { return focused }
    return store.string("defaultProfileId")
  }

  func engineProfile(for place: SettingsPlace) -> String { store.engineProfile(profileId(for: place)) }

  public func isLoaded(_ place: SettingsPlace) -> Bool { lists[engineProfile(for: place)] != nil }

  public func prepare(_ place: SettingsPlace) async {
    watchChanges()
    let profile = engineProfile(for: place)
    if lists[profile] == nil { await refresh(profile) }
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(ExtensionsPane(model: self, place: place))
  }

  private func watchChanges() {
    guard watching == nil else { return }
    let changes = services.extensionChanges()
    watching = Task { [weak self] in
      for await change in changes {
        guard let self else { return }
        guard self.synchronizeOwnership() != nil,
          self.cachedLists[change.profile] != nil || self.loading[change.profile] != nil else { continue }
        await self.refreshAfterChange(change.profile)
      }
    }
  }

  @discardableResult
  func refresh(_ profile: String) async -> [InstalledExtension] {
    guard let generation = synchronizeOwnership() else { return [] }
    if let running = loading[profile] { return await running.value }
    let result = Task { [weak self, services] () -> [InstalledExtension] in
      guard services.ownershipGeneration == generation else { return [] }
      let fetched = try? await services.listExtensions(profile: profile)
      guard let self, self.services.ownershipGeneration == generation else { return [] }
      self.loading[profile] = nil
      if let fetched {
        let sorted = Self.sorted(fetched)
        self.cachedLists[profile] = sorted
        return sorted
      }
      let kept = self.cachedLists[profile] ?? []
      self.cachedLists[profile] = kept
      return kept
    }
    loading[profile] = result
    return await result.value
  }

  func refreshAfterChange(_ profile: String) async {
    guard let generation = synchronizeOwnership() else { return }
    guard let running = loading[profile] else {
      await refresh(profile)
      return
    }
    if let next = trailing[profile] {
      _ = await next.value
      return
    }
    let next = Task { [weak self] () -> [InstalledExtension] in
      _ = await running.value
      guard let self, self.services.ownershipGeneration == generation else { return [] }
      self.trailing[profile] = nil
      return await self.refresh(profile)
    }
    trailing[profile] = next
    _ = await next.value
  }

  static func sorted(_ list: [InstalledExtension]) -> [InstalledExtension] {
    list.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedAscending }
  }

  private func patch(_ profile: String, _ id: String, _ change: (inout InstalledExtension) -> Void) {
    guard var list = lists[profile], let index = list.firstIndex(where: { $0.id == id }) else { return }
    change(&list[index])
    cachedLists[profile] = list
  }

  func setEnabled(_ profile: String, _ id: String, _ enabled: Bool) async {
    guard let generation = synchronizeOwnership() else { return }
    patch(profile, id) {
      $0.enabled = enabled
      $0.state = enabled ? "ENABLED" : "DISABLED"
    }
    try? await services.setExtensionEnabled(id, enabled: enabled, profile: profile)
    if services.ownershipGeneration == generation { await refreshAfterChange(profile) }
  }

  func setPinned(_ profile: String, _ id: String, _ pinned: Bool) async {
    guard let generation = synchronizeOwnership() else { return }
    patch(profile, id) { $0.pinned = pinned }
    do {
      try await services.configureExtension(id, profile: profile, options: ExtensionConfiguration(pinned: pinned))
    } catch {
      if services.ownershipGeneration == generation { await refreshAfterChange(profile) }
    }
  }

  func configure(_ profile: String, _ id: String, _ options: ExtensionConfiguration) async {
    guard let generation = synchronizeOwnership() else { return }
    try? await services.configureExtension(id, profile: profile, options: options)
    if services.ownershipGeneration == generation { await refreshAfterChange(profile) }
  }

  func reload(_ profile: String, _ id: String) async {
    guard let generation = synchronizeOwnership() else { return }
    try? await services.reloadExtension(id, profile: profile)
    if services.ownershipGeneration == generation { await refreshAfterChange(profile) }
  }

  func requestRemoval(_ ext: InstalledExtension, profile: String) {
    removal = ExtensionRemoval(profile: profile, ext: ext)
  }

  func confirmRemoval() async {
    guard let generation = synchronizeOwnership(), let removal else { return }
    pendingRemoval = nil
    try? await services.uninstallExtension(removal.ext.id, profile: removal.profile)
    if services.ownershipGeneration == generation { await refreshAfterChange(removal.profile) }
  }

  func openWebStore() {
    services.openInNewTab(ExtensionWebStore.categoryURL)
  }

  func addFromLink(_ text: String, profile: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let id = ExtensionWebStore.extensionId(trimmed) else {
      install = ExtensionInstallRequest(
        profile: profile,
        source: .webStore,
        status: .error(ExtensionWebStore.invalidLinkMessage),
        package: ExtensionPackage(name: "Extension", version: "", path: "")
      )
      return
    }
    services.openWebStoreDetail(ExtensionWebStore.detailURL(id), profile: profile)
  }

  func loadUnpacked(profile: String) async {
    guard let generation = synchronizeOwnership(), let path = await services.chooseExtensionFolder(),
      services.ownershipGeneration == generation else { return }
    do {
      let package = try await services.inspectUnpackedExtension(path: path)
      guard services.ownershipGeneration == generation else { return }
      install = ExtensionInstallRequest(profile: profile, source: .unpacked, status: .ready, package: package)
    } catch {
      guard services.ownershipGeneration == generation else { return }
      install = ExtensionInstallRequest(profile: profile, source: .unpacked, status: .error(ExtensionServiceError.message(error)), package: nil)
    }
  }

  func confirmInstall() async {
    guard let generation = synchronizeOwnership(), var request = install, let package = request.package,
      request.status == .ready else { return }
    request.status = .installing
    install = request
    do {
      try await services.installExtension(path: package.path, profile: request.profile)
      guard services.ownershipGeneration == generation else { return }
      if install?.id == request.id { install = nil }
      await refreshAfterChange(request.profile)
    } catch {
      guard services.ownershipGeneration == generation else { return }
      request.status = .error(ExtensionServiceError.message(error))
      if install?.id == request.id { install = request }
    }
  }

  func cancelInstall() {
    install = nil
  }

  func selected(_ place: SettingsPlace) -> InstalledExtension? {
    guard let detail = place.detail, place.profileId == profileId(for: place) else { return nil }
    return lists[engineProfile(for: place)]?.first { $0.id == detail }
  }

  func isGone(_ place: SettingsPlace) -> Bool {
    place.detail != nil && selected(place) == nil && lists[engineProfile(for: place)] != nil
  }

  func openDetail(_ ext: InstalledExtension, profileId: String, navigation: SettingsNavigation) {
    if navigation.profileId != profileId { navigation.replace(profileId: profileId) }
    navigation.go(.extensions, profileId: profileId, detail: ext.id)
  }

  func showList(profileId: String, navigation: SettingsNavigation) {
    if let previous = navigation.back.last, previous.pane == .extensions, previous.detail == nil, self.profileId(for: previous) == profileId {
      navigation.goBack()
    } else {
      navigation.go(.extensions, profileId: profileId)
    }
  }
}

struct ExtensionsPane: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: ExtensionsPaneModel
  let place: SettingsPlace

  var body: some View {
    let profileId = model.profileId(for: place)
    let profile = model.store.engineProfile(profileId)
    Group {
      if let selected = model.selected(place) {
        ExtensionDetails(model: model, ext: selected, profile: profile, profileId: profileId)
      } else {
        ExtensionsList(model: model, profileId: profileId, profile: profile)
      }
    }
    .task(id: model.services.ownershipGeneration) { await model.prepare(place) }
    .sheet(item: $model.install) { request in
      ExtensionInstallSheet(model: model, request: request)
    }
    .alert(
      model.removal?.title ?? "",
      isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }),
      presenting: model.removal
    ) { _ in
      Button("Remove", role: .destructive) { Task { await model.confirmRemoval() } }
      Button("Cancel", role: .cancel) { model.removal = nil }
    } message: { removal in
      Text(removal.message)
    }
    .onChange(of: model.isGone(place), initial: true) { _, gone in
      if gone { context?.navigation.replace(profileId: profileId, detail: nil) }
    }
  }
}

struct ExtensionsList: View {
  @Environment(\.settingsContext) private var context
  let model: ExtensionsPaneModel
  let profileId: String
  let profile: String
  @State private var link = ""

  var body: some View {
    let profiles = model.store.profiles
    let list = model.lists[profile] ?? []
    SettingsForm {
      SettingsSection(description: context?.index.entry("extensions.installed")?.displayCaption, anchor: "extensions.installed") {
        if profiles.count > 1 {
          SettingPicker(
            profiles.map { SettingOption($0.id, $0.name) },
            selection: Binding(get: { profileId }, set: { context?.navigation.replace(profileId: $0) })
          )
        }
      } content: {
        if list.isEmpty {
          SettingRow(title: "No extensions yet", description: .text("Extensions you add appear here and in the Extensions menu."))
        } else {
          ForEach(list) { ext in
            ExtensionRow(ext: ext) { on in
              Task { await model.setEnabled(profile, ext.id, on) }
            } open: {
              if let navigation = context?.navigation { model.openDetail(ext, profileId: profileId, navigation: navigation) }
            }
          }
        }
      }

      SettingsSection("Add extensions") {
        SettingRow("extensions.webStore") {
          Button("Open Web Store") { model.openWebStore() }
        }
        SettingRow("extensions.addLink") {
          HStack(spacing: 6) {
            TextField("", text: $link, prompt: Text("chromewebstore.google.com/detail/…"))
              .textContentType(.URL)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .frame(width: 210)
              .onSubmit(addLink)
            Button("Add", action: addLink)
              .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        SettingRow("extensions.unpacked") {
          Button("Choose Folder…") {
            Task { await model.loadUnpacked(profile: profile) }
          }
        }
      }
    }
  }

  private func addLink() {
    guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.addFromLink(link, profile: profile)
    link = ""
  }
}

struct ExtensionRow: View {
  let ext: InstalledExtension
  let setEnabled: @MainActor (Bool) -> Void
  let open: @MainActor () -> Void

  var versionText: String { "  \(ext.version)\(ext.fromWebStore ? "" : " · Developer")" }

  var detailText: String {
    if !ext.errors.isEmpty && !ext.enabled { return ext.errors[0] }
    return ext.description
  }

  var body: some View {
    HStack(spacing: 10) {
      ExtensionIcon(uri: ext.icon, size: 24)
        .opacity(ext.enabled ? 1 : 0.5)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(ext.name)\(Text(versionText).foregroundStyle(.tertiary))")
          .lineLimit(1)
        if !detailText.isEmpty {
          Text(detailText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle("", isOn: Binding(get: { ext.enabled }, set: setEnabled))
        .labelsHidden()
        .toggleStyle(.settingsSwitch)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .accessibilityAction(named: "Show Details", open)
  }
}

struct ExtensionDetails: View {
  @Environment(\.settingsContext) private var context
  let model: ExtensionsPaneModel
  let ext: InstalledExtension
  let profile: String
  let profileId: String

  var body: some View {
    SettingsForm {
      Section {
        HStack(spacing: 14) {
          ExtensionIcon(uri: ext.icon, size: 48)
          VStack(alignment: .leading, spacing: 2) {
            Text(ext.name)
              .font(.system(size: 17, weight: .semibold))
            Text("Version \(ext.version)\(ext.fromWebStore ? " · Chrome Web Store" : " · Unpacked")")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Toggle("", isOn: Binding(get: { ext.enabled }, set: { on in Task { await model.setEnabled(profile, ext.id, on) } }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
        }
        if !ext.description.isEmpty {
          Text(ext.description)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Button {
          if let navigation = context?.navigation { model.showList(profileId: profileId, navigation: navigation) }
        } label: {
          Label("All Extensions", systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
      }

      SettingsSection("Permissions") {
        if ext.permissions.isEmpty {
          SettingRow(title: "This extension requires no special permissions.", description: RowDescription.none)
        } else {
          ForEach(ext.permissions, id: \.self) { permission in
            SettingRow(title: permission, description: RowDescription.none)
          }
        }
        if let access = ext.siteAccess {
          SettingRow(title: "Site access", description: .text("Which sites the extension can read and change.")) {
            SettingPicker(
              ExtensionSiteAccess.allCases.map { SettingOption($0.rawValue, $0.title) },
              selection: Binding(get: { access.rawValue }, set: { value in
                guard let next = ExtensionSiteAccess(rawValue: value) else { return }
                Task { await model.configure(profile, ext.id, ExtensionConfiguration(siteAccess: next)) }
              })
            )
          }
        }
      }

      SettingsSection("Settings") {
        SettingRow(title: "Pin to toolbar", description: .text("Show its button next to the address.")) {
          switchFor(ext.pinned) { on in Task { await model.setPinned(profile, ext.id, on) } }
        }
        SettingRow(title: "Allow in Incognito", description: .text("Incognito can't stop extensions from recording your browsing.")) {
          switchFor(ext.incognito) { on in Task { await model.configure(profile, ext.id, ExtensionConfiguration(incognito: on)) } }
        }
        if let options = ext.optionsUrl {
          SettingRow(title: "Extension options", description: RowDescription.none) {
            Button("Open") { model.services.openInNewTab(options) }
          }
        }
        if let store = ext.webStoreUrl {
          SettingRow(title: "View in Chrome Web Store", description: RowDescription.none) {
            Button("Open") { model.services.openInNewTab(store) }
          }
        }
        if !ext.fromWebStore {
          SettingRow(title: "Reload", description: ext.path.map(RowDescription.text) ?? RowDescription.none) {
            Button("Reload") { Task { await model.reload(profile, ext.id) } }
          }
        }
        if !ext.errors.isEmpty {
          SettingRow(title: "Errors", description: .text(ext.errors.prefix(5).joined(separator: "\n")))
        }
        Text("ID \(ext.id)")
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }

      Section {
        Button("Remove Extension…", role: .destructive) {
          model.requestRemoval(ext, profile: profile)
        }
        .disabled(!ext.mayModify)
      }
    }
  }

  private func switchFor(_ value: Bool, _ set: @escaping @MainActor (Bool) -> Void) -> some View {
    Toggle("", isOn: Binding(get: { value }, set: set))
      .labelsHidden()
      .toggleStyle(.settingsSwitch)
  }
}

struct ExtensionIcon: View {
  let uri: String
  let size: CGFloat

  var body: some View {
    if let image = ExtensionIconCache.image(uri) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
    } else {
      Image(systemName: "puzzlepiece.extension.fill")
        .font(.system(size: size * 0.62))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
    }
  }
}

struct ExtensionInstallSheet: View {
  let model: ExtensionsPaneModel
  let request: ExtensionInstallRequest

  static let width: CGFloat = 400
  static let scrollingWarnings = 8

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if case .error(let message) = request.status {
        Text("Couldn't add the extension")
          .font(.system(size: 15, weight: .semibold))
        Text(message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      } else {
        HStack(spacing: 12) {
          if let icon = request.package?.icon, !icon.isEmpty {
            ExtensionIcon(uri: icon, size: 36)
          }
          Text(request.title)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        warnings
        if request.source == .unpacked {
          Text("Loaded from \(request.package?.path ?? "")")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .truncationMode(.middle)
            .padding(.top, 10)
        }
      }
      HStack(spacing: 8) {
        Spacer()
        if case .error = request.status {
          Button("OK") { model.cancelInstall() }
            .keyboardShortcut(.defaultAction)
        } else {
          Button("Cancel") { model.cancelInstall() }
            .keyboardShortcut(.cancelAction)
          Button(request.busy ? "Adding…" : "Add Extension") { Task { await model.confirmInstall() } }
            .keyboardShortcut(.defaultAction)
            .disabled(request.busy)
        }
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: Self.width, alignment: .leading)
    .interactiveDismissDisabled(request.busy)
  }

  @ViewBuilder
  private var warnings: some View {
    let warnings = request.warnings
    if warnings.isEmpty {
      Text("This extension requires no special permissions.")
        .foregroundStyle(.secondary)
        .padding(.top, 14)
    } else {
      Text("It can:")
        .padding(.top, 14)
        .padding(.bottom, 6)
      if warnings.count > Self.scrollingWarnings {
        ScrollView { bullets(warnings) }
          .frame(height: 180)
      } else {
        bullets(warnings)
      }
    }
  }

  private func bullets(_ warnings: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(warnings, id: \.self) { warning in
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text("•")
          Text(warning)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
      }
    }
  }
}
