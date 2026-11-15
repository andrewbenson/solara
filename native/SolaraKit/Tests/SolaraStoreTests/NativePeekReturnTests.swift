import SolaraModel
import SolaraStore
import Testing

struct NativePeekReturnTests {
  @Test func selectingTheSourceEndsTheTemporaryViewAndKeepsPlayback() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    try store.transact { $0.update { $0.live[source] = PageLiveFacts(playingAudio: true) } }
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    try store.dispatch(Command("activate", [.string(source)]))
    #expect(store.state.peeks[window] == nil)
    #expect(store.state.tabs[peek] == nil)
    #expect(store.state.activeTabId(window) == source)
    #expect(store.state.live[source]?.playingAudio == true)
  }

  @Test func closingKeepsSourceSelectionAndPlayback() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    try store.transact { $0.update { $0.live[source] = PageLiveFacts(playingAudio: true) } }
    _ = try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"]))
    try store.dispatch(Command("closePeek", [.string(window)]))
    #expect(store.state.activeTabId(window) == source)
    #expect(store.state.live[source]?.playingAudio == true)
  }

  @Test func promotionKeepsTheSameTabIdentity() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    let promoted = try store.dispatch(Command("peekToTab", [.string(window)])).result?.string
    #expect(promoted == peek)
    #expect(store.state.windows[window]?.tabIds.contains(peek) == true)
    #expect(store.state.tabs[source] != nil)
  }
}
