import AppKit
import Observation
import SwiftUI

public struct ProfileSummary: Hashable, Sendable, Identifiable {
  public static let defaultProfileId = "default"

  public var id: String
  public var name: String
  public var color: ProfileColorValue
  public var icon: String?
  public var dataId: String?
  public var theme: ProfileThemeValue?

  public init(id: String, name: String, color: ProfileColorValue, icon: String? = nil, dataId: String? = nil, theme: ProfileThemeValue? = nil) {
    self.id = id
    self.name = name
    self.color = color
    self.icon = icon
    self.dataId = dataId
    self.theme = theme
  }

  public var dataGroup: String { dataId ?? id }
  public var usesDefaultEngineProfile: Bool { dataGroup == Self.defaultProfileId }

  public var accent: String {
    if let theme { return ThemeMath.accent(theme) }
    return color.swatch
  }

  var initial: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.first.map(String.init) ?? "?").uppercased()
  }
}

public struct ProfileStats: Hashable, Sendable {
  public var historyPages: Int
  public var bookmarks: Int

  public init(historyPages: Int, bookmarks: Int) {
    self.historyPages = historyPages
    self.bookmarks = bookmarks
  }

  var text: String { "\(ProfileNames.plural(historyPages, "page")) in history · \(ProfileNames.plural(bookmarks, "bookmark"))" }
}

public struct ProfilePatch: Hashable, Sendable {
  public var name: String?
  public var color: ProfileColorValue?
  public var icon: String??
  public var theme: ProfileThemeValue??

  public init(name: String? = nil, color: ProfileColorValue? = nil, icon: String?? = nil, theme: ProfileThemeValue?? = nil) {
    self.name = name
    self.color = color
    self.icon = icon
    self.theme = theme
  }
}

public struct ArcThemeChoice: Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var emoji: String?
  public var theme: ProfileThemeValue

  public init(id: String, name: String, emoji: String? = nil, theme: ProfileThemeValue) {
    self.id = id
    self.name = name
    self.emoji = emoji
    self.theme = theme
  }

  var title: String { emoji.map { "\($0)  \(name)" } ?? name }
}

public enum BrowsingDataKind: String, Hashable, Sendable {
  case history
  case siteData
  case cache
}

@MainActor
public protocol ProfilesServices: AnyObject {
  var profiles: [ProfileSummary] { get }
  var appDark: Bool { get }
  func stats(profileId: String) -> ProfileStats
  func createProfile(name: String, color: ProfileColorValue, shareWith: String?) -> String
  func updateProfile(_ id: String, _ patch: ProfilePatch)
  func deleteProfile(_ id: String, completion: @escaping @MainActor (Bool) -> Void)
  func reorderProfiles(_ ids: [String])
  func setDefaultProfile(_ id: String)
  func clearHistory(profileId: String, since: Date?)
  func pruneProfileFavicons(profileId: String)
  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async
  func extensionsKeptOnDelete() async -> [String]?
  func adoptProfileTheme(_ id: String)
  func holdThemedWindowsKeyLook(_ on: Bool)
  func arcThemeChoices() async -> [ArcThemeChoice]
  func themeSwatch(_ spec: ThemeSwatchSpec) -> AnyView?
  func hapticTick()
}

public struct ProfileDeletePrompt: Identifiable, Hashable, Sendable {
  public var id: String { profileId }
  public let profileId: String
  public let title: String
  public let message: String
  public let fromDetails: Bool
  public let canDelete: Bool
}

@MainActor
@Observable
public final class ProfilesPaneModel: SettingsPaneProvider {
  @ObservationIgnored let safeMode: Bool
  @ObservationIgnored let services: ProfilesServices
  @ObservationIgnored let store: SettingsStoreSource
  var creating = false
  var clearingProfileId: String?
  var deletePrompt: ProfileDeletePrompt?
  var arcChoices: [ArcThemeChoice]?
  var themeDrafts: [String: ProfileThemeValue] = [:]
  @ObservationIgnored var pendingThemes: [String: ProfileThemeValue] = [:]
  @ObservationIgnored var themeFlush: Task<Void, Never>?

