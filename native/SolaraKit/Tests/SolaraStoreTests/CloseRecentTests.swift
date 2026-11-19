import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct CloseRecentTests {
  let clock = TestClock(1_800_000_000_000)
  let store: Store

  init() {
    let clock = clock
    store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: true, clock: { clock.now })
  }

  @discardableResult
  func run(_ name: String, _ args: JSONValue...) throws -> JSONValue {
    clock.advance(1000)
    return try store.dispatch(Command(name, args)).result ?? .null
  }

  func setup(_ hosts: String...) throws -> (String, [String]) {
    let window = try run("createWindow", ["url": .string("https://\(hosts[0]).com/")]).string ?? ""
    var ids = [store.state.windows[window]!.tabIds[0]]
    for host in hosts.dropFirst() {
      ids.append(try run("newTab", .string(window), ["url": .string("https://\(host).com/"), "background": true]).string ?? "")
    }
    try run("activate", .string(ids[0]))
    return (window, ids)
  }

  func link(_ window: String, _ host: String, _ opener: String, background: Bool = true) throws -> String {
    try run("newTab", .string(window), ["url": .string("https://\(host).com/"), "openerId": .string(opener), "background": .bool(background)]).string ?? ""
  }

  func shown(_ window: String) -> String? {
    let w = store.state.windows[window]!
    return w.activeTabIds[w.profileId]
  }

  func use(_ id: String) throws { try run("activate", .string(id)) }
  func close(_ id: String) throws { try run("closeTab", .string(id)) }
  func edit(_ change: @escaping (inout BrowserState) -> Void) throws { try store.transact { $0.update(change) } }

  @Test func closingTheShownTabGoesBackToTheTabUsedBeforeIt() throws {
    let (window, ids) = try setup("a", "b", "c", "d")
    try use(ids[1])
    try use(ids[3])
    try use(ids[2])
    try close(ids[2])
    #expect(shown(window) == ids[3])
    try close(ids[3])
    #expect(shown(window) == ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[0])
  }

  @Test func tabsOpenedBehindAndNeverShownAreSkipped() throws {
    let (window, ids) = try setup("a", "b")
    _ = try link(window, "x", ids[0])
    _ = try link(window, "y", ids[0])
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[0])
  }

  @Test func tabsTheClosedPageOpenedBehindDontTakeOver() throws {
    let (window, ids) = try setup("a", "b")
    try use(ids[1])
    _ = try link(window, "x", ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[0])
  }

  @Test func aLinkOpenedInFrontAndLeftBehindIsStillATabYouUsed() throws {
    let (window, ids) = try setup("a", "b")
    let x = try link(window, "x", ids[0], background: false)
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == x)
  }

  @Test func closingTheOpenerAfterReadingALinkItOpenedInFrontGoesBackToThatLink() throws {
    let (window, ids) = try setup("a", "b")
    let x = try link(window, "x", ids[0], background: false)
    try use(ids[0])
    try close(ids[0])
    #expect(shown(window) == x)
  }

  @Test func aTabOpenedBehindWithoutAnOpenerNeverWinsUntilShown() throws {
    let (window, ids) = try setup("a", "b")
    let z = try run("newTab", .string(window), ["url": "https://z.com/", "background": true]).string ?? ""
    #expect(store.state.tabs[z]?.shownAt == 0)
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[0])
  }

  @Test func aTabOpenedBehindCountsOnceShown() throws {
    let (window, ids) = try setup("a", "b")
    let x = try link(window, "x", ids[0])
    try use(x)
    #expect(store.state.tabs[x]?.shownAt == nil)
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == x)
  }

  @Test func aTabShownBecauseTheTabAboveClosedCountsAsShown() throws {
    let (window, ids) = try setup("a")
    let x = try run("newTab", .string(window), ["url": "https://x.com/", "background": true]).string ?? ""
    try close(ids[0])
    #expect(shown(window) == x)
    #expect(store.state.tabs[x]?.shownAt == clock.now)
  }

  @Test func aSleepingTabCanBeShownAndWakes() throws {
    let (window, ids) = try setup("a", "b", "c")
    try use(ids[1])
    try use(ids[2])
    let b = ids[1]
    try edit {
      $0.tabs[b]?.navigation = nil
      $0.tabs[b]?.unloaded = true
    }
    try close(ids[2])
    #expect(shown(window) == b)
    #expect(store.state.tabs[b]?.unloaded == nil)
    #expect(store.state.tabs[b]?.navigation != nil)
  }

  func withoutShownAt(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
      var out = object.mapValues(withoutShownAt)
      _ = out.removeValue(forKey: "shownAt")
      return .object(out)
    case .array(let items): return .array(items.map(withoutShownAt))
    default: return value
    }
  }

  @Test func tabsSavedBeforeShownAtRankByLastActive() throws {
    let (window, ids) = try setup("a", "b", "c")
    try use(ids[2])
    try use(ids[1])
    try run("hydrate", withoutShownAt(store.sessionDocument().json()))
    #expect(store.state.tabs.values.allSatisfy { $0.shownAt == nil })
    try close(ids[1])
    #expect(shown(window) == ids[2])
  }

  @Test func closingTheLastTabOfAGroupGoesBackOutsideTheGroup() throws {
    let (window, ids) = try setup("a", "b", "c")
    try run("groupTabs", [.string(ids[2])])
    try use(ids[0])
    try use(ids[2])
    try close(ids[2])
    #expect(shown(window) == ids[0])
  }

  @Test func aTabInsideACollapsedGroupIsPassedOver() throws {
    let (window, ids) = try setup("a", "b", "c")
    let group = try run("groupTabs", [.string(ids[1])]).string ?? ""
    try use(ids[1])
    try use(ids[0])
    try use(ids[2])
    try run("updateGroup", .string(group), ["collapsed": true])
    try close(ids[2])
    #expect(shown(window) == ids[0])
  }

  @Test func closingOnePaneOfASplitShowsTheOtherPane() throws {
    let (window, ids) = try setup("a", "b", "c")
    try run("createSplit", [.string(ids[1]), .string(ids[2])])
    try use(ids[0])
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[2])
  }

  @Test func closingOnePaneOfAThreePaneSplitStaysInTheSplitWhenPanesTie() throws {
    let (window, ids) = try setup("a", "b", "c", "d", "e")
    try run("createSplit", [.string(ids[1]), .string(ids[2]), .string(ids[3])])
    try use(ids[0])
    try use(ids[3])
    let (b, c) = (ids[1], ids[2])
    try edit {
      $0.tabs[b]?.shownAt = 5
      $0.tabs[c]?.shownAt = 5
    }
    try close(ids[3])
    #expect(shown(window) == c)
  }

  @Test func closingOnePaneOfAThreePaneSplitWithTiesOnBothSidesGoesBelow() throws {
    let (window, ids) = try setup("a", "b", "c", "d", "e")
    try run("createSplit", [.string(ids[1]), .string(ids[2]), .string(ids[3])])
    try use(ids[0])
    try use(ids[2])
    let (b, d) = (ids[1], ids[3])
    try edit {
      $0.tabs[b]?.shownAt = 5
      $0.tabs[d]?.shownAt = 5
    }
    try close(ids[2])
    #expect(shown(window) == d)
  }

  @Test func anOpenPeekIsNeverTheTabShownNext() throws {
    let (window, ids) = try setup("a", "b", "c")
    try use(ids[2])
    try run("openPeek", .string(ids[2]), "https://peek.com/")
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[2])
  }

  @Test func closingWithTheOpenerAsSuccessorLeavesOtherTabsAsTheyWere() throws {
    let (window, ids) = try setup("a", "b", "c")
    let x = try link(window, "x", ids[0], background: false)
    try use(ids[1])
    try use(x)
    let b = ids[1]
    try edit {
      $0.tabs[b]?.navigation = nil
      $0.tabs[b]?.unloaded = true
    }
    let before = (store.state.tabs[b]!.json, store.state.tabs[ids[2]]!.json)
    try run("closeTab", .string(x), .string(ids[0]))
    #expect(shown(window) == ids[0])
    #expect(store.state.tabs[b]!.json == before.0)
    #expect(store.state.tabs[ids[2]]!.json == before.1)
    #expect(store.state.tabs[ids[0]]?.lastActiveAt == clock.now)
    #expect(store.state.closedTabs.last?.tabId == x)
  }

  @Test func aSuccessorOutsideTheWindowIsIgnored() throws {
    let (window, ids) = try setup("a", "b")
    let other = try run("createWindow", ["url": "https://o.com/"]).string ?? ""
    let o = store.state.windows[other]!.tabIds[0]
    try use(ids[1])
    try use(ids[0])
    try use(ids[1])
    try run("closeTab", .string(ids[1]), .string(o))
    #expect(shown(window) == ids[0])
  }

  @Test func reopeningAClosedWindowKeepsWhenEachTabWasShown() throws {
    let (window, ids) = try setup("a", "b", "c")
    try use(ids[2])
    try use(ids[0])
    let keptC = store.state.tabs[ids[2]]!.lastActiveAt
    let other = try run("createWindow", ["url": "https://o.com/"]).string ?? ""
    try run("closeWindow", .string(window))
    try run("reopenClosedWindow")
    let back = store.state.tabs.values.filter { $0.windowId != other }
    #expect(back.first { $0.url.contains("b.com") }?.shownAt == 0)
    #expect(back.first { $0.url.contains("c.com") }?.shownAt == keptC)
  }

  @Test func aClosedWindowTabKeepsKeysItDoesNotKnow() throws {
    let source = #"{"url":"https://a.com/","title":"A","pinned":false,"muted":false,"profileId":"default","active":true,"shownAt":5,"later":"kept"}"#
    let tab = try ClosedWindowTab(json: try #require(JSONValue.parse(source).object))
    #expect(tab.shownAt == 5)
    #expect(tab.json["later"] == .string("kept"))
  }

  @Test func aWindowClosedBeforeShownAtComesBackWithItsOtherTabsNeverShown() throws {
    let (window, ids) = try setup("a", "b", "c")
    try use(ids[2])
    try use(ids[0])
    let other = try run("createWindow", ["url": "https://o.com/"]).string ?? ""
    try run("closeWindow", .string(window))
    try edit { s in
      s.closedWindows = s.closedWindows.map { entry in
        var e = entry
        e.tabs = e.tabs.map { item in
          var i = item
          i.shownAt = nil
          return i
        }
        return e
      }
    }
    try run("reopenClosedWindow")
    let back = store.state.tabs.values.filter { $0.windowId != other }
    #expect(back.first { $0.url.contains("b.com") }?.shownAt == 0)
    #expect(back.first { $0.url.contains("c.com") }?.shownAt == 0)
    #expect(back.first { $0.url.contains("a.com") }?.shownAt == nil)
  }

  @Test func anOpenerInACollapsedGroupIsNotRevealedByBack() throws {
    let (window, ids) = try setup("a", "b")
    let x = try link(window, "x", ids[0], background: false)
    try use(ids[1])
    try use(x)
    let group = try run("groupTabs", [.string(ids[0])]).string ?? ""
    try run("updateGroup", .string(group), ["collapsed": true])
    try run("closeTab", .string(x), .string(ids[0]))
    #expect(shown(window) == ids[1])
  }

  @Test func anotherProfilesTabsAreNeverPicked() throws {
    let work = try run("createProfile", ["name": "Work"]).string ?? ""
    let (window, ids) = try setup("a", "b")
    let other = try run("newTab", .string(window), ["url": "https://o.com/", "profileId": .string(work)]).string ?? ""
    try use(ids[1])
    try use(ids[0])
    try use(ids[1])
    try close(ids[1])
    #expect(shown(window) == ids[0])
    #expect(store.state.tabs[other]?.profileId == work)
  }

  @Test func withNoTabUsedBeforeItClosingFallsBackToTheNearestTab() throws {
    let (window, ids) = try setup("a")
    let x = try run("newTab", .string(window), ["url": "https://x.com/", "background": true]).string ?? ""
    try run("newTab", .string(window), ["url": "https://y.com/", "background": true])
    try close(ids[0])
    #expect(shown(window) == x)
  }

  @Test func whenTwoTabsWereShownAtTheSameMomentTheNearestTabDecides() throws {
    let (window, ids) = try setup("a", "b", "c")
    clock.advance(1000)
    for id in ids { try store.dispatch(Command("activate", [.string(id)])) }
    try close(ids[2])
    #expect(shown(window) == ids[1])
  }

  @Test func closingAPinnedTabGoesBackToTheTabUsedBeforeIt() throws {
    let (window, ids) = try setup("a", "b", "p")
    try run("togglePin", .string(ids[2]))
    try use(ids[1])
    try use(ids[0])
    try use(ids[2])
    try close(ids[2])
    #expect(shown(window) == ids[0])
  }

  @Test func withEqualTimesTheOpenerRuleStillDecides() throws {
    let (window, ids) = try setup("a", "b")
    clock.advance(1000)
    try store.dispatch(Command("activate", [.string(ids[1])]))
    try store.dispatch(Command("activate", [.string(ids[0])]))
    let child = try store.dispatch(Command("newTab", [.string(window), ["url": "https://c.com/", "openerId": .string(ids[0])]])).result?.string ?? ""
    try store.dispatch(Command("closeTab", [.string(child)]))
    #expect(shown(window) == ids[0])
  }
}
