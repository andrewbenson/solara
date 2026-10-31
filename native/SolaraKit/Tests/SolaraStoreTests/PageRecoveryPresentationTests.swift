import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct PageRecoveryPresentationTests {
  @Test func goneResetsTransferredFactsEvenAfterPageMemoryWasCleared() throws {
    let (store, source) = try phaseAPageFixture()
    let window = try #require(store.state.tabs[source]?.windowId)
    let destination = try #require(store.dispatch(Command("newTab", [.string(window), ["url": "https://destination.example/"]])).result?.string)
    try store.dispatch(phaseAReport(source, phaseACreated(store, source)))
    try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "H")))
    let epoch = store.registerKeepAliveRuntime()
    try store.dispatch(phaseAReport(destination, phaseAFeed(generation: "H", epoch: epoch, seq: 8)))
    try store.dispatch(phaseAReport(source, ["type": "media", "generation": "G", "playing": true]))
    try store.transact { $0.emit(.swapTabs(a: source, b: destination)) }
    #expect(store.pageFacts(destination) == nil)
    #expect(store.state.live[destination]?.playingAudio == true)
    try store.dispatch(phaseAReport(destination, ["type": "gone", "generation": "H"]))
    #expect(store.state.live[destination] == PageLiveFacts())
    #expect(store.memory.pageProducerFence[destination]?.retired == true)
    #expect(store.memory.feedWatermark[destination]?.seq == 8)
    try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "H", reestablished: true)))
    #expect(store.pageFacts(destination) == nil)
    try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "J")))
    try store.dispatch(phaseAReport(destination, ["type": "media", "generation": "J", "playing": true]))
    try store.dispatch(phaseAReport(destination, ["type": "gone", "generation": "H"]))
    #expect(store.state.live[destination]?.playingAudio == true)
    #expect(store.memory.pageProducerFence[destination]?.generation == "J")
    #expect(store.memory.pageProducerFence[destination]?.retired == false)
  }

  @Test func sameSessionRecoveryPreservesCurrentTransferredPresentationWithoutReadiness() throws {
    for discarded in [false, true] {
      let (store, source) = try phaseAPageFixture()
      let window = try #require(store.state.tabs[source]?.windowId)
      let destination = try #require(store.dispatch(Command("newTab", [.string(window), ["url": "https://destination.example/"]])).result?.string)
      try store.dispatch(phaseAReport(source, phaseACreated(store, source)))
      try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "H")))
      try store.dispatch(phaseAReport(destination, ["type": "ready", "generation": "H", "browserId": 7]))
      try store.dispatch(phaseAReport(source, ["type": "navigation", "generation": "G", "url": "https://page.example/",
        "title": "Transferred", "isLoading": true, "canGoBack": true, "canGoForward": true, "themeColor": "blue"]))
      try store.dispatch(phaseAReport(source, ["type": "media", "generation": "G", "playing": true]))
      if discarded { try store.dispatch(phaseAReport(source, ["type": "discarded", "generation": "G", "url": "https://page.example/"])) }
      let presentation = try #require(store.state.live[source])
      try store.transact { $0.emit(.swapTabs(a: source, b: destination)) }
      #expect(store.state.live[destination] == presentation)
      #expect(store.pageFacts(destination) == nil)
      let revision = store.rev
      try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "H", reestablished: true)))
      #expect(store.rev == revision)
      #expect(store.state.live[destination] == presentation)
      #expect(store.memory.pages[destination]?.live.facts == presentation)
      #expect(store.pageFacts(destination)?.generation == "H")
      #expect(store.pageFacts(destination)?.ready == nil)
      #expect(store.pageFacts(destination)?.keepAlive == nil)
      #expect(store.pageFacts(destination)?.latchedThrough == 0)
      #expect(store.pageFacts(destination)?.newestEventSeq == 0)
      try store.dispatch(phaseAReport(destination, phaseACreated(store, destination, generation: "J")))
      #expect(store.state.live[destination] == PageLiveFacts(themeColor: "blue"))
    }
  }
}
