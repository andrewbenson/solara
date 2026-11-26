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

  private func opening(_ s: Store, focused: @escaping (String) -> Void = { _ in }) -> SettingsOpening {
    SettingsOpening(state: { s.state }, run: { try? s.dispatch($0).result }, focus: focused)
  }

  private func urls(_ s: Store, _ window: String) -> [String] {
    s.state.viewTabIds(window).compactMap { s.state.tabs[$0]?.url }
  }

  @Test func openURLsAddsTabsToTheResolvedWindow() throws {
    let s = store()
    let window = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let count = urls(s, window).count
    opening(s).openURLs(["https://a.test/", "https://b.test/"])
    #expect(urls(s, window).count == count + 2)
    #expect(Set(urls(s, window)).isSuperset(of: ["https://a.test/", "https://b.test/"]))
    #expect(s.state.windowOrder.count == 1)
  }

  @Test func openURLsOpensOneWindowWhenOnlyAPrivateWindowExists() throws {
    let s = store()
    _ = try s.dispatch(Command("createWindow", [["incognito": true]]))
    opening(s).openURLs(["https://a.test/", "https://b.test/"])
    #expect(s.state.windowOrder.count == 2)
    let opened = s.state.windowOrder.first { s.state.windows[$0]?.incognito != true }!
    #expect(Set(urls(s, opened)).isSuperset(of: ["https://a.test/", "https://b.test/"]))
  }

  @Test func openURLsWithNoWindowCreatesOne() {
    let s = store()
    opening(s).openURLs(["https://a.test/"])
    #expect(s.state.windowOrder.count == 1)
    #expect(urls(s, s.state.windowOrder[0]).contains("https://a.test/"))
  }

  @Test func openInBrowserSkipsPrivateWindowsAndFocuses() throws {
    let s = store()
    let regular = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let secret = try s.dispatch(Command("createWindow", [["incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(secret)]))
    var focused: [String] = []
    opening(s) { focused.append($0) }.openInBrowser("https://live.test/")
    #expect(urls(s, regular).contains("https://live.test/"))
    #expect(!urls(s, secret).contains("https://live.test/"))
    #expect(focused == [regular])
  }

  @Test func openInBrowserWithOnlyPrivateWindowsDoesNothing() throws {
    let s = store()
    _ = try s.dispatch(Command("createWindow", [["incognito": true]]))
    var focused: [String] = []
    let tabs = s.state.tabs.values.count
    opening(s) { focused.append($0) }.openInBrowser("https://live.test/")
    #expect(s.state.tabs.values.count == tabs)
    #expect(focused.isEmpty)
  }

  private func recording(_ s: Store, _ calls: Box) -> SettingsOpening {
    SettingsOpening(
      state: { s.state },
      run: { command in
        calls.items.append(command.name)
        return try? s.dispatch(command).result
      },
      focus: { calls.items.append("focus:" + $0) })
  }

  final class Box: @unchecked Sendable { var items: [String] = [] }

  @Test func internalPageReusesAnOpenPageAndFocusesFirst() throws {
    let s = store()
    let window = try s.dispatch(Command("createWindow", [["url": "https://site.test/"]])).result!.string!
    let history = try s.dispatch(Command("newTab", [.string(window), ["url": "Solara://History?q=x"]])).result!.string!
    _ = try s.dispatch(Command("newTab", [.string(window), ["url": "https://other.test/"]]))
    let calls = Box()
    recording(s, calls).openInternalPage("history", scheme: "solara", isAppScheme: { $0.lowercased() == "solara" })
    #expect(s.state.activeTabId(window) == history)
    #expect(calls.items == ["setFocusedWindow", "focus:" + window, "activate"])
    #expect(s.state.ui.focusedWindowId == window)
  }

  @Test func internalPageOpensANewTabOrFillsABlankOne() throws {
    let s = store()
    let window = try s.dispatch(Command("createWindow", [["url": "https://site.test/"]])).result!.string!
    let count = s.state.viewTabIds(window).count
    let calls = Box()
    recording(s, calls).openInternalPage("bookmarks", scheme: "solara", isAppScheme: { $0 == "solara" })
    #expect(s.state.viewTabIds(window).count == count + 1)
    #expect(s.state.activeTab(window)?.url == "solara://bookmarks")
    #expect(calls.items == ["setFocusedWindow", "focus:" + window, "newTab"])

    let blank = store()
    let empty = try blank.dispatch(Command("createWindow", [[:]])).result!.string!
    let active = blank.state.activeTabId(empty)!
    #expect(blank.state.tabs[active]?.url == "")
    let tabs = blank.state.viewTabIds(empty).count
    let blankCalls = Box()
    recording(blank, blankCalls).openInternalPage("bookmarks", scheme: "solara", isAppScheme: { $0 == "solara" })
    #expect(blank.state.viewTabIds(empty).count == tabs)
    #expect(blank.state.activeTabId(empty) == active)
    #expect(blank.state.tabs[active]?.navigation?.url ?? blank.state.tabs[active]?.url == "solara://bookmarks")
    #expect(blankCalls.items == ["setFocusedWindow", "focus:" + empty, "navigate"])
  }

  @Test func openURLsPrefersFocusOrderAndSkipsSmallWindows() throws {
    let s = store()
    let first = try s.dispatch(Command("createWindow", [["url": "https://one.test/"]])).result!.string!
    let second = try s.dispatch(Command("createWindow", [["url": "https://two.test/"]])).result!.string!
    let small = try s.dispatch(Command("createWindow", [["url": "https://small.test/", "small": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(second)]))
    try s.dispatch(Command("setFocusedWindow", [.string(small)]))
    #expect(s.state.windowOrder.first == first)
    #expect(Array(s.state.ui.focusOrder.prefix(2)) == [small, second])
    let before = (urls(s, first).count, urls(s, second).count, urls(s, small).count)
    let calls = Box()
    recording(s, calls).openURLs(["https://a.test/"])
    #expect(urls(s, first).count == before.0)
    #expect(urls(s, second).count == before.1 + 1)
    #expect(urls(s, small).count == before.2)
    #expect(calls.items == ["newTab"])
  }

  @Test func openInBrowserPrefersFocusOrderOverWindowOrder() throws {
    let s = store()
    let first = try s.dispatch(Command("createWindow", [["url": "https://one.test/"]])).result!.string!
    let second = try s.dispatch(Command("createWindow", [["url": "https://two.test/"]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(first)]))
    try s.dispatch(Command("setFocusedWindow", [.string(second)]))
    #expect(s.state.windowOrder.first == first)
    #expect(s.state.ui.focusOrder.first == second)
    let calls = Box()
    recording(s, calls).openInBrowser("https://live.test/")
    #expect(urls(s, second).contains("https://live.test/"))
    #expect(!urls(s, first).contains("https://live.test/"))
    #expect(calls.items == ["newTab", "focus:" + second])
  }

  @Test func internalPageMatchesTheJSPattern() {
    let app = { (scheme: String) in scheme.lowercased() == "solara" }
    #expect(SettingsOpening.internalPage(of: "solara://history", isAppScheme: app) == "history")
    #expect(SettingsOpening.internalPage(of: "SOLARA://Downloads/x?q=1", isAppScheme: app) == "downloads")
    #expect(SettingsOpening.internalPage(of: "solara://settings", isAppScheme: app) == nil)
    #expect(SettingsOpening.internalPage(of: "https://history", isAppScheme: app) == nil)
    #expect(SettingsOpening.internalPage(of: "x:solara://history", isAppScheme: app) == nil)
    #expect(SettingsOpening.internalPage(of: "", isAppScheme: app) == nil)
  }

  @Test func extensionsProfileFollowsTheJSFallbacks() throws {
    let s = store()
    let work = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    #expect(opening(s).extensionsProfile(engine: work) == work)
    #expect(opening(s).extensionsProfile(engine: "") == Settings.defaultProfileID)
    let window = try s.dispatch(Command("createWindow", [["profileId": .string(work), "incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(window)]))
    #expect(opening(s).extensionsProfile(engine: "missing") == work)
  }

  @Test func extensionsProfileUsesProfileOrderForSharedEngineData() throws {
    let s = store()
    let owner = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    let shared = try s.dispatch(SettingsWrites.createProfile(name: "Shared", color: "blue", shareWith: owner)).result!.string!
    let engine = s.state.engineProfile(owner)
    #expect(s.state.engineProfile(shared) == engine)
    #expect(SettingsOpening.extensionsProfile(engine: engine, in: s.state) == owner)
    try s.dispatch(SettingsWrites.reorderProfiles([shared, owner, Settings.defaultProfileID]))
    #expect(SettingsOpening.extensionsProfile(engine: engine, in: s.state) == shared)
  }

  @Test func extensionsProfileReadsCurrentNativeWindowState() throws {
    let s = store()
    let work = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    let resolver = opening(s)
    #expect(resolver.extensionsProfile(engine: "missing") == Settings.defaultProfileID)
    let window = try s.dispatch(Command("createWindow", [["profileId": .string(work), "incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(window)]))
    #expect(resolver.extensionsProfile(engine: "missing") == work)
    #expect(SettingsOpening.extensionsProfile(engine: "missing", in: s.state) == work)
  }

  @Test func extensionsProfileWithNoWindowsAndAnUnknownEngineFallsBackToTheDefaultProfile() throws {
    let s = store()
    let work = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
    try s.dispatch(Command("setDefaultProfile", [.string(work)]))
    #expect(s.state.windowOrder.isEmpty)
    #expect(s.state.settings.defaultProfileId == work)
    #expect(opening(s).extensionsProfile(engine: "missing") == work)
  }
}
