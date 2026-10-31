import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct ClosingWindowLiveTests {
  @Test func undoNeitherRecordsNorRestoresTransientFactsAndReusesTabIds() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    let otherWindow = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result?.string)
    let other = try #require(store.state.windows[otherWindow]?.tabIds.first)
    try store.transact { $0.update { $0.live[tab] = PageLiveFacts(isLoading: true) } }
    let before = store.state
    let original = try #require(before.windows[window])
    let snapshot: JSONValue = [
      "window": .object(original.json),
      "tabs": .array(original.tabIds.map { .object(before.tabs[$0]!.json) }),
      "groups": [],
      "splits": [],
    ]
    let changes = SequencerValues<LiveChange>()
    store.observeLive(tabId: tab) { changes.append($0) }
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let undo = try #require(store.memory.closingWindowUndos[window])
    #expect(undo.before.live.isEmpty)
    #expect(undo.after.live.isEmpty)
    try store.transact { $0.update {
      $0.live[tab] = nil
      $0.live[other] = PageLiveFacts(playingAudio: true)
    } }
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [snapshot, "chrome", [.string(tab)]])).result?.string)
    #expect(restored != window)
    #expect(store.state.windows[restored]?.tabIds == [tab])
    #expect(store.state.tabs[tab]?.url == before.tabs[tab]?.url)
    #expect(Set(store.state.live.keys) == Set(store.state.tabs.keys))
    #expect(store.state.live[other] == PageLiveFacts(playingAudio: true))
    #expect(store.state.live[tab] == PageLiveFacts())
    #expect(changes.all.count == 2)
    #expect(changes.all[0].current == nil)
    #expect(changes.all[1].previous == nil)
    #expect(changes.all[1].current == PageLiveFacts())
    try store.transact { $0.update { $0.live[tab] = PageLiveFacts(canGoBack: true) } }
    #expect(changes.all.count == 3)
    #expect(changes.all[2].previous == PageLiveFacts())
    #expect(changes.all[2].current == PageLiveFacts(canGoBack: true))
    #expect(changes.all[2].url == before.tabs[tab]?.url)
  }
}