  public init(services: ProfilesServices, store: SettingsStoreSource, safeMode: Bool = false) {
    self.safeMode = safeMode
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { true }

  public func prepare(_ place: SettingsPlace) async {}

  public func view(_ place: SettingsPlace) -> AnyView {
    if let id = place.profileId {
      return AnyView(ProfileDetailsPane(model: self, profileId: id).id(id))
    }
    return AnyView(ProfilesPane(model: self))
  }

  var profiles: [ProfileSummary] { services.profiles }
  var order: [String] { profiles.map(\.id) }
  var defaultProfileId: String { store.string("defaultProfileId") }
  var lookSource: ThemeLookSource { store.bool("spacesFollowAppearance") ? .app : .own }

  func sharingProfiles(_ id: String) -> [String] {
    guard let profile = profile(id) else { return [] }
    return profiles.filter { $0.id != id && $0.dataGroup == profile.dataGroup }.map(\.id)
  }

  func sharedWith(_ id: String) -> [String] {
    let others = sharingProfiles(id)
    return others.isEmpty ? [id] : order.filter { $0 == id || others.contains($0) }
  }

  func rowDescription(_ id: String) -> String {
    let names = sharedWith(id).filter { $0 != id }.compactMap { profile($0)?.name }
    return [
      id == defaultProfileId ? "Default" : nil,
      names.isEmpty ? nil : "Shares data with \(ProfileNames.listOf(names))",
    ].compactMap { $0 }.joined(separator: " · ")
  }

  func setDefault(_ id: String) {
    guard profile(id) != nil else { return }
    services.setDefaultProfile(id)
  }

  func create(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    services.createProfile(name: name, color: color, shareWith: shareWith)
  }

  func requestDelete(_ id: String, fromDetails: Bool) async {
    guard let profile = profile(id), profiles.count > 1 else { return }
    if safeMode {
      deletePrompt = ProfileDeletePrompt(
        profileId: id, title: "Safe Mode", message: "Profiles can't be deleted in safe mode. Quit and open Solara normally to delete one.",
        fromDetails: fromDetails, canDelete: false)
      return
    }
    let sharing = sharingProfiles(id).compactMap { self.profile($0)?.name }
    let message: String
    if !sharing.isEmpty {
      message = "Its tabs will be closed. Its cookies, passwords, extensions, bookmarks and history stay with \(ProfileNames.ampersand(sharing)), which share them."
    } else {
      let note = profile.usesDefaultEngineProfile ? Self.keptExtensionsNote(await services.extensionsKeptOnDelete()) : ""
      message = "All data associated with this Profile will be removed. This action cannot be undone.\(note)"
    }
    deletePrompt = ProfileDeletePrompt(profileId: id, title: "Delete “\(profile.name)”?", message: message, fromDetails: fromDetails, canDelete: true)
  }

  static func keptExtensionsNote(_ names: [String]?) -> String {
    guard let names else { return " Its extensions stay installed on this Mac, turned off." }
    if names.isEmpty { return "" }
    return " Its extensions (\(ProfileNames.ampersand(names))) stay installed on this Mac, turned off."
  }

  func confirmDelete(_ prompt: ProfileDeletePrompt, navigation: SettingsNavigation?) {
    deletePrompt = nil
    guard !safeMode, prompt.canDelete, profiles.count > 1, profile(prompt.profileId) != nil else { return }
    services.deleteProfile(prompt.profileId) { deleted in
      if deleted, prompt.fromDetails, navigation?.profileId?.utf16.elementsEqual(prompt.profileId.utf16) == true { navigation?.go(.profiles) }
    }
  }

  func refuseProfileEdit(_ id: String) -> Bool {
    guard safeMode else { return false }
    deletePrompt = ProfileDeletePrompt(
      profileId: id, title: "Safe Mode", message: "Profile edits can't be saved in safe mode while the saved session and launch appearance are kept unchanged. Open Solara normally to edit profiles.",
      fromDetails: false, canDelete: false)
    return true
  }

  func move(_ id: String, to target: Int) {
    guard !refuseProfileEdit(id) else { return }
    var ids = order.filter { $0 != id }
    ids.insert(id, at: min(max(0, target), ids.count))
    if ids != order { services.reorderProfiles(ids) }
  }

  func updateName(_ id: String, _ draft: String) -> String? {
    guard let profile = profile(id) else { return nil }
    guard !refuseProfileEdit(id) else { return profile.name }
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return profile.name }
    if trimmed != profile.name { services.updateProfile(id, ProfilePatch(name: trimmed)) }
    return trimmed
  }

  func setIcon(_ id: String, _ icon: String?) {
    guard !refuseProfileEdit(id) else { return }
    services.updateProfile(id, ProfilePatch(icon: .some(icon)))
  }

