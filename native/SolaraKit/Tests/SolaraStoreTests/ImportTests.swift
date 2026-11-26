import SolaraModel
import SolaraStore
import Testing

@Suite struct ImportTests {
  func command(_ windows: [JSONValue], profileId: String = "default", pinnedAgainst: String = "anyPin") -> Command {
    Command("importWorkspace", [["profileId": .string(profileId), "pinnedAgainst": .string(pinnedAgainst), "windows": .array(windows)]])
  }

  @Test func safeImportRefusesWorkspaceAndThemeWithoutChangingStateOrIds() throws {
    var config = StoreConfig()
    config.safeMode = true
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), config: config, checksInvariants: true)
    let before = store.state
    let ids = store.memory.ids
    let imports: [[JSONValue]] = [[], [["newWindow": true, "tabs": [["url": "https://safe-import.example/", "title": "Refused"]]]]]
    for windows in imports {
      do {
        try store.dispatch(Command("importWorkspace", [["profileId": "default", "theme": ["kind": "solid", "color": "#123456"], "windows": .array(windows)]]))
        Issue.record("Safe workspace import reported success")
      } catch let error as CommandError {
        #expect(error.description.contains("safe mode"))
      }
      #expect(store.state == before)
      #expect(store.memory.ids == ids)
      #expect(store.rev == 0)
    }
  }

  @Test func importsWindowsGroupsAndSplitsWithUniqueIdsInOneCommit() throws {
    let store = makeStore()
    let seen = Seen()
    store.subscribe { seen.append($0.rev) }
    let commit = try store.dispatch(command([
      ["newWindow": true, "tabs": [
        ["url": "https://a.example/", "title": "A"],
        ["url": "https://pin.example/", "title": "Pin", "pinned": true],
        ["url": "https://b.example/", "title": "B"],
        ["url": "https://c.example/", "title": "C"]
      ], "groups": [["name": "Imported", "tabIndices": [0, 2]]], "splits": [["tabIndices": [0, 2], "orientation": "vertical"]]],
      ["newWindow": true, "tabs": [["url": "file:///tmp/import.html", "title": "File"]]]
    ]))
    #expect(commit.rev == 1)
    #expect(seen.values == [1])
    #expect(commit.result?["tabs"] == 5)
    #expect(store.state.windowOrder.count == 2)
    let ids = store.state.windows.keys + store.state.tabs.keys + store.state.groups.keys + store.state.splits.keys
    #expect(Set(ids).count == ids.count)
    #expect(Invariants.violations(store.state).isEmpty)
    let group = try #require(store.state.groups.values.first)
    let window = try #require(store.state.windows[group.windowId])
    let positions = group.tabIds.compactMap { window.tabIds.firstIndex(of: $0) }
    #expect(positions.max()! - positions.min()! == group.tabIds.count - 1)
    #expect(store.state.tabs[window.tabIds[0]]?.pinned == true)
    let split = try #require(store.state.splits.values.first)
    #expect(split.tabIds == group.tabIds)
    #expect(split.orientation == "vertical")
    #expect(split.sizes == [0.5, 0.5])
    #expect(store.state.tabs.values.allSatisfy { $0.navigation == nil && $0.unloaded == true && $0.adoptId == nil })
    #expect(!commit.effects.contains { if case .startNavigation = $0 { true } else { false } })
  }

  @Test func appendsToAnExistingWindowWithPinnedRowsAndPinnedGroups() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let commit = try store.dispatch(command([["windowId": .string(window), "tabs": [
      ["url": "https://a.example", "title": "A"],
      ["url": "https://row.example", "title": "Row", "pinned": true, "row": true, "customTitle": "Custom"],
      ["url": "https://b.example", "title": "B"]
    ], "groups": [["name": "Pinned", "tabIndices": [0, 2], "pinned": true]]]]))
    #expect(commit.result?["tabs"] == 3)
    #expect(store.state.windowOrder == [window])
    #expect(Invariants.violations(store.state).isEmpty)
    let row = try #require(store.state.tabs.values.first { $0.url == "https://row.example" })
    #expect(row.pinnedAsRow == true)
    #expect(row.customTitle == "Custom")
    let group = try #require(store.state.groups.values.first)
    #expect(group.pinned)
    #expect(group.tabIds.allSatisfy { store.state.tabs[$0]?.pinnedUrl != nil })
  }

  @Test func pinsImportedIntoTwoExistingWindowsAreBothKept() throws {
    let store = makeStore()
    let first = try store.dispatch(Command("createWindow")).result!.string!
    let second = try store.dispatch(Command("createWindow")).result!.string!
    let commit = try store.dispatch(command([
      ["windowId": .string(first), "tabs": [["url": "https://pin-a.example/", "title": "A", "pinned": true]]],
      ["windowId": .string(second), "tabs": [["url": "https://pin-b.example/", "title": "B", "pinned": true]]]
    ]))
    #expect(commit.result?["tabs"] == 2)
    #expect(Invariants.violations(store.state).isEmpty)
    for windowId in [first, second] {
      let pins = Set(store.state.windows[windowId]!.tabIds.compactMap { store.state.tabs[$0] }.filter(\.pinned).map(\.url))
      #expect(pins == ["https://pin-a.example/", "https://pin-b.example/"])
    }
    let returned = commit.result?["tabIds"]?.array?.flatMap { $0.array ?? [] }.compactMap(\.string) ?? []
    #expect(returned.count == 2)
    #expect(returned.allSatisfy { store.state.tabs[$0] != nil })
  }

  @Test func skipsUnsupportedAndDuplicatePagesUsingFreshNativeState() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://have.example/"]])).result!.string!
    let commit = try store.dispatch(command([["windowId": .string(window), "group": "Imported", "tabs": [
      ["url": "https://HAVE.example", "title": "Duplicate"],
      ["url": "javascript:alert(1)", "title": "Ignored"],
      ["url": "https://new.example", "title": "New"],
      ["url": "https://new.example/", "title": "Duplicate New"]
    ]]]))
    #expect(commit.result?["tabs"] == 1)
    #expect(store.state.groups.values.first?.tabIds.count == 1)
    #expect(store.state.groups.values.first?.name == "Imported")
  }

  @Test func refusesMalformedInputWithoutStateOrIdChanges() throws {
    let store = makeStore()
    let before = store.state
    let ids = store.memory.ids
    let control = try makeStore().dispatch(command([["tabs": [["url": "https://control.example", "title": "Control"]]]]))
    #expect(control.result?["tabs"] == 1)
    let malformed: [JSONValue] = [
      ["tabs": "invalid"],
      ["newWindow": "true", "tabs": []],
      ["tabs": [["url": "https://a.example", "title": "A", "pinned": 1]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]], "groups": [["name": "A", "tabIndices": [0]], ["name": "B", "tabIndices": [0, 1]]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]], "splits": [["tabIndices": [0, 1], "orientation": "invalid"]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B", "pinned": true]], "splits": [["tabIndices": [0, 1]]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]], "groups": [["name": "A", "tabIndices": [0]]], "splits": [["tabIndices": [0, 1]]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]], "splits": [["tabIndices": [0, 1]], ["tabIndices": [0, 1]]]],
      ["tabs": [["url": 7, "title": "Bad"]]],
      ["tabs": [["url": "https://a.example", "title": "A"]], "groups": [["name": "Bad", "tabIndices": [2]]]],
      ["tabs": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]], "splits": [["tabIndices": [0, 0]]]],
      ["windowId": "missing", "tabs": [["url": "https://a.example", "title": "A"]]]
    ]
    for bad in malformed {
      #expect(throws: CommandError.self) { try store.dispatch(command([["newWindow": true, "tabs": [["url": "https://valid.example", "title": "Valid"]]], bad])) }
      #expect(store.state == before)
      #expect(store.rev == 0)
      #expect(store.memory.ids == ids)
    }
    #expect(throws: CommandError.self) { try store.dispatch(command([], profileId: "missing")) }
    #expect(store.state == before)
  }

  @Test func importsNestedDraftsAlongsideTabsInOneCommit() throws {
    let store = makeStore()
    let commit = try store.dispatch(command([["tabs": [["url": "https://open.example", "title": "Open"]], "group": "Imported", "drafts": [
      ["title": "Outer", "children": [["title": "Inner", "children": [["title": "Pinned", "url": "https://pin.example"]]]]]
    ]]]))
    #expect(commit.rev == 1)
    #expect(commit.result?["tabs"] == 2)
    #expect(commit.result?["skipped"] == 0)
    #expect(store.state.groups.values.contains { $0.parentId != nil })
    #expect(store.state.tabs.values.allSatisfy { $0.navigation == nil && $0.unloaded == true })
    #expect(Invariants.violations(store.state).isEmpty)
  }

  @Test func refusalInsideAHeldTransactionHasNoPartialImport() throws {
    let store = makeStore()
    try store.dispatch(Command("beginTransaction"))
    let before = store.state
    #expect(throws: CommandError.self) {
      try store.dispatch(command([
        ["newWindow": true, "tabs": [["url": "https://valid.example", "title": "Valid"]]],
        ["tabs": [["url": "https://invalid.example", "title": "Invalid"]], "splits": [["tabIndices": [0, 4]]]]
      ]))
    }
    #expect(store.state == before)
    #expect(store.rev == 0)
    try store.dispatch(command([["newWindow": true, "tabs": [["url": "https://control.example", "title": "Control"]]]]))
    try store.dispatch(Command("endTransaction"))
    #expect(store.state.windows.count == 1)
    #expect(store.state.tabs.values.map(\.url) == ["https://control.example"])
    #expect(store.rev == 1)
  }

  @Test func skipsExistingOpenPagesForDiaEvenWhenImportingPins() throws {
    let store = makeStore()
    try store.dispatch(Command("createWindow", [["url": "https://have.example/"]]))
    let commit = try store.dispatch(command([["skipExistingOpen": true, "tabs": [["url": "https://HAVE.example", "title": "Pin", "pinned": true]]]]))
    #expect(commit.result?["tabs"] == 0)
    #expect(!store.state.tabs.values.contains { $0.pinned })
  }

  @Test func insertsImportedTabsAtTheConfiguredPositionInTheirSourceOrder() throws {
    let store = makeStore()
    try store.dispatch(settingsCommand(["newTabPosition": "top"]))
    let window = try store.dispatch(Command("createWindow", [["url": "https://existing.example"]])).result!.string!
    try store.dispatch(command([["windowId": .string(window), "tabs": [["url": "https://first.example", "title": "First"], ["url": "https://second.example", "title": "Second"]]]]))
    #expect(store.state.windows[window]!.tabIds.compactMap { store.state.tabs[$0]?.url } == ["https://first.example", "https://second.example", "https://existing.example"])
  }

  @Test func importsProfileThemeWithTheWorkspace() throws {
    let store = makeStore()
    let theme: JSONValue = ["kind": "solid", "color": "#123456"]
    let commit = try store.dispatch(Command("importWorkspace", [["profileId": "default", "theme": theme, "windows": []]]))
    #expect(commit.rev == 1)
    #expect(store.state.profiles["default"]?.theme == theme)
  }

  @Test func settingWindowLayoutLeavesSettingsUntouched() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let settings = store.state.settings
    try store.dispatch(Command("setWindowLayout", [.string(window), "sidebar"]))
    #expect(store.state.windows[window]?.tabLayout == "sidebar")
    #expect(store.state.settings == settings)
    #expect(throws: CommandError.self) { try store.dispatch(Command("setWindowLayout", [.string(window), "invalid"])) }
  }
  @Test func sidebarRowsPrecedeOpensFoldersAndFavoriteTiles() throws {
    let store = makeStore()
    let windows: [JSONValue] = [
      ["tabs": [["url": "https://row.example/", "title": "Row", "pinned": true, "row": true]]],
      ["tabs": [["url": "https://row.example/", "title": "Duplicate"], ["url": "https://open.example/", "title": "Open"]], "group": "Imported", "drafts": [
        ["title": "Outer", "children": [["title": "Inner", "children": [["title": "Folder page", "url": "https://open.example/"]]]]],
        ["title": "Empty", "children": []]
      ]]
    ]
    let written = try store.dispatch(command(windows))
    #expect(written.result?["tabs"] == 3)
    #expect(store.state.groups.values.map(\.name).sorted() == ["Imported", "Inner", "Outer"])
    #expect(store.state.tabs.values.filter { $0.pinnedAsRow == true }.count == 1)
    #expect(store.state.tabs.values.allSatisfy { $0.unloaded == true && $0.navigation == nil })
    let favorite: [JSONValue] = [["tabs": [["url": "https://row.example/", "title": "Tile", "pinned": true]], "pinnedAgainst": "tiles"]]
    #expect(try store.dispatch(command(favorite)).result?["tabs"] == 1)
    #expect(try store.dispatch(command(windows)).result?["tabs"] == 0)
    #expect(try store.dispatch(command(favorite)).result?["tabs"] == 0)
    #expect(Invariants.violations(store.state).isEmpty)
  }

  @Test func sidebarCapCountsRepeatedFreshRejectedLinksPerRoot() throws {
    let store = makeStore()
    let links: [JSONValue] = (0..<5000).map { ["title": "Link", "url": .string("https://cap.example/\($0)")] }
    let repeated: [JSONValue] = Array(repeating: ["title": "Overflow", "url": "https://cap.example/overflow"], count: 3)
    let commit = try store.dispatch(command([["tabs": [], "drafts": [
      ["title": "First", "children": .array(links + [["title": "Duplicate", "url": "https://cap.example/0"], ["title": "Invalid", "url": "javascript:invalid"], ["title": "Nested", "children": .array(repeated)]])],
      ["title": "Second", "children": [["title": "Fresh", "url": "https://second.example/"]]]
    ]]]))
    #expect(commit.result?["tabs"] == 5001)
    #expect(commit.result?["skipped"] == 3)
    #expect(!store.state.tabs.values.contains { $0.url.hasSuffix("overflow") })
    #expect(Invariants.violations(store.state).isEmpty)
  }

  @Test func sidebarThemePreservesFileOwnershipAndUpdatesOnlyOwnTheme() throws {
    let old: JSONValue = ["mode": "auto", "intensity": 0.2]
    let file: JSONValue = ["mode": "dark", "intensity": 0.4]
    let imported: JSONValue = ["mode": "light", "intensity": 0.8]
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.profiles["default"]!.theme = old
    state.profiles["default"] = state.profiles["default"]!.applyingFileTheme(file, name: "File", source: "fixture")
    let store = Store(state: state, checksInvariants: true)
    try store.dispatch(Command("importWorkspace", [["profileId": "default", "theme": imported, "windows": []]]))
    #expect(store.state.profiles["default"]?.theme == file)
    #expect(store.state.profiles["default"]?.ownTheme == imported)
    #expect(store.state.profiles["default"]?.fileTheme?.name == "File")
  }

  @Test func sidebarRowsAndOpensRespectExistingHomeAndParkedPages() throws {
    let seed = makeStore()
    let window = try #require(try seed.dispatch(Command("createWindow", [["url": "https://away.example/"]])).result?.string)
    let existing = try #require(seed.state.windows[window]?.tabIds.first)
    try seed.dispatch(Command("pinTabs", [[.string(existing)], true]))
    var state = seed.state
    state.tabs[existing]!.pinnedUrl = "https://home.example/"
    let snapshot = TabSnapshot(url: "https://parked.example/", title: "Parked", favicon: nil, pinned: true, muted: false, zoom: 1, customTitle: nil, customIcon: nil, profileId: "default", pinnedUrl: "https://parked.example/")
    state.parkedPins["default"] = ParkedPins(tabs: [ParkedTab(snapshot: snapshot, id: "parked", groupId: nil, restoreFrom: nil)], groups: [], splits: nil)
    let store = Store(state: state, checksInvariants: true)
    let before = store.state
    let commit = try store.dispatch(command([
      ["tabs": [["url": "https://home.example/", "title": "Home", "pinned": true, "row": true], ["url": "https://parked.example/", "title": "Parked", "pinned": true, "row": true]]],
      ["tabs": [["url": "https://away.example/", "title": "Away"], ["url": "https://parked.example/", "title": "Parked"]], "group": "Imported"]
    ]))
    #expect(commit.result?["tabs"] == 0)
    #expect(store.state == before)
    #expect(Invariants.violations(store.state).isEmpty)
  }

}
