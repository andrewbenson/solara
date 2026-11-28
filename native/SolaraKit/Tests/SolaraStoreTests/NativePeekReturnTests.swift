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

  @Test func aDelayedRendererOpenCannotReopenADismissedPeek() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let receipt = try #require(PageOpenSource(state: store.state, memory: store.memory, tabId: source))
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    _ = try store.dispatch(Command("closePeek", [.string(window), .string(peek)]))
    try store.transact { $0.openFromPage(receipt, request: ["url": "https://late.test/", "disposition": "peek"]) }
    #expect(store.state.peeks[window] == nil)
    #expect(store.state.activeTabId(window) == source)
  }

  @Test func delayedCloseAndPromotionOnlyAffectTheirOwnPeek() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let first = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://first.test/"])).result?.string)
    let second = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://second.test/"])).result?.string)
    try store.dispatch(Command("closePeek", [.string(window), .string(first)]))
    try store.dispatch(Command("peekToTab", [.string(window), ["tabId": .string(first)]]))
    #expect(store.state.peeks[window]?.tabId == second)
    #expect(store.state.activeTabId(window) == source)
  }

  @Test func dismissalRejectsNewAndAlreadyQueuedOpensWhileBackgroundAudioContinues() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let background = try #require(try store.dispatch(Command("newTab", [.string(window), ["background": true, "url": "https://audio.test/"]])).result?.string)
    try store.transact { $0.update { $0.live[background] = PageLiveFacts(playingAudio: true) } }
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    let queued = try #require(PageOpenSource(state: store.state, memory: store.memory, tabId: source))
    try store.transact { session in
      #expect(session.beginPeekDismissal(window, tabId: peek))
      #expect(!session.beginPeekDismissal(window, tabId: peek))
      session.openFromPage(queued, request: ["url": "https://late.test/", "disposition": "peek"])
    }
    #expect(store.state.peeks[window]?.tabId == peek)
    #expect(PageOpenSource(state: store.state, memory: store.memory, tabId: source) == nil)
    try store.dispatch(Command("closePeek", [.string(window), .string(peek)]))
    #expect(store.state.activeTabId(window) == source)
    #expect(store.state.live[background]?.playingAudio == true)
    #expect(PageOpenSource(state: store.state, memory: store.memory, tabId: source) != nil)
  }

  @Test func explicitNavigationRejectsThePreviousDocumentAndEndsItsPeek() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    let receipt = try #require(PageOpenSource(state: store.state, memory: store.memory, tabId: source))
    try store.dispatch(Command("navigate", [.string(source), "https://elsewhere.test/"]))
    try store.transact { $0.openFromPage(receipt, request: ["url": "https://late.test/", "disposition": "peek"]) }
    #expect(store.state.peeks[window]?.tabId == peek)
    try store.dispatch(Command("navigated", [.string(source), ["url": "https://elsewhere.test/"]]))
    #expect(store.state.peeks[window] == nil)
    #expect(store.state.activeTabId(window) == source)
  }

  @Test func rendererSplitUsesThePeekSourceAndKeepsTheSourceSelected() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let peek = try #require(try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"])).result?.string)
    let receipt = try #require(PageOpenSource(state: store.state, memory: store.memory, tabId: peek))
    try store.transact { $0.openFromPage(receipt, request: ["url": "https://split.test/", "disposition": "split", "adoptId": "adopt-split"]) }
    let split = try #require(Splits.splitOf(store.state, source))
    let sibling = try #require(split.tabIds.last)
    #expect(store.state.tabs[sibling]?.openerId == source)
    #expect(store.state.tabs[sibling]?.adoptId == "adopt-split")
    #expect(store.state.activeTabId(window) == source)
    #expect(store.state.peeks[window]?.tabId == peek)
  }
}