  func clearData(profileId: String, range: ClearDataRange, history: Bool, siteData: Bool, now: Date = Date()) async {
    let since = range.since(now)
    if history {
      services.clearHistory(profileId: profileId, since: since)
      services.pruneProfileFavicons(profileId: profileId)
    }
    let kinds: [BrowsingDataKind] = (history ? [.history] : []) + (siteData ? [.siteData, .cache] : [])
    if !kinds.isEmpty { await services.clearBrowsingData(engineProfile: store.engineProfile(profileId), kinds: kinds, since: since) }
  }

  func editedTheme(_ id: String) -> ProfileThemeValue? {
    themeDrafts[id] ?? profile(id)?.theme
  }

  func changeTheme(_ id: String, _ next: ProfileThemeValue, settle: Bool) {
    guard !refuseProfileEdit(id) else { return }
    pendingThemes[id] = next
    if settle {
      themeDrafts[id] = nil
      themeFlush?.cancel()
      themeFlush = nil
      flushThemes()
    } else {
      themeDrafts[id] = next
      guard themeFlush == nil else { return }
      themeFlush = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, let self else { return }
        themeFlush = nil
        flushThemes()
      }
    }
  }

  func flushThemes() {
    let pending = pendingThemes
    pendingThemes = [:]
    for (id, theme) in pending {
      services.adoptProfileTheme(id)
      services.updateProfile(id, ProfilePatch(theme: .some(theme)))
    }
  }

  func choosePreset(_ id: String, _ color: ProfileColorValue) {
    guard !refuseProfileEdit(id) else { return }
    pendingThemes[id] = nil
    themeDrafts[id] = nil
    services.adoptProfileTheme(id)
    services.updateProfile(id, ProfilePatch(color: color, theme: .some(nil)))
  }

  func importArcTheme(_ id: String, _ choice: ArcThemeChoice) {
    guard !refuseProfileEdit(id) else { return }
    pendingThemes[id] = nil
    themeDrafts[id] = nil
    services.adoptProfileTheme(id)
    services.updateProfile(id, ProfilePatch(theme: .some(choice.theme)))
  }

  func loadArcChoices() async {
    arcChoices = await services.arcThemeChoices()
  }
}

struct ProfilesPane: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: ProfilesPaneModel

  var body: some View {
    SettingsForm {
      Section {
        EmptyView()
      } header: {
        Text("Profiles keep browsing data separate unless you choose Share data when creating one. Tabs always stay separate.")
          .font(.callout)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      SettingsSection("New windows open with") {
        SettingRow("profiles.defaultProfile") {
          SettingPicker(
            model.profiles.map { SettingOption($0.id, $0.name) },
            selection: Binding(get: { model.defaultProfileId }, set: { model.setDefault($0) })
          )
          .frame(minWidth: 160, alignment: .trailing)
        }
      }

      SettingsSection(description: context?.index.entry("profiles.list")?.displayCaption, anchor: "profiles.list") {
        Button {
          model.creating = true
        } label: {
          Label("Create Profile", systemImage: "plus")
        }
      } content: {
        ProfileList(model: model)
          .listRowInsets(EdgeInsets())
      }
    }
    .sheet(isPresented: $model.creating) {
      CreateProfileSheet(model: model) { model.creating = false }
    }
    .profileDeleteAlert(model: model)
  }
}

extension View {
  func profileDeleteAlert(model: ProfilesPaneModel) -> some View {
    modifier(ProfileDeleteAlert(model: model))
  }
}

struct ProfileDeleteAlert: ViewModifier {
  @Environment(\.settingsContext) private var context
  @Bindable var model: ProfilesPaneModel

  func body(content: Content) -> some View {
    let prompt = model.deletePrompt
    content.alert(
      prompt?.title ?? "",
      isPresented: Binding(get: { model.deletePrompt != nil }, set: { if !$0 { model.deletePrompt = nil } }),
      presenting: prompt
    ) { prompt in
      if prompt.canDelete {
        Button("Delete Profile", role: .destructive) { model.confirmDelete(prompt, navigation: context?.navigation) }
        Button("Cancel", role: .cancel) { model.deletePrompt = nil }
      } else {
        Button("OK", role: .cancel) { model.deletePrompt = nil }
      }
    } message: { prompt in
      Text(prompt.message)
    }
  }
}

enum ProfileReorder {
  static let rowHeight: CGFloat = 46
  static let overshoot: CGFloat = 6

