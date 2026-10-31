import SolaraModel
import SolaraStore
import Testing

@Suite struct PageIngressOrderTests {
  @Test func reentrantDispatchCannotPassAnOlderQueuedReport() throws {
    let (store, id) = try phaseAPageFixture()
    let window = try #require(store.state.tabs[id]?.windowId)
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://active.example/"]]))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let baseline = store.rev
    let commits = SequencerValues<Commit>()
    let errors = SequencerValues<String>()
    store.subscribe { commit in
      commits.append(commit)
      if commit.rev == baseline + 1 {
        store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
        do { try store.dispatch(Command("clearUnpinnedTabs", [.string(window)])) }
        catch { errors.append(String(describing: error)) }
      }
    }
    store.enqueuePageReport(id: id, report: phaseANavigation(url: "https://queued.example/"))
    store.sequence {}
    #expect(errors.all.isEmpty)
    #expect(store.state.tabs[id]?.url == "https://queued.example/")
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(commits.all.prefix(2).map(\.origin) == [.engine, .engine])
    #expect(commits.all.prefix(2).map(\.rev) == [baseline + 1, baseline + 2])
  }

  @Test func reportEnqueuedInsideSequenceWaitsForNextBarrier() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let baseline = store.rev
    let edges = SequencerValues<Bool?>()
    store.observeLive(tabId: id) { edges.append($0.current?.playingAudio) }
    store.sequence {
      store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
      #expect(store.deliveryCursor().committed == baseline)
    }
    #expect(edges.all.isEmpty)
    let facts = store.pageFacts(id)
    #expect(facts?.generation == "G")
    #expect(edges.all == [true])
    #expect(store.rev == baseline + 1)
  }

  @Test func refusedSyncStillDrainsWithoutTaggingFactsAsSync() throws {
    let (store, id) = try phaseAPageFixture()
    store.useSyncOrigins(true)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let commits = SequencerValues<Commit>()
    store.subscribe { commits.append($0) }
    try store.dispatch(Command("beginTransaction"))
    store.enqueuePageReport(id: id, report: phaseANavigation(url: "https://engine.example/", loading: true))
    #expect(throws: StoreBusy.self) { try store.dispatch(settingsCommand(["appearance": "dark"]), origin: .sync) }
    let report = try #require(commits.all.last)
    #expect(report.origin == .engine)
    #expect(!report.fromSync)
    #expect(!report.patch.fromSync)
    #expect(report.state.tabs[id]?.url == "https://engine.example/")
    #expect(report.state.live[id]?.isLoading == true)
    #expect(store.queuedFromSyncCount == 0)
    try store.dispatch(Command("endTransaction"))
  }
}
