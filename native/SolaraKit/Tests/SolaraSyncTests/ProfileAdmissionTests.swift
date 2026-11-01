import SolaraModel
import SolaraStore
@testable import SolaraSync
import Testing

private final class ProfileAdmissionStore: SyncStore {
  var state = BrowserState()
  var commands: [Command] = []
  var refusing: String?

  func run(_ command: Command) throws {
    if command.args.first?.string == refusing { throw CommandError("Profile update refused") }
    commands.append(command)
  }
}

struct ProfileAdmissionTests {
  @Test(arguments: [false, true]) func refusedProfileKeysLeaveLaterKeysSettled(_ writtenKeysOnly: Bool) async {
    let store = ProfileAdmissionStore()
    let invalid = Profile(id: "Saved-MixedCase", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    let valid = Profile(id: "p-launch-1", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    store.state.profiles[invalid.id] = invalid
    store.state.profiles[valid.id] = valid
    let links: JSMap<JSONValue> = [invalid.id: ["syncId": "invalid"], valid.id: ["syncId": "valid"]]
    let adapter = ProfilesAdapter(store: store, links: { links })
    let state = ScopeState()
    state.joined = true
    for key in ["prof:invalid", "prof:valid"] {
      state.records[key] = SyncRecord(h: "1", v: ["n": "Remote", "c": "green", "i": .null], o: Origin("remote", 1))
      state.base[key] = syncCanonical(["n": "Saved", "c": "blue", "i": .null])
    }
    let previous = state.base["prof:invalid"]
    let left = await applyAdapter(state, adapter, OrderedSet(["prof:invalid", "prof:valid"]), 0, 0, writtenKeysOnly, nil)
    #expect(left == ["prof:invalid"])
    #expect(state.base["prof:invalid"] == previous)
    #expect(state.base["prof:valid"] == syncCanonical(state.records["prof:valid"]!.v))
    #expect(store.commands.map { $0.args[0].string } == [valid.id])
  }

  @Test(arguments: [false, true]) func refusedThemeKeysKeepTheirAnglesAndAdoptionPending(_ writtenKeysOnly: Bool) async {
    let store = ProfileAdmissionStore()
    let invalid = Profile(id: "p-launch-1", name: "Saved", color: "blue", icon: nil, createdAt: 0, dataId: "Saved-Data", theme: .null)
    let valid = Profile(id: "p-launch-2", name: "Saved", color: "blue", icon: nil, createdAt: 0, theme: .null)
    store.state.profiles[invalid.id] = invalid
    store.state.profiles[valid.id] = valid
    let links: JSMap<JSONValue> = [invalid.id: ["syncId": "invalid"], valid.id: ["syncId": "valid"]]
    var adopted: [String] = []
    let adapter = ProfileThemesAdapter(store: store, links: { links }, records: { nil }, adopted: { adopted.append($0) })
    let state = ScopeState()
    state.joined = true
    let keys = ["pth:invalid", "pth:invalid:angle", "pth:valid", "pth:valid:angle"]
    for key in keys {
      let value: JSONValue = key.jsEndsWith(":angle") ? ["a": 42] : ["preset": true]
      state.records[key] = SyncRecord(h: "1", v: value, o: Origin("remote", 1))
      state.base[key] = syncCanonical(.null)
    }
    let left = await applyAdapter(state, adapter, OrderedSet(keys), 0, 0, writtenKeysOnly, nil)
    #expect(left == ["pth:invalid", "pth:invalid:angle"])
    for key in left { #expect(state.base[key] == syncCanonical(.null)) }
    for key in ["pth:valid", "pth:valid:angle"] { #expect(state.base[key] == syncCanonical(state.records[key]!.v)) }
    #expect(store.commands.map { $0.args[0].string } == [valid.id])
    #expect(adopted == [valid.id])
  }

  @Test func runtimeRefusalOfOneProfileStillAppliesTheNext() async throws {
    let store = ProfileAdmissionStore()
    store.refusing = "p-launch-1"
    var links = JSMap<JSONValue>()
    for id in ["p-launch-1", "p-launch-2"] {
      store.state.profiles[id] = Profile(id: id, name: "Saved", color: "blue", icon: nil, createdAt: 0)
      links[id] = ["syncId": .string(id)]
    }
    let all = links
    let adapter = ProfilesAdapter(store: store, links: { all })
    let changed = ["prof:p-launch-1", "prof:p-launch-2"]
    let visible: [(key: String, value: JSONValue)] = changed.map { ($0, ["n": "Remote", "c": "green", "i": .null]) }
    do {
      _ = try await adapter.apply(visible, changed, { _ in nil }, ApplyRecords(known: { _ in true }, now: 0, horizon: 0, joined: true))
      Issue.record("Expected a per-key refusal")
    } catch let error as ApplyRefusal {
      #expect(error.refused == [changed[0]])
    }
    #expect(store.commands.map { $0.args[0].string } == ["p-launch-2"])
  }

  @Test(arguments: [false, true]) func pendingLegacyThemeSurvivesMetadataExtraction(_ adopting: Bool) async throws {
    let store = ProfileAdmissionStore()
    let id = "Saved-MixedCase"
    store.state.profiles[id] = Profile(id: id, name: "Renamed", color: "blue", icon: nil, createdAt: 0, theme: .null)
    let links: JSMap<JSONValue> = [id: ["syncId": "remote", "themeAdopting": .bool(adopting)]]
    let remote: JSONValue = ["n": "Remote", "c": "green", "th": ["unapplied": "theme"]]
    let adapter = ProfilesAdapter(store: store, links: { links })
    let result = try await adapter.extract(ExtractContext(
      base: { _ in nil }, queued: { _ in false }, now: 0, known: { _ in true }, remote: { _ in remote }, stamp: { _ in nil }, unapplied: { _ in !adopting }))
    #expect(result?.values.first?.value?["th"] == remote["th"])
    #expect(result?.values.first?.value?["n"] == "Renamed")
    #expect(store.state.profiles[id]?.theme == .null)
  }
}
