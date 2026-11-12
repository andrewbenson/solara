import SolaraModel
import SolaraStore
import Testing

private struct LastWindowFixture {
  let store: Store
  let windowId: String
  let tabIds: [String]
  let groupIds: [String]
  let splitId: String

  init() throws {
    let store = makeStore()
    let windowId = try store.dispatch(Command("createWindow", [["url": "https://tile.example/"]])).result!.string!
    var ids = store.state.windows[windowId]!.tabIds
    for host in ["row", "member", "left", "right"] {
      ids.append(try store.dispatch(Command("newTab", [.string(windowId), ["url": .string("https://\(host).example/")]])).result!.string!)
    }
    try store.dispatch(Command("pinTabs", [[.string(ids[0])], true]))
    try store.dispatch(Command("pinTabs", [[.string(ids[1])], true, true]))
    let pinned = try store.dispatch(Command("groupTabs", [[.string(ids[2])], ["name": "Pinned", "pinned": true]])).result!.string!
    let ordinary = try store.dispatch(Command("groupTabs", [.array(ids.suffix(2).map(JSONValue.string)), ["name": "Reading", "pinned": false]])).result!.string!
    let splitId = try store.dispatch(Command("createSplit", [.array(ids.suffix(2).map(JSONValue.string)), "vertical"])).result!.string!
    try store.dispatch(Command("activate", [.string(ids[3])]))
    try store.dispatch(Command("setWindowFrame", [.string(windowId), [120, 180, 1100, 760]]))
    try store.dispatch(Command("setWindowSidebar", [.string(windowId), ["sidebarWidth": 260, "sidePanelWidth": 390]]))
    try store.dispatch(Command("setSelection", [.string(windowId), [.string(ids[3]), .string(ids[4])]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(windowId), .string(ids[3])]))
    try store.dispatch(Command("setFind", [.string(ids[3]), ["open": true, "query": "retained"]]))
    try store.dispatch(Command("setWindowKeptOnClose", [.string(windowId), true]))
    self.store = store
    self.windowId = windowId
    tabIds = ids
    groupIds = [pinned, ordinary]
    self.splitId = splitId
  }
}

@Suite struct LastWindowSessionTests {
  @Test func serializingRetainedWindowLeavesEveryLiveWorkspaceFieldUntouched() throws {
    let fixture = try LastWindowFixture()
    let store = fixture.store
    let before = store.state
    let revision = store.rev
    let document = store.sessionDocument()
    #expect(store.state == before)
    #expect(store.rev == revision)
    #expect(document.windows[fixture.windowId] == .object(before.windows[fixture.windowId]!.persistedJSON))
    #expect(document.windowOrder == [fixture.windowId])
    #expect(document.focusedWindowId == fixture.windowId)
    #expect(document.tabs.keys == before.tabs.keys)
    #expect(document.groups.keys == before.groups.keys)
    #expect(document.splits.keys == before.splits.keys)
    #expect(document.closedWindows.isEmpty)
    #expect(document.closedTabs.isEmpty)
    #expect(document.parkedPins.isEmpty)
    #expect(store.state.selection[fixture.windowId]?.ids == [fixture.tabIds[3], fixture.tabIds[4]])
    #expect(store.state.selectionAnchors[fixture.windowId]?.tabId == fixture.tabIds[3])
    #expect(store.state.find[fixture.tabIds[3]]?.json["query"] == "retained")
  }

  @Test(arguments: [false, true]) func relaunchRestoresRetainedWindowAsOpenWithItsOriginalIdsAndActivePane(restoreSession: Bool) throws {
    let fixture = try LastWindowFixture()
    try fixture.store.dispatch(settingsCommand(["restoreSession": .bool(restoreSession)]))
    let before = fixture.store.state
    let document = fixture.store.sessionDocument().json()
    let reloaded = makeStore()
    try reloaded.transact { _ = $0.loadSession(document, downloads: nil) }
    let state = reloaded.state
    let window = try #require(state.windows[fixture.windowId])
    #expect(state.windowOrder == [fixture.windowId])
    #expect(state.ui.focusedWindowId == fixture.windowId)
    var expectedWindow = before.windows[fixture.windowId]!
    expectedWindow.keptOnClose = nil
    #expect(window.persistedJSON == expectedWindow.persistedJSON)
    #expect(window.keptOnClose == nil)
    #expect(window.activeTabIds["default"] == fixture.tabIds[3])
    #expect(state.tabs.keys == before.tabs.keys)
    for id in fixture.tabIds {
      #expect(state.tabs[id]?.url == before.tabs[id]?.url)
      #expect(state.tabs[id]?.pinned == before.tabs[id]?.pinned)
      #expect(state.tabs[id]?.pinnedAsRow == before.tabs[id]?.pinnedAsRow)
      #expect(state.tabs[id]?.windowId == fixture.windowId)
    }
    for id in fixture.groupIds {
      let restored = try #require(state.groups[id])
      #expect(restored.json == before.groups[id]?.json)
    }
    let restoredSplit = try #require(state.splits[fixture.splitId])
    #expect(restoredSplit.json == before.splits[fixture.splitId]?.json)
    #expect(state.closedWindows.isEmpty)
    #expect(state.closedTabs.isEmpty)
    #expect(state.parkedPins.isEmpty)
    #expect(state.selection.isEmpty)
    #expect(state.selectionAnchors.isEmpty)
  }

