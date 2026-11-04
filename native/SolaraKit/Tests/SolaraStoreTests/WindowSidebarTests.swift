import SolaraModel
import SolaraStore
import Testing

@Suite struct WindowSidebarTests {
  @Test func changingOneWindowPinsTheOtherAtItsPreviousWidth() throws {
    let store = makeStore()
    try store.dispatch(settingsCommand(["sidebarWidth": 240]))
    let first = try store.dispatch(Command("createWindow", [["url": "https://first.example/"]])).result!.string!
    let second = try store.dispatch(Command("createWindow", [["url": "https://second.example/"]])).result!.string!
    try store.dispatch(Command("setWindowSidebar", [.string(first), ["sidebarWidth": 300]]))
    #expect(store.state.windows[first]?.json["sidebarWidth"] == 300)
    #expect(store.state.windows[second]?.json["sidebarWidth"] == 240)
    #expect(store.state.settings.number("sidebarWidth") == 300)
  }
}

private func sidebarWindow(_ store: Store, small: Bool = false) throws -> String {
  try store.dispatch(Command("createWindow", [["url": "https://window.example/", "small": .bool(small)]])).result!.string!
}

extension WindowSidebarTests {
  @Test func sidebarChangesPreserveExistingOverridesAndSeedNewWindows() throws {
    let store = makeStore()
    let first = try sidebarWindow(store)
    let second = try sidebarWindow(store)
    let little = try sidebarWindow(store, small: true)
    try store.dispatch(Command("setWindowSidebar", [.string(first), ["sidebarWidth": 280, "sidebarIconsOnly": true, "sidePanelWidth": 410]]))
    #expect(store.state.windows[second]?.effectiveSidebarWidth(store.state.settings) == 190)
    #expect(store.state.windows[second]?.effectiveSidebarIconsOnly(store.state.settings) == false)
    #expect(store.state.windows[second]?.effectiveSidePanelWidth(store.state.settings) == 360)
    #expect(store.state.windows[little]?.sidebarWidth == nil)
    #expect(store.state.windows[little]?.sidebarIconsOnly == nil)
    #expect(store.state.windows[little]?.sidePanelWidth == nil)
    let third = try sidebarWindow(store)
    #expect(store.state.windows[third]?.sidebarWidth == nil)
    #expect(store.state.windows[third]?.effectiveSidebarWidth(store.state.settings) == 280)
    #expect(store.state.windows[third]?.effectiveSidebarIconsOnly(store.state.settings) == true)
    #expect(store.state.windows[third]?.effectiveSidePanelWidth(store.state.settings) == 410)
    try store.dispatch(Command("setWindowSidebar", [.string(third), ["sidebarWidth": 320, "sidebarIconsOnly": false, "sidePanelWidth": 450]]))
    #expect(store.state.windows[first]?.effectiveSidebarWidth(store.state.settings) == 280)
    #expect(store.state.windows[first]?.effectiveSidebarIconsOnly(store.state.settings) == true)
    #expect(store.state.windows[first]?.effectiveSidePanelWidth(store.state.settings) == 410)
    #expect(store.state.windows[second]?.effectiveSidebarWidth(store.state.settings) == 190)
    #expect(store.state.windows[second]?.effectiveSidebarIconsOnly(store.state.settings) == false)
    #expect(store.state.windows[second]?.effectiveSidePanelWidth(store.state.settings) == 360)
    #expect(Set(store.state.settings.chosen ?? []).isSuperset(of: ["sidebarWidth", "sidebarIconsOnly", "extensionSidePanelWidth"]))
  }

  @Test func settingsIconsOnlyClearsEveryOverrideEvenWhenTheGlobalAlreadyMatches() throws {
    let store = makeStore()
    let first = try sidebarWindow(store)
    let second = try sidebarWindow(store)
    try store.dispatch(Command("setWindowSidebar", [.string(first), ["sidebarIconsOnly": true]]))
    #expect(store.state.windows[second]?.sidebarIconsOnly == false)
    try store.dispatch(settingsCommand(["sidebarIconsOnly": true]))
    #expect(store.state.windows[first]?.sidebarIconsOnly == nil)
    #expect(store.state.windows[second]?.sidebarIconsOnly == nil)
    #expect(store.state.windows[first]?.effectiveSidebarIconsOnly(store.state.settings) == true)
    #expect(store.state.windows[second]?.effectiveSidebarIconsOnly(store.state.settings) == true)
  }

  @Test(arguments: ["option", "origin", "dispatch", "transaction"])
  func syncSettingsKeepsWindowOverrides(channel: String) throws {
    let store = makeStore()
    let first = try sidebarWindow(store)
    let second = try sidebarWindow(store)
    try store.dispatch(Command("setWindowSidebar", [.string(first), ["sidebarIconsOnly": true]]))
    switch channel {
    case "option": try store.dispatch(settingsCommand(["sidebarIconsOnly": false], fromSync: true))
    case "origin": try store.dispatch(settingsCommand(["sidebarIconsOnly": false]), origin: .sync)
    case "dispatch": try store.dispatch(settingsCommand(["sidebarIconsOnly": false]), fromSync: true)
    default:
      try store.dispatch(Command("beginFromSync"))
      try store.dispatch(settingsCommand(["sidebarIconsOnly": false]))
      try store.dispatch(Command("endFromSync"))
    }
    #expect(store.state.windows[first]?.sidebarIconsOnly == true)
    #expect(store.state.windows[second]?.sidebarIconsOnly == false)
  }

