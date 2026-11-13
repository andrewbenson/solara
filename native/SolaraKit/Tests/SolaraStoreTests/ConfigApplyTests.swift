import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite(.serialized) struct ConfigApplyTests {
  static let source = "~/.config/solara/config.json"
  static let ocean: JSONValue = ["stops": [["color": ["r": 0.2, "g": 0.4, "b": 1, "a": 1], "x": 0.5, "y": 0.5]], "mode": "auto", "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1]
  static let own: JSONValue = ["stops": [["color": ["r": 1, "g": 0, "b": 0, "a": 1], "x": 0.5, "y": 0.5]], "mode": "light", "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1]

  static func contents(settings: JSONObject = [:], keybindings: JSONObject = [:], theme: JSONValue? = nil) -> ConfigContents {
    var contents = ConfigContents()
    contents.settings = settings
    contents.keybindings = keybindings
    contents.theme = theme.map { ConfigTheme(name: "ocean", look: $0) }
    return contents
  }

  static func store() throws -> Store {
    let store = Store(checksInvariants: true)
    try store.dispatch(Command("applyState", [[
      "profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0, "theme": own]],
      "profileOrder": ["default"],
    ]]), origin: .bridge)
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    return store
  }

  @Test func theFileWinsInStateButNeverInTheSavedSession() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(settings: ["appearance": "dark", "sidebarWidth": 240], theme: Self.ocean), source: Self.source)
    #expect(store.state.settings["appearance"] == "dark")
    #expect(store.state.settings["sidebarWidth"] == 240)
    #expect(store.state.profiles["default"]?.theme == Self.ocean)
    let document = store.sessionDocument()
    #expect(document.settings["appearance"] == "light")
    #expect(document.settings["sidebarWidth"] == 190)
    #expect(document.profiles["default"]?["theme"] == Self.own)
    #expect(store.state.settings.own.chosen?.contains("sidebarWidth") != true)
  }

  @Test func settingsWritesToFileKeysDontChangeWhatShows() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(settings: ["appearance": "dark"]), source: Self.source)
    let commit = try store.dispatch(Command("updateSettings", [["appearance": "auto"]]))
    #expect(store.state.settings["appearance"] == "dark")
    #expect(store.state.settings.ownValues["appearance"] == "auto")
    #expect(commit.changes.settingsChanged.contains("appearance"))
    try store.dispatch(Command("updateSettings", [["sidebarWidth": 300], ["fromSync": true]]))
    #expect(store.state.settings["sidebarWidth"] == 300)
    try store.applyConfig(nil, source: Self.source)
    #expect(store.state.settings["appearance"] == "auto")
    #expect(store.state.settings.fileLayer == nil)
  }

  @Test func profileThemeEditsLandBeneathTheFileTheme() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(theme: Self.ocean), source: Self.source)
    let edited: JSONValue = ["stops": [], "mode": "dark", "intensity": 1, "grain": 0, "texture": "sand", "translucency": 1]
    try store.dispatch(Command("updateProfile", ["default", ["theme": edited]]))
    #expect(store.state.profiles["default"]?.theme == Self.ocean)
    #expect(store.state.profiles["default"]?.ownTheme == edited)
    try store.dispatch(Command("updateProfile", ["default", ["name": "Home"]]))
    #expect(store.state.profiles["default"]?.ownTheme == edited)
    #expect(store.state.profiles["default"]?.name == "Home")
    try store.applyConfig(Self.contents(), source: Self.source)
    #expect(store.state.profiles["default"]?.theme == edited)
    #expect(store.state.profiles["default"]?.fileTheme == nil)
  }

  @Test func theReplicaPatchCarriesOwnValuesAndDropsThemWithTheFile() throws {
    let store = try Self.store()
    func patchOf(_ change: () throws -> Void) rethrows -> JSONValue {
      let before = store.state
      try change()
      return Patch(rev: store.rev, changes: ChangeSet(from: before, to: store.state), state: store.state).json
    }
    let patch = try patchOf { try store.applyConfig(Self.contents(settings: ["appearance": "dark"]), source: Self.source) }
    #expect(patch["settings"]?["set"]?[SettingsFileLayer.replicaKey]?["own"]?["appearance"] == "light")
    #expect(store.state.stateJSON["settings"]?[SettingsFileLayer.replicaKey]?["covered"] == ["appearance"])
    let editPatch = try patchOf { try store.dispatch(Command("updateSettings", [["appearance": "auto"]])) }
    #expect(editPatch["settings"]?["set"]?[SettingsFileLayer.replicaKey]?["own"]?["appearance"] == "auto")
    #expect(editPatch["settings"]?["set"]?["appearance"] == "dark")
    let clearedPatch = try patchOf { try store.applyConfig(nil, source: Self.source) }
    #expect(clearedPatch["settings"]?["remove"]?.array?.contains(.string(SettingsFileLayer.replicaKey)) == true)
    #expect(clearedPatch["settings"]?["set"]?["appearance"] == "auto")
    #expect(store.state.stateJSON["settings"]?[SettingsFileLayer.replicaKey] == nil)
  }

  @Test func aReplicaEchoOfTheFileValueIsNotAnEdit() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(settings: ["appearance": "dark"], theme: Self.ocean), source: Self.source)
    let snapshot = store.state.stateJSON
    try store.dispatch(Command("applyState", [["settings": snapshot["settings"]!, "profiles": snapshot["profiles"]!]]), origin: .bridge)
    #expect(store.state.settings.ownValues["appearance"] == "light")
    #expect(store.state.settings.values[SettingsFileLayer.replicaKey] == nil)
    #expect(store.state.profiles["default"]?.ownTheme == Self.own)
    #expect(store.state.profiles["default"]?.extra[ProfileFileTheme.replicaKey] == nil)
    var settings = snapshot["settings"]!.object!
    settings["appearance"] = "auto"
    try store.dispatch(Command("applyState", [["settings": .object(settings)]]), origin: .bridge)
    #expect(store.state.settings["appearance"] == "dark")
    #expect(store.state.settings.ownValues["appearance"] == "auto")
    #expect(store.sessionDocument().settings["appearance"] == "auto")
  }

  @Test func aStaleReplicaEchoAfterTheFileGoesAwayKeepsTheOwnValues() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(settings: ["appearance": "dark"], theme: Self.ocean), source: Self.source)
    let stale = store.state.stateJSON
    try store.applyConfig(nil, source: Self.source)
    var settings = stale["settings"]!.object!
    settings["showFullUrl"] = true
    try store.dispatch(Command("applyState", [["settings": .object(settings), "profiles": stale["profiles"]!]]), origin: .bridge)
    #expect(store.state.settings["appearance"] == "light")
    #expect(store.state.settings["showFullUrl"] == true)
    #expect(store.state.profiles["default"]?.theme == Self.own)
    #expect(store.sessionDocument().settings["appearance"] == "light")
  }

  @Test func aNewReplicaProfileCarryingAFileThemeKeepsOnlyItsOwnTheme() throws {
    let store = try Self.store()
    let row: JSONValue = [
      "id": "p2", "name": "Work", "color": "blue", "icon": .null, "createdAt": 1, "theme": Self.ocean,
      ProfileFileTheme.replicaKey: ["name": "ocean", "source": .string(Self.source), "own": Self.own],
    ]
    var profiles = store.state.stateJSON["profiles"]!.object!
    profiles["p2"] = row
    try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": ["default", "p2"]]]), origin: .bridge)
    #expect(store.state.profiles["p2"]?.theme == Self.own)
    #expect(store.state.profiles["p2"]?.fileTheme == nil)
    #expect(store.state.profiles["p2"]?.extra[ProfileFileTheme.replicaKey] == nil)
    var bare = row.object!
    bare[ProfileFileTheme.replicaKey] = ["name": "ocean", "source": .string(Self.source)]
    bare["id"] = "p3"
    profiles["p3"] = .object(bare)
    try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": ["default", "p2", "p3"]]]), origin: .bridge)
    #expect(store.state.profiles["p3"]?.theme == nil)
  }

  @Test func anExistingProfileKeepsItsNativeThemeWhenAReplicaRowCarriesAFileTheme() throws {
    let store = try Self.store()
    let native: JSONValue = ["stops": [["color": ["r": 0, "g": 1, "b": 0, "a": 1], "x": 0.5, "y": 0.5]], "mode": "dark", "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1]
    let plain: JSONValue = ["id": "p2", "name": "Work", "color": "blue", "icon": .null, "createdAt": 1, "theme": native]
    var profiles = store.state.stateJSON["profiles"]!.object!
    profiles["p2"] = plain
    try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": ["default", "p2"]]]), origin: .bridge)
    #expect(store.state.profiles["p2"]?.theme == native)
    var row = plain.object!
    row["theme"] = Self.ocean
    row[ProfileFileTheme.replicaKey] = ["name": "ocean", "source": .string(Self.source), "own": Self.own]
    profiles["p2"] = .object(row)
    try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": ["default", "p2"]]]), origin: .bridge)
    #expect(store.state.profiles["p2"]?.theme == native)
    #expect(store.state.profiles["p2"]?.fileTheme == nil)
    #expect(store.state.profiles["p2"]?.extra[ProfileFileTheme.replicaKey] == nil)
  }

  @Test func keybindingsMergePerAction() throws {
    let store = try Self.store()
    try store.dispatch(Command("updateSettings", [["shortcuts": ["closeTab": ["q", "command"]]]]))
    try store.applyConfig(Self.contents(keybindings: ["newTab": ["y", "command"]]), source: Self.source)
    #expect(store.state.settings["shortcuts"] == ["closeTab": ["q", "command"], "newTab": ["y", "command"]])
    try store.dispatch(Command("updateSettings", [["shortcuts": [:], "shortcutPrecedence": [:]]]))
    #expect(store.state.settings["shortcuts"] == ["newTab": ["y", "command"]])
    #expect(store.state.settings.ownValues["shortcuts"] == [:])
  }

  @Test func applyingTheSameConfigTwiceIsANoOp() throws {
    let store = try Self.store()
    let contents = Self.contents(settings: ["appearance": "dark"], theme: Self.ocean)
    #expect(try store.applyConfig(contents, source: Self.source))
    let rev = store.rev
    #expect(try !store.applyConfig(contents, source: Self.source))
    #expect(store.rev == rev)
  }

  @Test func launchApplyHappensBeforeTheStoreExists() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "cfg34-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "themes"), withIntermediateDirectories: true)
    try Data(#"{"settings":{"showFullUrl":true},"theme":"ocean"}"#.utf8).write(to: root.appending(path: "config.json"))
    try Data(##"{"colors":["#3366FF"]}"##.utf8).write(to: root.appending(path: "themes/ocean.json"))
    var state = BrowserState()
    state.profiles["default"] = Profile(id: "default", name: "Personal", color: "plum", icon: nil, createdAt: 0)
    let problems = ConfigProblems()
    let (applied, contents) = ConfigLiveFiles.launch(ConfigLocation(url: root), state: state, problems: problems)
    #expect(contents != nil)
    #expect(applied.settings["showFullUrl"] == true)
    #expect(applied.profiles["default"]?.fileTheme?.name == "ocean")
    #expect(problems.all.isEmpty)
  }

  @Test func liveReloadKeepsTheLastGoodConfigAndRecovers() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "cfg34-live-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "config.json")
    try Data(#"{"settings":{"appearance":"dark"}}"#.utf8).write(to: file)
    let store = try Self.store()
    let problems = ConfigProblems()
    let queue = DispatchQueue(label: "cfg34-live")
    let (_, contents) = ConfigLiveFiles.launch(ConfigLocation(url: root), state: store.state, problems: problems)
    let live = ConfigLiveFiles(location: ConfigLocation(url: root), store: store, contents: contents, problems: problems, debounce: 0.05, queue: queue)
    queue.sync { live.start() }
    defer { queue.sync { live.stop() } }
    try store.applyConfig(contents, source: live.source)
    #expect(store.state.settings["appearance"] == "dark")

    func waitFor(_ condition: () -> Bool) -> Bool {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if queue.sync(execute: condition) { return true }
        Thread.sleep(forTimeInterval: 0.02)
      }
      return false
    }

    try Data(#"{"settings":{"appearance":"light","showFullUrl":true}}"#.utf8).write(to: file)
    #expect(waitFor { store.state.settings["showFullUrl"] == true })
    #expect(store.state.settings["appearance"] == "light")

    try Data(#"{"settings":{"appearance":"purple"}}"#.utf8).write(to: file)
    #expect(waitFor { !problems.all.isEmpty })
    #expect(problems.all.first?.key == "settings.appearance")
    #expect(store.state.settings["appearance"] == "light")
    #expect(store.state.settings["showFullUrl"] == true)

    let temp = root.appending(path: "config.json.tmp")
    try Data(#"{"settings":{"appearance":"dark"}}"#.utf8).write(to: temp)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: temp, to: file)
    #expect(waitFor { problems.all.isEmpty && store.state.settings["appearance"] == "dark" })
    #expect(store.state.settings["showFullUrl"] == false)

    try FileManager.default.removeItem(at: file)
    #expect(waitFor { store.state.settings.fileLayer == nil })
    #expect(store.state.settings["appearance"] == "light")
  }
}
