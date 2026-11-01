import SolaraModel
@testable import SolaraStore
import Testing

func phaseANavigation(generation: String = "G", url: String = "https://page.example/", loading: Bool = false) -> JSONValue {
  ["type": "navigation", "generation": .string(generation), "url": .string(url), "title": "Reported title",
    "isLoading": .bool(loading), "canGoBack": false, "canGoForward": false]
}

func phaseAIssued(_ store: Store, _ id: String, generation: String = "G", revision: Int = 1, shown: String? = nil) -> JSONValue {
  var report = phaseAContext(store, id, revision: revision, shown: shown)
  report["type"] = "issued"
  report["generation"] = .string(generation)
  report["navigation"] = store.state.tabs[id]?.navigation?.jsonValue ?? .null
  report["startedEarly"] = false
  return .object(report)
}

@Suite struct PageReportTests {
  @Test func drainsReportsBeforeNavigateActivationAndStrip() throws {
    for command in ["navigate", "activate", "stripSnapshot"] {
      let (store, id) = try phaseAPageFixture()
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      let baseline = store.rev
      let commits = SequencerValues<Commit>()
      store.subscribe { commits.append($0) }
      store.enqueuePageReport(id: id, report: phaseANavigation(url: "https://reported.example/"))
      store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
      switch command {
      case "navigate": try store.dispatch(Command(command, [.string(id), "https://next.example/"]))
      case "activate": try store.dispatch(Command(command, [.string(id)]))
      default: try store.dispatch(Command(command, [["strip": 1, "window": 1, "profile": "default", "tabs": []]]))
      }
      #expect(commits.all.prefix(2).map(\.rev) == [baseline + 1, baseline + 2])
      #expect(commits.all.first?.state.tabs[id]?.url == "https://reported.example/")
      #expect(commits.all.dropFirst().first?.state.live[id]?.playingAudio == true)
    }
  }

