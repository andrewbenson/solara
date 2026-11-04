import SolaraModel
import Testing
@testable import SolaraUI

struct TabViewWantedNewTabTests {
  private func state(split: Bool = false, peek: Bool = false) -> BrowserState {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var window = BrowserWindow(id: "w1", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b"]
    window.activeTabIds[profile] = "a"
    state.windows["w1"] = window
    state.windowOrder = ["w1"]
    for id in ["a", "b", "p"] {
      var tab = Tab(id: id, windowId: "w1", profileId: profile, url: "https://\(id).example/", now: 0)
      tab.navigation = Navigation(url: tab.url, seq: 1)
      state.tabs[id] = tab
    }
    state.tabs["a"]!.url = ""
    if split { state.splits["s"] = SplitView(id: "s", windowId: "w1", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5]) }
    if peek { state.peeks["w1"] = Peek(tabId: "p", sourceId: "b", sourcePage: "https://b.example/", from: nil) }
    return state
  }

  private func wanted(_ state: BrowserState, shownOver: Set<String>) -> [String: TabViewWanted] {
    Dictionary(uniqueKeysWithValues: TabViewWanted.from(state, windows: ["w1"], isInternal: { _ in false }, frozen: { _ in false },
      newTabShown: { shownOver.contains($0) }).map { ($0.tabId, $0) })
  }

  @Test func theActiveTabsKeptPageIsHiddenWhileNewTabIsShownOverIt() {
    let out = wanted(state(), shownOver: ["a"])
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["a"] != nil)
  }

  @Test func goingForwardShowsTheKeptPageAgain() {
    #expect(wanted(state(), shownOver: [])["a"]?.shown == .card)
  }

  @Test func aSplitPaneShowingNewTabHidesOnlyItsOwnPage() {
    let out = wanted(state(split: true), shownOver: ["a"])
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["b"]?.shown == .pane)
  }

  @Test func aPeekShowingNewTabIsHidden() {
    let out = wanted(state(peek: true), shownOver: ["p"])
    #expect(out["p"]?.shown == TabViewWanted.Shown.none)
    #expect(out["a"]?.shown == .card)
  }
}
