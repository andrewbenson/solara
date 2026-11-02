import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct PrivateSessionRetentionTests {
  private func window(_ store: Store, privateMode: Bool, url: String) throws -> String {
    try #require(try store.dispatch(Command("createWindow", [["url": .string(url), "incognito": .bool(privateMode)]])).result?.string)
  }

  private func restore(_ store: Store, snapshot: BrowserState, id: String) throws -> String? {
    let window = try #require(snapshot.windows[id])
    return try store.transact { session in
      session.result = JSONValue(session.restoreClosingWindow(window, window.tabIds.compactMap { snapshot.tabs[$0] },
        snapshot.groups.values.filter { $0.windowId == id }, snapshot.splits.values.filter { $0.windowId == id },
        chromeWindow: "native-confirmation", liveTabIds: window.tabIds))
    }.result?.string
  }

  @Test func confirmedEndExpiresPrivateUndoAndMakesLaggingReplicaTakeASnapshot() throws {
    let store = makeStore()
    let id = try window(store, privateMode: true, url: "https://secret.example/private")
    let before = store.state
    let profile = try #require(before.windows[id]?.profileId)
    let lagging = store.rev - 1
    try store.dispatch(Command("closeWindow", [.string(id)]))
    #expect(store.memory.closingWindowUndos[id] != nil)
    #expect(store.patches(since: lagging) != nil)
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [profile]))
    #expect(store.memory.closingWindowUndos[id] == nil)
    #expect(try restore(store, snapshot: before, id: id) == nil)
    if case .snapshot(let rev, let state) = store.catchUp(sinceRev: lagging) {
      #expect(rev == store.rev)
      #expect(state == store.state)
      #expect(!state.tabs.values.contains { $0.url == "https://secret.example/private" })
    } else { Issue.record("a lagging replica received retained private patches") }
  }

  @Test func unconfirmedPrivateCloseCanStillBeCanceled() throws {
    let store = makeStore()
    let id = try window(store, privateMode: true, url: "https://secret.example/canceled")
    let before = store.state
    try store.dispatch(Command("closeWindow", [.string(id)]))
    let restored = try #require(try restore(store, snapshot: before, id: id))
    #expect(store.state.windows[restored]?.incognito == true)
    #expect(store.state.windows[restored]?.profileId == before.windows[id]?.profileId)
    #expect(store.state.tabs.values.contains { $0.url == "https://secret.example/canceled" })
  }

  @Test func otherUndoSnapshotsLosePrivatePayloadWhileOrdinaryCancellationStillRestores() throws {
    let store = makeStore()
    let privateId = try window(store, privateMode: true, url: "https://secret.example/nested")
    let profile = try #require(store.state.windows[privateId]?.profileId)
    let privateTab = try #require(store.state.windows[privateId]?.tabIds.first)
    try store.dispatch(Command("setFind", [.string(privateTab), ["query": "secret snapshot find"]]))
    try store.dispatch(Command("openPanel", [.string(privateId), "secret snapshot panel"]))
    let ordinary = try window(store, privateMode: false, url: "https://ordinary.example/")
    let beforeOrdinary = store.state
    try store.dispatch(Command("closeWindow", [.string(ordinary)]))
    #expect(store.memory.closingWindowUndos[ordinary]?.before.tabs.values.contains { $0.profileId == profile } == true)
    try store.dispatch(Command("closeWindow", [.string(privateId)]))
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [profile]))
    let undo = try #require(store.memory.closingWindowUndos[ordinary])
    for snapshot in [undo.before, undo.after] {
      #expect(!snapshot.tabs.values.contains { $0.profileId == profile })
      #expect(!snapshot.windows.values.contains { $0.profileId == profile })
      let encoded = JSONValue.object(snapshot.stateJSON).text()
      #expect(!encoded.contains("https://secret.example/nested"))
      #expect(!encoded.contains("secret snapshot find"))
      #expect(!encoded.contains("secret snapshot panel"))
    }
    let restored = try #require(try restore(store, snapshot: beforeOrdinary, id: ordinary))
    #expect(store.state.windows[restored]?.incognito == false)
    #expect(store.state.tabs.values.contains { $0.url == "https://ordinary.example/" })
    #expect(!store.state.tabs.values.contains { $0.profileId == profile })
  }

  @Test func survivingSharedDataOwnerRefusesEndWithoutExpiringItsUndo() throws {
    let store = makeStore()
    let alias = try #require(try store.dispatch(Command("createProfile", [["name": "Alias", "shareWith": "default"]])).result?.string)
    let first = try window(store, privateMode: true, url: "https://secret.example/first")
    let second = try #require(try store.dispatch(Command("createWindow", [["incognito": true, "profileId": .string(alias)]])).result?.string)
    let profile = try #require(store.state.windows[first]?.profileId)
    try store.dispatch(Command("closeWindow", [.string(first)]))
    let rev = store.rev
    #expect(!store.confirmPrivateSessionEnded(session: "", profiles: [profile]))
    #expect(store.memory.closingWindowUndos[first] != nil)
    #expect(store.state.windows[second] != nil)
    #expect(store.patches(since: rev - 1) != nil)
  }

  @Test func heldTransactionCannotRetainOrRestorePrivateUndoAfterConfirmation() throws {
    let store = makeStore()
    let id = try window(store, privateMode: true, url: "https://secret.example/held")
    let before = store.state
    let profile = try #require(before.windows[id]?.profileId)
    try store.dispatch(Command("closeWindow", [.string(id)]))
    try store.dispatch(Command("beginTransaction"))
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [profile]))
    try store.dispatch(Command("endTransaction"))
    #expect(store.memory.closingWindowUndos[id] == nil)
    #expect(try restore(store, snapshot: before, id: id) == nil)
  }

  @Test func anUnrelatedSessionKeepsItsUndoAndPrivatePayload() throws {
    let store = makeStore()
    let profile = try #require(try store.dispatch(Command("createProfile", [["name": "Other"]])).result?.string)
    let other = try #require(try store.dispatch(Command("createWindow", [["incognito": true, "profileId": .string(profile), "url": "https://other.example/private"]])).result?.string)
    let otherBefore = store.state
    try store.dispatch(Command("closeWindow", [.string(other)]))
    let id = try window(store, privateMode: true, url: "https://secret.example/ended")
    let alias = try #require(store.state.windows[id]?.profileId)
    try store.dispatch(Command("closeWindow", [.string(id)]))
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [alias]))
    let restored = try #require(try restore(store, snapshot: otherBefore, id: other))
    #expect(store.state.windows[restored]?.incognito == true)
    #expect(store.state.tabs.values.contains { $0.url == "https://other.example/private" })
  }

  @Test func confirmedEndRemovesSessionDownloadRecordsAndRejectsTheirLateReturn() throws {
    var config = StoreConfig()
    config.nativePrivateSessionEffects = true
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "private-downloads")), config: config, clock: { 1_000 })
    let id = try window(store, privateMode: true, url: "https://secret.example/downloads")
    store.setPrivateSessionGeneration(session: "", generation: "download-generation")
    let profile = try #require(store.state.windows[id]?.profileId)
    let privateRecord = Download(json: ["id": "private-complete", "state": "complete", "offTheRecord": true, "profile": "", "path": "/saved/private.pdf"])
    let ordinaryRecord = Download(json: ["id": "ordinary-complete", "state": "complete", "profile": "", "path": "/saved/ordinary.pdf"])
    try store.dispatch(upsert(privateRecord))
    try store.dispatch(upsert(ordinaryRecord))
    try store.dispatch(Command("closeWindow", [.string(id)]))
    #expect(store.state.downloads.contains { $0.id == privateRecord.id })
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [profile]))
    #expect(store.state.downloads == [ordinaryRecord])
    #expect(store.memory.endedPrivateDownloads.contains(privateRecord.id))
    try store.dispatch(upsert(privateRecord))
    #expect(store.state.downloads == [ordinaryRecord])
  }


  @Test func anOldConfirmationCannotRetireAReplacementGenerationWithoutWindows() throws {
    let store = makeStore()
    let id = try window(store, privateMode: true, url: "https://secret.example/replacement")
    let profile = try #require(store.state.windows[id]?.profileId)
    store.setPrivateSessionGeneration(session: "", generation: "old")
    try store.dispatch(Command("closeWindow", [.string(id)]))
    store.setPrivateSessionGeneration(session: "", generation: "replacement")
    #expect(!store.confirmPrivateSessionEnded(session: "", profiles: [profile], generation: "old"))
    #expect(store.memory.privateSessionGenerations[JSKey("")] == "replacement")
    #expect(store.memory.closingWindowUndos[id] != nil)
    #expect(store.confirmPrivateSessionEnded(session: "", profiles: [profile], generation: "replacement"))
    #expect(store.memory.privateSessionGenerations[JSKey("")] == nil)
  }


  @Test func nativeLaneAcceptsUnmodifiedAPI34DownloadPayloads() throws {
    var config = StoreConfig()
    config.nativePrivateSessionEffects = true
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "api34-downloads")), config: config, clock: { 1_000 })
    let id = try window(store, privateMode: true, url: "https://secret.example/current-download")
    store.setPrivateSessionGeneration(session: "", generation: "native-only-generation")
    let privateRecord = Download(json: ["id": "api34-private", "state": "complete", "offTheRecord": true, "profile": ""])
    let ordinaryRecord = Download(json: ["id": "api34-ordinary", "state": "complete", "profile": ""])
    try store.dispatch(upsert(privateRecord))
    try store.dispatch(upsert(ordinaryRecord))
    #expect(store.state.windows[id]?.incognito == true)
    #expect(store.state.downloads == [ordinaryRecord, privateRecord])
    #expect(store.state.downloads.last?.json == privateRecord.json)
  }

}
