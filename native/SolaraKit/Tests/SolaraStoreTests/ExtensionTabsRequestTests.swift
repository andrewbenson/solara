import SolaraModel
import SolaraStore
import Testing

struct ExtensionTabsRequestTests {
  @Test func privateSplitOfferStaysInItsPrivateSession() throws {
    let store = makeStore()
    let privateWindow = try #require(try store.dispatch(Command("createWindow", [["incognito": true]])).result?.string)
    let profile = try #require(store.state.windows[privateWindow]?.profileId)
    let regular = try #require(try store.dispatch(Command("createWindow", [])).result?.string)
    var requests = ExtensionTabsRequest()
    try requests.apply(["action": "open", "url": "https://private.example/", "profile": .string(store.state.engineProfile(profile)),
      "incognito": true, "adoptId": "private-offer", "active": false], to: store)
    let adopted = try #require(store.state.tabs.values.first { $0.adoptId == "private-offer" })
    #expect(adopted.windowId == privateWindow)
    #expect(adopted.profileId == profile)
    #expect(store.state.ui.focusedWindowId == regular)
    #expect(store.state.activeTabId(privateWindow) != adopted.id)
  }

  @Test func duplicateOffersAndWindowCloseAreConsumedOnce() throws {
    let store = makeStore()
    var requests = ExtensionTabsRequest()
    let open: JSONValue = ["action": "open", "url": "https://example.org/", "profile": "", "chromeWindow": "chrome", "adoptId": "offer"]
    let close: JSONValue = ["action": "closeWindow", "chromeWindow": "chrome"]
    try requests.apply(open, to: store)
    try requests.apply(open, to: store)
    let window = try #require(store.state.windows.values.first { $0.chromeWindow == "chrome" })
    #expect(window.tabIds.count == 1)
    try requests.apply(close, to: store)
    let closed = store.state
    #expect(closed.windows[window.id] == nil)
    try requests.apply(close, to: store)
    try requests.apply(open, to: store)
    #expect(store.state == closed)
  }

  @Test(arguments: [false, true])
  func cancelledCloseUsesNativeUndoWithOneAdoption(named: Bool) throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://example.org/"]])).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let live: JSONValue = named ? ["storeTabId": .string(tab), "adoptId": "recovered-offer"]
      : ["url": "https://example.org/", "profile": "", "incognito": false, "adoptId": "recovered-offer"]
    let event: JSONValue = ["action": "closeCancelled", "chromeWindow": "recovered", "appWindow": .string(named ? "" : window), "tabs": .array([live])]
    var requests = ExtensionTabsRequest()
    try requests.apply(event, to: store)
    let restored = try #require(store.state.tabs[tab])
    #expect(restored.adoptId == "recovered-offer")
    #expect(store.state.windows[restored.windowId]?.chromeWindow == "recovered")
    #expect(store.state.closedWindows.isEmpty)
    let after = store.state
    try requests.apply(event, to: store)
    #expect(store.state == after)
  }
  @Test func stayAfterDeadlineKeepsInterveningWindowsAndFocusesTheRestoredWindow() throws {
    let clock = TestClock(1000)
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), clock: { clock.now })
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://example.org/"]])).result?.string)
    let tab = try #require(store.state.activeTabId(window))
    var requests = ExtensionTabsRequest()
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try requests.apply(["action": "windowCloseStarted", "appWindow": .string(window)], to: store)
    clock.advance(31_000)
    let other = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result?.string)
    try requests.apply(["action": "closeCancelled", "appWindow": .string(window), "chromeWindow": "recovery",
      "tabs": [["storeTabId": .string(tab), "adoptId": "recovered-offer"]]], to: store)
    let restored = try #require(store.state.tabs[tab]?.windowId)
    #expect(store.state.windowOrder == [restored, other])
    #expect(store.state.ui.focusedWindowId == restored)
    #expect(store.state.ui.focusOrder.prefix(2).elementsEqual([restored, other]))
    #expect(store.state.closedWindows.isEmpty)
  }

  @Test(arguments: [false, true])
  func littleWindowStayAdoptsTheSurvivingBrowserAfterItsViewDetaches(named: Bool) throws {
    let clock = TestClock(1000)
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), clock: { clock.now })
    let window = try #require(try store.dispatch(Command("createWindow", [
      ["small": true, "frame": [80, 90, 900, 640], "url": "https://example.org/"]
    ])).result?.string)
    let original = try #require(store.state.windows[window])
    let tab = try #require(store.state.activeTabId(window))
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    try store.dispatch(phaseAReport(tab, ["type": "ready", "generation": "G", "browserId": 42]))
    var requests = ExtensionTabsRequest()
    try store.dispatch(Command("closeWindow", [.string(window)]))
    if named {
      try requests.apply(["action": "windowCloseStarted", "appWindow": .string(window)], to: store)
    }
    try store.dispatch(phaseAReport(tab, ["type": "gone", "generation": "G"]))
    if named { clock.advance(31_000) }
    let wrong = try requests.apply(["action": "closeCancelled", "chromeWindow": "wrong",
      "tabs": [["browserId": 43, "url": "https://example.org/", "profile": "", "incognito": false, "adoptId": "wrong-page"]]], to: store)
    #expect(wrong == nil)
    let result = try requests.apply(["action": "closeCancelled", "appWindow": .string(named ? window : ""), "chromeWindow": "recovery",
      "tabs": [["browserId": 42, "url": "https://example.org/", "profile": "", "incognito": false, "adoptId": "surviving-page"]]], to: store)
    let restored = try #require(result)
    #expect(store.state.windows[restored]?.kind == original.kind)
    #expect(store.state.windows[restored]?.frame == original.frame)
    #expect(store.state.windows[restored]?.profileId == original.profileId)
    #expect(store.state.activeTabId(restored) == tab)
    #expect(store.state.tabs[tab]?.adoptId == "surviving-page")
    #expect(store.state.closedTabs.isEmpty)
  }

  @Test func committedCloseUsesTheAppWindowIdAndConsumesStaleOffers() throws {
    let store = makeStore()
    var requests = ExtensionTabsRequest()
    let open: JSONValue = ["action": "open", "url": "https://example.org/", "profile": "", "chromeWindow": "chrome", "adoptId": "offer"]
    try requests.apply(open, to: store)
    let window = try #require(store.state.windows.values.first { $0.chromeWindow == "chrome" })
    try requests.apply(["action": "windowCloseStarted", "appWindow": .string(window.id)], to: store)
    #expect(store.state.windows[window.id] != nil)
    let closed: JSONValue = ["action": "windowCloseCommitted", "appWindow": .string(window.id)]
    try requests.apply(closed, to: store)
    #expect(store.state.windows[window.id] == nil)
    let after = store.state
    try requests.apply(closed, to: store)
    try requests.apply(["action": "open", "url": "https://late.example/", "profile": "", "chromeWindow": "chrome", "adoptId": "late"], to: store)
    #expect(store.state == after)
  }
}
