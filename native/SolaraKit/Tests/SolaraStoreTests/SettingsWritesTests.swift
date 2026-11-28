import Foundation
import SolaraModel
import Testing

@testable import SolaraStore

@Suite(.serialized) struct SettingsWritesTests {
  private func store() -> Store {
    Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "writes")), checksInvariants: true, clock: { 1_000 })
  }

  @Test func settingsAliasLeavesTheSourceTabAndWindowIntact() throws {
    let s = store()
    let window = try #require(s.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(s.state.activeTabId(window))
    let before = s.state.tabs[tab]
    let routed = try s.dispatch(Command("navigate", [.string(tab), "chrome://settings/manageProfile"]), origin: .native)
    #expect(s.state.tabs[tab] == before)
    #expect(routed.effects.map(\.json).contains(["type": "openSettings", "pane": "profiles"]))
  }

  @Test func newTabAliasOpensABlankTabInTheSourceWindow() throws {
    let s = store()
    let window = try #require(s.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(s.state.activeTabId(window))
    try s.dispatch(Command("navigate", [.string(tab), "about:newtab"]), origin: .native)
    let opened = try #require(s.state.activeTabId(window))
    #expect(opened != tab)
    #expect(s.state.tabs[opened]?.url == "")
    #expect(s.state.tabs[opened]?.navigation == nil)
  }

  @Test func unrecognizedSettingsAndRestoredSettingsKeepTheirWebDestination() throws {
    let s = store()
    let window = try #require(s.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(s.state.activeTabId(window))
    try s.dispatch(Command("navigate", [.string(tab), "solara://settings/content"]), origin: .native)
    #expect(s.state.tabs[tab]?.navigation?.url == "solara://settings/content")
    let restored = try s.dispatch(Command("newTab", [.string(window), ["url": "solara://settings/sync", "snapshot": ["title": "Settings"]]]))
    #expect(s.state.tabs[restored.result?.string ?? ""]?.url == "solara://settings/sync")
  }

  @Test func internalNavigationCommitsTheTitleAndQueryWithoutAnEngineLoad() throws {
    let s = store()
    let window = try #require(s.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(s.state.activeTabId(window))
    try s.dispatch(Command("updateTab", [.string(tab), ["url": "https://example.org", "title": "Example", "favicon": "icon"]]))
    let url = "solara://history?q=a%2Bb%20c"
    let routed = try s.dispatch(Command("navigate", [.string(tab), .string(url)]), origin: .native)
    #expect(s.state.tabs[tab]?.url == url)
    #expect(s.state.tabs[tab]?.title == "History")
    #expect(s.state.tabs[tab]?.favicon == nil)
    #expect(s.state.tabs[tab].flatMap(InternalPageDestination.init(tab:))?.query == "a+b c")
    #expect(!routed.effects.contains { if case .startNavigation = $0 { return true }; return false })
  }

  @Test func restoredInternalAliasKeepsItsQueryAndNativeTitle() throws {
    let s = store()
    let window = try #require(s.dispatch(Command("createWindow")).result?.string)
    let restored = try s.dispatch(Command("newTab", [.string(window), [
      "url": "chrome://history?q=%bogus", "snapshot": ["title": "Stored title"],
    ]]))
    let id = try #require(restored.result?.string)
    let tab = try #require(s.state.tabs[id])
    #expect(tab.url == "solara://history?q=%bogus")
    #expect(tab.navigation?.url == tab.url)
    #expect(tab.title == "History")
    #expect(InternalPageDestination(tab: tab)?.query == "%bogus")
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

  @MainActor private func withLayoutStore(_ store: Store, run: () throws -> Void) rethrows {
    let previousOwns = NativeStoreHandle.ownsWorkspace
    let previousResolve = NativeStoreHandle.resolve
    defer {
      NativeStoreHandle.ownsWorkspace = previousOwns
      NativeStoreHandle.resolve = previousResolve
    }
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = true
    try run()
  }

  @MainActor @Test func choosingTopPreservesInheritedAndExplicitLayouts() throws {
    let s = store()
    let inherited = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    let explicitTop = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    let privateWindow = try #require(try s.dispatch(Command("createWindow", [["incognito": true]])).result?.string)
    let little = try #require(try s.dispatch(Command("createWindow", [["small": true, "url": "https://example.test"]])).result?.string)
    let explicitSidebar = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    let lastInherited = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    try s.dispatch(Command("setWindowLayout", [.string(explicitTop), "top"]))
    try s.dispatch(Command("setWindowLayout", [.string(explicitSidebar), "sidebar"]))

    try withLayoutStore(s) {
      let choseTop = try SettingsWrites.chooseTabLayout("top")
      #expect(choseTop)
    }

    #expect(s.state.settings.string("tabLayout") == "top")
    #expect(s.state.windows[inherited]?.tabLayout == nil)
    #expect(s.state.windows[explicitTop]?.tabLayout == "top")
    #expect(s.state.windows[privateWindow]?.incognito == true)
    #expect(s.state.windows[privateWindow]?.tabLayout == nil)
    #expect(s.state.windows[little]?.isSmall == true)
    #expect(s.state.windows[little]?.tabLayout == nil)
    #expect(s.state.windows[explicitSidebar]?.tabLayout == "sidebar")
    #expect(s.state.windows[lastInherited]?.tabLayout == nil)
  }

  @MainActor @Test func choosingTheCurrentDefaultPreservesDifferingOverrides() throws {
    let s = store()
    let inherited = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    let top = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    try s.dispatch(Command("setWindowLayout", [.string(top), "top"]))

    try withLayoutStore(s) {
      let choseSidebar = try SettingsWrites.chooseTabLayout("sidebar")
      #expect(choseSidebar)
    }

    #expect(s.state.settings.string("tabLayout") == "sidebar")
    #expect(s.state.windows[top]?.tabLayout == "top")
    #expect(s.state.windows[inherited]?.tabLayout == nil)
  }

  @MainActor @Test func sixWindowsKeepFollowingTheirOwnOrGlobalLayoutAcrossChoices() throws {
    let s = store()
    let ids = try (0..<6).map { _ in
      try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    }
    try s.dispatch(Command("setWindowLayout", [.string(ids[1]), "top"]))
    try s.dispatch(Command("setWindowLayout", [.string(ids[4]), "sidebar"]))
    let overrides: [String?] = [nil, "top", nil, nil, "sidebar", nil]

    try withLayoutStore(s) {
      for layout in ["top", "sidebar"] {
        let choseLayout = try SettingsWrites.chooseTabLayout(layout)
        #expect(choseLayout)
        let state = s.state
        #expect(state.settings.string("tabLayout") == layout)
        #expect(ids.map { state.windows[$0]?.tabLayout } == overrides)
        #expect(ids.map { state.windows[$0]?.tabLayout ?? state.settings.string("tabLayout") } ==
                [layout, "top", layout, layout, "sidebar", layout])
      }
    }
  }

  @MainActor @Test func aFileOwnedLayoutRefusesTheSettingsChoice() throws {
    let s = store()
    let inherited = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    let explicit = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)
    try s.dispatch(Command("setWindowLayout", [.string(explicit), "sidebar"]))
    try s.applyConfig(ConfigApplyTests.contents(settings: ["tabLayout": "top"]), source: ConfigApplyTests.source)

    try withLayoutStore(s) {
      let choseSidebar = try SettingsWrites.chooseTabLayout("sidebar")
      #expect(!choseSidebar)
    }

    #expect(s.state.settings.string("tabLayout") == "top")
    #expect(s.state.settings.ownValues["tabLayout"] == "sidebar")
    #expect(s.state.settings.chosen?.contains("tabLayout") == false)
    #expect(s.state.windows[inherited]?.tabLayout == nil)
    #expect(s.state.windows[explicit]?.tabLayout == "sidebar")
  }

  @MainActor @Test func aFrozenOrUnownedStoreRefusesTheSettingsChoice() throws {
    let s = store()
    let inherited = try #require(try s.dispatch(Command("createWindow", [[:]])).result?.string)

    try withLayoutStore(s) {
      NativeStoreHandle.ownsWorkspace = false
      let choseTopUnowned = try SettingsWrites.chooseTabLayout("top")
      #expect(!choseTopUnowned)
      NativeStoreHandle.ownsWorkspace = true
      NativeStoreHandle.markFrozen()
      defer { NativeStoreHandle.thawForTests() }
      let choseTopFrozen = try SettingsWrites.chooseTabLayout("top")
      #expect(!choseTopFrozen)
    }

    #expect(s.state.settings.string("tabLayout") == "sidebar")
    #expect(s.state.windows[inherited]?.tabLayout == nil)
  }

  @MainActor @Test func anOwnedSafeModeStoreAcceptsTheSettingsChoice() throws {
    var config = StoreConfig()
    config.safeMode = true
    let s = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), config: config)

    try withLayoutStore(s) {
      let choseTop = try SettingsWrites.chooseTabLayout("top")
      #expect(choseTop)
    }

    #expect(s.state.settings.string("tabLayout") == "top")
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

  @MainActor @Test func settingsProfileCreationProjectsSharedAndIndependentProfilesImmediately() throws {
    let s = store()
    let window = try s.dispatch(Command("createWindow", [[:]]))
    let before = window.state
    let model = SettingsModel(store: s)

    try withLayoutStore(s) {
      let sharedCommit = try model.writeProfile(SettingsWrites.createProfile(name: "  Work  ", color: "blue", shareWith: "default"))
      let shared = try #require(sharedCommit?.result?.string)
      #expect(sharedCommit?.origin == .native)
      #expect(sharedCommit?.effects == [.profileCreated(profileId: shared, sharedWith: "default")])
      #expect(model.profiles.map(\.id) == ["default", shared])
      #expect(model.profiles.last?.name == "Work")
      #expect(model.profiles.last?.color == "blue")
      #expect(model.profiles.last?.dataId == "default")

      let independentCommit = try model.writeProfile(SettingsWrites.createProfile(name: "  ", color: "green", shareWith: "missing"))
      let independent = try #require(independentCommit?.result?.string)
      #expect(independentCommit?.effects == [.profileCreated(profileId: independent, sharedWith: nil)])
      #expect(model.profiles.map(\.id) == ["default", shared, independent])
      #expect(model.profiles.last?.name == "Profile 3")
      #expect(model.profiles.last?.dataId == nil)
    }
    #expect(s.state.windows == before.windows)
    #expect(s.state.tabs == before.tabs)
    #expect(s.state.ui.focusedWindowId == before.ui.focusedWindowId)
    #expect(s.state.settings.defaultProfileId == before.settings.defaultProfileId)
  }

  @MainActor @Test func settingsProfileWritesRefuseAnUnownedFrozenOrReplacedStore() throws {
    let s = store()
    let model = SettingsModel(store: s)
    let replacement = store()
    let before = s.state
    try withLayoutStore(s) {
      NativeStoreHandle.ownsWorkspace = false
      let unowned = try model.writeProfile(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil))
      #expect(unowned == nil)
      NativeStoreHandle.ownsWorkspace = true
      NativeStoreHandle.markFrozen()
      let frozen: Commit?
      do {
        defer { NativeStoreHandle.thawForTests() }
        frozen = try model.editProfile("default", fields: ["name": "Refused"])
      }
      #expect(frozen == nil)
      NativeStoreHandle.resolve = { replacement }
      let replaced = try model.writeProfile(SettingsWrites.reorderProfiles(["default"]))
      #expect(replaced == nil)
    }
    #expect(s.state == before)
    #expect(s.rev == 0)
    #expect(replacement.rev == 0)
  }

  @MainActor @Test func profileEditsAndReordersKeepTheLatestProjection() throws {
    let s = store()
    let added = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil))
    let id = try #require(added.result?.string)
    let model = SettingsModel(store: s)
    let stale = try s.dispatch(SettingsWrites.updateProfile(id, ["name": "Earlier"]), origin: .native)

    try withLayoutStore(s) {
      let edit = try model.editProfile(id, fields: ["name": "Office", "color": "green"])
      let reorder = try model.writeProfile(SettingsWrites.reorderProfiles(["unknown", id]))
      #expect(edit?.origin == .native)
      #expect(reorder?.origin == .native)
      model.adopt(stale)
      #expect(model.profiles.map(\.id) == [id, "default"])
      #expect(model.profiles.first?.name == "Office")
      #expect(model.profiles.first?.color == "green")
      let missing = try model.editProfile("missing", fields: ["name": "Nobody"])
      #expect(missing == nil)
    }
  }

  @Test func concurrentNativeProfileEditsAndReordersPreserveBothWrites() async throws {
    let s = store()
    let added = try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil))
    let id = try #require(added.result?.string)
    let before = s.state

    async let edit = s.dispatch(SettingsWrites.updateProfile(id, ["name": "Office", "color": "green"]), origin: .native)
    async let reorder = s.dispatch(SettingsWrites.reorderProfiles([id, "unknown"]), origin: .native)
    let (edited, reordered) = try await (edit, reorder)

    #expect(edited.rev != reordered.rev)
    #expect(s.state.profileOrder == [id, "default"])
    #expect(s.state.profiles[id]?.name == "Office")
    #expect(s.state.profiles[id]?.color == "green")
    #expect(s.state.settings.defaultProfileId == before.settings.defaultProfileId)
  }

  private func opening(_ s: Store, focused: @escaping (String) -> Void = { _ in }) -> SettingsOpening {
    SettingsOpening(state: { s.state }, run: { try? s.dispatch($0) }, focus: focused)
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

  @Test func openInNewTabUsesTheFocusedPrivateWindow() throws {
    let s = store()
    let regular = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let secret = try s.dispatch(Command("createWindow", [["incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(secret)]))
    let calls = Box()
    let url = "https://extension.test/"
    #expect(recording(s, calls).openInNewTab(url))
    #expect(s.state.activeTab(secret)?.url == url)
    #expect(s.state.activeTab(secret)?.profileId == s.state.windows[secret]?.profileId)
    #expect(!urls(s, regular).contains(url))
    #expect(calls.items == ["newTab"])
  }

  @Test func openInNewTabWithNoWindowDoesNothing() {
    let s = store()
    let calls = Box()
    #expect(!recording(s, calls).openInNewTab("https://extension.test/"))
    #expect(s.state.windowOrder.isEmpty)
    #expect(calls.items.isEmpty)
  }

  @Test func openInNewTabSkipsLittleSolara() throws {
    let s = store()
    let small = try s.dispatch(Command("createWindow", [["url": "https://small.test/", "small": true]])).result!.string!
    let url = "https://extension.test/"
    #expect(!opening(s).openInNewTab(url))
    let window = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(small)]))
    #expect(opening(s).openInNewTab(url))
    #expect(s.state.activeTab(window)?.url == url)
    #expect(urls(s, small) == ["https://small.test/"])
  }

  @Test func refusedOpenStopsTheBatchAndDoesNotFocus() throws {
    let s = store()
    _ = try s.dispatch(Command("createWindow", [[:]]))
    var commands: [String] = []
    var focused: [String] = []
    let refused = SettingsOpening(state: { s.state }, run: { command in
      commands.append(command.name)
      return nil
    }, focus: { focused.append($0) })
    #expect(!refused.openURLs(["https://a.test/", "https://b.test/"]))
    #expect(!refused.openInNewTab("https://extension.test/"))
    #expect(!refused.openInBrowser("https://live.test/"))
    #expect(!refused.openInternalPage("history", scheme: "solara", isAppScheme: { $0 == "solara" }))
    #expect(commands == ["newTab", "newTab", "newTab", "setFocusedWindow"])
    #expect(focused.isEmpty)
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
        return try? s.dispatch(command)
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

  @Test func internalPageWithExplicitPrivateWindowLeavesWindowFocusAlone() throws {
    let s = store()
    let regular = try s.dispatch(Command("createWindow", [["url": "https://regular.test/"]])).result!.string!
    let secret = try s.dispatch(Command("createWindow", [["incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(regular)]))
    let blank = try #require(s.state.activeTabId(secret))
    let calls = Box()

    #expect(recording(s, calls).openInternalPage("history", windowId: secret, scheme: "solara", isAppScheme: { $0 == "solara" }))
    #expect(calls.items == ["navigate"])
    #expect(s.state.activeTabId(secret) == blank)
    #expect(s.state.tabs[blank]?.navigation?.url == "solara://history")
    #expect(s.state.tabs[blank]?.profileId == s.state.windows[secret]?.profileId)
    #expect(s.state.ui.focusedWindowId == regular)
  }

  @Test func backgroundInternalPageReusesTheSameTabAndEncodesQuery() throws {
    let s = store()
    let window = try s.dispatch(Command("createWindow", [[:]])).result!.string!
    let blank = try #require(s.state.activeTabId(window))
    let calls = Box()
    let library = recording(s, calls)
    let isAppScheme: (String) -> Bool = { $0 == "solara" }

    #expect(library.openInternalPage("downloads", background: true, scheme: "solara", isAppScheme: isAppScheme))
    let downloads = try #require(s.state.viewTabIds(window).first { $0 != blank })
    let count = s.state.viewTabIds(window).count
    #expect(s.state.tabs[downloads]?.url == "solara://downloads")
    #expect(library.openInternalPage("downloads", windowId: "closed", query: "a+b &é/#", background: true,
      scheme: "solara", isAppScheme: isAppScheme))
    #expect(s.state.tabs[downloads]?.navigation?.url == "solara://downloads?q=a%2Bb%20%26%C3%A9%2F%23")
    #expect(s.state.viewTabIds(window).count == count)
    #expect(s.state.activeTabId(window) == blank)
    #expect(calls.items == ["newTab", "navigate"])

    #expect(library.openInternalPage("downloads", windowId: "closed", scheme: "solara", isAppScheme: isAppScheme))
    #expect(s.state.activeTabId(window) == downloads)
    #expect(calls.items == ["newTab", "navigate", "setFocusedWindow", "focus:" + window, "activate"])
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
