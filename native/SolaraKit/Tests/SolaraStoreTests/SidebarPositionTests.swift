import SolaraModel
import SolaraStore
import Testing

@Suite struct SidebarPositionTests {
  func window(_ store: Store, small: Bool = false) throws -> String {
    try store.dispatch(Command("createWindow", [["url": "https://side.example/", "small": .bool(small)]])).result!.string!
  }

  @Test func windowChoicePinsPeersAndSeedsNewWindows() throws {
    let store = makeStore()
    let first = try window(store)
    let second = try window(store)
    let little = try window(store, small: true)
    #expect(store.state.windows[first]?.effectiveSidebarPosition(store.state.settings) == "left")
    try store.dispatch(Command("setSidebarPosition", [.string(first), "right"]))
    #expect(store.state.windows[first]?.sidebarPosition == "right")
    #expect(store.state.windows[second]?.sidebarPosition == "left")
    #expect(store.state.windows[little]?.sidebarPosition == nil)
    #expect(store.state.settings.string("sidebarPosition") == "right")
    let third = try window(store)
    #expect(store.state.windows[third]?.sidebarPosition == nil)
    #expect(store.state.windows[third]?.effectiveSidebarPosition(store.state.settings) == "right")
    try store.dispatch(Command("setSidebarPosition", [.string(third), "left"]))
    #expect(store.state.windows[first]?.effectiveSidebarPosition(store.state.settings) == "right")
    #expect(store.state.windows[second]?.effectiveSidebarPosition(store.state.settings) == "left")
  }

  @Test func settingsChoiceClearsRegularOverridesIncludingMatchingDefault() throws {
    let store = makeStore()
    let first = try window(store)
    let second = try window(store)
    try store.dispatch(Command("setSidebarPosition", [.string(first), "right"]))
    try store.dispatch(Command("setSidebarPosition", [.null, "right"]))
    #expect(store.state.windows[first]?.sidebarPosition == nil)
    #expect(store.state.windows[second]?.sidebarPosition == nil)
    #expect(store.state.windows[second]?.effectiveSidebarPosition(store.state.settings) == "right")
  }

  @Test func invalidValuesAndUnknownWindowsAreRejectedAtomically() throws {
    let store = makeStore()
    let first = try window(store)
    for arguments: [JSONValue] in [[.string(first), "bottom"], [.null, 7], ["missing", "right"], [7, "right"]] {
      let before = store.sessionDocument().json()
      #expect(throws: CommandError.self) { try store.dispatch(Command("setSidebarPosition", arguments)) }
      #expect(store.sessionDocument().json() == before)
    }
  }

  @Test func configWinsOverWindowOverrideAndRetainsOwnChoice() throws {
    let store = makeStore()
    let first = try window(store)
    try store.dispatch(Command("setSidebarPosition", [.string(first), "right"]))
    try store.transact { session in
      session.update { $0.settings = $0.settings.applyingFile(SettingsFileLayer(source: "config.json", values: ["sidebarPosition": "left"])) }
    }
    #expect(store.state.windows[first]?.effectiveSidebarPosition(store.state.settings) == "left")
    try store.dispatch(Command("setSidebarPosition", [.string(first), "right"]))
    #expect(store.state.windows[first]?.effectiveSidebarPosition(store.state.settings) == "left")
    #expect(store.state.settings.own.string("sidebarPosition") == "right")
    try store.transact { session in session.update { $0.settings = $0.settings.applyingFile(nil) } }
    #expect(store.state.windows[first]?.effectiveSidebarPosition(store.state.settings) == "right")
  }

  @Test func sessionAndClosedWindowRetainSideThroughTopTabs() throws {
    let store = makeStore()
    let first = try window(store)
    try store.dispatch(Command("setSidebarPosition", [.string(first), "right"]))
    try store.dispatch(Command("setWindowLayout", [.string(first), "top"]))
    let reloaded = makeStore()
    try reloaded.dispatch(Command("hydrate", [store.sessionDocument().json()]))
    #expect(reloaded.state.windows[first]?.effectiveSidebarPosition(reloaded.state.settings) == "right")
    try reloaded.dispatch(Command("closeWindow", [.string(first)]))
    let archive = try #require(reloaded.state.closedWindows.last)
    #expect(try ClosedWindow(json: archive.json).sidebarPosition == "right")
    let closedReload = makeStore()
    try closedReload.dispatch(Command("hydrate", [reloaded.sessionDocument().json()]))
    try closedReload.dispatch(Command("reopenClosedWindow"))
    let restored = try #require(closedReload.state.windows.values.first)
    #expect(restored.tabLayout == "top")
    try closedReload.dispatch(Command("setWindowLayout", [.string(restored.id), "sidebar"]))
    #expect(closedReload.state.windows[restored.id]?.effectiveSidebarPosition(closedReload.state.settings) == "right")
  }

  @Test func legacySessionDefaultsLeftWithoutAddingAnOverride() throws {
    let store = makeStore()
    let first = try window(store)
    let old = store.state.windows[first]!.json
    let decoded = try BrowserWindow(json: old)
    #expect(decoded.sidebarPosition == nil)
    #expect(decoded.effectiveSidebarPosition(Settings.hydrated(from: nil)) == "left")
    #expect(decoded.json == old)
  }
}

extension SidebarPositionTests {
  @Test func settingsPatchReachesTheSamePolicyAndInvalidPatchesRollBack() throws {
    let store = makeStore()
    let first = try window(store)
    let second = try window(store)
    let command = try Command(json: ["name": "setSidebarPosition", "args": [.string(first), "right"]])
    let commit = try store.dispatch(command)
    #expect(commit.durable)
    try store.dispatch(settingsCommand(["sidebarPosition": "right"]))
    #expect(store.state.windows[first]?.sidebarPosition == nil)
    #expect(store.state.windows[second]?.sidebarPosition == nil)
    let before = store.state.stateJSON
    #expect(throws: CommandError.self) { try store.dispatch(settingsCommand(["sidebarPosition": "top", "appearance": "dark"])) }
    #expect(store.state.stateJSON == before)
  }
}
