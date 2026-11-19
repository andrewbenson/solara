import Foundation
import SolaraModel
import Testing

@testable import SolaraStore

@Suite(.serialized) struct SettingsWritesTests {
  private func store() -> Store {
    Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "writes")), checksInvariants: true, clock: { 1_000 })
  }

  private func bridged(_ text: String) throws -> Command {
    try Command(json: JSONValue.parse(text))
  }

  @Test func createProfileMatchesTheBridgeCommand() throws {
    let bridge = try bridged(#"{"name":"createProfile","args":[{"name":"Work","color":"blue","shareWith":null}]}"#)
    #expect(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil) == bridge)
    let shared = try bridged(#"{"name":"createProfile","args":[{"name":"Work","color":"blue","shareWith":"default"}]}"#)
    #expect(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: "default") == shared)
  }

  @Test func createdProfileIsTheSameEitherWay() throws {
    let direct = store()
    let bridge = store()
    let a = try direct.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: Settings.defaultProfileID), origin: .native)
    let b = try bridge.dispatch(bridged(#"{"name":"createProfile","args":[{"name":"Work","color":"blue","shareWith":"default"}]}"#), origin: .bridge)
    #expect(a.result == b.result)
    #expect(direct.state.profiles.map.keys == bridge.state.profiles.map.keys)
    #expect(direct.state.profiles.values == bridge.state.profiles.values)
    #expect(direct.state.profileOrder == bridge.state.profileOrder)
  }

  @Test func updateProfileMatchesTheBridgeCommand() throws {
    let patch = JSONObject([("name", .string("Home")), ("icon", .null), ("theme", .null)])
    let bridge = try bridged(#"{"name":"updateProfile","args":["p1",{"name":"Home","icon":null,"theme":null}]}"#)
    #expect(SettingsWrites.updateProfile("p1", patch) == bridge)
  }

  @Test func updateProfileClearsIconWithNull() throws {
    let s = store()
    let id = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    try s.dispatch(SettingsWrites.updateProfile(id, JSONObject([("icon", .string("star"))])))
    #expect(s.state.profiles[id]?.icon == "star")
    try s.dispatch(SettingsWrites.updateProfile(id, JSONObject([("icon", .null)])))
    #expect(s.state.profiles[id]?.icon == nil)
  }

  @Test func reorderAndDeleteMatchTheBridgeCommands() throws {
    #expect(SettingsWrites.reorderProfiles(["b", "a"]) == (try bridged(#"{"name":"reorderProfiles","args":[["b","a"]]}"#)))
    #expect(SettingsWrites.deleteProfile("a") == (try bridged(#"{"name":"deleteProfile","args":["a"]}"#)))
  }

  @Test func deletingAMissingProfileChangesNothingEitherWay() throws {
    let direct = store()
    let bridge = store()
    let a = try direct.dispatch(SettingsWrites.deleteProfile("missing"), origin: .native)
    let b = try bridge.dispatch(bridged(#"{"name":"deleteProfile","args":["missing"]}"#), origin: .bridge)
    #expect(a.changes.isEmpty && b.changes.isEmpty)
    #expect(direct.state.profileOrder == [Settings.defaultProfileID])
  }

  @Test func deletedProfileIsTheSameEitherWay() throws {
    let direct = store()
    let bridge = store()
    let a = try direct.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    let b = try bridge.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    let x = try direct.dispatch(SettingsWrites.deleteProfile(a), origin: .native)
    let y = try bridge.dispatch(bridged("{\"name\":\"deleteProfile\",\"args\":[\"\(b)\"]}"), origin: .bridge)
    #expect(x.effects == y.effects)
    #expect(direct.state.profileOrder == bridge.state.profileOrder)
    #expect(direct.state.orphanedProfileData == bridge.state.orphanedProfileData)
  }

  @Test func chooseTabLayoutTogglesWindowsThatDifferFromTheOldChoice() throws {
    let s = store()
    let plain = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let top = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    try s.dispatch(Command("setWindowLayout", [.string(top), "top"]))
    let commands = SettingsWrites.chooseTabLayout("top", in: s.state)
    let choose = try bridged(#"{"name":"updateSettings","args":[{"tabLayout":"top"}]}"#)
    #expect(commands == [choose, Command("toggleTabLayout", [.string(plain)]), choose])
    for command in commands { try s.dispatch(command) }
    #expect(s.state.settings.string("tabLayout") == "top")
    #expect(s.state.windows[top]?.tabLayout == "top")
    #expect(s.state.windows[plain]?.tabLayout == "sidebar")
  }

  @Test func chooseTabLayoutBackToSidebarTogglesOverriddenWindows() throws {
    let s = store()
    let plain = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let top = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    try s.dispatch(Command("setWindowLayout", [.string(top), "top"]))
    let commands = SettingsWrites.chooseTabLayout("sidebar", in: s.state)
    let choose = try bridged(#"{"name":"updateSettings","args":[{"tabLayout":"sidebar"}]}"#)
    #expect(commands == [choose, Command("toggleTabLayout", [.string(top)]), choose])
    for command in commands { try s.dispatch(command) }
    #expect(s.state.settings.string("tabLayout") == "sidebar")
    #expect(s.state.windows[top]?.tabLayout == "sidebar")
    #expect(s.state.windows[plain]?.tabLayout == nil)
  }

  @MainActor @Test func directStoreFollowsOwnershipSafeModeAndFreeze() {
    let previousOwns = NativeStoreHandle.ownsWorkspace
    let previousResolve = NativeStoreHandle.resolve
    defer {
      NativeStoreHandle.ownsWorkspace = previousOwns
      NativeStoreHandle.resolve = previousResolve
      NativeStoreHandle.thawForTests()
    }
    let owned = store()
    var safeConfig = StoreConfig()
    safeConfig.safeMode = true
    let safe = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), config: safeConfig)
    NativeStoreHandle.thawForTests()
    NativeStoreHandle.resolve = { owned }
    NativeStoreHandle.ownsWorkspace = false
    #expect(SettingsWrites.directStore == nil)
    NativeStoreHandle.ownsWorkspace = true
    #expect(SettingsWrites.directStore === owned)
    NativeStoreHandle.resolve = { nil }
    #expect(SettingsWrites.directStore == nil)
    NativeStoreHandle.resolve = { safe }
    #expect(SettingsWrites.directStore == nil)
    NativeStoreHandle.resolve = { owned }
    NativeStoreHandle.markFrozen()
    #expect(SettingsWrites.directStore == nil)
  }
}
