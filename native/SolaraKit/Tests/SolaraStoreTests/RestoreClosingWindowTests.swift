import SolaraModel
import SolaraStore
import Testing

private func closeSnapshot(_ state: BrowserState, _ id: String) -> JSONValue {
  let window = state.windows[id]!
  return [
    "window": .object(window.json),
    "tabs": .array(window.tabIds.map { .object(state.tabs[$0]!.json) }),
    "groups": .array(state.groups.values.filter { $0.windowId == id }.map { .object($0.json) }),
    "splits": .array(state.splits.values.filter { $0.windowId == id }.map { .object($0.json) }),
  ]
}

@Suite struct RestoreClosingWindowTests {
  @Test func nativeWindowLocalsReturnUnderTheNewWindowIdWhileUnrelatedChangesSurvive() throws {
    let store = makeStore()
    let other = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    let otherTab = store.state.windows[other]!.tabIds[0]
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let first = store.state.windows[window]!.tabIds[0]
    let second = try store.dispatch(Command("newTab", [.string(window), ["url": "https://b.example/"]])).result!.string!
    try store.dispatch(Command("setSelection", [.string(window), [.string(second), .string(first)]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(first)]))
    try store.dispatch(Command("openPanel", [.string(window), "keep this text", ["profileId": "default"]]))
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.selection[window] == nil)
    #expect(store.state.selectionAnchors[window] == nil)
    #expect(store.state.windowUi[window] == nil)
    try store.dispatch(Command("setSelection", [.string(other), [.string(otherTab)]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(other), .string(otherTab)]))
    try store.dispatch(Command("openPanel", [.string(other), "newer panel"]))
    try store.dispatch(Command("setDownloadsOpen", [.string(other), true]))
    let unrelated = store.state
    let result = try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(first), .string(second)]]))
    let restored = try #require(result.result?.string)
    #expect(restored != window)
    #expect(store.state.selection[restored] == before.selection[window])
    #expect(store.state.selectionAnchors[restored] == before.selectionAnchors[window])
    #expect(store.state.windowUi[restored] == before.windowUi[window])
    #expect(store.state.selection[window] == nil)
    #expect(store.state.selectionAnchors[window] == nil)
    #expect(store.state.windowUi[window] == nil)
    #expect(store.state.selection[other] == unrelated.selection[other])
    #expect(store.state.selectionAnchors[other] == unrelated.selectionAnchors[other])
    #expect(store.state.windowUi[other] == unrelated.windowUi[other])
    for slice in ["selection", "selectionAnchors", "windowUi"] {
      #expect(result.patch.json[slice]?["upsert"]?.array?.contains { $0["windowId"] == .string(restored) } == true)
      #expect(!store.sessionDocument().json().object!.keys.contains(slice))
    }
  }

  @Test(arguments: [false, true]) func partialRestoreDropsMissingSelectionAndAnchorWithoutChangingWindowUi(anchorOnPin: Bool) throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://pin.example/"]])).result!.string!
    let pin = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [[.string(pin)], true]))
    let missing = try store.dispatch(Command("newTab", [.string(window), ["url": "https://missing.example/"]])).result!.string!
    let live = try store.dispatch(Command("newTab", [.string(window), ["url": "https://live.example/"]])).result!.string!
    try store.dispatch(Command("setSelection", [.string(window), [.string(pin), .string(missing), .string(live)]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(anchorOnPin ? pin : missing)]))
    try store.dispatch(Command("openPanel", [.string(window), "partial panel"]))
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let result = try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(live)]]))
    let restored = try #require(result.result?.string)
    #expect(store.state.tabs[pin]?.unloaded == true)
    #expect(store.state.tabs[missing] == nil)
    #expect(store.state.selection[restored]?.ids == [live])
    #expect(store.state.selectionAnchors[restored] == nil)
    #expect(store.state.windowUi[restored] == before.windowUi[window])
    #expect(result.patch.json["selection"]?["upsert"]?.array == [["windowId": .string(restored), "ids": [.string(live)]]])
  }

  @Test func partialRestoreDropsEmptySelectionAndKeepsLiveAnchor() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://missing.example/"]])).result!.string!
    let missing = store.state.windows[window]!.tabIds[0]
    let live = try store.dispatch(Command("newTab", [.string(window), ["url": "https://live.example/"]])).result!.string!
    try store.dispatch(Command("setSelection", [.string(window), [.string(missing)]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(live)]))
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(live)]])).result?.string)
    #expect(store.state.selection[restored] == nil)
    #expect(store.state.selectionAnchors[restored]?.tabId == live)
  }

  @Test(arguments: ["selection", "selectionAnchors", "windowUi"]) func conflictingNativeWindowLocalRefusesWithoutConsumingUndo(slice: String) throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setSelection", [.string(window), [.string(tab)]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(tab)]))
    try store.dispatch(Command("openPanel", [.string(window), "before"]))
    let original = store.state
    let snapshot = closeSnapshot(original, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update {
      switch slice {
      case "selection": $0.selection[window] = TabSelection(["newer"])
      case "selectionAnchors": $0.selectionAnchors[window] = SelectionAnchor("newer")
      default: $0.windowUi[window] = WindowUi(json: ["panel": ["open": true, "initialText": "newer"]])
      }
    } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]])).result == .null)
    #expect(store.state == before)
    try store.transact { session in session.update {
      $0.selection[window] = nil
      $0.selectionAnchors[window] = nil
      $0.windowUi[window] = nil
    } }
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.selection[restored] == original.selection[window])
    #expect(store.state.selectionAnchors[restored] == original.selectionAnchors[window])
    #expect(store.state.windowUi[restored] == original.windowUi[window])
  }

  @Test func nativeFindReturnsWhileNewerAppearanceAndUnrelatedFindSurvive() throws {
    let store = makeStore()
    let other = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    let otherTab = store.state.windows[other]!.tabIds[0]
    try store.dispatch(Command("setFind", [.string(otherTab), ["query": "before"]]))
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setFind", [.string(tab), ["open": true, "query": "needle", "count": 3, "active": 2]]))
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.find[tab] == nil)
    try store.dispatch(Command("setAppDark", [.bool(!before.ui.appDark)]))
    try store.dispatch(Command("setFind", [.string(otherTab), ["query": "newer"]]))
    let unrelated = store.state.find[otherTab]
    let result = try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]]))
    let restored = try #require(result.result?.string)
    #expect(store.state.find[tab] == before.find[tab])
    #expect(store.state.find[otherTab] == unrelated)
    #expect(store.state.ui.appDark == !before.ui.appDark)
    #expect(store.state.ui.focusedWindowId == restored)
    #expect(store.state.ui.focusOrder == before.ui.focusOrder.map { $0 == window ? restored : $0 })
    #expect(store.state.ui.lastProfileId == before.ui.lastProfileId)
    #expect(result.patch.json["find"]?["upsert"]?.array?.contains { $0["tabId"] == .string(tab) } == true)
    #expect(!store.sessionDocument().json().object!.keys.contains("find"))
  }

  @Test func partialRestoreDropsFindForMissingTabsAndUnloadedPins() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://pin.example/"]])).result!.string!
    let pin = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [[.string(pin)], true]))
    let missing = try store.dispatch(Command("newTab", [.string(window), ["url": "https://missing.example/"]])).result!.string!
    let live = try store.dispatch(Command("newTab", [.string(window), ["url": "https://live.example/"]])).result!.string!
    for tab in [pin, missing, live] {
      try store.dispatch(Command("setFind", [.string(tab), ["open": true, "query": .string(tab)]]))
    }
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let result = try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(live)]]))
    #expect(result.result?.string != nil)
    #expect(store.state.tabs[pin]?.unloaded == true)
    #expect(store.state.tabs[missing] == nil)
    #expect(store.state.find[pin] == nil)
    #expect(store.state.find[missing] == nil)
    #expect(store.state.find[live] == before.find[live])
    #expect(result.patch.json["find"]?["upsert"]?.array?.count == 1)
  }

  @Test func conflictingNativeFindRefusesWithoutConsumingUndo() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setFind", [.string(tab), ["query": "before"]]))
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update { $0.find[tab] = FindState(json: ["query": "newer"]) } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]])).result == .null)
    #expect(store.state == before)
    try store.transact { session in session.update { $0.find.removeValue(forKey: tab) } }
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]])).result?.string != nil)
    #expect(store.state.find[tab]?.json["query"] == "before")
  }

  @Test func pinsGroupsAndSplitKeepTheirIdsExactlyOnce() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://tile.example/"]])).result!.string!
    let tile = store.state.windows[window]!.tabIds[0]
    var ids = [tile]
    for host in ["row", "member", "a", "b"] {
      ids.append(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).example/")]])).result!.string!)
    }
    try store.dispatch(Command("pinTabs", [.array([.string(tile)]), true]))
    try store.dispatch(Command("pinTabs", [.array([.string(ids[1])]), true, true]))
    let pinned = try store.dispatch(Command("groupTabs", [.array([.string(ids[2])]), ["pinned": true, "name": "Pinned"]])).result!.string!
    let regular = try store.dispatch(Command("groupTabs", [.array(ids.suffix(2).map(JSONValue.string)), ["pinned": false, "name": "Regular"]])).result!.string!
    let split = try store.dispatch(Command("createSplit", [.array(ids.suffix(2).map(JSONValue.string)), "vertical"])).result!.string!
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.parkedPins[before.windows[window]!.profileId]?.tabs.count == 3)
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result?.string)
    let state = store.state
    #expect(state.windows[restored]?.tabIds == before.windows[window]?.tabIds)
    #expect(state.windows[restored]?.profileId == before.windows[window]?.profileId)
    #expect(state.windows[restored]?.kind == before.windows[window]?.kind)
    #expect(state.windowOrder == before.windowOrder.map { $0 == window ? restored : $0 })
    #expect(state.ui.focusOrder == before.ui.focusOrder.map { $0 == window ? restored : $0 })
    #expect(state.ui.focusedWindowId == restored)
    #expect(state.ui.lastProfileId == before.ui.lastProfileId)
    for id in ids {
      #expect(state.tabs.values.filter { $0.id == id }.count == 1)
      #expect(state.windows.values.flatMap(\.tabIds).filter { $0 == id }.count == 1)
      #expect(!state.parkedPins.values.flatMap(\.tabs).contains { $0.id == id })
      #expect(!state.closedTabs.contains { $0.tabId == id })
      #expect(!state.closedWindows.flatMap(\.tabs).contains { $0.tabId == id })
    }
    for id in [pinned, regular] {
      #expect(state.groups.values.filter { $0.id == id }.count == 1)
      #expect(state.groups[id]?.windowId == restored)
      #expect(!state.parkedPins.values.flatMap(\.groups).contains { $0.id == id })
    }
    #expect(state.splits.values.filter { $0.id == split }.count == 1)
    #expect(state.splits[split]?.windowId == restored)
    #expect(state.parkedPins == before.parkedPins)
  }

  @Test func onlyLiveTabsReturnAndOtherPagesRemainReopenable() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    var ids = store.state.windows[window]!.tabIds
    for host in ["b", "c"] {
      ids.append(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).example/")]])).result!.string!)
    }
    let group = try store.dispatch(Command("groupTabs", [.array(ids.map(JSONValue.string)), ["pinned": false, "name": "Group"]])).result!.string!
    let split = try store.dispatch(Command("createSplit", [.array(ids.map(JSONValue.string)), "vertical"])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array([.string(ids[0])])])).result?.string)
    #expect(store.state.windows[restored]?.tabIds == [ids[0]])
    #expect(store.state.windows[restored]?.activeTabIds["default"] == ids[0])
    #expect(store.state.tabs.keys == [ids[0]])
    #expect(store.state.groups[group]?.tabIds == [ids[0]])
    #expect(store.state.splits[split] == nil)
    #expect(store.state.closedTabs.compactMap(\.tabId) == Array(ids.suffix(2)))
    #expect(store.state.closedTabs.allSatisfy { $0.group?.id == group && $0.windowId == restored })
    #expect(store.state.closedWindows.isEmpty)
    try store.dispatch(Command("reopenClosedTab", [.string(restored)]))
    #expect(store.state.tabs.values.contains { $0.url == "https://c.example/" })
    #expect(store.state.closedTabs.compactMap(\.tabId) == [ids[1]])
  }

  @Test func nonLivePinnedPagesUnloadWithoutChangingPinnedSyncValues() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    var ids = store.state.windows[window]!.tabIds
    for host in ["b", "c"] {
      ids.append(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).example/"), "index": JSONValue(ids.count)]])).result!.string!)
    }
    try store.dispatch(Command("pinTabs", [.array(ids.map(JSONValue.string)), true, true]))
    let split = try store.dispatch(Command("createSplit", [.array(ids.map(JSONValue.string)), "vertical"])).result!.string!
    let lookups = PinnedLookups(base: { _ in nil })
    let before = JSONObject(try PinnedSync.pinnedValues(store.state, "default", lookups).values.map { ($0.key, $0.value) })
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array([.string(ids[0])])])).result?.string)
    #expect(store.state.windows[restored]?.tabIds == ids)
    #expect(store.state.windows[restored]?.activeTabIds["default"] == ids[0])
    #expect(store.state.tabs[ids[0]]?.unloaded != true)
    #expect(hasPage(store.state.tabs[ids[0]]!))
    for id in ids.suffix(2) {
      #expect(store.state.tabs[id]?.unloaded == true)
      #expect(!hasPage(store.state.tabs[id]!))
    }
    #expect(store.state.closedTabs.compactMap(\.tabId) == Array(ids.suffix(2)))
    #expect(store.state.closedTabs.allSatisfy { $0.pinnedTile == true })
    #expect(store.state.splits[split] == nil)
    #expect(JSONObject(try PinnedSync.pinnedValues(store.state, "default", lookups).values.map { ($0.key, $0.value) }) == before)
  }

  @Test func aProfileWithoutLivePagesDoesNotWakeItsPinnedGroup() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://live.example/"]])).result!.string!
    let live = store.state.windows[window]!.tabIds[0]
    let profile = try store.dispatch(Command("createProfile", [["name": "Other"]])).result!.string!
    let pin = try store.dispatch(Command("newTab", [.string(window), ["url": "https://pin.example/", "profileId": .string(profile)]])).result!.string!
    let group = try store.dispatch(Command("groupTabs", [.array([.string(pin)]), ["pinned": true, "name": "Pinned"]])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array([.string(live)])])).result?.string)
    #expect(store.state.windows[restored]?.profileId == "default")
    #expect(store.state.windows[restored]?.activeTabIds == ["default": live])
    #expect(store.state.ui.lastProfileId == "default")
    #expect(store.state.windows[restored]?.tabIds == [pin, live])
    #expect(store.state.groups[group]?.tabIds == [pin])
    #expect(store.state.tabs[pin]?.unloaded == true)
    #expect(!hasPage(store.state.tabs[pin]!))
    #expect(store.state.closedTabs.compactMap(\.tabId) == [pin])
  }

  @Test func anUnloadedMissingPinKeepsItsEarlierClosedPage() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://pin.example/"]])).result!.string!
    let pin = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [.array([.string(pin)]), true]))
    let live = try store.dispatch(Command("newTab", [.string(window), ["url": "https://live.example/"]])).result!.string!
    try store.dispatch(Command("closeTabs", [.array([.string(pin)])]))
    let closed = store.state.closedTabs
    #expect(closed.compactMap(\.tabId) == [pin])
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array([.string(live)])])).result?.string)
    #expect(store.state.tabs[pin]?.windowId == restored)
    #expect(store.state.tabs[pin]?.unloaded == true)
    #expect(!hasPage(store.state.tabs[pin]!))
    #expect(store.state.closedTabs == closed)
    try store.dispatch(Command("reopenClosedTab", [.string(restored)]))
    #expect(hasPage(store.state.tabs[pin]!))
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func aLivePinKeepsItsEarlierClosedPage() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://pin.example/"]])).result!.string!
    let pin = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [.array([.string(pin)]), true]))
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://other.example/"]]))
    try store.dispatch(Command("navigate", [.string(pin), "https://earlier.example/"]))
    try store.dispatch(Command("navigated", [.string(pin), ["url": "https://earlier.example/", "title": "Earlier"]]))
    try store.dispatch(Command("closeTabs", [.array([.string(pin)])]))
    let closed = store.state.closedTabs
    #expect(closed.compactMap(\.tabId) == [pin])
    try store.dispatch(Command("navigate", [.string(pin), "https://later.example/"]))
    try store.dispatch(Command("navigated", [.string(pin), ["url": "https://later.example/", "title": "Later"]]))
    try store.dispatch(Command("activate", [.string(pin)]))
    let snapshot = closeSnapshot(store.state, window)
    let live = store.state.windows[window]!.tabIds
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(live.map(JSONValue.string))])).result?.string)
    #expect(store.state.tabs[pin]?.windowId == restored)
    #expect(store.state.tabs[pin]?.url == "https://later.example/")
    #expect(hasPage(store.state.tabs[pin]!))
    #expect(store.state.closedTabs == closed)
  }

  @Test func aPeekWithoutALiveSnapshotOfferDoesNotReturn() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://live.example/"]])).result!.string!
    let live = store.state.windows[window]!.tabIds[0]
    let peek = try store.dispatch(Command("openPeek", [.string(live), "https://peek.example/"])).result!.string!
    #expect(!peek.isEmpty)
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.tabs[peek] == nil)
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array([.string(live)])])).result?.string)
    #expect(store.state.windows[restored]?.tabIds == [live])
    #expect(store.state.tabs[peek] == nil)
    #expect(store.state.peeks[restored] == nil)
    #expect(!store.state.closedTabs.contains { $0.tabId == peek })
  }

  @Test func noMatchingLiveTabRefusesWithoutChangingState() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let before = store.state
    for ids: [String] in [[], ["foreign"]] {
      #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(ids.map(JSONValue.string))])).result == .null)
      #expect(store.state == before)
    }
  }

  @Test func aTabIdAlreadyInUseRefusesWithoutChangingState() throws {
    let store = makeStore()
    let other = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    var tab = store.state.tabs[store.state.windows[window]!.tabIds[0]]!
    tab.windowId = other
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update {
      $0.tabs[tab.id] = tab
      $0.windows[other]!.tabIds.append(tab.id)
    } }
    let before = store.state
    let result = try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })]))
    #expect(result.result == .null)
    #expect(store.state == before)
  }

  @Test func privateWindowKeepsItsIncognitoProfileId() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://private.example/", "incognito": true]])).result!.string!
    var ids = store.state.windows[window]!.tabIds
    for host in ["row", "member", "a", "b"] {
      ids.append(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).example/"), "background": true]])).result!.string!)
    }
    try store.dispatch(Command("pinTabs", [.array([.string(ids[0])]), true]))
    try store.dispatch(Command("pinTabs", [.array([.string(ids[1])]), true, true]))
    try store.dispatch(Command("groupTabs", [.array([.string(ids[2])]), ["pinned": true, "name": "Pinned"]]))
    try store.dispatch(Command("groupTabs", [.array(ids.suffix(2).map(JSONValue.string)), ["pinned": false, "name": "Regular"]]))
    try store.dispatch(Command("createSplit", [.array(ids.suffix(2).map(JSONValue.string)), "vertical"]))
    let before = store.state
    let snapshot = closeSnapshot(before, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result?.string)
    #expect(store.state.windows[restored]?.incognito == true)
    #expect(store.state.windows[restored]?.profileId == before.windows[window]?.profileId)
    #expect(store.state.windows[restored]?.originalProfileId == before.windows[window]?.originalProfileId)
    #expect(store.state.windows[restored]?.tabIds == before.windows[window]?.tabIds)
    #expect(store.state.tabs.values.allSatisfy { $0.profileId == before.windows[window]!.profileId })
    #expect(store.state.groups.keys == before.groups.keys)
    #expect(store.state.splits.keys == before.splits.keys)
    #expect(store.state.parkedPins == before.parkedPins)
    #expect(store.state.closedWindows == before.closedWindows)
    #expect(store.state.closedTabs == before.closedTabs)
  }

  @Test func smallWindowRemovesItsCloseHistory() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://small.example/", "small": true]])).result!.string!
    for host in ["row", "member", "a", "b"] {
      try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).example/"), "background": true]]))
    }
    let snapshot = closeSnapshot(store.state, window)
    let ids = store.state.windows[window]!.tabIds
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.closedTabs.contains { ids.contains($0.tabId ?? "") })
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result?.string)
    #expect(store.state.windows[restored]?.kind == "small")
    #expect(!store.state.closedTabs.contains { ids.contains($0.tabId ?? "") })
  }

  @Test func danglingWindowMembershipRefusesWithoutChangingState() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: false, clock: { 1_000 })
    let other = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    let tabId = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update { $0.windows[other]!.tabIds.append(tabId) } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test func aTabIdInParkedPinsRefusesWithoutChangingState() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let snapshot = closeSnapshot(store.state, window)
    let tab = store.state.tabs[store.state.windows[window]!.tabIds[0]]!
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let park = ParkedPins(tabs: [ParkedTab(snapshot: snapshotTab(tab), id: tab.id, groupId: nil, restoreFrom: nil)], groups: [], splits: nil)
    try store.transact { session in session.update { $0.parkedPins[tab.profileId] = park } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test func aSharedPageReturnedToAnotherWindowRefusesWithoutChangingState() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://pin.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [.array([.string(tab)]), true, true]))
    try store.dispatch(Command("activate", [.string(tab)]))
    let other = try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result!.string!
    let copy = try #require(store.state.windows[other]!.tabIds.first { store.state.tabs[$0]?.pinned == true })
    try store.dispatch(Command("activate", [.string(copy)]))
    let snapshot = closeSnapshot(store.state, other)
    try store.dispatch(Command("closeWindow", [.string(other)]))
    #expect(store.state.tabs[tab]?.windowId == window)
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test func danglingGroupMembershipRefusesWithoutChangingState() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: false, clock: { 1_000 })
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    try store.dispatch(Command("groupTabs", [.array(store.state.windows[window]!.tabIds.map(JSONValue.string)), ["name": "Pinned", "pinned": true]]))
    let snapshot = closeSnapshot(store.state, window)
    var group = store.state.groups.values[0]
    group.id = "foreign"
    group.windowId = "elsewhere"
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update { $0.groups[group.id] = group } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test func changingParkedPinsAfterCloseRefusesWithoutChangingState() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [.array([.string(tab)]), true]))
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.transact { session in session.update {
      var park = $0.parkedPins["default"]!
      var added = park.tabs[0]
      added.id = "newer-pin"
      park.tabs.append(added)
      $0.parkedPins["default"] = park
    } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test func unrelatedParkedPinsSurviveAndAliasKeysAreUnparked() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [.array([.string(tab)]), true]))
    try store.dispatch(Command("updateTab", [.string(tab), ["pinKey": "pin-key"]]))
    var parked = ParkedTab(snapshot: snapshotTab(store.state.tabs[tab]!), id: "unrelated", groupId: nil, restoreFrom: nil)
    parked.snapshot.url = "https://unrelated.example/"
    parked.snapshot.pinnedUrl = parked.snapshot.url
    let old = ParkedPins(tabs: [parked], groups: [], splits: nil)
    try store.transact { session in session.update { $0.parkedPins["default"] = old } }
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.state.parkedPins["default"]?.tabs.contains { $0.id == "pin-key" } == true)
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result?.string)
    #expect(store.state.parkedPins["default"] == old)
    #expect(store.state.tabs[tab]?.pinKey == "pin-key")
    #expect(store.state.tabs[tab]?.windowId == restored)
  }

  @Test func aPinnedOpenerReferenceRefusesWithoutChangingState() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: false, clock: { 1_000 })
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    var group = TabGroup(id: "foreign", windowId: "elsewhere", profileId: "default", name: "Foreign", icon: nil, color: nil, collapsed: false, pinned: false, tabIds: [], createdAt: 1_000)
    group.pinnedOpenerId = tab
    try store.transact { session in session.update { $0.groups[group.id] = group } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

  @Test(arguments: [false, true]) func aParkedGroupParentReferenceRefusesWithoutChangingState(alias: Bool) throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    let group = try store.dispatch(Command("groupTabs", [.array(store.state.windows[window]!.tabIds.map(JSONValue.string)), ["name": "Pinned", "pinned": true]])).result!.string!
    if alias {
      try store.transact { session in session.update { $0.groups[group]!.pinKey = "group-key" } }
    }
    let snapshot = closeSnapshot(store.state, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let child = ParkedGroup(id: "foreign-child", name: "Child", icon: nil, color: nil, collapsed: false, parentId: alias ? "group-key" : group)
    try store.transact { session in session.update { $0.parkedPins["elsewhere"] = ParkedPins(tabs: [], groups: [child], splits: nil) } }
    let before = store.state
    #expect(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", .array(snapshot["tabs"]!.array!.map { $0["id"]! })])).result == .null)
    #expect(store.state == before)
  }

}
