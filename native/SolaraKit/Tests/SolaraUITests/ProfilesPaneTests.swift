import Foundation
import Observation
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
@Observable
final class FakeProfilesServices: ProfilesServices {
  let store: FakeSettingsStore
  var profiles: [ProfileSummary] { didSet { syncStore() } }
  var appDark = false
  var calls: [String] = []
  var keptExtensions: [String]? = []
  var arcChoices: [ArcThemeChoice] = []
  var heldKeyLook = false
  var createdIds = 0

  init(store: FakeSettingsStore, profiles: [ProfileSummary] = ProfilesFixture.profiles) {
    self.store = store
    self.profiles = profiles
    syncStore()
    store.values["defaultProfileId"] = .string("default")
  }

  private func syncStore() {
    store.profiles = profiles.map {
      SettingsProfile(id: $0.id, name: $0.name, engineProfile: $0.usesDefaultEngineProfile ? "" : $0.dataGroup)
    }
  }

  func stats(profileId: String) -> ProfileStats {
    profileId == "default" ? ProfileStats(historyPages: 1_284, bookmarks: 1) : ProfileStats(historyPages: 0, bookmarks: 12)
  }

  func createProfile(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    createdIds += 1
    let id = "new\(createdIds)"
    let source = shareWith.flatMap { share in profiles.first { $0.id == share } }
    profiles.append(ProfileSummary(id: id, name: name, color: color, dataId: source?.dataGroup))
    calls.append("create \(name) \(color.rawValue) \(shareWith ?? "-")")
    return id
  }

  func updateProfile(_ id: String, _ patch: ProfilePatch) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    if let name = patch.name { profiles[index].name = name }
    if let color = patch.color { profiles[index].color = color }
    if let icon = patch.icon { profiles[index].icon = icon }
    if let theme = patch.theme { profiles[index].theme = theme }
    calls.append("update \(id)")
  }

  func deleteProfile(_ id: String, completion: @escaping @MainActor (Bool) -> Void) {
    profiles.removeAll { $0.id == id }
    if store.string("defaultProfileId") == id, let first = profiles.first { store.values["defaultProfileId"] = .string(first.id) }
    calls.append("delete \(id)")
    completion(true)
  }

  func reorderProfiles(_ ids: [String]) {
    profiles = ids.compactMap { id in profiles.first { $0.id == id } }
    calls.append("reorder \(ids.joined(separator: ","))")
  }

  func setDefaultProfile(_ id: String) {
    store.values["defaultProfileId"] = .string(id)
    calls.append("default \(id)")
  }

  func clearHistory(profileId: String, since: Date?) { calls.append("clearHistory \(profileId) \(since == nil ? "all" : "since")") }
  func pruneProfileFavicons(profileId: String) { calls.append("prune \(profileId)") }
  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async {
    calls.append("clearData [\(engineProfile)] \(kinds.map(\.rawValue).joined(separator: ","))")
  }
  func extensionsKeptOnDelete() async -> [String]? { keptExtensions }
  func adoptProfileTheme(_ id: String) { calls.append("adopt \(id)") }
  func holdThemedWindowsKeyLook(_ on: Bool) { heldKeyLook = on }
  func arcThemeChoices() async -> [ArcThemeChoice] { arcChoices }
  func themeSwatch(_ spec: ThemeSwatchSpec) -> AnyView? { nil }
  func hapticTick() { calls.append("haptic") }
}

enum ProfilesFixture {
  static let custom = ProfileThemeValue(
    stops: [
      ThemeStopValue(color: ThemeRGBA(r: 0.36, g: 0.84, b: 0.83), x: 0.2, y: 0.51),
      ThemeStopValue(color: ThemeRGBA(r: 0.36, g: 0.44, b: 0.84), x: 0.31, y: 0.27),
      ThemeStopValue(color: ThemeRGBA(r: 0.84, g: 0.36, b: 0.83), x: 0.66, y: 0.24),
    ],
    intensity: 0.6,
    mode: .auto,
    grain: 0.3,
    texture: .denim,
    translucency: 0.8,
    angle: 120
  )

  static var withDarkLook: ProfileThemeValue {
    var theme = ThemeMath.starting(swatch: ProfileColorValue.orange.swatch)
    theme.dark = ThemeLookValue(stops: custom.stops, intensity: 0.4, grain: 0, texture: .grain, translucency: 1, angle: 200)
    return theme
  }

  static let profiles = [
    ProfileSummary(id: "default", name: "Personal", color: .plum, icon: "symbol:house.fill"),
    ProfileSummary(id: "work", name: "Work", color: .blue, icon: "symbol:briefcase.fill", theme: custom),
    ProfileSummary(id: "side", name: "Side Project", color: .green, icon: "🚀", dataId: "default"),
    ProfileSummary(id: "studio", name: "Studio", color: .orange, theme: withDarkLook),
  ]
}

