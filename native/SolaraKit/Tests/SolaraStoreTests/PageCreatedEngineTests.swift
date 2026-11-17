import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct PageCreatedEngineTests {
  private func fixture(engine: String = "chromium", empty: Bool = false, url: String = "https://page.example/") throws -> (Store, String) {
    let store = makeStore()
    try store.dispatch(Command("updateSettings", [["pageEngine": .string(engine)]]))
    let window = try #require(try store.dispatch(Command("createWindow", [["url": .string(url)]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    try store.transact { session in session.updateTab(id, empty ? TabUpdate(set: ["engine": ""]) : TabUpdate(unset: ["engine"])) }
    return (store, id)
  }

  @Test(arguments: ["chromium", "webkit"])
  func acceptedCreationPersistsAnAbsentOrEmptyEngineInTheSameCommit(engine: String) throws {
    for empty in [false, true] {
      let (store, id) = try fixture(engine: engine, empty: empty)
      try store.transact { session in session.update { $0.live[id] = PageLiveFacts(discarded: true) } }
      let before = store.rev
      let commit = try store.dispatch(phaseAReport(id, phaseACreated(store, id, engine: engine)))
      #expect(store.state.tabs[id]?.engine == engine)
      #expect(commit.rev == before + 1)
      #expect(commit.changes.tabs.upserted.contains(id))
      #expect(commit.changes.live.upserted.contains(id))
      #expect(commit.patch.json["tabs"]?["upsert"]?.array?.first?["engine"]?.string == engine)
      #expect(commit.patch.json["live"]?["upsert"]?.array?.first?["discarded"] == false)
      #expect(store.pageFacts(id)?.generation == "G")
      let revision = store.rev
      try store.dispatch(Command("updateTab", [.string(id), ["engine": .string(engine)]]))
      #expect(store.rev == revision)
    }
  }

  @Test func anExplicitPreferenceSurvivesForcedChromiumCreation() throws {
    let (store, id) = try fixture(engine: "webkit", url: "chrome://settings/")
    try store.dispatch(Command("updateTab", [.string(id), ["engine": "webkit"]]))
    let commit = try store.dispatch(phaseAReport(id, phaseACreated(store, id, engine: "chromium")))
    #expect(store.pageFacts(id)?.generation == "G")
    #expect(store.state.tabs[id]?.engine == "webkit")
    #expect(!commit.changes.tabs.upserted.contains(id))
  }

  @Test(arguments: ["chromium", "webkit"])
  func anExplicitPreferenceIsNeverRewritten(engine: String) throws {
    let (store, id) = try fixture(engine: engine)
    try store.dispatch(Command("updateTab", [.string(id), ["engine": .string(engine)]]))
    let commit = try store.dispatch(phaseAReport(id, phaseACreated(store, id, engine: engine)))
    #expect(store.state.tabs[id]?.engine == engine)
    #expect(!commit.changes.tabs.upserted.contains(id))
  }

  @Test(arguments: ["wrongEngine", "navigationMismatch", "retiredGeneration", "invalidRecovery"])
  func rejectedCreationCannotPersistAnEngine(reason: String) throws {
    let (store, id) = try fixture()
    var report = try #require(phaseACreated(store, id).object)
    switch reason {
    case "wrongEngine": report["engine"] = "webkit"
    case "navigationMismatch": report["navigationSeq"] = JSONValue((store.state.tabs[id]?.navigation?.seq ?? 0) + 1)
    case "retiredGeneration":
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      try store.dispatch(phaseAReport(id, ["type": "gone", "generation": "G"]))
      try store.transact { session in session.updateTab(id, TabUpdate(unset: ["engine"])) }
    case "invalidRecovery": report["reestablished"] = true
    default: break
    }
    let revision = store.rev
    let commit = try store.dispatch(phaseAReport(id, .object(report)))
    #expect(store.state.tabs[id]?.engine == nil)
    #expect(store.pageFacts(id) == nil)
    #expect(store.rev == revision)
    #expect(!commit.changes.tabs.upserted.contains(id))
  }
}
