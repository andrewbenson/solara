import Foundation
import SolaraModel
@testable import SolaraPersistence
@testable import SolaraStore
import Testing

private final class RelaunchClock: @unchecked Sendable {
  var milliseconds: Double = 100
}

private final class RelaunchWorkspace {
  let folder: DataFolder
  let launch: Launch
  let store: Store
  let writer: PersistenceWriter

  init(folder: DataFolder? = nil, clock: @escaping @Sendable () -> Double = { now.timeIntervalSince1970 * 1000 }) throws {
    self.folder = try folder ?? scratchFolder()
    launch = try open(self.folder)
    store = SolaraStore.Store(state: launch.state, memory: launch.memory, checksInvariants: true, clock: clock)
    try store.dispatch(Command("updateSettings", [["newTabPosition": "bottom"]]))
    writer = PersistenceWriter(store: store, database: launch.database, folder: self.folder, persisted: launch.persisted)
  }

  deinit {
    writer.freeze()
    try? launch.database.close()
  }

  @discardableResult func call(_ name: String, _ args: [JSONValue] = []) throws -> String {
    try store.dispatch(Command(name, args)).result?.string ?? ""
  }

  func window(_ url: String = "https://public.example/", _ options: JSONObject = [:]) throws -> String {
    var o = options
    o["url"] = .string(url)
    return try call("createWindow", [.object(o)])
  }

  func tab(_ window: String, _ url: String) throws -> String {
    try call("newTab", [.string(window), ["url": .string(url)]])
  }

  func save() throws -> JSONValue {
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    let rows = try #require(launch.database.load().sessionJSON())
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    for key in ["windows", "tabs", "groups", "splits", "closedTabs", "closedWindows", "cleanedTabs", "parkedPins", "pinSync", "launchTab", "linkProfile", "lastProfileId", "settings"] {
      #expect(rows[key] == shadow[key], "rows and shadow disagree for \(key)")
    }
    return rows
  }

  func reopen(at milliseconds: Double? = nil) throws -> Launch {
    writer.freeze()
    try launch.database.close()
    if let milliseconds {
      return try Launcher.open(folder, appVersion: "1.0", now: Date(timeIntervalSince1970: milliseconds / 1000), context: LoadContext(memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)), now: milliseconds))
    }
    return try open(folder)
  }
}

private func row(_ document: JSONValue, _ table: String, _ id: String) throws -> JSONValue {
  try #require(document[table]?.array?.first { $0["id"] == .string(id) })
}

private func snapshot(_ profile: String = "default", _ url: String = "https://public.example/") -> JSONValue {
  ["url": .string(url), "title": "Saved", "favicon": .null, "pinned": false, "muted": false, "zoom": 1, "customTitle": .null, "customIcon": .null, "profileId": .string(profile)]
}

private func cleaned(_ id: String, profile: String = "default", at: Double = now.timeIntervalSince1970 * 1000) throws -> ClosedTab {
  try ClosedTab(json: ["kind": "tab", "id": .string(id), "tab": snapshot(profile, profile == "default" ? "https://public.example/\(id)" : "https://secret.example/"), "windowId": "gone", "index": 0, "group": .null, "closedAt": .number(at)])
}

private func pinnedURLs(_ state: BrowserState, _ window: String) -> [String] {
  (state.windows[window]?.tabIds ?? []).compactMap { state.tabs[$0] }.filter(\.pinned).map(\.url)
}

