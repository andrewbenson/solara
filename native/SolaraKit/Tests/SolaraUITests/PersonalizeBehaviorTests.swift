import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

struct PersonalizeBehaviorTests {
  private let appearance = PersonalizeAppearance(dark: true, tokens: ["icon": "#FFFFFF"])

  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.profiles["p"] = Profile(id: "p", name: "Work", color: "plum", icon: nil, createdAt: 0, theme: ["mode": "dark"])
    state.profiles["other"] = Profile(id: "other", name: "Home", color: "green", icon: nil, createdAt: 0)
    state.windows["w"] = BrowserWindow(id: "w", profileId: "p", incognito: false, frame: nil, createdAt: 0)
    state.windows["second"] = BrowserWindow(id: "second", profileId: "other", incognito: false, frame: nil, createdAt: 0)
    return state
  }

  private func project(_ state: BrowserState, window: String = "w", open: Bool = true) -> PersonalizeState? {
    PersonalizeBehavior.project(state, windowId: window, open: open, appearance: appearance)
  }

  @Test func profileLayoutAndAppearanceComeFromCurrentNativeState() throws {
    var state = fixture()
    state.settings["tabLayout"] = "top"
    let shown = try #require(project(state))
    #expect(shown.profileId == "p" && shown.color == "plum" && shown.layout == "top")
    #expect(shown.dark && shown.tokens["icon"] == "#FFFFFF" && shown.canPickColor)
    state.windows["w"]?.tabLayout = "sidebar"
    #expect(project(state)?.layout == "sidebar")
    #expect(project(state, window: "second")?.color == "green")
    state.profiles["p"] = nil
    #expect(project(state)?.canPickColor == false)
    #expect(project(state)?.color == nil)
  }

  @Test func privateAndMissingWindowsHaveNoSurface() {
    var state = fixture()
    state.windows["w"]?.incognito = true
    #expect(project(state) == nil)
    #expect(project(state, window: "gone") == nil)
  }

  private func safeModeStore() -> Store {
    var config = StoreConfig()
    config.safeMode = true
    return Store(state: fixture(), config: config)
  }

  @Test func safeModeStillProjectsPersonalize() throws {
    let store = safeModeStore()
    let shown = try #require(project(store.state))
    #expect(shown.open && shown.color == "plum" && shown.canPickColor)
  }

  @Test func safeModeStillTogglesBetweenClassicAndSidebar() throws {
    let store = safeModeStore()
    for layout in ["top", "sidebar"] {
      let command = PersonalizeBehavior.command("layout", value: layout, presented: project(store.state), state: store.state, windowId: "w")
      try store.dispatch(try #require(command), origin: .native)
      #expect(project(store.state)?.layout == layout)
    }
  }

  @Test func safeModeRefusesColorWithProfileEditFeedback() throws {
    let store = safeModeStore()
    let command = try #require(PersonalizeBehavior.command("color", value: "blue", presented: project(store.state), state: store.state, windowId: "w"))
    let refusal = #expect(throws: CommandError.self) { try store.dispatch(command, origin: .native) }
    #expect(refusal?.description == "Profile edits can't be saved in safe mode while the saved session and launch appearance are kept unchanged. Open Solara normally to edit profiles.")
    #expect(project(store.state)?.color == "plum")
  }

  @Test func choicesAreRefusedWhileTheWindowIsClosing() throws {
    let store = makeUIStore(fixture())
    let shown = try #require(project(store.state))
    for origin: Origin in [.native, .bridge] {
      try store.dispatch(Command("setWindowClosing", ["w", true]), origin: origin)
      #expect(PersonalizeBehavior.command("layout", value: "top", presented: shown, state: store.state, windowId: "w", closing: store.memory.closingWindows) == nil)
      #expect(PersonalizeBehavior.command("color", value: "blue", presented: shown, state: store.state, windowId: "w", closing: store.memory.closingWindows) == nil)
      try store.dispatch(Command("setWindowClosing", ["w", false]), origin: origin)
      #expect(PersonalizeBehavior.command("layout", value: "top", presented: shown, state: store.state, windowId: "w", closing: store.memory.closingWindows) == Command("toggleTabLayout", ["w"]))
      #expect(PersonalizeBehavior.command("color", value: "blue", presented: shown, state: store.state, windowId: "w", closing: store.memory.closingWindows) == SettingsWrites.updateProfile("p", ["color": "blue"]))
    }
  }

  @Test func colorPreservesThemeAndSelectedLayoutDoesNothing() throws {
    let state = fixture()
    let shown = try #require(project(state))
    let color = PersonalizeBehavior.command("color", value: "blue", presented: shown, state: state, windowId: "w")
    #expect(color == SettingsWrites.updateProfile("p", ["color": "blue"]))
    let store = makeUIStore(state)
    try store.dispatch(try #require(color), origin: .native)
    #expect(store.state.profiles["p"]?.theme == state.profiles["p"]?.theme)
    #expect(PersonalizeBehavior.command("layout", value: shown.layout, presented: shown, state: state, windowId: "w") == nil)
    let other = shown.layout == "top" ? "sidebar" : "top"
    #expect(PersonalizeBehavior.command("layout", value: other, presented: shown, state: state, windowId: "w") == Command("toggleTabLayout", ["w"]))
  }

  @Test func closedInvalidStaleAndPrivateActionsAreRefused() throws {
    var state = fixture()
    let shown = try #require(project(state))
    #expect(PersonalizeBehavior.command("color", value: "toString", presented: shown, state: state, windowId: "w") == nil)
    #expect(PersonalizeBehavior.command("layout", value: "invalid", presented: shown, state: state, windowId: "w") == nil)
    #expect(PersonalizeBehavior.command("color", value: "blue", presented: project(state, open: false), state: state, windowId: "w") == nil)
    #expect(PersonalizeBehavior.command("color", value: "blue", presented: shown, state: state, windowId: "second") == nil)
    state.windows["w"]?.profileId = "other"
    #expect(PersonalizeBehavior.command("color", value: "blue", presented: shown, state: state, windowId: "w") == nil)
    state.windows["w"]?.profileId = "p"
    state.windows["w"]?.incognito = true
    #expect(PersonalizeBehavior.command("layout", value: "top", presented: shown, state: state, windowId: "w") == nil)
    state.windows["w"] = nil
    #expect(PersonalizeBehavior.command("layout", value: "top", presented: shown, state: state, windowId: "w") == nil)
  }
}
