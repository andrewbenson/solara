import SolaraModel
import SolaraStore
import SolaraSync
import Testing

@Suite struct ProfileIconSyncTests {
  func context() -> ExtractContext {
    ExtractContext(base: { _ in nil }, queued: { _ in false }, now: 1000, known: { _ in true }, remote: { _ in nil }, stamp: { _ in nil })
  }

  func store() throws -> Store {
    let store = Store(checksInvariants: true)
    try store.dispatch(Command("hydrate", [[
      "profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0]],
      "profileOrder": ["default"],
    ]]))
    return store
  }

  @Test(arguments: ["symbol:briefcase.fill", "🍌", "symbol:future.symbol.fill"])
  func iconAndClearRoundTripThroughNativeAdapters(_ icon: String) async throws {
    let source = try store()
    let destination = try store()
    let links: JSMap<JSONValue> = ["default": ["syncId": "personal"]]
    let publisher = ProfilesAdapter(store: source, links: { links })
    let receiver = ProfilesAdapter(store: destination, links: { links })
    let records = ApplyRecords(known: { _ in true }, now: 0, horizon: 0, joined: true)
    for value in [JSONValue.string(icon), .null] {
      try source.dispatch(Command("updateProfile", ["default", ["icon": value]]))
      let extracted = try #require(try await publisher.extract(context()))
      let record = try #require(extracted.values.first?.value)
      #expect(record["i"] == value)
      _ = try await receiver.apply([("prof:personal", record)], ["prof:personal"], { _ in nil }, records)
      #expect(destination.state.profiles["default"]?.json["icon"] == value)
    }
  }

  @Test func absentLegacyIconPreservesLocalChoiceAndUnknownFieldsAreIgnored() async throws {
    let store = try store()
    try store.dispatch(Command("updateProfile", ["default", ["icon": "symbol:star.fill"]]))
    let links: JSMap<JSONValue> = ["default": ["syncId": "personal"]]
    let adapter = ProfilesAdapter(store: store, links: { links })
    let records = ApplyRecords(known: { _ in true }, now: 0, horizon: 0, joined: true)
    _ = try await adapter.apply([("prof:personal", ["n": "Renamed", "c": "blue", "future": "ignored"])], ["prof:personal"], { _ in nil }, records)
    #expect(store.state.profiles["default"]?.name == "Renamed")
    #expect(store.state.profiles["default"]?.icon == "symbol:star.fill")
    #expect(store.state.profiles["default"]?.extra["future"] == nil)
  }
}
