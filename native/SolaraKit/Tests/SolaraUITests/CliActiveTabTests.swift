import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct CliActiveTabTests {
  @Test func tabProfileNamesFollowTheTabAndExcludePrivateWindows() {
    var state = fixture()
    state.profiles["p"]?.dataId = "shared"
    state.profiles["q"]?.dataId = "shared"
    state.windows["x"]?.incognito = true
    let ids = ["a": 101, "b": 102, "c": 103, "missing": 104]
    #expect(cliTabProfileNames(state, sessionIds: ids) == ["101": "Personal", "103": "Work"])
    state.profiles["q"]?.name = "Renamed"
    #expect(cliTabProfileNames(state, sessionIds: ids)["103"] == "Renamed")
    state.tabs["a"] = nil
    #expect(cliTabProfileNames(state, sessionIds: ids) == ["103": "Renamed"])
  }

  private func fixture() -> BrowserState {
    var state = BrowserState()
    state.profiles["p"] = Profile(id: "p", name: "Personal", color: "plum", icon: nil, createdAt: 0)
    state.profiles["q"] = Profile(id: "q", name: "Work", color: "blue", icon: nil, createdAt: 0)
    state.profileOrder = ["p", "q"]
    for (id, window, profile) in [("a", "w", "p"), ("b", "x", "p"), ("c", "w", "q"), ("peek", "w", "p")] {
      var tab = Tab(id: id, windowId: window, profileId: profile, url: "https://\(id).example/", now: 0)
      tab.navigation = Navigation(url: tab.url, seq: 1)
      state.tabs[id] = tab
    }
    var first = BrowserWindow(id: "w", profileId: "p", incognito: false, frame: nil, createdAt: 0)
    first.tabIds = ["a", "c"]
    first.activeTabIds["p"] = "a"
    first.activeTabIds["q"] = "c"
    var second = BrowserWindow(id: "x", profileId: "p", incognito: false, frame: nil, createdAt: 0)
    second.tabIds = ["b"]
    second.activeTabIds["p"] = "b"
    state.windows["w"] = first
    state.windows["x"] = second
    state.windowOrder = ["w", "x"]
    state.ui.focusedWindowId = "w"
    return state
  }

  private var browsers: [String: Int] { ["a": 11, "b": 22, "c": 33, "peek": 44] }

  @Test func followsTheFocusedWindow() {
    var state = fixture()
    #expect(cliActiveBrowserId(state, browsers: browsers) == 11)
    state.ui.focusedWindowId = "x"
    #expect(cliActiveBrowserId(state, browsers: browsers) == 22)
    state.ui.focusedWindowId = nil
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
    state.ui.focusedWindowId = "missing"
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
  }

  @Test func selectsTheFocusedWindowsCurrentProfile() {
    var state = fixture()
    state.windows["w"]!.profileId = "q"
    #expect(cliActiveBrowserId(state, browsers: browsers) == 33)
    state.windows["w"]!.activeTabIds["q"] = nil
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
  }

  @Test func peekTakesPrecedenceAndDoesNotFallBackWhenItHasNoPage() {
    var state = fixture()
    state.peeks["w"] = Peek(tabId: "peek", sourceId: "a", sourcePage: "https://a.example/", from: nil)
    #expect(cliActiveBrowserId(state, browsers: browsers) == 44)
    state.tabs["peek"]!.navigation = nil
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
    state.peeks.remove(["w"])
    #expect(cliActiveBrowserId(state, browsers: browsers) == 11)
  }

  @Test func emptyUrlRejectsTheRetainedPageBehindNewTab() {
    var state = fixture()
    state.tabs["a"]!.url = ""
    #expect(state.tabs["a"]!.navigation != nil)
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
  }

  @Test func missingUrlRejectsAnAdoptedPage() throws {
    var state = fixture()
    state.tabs["a"] = try Tab(json: ["id": "a", "windowId": "w", "profileId": "p", "adoptId": "solaracore:7"])
    #expect(hasPage(state.tabs["a"]!))
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
  }

  @Test func rejectsMissingTabsAndTabsWithoutPages() {
    var state = fixture()
    state.tabs["a"]!.navigation = nil
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
    state.tabs["a"]!.adoptId = "solaracore:7"
    #expect(cliActiveBrowserId(state, browsers: browsers) == 11)
    state.tabs.remove(["a"])
    #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
  }

  @Test func internalPagesMatchThePoolRuleAndUseNavigationUrl() {
    AppScheme.withScheme(productName: "Solara") {
      for url in ["solara://history", "solara://BOOKMARKS/path?x=1", "SOLARA://downloads#today"] {
        var state = fixture()
        state.tabs["a"]!.navigation = Navigation(url: url, seq: 2)
        #expect(cliActiveBrowserId(state, browsers: browsers) == nil)
      }
      for url in ["solara://version", "chrome://history", "https://history/", "about:blank"] {
        var state = fixture()
        state.tabs["a"]!.navigation = Navigation(url: url, seq: 2)
        #expect(cliActiveBrowserId(state, browsers: browsers) == 11)
      }
      var adopted = fixture()
      adopted.tabs["a"]!.navigation = nil
      adopted.tabs["a"]!.adoptId = "solaracore:7"
      adopted.tabs["a"]!.url = "solara://history"
      #expect(cliActiveBrowserId(adopted, browsers: browsers) == nil)
    }
  }

  @Test func rejectsMissingAndInvalidBridgeMappings() {
    let state = fixture()
    #expect(cliActiveBrowserId(state, browsers: [:]) == nil)
    #expect(cliActiveBrowserId(state, browsers: ["a": -1]) == nil)
    #expect(cliActiveBrowserId(state, browsers: ["a": 0]) == nil)
  }

  @Test func reducerSendsOnlyWhileStartingOrOnAndDeduplicates() {
    var sync = CliActiveTabSync()
    #expect(sync.update(serverState: nil, chromeId: 101) == nil)
    #expect(sync.update(serverState: "off", chromeId: 101) == nil)
    #expect(sync.update(serverState: "starting", chromeId: 101) == ["active": 101])
    #expect(sync.update(serverState: "starting", chromeId: 101) == nil)
    #expect(sync.update(serverState: "on", chromeId: 101) == nil)
    #expect(sync.update(serverState: "on", chromeId: 202) == ["active": 202])
    #expect(sync.update(serverState: "on", chromeId: nil) == ["active": -1])
    #expect(sync.update(serverState: "on", chromeId: -1) == nil)
  }

  @Test func stoppingForgetsTheSentIdAndRestartResendsIt() {
    var sync = CliActiveTabSync()
    #expect(sync.update(serverState: "on", chromeId: 101) == ["active": 101])
    #expect(sync.update(serverState: "off", chromeId: 101) == nil)
    #expect(sync.update(serverState: "starting", chromeId: 101) == ["active": 101])
    #expect(sync.update(serverState: "stopping", chromeId: 101) == nil)
    #expect(sync.update(serverState: "on", chromeId: 101) == ["active": 101])
  }

  private func transaction(_ rev: Int, browser: Int, closed: Bool = false) -> StripTransaction {
    StripTransaction(json: [
      "rev": JSONValue(rev),
      "strips": [["strip": 1, "window": 1, "profile": "", "closed": .bool(closed), "tabs": [["key": "a", "browser": JSONValue(browser)]]]],
    ])
  }

  private func memory(_ rev: Int, browser: Int) -> ChromeTabsMemory {
    let tx = transaction(rev, browser: browser)
    var memory = ChromeTabsMemory()
    memory.lastRev = rev
    memory.mirror[1] = tx.strips[0]
    return memory
  }

  @Test func tapReadinessDoesNotWaitForTheStoreMirror() {
    var observed = CliActiveTabBrowsers(snapshot: transaction(1, browser: 11))
    observed.receive(transaction(2, browser: 22))
    #expect(observed.map(memory(1, browser: 11))["a"] == 22)
    #expect(observed.map(memory(3, browser: 33))["a"] == 33)
    #expect(observed.map(memory(2, browser: 11))["a"] == 22)
  }

  @Test func tapMirrorIgnoresStaleEventsAndRemovesClosedStrips() {
    var observed = CliActiveTabBrowsers(snapshot: transaction(2, browser: 22))
    observed.receive(transaction(1, browser: 11))
    #expect(observed.map(ChromeTabsMemory())["a"] == 22)
    observed.receive(transaction(3, browser: 22, closed: true))
    #expect(observed.map(memory(2, browser: 22))["a"] == nil)
  }
}