  @Test func nativeLoadingCompletionFiresOncePerEdgeAcrossCommandArray() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let edges = SequencerValues<Bool>()
    store.observeLive(tabId: id) { change in
      if change.previous?.isLoading != change.current?.isLoading, let current = change.current { edges.append(current.isLoading) }
    }
    let revision = store.rev
    let commit = try store.dispatch([
      phaseAReport(id, phaseANavigation(loading: true)),
      Command("nextId", ["test"]),
      phaseAReport(id, phaseANavigation(loading: false)),
    ])
    #expect(edges.all == [true, false])
    #expect(commit.rev == revision + 2)
    #expect(commit.result?.string?.hasPrefix("test") == true)
    #expect(store.state.tabs[id]?.title == "Reported title")
  }

  @Test func oldPageSessionGenerationCannotMutateReplacement() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
    let baseline = store.snapshot
    let reports: [JSONValue] = [
      phaseANavigation(), ["type": "media", "generation": "G", "playing": true],
      ["type": "ready", "generation": "G", "browserId": 12], ["type": "gone", "generation": "G"],
      ["type": "discarded", "generation": "G", "url": "https://old.example/"],
      ["type": "download", "generation": "G"], ["type": "failed", "generation": "G"],
      ["type": "loadError", "generation": "G"], ["type": "advance", "generation": "G"],
      ["type": "moved", "generation": "G", "sameProfile": true], ["type": "media", "playing": true],
    ]
    for report in reports { try store.dispatch(phaseAReport(id, report)) }
    #expect(store.snapshot.state == baseline.state)
    #expect(store.rev == baseline.rev)
    #expect(store.pageFacts(id)?.generation == "H")
    #expect(store.memory.pageProducerFence[id]?.retired == false)
  }

  @Test func createdNewGenerationClearsDiscardedButDiscardKeepsGeneration() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, ["type": "media", "generation": "G", "playing": true]))
    try store.dispatch(phaseAReport(id, ["type": "discarded", "generation": "G", "url": "https://page.example/"]))
    #expect(store.state.live[id]?.discarded == true)
    #expect(store.state.live[id]?.playingAudio == false)
    #expect(store.pageFacts(id)?.generation == "G")
    try store.dispatch(phaseAReport(id, ["type": "ready", "generation": "G", "browserId": 12]))
    #expect(store.state.live[id]?.discarded == false)
    try store.dispatch(phaseAReport(id, ["type": "discarded", "generation": "G", "url": "https://page.example/"]))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
    #expect(store.state.live[id] == PageLiveFacts())
    #expect(store.pageFacts(id)?.generation == "H")
    #expect(store.pageFacts(id)?.ready == nil)
    #expect(!Command.known.contains("setDiscarded"))
  }

  @Test func goneGenerationRemainsRetired() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.transact { $0.memory.pages[id] = nil }
    try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "G"]))
    #expect(store.memory.pageProducerFence[id]?.retired == true)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    #expect(store.pageFacts(id) == nil)
    #expect(store.state.live[id] == PageLiveFacts())
  }

  @Test func sameGenerationReestablishmentPreservesWatermarkAndRejectsRetiredFence() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(id, ["type": "ready", "generation": "G", "browserId": 12, "eventSeq": 8]))
    try store.dispatch(phaseAReport(id, ["type": "latch", "generation": "G", "eventSeq": 8]))
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    let serial = store.memory.pages[id]!.modelSerial
    try store.dispatch(Command("updateTab", [.string(id), ["unloaded": true]]))
    try store.dispatch(Command("activate", [.string(id)]))
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    #expect(store.pageFacts(id) == nil)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    #expect(store.pageFacts(id) == nil)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    #expect(store.pageFacts(id)?.generation == "G")
    #expect(store.pageFacts(id)?.ready == nil)
    #expect(store.pageFacts(id)?.keepAlive == nil)
    #expect(store.pageFacts(id)?.latchedThrough == 0)
    #expect(store.pageFacts(id)?.newestEventSeq == 0)
    #expect(store.memory.pages[id]!.modelSerial > serial)
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    #expect(store.pageFacts(id)?.keepAlive == nil)
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 9)))
    #expect(store.pageFacts(id)?.keepAlive?.seq == 9)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
    try store.transact { $0.memory.pages[id] = nil }
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    #expect(store.pageFacts(id) == nil)
    try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "H"]))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H", reestablished: true)))
    #expect(store.pageFacts(id) == nil)
  }

  @Test func retainedWebKitCreationDoesNotConsumeUnexecutedNavigation() throws {
    for engine in ["chromium", "webkit"] {
      let (store, id) = try phaseAPageFixture(engine: engine)
      try store.dispatch(phaseAReport(id, phaseACreated(store, id, engine: engine)))
      let executedSequence = store.state.tabs[id]!.navigation!.seq
      try store.dispatch(Command("updateTab", [.string(id), ["unloaded": true]]))
      try store.dispatch(Command("activate", [.string(id)]))
      try store.dispatch(Command("navigate", [.string(id), "https://pending.example/"]))
      var recovered = phaseACreated(store, id, engine: engine, reestablished: true).object!
      recovered["handoffSeq"] = JSONValue(executedSequence)
      try store.dispatch(phaseAReport(id, .object(recovered)))
      let candidate = try store.preparePooledIssue(id: id, report: phaseAIssued(store, id))
      #expect(candidate?.actions == [["type": "load", "url": "https://pending.example/", "userInitiated": true]])
      #expect(store.consumePooledIssue(id: id, prepared: try #require(candidate)))
      let next = try store.preparePooledIssue(id: id, report: phaseAIssued(store, id))
      #expect(next?.actions == [])
    }
  }

  @Test func compatibleSetPlayingAudioStillDispatches() throws {
    let (store, id) = try phaseAPageFixture()
    #expect(Command.known.contains("setPlayingAudio"))
    try store.dispatch(Command("setPlayingAudio", [[.string(id)]]))
    #expect(store.state.caches.playingAudio == [id])
    #expect(store.state.live[id]?.playingAudio == false)
    let window = store.state.tabs[id]!.windowId
    _ = try store.dispatch(Command("newTab", [.string(window), ["url": "https://active.example/"]]))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    try store.dispatch(Command("setPlayingAudio", [[]]))
    try store.dispatch(Command("clearUnpinnedTabs", [.string(window)]))
    #expect(store.state.tabs[id] != nil)
    #expect(store.state.caches.playingAudio.isEmpty)
  }

  @Test func queuedReportFailureUsesExistingTroublePath() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let errors = SequencerValues<String>()
    store.observeSequencedFailures { command, error in errors.append("\(command.name):\(error)") }
    store.enqueuePageReport(id: id, report: ["type": "navigation", "generation": "G", "url": 17])
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    store.sequence {}
    #expect(errors.all.count == 1)
    #expect(errors.all.first?.contains("malformed navigation") == true)
    #expect(store.state.live[id]?.playingAudio == true)
  }

  @Test func downloadURLSettlementAlreadyContainsStoppedLoading() throws {
    for committed in [nil, "https://download.example/"] as [String?] {
      let (store, id) = try phaseAPageFixture()
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      try store.dispatch(phaseAReport(id, phaseANavigation(loading: true)))
      let before = store.state
      var config = StoreConfig()
      config.listeners = []
      let session = Session(state: before, memory: store.memory, env: PlainWebAddressing(), config: config, now: 0)
      session.beginTransaction()
      try session.pageReport(id, ["type": "download", "generation": "G", "committedUrl": JSONValue(committed)])
      #expect(session.state.tabs[id]?.url == (committed ?? ""))
      #expect(session.state.live[id]?.isLoading == false)
      #expect(session.heard == nil)
      #expect(session.pageMoved(session.state, before))
      #expect(session.memory.pages[id]?.live.facts?.isLoading == false)
    }
  }

  @Test func hydrateResetsLiveAndPages() throws {
    let (store, id) = try phaseAPageFixture()
    var document = store.sessionDocument().json().object!
    document["live"] = .object([id: ["isLoading": true, "playingAudio": true]])
    let other = try store.dispatch(Command("newTab", [.string(store.state.tabs[id]!.windowId), ["url": "https://removed.example/"]])).result!.string!
    for tab in [id, other] { try store.dispatch(phaseAReport(tab, phaseACreated(store, tab))) }
    let epoch = store.registerKeepAliveRuntime()
    for tab in [id, other] {
      try store.dispatch(phaseAReport(tab, phaseANavigation(loading: true)))
      try store.dispatch(phaseAReport(tab, ["type": "media", "generation": "G", "playing": true]))
      try store.dispatch(phaseAReport(tab, ["type": "ready", "generation": "G", "browserId": 12, "eventSeq": 8]))
      try store.dispatch(phaseAReport(tab, ["type": "latch", "generation": "G", "eventSeq": 8]))
      try store.dispatch(phaseAReport(tab, phaseAFeed(epoch: epoch, seq: 8)))
    }
    let closedWindow = try store.dispatch(Command("createWindow", [["url": "https://closed.example/"]])).result!.string!
    try store.dispatch(Command("closeWindow", [.string(closedWindow)]))
    #expect(!store.memory.closingWindowUndos.isEmpty)
    let serial = store.memory.nextPageModelSerial
    try store.dispatch(Command("hydrate", [.object(document)]))
    #expect(store.state.live == [id: PageLiveFacts()])
    #expect(store.livePages().isEmpty)
    #expect(store.pageFacts(id) == nil)
    #expect(store.memory.pages.isEmpty)
    #expect(store.memory.currentEpoch == epoch)
    #expect(store.memory.feedWatermark[id]?.seq == 8)
    #expect(store.memory.pageProducerFence[id] == PageProducerFence(generation: "G", retired: false))
    #expect(store.memory.feedWatermark[other] == nil)
    #expect(store.memory.pageProducerFence[other] == nil)
    #expect(store.memory.closingWindowUndos.isEmpty)
    #expect(store.memory.nextPageModelSerial == serial)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    #expect(store.pageFacts(id)?.ready == nil)
    #expect(store.pageFacts(id)?.keepAlive == nil)
    #expect(store.pageFacts(id)?.latchedThrough == 0)
    #expect(store.pageFacts(id)?.newestEventSeq == 0)
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 8)))
    #expect(store.pageFacts(id)?.keepAlive == nil)
    try store.dispatch(phaseAReport(id, phaseAFeed(epoch: epoch, seq: 9)))
    #expect(store.pageFacts(id)?.keepAlive?.seq == 9)
  }

  @Test func malformedCurrentIssuedReportsUseFailureFanOut() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let errors = SequencerValues<String>()
    store.observeSequencedFailures { _, error in errors.append(String(describing: error)) }
    var missing = phaseAIssued(store, id).object!
    missing.removeValue(forKey: "navigation")
    var malformed = phaseAIssued(store, id).object!
    malformed["startedEarly"] = "yes"
    store.enqueuePageReport(id: id, report: .object(missing))
    store.enqueuePageReport(id: id, report: .object(malformed))
    store.enqueuePageReport(id: id, report: ["type": "media", "generation": "G", "playing": true])
    store.sequence {}
    #expect(errors.all.count == 2)
    #expect(errors.all.allSatisfy { $0.contains("malformed issued request") })
    #expect(store.state.live[id]?.playingAudio == true)
    #expect(store.memory.pages[id]?.model.issuedSeq == nil)
  }

  @Test func staleIssuedPreviewAlwaysReturnsExplicitRefusal() throws {
    for reason in ["missing", "unloaded", "oldGeneration", "reset"] {
      let (store, id) = try phaseAPageFixture()
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      let request = phaseAIssued(store, id)
      switch reason {
      case "missing": try store.dispatch(Command("closeTab", [.string(id)]))
      case "unloaded": try store.dispatch(Command("updateTab", [.string(id), ["unloaded": true]]))
      case "oldGeneration": try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
      default: try store.transact { $0.memory.pages[id] = nil }
      }
      let revision = store.rev
      let result = try store.dispatch(phaseAReport(id, request))
      #expect(result.result == ["actions": [], "guard": .null])
      #expect(store.rev == revision)
    }
  }

  @Test func issuedPreviewConsumesOnlyAtAcceptedFinalization() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let report = phaseAIssued(store, id, revision: 2, shown: "https://page.example/")
    let serial = store.memory.pages[id]!.modelSerial
    let preview = try store.dispatch(phaseAReport(id, report))
    #expect(preview.result?["guard"]?["modelSerial"] == JSONValue(serial))
    #expect(preview.result?["actions"]?.array?.first == ["type": "clearNewTabShown"])
    #expect(store.memory.pages[id]!.modelSerial == serial)
    let candidate = try #require(try store.preparePooledIssue(id: id, report: report))
    try store.dispatch(phaseAReport(id, ["type": "media", "generation": "G", "playing": true]))
    #expect(store.consumePooledIssue(id: id, prepared: candidate))
    #expect(!store.consumePooledIssue(id: id, prepared: candidate))
    #expect(store.memory.pages[id]?.newTabShownUrl == nil)
    #expect(store.state.live[id]?.playingAudio == true)
  }

  @Test func invalidatedIssueCandidateCannotOverwriteNewerModelFacts() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let candidate = try #require(try store.preparePooledIssue(id: id, report: phaseAIssued(store, id)))
    try store.dispatch(phaseAReport(id, phaseANavigation(url: "https://arrived.example/")))
    let page = store.memory.pages[id]
    #expect(!store.consumePooledIssue(id: id, prepared: candidate))
    #expect(store.memory.pages[id] == page)
    #expect(store.state.tabs[id]?.url == "https://arrived.example/")
  }

  @Test func sameSequenceContextRetryDoesNotRemainConsumed() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let candidate = try #require(try store.preparePooledIssue(id: id, report: phaseAIssued(store, id)))
    var context = phaseAContext(store, id, revision: 2, shown: "https://page.example/")
    context["type"] = "context"
    context["generation"] = "G"
    try store.dispatch(phaseAReport(id, .object(context)))
    #expect(!store.consumePooledIssue(id: id, prepared: candidate))
    let retry = try #require(try store.preparePooledIssue(id: id, report: phaseAIssued(store, id, revision: 2, shown: "https://page.example/")))
    #expect(retry.actions.array?.first == ["type": "clearNewTabShown"])
    #expect(retry.actions.array?.last?["type"] == "load")
    #expect(store.consumePooledIssue(id: id, prepared: retry))
  }

  @Test func effectiveEngineSettingsGovernCreationAndIssueConsumption() throws {
    let (store, id) = try phaseAPageFixture()
    #expect(store.state.tabs[id]?.engine == nil)
    try store.dispatch(settingsCommand(["pageEngine": "webkit"]))
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    #expect(store.pageFacts(id) == nil)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, engine: "webkit")))
    #expect(store.pageFacts(id)?.generation == "G")
    let candidate = try #require(try store.preparePooledIssue(id: id, report: phaseAIssued(store, id)))
    try store.dispatch(settingsCommand(["pageEngine": "chromium"]))
    #expect(!store.consumePooledIssue(id: id, prepared: candidate))
    #expect(store.memory.pages[id]?.model.issuedSeq == nil)
  }

  @Test func sameGenerationResetCannotReusePreparedIssueSerial() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let candidate = try #require(try store.preparePooledIssue(id: id, report: phaseAIssued(store, id)))
    try store.transact { $0.memory.pages[id] = nil }
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, reestablished: true)))
    #expect(!store.consumePooledIssue(id: id, prepared: candidate))
    #expect(store.memory.pages[id]!.modelSerial > candidate.guardValue.modelSerial)
  }
}
