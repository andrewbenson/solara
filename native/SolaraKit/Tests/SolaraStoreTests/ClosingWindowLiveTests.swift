import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct ClosingWindowLiveTests {
  @Test func structuralUndoExcludesLiveWhileTransientUndoRestoresFactsAndReusesTabIds() throws {
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
    #expect(store.state.live[tab] == PageLiveFacts(isLoading: true))
    #expect(changes.all.count == 2)
    #expect(changes.all[0].current == nil)
    #expect(changes.all[1].previous == nil)
    #expect(changes.all[1].current == PageLiveFacts(isLoading: true))
    try store.transact { $0.update { $0.live[tab] = PageLiveFacts(canGoBack: true) } }
    #expect(changes.all.count == 3)
    #expect(changes.all[2].previous == PageLiveFacts(isLoading: true))
    #expect(changes.all[2].current == PageLiveFacts(canGoBack: true))
    #expect(changes.all[2].url == before.tabs[tab]?.url)
  }

  private func snapshot(_ store: Store, _ window: String) -> JSONValue {
    let state = store.state
    let original = state.windows[window]!
    return ["window": .object(original.json), "tabs": .array(original.tabIds.map { .object(state.tabs[$0]!.json) }),
      "groups": .array(state.groups.values.filter { $0.windowId == window }.map { .object($0.json) }),
      "splits": .array(state.splits.values.filter { $0.windowId == window }.map { .object($0.json) })]
  }

  private func heldFixture() throws -> (Store, String, String, JSONValue) {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    let issue = try #require(try store.preparePooledIssue(id: tab, report: phaseAIssued(store, tab)))
    #expect(store.consumePooledIssue(id: tab, prepared: issue))
    try store.dispatch(phaseAReport(tab, phaseANavigation(loading: true)))
    try store.dispatch(phaseAReport(tab, ["type": "ready", "generation": "G", "browserId": 12]))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    return (store, window, tab, saved)
  }

  @Test func heldLoadedSurvivorsRestoreLiveInSameCommit() throws {
    let (store, window, tab, saved) = try heldFixture()
    let baseline = store.rev
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://newer.example/", loading: false)))
    try store.dispatch(phaseAReport(tab, ["type": "media", "generation": "G", "playing": true]))
    #expect(store.rev == baseline)
    #expect(store.state.tabs[tab] == nil)
    #expect(store.pageFacts(tab) == nil)
    #expect(store.memory.pages[tab] == nil)
    #expect(store.livePages().isEmpty)
    let commits = SequencerValues<Commit>()
    store.subscribe { commits.append($0) }
    let result = try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]]))
    let restored = try #require(result.result?.string)
    #expect(restored != window)
    #expect(commits.all.count == 1)
    #expect(commits.all.first?.state.tabs[tab]?.windowId == restored)
    #expect(commits.all.first?.state.tabs[tab]?.url == "https://newer.example/")
    #expect(commits.all.first?.state.live[tab]?.playingAudio == true)
    #expect(commits.all.first?.state.live[tab]?.isLoading == false)
    #expect(store.pageFacts(tab)?.generation == "G")
    #expect(store.pageFacts(tab)?.ready?.browserId == 12)
    #expect(store.memory.closingWindowUndos[window] == nil)
  }

  @Test func heldSurvivorKeepsAdoptedOpenerAndReturnsToItWhenClosed() throws {
    let (store, ancestor) = try phaseAPageFixture()
    let window = store.state.tabs[ancestor]!.windowId
    let parent = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://parent.example/", "background": true]])).result?.string)
    let child = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://child.example/", "background": true]])).result?.string)
    let other = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://other.example/", "background": true]])).result?.string)
    try store.dispatch(Command("activate", [.string(child)]))
    try store.dispatch(Command("updateTab", [.string(parent), ["openerId": .string(ancestor)]]))
    try store.dispatch(Command("updateTab", [.string(child), ["openerId": .string(parent)]]))
    try store.dispatch(phaseAReport(child, phaseACreated(store, child)))
    #expect(store.state.windows[window]?.tabIds == [ancestor, parent, child, other])
    #expect(store.state.windows[window]?.activeTabIds["default"] == child)
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.dispatch(phaseAReport(child, phaseANavigation(url: "https://survived.example/")))
    let restored = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(ancestor), .string(child), .string(other)]])).result?.string)
    #expect(store.state.windows[restored]?.tabIds == [ancestor, child, other])
    #expect(store.state.tabs[parent] == nil)
    #expect(store.state.tabs[child]?.windowId == restored)
    #expect(store.state.tabs[child]?.openerId == ancestor)
    #expect(store.state.tabs[child]?.url == "https://survived.example/")
    #expect(store.state.tabs[child]?.title == "Reported title")
    #expect(store.pageFacts(child)?.generation == "G")
    #expect(store.state.windows[restored]?.activeTabIds["default"] == child)
    try store.dispatch(Command("closeTabs", [[.string(child)]]))
    #expect(store.state.windows[restored]?.activeTabIds["default"] == ancestor)
  }

  @Test func missingAndUnloadedSurvivorsAreAbsentOrIdle() throws {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    let pin = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://pin.example/"]])).result?.string)
    let missing = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://missing.example/"]])).result?.string)
    try store.dispatch(Command("pinTabs", [[.string(pin)], true]))
    for id in [tab, pin, missing] {
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      try store.dispatch(phaseAReport(id, ["type": "media", "generation": "G", "playing": true]))
    }
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.tabs[missing] == nil)
    #expect(store.state.live[missing] == nil)
    #expect(store.pageFacts(missing) == nil)
    #expect(store.state.tabs[pin]?.unloaded == true)
    #expect(store.state.live[pin] == PageLiveFacts())
    #expect(store.pageFacts(pin) == nil)
    #expect(store.state.live[tab]?.playingAudio == true)
  }

  @Test func newerUnrelatedLiveSurvivesUndo() throws {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    let otherWindow = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result?.string)
    let other = try #require(store.state.windows[otherWindow]?.tabIds.first)
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    try store.dispatch(phaseAReport(other, phaseACreated(store, other, generation: "H")))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.dispatch(phaseAReport(other, ["type": "media", "generation": "H", "playing": true]))
    let expected = store.state.live[other]
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.live[other] == expected)
    #expect(store.memory.closingWindowUndos[window] == nil)
  }

  @Test func conflictingAffectedLiveRefusesWithoutConsumingUndo() throws {
    let (store, window, tab, saved) = try heldFixture()
    let current = store.state
    let session = Session(state: current, memory: store.memory, env: PlainWebAddressing(), config: StoreConfig(), now: 1_000)
    session.state.live[tab] = PageLiveFacts(playingAudio: true)
    let before = session.state
    let original = try BrowserWindow(json: saved["window"]!.object!)
    let tabs = try saved["tabs"]!.array!.map { try Tab(json: $0.object!) }
    #expect(session.restoreClosingWindow(original, tabs, [], [], chromeWindow: "chrome", liveTabIds: [tab]) == nil)
    #expect(session.state == before)
    #expect(session.memory.closingWindowUndos[window] != nil)
    session.state.live[tab] = PageLiveFacts()
    #expect(session.restoreClosingWindow(original, tabs, [], [], chromeWindow: "chrome", liveTabIds: [tab]) != nil)
  }

  @Test func restoredHeldTokenAcceptsNextReportWithoutReload() throws {
    let (store, _, tab, saved) = try heldFixture()
    let serial = try #require(store.memory.closingWindowUndos.values.first?.heldPages[tab]?.page.modelSerial)
    try store.dispatch(phaseAReport(tab, ["type": "failed", "generation": "G"]))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.memory.pages[tab]?.model.pending == nil)
    #expect(store.memory.pages[tab]!.modelSerial > serial)
    let restored = store.memory.pages[tab]!
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://after-cancel.example/")))
    #expect(store.state.tabs[tab]?.url == "https://after-cancel.example/")
    #expect(store.pageFacts(tab)?.generation == "G")
    #expect(store.pageFacts(tab)?.ready == restored.ready)
    #expect(try store.preparePooledIssue(id: tab, report: phaseAIssued(store, tab))?.actions == [])
  }

  @Test func retiredHeldTokenCannotResurrectMissingTab() throws {
    let (store, window, tab, saved) = try heldFixture()
    try store.dispatch(phaseAReport(tab, ["type": "gone", "generation": "G"]))
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://late.example/")))
    #expect(store.memory.closingWindowUndos[window]?.heldPages[tab] == nil)
    #expect(store.memory.closingWindowUndos[window]?.heldProducers[tab] == nil)
    #expect(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result == .null)
    #expect(store.state.tabs[tab] == nil)
    #expect(store.pageFacts(tab) == nil)
  }

  @Test func restoredPagesDoNotRestoreKeepAliveEpochValues() throws {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(tab, phaseAFeed(epoch: epoch, seq: 8)))
    try store.dispatch(phaseAReport(tab, ["type": "latch", "generation": "G", "eventSeq": 9]))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let baseline = store.memory.closingWindowUndos[window]
    try store.dispatch(phaseAReport(tab, phaseAFeed(epoch: epoch, seq: 9)))
    try store.dispatch(phaseAReport(tab, ["type": "latch", "generation": "G", "eventSeq": 10]))
    #expect(store.memory.closingWindowUndos[window] == baseline)
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.pageFacts(tab)?.keepAlive == nil)
    #expect(store.pageFacts(tab)?.latchedThrough == 0)
    #expect(store.memory.feedWatermark[tab] == nil)
    #expect(store.memory.currentEpoch == epoch)
    try store.dispatch(phaseAReport(tab, phaseAFeed(epoch: epoch, seq: 1)))
    #expect(store.pageFacts(tab)?.keepAlive?.seq == 1)
  }

  @Test(arguments: ["current", "missing", "retired"]) func noSeedHeldProducerRecoversOnlyWithCurrentNonretiredFence(authority: String) throws {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    try store.transact { session in
      session.memory.pages[tab] = nil
      if authority == "missing" { session.memory.pageProducerFence[tab] = nil }
      if authority == "retired" { session.memory.pageProducerFence[tab]?.retired = true }
    }
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    #expect(store.memory.closingWindowUndos[window]?.heldPages[tab] == nil)
    try store.dispatch(phaseAReport(tab, ["type": "media", "generation": "G", "playing": true]))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.pageFacts(tab) == nil)
    try store.dispatch(phaseAReport(tab, ["type": "media", "generation": "G", "playing": true]))
    #expect(store.state.live[tab]?.playingAudio == false)
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab, reestablished: true)))
    #expect((store.pageFacts(tab) != nil) == (authority == "current"))
    if authority != "current" {
      try store.dispatch(phaseAReport(tab, phaseACreated(store, tab, generation: "H")))
      #expect(store.pageFacts(tab)?.generation == "H")
    }
  }

  @Test func heldLoadingThenDownloadRestoresStoppedLoading() throws {
    let (store, _, tab, saved) = try heldFixture()
    let baseline = store.rev
    try store.dispatch(phaseAReport(tab, ["type": "download", "generation": "G", "committedUrl": "https://download.example/"]))
    #expect(store.rev == baseline)
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.tabs[tab]?.url == "https://download.example/")
    #expect(store.state.live[tab]?.isLoading == false)
    #expect(store.memory.pages[tab]?.model.pending == nil)
  }

  @Test func heldReadyMediaThenDiscardRestoresDiscardedAndSilent() throws {
    let (store, _, tab, saved) = try heldFixture()
    try store.dispatch(phaseAReport(tab, ["type": "ready", "generation": "G", "browserId": 19]))
    try store.dispatch(phaseAReport(tab, ["type": "media", "generation": "G", "playing": true]))
    try store.dispatch(phaseAReport(tab, ["type": "discarded", "generation": "G", "url": "https://discarded.example/"]))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.live[tab]?.discarded == true)
    #expect(store.state.live[tab]?.playingAudio == false)
    #expect(store.state.live[tab]?.isLoading == false)
    #expect(store.memory.pages[tab]?.model.pending == "https://discarded.example/")
    #expect(store.pageFacts(tab)?.ready?.browserId == 19)
  }

  @Test func heldFailureDoesNotReplayOlderPendingNavigation() throws {
    let (store, _, tab, saved) = try heldFixture()
    try store.dispatch(phaseAReport(tab, ["type": "loadError", "generation": "G"]))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.memory.pages[tab]?.model.pending == nil)
    #expect(store.state.live[tab]?.isLoading == false)
  }

  @Test func heldTerminalCloseDoesNotRestoreLoadedSurvivor() throws {
    let (store, tab) = try phaseAPageFixture()
    let window = store.state.tabs[tab]!.windowId
    let other = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://other.example/"]])).result?.string)
    try store.dispatch(Command("updateTab", [.string(tab), ["openerId": .string(other), "adoptId": "tab:12"]]))
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.dispatch(phaseAReport(tab, ["type": "download", "generation": "G"]))
    #expect(store.memory.closingWindowUndos[window]?.heldPages[tab]?.restorable == false)
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab), .string(other)]])).result?.string)
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.tabs[other] != nil)
    #expect(store.pageFacts(tab) == nil)
  }

  @Test func staleOrUnseededHeldReportsCannotCreateState() throws {
    let (store, window, tab, _) = try heldFixture()
    let memory = store.memory
    let baseline = store.rev
    try store.dispatch(phaseAReport(tab, phaseANavigation(generation: "H", url: "https://stale.example/")))
    try store.dispatch(phaseAReport("missing", phaseANavigation()))
    #expect(store.rev == baseline)
    #expect(store.memory.closingWindowUndos[window] == memory.closingWindowUndos[window])
    #expect(store.state.tabs[tab] == nil)
  }


  @Test(arguments: [false, true]) func heldPrewarmAdoptionThenFailureKeepsCurrentModelWithoutHistoricalLoad(newerNavigation: Bool) throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [])).result?.string)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    let baseline = store.memory.navSeq
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://adopted.example/")))
    if newerNavigation { try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://current.example/"))) }
    try store.dispatch(phaseAReport(tab, ["type": "loadError", "generation": "G"]))
    #expect(store.memory.navSeq == baseline)
    #expect(store.memory.closingWindowUndos[window]?.heldPages[tab]?.page.model.pending == nil)
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.memory.navSeq == baseline + 1)
    #expect(store.state.tabs[tab]?.url == (newerNavigation ? "https://current.example/" : "https://adopted.example/"))
    #expect(store.state.tabs[tab]?.navigation?.url == "https://adopted.example/")
    #expect(store.memory.pages[tab]?.model.pending == nil)
    let prepared = try #require(try store.preparePooledIssue(id: tab, report: phaseAIssued(store, tab)))
    #expect(prepared.actions == [])
    #expect(store.consumePooledIssue(id: tab, prepared: prepared))
    #expect(try store.preparePooledIssue(id: tab, report: phaseAIssued(store, tab))?.actions == [])
  }


  @Test func heldURLProjectionKeepsNativeMutePinHomeAndWakeAdoptionRules() throws {
    let (base, tab) = try phaseAPageFixture()
    var state = base.state
    let window = state.tabs[tab]!.windowId
    state.tabs[tab]!.pinned = true
    state.tabs[tab]!.pinnedUrl = nil
    state.tabs[tab]!.wakeAdoptId = "restore:old"
    state.settings = Settings.hydrated(from: ["mutedSites": ["first.example"]])
    var config = StoreConfig()
    config.listeners = []
    let store = Store(state: state, memory: base.memory, config: config, checksInvariants: false, clock: { 1_000 })
    try store.dispatch(phaseAReport(tab, phaseACreated(store, tab)))
    let saved = snapshot(store, window)
    try store.dispatch(Command("closeWindow", [.string(window)]))
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://first.example/")))
    let first = store.memory.closingWindowUndos[window]?.heldPages[tab]?.tab
    #expect(first?.muted == true)
    #expect(first?.pinnedUrl == "https://first.example/")
    #expect(first?.wakeAdoptId == nil)
    try store.dispatch(phaseAReport(tab, phaseANavigation(url: "https://second.example/")))
    _ = try #require(try store.dispatch(Command("restoreClosingWindow", [saved, "chrome", [.string(tab)]])).result?.string)
    #expect(store.state.tabs[tab]?.url == "https://second.example/")
    #expect(store.state.tabs[tab]?.muted == false)
    #expect(store.state.tabs[tab]?.pinnedUrl == "https://first.example/")
    #expect(store.state.tabs[tab]?.wakeAdoptId == nil)
  }

}
