import SolaraModel
import Testing
@testable import SolaraStore

struct ProfileThemeEditTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.profiles["p"] = Profile(id: "p", name: "Work", color: "plum", icon: nil, createdAt: 0)
    state.profileOrder = ["p"]
    return state
  }

  @Test func installsAndClearsOnlyTheTheme() {
    let state = fixture()
    let theme: JSONValue = ["mode": "dark", "intensity": 0.6]
    #expect(ProfileThemeEdit.command(profileId: "p", kind: "theme", value: theme, state: state) == SettingsWrites.updateProfile("p", ["theme": theme]))
    #expect(ProfileThemeEdit.command(profileId: "p", kind: "theme", value: .null, state: state) == SettingsWrites.updateProfile("p", ["theme": .null]))
  }

  @Test func presetClearsCustomThemeThroughTheCanonicalReducer() throws {
    var state = fixture()
    state.profiles["p"]?.theme = ["mode": "dark"]
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: "theme-edit")), checksInvariants: false, clock: { 1 })
    let command = try #require(ProfileThemeEdit.command(profileId: "p", fields: ["color": "blue", "theme": .null], state: store.state))
    try store.dispatch(command, origin: .native)
    #expect(store.state.profiles["p"]?.color == "blue")
    #expect(store.state.profiles["p"]?.theme == .null || store.state.profiles["p"]?.theme == nil)
    #expect(store.state.profiles["p"]?.name == "Work")
  }

  @Test func rejectsMissingProfilesInvalidPresetsAndMalformedRequests() {
    let state = fixture()
    #expect(ProfileThemeEdit.command(profileId: "gone", kind: "theme", value: .null, state: state) == nil)
    for value in ["toString", "invalid", .null, 4] as [JSONValue] {
      #expect(ProfileThemeEdit.command(profileId: "p", kind: "preset", value: value, state: state) == nil)
    }
    #expect(ProfileThemeEdit.command(profileId: "p", kind: "theme", value: "bad", state: state) == nil)
    #expect(ProfileThemeEdit.command(profileId: "p", kind: "other", value: .null, state: state) == nil)
  }
}