  @Test func anOldWindowRoundTripAndHydrationKeepItsSavedGlobalWidths() throws {
    let store = makeStore()
    let window = try sidebarWindow(store)
    let old = store.state.windows[window]!.json
    let roundTrip = try BrowserWindow(json: old)
    #expect(roundTrip.json == old)
    for key in ["sidebarWidth", "sidebarIconsOnly", "sidePanelWidth"] { #expect(roundTrip.json[key] == nil) }
    var document = store.sessionDocument().json().object!
    document["settings"] = ["sidebarWidth": 247, "sidebarIconsOnly": true, "extensionSidePanelWidth": 397]
    let reloaded = makeStore()
    try reloaded.dispatch(Command("hydrate", [.object(document)]))
    let restored = try #require(reloaded.state.windows[window])
    #expect(restored.effectiveSidebarWidth(reloaded.state.settings) == 247)
    #expect(restored.effectiveSidebarIconsOnly(reloaded.state.settings) == true)
    #expect(restored.effectiveSidePanelWidth(reloaded.state.settings) == 397)
    #expect(restored.json == old)
  }

  @Test func closedWindowsRoundTripAndRestoreTheirWindowPresentation() throws {
    let store = makeStore()
    let window = try sidebarWindow(store)
    try store.dispatch(Command("setWindowLayout", [.string(window), "top"]))
    try store.dispatch(Command("setWindowFullScreen", [.string(window), true]))
    try store.dispatch(Command("setWindowSidebar", [.string(window), ["sidebarWidth": 275, "sidebarIconsOnly": false, "sidePanelWidth": 420]]))
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let archive = try #require(store.state.closedWindows.last)
    let decoded = try ClosedWindow(json: archive.json)
    #expect(decoded.json == archive.json)
    #expect(decoded.tabLayout == "top")
    #expect(decoded.fullScreen == 1_000)
    #expect(decoded.sidebarWidth == 275)
    #expect(decoded.sidebarIconsOnly == false)
    #expect(decoded.sidePanelWidth == 420)
    try store.dispatch(Command("reopenClosedWindow"))
    let restored = try #require(store.state.windows.values.first)
    #expect(restored.tabLayout == decoded.tabLayout)
    #expect(restored.fullScreen == decoded.fullScreen)
    #expect(restored.sidebarWidth == decoded.sidebarWidth)
    #expect(restored.sidebarIconsOnly == decoded.sidebarIconsOnly)
    #expect(restored.sidePanelWidth == decoded.sidePanelWidth)
  }

  @Test func startingFreshArchivesEachWindowWithItsOwnPresentation() throws {
    let store = makeStore()
    let kept = try sidebarWindow(store)
    let resized = try sidebarWindow(store)
    try store.dispatch(Command("setWindowLayout", [.string(kept), "top"]))
    try store.dispatch(Command("setWindowSidebar", [.string(kept), ["sidebarWidth": 240, "sidebarIconsOnly": false, "sidePanelWidth": 390]]))
    try store.dispatch(Command("setWindowSidebar", [.string(resized), ["sidebarWidth": 310, "sidebarIconsOnly": true, "sidePanelWidth": 480]]))
    var document = store.sessionDocument().json().object!
    var settings = document["settings"]?.object ?? [:]
    settings["restoreSession"] = false
    document["settings"] = .object(settings)
    let fresh = makeStore()
    try fresh.transact { _ = $0.loadSession(.object(document), downloads: nil) }
    #expect(fresh.state.windows.isEmpty)
    let archive = try #require(fresh.state.closedWindows.first { $0.sidebarWidth == 240 })
    #expect(archive.tabLayout == "top")
    #expect(archive.sidebarIconsOnly == false)
    #expect(archive.sidePanelWidth == 390)
    try fresh.dispatch(Command("restoreClosed", [.string(archive.id)]))
    let restored = try #require(fresh.state.windows.values.first)
    #expect(restored.effectiveSidebarWidth(fresh.state.settings) == 240)
    #expect(restored.effectiveSidebarIconsOnly(fresh.state.settings) == false)
    #expect(restored.effectiveSidePanelWidth(fresh.state.settings) == 390)
    #expect(restored.tabLayout == "top")
  }

  @Test func oldClosedWindowsDecodeRoundTripAndRestoreWithoutOverrides() throws {
    let store = makeStore()
    let window = try sidebarWindow(store)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let archive = try #require(store.state.closedWindows.last)
    let decoded = try ClosedWindow(json: archive.json)
    #expect(decoded.json == archive.json)
    #expect(decoded.tabLayout == nil)
    #expect(decoded.fullScreen == nil)
    #expect(decoded.sidebarWidth == nil)
    #expect(decoded.sidebarIconsOnly == nil)
    #expect(decoded.sidePanelWidth == nil)
    for key in ["tabLayout", "fullScreen", "sidebarWidth", "sidebarIconsOnly", "sidePanelWidth"] {
      #expect(decoded.json["window"]?[key] == nil)
    }
    try store.dispatch(settingsCommand(["sidebarWidth": 255, "extensionSidePanelWidth": 385]))
    try store.dispatch(Command("reopenClosedWindow"))
    let restored = try #require(store.state.windows.values.first)
    #expect(restored.sidebarWidth == nil)
    #expect(restored.effectiveSidebarWidth(store.state.settings) == 255)
    #expect(restored.effectiveSidePanelWidth(store.state.settings) == 385)
  }
}
