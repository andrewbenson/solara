import SolaraModel
import SolaraStore
import Testing

@Suite struct PagePatchRingTests {
  @Test func exactCapacityAndWrapRetainMixedLiveAndWorkspaceRevisions() throws {
    let (store, id) = try phaseAPageFixture()
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let baseline = store.rev
    for index in 1...Store.ringSize {
      try store.dispatch(phaseAReport(id, ["type": "navigation", "generation": "G", "url": .string("https://page.example/\(index)"),
        "title": .string("Page \(index)"), "isLoading": .bool(index.isMultiple(of: 2)), "canGoBack": true, "canGoForward": false]))
    }
    #expect(Store.ringSize == 65_536)
    let full = try #require(store.patches(since: baseline))
    #expect(full.count == Store.ringSize)
    #expect(full.map(\.rev) == Array((baseline + 1)...(baseline + Store.ringSize)))
    #expect(full.allSatisfy { $0.json["tabs"] != nil && $0.json["live"] != nil })
    #expect(full.first?.json["tabs"]?["upsert"]?.array?.first?["url"] == "https://page.example/1")
    try store.dispatch(phaseAReport(id, ["type": "navigation", "generation": "G", "url": "https://page.example/wrapped",
      "title": "Wrapped", "isLoading": true, "canGoBack": false, "canGoForward": true]))
    #expect(store.patches(since: baseline) == nil)
    let wrapped = try #require(store.patches(since: baseline + 1))
    #expect(wrapped.count == Store.ringSize)
    #expect(wrapped.first?.rev == baseline + 2)
    #expect(wrapped.last?.rev == baseline + Store.ringSize + 1)
    #expect(store.patches(since: store.rev - 2)?.map(\.rev) == [store.rev - 1, store.rev])
    #expect(store.patches(since: Int.max)?.isEmpty == true)
    #expect(store.patches(since: Int.min) == nil)
  }
}
