import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

struct ThemeScopeProjectionTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: ["defaultProfileId": "home"]))
    state.profiles["home"] = Profile(id: "home", name: "Home", color: "green", icon: nil, createdAt: 0)
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0)
    state.windows["w"] = BrowserWindow(id: "w", profileId: "work", incognito: false, frame: nil, createdAt: 0)
    state.profileOrder = ["home", "work"]
    state.ui.focusedWindowId = "w"
    state.ui.appDark = false
    return state
  }

  @Test func resolvesWindowFocusedPageAndDefaultProfiles() {
    var state = fixture()
    #expect(ThemeScopeProjection.project(state, windowId: "w").profileColor == "blue")
    #expect(ThemeScopeProjection.project(state).profileColor == "blue")
    #expect(ThemeScopeProjection.project(state, windowId: "w", pageProfileId: "home").profileColor == "green")
    #expect(ThemeScopeProjection.project(state, windowId: "missing").profileColor == "green")
    #expect(ThemeScopeProjection.project(state, windowId: "w", pageProfileId: "missing").profileColor == "plum")
    state.ui.focusedWindowId = nil
    #expect(ThemeScopeProjection.project(state).profileColor == "green")
  }

  @Test func privateWindowOverridesPageProfileAndAppAppearance() {
    var state = fixture()
    state.windows["w"]?.incognito = true
    let theme = ThemeScopeProjection.project(state, windowId: "w", pageProfileId: "home")
    #expect(theme.dark)
    #expect(theme.profileColor == "incognito")
    #expect(theme.backdrop.tintColor == "#3A3A3C")
    #expect(theme.powerUpPalette == ["#808080A6"])
    #expect(theme.custom == nil)
    #expect(ThemeScopeProjection.project(state) == theme)
  }

  @Test func ownAppAndUtilityAppearanceResolveDarkVariants() {
    var state = fixture()
    state.profiles["work"]?.theme = [
      "mode": "dark", "stops": [["color": ["r": 1, "g": 1, "b": 1]]],
      "dark": ["stops": [["color": ["r": 0, "g": 0, "b": 0]]], "angle": 90],
    ]
    state.settings["spacesFollowAppearance"] = false
    let own = ThemeScopeProjection.project(state, windowId: "w")
    #expect(own.dark)
    #expect(own.powerUpColor == "#000000")
    #expect(own.backdrop.themeAngle == 90)
    #expect(own.backdrop.themeAppearance == .dark)
    state.settings["spacesFollowAppearance"] = true
    let app = ThemeScopeProjection.project(state, windowId: "w")
    #expect(!app.dark)
    #expect(app.powerUpPalette == ["#FFFFFF"])
    #expect(app.backdrop.themeAppearance == .auto)
    state.ui.appDark = true
    let utility = ThemeScopeProjection.project(state)
    #expect(utility.dark)
    #expect(utility.backdrop.themeAppearance == .auto)

    state.profiles["work"]?.theme = ["mode": "auto", "stops": [["color": ["r": 1, "g": 1, "b": 1]]], "translucency": 0]
    #expect(ThemeScopeProjection.project(state).powerUpColor == "#666666")
  }

  @Test func lowContrastInkAndLiveStoreUpdates() throws {
    var state = fixture()
    state.settings["spacesFollowAppearance"] = false
    state.profiles["work"]?.theme = [
      "mode": "dark", "stops": [["color": ["r": 0.70, "g": 0.70, "b": 0.70]]], "translucency": 0,
    ]
    let store = makeUIStore(state)
    let initial = ThemeScopeProjection.project(store.displayState, windowId: "w")
    #expect(initial.dark)
    #expect(initial.sidebarInk?["ink"] == "dark")
    #expect(initial.sidebarInk?["tabSelectedText"] == "#FFFFFF")
    #expect(initial.stripInk == initial.sidebarInk)
    #expect(initial.adjustInk)
    try store.dispatch(Command("updateSettings", [["lightColorsKeepWhiteText": true]]), origin: .native)
    #expect(!ThemeScopeProjection.project(store.displayState, windowId: "w").adjustInk)
    try store.dispatch(SettingsWrites.updateProfile("work", ["theme": .null, "color": "red"]), origin: .native)
    let updated = ThemeScopeProjection.project(store.displayState, windowId: "w")
    #expect(updated.profileColor == "red")
    #expect(updated.powerUpColor == "#C1575C")
    #expect(updated.sidebarInk == nil)
  }
}
