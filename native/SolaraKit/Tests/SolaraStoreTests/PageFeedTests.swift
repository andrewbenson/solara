import SolaraModel
@testable import SolaraStore
import Testing

func phaseAPageFixture(engine: String = "chromium") throws -> (Store, String) {
  let store = makeStore()
  let window = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result!.string!
  let id = store.state.windows[window]!.tabIds[0]
  if engine != "chromium" { try store.dispatch(Command("updateTab", [.string(id), ["engine": .string(engine)]])) }
  return (store, id)
}

func phaseAContext(_ store: Store, _ id: String, revision: Int = 1, shown: String? = nil) -> JSONObject {
  ["navigationSeq": store.state.tabs[id]?.navigation.map { JSONValue($0.seq) } ?? .null,
    "contextRevision": JSONValue(revision), "wasNewTab": false, "newTabShownUrl": JSONValue(shown)]
}

func phaseACreated(_ store: Store, _ id: String, generation: String = "G", engine: String = "chromium", reestablished: Bool = false) -> JSONValue {
  var report = phaseAContext(store, id)
  report["type"] = "created"
  report["generation"] = .string(generation)
  report["engine"] = .string(engine)
  if reestablished { report["reestablished"] = true }
  return .object(report)
}

func phaseAReport(_ id: String, _ report: JSONValue) -> Command { Command("pageReport", [.string(id), report]) }

func phaseAFeed(generation: String = "G", epoch: Int, seq: Int, handled: Int = 0) -> JSONValue {
  ["type": "keepAlive", "generation": .string(generation), "epoch": JSONValue(epoch), "seq": JSONValue(seq), "handled": JSONValue(handled),
    "keep": ["capturing": false, "newTabShown": false, "pip": false, "displayRequest": false, "media": "none"],
    "reveal": ["fullscreen": false, "crashed": false, "unresponsive": false, "scrolledDown": false, "sharing": false]]
}

