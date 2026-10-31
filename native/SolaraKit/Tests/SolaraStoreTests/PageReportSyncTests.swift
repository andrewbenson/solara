import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct PageReportSyncTests {
  func fixture(tags: Bool = true, clock: @escaping @Sendable () -> Double = { 1_000 }) throws -> (Store, String) {
    var config = StoreConfig()
    config.syncOrigins = tags
    let store = Store(config: config, clock: clock)
    let window = try #require(store.dispatch(Command("createWindow", [["url": "https://before.example/"]])).result?.string)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    let seq = try #require(store.state.tabs[tab]?.navigation?.seq)
    try store.dispatch(Command("pageReport", [.string(tab), ["type": "created", "generation": "G", "engine": "chromium", "navigationSeq": .number(seq), "contextRevision": 0, "wasNewTab": false, "newTabShownUrl": .null]]))
    return (store, tab)
  }

  func navigation(_ tab: String, title: String = "After") -> Command {
    Command("pageReport", [.string(tab), ["type": "navigation", "generation": "G", "url": "https://after.example/", "title": .string(title), "isLoading": false, "canGoBack": false, "canGoForward": false]])
  }

  var pins: Command {
    Command("syncPinsApply", ["default", ["kind": "pins", "visible": [], "changed": [], "base": [:], "known": [], "now": 1_000, "horizon": 0]])
  }

  @Test func pageReportBatchCannotBypassPinnedIsolation() throws {
    for pinned in [pins, Command("settlePinChoices", ["default", [:]])] {
      for reportFirst in [true, false] {
        let (store, tab) = try fixture()
        let before = store.snapshot
        let commands = reportFirst ? [navigation(tab), pinned] : [pinned, navigation(tab)]
        #expect(throws: CommandError.self) { try store.dispatch(commands) }
        #expect(store.rev == before.rev)
        #expect(store.state == before.state)
        #expect(store.queuedFromSyncCount == 0)
      }
    }
  }

  @Test func queuedPinSettlementKeepsBooleanAndOrder() throws {
    let (store, tab) = try fixture()
    let events = SequencerValues<Commit>()
    let queued = SequencerValues<JSONValue?>()
    store.subscribe { events.append($0) }
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { session in
      session.updateSettings(["appearance": "dark"], fromSync: true)
    }
    let settlement = try store.dispatch(Command("settlePinChoices", ["default", [:]]))
    queued.append(settlement.result)
    #expect(queued.all == [.bool(true)])
    #expect(store.queuedFromSyncCount == 2)
    store.enqueueSequenced(navigation(tab))
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.tabs[tab]?.title == "After")
    #expect(store.state.settings.values["appearance"] == "dark")
    let fact = try #require(events.all.first { $0.commands.first?.name == "pageReport" })
    let sync = try #require(events.all.first { $0.patch.json["settings"] != nil })
    #expect(fact.origin == .engine)
    #expect(!fact.fromSync)
    #expect(fact.rev < sync.rev)
    #expect(sync.fromSync)
  }

  @Test func throwingTransactionReplaysReadySyncWithoutExitDrain() throws {
    let (store, tab) = try fixture()
    let events = SequencerValues<Commit>()
    store.subscribe { events.append($0) }
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    #expect(throws: CommandError.self) {
      try store.sequence {
        try store.dispatch(Command("endTransaction"))
        store.enqueueSequenced(navigation(tab))
        throw CommandError("after transaction")
      }
    }
    #expect(events.all.contains { $0.state.settings.values["appearance"] == "dark" && $0.fromSync })
    #expect(events.all.allSatisfy { !$0.commands.contains(where: { $0.name == "pageReport" }) })
    store.sequence {}
    #expect(store.state.tabs[tab]?.title == "After")
    #expect(events.all.last?.origin == .engine)
    #expect(events.all.last?.fromSync == false)
  }

  @Test func pinnedIsolationSurvivesTagsOff() throws {
    let now = Mutex<Double>(1_000)
    let (store, tab) = try fixture(tags: false, clock: { now.withLock { $0 } })
    let events = SequencerValues<Commit>()
    store.subscribe { events.append($0) }
    try store.dispatch(Command("beginTransaction"))
    store.enqueueSequenced(navigation(tab))
    #expect(throws: StoreBusy.self) { try store.dispatch(pins) }
    #expect(store.state.tabs[tab]?.title == "After")
    #expect(events.all.last?.origin == .engine)
    #expect(events.all.last?.fromSync == false)
    #expect(store.queuedFromSyncCount == 0)
    now.withLock { $0 += Store.heldTransactionLimit + 1 }
    _ = try store.dispatch(pins)
    try store.dispatch(Command("beginTransaction"))
    let settled = try store.dispatch(Command("settlePinChoices", ["default", [:]]))
    #expect(settled.result == .bool(true))
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(events.all.allSatisfy { !$0.fromSync && $0.patch.json["sync"] == nil })
  }
}