@Suite struct RelaunchPersistenceTests {
  @Test func sidebarThemeUsesOwnThemeAndSurvivesRelaunch() throws {
    let h = try RelaunchWorkspace()
    let old: JSONValue = ["stops": [["color": ["r": 0, "g": 0, "b": 1, "a": 1], "x": 0.5, "y": 0.5]], "mode": "auto"]
    let imported: JSONValue = ["stops": [["color": ["r": 1, "g": 0, "b": 0, "a": 1], "x": 1, "y": 0.5]], "mode": "light"]
    try h.call("updateProfile", ["default", ["theme": old]])
    try h.call("importWorkspace", [["profileId": "default", "theme": imported, "windows": [["tabs": [["url": "https://theme.example/", "title": "Theme", "pinned": true, "row": true]]]]]])
    #expect(h.store.state.profiles["default"]?.ownTheme == imported)
    _ = try h.save()
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.profiles["default"]?.ownTheme == imported)
    #expect(next.state.tabs.values.contains { $0.url == "https://theme.example/" && $0.pinnedAsRow == true })
  }

  @Test func omittedFailedThemePreservesOldThemeWhileTabsPersist() throws {
    let h = try RelaunchWorkspace()
    let old: JSONValue = ["stops": [["color": ["r": 0, "g": 0, "b": 1, "a": 1], "x": 0.5, "y": 0.5]], "mode": "auto"]
    try h.call("updateProfile", ["default", ["theme": old]])
    try h.call("importWorkspace", [["profileId": "default", "windows": [["tabs": [["url": "https://kept.example/", "title": "Kept"]], "group": "Imported"]]]])
    _ = try h.save()
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.profiles["default"]?.ownTheme == old)
    #expect(next.state.tabs.values.contains { $0.url == "https://kept.example/" })
  }

  @Test func fullScreenOrderSurvivesRelaunch() throws {
    let clock = RelaunchClock()
    let h = try RelaunchWorkspace(clock: { clock.milliseconds })
    let a = try h.window("https://a.example/")
    let b = try h.window("https://b.example/")
    let c = try h.window("https://c.example/")
    clock.milliseconds = 100
    try h.call("setWindowFullScreen", [.string(b), true])
    clock.milliseconds = 200
    try h.call("setWindowFullScreen", [.string(a), true])
    let saved = try h.save()
    #expect(try row(saved, "windows", b)["fullScreen"] == 100)
    #expect(try row(saved, "windows", a)["fullScreen"] == 200)
    #expect(try row(saved, "windows", c)["fullScreen"] == nil)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows[b]?.fullScreen == 100)
    #expect(next.state.windows[a]?.fullScreen == 200)
    #expect(next.state.windows[c]?.fullScreen == nil)
  }

  @Test func keptWindowRestoresItsIDsActivePaneGroupsAndSplit() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let first = try #require(h.store.state.activeTabId(w))
    let second = try h.tab(w, "https://second.example/")
    let pin = try h.tab(w, "https://pin.example/")
    try h.call("pinTabs", [[.string(pin)], true])
    let group = try h.call("groupTabs", [[.string(first), .string(second)], ["name": "Reading", "pinned": false]])
    let split = try h.call("createSplit", [[.string(first), .string(second)], "vertical"])
    try h.call("activate", [.string(first)])
    try h.call("setWindowKeptOnClose", [.string(w), true])
    let saved = try h.save()
    #expect(try row(saved, "windows", w)["keptOnClose"] == true)
    #expect(saved["closedWindows"] == [])
    #expect(saved["parkedPins"] == [:])
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windowOrder == [w])
    #expect(next.state.activeTabId(w) == first)
    #expect(next.state.tabs.keys == h.store.state.tabs.keys)
    #expect(next.state.windows[w]?.tabIds == [pin, first, second])
    #expect(next.state.tabs[pin]?.pinned == true)
    #expect(next.state.groups[group]?.json == h.store.state.groups[group]?.json)
    #expect(next.state.splits[split]?.json == h.store.state.splits[split]?.json)
    #expect(next.state.windows[w]?.keptOnClose == nil)
    #expect(next.state.closedWindows.isEmpty && next.state.parkedPins.isEmpty)
  }

  @Test func startFreshRetainsOnlyTheKeptWindow() throws {
    let h = try RelaunchWorkspace()
    let kept = try h.window("https://kept.example/")
    let active = try #require(h.store.state.activeTabId(kept))
    let second = try h.tab(kept, "https://second.example/")
    let pin = try h.tab(kept, "https://pin.example/")
    try h.call("pinTabs", [[.string(pin)], true])
    try h.call("activate", [.string(active)])
    try h.call("setWindowKeptOnClose", [.string(kept), true])
    let ordinary = try h.window("https://ordinary.example/")
    try h.call("updateSettings", [["restoreSession": false]])
    let saved = try h.save()
    #expect(try row(saved, "windows", kept)["keptOnClose"] == true)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windowOrder == [kept])
    #expect(next.state.activeTabId(kept) == active)
    #expect(next.state.windows[kept]?.tabIds == [pin, active, second])
    #expect(next.state.tabs[second]?.url == "https://second.example/")
    #expect(next.state.tabs[pin]?.pinned == true)
    #expect(next.state.windows[kept]?.keptOnClose == nil)
    #expect(next.state.windows[ordinary] == nil)
    #expect(next.state.closedWindows.flatMap(\.tabs).map(\.snapshot.url) == ["https://ordinary.example/"])
  }

  @Test func revealedWindowFollowsStartFreshAgain() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    try h.call("setWindowKeptOnClose", [.string(w), true])
    try h.call("setWindowKeptOnClose", [.string(w), false])
    try h.call("updateSettings", [["restoreSession": false]])
    let saved = try h.save()
    #expect(try row(saved, "windows", w)["keptOnClose"] == nil)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows.isEmpty)
    #expect(next.state.closedWindows.count == 1)
    #expect(next.state.closedWindows[0].tabs.map(\.snapshot.url) == ["https://public.example/"])
  }

  @Test func launchHintMatchesTheRestoredActivePage() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://launch.example/")
    let id = try #require(h.store.state.activeTabId(w))
    try h.call("setFocusedWindow", [.string(w)])
    let saved = try h.save()
    #expect(saved["launchTab"] == ["id": .string(id), "url": "https://launch.example/", "profile": ""])
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.ui.focusedWindowId == w)
    #expect(next.state.activeTabId(w) == id)
    #expect(next.state.tabs[id]?.url == "https://launch.example/")
    #expect(next.state.engineProfile(next.state.tabs[id]!.profileId) == "")
  }

  @Test func onlyPublicRestoreWakeTokensSurviveRelaunch() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let restored = try #require(h.store.state.activeTabId(w))
    let transient = try h.tab(w, "https://transient.example/")
    let privateWindow = try h.window("https://secret.example/", ["incognito": true])
    let privateTab = try #require(h.store.state.activeTabId(privateWindow))
    try h.store.transact { s in s.update { state in
      state.tabs[restored]?.wakeAdoptId = "restore:public"
      state.tabs[restored]?.unloaded = true
      state.tabs[transient]?.wakeAdoptId = "tab:pending"
      state.tabs[privateTab]?.wakeAdoptId = "restore:private"
    } }
    let saved = try h.save()
    #expect(try row(saved, "tabs", restored)["wakeAdoptId"] == "restore:public")
    #expect(try row(saved, "tabs", transient)["wakeAdoptId"] == nil)
    #expect(!saved.text().contains("restore:private"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    let loaded = store(for: next)
    #expect(loaded.state.tabs[restored]?.wakeAdoptId == "restore:public")
    try loaded.dispatch(Command("activate", [.string(restored)]))
    #expect(loaded.state.tabs[restored]?.adoptId == "restore:public")
    #expect(loaded.state.tabs[transient]?.wakeAdoptId == nil)
    #expect(loaded.state.tabs[privateTab] == nil)
  }

  @Test func adoptedPageRelaunchesByURLWithoutItsAdoptionToken() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://adopted.example/")
    let id = try #require(h.store.state.activeTabId(w))
    try h.store.transact { s in s.update { $0.tabs[id]?.adoptId = "tab:engine-page" } }
    try h.call("setFocusedWindow", [.string(w)])
    let saved = try h.save()
    #expect(try row(saved, "tabs", id)["adoptId"] == nil)
    #expect(saved["launchTab"] == ["id": .string(id), "url": "https://adopted.example/", "profile": ""])
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[id]?.adoptId == nil)
    #expect(next.state.tabs[id]?.navigation?.url == "https://adopted.example/")
  }

  @Test func startFreshExportsNoLaunchHint() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    try h.call("setFocusedWindow", [.string(w)])
    try h.call("updateSettings", [["restoreSession": false]])
    #expect(try h.save()["launchTab"] == .null)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows.isEmpty)
  }

  @Test func startFreshArchivesEachWindowsOwnPresentation() throws {
    let h = try RelaunchWorkspace()
    let a = try h.window("https://a.example/")
    let b = try h.window("https://b.example/")
    try h.call("setWindowLayout", [.string(a), "top"])
    try h.call("setWindowSidebar", [.string(a), ["sidebarWidth": 240, "sidebarIconsOnly": false, "sidePanelWidth": 390]])
    try h.call("setWindowLayout", [.string(b), "sidebar"])
    try h.call("setWindowSidebar", [.string(b), ["sidebarWidth": 310, "sidebarIconsOnly": true, "sidePanelWidth": 480]])
    try h.call("updateSettings", [["restoreSession": false]])
    let saved = try h.save()
    #expect(try row(saved, "windows", a)["sidePanelWidth"] == 390)
    #expect(try row(saved, "windows", b)["sidePanelWidth"] == 480)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows.isEmpty)
    let first = try #require(next.state.closedWindows.first { $0.tabs.first?.snapshot.url == "https://a.example/" })
    let second = try #require(next.state.closedWindows.first { $0.tabs.first?.snapshot.url == "https://b.example/" })
    #expect(first.tabLayout == "top" && first.sidebarWidth == 240 && first.sidebarIconsOnly == false && first.sidePanelWidth == 390)
    #expect(second.tabLayout == "sidebar" && second.sidebarWidth == 310 && second.sidebarIconsOnly == true && second.sidePanelWidth == 480)
  }

  @Test func launchHintTracksNavigationSelectionClosingAndWindowChanges() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://first.example/")
    let first = try #require(h.store.state.activeTabId(w))
    try h.call("setFocusedWindow", [.string(w)])
    #expect(try h.save()["launchTab"]?["id"] == .string(first))
    try h.call("navigate", [.string(first), "https://navigated.example/"])
    try h.call("updateTab", [.string(first), ["url": "https://navigated.example/"]])
    #expect(try h.save()["launchTab"]?["url"] == "https://navigated.example/")
    let second = try h.tab(w, "https://second.example/")
    #expect(try h.save()["launchTab"]?["id"] == .string(second))
    try h.call("activate", [.string(first)])
    #expect(try h.save()["launchTab"]?["id"] == .string(first))
    try h.call("closeTab", [.string(first)])
    #expect(try h.save()["launchTab"]?["id"] == .string(second))
    let other = try h.window("https://other.example/")
    try h.call("setFocusedWindow", [.string(other)])
    #expect(try h.save()["launchTab"]?["url"] == "https://other.example/")
    let internalID = try #require(h.store.state.activeTabId(other))
    try h.call("navigate", [.string(internalID), "solara://settings"])
    try h.call("updateTab", [.string(internalID), ["url": "solara://settings"]])
    #expect(try h.save()["launchTab"] == .null)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.activeTabId(other) == internalID)
  }

  @Test func unflushedNavigationKeepsTheSavedSessionsHint() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://saved.example/")
    let id = try #require(h.store.state.activeTabId(w))
    try h.call("setFocusedWindow", [.string(w)])
    let hint: JSONValue = ["id": .string(id), "url": "https://saved.example/", "profile": ""]
    #expect(try h.save()["launchTab"] == hint)
    h.writer.freeze()
    try h.call("navigate", [.string(id), "https://unsaved.example/"])
    try h.call("updateTab", [.string(id), ["url": "https://unsaved.example/"]])
    #expect(h.store.state.tabs[id]?.url == "https://unsaved.example/")
    #expect(try h.launch.database.load().sessionJSON()?["launchTab"] == hint)
    #expect(try JSONValue.parse(Data(contentsOf: h.folder.session))["launchTab"] == hint)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[id]?.url == "https://saved.example/")
    #expect(next.state.activeTabId(w) == id)
  }

  @Test func linkProfileUsesTheLastPublicProfile() throws {
    let h = try RelaunchWorkspace()
    let work = try h.call("createProfile", [["name": "Work"]])
    try h.store.transact { s in s.update { $0.ui.lastProfileId = work } }
    #expect(try h.save()["linkProfile"] == .string(h.store.state.engineProfile(work)))
    try h.store.transact { s in s.update { $0.ui.lastProfileId = nil } }
    #expect(try h.save()["linkProfile"] == "")
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.profiles[work] != nil)
  }

  @Test func peekRowsNeverPersistOrReturnAtLaunch() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let source = try #require(h.store.state.activeTabId(w))
    let peek = try h.call("openPeek", [.string(source), "https://peek.example/"])
    #expect(h.store.state.tabs[peek] != nil)
    let saved = try h.save()
    #expect(saved["tabs"]?.array?.contains { $0["id"] == .string(peek) } == false)
    #expect(!saved.text().contains("peek.example"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows[w] != nil && next.state.tabs[source] != nil)
    #expect(next.state.tabs[peek] == nil && next.state.peeks.isEmpty)
  }

  @Test func mirroredPinsReturnInOrderInBothWindows() throws {
    let h = try RelaunchWorkspace()
    let a = try h.window("https://one.example/")
    let one = try #require(h.store.state.activeTabId(a))
    let two = try h.tab(a, "https://two.example/")
    try h.call("pinTabs", [[.string(one), .string(two)], true])
    let b = try h.window("https://other.example/")
    let saved = try h.save()
    #expect(try row(saved, "tabs", one)["pinned"] == true)
    let next = try h.reopen()
    defer { try? next.database.close() }
    for w in [a, b] { #expect(pinnedURLs(next.state, w) == ["https://one.example/", "https://two.example/"]) }
  }

  private func sharedPin(_ h: RelaunchWorkspace) throws -> (String, String, String, String) {
    let a = try h.window("https://shared.example/")
    let id = try #require(h.store.state.activeTabId(a))
    try h.call("pinTabs", [[.string(id)], true])
    let b = try h.window("https://other.example/")
    let copy = try #require(h.store.state.windows[b]?.tabIds.first { h.store.state.tabs[$0]?.pinned == true })
    try h.call("activate", [.string(copy)])
    return (b, a, id, copy)
  }

  @Test func frozenCopyExportsUnloadedWithoutItsPageLink() throws {
    let h = try RelaunchWorkspace()
    let (_, _, holder, copy) = try sharedPin(h)
    #expect(h.store.state.tabs[copy]?.pageIn == holder)
    let saved = try h.save()
    #expect(try row(saved, "tabs", copy)["pageIn"] == nil)
    #expect(try row(saved, "tabs", copy)["unloaded"] == true)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[copy] != nil)
    #expect(next.state.tabs.values.filter { $0.pinKeyOrId == holder && hasPage($0) }.count == 1)
  }

  @Test func sharedPinRestoresTwoCopiesWithExactlyOnePageHolder() throws {
    let h = try RelaunchWorkspace()
    let (a, b, holder, copy) = try sharedPin(h)
    let saved = try h.save()
    #expect(try row(saved, "tabs", holder)["id"] == .string(holder))
    #expect(try row(saved, "tabs", copy)["id"] == .string(copy))
    let next = try h.reopen()
    defer { try? next.database.close() }
    let copies = next.state.tabs.values.filter { $0.pinKeyOrId == holder }
    #expect(Set(copies.map(\.id)) == Set([holder, copy]))
    #expect(Set(copies.map(\.windowId)) == Set([a, b]))
    #expect(copies.filter { $0.unloaded != true && $0.pageIn == nil }.count == 1)
    let frozen = try #require(copies.first { $0.pageIn != nil })
    #expect(!hasPage(frozen))
    #expect(copies.contains { $0.id == frozen.pageIn && $0.pageIn == nil && $0.unloaded != true })
  }

  @Test func pinnedRowsKeepTheirKindsThroughRelaunchParkingAndReopening() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://tile.example/")
    let tile = try #require(h.store.state.activeTabId(w))
    let rowID = try h.tab(w, "https://row.example/")
    try h.call("pinTabs", [[.string(tile)], true])
    try h.call("pinTabs", [[.string(rowID)], true, true])
    let saved = try h.save()
    #expect(try row(saved, "tabs", rowID)["pinnedAsRow"] == true)
    let next = try h.reopen()
    defer { try? next.database.close() }
    let s = store(for: next)
    #expect(s.state.tabs[rowID]?.isPinnedRow == true)
    #expect(s.state.tabs[tile]?.isPinnedRow == false)
    try s.dispatch(Command("closeWindow", [.string(w)]))
    #expect(s.state.parkedPins["default"]?.tabs.map(\.snapshot.pinnedAsRow) == [nil, true])
    let reopened = try #require(try s.dispatch(Command("createWindow")).result?.string)
    #expect(pinnedURLs(s.state, reopened) == ["https://tile.example/", "https://row.example/"])
    #expect(s.state.windows[reopened]?.tabIds.compactMap { s.state.tabs[$0] }.filter(\.isPinnedRow).map(\.url) == ["https://row.example/"])
  }

  @Test func privateCurrentAndCleanedPagesNeverReachDisk() throws {
    let h = try RelaunchWorkspace()
    _ = try h.window()
    let w = try h.window("https://secret.example/current", ["incognito": true])
    let old = try h.tab(w, "https://secret.example/old")
    let current = try h.tab(w, "https://secret.example/current")
    try h.call("activate", [.string(current)])
    try h.call("updateTab", [.string(old), ["lastActiveAt": .number(now.timeIntervalSince1970 * 1000 - 8 * 86_400_000)]])
    try h.call("cleanUpTabs", [.string(w)])
    #expect(h.store.state.privateCleanedTabs[w]?.isEmpty == false)
    let saved = try h.save()
    #expect(saved.text().contains("public.example"))
    #expect(!saved.text().contains("secret.example"))
    try h.call("closeWindow", [.string(w)])
    #expect(try !h.save().text().contains("secret.example"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.privateCleanedTabs.isEmpty)
    #expect(next.state.tabs.values.map(\.url) == ["https://public.example/"])
  }

  @Test func legacyPrivateCleanedRowsArePurgedBeforeTheNextSave() throws {
    let folder = try scratchFolder()
    var legacy = try JSONValue.parse(legacySession).object!
    legacy["cleanedTabs"] = .array([try cleaned("ct-old", profile: "incognito:w-private").jsonValue, try cleaned("ct-ok").jsonValue])
    try write(JSONValue.object(legacy).text(), to: folder.session)
    let h = try RelaunchWorkspace(folder: folder)
    #expect(h.store.state.cleanedTabs.map(\.id) == ["ct-ok"])
    _ = try h.window()
    let saved = try h.save()
    #expect(saved["cleanedTabs"]?.array?.compactMap { $0["id"]?.string } == ["ct-ok"])
    #expect(!saved.text().contains("secret.example"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.cleanedTabs.map(\.id) == ["ct-ok"])
  }

  @Test func cleanedEntriesExpireAtLaunchWithoutDroppingRecentEntries() throws {
    let h = try RelaunchWorkspace()
    let start = now.timeIntervalSince1970 * 1000
    let old = try cleaned("ct-stale", at: start)
    let recent = try cleaned("ct-recent", at: start + 7 * 86_400_000)
    try h.store.transact { s in s.update { $0.cleanedTabs = [old, recent] } }
    let saved = try h.save()
    #expect(saved["cleanedTabs"]?.array?.compactMap { $0["id"]?.string } == ["ct-stale", "ct-recent"])
    let next = try h.reopen(at: start + 8 * 86_400_000)
    defer { try? next.database.close() }
    #expect(next.state.cleanedTabs.map(\.id) == ["ct-recent"])
  }

  @Test func privateArchivesAndParkedPinsAreFilteredFromEveryList() throws {
    let h = try RelaunchWorkspace()
    _ = try h.window()
    let privateProfile = "incognito:w-x"
    let stamp = now.timeIntervalSince1970 * 1000
    let privateTab = try cleaned("private-tab", profile: privateProfile)
    let publicTab = try cleaned("public-tab")
    func group(_ id: String, _ profile: String) throws -> ClosedGroup {
      try ClosedGroup(json: ["kind": "group", "id": .string(id), "group": ["id": "g", "name": "Saved", "pinned": false], "tabs": [snapshot(profile, profile == "default" ? "https://public.example/" : "https://secret.example/")], "windowId": "gone", "index": 0, "closedAt": .number(stamp)])
    }
    func window(_ id: String, _ profile: String) throws -> ClosedWindow {
      var tab = snapshot(profile, profile == "default" ? "https://public.example/" : "https://secret.example/").object!
      tab["active"] = true
      return try ClosedWindow(json: ["kind": "window", "id": .string(id), "window": ["profileId": .string(profile), "sidebarOpen": true, "frame": .null], "tabs": [.object(tab)], "groups": [], "closedAt": .number(stamp)])
    }
    func park(_ profile: String) throws -> ParkedPins {
      var tab = snapshot(profile, profile == "default" ? "https://public.example/" : "https://secret.example/").object!
      tab["id"] = "parked"
      tab["pinned"] = true
      return try ParkedPins(json: ["tabs": [.object(tab)], "groups": []])
    }
    let publicWindow = try window("public-window", "default")
    let privateWindow = try window("private-window", privateProfile)
    let publicGroup = try group("public-group", "default")
    let privateGroup = try group("private-group", privateProfile)
    let publicPark = try park("default")
    let privatePark = try park(privateProfile)
    try h.store.transact { s in s.update { state in
      state.closedTabs = [publicTab, privateTab]
      state.closedWindows = [publicWindow, privateWindow]
      state.closedGroups = [publicGroup, privateGroup]
      state.deletedGroups = [publicGroup, privateGroup]
      state.parkedPins["default"] = publicPark
      state.parkedPins[privateProfile] = privatePark
    } }
    let saved = try h.save()
    #expect(!saved.text().contains("secret.example"))
    #expect(!saved.text().contains("incognito:"))
    for key in ["closedTabs", "closedWindows", "closedGroups", "deletedGroups"] {
      #expect(saved[key]?.array?.count == 1)
      #expect(saved[key]?.text().contains("public.example") == true)
    }
    #expect(saved["parkedPins"]?["default"]?["tabs"]?.array?.count == 1)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.closedTabs.map(\.id) == ["public-tab"])
    #expect(next.state.closedWindows.map(\.id) == ["public-window"])
    #expect(next.state.closedGroups.map(\.id) == ["public-group"])
    #expect(next.state.deletedGroups.map(\.id) == ["public-group"])
    #expect(next.state.parkedPins[privateProfile] == nil)
  }

  private func downloads(_ h: RelaunchWorkspace, privateCount: Int) throws {
    _ = try h.window()
    try h.call("upsertDownload", [["id": "regular2", "url": "https://files.example/regular2", "state": "finished", "profile": ""]])
    for i in 0..<privateCount {
      let w = try h.window("https://secret.example/\(i)", ["incognito": true])
      let profile = try #require(h.store.state.windows[w]?.profileId)
      try h.call("upsertDownload", [["id": .string("secret\(i)"), "url": .string("https://secret.example/download\(i)"), "state": "finished", "profile": .string(profile)]])
    }
    #expect(h.store.state.downloads.filter(\.isPrivate).count == privateCount)
  }

  private func assertPublicDownload(_ h: RelaunchWorkspace) throws {
    _ = try h.save()
    let persisted = try h.launch.database.load()
    #expect(persisted.downloads.map { $0.json["id"] } == ["regular2"])
    let shadow = try JSONValue.parse(Data(contentsOf: h.folder.downloads))
    #expect(shadow["downloads"]?.array?.compactMap { $0["id"]?.string } == ["regular2"])
    #expect(!shadow.text().contains("secret"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.downloads.count == 1)
    #expect(next.state.downloads[0].json["id"] == "saved-0")
    #expect(next.state.downloads[0].json["url"] == "https://files.example/regular2")
  }

  @Test func privateDownloadsStayOffDiskAndPublicDownloadsReload() throws {
    let h = try RelaunchWorkspace()
    try downloads(h, privateCount: 1)
    try assertPublicDownload(h)
  }

  @Test func privateFaviconAndPageURLsNeverLeakIntoWorkspaceDocuments() throws {
    let h = try RelaunchWorkspace()
    _ = try h.window()
    let w = try h.window("https://secret.example/", ["incognito": true])
    let id = try #require(h.store.state.activeTabId(w))
    try h.call("updateTab", [.string(id), ["favicon": "https://secret.example/icon.png"]])
    let saved = try h.save()
    #expect(saved.text().contains("public.example"))
    #expect(!saved.text().contains("secret.example"))
    #expect(try !String(contentsOf: h.folder.session, encoding: .utf8).contains("secret.example"))
    #expect(try !String(contentsOf: h.folder.downloads, encoding: .utf8).contains("secret.example"))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[id] == nil)
  }

  @MainActor @Test func failedProfileDeletionStaysQueuedUntilARelaunchRetrySucceeds() async throws {
    let h = try RelaunchWorkspace()
    try h.store.transact { s in s.update { state in
      state.profiles["default"]?.dataId = "active-data"
      state.orphanedProfileData = [""]
    } }
    var attempts: [String] = []
    let failure = ProfileDataCleanup(store: h.store, delete: { engine, done in attempts.append(engine); done(["WebKit data"]) }, grace: {})
    failure.start()
    await failure.task?.value
    failure.stop()
    #expect(attempts == [""])
    #expect(try h.save()["orphanedProfileData"] == [""])
    let next = try h.reopen()
    let s = store(for: next)
    let writer = PersistenceWriter(store: s, database: next.database, folder: h.folder, persisted: next.persisted)
    defer { writer.freeze(); try? next.database.close() }
    #expect(s.state.orphanedProfileData == [""])
    let success = ProfileDataCleanup(store: s, delete: { engine, done in attempts.append(engine); done([]) }, grace: {})
    success.start()
    await success.task?.value
    success.stop()
    #expect(attempts == ["", ""])
    #expect(s.state.orphanedProfileData.isEmpty)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try next.database.load().sessionJSON()?["orphanedProfileData"] == [])
    writer.freeze()
    try next.database.close()
    let third = try open(h.folder)
    defer { try? third.database.close() }
    #expect(third.state.orphanedProfileData.isEmpty)
  }

  @Test func twoPrivateSessionsExportOnlyThePublicDownload() throws {
    let h = try RelaunchWorkspace()
    try downloads(h, privateCount: 2)
    try assertPublicDownload(h)
  }

  @Test func privateWindowTabAndProfileIDsNeverPersist() throws {
    let h = try RelaunchWorkspace()
    let work = try h.call("createProfile", [["name": "Work"]])
    _ = try h.window("https://public.example/", ["profileId": .string(work)])
    var privateWindows: [String] = []
    var privateTabs: [String] = []
    for _ in 0..<2 {
      let w = try h.window("https://secret.example/", ["incognito": true])
      privateWindows.append(w)
      privateTabs.append(try #require(h.store.state.activeTabId(w)))
    }
    let saved = try h.save()
    #expect(saved["profiles"]?[work] != nil)
    #expect(!saved.text().contains("secret.example"))
    #expect(!saved.text().contains("incognito:"))
    for id in privateWindows + privateTabs { #expect(!saved.text().contains("\"\(id)\"")) }
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.profiles[work] != nil)
    for id in privateWindows { #expect(next.state.windows[id] == nil) }
    for id in privateTabs { #expect(next.state.tabs[id] == nil) }
  }

  @Test func parkedPinsAndGroupsReturnInOrderUnloadedAfterRelaunch() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://tile.example/")
    let tile = try #require(h.store.state.activeTabId(w))
    let member = try h.tab(w, "https://member.example/")
    try h.call("pinTabs", [[.string(tile)], true])
    try h.call("groupTabs", [[.string(member)], ["name": "Pinned", "pinned": true]])
    try h.call("closeWindow", [.string(w)])
    let expected = h.store.state.parkedPins["default"]!.tabs.map(\.snapshot.url)
    let saved = try h.save()
    #expect(saved["parkedPins"]?["default"]?["tabs"]?.array?.compactMap { $0["url"]?.string } == expected)
    let next = try h.reopen()
    defer { try? next.database.close() }
    let s = store(for: next)
    #expect(s.state.windows.isEmpty)
    let reopened = try #require(try s.dispatch(Command("createWindow")).result?.string)
    let tabs = try #require(s.state.windows[reopened]).tabIds.compactMap { s.state.tabs[$0] }
    #expect(Array(tabs.prefix(2)).map(\.url) == expected)
    #expect(tabs.prefix(2).allSatisfy { $0.unloaded == true })
    #expect(s.state.groups.values.contains { $0.windowId == reopened && $0.name == "Pinned" && $0.tabIds.count == 1 })
  }

  @Test func placeholderRowsReferencesAndLaunchHintAreAbsent() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("")
    let placeholder = try h.call("newTab", [.string(w), ["newTabCommand": true]])
    try h.call("setFocusedWindow", [.string(w)])
    #expect(h.store.state.tabs[placeholder]?.newTabPlaceholder == true)
    let saved = try h.save()
    #expect(saved["tabs"]?.array?.contains { $0["id"] == .string(placeholder) } == false)
    #expect(try row(saved, "windows", w)["tabIds"]?.array?.contains(.string(placeholder)) == false)
    #expect(try row(saved, "windows", w)["activeTabIds"]?.object?.values.contains(.string(placeholder)) == false)
    #expect(saved["launchTab"] == .null)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[placeholder] == nil)
  }

  @Test func settledEmptyTabsSurvivePersistenceAndRelaunch() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let empty = try h.call("newTab", [.string(w), ["newTabCommand": true]])
    try h.call("settleNewTab", [.string(empty)])
    #expect(h.store.state.tabs[empty]?.url == "")
    let saved = try h.save()
    #expect(try row(saved, "tabs", empty)["url"] == "")
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[empty]?.url == "")
    #expect(next.state.windows[w]?.tabIds.contains(empty) == true)
  }

  @Test func activeTabBeforeThePlaceholderIsPersistedAndRestored() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let second = try h.tab(w, "https://second.example/")
    try h.store.transact { s in s.update { $0.tabs[second]?.shownAt = now.timeIntervalSince1970 * 1000 + 1 } }
    let placeholder = try h.call("newTab", [.string(w), ["newTabCommand": true]])
    #expect(h.store.state.activeTabId(w) == placeholder)
    let saved = try h.save()
    #expect(try row(saved, "windows", w)["activeTabIds"]?["default"] == .string(second))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.activeTabId(w) == second)
  }

  @Test func sidebarRailPreferenceRetainsTheFullWidth() throws {
    let h = try RelaunchWorkspace()
    try h.call("updateSettings", [["sidebarIconsOnly": true, "sidebarWidth": 260]])
    _ = try h.save()
    #expect(try h.launch.database.load().settings?["sidebarIconsOnly"] == true)
    #expect(try h.launch.database.load().settings?["sidebarWidth"] == 260)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.settings["sidebarIconsOnly"] == true)
    #expect(next.state.settings["sidebarWidth"] == 260)
  }

  @Test func lastPublicProfileAndFocusSurvivePrivateFocusAndRelaunch() throws {
    let h = try RelaunchWorkspace()
    _ = try h.window()
    let work = try h.call("createProfile", [["name": "Work"]])
    let b = try h.window("https://work.example/", ["profileId": .string(work)])
    try h.call("setFocusedWindow", [.string(b)])
    let privateWindow = try h.window("https://secret.example/", ["incognito": true])
    try h.call("setFocusedWindow", [.string(privateWindow)])
    let saved = try h.save()
    #expect(saved["lastProfileId"] == .string(work))
    #expect(saved["focusedWindowId"] == .string(b))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.ui.lastProfileId == work)
    #expect(next.state.ui.focusedWindowId == b)
    let s = store(for: next)
    let little = try #require(try s.dispatch(Command("createWindow", [["small": true]])).result?.string)
    #expect(s.state.windows[little]?.profileId == work)
  }

  @Test func sidebarPinnedTabReturnsPinnedAndActive() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window()
    let id = try #require(h.store.state.activeTabId(w))
    try h.call("pinTabs", [[.string(id)], true])
    try h.call("activate", [.string(id)])
    let saved = try h.save()
    #expect(try row(saved, "tabs", id)["pinned"] == true)
    #expect(try row(saved, "windows", w)["activeTabIds"]?["default"] == .string(id))
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.tabs[id]?.pinned == true)
    #expect(next.state.activeTabId(w) == id)
  }

  @Test func tileFoldersKeepMembershipOrderAndNameThroughRelaunchAndParking() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://mail.example/")
    let mail = try #require(h.store.state.activeTabId(w))
    let unrelated = try h.tab(w, "https://unrelated.example/")
    let cal = try h.tab(w, "https://cal.example/")
    let other = try h.tab(w, "https://other.example/")
    try h.call("pinTabs", [[.string(mail), .string(unrelated), .string(cal), .string(other)], true])
    try h.store.transact { s in s.update { state in
      state.tabs[mail]?.tileFolder = try? TileFolder(json: ["id": "mail-cal", "name": "Mail & Cal", "renamedAt": 3])
      state.tabs[cal]?.tileFolder = try? TileFolder(json: ["id": "mail-cal", "name": "Mail & Cal", "renamedAt": 3])
    } }
    let saved = try h.save()
    for id in [mail, cal] { #expect(try row(saved, "tabs", id)["tileFolder"]?["name"] == "Mail & Cal") }
    let next = try h.reopen()
    defer { try? next.database.close() }
    let s = store(for: next)
    let urls = ["https://mail.example/", "https://unrelated.example/", "https://cal.example/", "https://other.example/"]
    #expect(s.state.windows[w]?.tabIds == [mail, unrelated, cal, other])
    #expect(pinnedURLs(s.state, w) == urls)
    for id in [mail, cal] { #expect(s.state.tabs[id]?.tileFolder?.name == "Mail & Cal") }
    for id in [unrelated, other] { #expect(s.state.tabs[id]?.tileFolder == nil) }
    let mixed = s.state.windows[w]!.tabIds.reduce(into: [String]()) { order, id in
      let key = s.state.tabs[id]?.tileFolder?.id ?? id
      if !order.contains(key) { order.append(key) }
    }
    #expect(mixed == ["mail-cal", unrelated, other])
    try s.dispatch(Command("closeWindow", [.string(w)]))
    #expect(s.state.parkedPins["default"]?.tabs.map(\.snapshot.tileFolder?.name) == ["Mail & Cal", nil, "Mail & Cal", nil])
    let reopened = try #require(try s.dispatch(Command("createWindow")).result?.string)
    #expect(pinnedURLs(s.state, reopened) == urls)
    let members = s.state.windows[reopened]!.tabIds.compactMap { s.state.tabs[$0] }.filter(\.pinned)
    #expect(members.map(\.tileFolder?.id) == ["mail-cal", nil, "mail-cal", nil])
    #expect(members.map(\.tileFolder?.name) == ["Mail & Cal", nil, "Mail & Cal", nil])
  }

  @Test func sidebarVisibilityIsWindowLocalAfterRelaunch() throws {
    let h = try RelaunchWorkspace()
    let a = try h.window("https://a.example/")
    let b = try h.window("https://b.example/")
    try h.call("toggleSidebar", [.string(a)])
    let saved = try h.save()
    #expect(try row(saved, "windows", a)["sidebarOpen"] == false)
    #expect(try row(saved, "windows", b)["sidebarOpen"] == true)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows[a]?.sidebarOpen == false)
    #expect(next.state.windows[b]?.sidebarOpen == true)
  }

  @Test func showingTheSidebarAgainSurvivesASecondRelaunch() throws {
    let h = try RelaunchWorkspace()
    let a = try h.window()
    try h.call("toggleSidebar", [.string(a)])
    #expect(try row(h.save(), "windows", a)["sidebarOpen"] == false)
    let first = try h.reopen()
    try first.database.close()
    let second = try RelaunchWorkspace(folder: h.folder)
    #expect(second.store.state.windows[a]?.sidebarOpen == false)
    try second.call("toggleSidebar", [.string(a)])
    #expect(try row(second.save(), "windows", a)["sidebarOpen"] == true)
    let last = try second.reopen()
    defer { try? last.database.close() }
    #expect(last.state.windows[a]?.sidebarOpen == true)
  }

  @Test func closedHiddenSidebarReopensHiddenAfterRelaunch() throws {
    let h = try RelaunchWorkspace()
    let a = try h.window("https://hidden.example/")
    _ = try h.window("https://other.example/")
    try h.call("toggleSidebar", [.string(a)])
    try h.call("closeWindow", [.string(a)])
    let saved = try h.save()
    #expect(saved["windows"]?.array?.contains { $0["id"] == .string(a) } == false)
    #expect(saved["closedWindows"]?.array?.first?["window"]?["sidebarOpen"] == false)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.windows[a] == nil)
    let s = store(for: next)
    let archive = try #require(s.state.closedWindows.first)
    try s.dispatch(Command("restoreClosed", [.string(archive.id)]))
    let reopened = try #require(s.state.windows.values.first { w in w.tabIds.contains { s.state.tabs[$0]?.url == "https://hidden.example/" } })
    #expect(reopened.sidebarOpen == false)
  }

  private func records(_ state: BrowserState, base: JSONObject = [:], at: Double = 0) throws -> JSONObject {
    let extraction = try PinnedSync.pinnedValues(state, "default", PinnedLookups(base: { base[$0] }, now: at))
    return JSONObject(extraction.values.map { ($0.key, $0.value) })
  }

  private func apply(_ s: Store, _ records: JSONObject, at: Double = 0, horizon: Double = 90 * 86_400_000) throws {
    let visible = records.map { JSONValue.array([.string($0.key), $0.value]) }
    try s.dispatch(Command("syncPinsApply", ["default", ["kind": "pins", "visible": .array(visible), "changed": JSONValue(records.keys), "base": .object(records), "known": JSONValue(records.keys), "now": .number(at), "horizon": .number(horizon)]]), origin: .sync, fromSync: true)
  }

  private func expectOwnership(_ state: BrowserState) {
    for window in state.windows.values {
      #expect(Set(window.tabIds).count == window.tabIds.count)
      for id in window.tabIds { #expect(state.tabs[id]?.windowId == window.id) }
      for id in window.activeTabIds.values { #expect(window.tabIds.contains(id)) }
    }
    for group in state.groups.values {
      for id in group.tabIds { #expect(state.tabs[id]?.windowId == group.windowId) }
    }
    for split in state.splits.values {
      for id in split.tabIds { #expect(state.tabs[id]?.windowId == split.windowId) }
    }
  }

  @Test func syncWorkspaceMetadataAndStructureSurviveRelaunch() throws {
    let h = try RelaunchWorkspace()
    let w = try h.window("https://tile.example/")
    let tile = try #require(h.store.state.activeTabId(w))
    try h.call("pinTabs", [[.string(tile)], true])
    let left = try h.tab(w, "https://left.example/")
    let right = try h.tab(w, "https://right.example/")
    try h.call("groupTabs", [[.string(left), .string(right)], ["name": "Pinned", "pinned": true]])
    try h.call("createSplit", [[.string(left), .string(right)], "vertical"])
    _ = try h.window("https://mirror.example/")
    let metadata: JSONValue = ["g": "pending-parent", "w": 123456]
    try h.store.transact { s in s.update { $0.pinSync["default"] = [tile: metadata] } }
    let expected = h.store.state
    let saved = try h.save()
    #expect(saved["pinSync"]?["default"]?[tile] == metadata)
    let next = try h.reopen()
    defer { try? next.database.close() }
    #expect(next.state.pinSync["default"]?[tile] == metadata)
    expectOwnership(next.state)
    #expect(next.state.windowOrder == expected.windowOrder)
    #expect(next.state.groups.keys == expected.groups.keys)
    #expect(next.state.splits.keys == expected.splits.keys)
    for g in expected.groups.values { #expect(next.state.groups[g.id]?.json == g.json) }
    for split in expected.splits.values { #expect(next.state.splits[split.id]?.json == split.json) }
    for w in expected.windows.values { #expect(next.state.windows[w.id]?.tabIds == w.tabIds) }
  }

  @Test func waitingGroupMetadataSurvivesUntilExpiryAndStandalonePinSurvivesAgain() throws {
    let h = try RelaunchWorkspace()
    _ = try h.window()
    let start = now.timeIntervalSince1970 * 1000
    let value: JSONValue = ["g": "never-seen", "u": "https://wait.example/", "t": .null, "i": .null, "ti": "Wait", "pos": "V"]
    let scope: JSONObject = ["pin:t:wait": value]
    try apply(h.store, scope, at: start)
    #expect(h.store.state.pinSync["default"]?["wait"]?["g"] == "never-seen")
    let saved = try h.save()
    #expect(saved["pinSync"]?["default"]?["wait"] == ["g": "never-seen", "w": .number(start + 90 * 86_400_000)])
    let first = try h.reopen(at: start + 89 * 86_400_000)
    let s = store(for: first)
    let writer = PersistenceWriter(store: s, database: first.database, folder: h.folder, persisted: first.persisted)
    defer { writer.freeze(); try? first.database.close() }
    let day89 = try records(s.state, base: scope, at: start + 89 * 86_400_000)
    #expect(day89["pin:t:wait"]?["g"] == "never-seen")
    let day91 = try records(s.state, base: day89, at: start + 91 * 86_400_000)
    #expect(day91["pin:t:wait"]?["g"] == .null)
    try apply(s, day91, at: start + 91 * 86_400_000)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try first.database.load().sessionJSON()?["pinSync"]?["default"]?["wait"]?["g"] == nil)
    writer.freeze()
    try first.database.close()
    let second = try Launcher.open(h.folder, appVersion: "1.0", now: now, context: LoadContext(memory: StoreMemory(ids: IdSource(launch: "expired")), now: start + 91 * 86_400_000))
    defer { try? second.database.close() }
    #expect(try records(second.state, base: day91, at: start + 91 * 86_400_000)["pin:t:wait"]?["g"] == .null)
    #expect(second.state.tabs.values.contains { $0.pinKeyOrId == "wait" && $0.pinned })
    expectOwnership(second.state)
  }
}
