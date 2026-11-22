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

  @Test func anUntouchedPlaceholderOwnsARealEnginePageFromItsFirstOpen() {
    var input = state()
    input.tabs["a"]!.newTabPlaceholder = true
    input.tabs["a"]!.navigation = Navigation(url: "about:blank", seq: 1)
    let out = wanted(input, shownOver: [])
    #expect(out["a"] != nil)
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["a"]?.profileId == input.tabs["a"]?.profileId)
  }

  @Test func settlingAnEmptyPlaceholderKeepsItsEnginePageHidden() {
    var input = state()
    input.tabs["a"]!.navigation = Navigation(url: "about:blank", seq: 1)
    #expect(wanted(input, shownOver: [])["a"]?.shown == TabViewWanted.Shown.none)
    input.tabs["a"]!.url = "about:blank"
    #expect(wanted(input, shownOver: [])["a"]?.shown == .card)
    input.tabs["a"]!.url = "https://destination.example/"
    input.tabs["a"]!.navigation = Navigation(url: "https://destination.example/", seq: 2)
    #expect(wanted(input, shownOver: [])["a"]?.shown == .card)
  }

  @Test func emptySplitAndPeekPagesStayHiddenBeforePagePropsArrive() {
    var input = state(split: true, peek: true)
    input.tabs["p"]!.url = ""
    let out = wanted(input, shownOver: [])
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["b"]?.shown == .pane)
    #expect(out["p"]?.shown == TabViewWanted.Shown.none)
  }

  @Test func adoptedPagesKeepTheirPresentationBeforeTheirURLArrives() {
    var input = state(split: true, peek: true)
    input.tabs["a"]!.navigation = nil
    input.tabs["a"]!.adoptId = "adopt-a"
    input.tabs["p"]!.url = ""
    input.tabs["p"]!.navigation = nil
    input.tabs["p"]!.adoptId = "adopt-p"
    #expect(wanted(input, shownOver: [])["a"]?.shown == .pane)
    #expect(wanted(input, shownOver: [])["p"]?.shown == .peek)
    input.splits.remove(["s"])
    #expect(wanted(input, shownOver: [])["a"]?.shown == .card)
  }

  @Test func theActiveTabsKeptPageIsHiddenWhileNewTabIsShownOverIt() {
    var input = state()
    input.tabs["a"]!.url = "https://a.example/"
    let out = wanted(input, shownOver: ["a"])
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["a"] != nil)
  }

  @Test func goingForwardShowsTheKeptPageAgain() {
    var input = state()
    input.tabs["a"]!.url = "https://a.example/"
    #expect(wanted(input, shownOver: [])["a"]?.shown == .card)
  }

  @Test func aSplitPaneShowingNewTabHidesOnlyItsOwnPage() {
    var input = state(split: true)
    input.tabs["a"]!.url = "https://a.example/"
    let out = wanted(input, shownOver: ["a"])
    #expect(out["a"]?.shown == TabViewWanted.Shown.none)
    #expect(out["b"]?.shown == .pane)
  }

  @Test func aPeekShowingNewTabIsHidden() {
    var input = state(peek: true)
    input.tabs["a"]!.url = "https://a.example/"
    let out = wanted(input, shownOver: ["p"])
    #expect(out["p"]?.shown == TabViewWanted.Shown.none)
    #expect(out["a"]?.shown == .card)
  }
}