  @Test func newWindowDoesNotReplaceRetainedWindowOrItsSelection() throws {
    let fixture = try LastWindowFixture()
    let before = fixture.store.state
    let created = try fixture.store.dispatch(Command("createWindow", [["url": "https://new.example/"]])).result!.string!
    #expect(created != fixture.windowId)
    #expect(fixture.store.state.windowOrder == [fixture.windowId, created])
    #expect(fixture.store.state.windows[fixture.windowId] == before.windows[fixture.windowId])
    #expect(fixture.store.state.selection[fixture.windowId] == before.selection[fixture.windowId])
    #expect(fixture.store.state.selectionAnchors[fixture.windowId] == before.selectionAnchors[fixture.windowId])
    #expect(fixture.store.state.splits[fixture.splitId] == before.splits[fixture.splitId])
    #expect(fixture.store.state.closedWindows.isEmpty)
  }

  @Test func retentionMarkerIsDurableIdempotentAndDoesNotChangeWindowLocalState() throws {
    let fixture = try LastWindowFixture()
    let store = fixture.store
    let before = store.state
    let same = try store.dispatch(Command("setWindowKeptOnClose", [.string(fixture.windowId), true]))
    #expect(same.changes.isEmpty)
    let reveal = try store.dispatch(Command("setWindowKeptOnClose", [.string(fixture.windowId), false]))
    #expect(reveal.durable)
    #expect(store.state.windows[fixture.windowId]?.keptOnClose == nil)
    #expect(store.state.windows[fixture.windowId]?.json["keptOnClose"] == nil)
    #expect(store.state.tabs == before.tabs)
    #expect(store.state.groups == before.groups)
    #expect(store.state.splits == before.splits)
    #expect(store.state.selection == before.selection)
    #expect(store.state.selectionAnchors == before.selectionAnchors)
    #expect(store.state.find == before.find)
    #expect(store.state.ui == before.ui)
  }

  @Test func startFreshRestoresOnlyTheRetainedWindowAndArchivesOtherWindows() throws {
    let fixture = try LastWindowFixture()
    let other = try fixture.store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    try fixture.store.dispatch(settingsCommand(["restoreSession": false]))
    let reloaded = makeStore()
    try reloaded.transact { _ = $0.loadSession(fixture.store.sessionDocument().json(), downloads: nil) }
    #expect(reloaded.state.windowOrder == [fixture.windowId])
    #expect(reloaded.state.windows[fixture.windowId]?.keptOnClose == nil)
    #expect(reloaded.state.windows[other] == nil)
    #expect(reloaded.state.closedWindows.count == 1)
    #expect(reloaded.state.closedWindows[0].tabs.map(\.snapshot.url) == ["https://other.example/"])
    #expect(reloaded.state.groups.keys == fixture.store.state.groups.keys.filter { fixture.groupIds.contains($0) })
    #expect(reloaded.state.splits[fixture.splitId] != nil)
    #expect(reloaded.state.parkedPins.isEmpty)
  }

  @Test func revealingBeforeQuitReturnsToStartFreshPreference() throws {
    let fixture = try LastWindowFixture()
    try fixture.store.dispatch(Command("setWindowKeptOnClose", [.string(fixture.windowId), false]))
    try fixture.store.dispatch(settingsCommand(["restoreSession": false]))
    let reloaded = makeStore()
    try reloaded.transact { _ = $0.loadSession(fixture.store.sessionDocument().json(), downloads: nil) }
    #expect(reloaded.state.windows.isEmpty)
    #expect(reloaded.state.tabs.isEmpty)
    #expect(reloaded.state.closedWindows.count == 1)
    #expect(reloaded.state.parkedPins["default"]?.tabs.count == 3)
  }

  @Test(arguments: ["private", "small"]) func privateAndLittleWindowsRejectRetentionMarker(kind: String) throws {
    let store = makeStore()
    let id = try store.dispatch(Command("createWindow", [["url": "https://ephemeral.example/", "incognito": .bool(kind == "private"), "small": .bool(kind == "small")]])).result!.string!
    let before = store.state
    try store.dispatch(Command("setWindowKeptOnClose", [.string(id), true]))
    #expect(store.state == before)
    var raw = store.state.windows[id]!.json
    raw["keptOnClose"] = true
    #expect(try BrowserWindow(json: raw).keptOnClose == nil)
    #expect(store.sessionDocument().windows.isEmpty)
    #expect(store.sessionDocument().tabs.isEmpty)
  }

  @Test func physicalCloseOfOneOfTwoWindowsArchivesOnlyThatWindow() throws {
    let store = makeStore()
    let first = try store.dispatch(Command("createWindow", [["url": "https://first.example/"]])).result!.string!
    let second = try store.dispatch(Command("createWindow", [["url": "https://second.example/"]])).result!.string!
    let secondBefore = store.state.windows[second]
    try store.dispatch(Command("closeWindow", [.string(first)]))
    #expect(store.state.windows[first] == nil)
    #expect(store.state.windows[second] == secondBefore)
    #expect(store.state.windowOrder == [second])
    #expect(store.state.closedWindows.count == 1)
    #expect(store.state.closedWindows[0].tabs.map(\.snapshot.url) == ["https://first.example/"])
    #expect(store.sessionDocument().windows.keys == [second])
  }

  @Test func physicalCloseOfLastPrivateWindowDestroysItWithoutPersistingItsPages() throws {
    let store = makeStore()
    let id = try store.dispatch(Command("createWindow", [["url": "https://private.example/", "incognito": true]])).result!.string!
    try store.dispatch(Command("newTab", [.string(id), ["url": "https://secret.example/"]]))
    #expect(store.sessionDocument().windows.isEmpty)
    #expect(store.sessionDocument().tabs.isEmpty)
    try store.dispatch(Command("closeWindow", [.string(id)]))
    #expect(store.state.windows.isEmpty)
    #expect(store.state.tabs.isEmpty)
    #expect(store.state.closedWindows.isEmpty)
    #expect(store.state.closedTabs.isEmpty)
    #expect(store.sessionDocument().windows.isEmpty)
    #expect(store.sessionDocument().tabs.isEmpty)
  }
}
