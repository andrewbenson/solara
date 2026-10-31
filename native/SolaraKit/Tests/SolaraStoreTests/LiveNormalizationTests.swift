import SolaraModel
@testable import SolaraStore
import Testing

private func normalizationFixture() throws -> (Store, [String]) {
  var config = StoreConfig()
  config.listeners = []
  let store = Store(memory: StoreMemory(ids: IdSource(launch: "normalize")), config: config, clock: { 1_000 })
  let window = try #require(store.dispatch(Command("createWindow", [["url": "https://first.example/"]])).result?.string)
  try store.dispatch(Command("newTab", [.string(window), ["url": "https://second.example/"]]))
  try store.dispatch(Command("newTab", [.string(window), ["url": "https://third.example/"]]))
  return (store, try #require(store.state.windows[window]?.tabIds))
}

@Suite struct LiveNormalizationTests {
  @Test func holdersUnloadCloseAndSwapNormalizeLive() throws {
    let (store, ids) = try normalizationFixture()
    let facts = PageLiveFacts(isLoading: true, canGoBack: true, playingAudio: true, themeColor: "blue")
    #expect(Set(store.state.live.keys) == Set(ids))
    #expect(store.state.live.values.allSatisfy { $0 == PageLiveFacts() })
    try store.transact { $0.update { $0.live[ids[0]] = facts } }
    let swapped = try store.transact { session in
      session.emit(.swapTabs(a: ids[0], b: ids[1]))
      session.update { $0.tabs[ids[1]]?.title = "Transferred" }
    }
    #expect(swapped.state.live[ids[0]] == facts)
    #expect(swapped.state.live[ids[1]] == facts)
    #expect(swapped.changes.live.upserted == [ids[1]])
    let unloaded = try store.transact { session in
      session.update { $0.tabs[ids[1]]?.unloaded = true }
    }
    #expect(unloaded.state.live[ids[1]] == PageLiveFacts())
    let closed = try store.dispatch(Command("closeTab", [.string(ids[2])]))
    #expect(closed.state.tabs[ids[2]] == nil)
    #expect(closed.state.live[ids[2]] == nil)
    #expect(closed.changes.live.removed.contains(ids[2]))
  }

  @Test func borrowerUpdatesWithoutTabMutation() throws {
    let (store, ids) = try normalizationFixture()
    try store.transact { session in
      session.update {
        $0.tabs[ids[1]]?.pageIn = ids[0]
        $0.tabs[ids[1]]?.navigation = nil
        $0.tabs[ids[2]]?.pageIn = ids[1]
        $0.tabs[ids[2]]?.navigation = nil
      }
    }
    let facts = PageLiveFacts(isLoading: true, playingAudio: true)
    let commit = try store.transact { $0.update { $0.live[ids[0]] = facts } }
    #expect(commit.changes.tabs.isEmpty)
    #expect(Set(commit.changes.live.upserted) == Set(ids))
    #expect(ids.allSatisfy { commit.state.live[$0] == facts })
    try store.transact { session in
      session.update { $0.tabs[ids[1]]?.pageIn = ids[2] }
    }
    #expect(store.state.live[ids[1]] == PageLiveFacts())
    #expect(store.state.live[ids[2]] == PageLiveFacts())
    try store.transact { session in
      session.update { $0.tabs[ids[1]]?.pageIn = "missing" }
    }
    #expect(store.state.live[ids[1]] == PageLiveFacts())
    #expect(store.state.live[ids[2]] == PageLiveFacts())
  }

  @Test func multipleSwapsAndReportsApplyEachLiveTransferOnce() throws {
    let (store, ids) = try normalizationFixture()
    let first = PageLiveFacts(isLoading: true, playingAudio: true)
    let second = PageLiveFacts(canGoBack: true, themeColor: "green")
    let final = PageLiveFacts(canGoForward: true, playingAudio: true)
    let commit = try store.transact { session in
      session.update { $0.live[ids[0]] = first }
      session.emit(.swapTabs(a: ids[0], b: ids[1]))
      session.update { $0.tabs[ids[1]]?.title = "First transfer" }
      #expect(session.state.live[ids[1]] == first)
      session.update { $0.live[ids[0]] = second }
      session.emit(.swapTabs(a: ids[0], b: ids[2]))
      session.update { $0.tabs[ids[2]]?.title = "Second transfer" }
      #expect(session.state.live[ids[2]] == second)
      session.update { $0.live[ids[1]] = final }
    }
    #expect(commit.state.live[ids[0]] == second)
    #expect(commit.state.live[ids[1]] == final)
    #expect(commit.state.live[ids[2]] == second)
    #expect(commit.effects == [.swapTabs(a: ids[0], b: ids[1]), .swapTabs(a: ids[0], b: ids[2])])
  }

  @Test func normalizationPrecedesPageSensitiveListeners() throws {
    let (store, ids) = try normalizationFixture()
    var config = StoreConfig()
    config.listeners = [.settleNesting, .livePinTable, .settlePeeks]
    let session = Session(state: store.state, memory: store.memory, env: PlainWebAddressing(), config: config, now: 1_000)
    session.update {
      $0.tabs[ids[1]]?.pageIn = ids[0]
      $0.tabs[ids[1]]?.navigation = nil
    }
    session.beginTransaction()
    session.update { $0.live[ids[0]] = PageLiveFacts(isLoading: true, playingAudio: true) }
    #expect(session.state.live[ids[1]] == session.state.live[ids[0]])
    #expect(session.heard == nil)
    session.update { $0.live[ids[0]] = PageLiveFacts(playingAudio: true) }
    #expect(session.state.live[ids[1]]?.isLoading == false)
    #expect(session.state.live[ids[1]]?.playingAudio == true)
    #expect(session.heard == nil)
    session.endTransaction()
  }

  @Test func settlementPrunesMemoryEvenWithoutALiveEntry() throws {
    let (store, ids) = try normalizationFixture()
    let id = ids[0]
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.transact { session in
      session.memory.pages["missing"] = session.memory.pages[id]
      session.memory.feedWatermark["missing"] = FeedWatermark(epoch: 1, generation: "G", seq: 8)
      session.memory.pageProducerFence["missing"] = PageProducerFence(generation: "G", retired: false)
      #expect(session.state.live["missing"] == nil)
      session.memory.pageProducerFence[id] = PageProducerFence(generation: "H", retired: false)
    }
    #expect(store.state.live["missing"] == nil)
    #expect(store.memory.pages["missing"] == nil)
    #expect(store.memory.feedWatermark["missing"] == nil)
    #expect(store.memory.pageProducerFence["missing"] == nil)
    #expect(store.memory.pageProducerFence[id]?.generation == "H")
  }

  @Test func loadingEdgesSurviveOneDrainAndHeldTransaction() throws {
    let (store, ids) = try normalizationFixture()
    let id = ids[0]
    let sequence = try #require(store.state.tabs[id]?.navigation?.seq)
    try store.dispatch(Command("pageReport", [.string(id), ["type": "created", "generation": "G", "engine": "chromium",
      "navigationSeq": .number(sequence), "contextRevision": 0, "wasNewTab": false, "newTabShownUrl": .null]]))
    let edges = SequencerValues<Bool?>()
    store.observeLive(tabId: id) { edges.append($0.current?.isLoading) }
    let baseline = store.rev
    try store.dispatch(Command("beginTransaction"))
    for loading in [true, false] {
      store.enqueuePageReport(id: id, report: ["type": "navigation", "generation": "G", "url": "https://first.example/",
        "title": "First", "isLoading": .bool(loading), "canGoBack": false, "canGoForward": false])
    }
    store.sequence {}
    #expect(edges.all == [true, false])
    #expect(store.rev == baseline + 2)
    try store.dispatch(Command("endTransaction"))
    #expect(edges.all == [true, false])
  }

  @Test func nativeLoadingCompletionFiresOncePerEdgeAcrossCommandArray() throws {
    let (store, ids) = try normalizationFixture()
    let id = ids[0]
    let sequence = try #require(store.state.tabs[id]?.navigation?.seq)
    try store.dispatch(Command("pageReport", [.string(id), ["type": "created", "generation": "G", "engine": "chromium",
      "navigationSeq": .number(sequence), "contextRevision": 0, "wasNewTab": false, "newTabShownUrl": .null]]))
    let edges = SequencerValues<Bool?>()
    store.observeLive(tabId: id) { edges.append($0.current?.isLoading) }
    let reports = [true, false, false].map { loading in
      Command("pageReport", [.string(id), ["type": "navigation", "generation": "G", "url": "https://first.example/",
        "title": "First", "isLoading": .bool(loading), "canGoBack": false, "canGoForward": false]])
    }
    let commit = try store.dispatch([Command("nextId", ["scope"])] + reports)
    #expect(edges.all == [true, false])
    #expect(commit.result?.string?.hasPrefix("scope-") == true)
    #expect(store.patches(since: commit.rev - 2)?.map(\.rev) == [commit.rev - 1, commit.rev])
  }
}