@MainActor
struct ProfilesPaneTests {
  func make(_ profiles: [ProfileSummary] = ProfilesFixture.profiles) -> (ProfilesPaneModel, FakeProfilesServices, FakeSettingsStore) {
    let store = FakeSettingsStore()
    let services = FakeProfilesServices(store: store, profiles: profiles)
    return (ProfilesPaneModel(services: services, store: store), services, store)
  }

  @Test func rowDescriptionsShowDefaultAndSharing() {
    let (model, _, _) = make()
    #expect(model.rowDescription("default") == "Default · Shares data with Side Project")
    #expect(model.rowDescription("side") == "Shares data with Personal")
    #expect(model.rowDescription("work") == "")
    #expect(model.sharedWith("side") == ["default", "side"])
    #expect(model.sharedWith("work") == ["work"])
  }

  @Test func nameListsMatchRN() {
    #expect(ProfileNames.listOf(["A"]) == "A")
    #expect(ProfileNames.listOf(["A", "B"]) == "A and B")
    #expect(ProfileNames.listOf(["A", "B", "C"]) == "A, B, and C")
    #expect(ProfileNames.ampersand(["A", "B"]) == "A & B")
    #expect(ProfileNames.ampersand(["A", "B", "C", "D"]) == "A, B, & 2 more")
    #expect(ProfileStats(historyPages: 1, bookmarks: 0).text == "1 page in history · 0 bookmarks")
  }

  @Test func reorderMath() {
    #expect(ProfileReorder.target(0, from: 1, count: 4) == 1)
    #expect(ProfileReorder.target(23, from: 1, count: 4) == 2)
    #expect(ProfileReorder.target(22, from: 1, count: 4) == 1)
    #expect(ProfileReorder.target(-500, from: 1, count: 4) == 0)
    #expect(ProfileReorder.target(500, from: 1, count: 4) == 3)
    #expect(ProfileReorder.clampedOffset(500, from: 1, count: 4) == CGFloat(98))
    #expect(ProfileReorder.clampedOffset(-500, from: 1, count: 4) == CGFloat(-52))
    #expect(ProfileReorder.neighborOffset(2, from: 0, to: 2) == -46)
    #expect(ProfileReorder.neighborOffset(3, from: 0, to: 2) == 0)
    #expect(ProfileReorder.neighborOffset(1, from: 3, to: 1) == 46)
  }

  @Test func moveReordersOnlyWhenChanged() {
    let (model, services, _) = make()
    model.move("work", to: 1)
    #expect(services.calls.isEmpty)
    model.move("work", to: 3)
    #expect(services.calls == ["reorder default,side,studio,work"])
  }

  @Test func deletePromptForSharingProfile() async {
    let (model, _, _) = make()
    await model.requestDelete("side", fromDetails: false)
    #expect(model.deletePrompt?.title == "Delete “Side Project”?")
    #expect(model.deletePrompt?.message == "Its tabs will be closed. Its cookies, passwords, extensions, bookmarks and history stay with Personal, which share them.")
  }

  @Test func deletePromptMentionsKeptExtensionsOnlyForTheDefaultEngineProfile() async {
    let (model, services, _) = make(Array(ProfilesFixture.profiles.prefix(2)))
    services.keptExtensions = ["uBlock", "1Password"]
    await model.requestDelete("default", fromDetails: false)
    #expect(model.deletePrompt?.message == "All data associated with this Profile will be removed. This action cannot be undone. Its extensions (uBlock & 1Password) stay installed on this Mac, turned off.")
    await model.requestDelete("work", fromDetails: false)
    #expect(model.deletePrompt?.message == "All data associated with this Profile will be removed. This action cannot be undone.")
    services.keptExtensions = nil
    await model.requestDelete("default", fromDetails: false)
    #expect(model.deletePrompt?.message.hasSuffix(" Its extensions stay installed on this Mac, turned off.") == true)
  }

  @Test func onlyProfileCannotBeDeleted() async {
    let (model, _, _) = make([ProfilesFixture.profiles[0]])
    await model.requestDelete("default", fromDetails: true)
    #expect(model.deletePrompt == nil)
  }

  @Test func confirmingDeleteFromDetailsGoesBackToTheList() async {
    let (model, services, _) = make()
    let navigation = SettingsNavigation(place: SettingsPlace(pane: .profiles, profileId: "work"))
    await model.requestDelete("work", fromDetails: true)
    let prompt = try! #require(model.deletePrompt)
    model.confirmDelete(prompt, navigation: navigation)
    #expect(services.calls == ["delete work"])
    #expect(navigation.place == SettingsPlace(pane: .profiles))
    #expect(model.deletePrompt == nil)
  }

  @Test func nameCommitTrimsAndRestoresEmpty() {
    let (model, services, _) = make()
    #expect(model.updateName("work", "  ") == "Work")
    #expect(services.calls.isEmpty)
    #expect(model.updateName("work", " Office ") == "Office")
    #expect(model.profile("work")?.name == "Office")
  }

