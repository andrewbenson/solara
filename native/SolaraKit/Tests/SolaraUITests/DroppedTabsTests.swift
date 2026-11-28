import Foundation
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private let typeScriptTable = #"[[[{"kind":"url","url":"https://example.com/a"}],["https://example.com/a"]],[[{"kind":"url","url":"  http://example.com/b  "}],["http://example.com/b"]],[[{"kind":"url","url":"javascript:alert(1)"}],[]],[[{"kind":"url","url":"data:text/html,x"}],[]],[[{"kind":"url","url":"https:///nohost"}],[]],[[{"kind":"url","url":"HTTPS://EXAMPLE.COM/"}],["HTTPS://EXAMPLE.COM/"]],[[{"kind":"file","url":"file:///Users/me/a.pdf"}],["file:///Users/me/a.pdf"]],[[{"kind":"file","url":"file://host/share/a.pdf"}],[]],[[{"kind":"file","url":"file:////double"}],[]],[[{"kind":"file","url":"FILE:///Users/me/b.pdf"}],["FILE:///Users/me/b.pdf"]],[[{"kind":"text","text":"example.com"}],["https://example.com"]],[[{"kind":"text","text":"  example.com/path?q=1  "}],["https://example.com/path?q=1"]],[[{"kind":"text","text":"two words"}],[]],[[{"kind":"text","text":"localhost:3000"}],["http://localhost:3000"]],[[{"kind":"text","text":"notaurl"}],[]],[[{"kind":"text","text":"ftp://example.com/x"}],[]],[[{"kind":"text","text":"https://example.com/x"}],["https://example.com/x"]],[[{"kind":"text","text":"192.168.1.1"}],["http://192.168.1.1"]],[[{"kind":"text","text":"example.com\tx"}],[]],[[{"kind":"url","url":"https://a.example/"},{"kind":"file","url":"file:///tmp/x"},{"kind":"text","text":"b.example"}],["https://a.example/","file:///tmp/x"]],[[{"kind":"url","url":"https://x0.example/"},{"kind":"url","url":"https://x1.example/"},{"kind":"url","url":"https://x2.example/"},{"kind":"url","url":"https://x3.example/"},{"kind":"url","url":"https://x4.example/"},{"kind":"url","url":"https://x5.example/"},{"kind":"url","url":"https://x6.example/"},{"kind":"url","url":"https://x7.example/"},{"kind":"url","url":"https://x8.example/"},{"kind":"url","url":"https://x9.example/"},{"kind":"url","url":"https://x10.example/"},{"kind":"url","url":"https://x11.example/"},{"kind":"url","url":"https://x12.example/"},{"kind":"url","url":"https://x13.example/"},{"kind":"url","url":"https://x14.example/"},{"kind":"url","url":"https://x15.example/"},{"kind":"url","url":"https://x16.example/"},{"kind":"url","url":"https://x17.example/"},{"kind":"url","url":"https://x18.example/"},{"kind":"url","url":"https://x19.example/"},{"kind":"url","url":"https://x20.example/"},{"kind":"url","url":"https://x21.example/"},{"kind":"url","url":"https://x22.example/"},{"kind":"url","url":"https://x23.example/"},{"kind":"url","url":"https://x24.example/"},{"kind":"url","url":"https://x25.example/"},{"kind":"url","url":"https://x26.example/"},{"kind":"url","url":"https://x27.example/"},{"kind":"url","url":"https://x28.example/"},{"kind":"url","url":"https://x29.example/"},{"kind":"url","url":"https://x30.example/"},{"kind":"url","url":"https://x31.example/"},{"kind":"url","url":"https://x32.example/"},{"kind":"url","url":"https://x33.example/"},{"kind":"url","url":"https://x34.example/"},{"kind":"url","url":"https://x35.example/"},{"kind":"url","url":"https://x36.example/"},{"kind":"url","url":"https://x37.example/"},{"kind":"url","url":"https://x38.example/"},{"kind":"url","url":"https://x39.example/"},{"kind":"url","url":"https://x40.example/"},{"kind":"url","url":"https://x41.example/"},{"kind":"url","url":"https://x42.example/"},{"kind":"url","url":"https://x43.example/"},{"kind":"url","url":"https://x44.example/"},{"kind":"url","url":"https://x45.example/"},{"kind":"url","url":"https://x46.example/"},{"kind":"url","url":"https://x47.example/"},{"kind":"url","url":"https://x48.example/"},{"kind":"url","url":"https://x49.example/"},{"kind":"url","url":"https://x50.example/"}],["https://x0.example/","https://x1.example/","https://x2.example/","https://x3.example/","https://x4.example/","https://x5.example/","https://x6.example/","https://x7.example/","https://x8.example/","https://x9.example/","https://x10.example/","https://x11.example/","https://x12.example/","https://x13.example/","https://x14.example/","https://x15.example/","https://x16.example/","https://x17.example/","https://x18.example/","https://x19.example/","https://x20.example/","https://x21.example/","https://x22.example/","https://x23.example/","https://x24.example/","https://x25.example/","https://x26.example/","https://x27.example/","https://x28.example/","https://x29.example/","https://x30.example/","https://x31.example/","https://x32.example/","https://x33.example/","https://x34.example/","https://x35.example/","https://x36.example/","https://x37.example/","https://x38.example/","https://x39.example/","https://x40.example/","https://x41.example/","https://x42.example/","https://x43.example/","https://x44.example/","https://x45.example/","https://x46.example/","https://x47.example/","https://x48.example/","https://x49.example/"]]]"#

