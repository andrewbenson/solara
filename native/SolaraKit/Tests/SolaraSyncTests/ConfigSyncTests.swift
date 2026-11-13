import Foundation
import SolaraModel
import SolaraStore
import SolaraSync
import Testing

@Suite struct ConfigSyncTests {
  static let fileLook: JSONValue = ["stops": [["color": ["r": 0, "g": 0, "b": 1, "a": 1], "x": 0.5, "y": 0.5]], "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1, "mode": "auto"]
  static let ownLook: JSONValue = ["stops": [["color": ["r": 1, "g": 0, "b": 0, "a": 1], "x": 0.5, "y": 0.5]], "intensity": 0.6, "grain": 0, "texture": "grain", "translucency": 1, "mode": "light"]

  static func context() -> ExtractContext {
    ExtractContext(base: { _ in nil }, queued: { _ in false }, now: 1000, known: { _ in false }, remote: { _ in nil }, stamp: { _ in nil })
  }

  static func values(_ extraction: Extraction?) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (key, value) in extraction?.values ?? [] { out[key] = value ?? .null }
    return out
  }

  static func store() throws -> Store {
    let store = Store(checksInvariants: true)
    try store.dispatch(Command("applyState", [[
      "profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0, "theme": ownLook]],
      "profileOrder": ["default"],
    ]]), origin: .bridge)
    try store.dispatch(Command("updateSettings", [["appearance": "light", "showFullUrl": false]]))
    return store
  }

  static func contents() -> ConfigContents {
    var contents = ConfigContents()
    contents.settings = ["appearance": "dark", "showFullUrl": true]
    contents.keybindings = ["newTab": ["y", "command"]]
    contents.theme = ConfigTheme(name: "ocean", look: fileLook)
    return contents
  }

  @Test func theSettingsPayloadCarriesOnlyTheUsersOwnValues() async throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(), source: "config.json")
    #expect(store.state.settings["appearance"] == "dark")
    let values = Self.values(try await SettingsAdapter(store: store).extract(Self.context()))
    #expect(values["set:appearance"]?["v"] == "light")
    #expect(values["set:showFullUrl"]?["v"] == false)
    #expect(values["set:shortcuts"]?["v"]?["newTab"] == nil)
  }

  @Test func theThemePayloadCarriesTheProfilesOwnTheme() async throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(), source: "config.json")
    #expect(store.state.profiles["default"]?.theme == Self.fileLook)
    let links: JSMap<JSONValue> = ["default": ["syncId": "s1"]]
    let adapter = ProfileThemesAdapter(store: store, links: { links }, records: { nil })
    let values = Self.values(try await adapter.extract(Self.context()))
    let published = values["pth:s1"]?["t"]?["stops"]?.array?.first?["color"]?["r"]
    #expect(published == 1)
  }

  @Test func syncArrivalsUnderTheFileComeBackWhenTheKeyLeaves() throws {
    let store = try Self.store()
    try store.applyConfig(Self.contents(), source: "config.json")
    try store.dispatch(Command("updateSettings", [["appearance": "auto"], ["fromSync": true]]), origin: .sync)
    try store.dispatch(Command("updateProfile", ["default", ["theme": ["stops": [], "mode": "dark", "intensity": 1, "grain": 0, "texture": "sand", "translucency": 1]]]), origin: .sync)
    #expect(store.state.settings["appearance"] == "dark")
    #expect(store.state.profiles["default"]?.theme == Self.fileLook)
    try store.applyConfig(nil, source: "config.json")
    #expect(store.state.settings["appearance"] == "auto")
    #expect(store.state.settings["showFullUrl"] == false)
    #expect(store.state.profiles["default"]?.theme?["texture"] == "sand")
  }
}