  @Test func clearDataClearsHistoryThenEngineData() async {
    let (model, services, _) = make()
    await model.clearData(profileId: "work", range: .all, history: true, siteData: true)
    #expect(services.calls == ["clearHistory work all", "prune work", "clearData [work] history,siteData,cache"])
    services.calls = []
    await model.clearData(profileId: "side", range: .hour, history: false, siteData: true)
    #expect(services.calls == ["clearData [] siteData,cache"])
    #expect(ClearDataRange.week.since(Date(timeIntervalSince1970: 1_000_000)) == Date(timeIntervalSince1970: 1_000_000 - 604_800))
  }

  @Test func presetColorClearsTheThemeAndAdopts() {
    let (model, services, _) = make()
    model.choosePreset("work", .red)
    #expect(services.calls == ["adopt work", "update work"])
    #expect(model.profile("work")?.theme == nil)
    #expect(model.profile("work")?.color == .red)
  }

  @Test func liveThemeChangesCoalesceUntilSettled() async throws {
    let (model, services, _) = make()
    var theme = ProfilesFixture.custom
    theme.intensity = 0.2
    model.changeTheme("work", theme, settle: false)
    theme.intensity = 0.3
    model.changeTheme("work", theme, settle: false)
    #expect(model.editedTheme("work")?.intensity == 0.3)
    #expect(services.calls.isEmpty)
    for _ in 0..<50 where services.calls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(services.calls == ["adopt work", "update work"])
    theme.intensity = 0.9
    model.changeTheme("work", theme, settle: true)
    #expect(model.themeDrafts["work"] == nil)
    #expect(model.profile("work")?.theme?.intensity == 0.9)
  }

  @Test func themeStateDescribesTheLook() {
    let plain = ThemeEditorState(stored: nil, appDark: false, source: .own)
    #expect(plain.colorDescription(preset: .blue) == "Blue")
    let custom = ThemeEditorState(stored: ProfilesFixture.custom, appDark: false, source: .own)
    #expect(custom.colorDescription(preset: .blue) == "Custom gradient")
    let split = ThemeEditorState(stored: ProfilesFixture.withDarkLook, appDark: true, source: .own)
    #expect(split.colorDescription(preset: .blue) == "Separate light and dark looks. Editing keeps the dark one.")
    #expect(split.custom?.angle == 200)
    #expect(split.custom?.dark == nil)
  }

  @Test func newProfileTakesTheFirstUnusedColor() {
    #expect(ProfileColorValue.unused(by: ProfilesFixture.profiles) == .purple)
  }

  @Test func iconTitles() {
    #expect(ProfileIcons.title(nil) == "Initial")
    #expect(ProfileIcons.title("symbol:airplane") == "Travel")
    #expect(ProfileIcons.title("symbol:cup.and.saucer") == "Cup and saucer")
    #expect(ProfileIcons.title("symbol:checkmark.seal") == "Checkmark seal")
    #expect(ProfileIcons.title("🚀") == "🚀")
  }

  @Test func theIconPickerOpensAsAProfilePickerThatOffersTheInitial() {
    let state = ProfileIconPicker.state(profileId: "p1", current: "🚀", dark: true)
    #expect(state.kind == "profile")
    #expect(state.id == "p1")
    #expect(state.dark)
    #expect(SidebarIconPickerMetrics.showsFooter(state))
    #expect(!SidebarIconPickerMetrics.showsFooter(ProfileIconPicker.state(profileId: "p1", current: nil, dark: false)))
  }

  @Test func detailsTitleIsTheProfileName() {
    let (context, store) = SettingsFixture.context()
    let services = FakeProfilesServices(store: store)
    _ = services
    #expect(context.title(for: SettingsPlace(pane: .profiles, profileId: "side")) == "Side Project")
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersProfiles() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, store) = await SettingsFixture.loaded()
    let services = FakeProfilesServices(store: store)
    services.arcChoices = [ArcThemeChoice(id: "s1", name: "Research", emoji: "🔬", theme: ProfilesFixture.custom)]
    let model = ProfilesPaneModel(services: services, store: store)
    context.panes[.profiles] = model
    await model.loadArcChoices()
    try await Snapshot.renderPanes(
      context,
      [.profiles],
      places: ["default", "work", "studio"].map { SettingsPlace(pane: .profiles, profileId: $0) },
      named: { place in place.profileId.map { "profiles-\($0)" } ?? "profiles" }
    )
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      try await Snapshot.render(
        CreateProfileSheet(model: model) {}.environment(\.settingsContext, context),
        size: NSSize(width: 460, height: 420), dark: dark,
        to: directory.appendingPathComponent("profiles-create-\(scheme).png")
      )
      try await Snapshot.render(
        ClearBrowsingDataSheet(model: model, profileId: "work") {}.environment(\.settingsContext, context),
        size: NSSize(width: 480, height: 300), dark: dark,
        to: directory.appendingPathComponent("profiles-clear-\(scheme).png")
      )
    }
  }
}