@Suite struct PageFeedTests {
  @Test func retiredRuntimeTA8ThenBThenTA7StaysProtected() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let a = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: a, seq: 8)))
    #expect(store.pageFacts(id)?.keepAlive?.seq == 8)
    let b = store.registerKeepAliveRuntime()
    #expect(b == a + 1)
    let revision = store.rev
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: a, seq: 7)))
    #expect(store.pageFacts(id)?.keepAlive == nil)
    #expect(store.rev == revision)
  }

  @Test func registeringRuntimeClearsEveryValueAndKeepsWatermarks() throws {
    let (store, id) = try phaseAPageFixture()
    let other = try store.dispatch(Command("newTab", [.string(store.state.tabs[id]!.windowId), ["url": "https://other.example/"]])).result!.string!
    for tab in [id, other] { try store.dispatch(phaseAReport(tab, phaseACreated(store, tab))) }
    let epoch = store.registerKeepAliveRuntime()
    for tab in [id, other] {
      try store.dispatch(phaseAReport(tab, ["type": "ready", "generation": "G", "browserId": 12]))
      try store.dispatch(phaseAReport(tab, ["type": "latch", "generation": "G", "eventSeq": 4]))
      try store.dispatch(phaseAReport(tab, phaseAFeed(epoch: epoch, seq: 3)))
    }
    let watermarks = store.memory.feedWatermark
    _ = store.registerKeepAliveRuntime()
    #expect(store.memory.feedWatermark == watermarks)
    for tab in [id, other] {
      #expect(store.pageFacts(tab)?.keepAlive == nil)
      #expect(store.pageFacts(tab)?.ready?.browserId == 12)
      #expect(store.pageFacts(tab)?.latchedThrough == 4)
    }
  }

  @Test func generationChangeResetsWatermarkAgainstItsOwnGeneration() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "G"]))
    #expect(store.memory.feedWatermark[id]?.seq == 8)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
    #expect(store.memory.feedWatermark[id] == nil)
    try store.dispatch(phaseAReport(id, phaseAFeed(generation: "H", epoch: epoch, seq: 1)))
    #expect(store.pageFacts(id)?.keepAlive?.seq == 1)
  }

  @Test func tabRemovalClearsPageAndWatermark() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    try store.dispatch(Command("closeTab", [.string(id)]))
    #expect(store.pageFacts(id) == nil)
    #expect(store.memory.pages[id] == nil)
    #expect(store.memory.feedWatermark[id] == nil)
    #expect(store.memory.pageProducerFence[id] == nil)
  }

  @Test func epochZeroAndUnregisteredFeedsDropSilently() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let failures = SequencerValues<String>()
    store.observeSequencedFailures { _, error in failures.append(String(describing: error)) }
    let revision = store.rev
    store.enqueuePageReport(id: id, report: phaseAFeed(epoch: 0, seq: 1))
    store.enqueuePageReport(id: id, report: phaseAFeed(epoch: 1, seq: 1))
    #expect(store.pageFacts(id)?.keepAlive == nil)
    #expect(store.rev == revision)
    #expect(failures.all.isEmpty)
  }

  @Test func sameEpochRequiresStrictlyIncreasingSequenceAfterValueWipe() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    try store.transact { $0.memory.pages[id] = nil }
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    for sequence in [7, 8] { try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: sequence))) }
    #expect(store.pageFacts(id)?.keepAlive == nil)
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 9)))
    #expect(store.pageFacts(id)?.keepAlive?.seq == 9)
  }

  @Test func goneAndUnloadKeepWatermark() throws {
    for gone in [false, true] {
      let (store, id) = try phaseAPageFixture()
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      let epoch = store.registerKeepAliveRuntime()
      try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
      if gone { try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "G"])) }
      else { try store.dispatch(Command("updateTab", [.string(id), ["unloaded": true]])) }
      #expect(store.pageFacts(id) == nil)
      #expect(store.memory.feedWatermark[id]?.seq == 8)
    }
  }

  @Test func latchTakesMaximumAndFeedAndLatchNeverCommit() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    let baseline = store.rev
    let commits = SequencerValues<Int>()
    let live = SequencerValues<LiveChange>()
    store.subscribe { commits.append($0.rev) }
    store.observeLive { live.append($0) }
    for sequence in [3, 8, 4, 8, 0] { try store.dispatch(phaseAReport(id, ["type": "latch", "generation": "G", "eventSeq": JSONValue(sequence)])) }
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 1, handled: 6)))
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 1, handled: 8)))
    #expect(store.pageFacts(id)?.latchedThrough == 8)
    #expect(store.pageFacts(id)?.keepAlive?.handled == 6)
    #expect(store.rev == baseline)
    #expect(store.patches(since: baseline)?.isEmpty == true)
    #expect(commits.all.isEmpty)
    #expect(live.all.isEmpty)
  }

  @Test func missingTabMemoryOrGenerationNeverCreatesFeedPage() throws {
    let (store, id) = try phaseAPageFixture()
    let epoch = store.registerKeepAliveRuntime()
    let baseline = store.rev
    try store.dispatch(phaseAReport("missing", phaseAFeed(epoch: epoch, seq: 1)))
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 1)))
    #expect(store.pageFacts(id) == nil)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, phaseAFeed(generation: "H", epoch: epoch, seq: 1)))
    for number in [Double(-1), 0.5, .infinity, .nan, 9_007_199_254_740_992] {
      var malformed = phaseAFeed(epoch: epoch, seq: 1).object!
      malformed["seq"] = .number(number)
      try store.dispatch(phaseAReport(id, .object(malformed)))
    }
    try store.dispatch(phaseAReport(id, ["type": "latch", "eventSeq": 5]))
    #expect(store.pageFacts(id)?.keepAlive == nil)
    #expect(store.pageFacts(id)?.latchedThrough == 0)
    #expect(store.rev == baseline)
    #expect(throws: CommandError.self) { try store.dispatch(phaseAReport(id, ["type": "unknown"])) }
  }

  @Test func pageFactsAndLivePagesDrainAndReturnIndependentCopies() throws {
    let (store, id) = try phaseAPageFixture()
    let epoch = store.registerKeepAliveRuntime()
    store.enqueuePageReport(id: id, report: phaseACreated(store, id))
    store.enqueuePageReport(id: id, report: ["type": "ready", "generation": "G", "browserId": 12, "tabId": 34, "eventSeq": 7])
    store.enqueuePageReport(id: id, report: ["type": "latch", "generation": "G", "eventSeq": 6])
    store.enqueuePageReport(id: id, report: phaseAFeed(epoch: epoch, seq: 1))
    let previous = store.livePages()
    #expect(previous[id]?.ready == PageReadyFacts(browserId: 12, tabId: 34))
    #expect(previous[id]?.latchedThrough == 6)
    #expect(previous[id]?.newestEventSeq == 7)
    #expect(previous[id]?.keepAlive?.seq == 1)
    try store.dispatch(phaseAReport(id, ["type": "latch", "generation": "G", "eventSeq": 9]))
    #expect(store.pageFacts(id)?.latchedThrough == 9)
    #expect(previous[id]?.latchedThrough == 6)
    try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "G"]))
    #expect(store.livePages()[id] == nil)
    #expect(previous[id] != nil)
  }

  @Test func registrationDrainsOlderReportsWithoutStateRevisionOfItsOwn() throws {
    let (store, id) = try phaseAPageFixture()
    let baseline = store.memory.currentEpoch
    let revision = store.rev
    store.enqueuePageReport(id: id, report: phaseACreated(store, id))
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    let epoch = store.registerKeepAliveRuntime()
    #expect(epoch == baseline + 1)
    #expect(store.rev == revision + 1)
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(store.pageFacts(id)?.keepAlive == nil)
  }

  @Test func registrationRefusesSafeIntegerExhaustionBeforeMutation() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    try store.transact { $0.memory.currentEpoch = pageMaximumSafeInteger }
    let before = store.memory
    let revision = store.rev
    #expect(throws: CommandError.self) { try store.dispatch(Command("registerKeepAliveRuntime")) }
    #expect(store.memory == before)
    #expect(store.rev == revision)
  }

  @Test func swapDoesNotTransferKeepAliveOrReady() throws {
    let (store, id) = try phaseAPageFixture()
    let other = try store.dispatch(Command("newTab", [.string(store.state.tabs[id]!.windowId), ["url": "https://other.example/"]])).result!.string!
    for tab in [id, other] { try store.dispatch(phaseAReport(tab, phaseACreated(store, tab))) }
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, ["type": "ready", "generation": "G", "browserId": 12]))
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 1)))
    try store.dispatch(phaseAReport(id, ["type": "media", "generation": "G", "playing": true]))
    try store.transact { $0.emit(.swapTabs(a: id, b: other)) }
    #expect(store.state.live[other]?.playingAudio == true)
    #expect(store.pageFacts(other) == nil)
    #expect(store.pageFacts(id)?.ready?.browserId == 12)
    #expect(store.pageFacts(id)?.keepAlive?.seq == 1)
  }
}