  static func clampedOffset(_ dy: CGFloat, from: Int, count: Int) -> CGFloat {
    let maxIndex = count - 1
    return max(-CGFloat(from) * rowHeight - overshoot, min(CGFloat(maxIndex - from) * rowHeight + overshoot, dy))
  }

  static func target(_ dy: CGFloat, from: Int, count: Int) -> Int {
    let raw = (CGFloat(from) + dy / rowHeight)
    let rounded = Int((raw + 0.5).rounded(.down))
    return max(0, min(count - 1, rounded))
  }

  static func neighborOffset(_ index: Int, from: Int, to: Int) -> CGFloat {
    if from < index && index <= to { return -rowHeight }
    if to <= index && index < from { return rowHeight }
    return 0
  }
}

struct ProfileList: View {
  let model: ProfilesPaneModel
  @State private var dragging: String?
  @State private var dragOffset: CGFloat = 0
  @State private var target = 0

  var body: some View {
    let ids = model.order
    let from = dragging.flatMap { ids.firstIndex(of: $0) } ?? 0
    VStack(spacing: 0) {
      ForEach(Array(ids.enumerated()), id: \.element) { index, id in
        if let profile = model.profile(id) {
          let lifted = dragging == id
          ProfileRow(model: model, profile: profile, first: index == 0, lifted: lifted)
            .offset(y: lifted ? dragOffset : dragging == nil ? 0 : ProfileReorder.neighborOffset(index, from: from, to: target))
            .zIndex(lifted ? 1 : 0)
            .animation(lifted ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.16), value: target)
            .animation(lifted ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.16), value: dragging)
            .gesture(
              DragGesture(minimumDistance: 3)
                .onChanged { value in drag(id, ids: ids, dy: value.translation.height) }
                .onEnded { _ in end(commit: true) }
            )
        }
      }
    }
  }

  private func drag(_ id: String, ids: [String], dy: CGFloat) {
    if dragging != id {
      dragging = id
      target = ids.firstIndex(of: id) ?? 0
    }
    let from = ids.firstIndex(of: id) ?? 0
    dragOffset = ProfileReorder.clampedOffset(dy, from: from, count: ids.count)
    let next = ProfileReorder.target(dy, from: from, count: ids.count)
    if next != target {
      target = next
      model.services.hapticTick()
    }
  }

  private func end(commit: Bool) {
    guard let id = dragging else { return }
    let from = model.order.firstIndex(of: id) ?? 0
    var transaction = Transaction()
    transaction.disablesAnimations = commit && from != target
    withTransaction(transaction) {
      if commit && from != target { model.move(id, to: target) }
      dragging = nil
      dragOffset = 0
    }
  }
}

struct ProfileRow: View {
  @Environment(\.settingsContext) private var context
  let model: ProfilesPaneModel
  let profile: ProfileSummary
  let first: Bool
  let lifted: Bool
  @State private var hovered: Bool

  init(model: ProfilesPaneModel, profile: ProfileSummary, first: Bool, lifted: Bool, hovered: Bool = false) {
    self.model = model
    self.profile = profile
    self.first = first
    self.lifted = lifted
    _hovered = State(initialValue: hovered)
  }

  var body: some View {
    let description = model.rowDescription(profile.id)
    VStack(spacing: 0) {
      if !first && !lifted {
        Divider().padding(.horizontal, 12)
      }
      HStack(spacing: 10) {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .frame(width: 14, height: 14)
          .help("Drag to reorder")
        ProfileBadge(profile: profile)
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.name)
            .font(.system(size: 13))
          if !description.isEmpty {
            Text(description)
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 12, height: 14)
      }
      .padding(.leading, 8)
      .padding(.trailing, 12)
      .frame(height: ProfileReorder.rowHeight - (first ? 0 : 1))
      .background {
        if hovered && !lifted {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .padding(.horizontal, -6)
            .padding(.vertical, 2)
        }
      }
    }
    .background {
      if lifted {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(nsColor: .windowBackgroundColor))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture { context?.navigation.go(.profiles, profileId: profile.id) }
    .contextMenu {
      Button("Show Profile Details") { context?.navigation.go(.profiles, profileId: profile.id) }
      Button("Make Default Profile") { model.setDefault(profile.id) }
        .disabled(profile.id == model.defaultProfileId)
      Divider()
      Button("Delete Profile…") { Task { await model.requestDelete(profile.id, fromDetails: false) } }
        .disabled(model.profiles.count <= 1)
    }
  }
}