@MainActor
@Suite(.serialized)
struct DroppedTabsTests {
  @Test func urlsMatchTheTypeScriptDroppedUrlsTable() throws {
    let cases = try #require(try JSONSerialization.jsonObject(with: Data(typeScriptTable.utf8)) as? [[Any]])
    #expect(cases.count == 21)
    for entry in cases {
      let items = try #require(entry[0] as? [[String: String]])
      let expected = try #require(entry[1] as? [String])
      #expect(DroppedTabs.urls(items) == expected, "\(items.prefix(3))")
    }
  }

  @Test func spacingFollowsJavaScriptForBOMVerticalTabAndNextLine() {
    #expect(DroppedTabs.urls([["kind": "url", "url": "\u{FEFF}https://a.com/"]]) == ["https://a.com/"])
    #expect(DroppedTabs.urls([["kind": "text", "text": "a.com/x\u{000B}y"]]) == [])
    #expect(DroppedTabs.urls([["kind": "text", "text": "\u{0085}example.com"]]) == [])
    #expect(DroppedTabs.urls([["kind": "url", "url": "https://\u{FEFF}a.com/"]]) == [])
    #expect(DroppedTabs.urls([["kind": "url", "url": "https://\u{0085}a.com/"]]) == ["https://\u{0085}a.com/"])
  }

