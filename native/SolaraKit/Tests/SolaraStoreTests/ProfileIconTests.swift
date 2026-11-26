import SolaraModel
import SolaraStore
import Testing

@Suite struct ProfileIconTests {
  @Test(arguments: ["symbol:briefcase.fill", "🍌", "symbol:future.symbol.fill"])
  func iconSurvivesCreationSessionHydrationAndClear(_ icon: String) throws {
    let store = makeStore()
    let id = try #require(try store.dispatch(Command("createProfile", [["name": "Work", "icon": .string(icon)]])).result?.string)
    #expect(store.state.profiles[id]?.icon == icon)
    let reloaded = makeStore()
    try reloaded.dispatch(Command("hydrate", [store.sessionDocument().json()]))
    #expect(reloaded.state.profiles[id]?.icon == icon)
    let rename = try #require(ProfileThemeEdit.command(profileId: id, fields: ["name": "Office"], state: reloaded.state))
    try reloaded.dispatch(rename, origin: .native)
    #expect(reloaded.state.profiles[id]?.name == "Office")
    #expect(reloaded.state.profiles[id]?.icon == icon)
    let clear = try #require(ProfileThemeEdit.command(profileId: id, fields: ["icon": .null], state: reloaded.state))
    try reloaded.dispatch(clear, origin: .native)
    let cleared = makeStore()
    try cleared.dispatch(Command("hydrate", [reloaded.sessionDocument().json()]))
    #expect(cleared.state.profiles[id]?.icon == nil)
    #expect(cleared.state.profiles[id]?.json["icon"] == .null)
  }

  @Test func profileModelPreservesMissingNullAndUnknownValues() throws {
    var json: JSONObject = ["id": "default", "name": "Personal", "color": "plum", "createdAt": 0, "future": "kept"]
    let missing = try Profile(json: json)
    #expect(missing.icon == nil)
    #expect(missing.json["icon"] == nil)
    json["icon"] = .null
    let cleared = try Profile(json: json)
    #expect(cleared.json["icon"] == .null)
    json["icon"] = "symbol:future.symbol.fill"
    let future = try Profile(json: json)
    #expect(future.icon == "symbol:future.symbol.fill")
    #expect(future.json["future"] == "kept")
  }
}