  @Test func aRefusedTabIsReportedAndTheRestStillOpenAndPlace() throws {
    let (store, window, before) = try window(tabs: 2)
    var refusals = 0
    let placement = try JSONValue.parse(#"{"pinned":false,"beforeId":"\#(before[0])"}"#)
    let ids = DroppedTabs.open(store, windowId: window, items: [["kind": "url", "url": "https://x.com/"]], placement: placement) { _ in refusals += 1 }
    #expect(refusals == 0)
    #expect(store.state.windows[window]!.tabIds.first == ids.first)
  }

  func window(tabs count: Int) throws -> (Store, String, [String]) {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for _ in 1..<count { try store.dispatch(Command("newTab", [.string(window)])) }
    return (store, window, store.state.windows[window]!.tabIds)
  }

  @Test func theFirstDropIsActiveAndTheRestFollowItInOrder() throws {
    let (store, window, before) = try window(tabs: 3)
    let items = ["https://x.com/", "https://y.com/", "https://z.com/"].map { ["kind": "url", "url": $0] }
    let ids = DroppedTabs.open(store, windowId: window, items: items, placement: nil)
    #expect(ids.count == 3)
    let order = store.state.windows[window]!.tabIds
    let at = ids.map { order.firstIndex(of: $0)! }
    #expect(at == [at[0], at[0] + 1, at[0] + 2])
    #expect(ids.map { store.state.tabs[$0]!.url } == ["https://x.com/", "https://y.com/", "https://z.com/"])
    #expect(store.state.activeTabId(window) == ids[0])
    #expect(Set(order).isSuperset(of: before))
  }

  @Test func aPlacementMovesTheDroppedTabsTogether() throws {
    let (store, window, before) = try window(tabs: 3)
    let items = ["https://x.com/", "https://y.com/"].map { ["kind": "url", "url": $0] }
    let placement = try JSONValue.parse(#"{"pinned":false,"beforeId":"\#(before[1])"}"#)
    let ids = DroppedTabs.open(store, windowId: window, items: items, placement: placement)
    let order = store.state.windows[window]!.tabIds
    #expect(order.firstIndex(of: ids[1])! + 1 == order.firstIndex(of: before[1])!)
    #expect(order.firstIndex(of: ids[0])! + 1 == order.firstIndex(of: ids[1])!)
  }

  @Test func nothingOpensForNoUsableItemsOrAMissingWindow() throws {
    let (store, window, before) = try window(tabs: 2)
    #expect(DroppedTabs.open(store, windowId: window, items: [["kind": "text", "text": "two words"]], placement: nil).isEmpty)
    #expect(DroppedTabs.open(store, windowId: "gone", items: [["kind": "url", "url": "https://x.com/"]], placement: nil).isEmpty)
    #expect(store.state.windows[window]!.tabIds == before)
  }

  @Test func anExternalDropKeepsItsProfileWhenTheWindowPagesBeforeOpening() throws {
    let (store, window, before) = try window(tabs: 2)
    let original = try #require(store.state.windows[window]?.profileId)
    let landing = try #require(DroppedTabs.Landing(store, windowId: window, generation: 1))
    let paged = try #require(store.dispatch(Command("createProfile", [["name": "Paged"]])).result?.string)
    try store.dispatch(Command("switchProfile", [.string(window), .string(paged)]))
    let selected = store.state.activeTabId(window)
    let placement: JSONValue = ["pinned": true, "beforeId": .string(before[0])]

    let ids = landing.open(in: store, generation: 1, items: [["kind": "url", "url": "https://x.com/"]], placement: placement)
    let dropped = try #require(ids.first.flatMap { store.state.tabs[$0] })
    #expect(dropped.profileId == original && !dropped.pinned)
    #expect(store.state.activeTabId(window) == selected)
    #expect(store.state.windows[window]?.profileId == paged)
  }

  @Test func aQueuedDropRefusesAReplacementOwnerOrChangedGeneration() throws {
    let (store, window, before) = try window(tabs: 2)
    let replacement = Store(state: store.state, checksInvariants: true)
    let landing = try #require(DroppedTabs.Landing(store, windowId: window, generation: 1))
    let items = [["kind": "url", "url": "https://drop.example/"]]

    #expect(landing.open(in: replacement, generation: 1, items: items, placement: nil).isEmpty)
    #expect(landing.open(in: store, generation: 2, items: items, placement: nil).isEmpty)
    #expect(store.state.windows[window]?.tabIds == before)
    #expect(replacement.state.windows[window]?.tabIds == before)
    #expect(landing.open(in: store, generation: 1, items: items, placement: nil).count == 1)
  }

  @Test func aQueuedDropRefusesAWindowThatStartedClosing() throws {
    let (store, window, before) = try window(tabs: 2)
    let items = [["kind": "url", "url": "https://drop.example/"]]
    let landing = try #require(DroppedTabs.Landing(store, windowId: window, generation: 1))
    try store.dispatch(Command("setWindowClosing", [.string(window), .bool(true)]))

    #expect(landing.open(in: store, generation: 1, items: items, placement: nil).isEmpty)
    #expect(DroppedTabs.Landing(store, windowId: window, generation: 1) == nil)
    #expect(store.state.windows[window]?.tabIds == before)
  }

  @Test func atMostFiftyTabsOpen() throws {
    let (store, window, _) = try window(tabs: 1)
    let items = (0..<60).map { ["kind": "url", "url": "https://x\($0).example/"] }
    #expect(DroppedTabs.open(store, windowId: window, items: items, placement: nil).count == DroppedTabs.maxTabs)
  }
}
