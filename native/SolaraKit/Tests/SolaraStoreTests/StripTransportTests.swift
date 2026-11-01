import Foundation
import SolaraModel
import SolaraStore
import Testing

final class FakeStripEngine: StripEngine {
  var observers: [Int: (JSONValue) -> Void] = [:]
  var last = 0
  var rev = 1
  var strips: [JSONValue] = []
  var sent: [(id: Int, command: JSONValue)] = []
  var duringSnapshot: (() -> Void)?
  var duringObserve: ((@escaping (JSONValue) -> Void) -> Void)?
  var reply: ((Int, JSONValue) -> Void)?

  func observe(_ receive: @escaping (JSONValue) -> Void) -> Int {
    last += 1
    observers[last] = receive
    duringObserve?(receive)
    return last
  }

  func stopObserving(_ token: Int) { observers[token] = nil }

  func snapshot() -> JSONValue {
    let snapshot: JSONValue = ["rev": JSONValue(rev), "cmd": .null, "strips": .array(strips)]
    duringSnapshot?()
    return snapshot
  }

  func send(id: Int, command: JSONValue) {
    sent.append((id, command))
    reply?(id, command)
  }

  func emit(cmd: Int?, strips: [JSONValue], rejected: Bool = false) {
    rev += 1
    var tx: JSONObject = ["rev": JSONValue(rev), "cmd": cmd.map { JSONValue($0) } ?? .null, "strips": .array(strips)]
    if rejected { tx["rejected"] = true }
    for token in observers.keys.sorted() { observers[token]?(.object(tx)) }
  }
}

final class Troubles: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ line: String) { lock.withLock { lines.append(line) } }
  var all: [String] { lock.withLock { lines } }
}

final class BackgroundStripReceipt: @unchecked Sendable {
  let receive: (JSONValue) -> Void

  init(_ receive: @escaping (JSONValue) -> Void) { self.receive = receive }

  func deliver(_ transactions: [JSONValue]) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      for transaction in transactions { self.receive(transaction) }
      done.signal()
    }
    return done.wait(timeout: .now() + 5) == .success
  }
}

@MainActor
final class HeldSequence {
  var holding = false
  var work: [() -> Void] = []
}

@MainActor
final class LaterQueue {
  var work: [@MainActor () -> Void] = []
  func flush() {
    while !work.isEmpty { work.removeFirst()() }
  }
}

@MainActor
@Suite struct StripTransportTests {
  struct Fixture {
    let store: Store
    let engine: FakeStripEngine
    let later: LaterQueue
    let transport: StripTransport
    let keys: [String]
    let trouble: Troubles
  }

  func fixture(actual order: [Int] = [2, 0, 1]) throws -> Fixture {
    let store = makeStore()
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    let w = store.state.windowOrder[0]
    for u in ["b", "c"] { try store.dispatch(Command("newTab", [.string(w), ["url": .string("https://\(u).example/"), "background": true]])) }
    let keys = store.state.windows[w]!.tabIds
    let window = store.state.windows[w]!
    let active = window.activeTabIds[window.profileId]
    let engine = FakeStripEngine()
    engine.strips = [strip(order.map { keys[$0] }, active: active)]
    let later = LaterQueue()
    let trouble = Troubles()
    let transport = StripTransport(store: store, engine: engine, later: { later.work.append($0) }, trouble: { trouble.add($0) })
    return Fixture(store: store, engine: engine, later: later, transport: transport, keys: keys, trouble: trouble)
  }

  func strip(_ keys: [String], active: String?, number: Int = 7) -> JSONValue {
    let tabs: [JSONValue] = keys.enumerated().map { i, key in
      ["key": .string(key), "browser": JSONValue(100 * number + i), "index": JSONValue(i), "active": .bool(key == active), "pinned": false]
    }
    return ["strip": JSONValue(number), "window": JSONValue(10 * number), "profile": "", "tabs": .array(tabs)]
  }

  func arranges(_ engine: FakeStripEngine) -> [JSONValue] { engine.sent.map(\.command).filter { $0["op"] == "arrange" } }

  @Test func startTakesTheSnapshotAndProjectsOnce() throws {
    let f = try fixture()
    f.transport.start()
    #expect(f.later.work.count == 1, "one projection is scheduled for the snapshot")
    f.later.flush()
    #expect(arranges(f.engine).count == 1)
    #expect(f.engine.sent.first?.id == 1)
    #expect(f.engine.sent.first?.command["keys"] == JSONValue(f.keys))
    #expect(f.store.memory.chromeTabs.inflight[7]?.cmd == 1, "the id is in the inflight record before the engine answers")
  }

  @Test func aCompletionInsideTheSendClearsTheInflightRecord() throws {
    let f = try fixture()
    f.engine.reply = { [engine = f.engine, keys = f.keys] id, _ in
      engine.emit(cmd: id, strips: [self.strip(keys, active: keys[0])])
    }
    f.transport.start()
    f.later.flush()
    #expect(f.engine.sent.count == 1)
    #expect(f.store.memory.chromeTabs.inflight[7] == nil, "the synchronous answer matched the reserved id")
    #expect(f.store.memory.chromeTabs.mirror[7]?.tabs.map(\.key) == f.keys.map(Optional.some))
    f.later.flush()
    #expect(f.engine.sent.count == 1, "nothing left to send once Chrome matches the plan")
  }

  @Test func anUnrelatedChangeDoesNotMatchAnInflightCommand() throws {
    let f = try fixture()
    f.transport.start()
    f.later.flush()
    f.engine.emit(cmd: nil, strips: [strip([f.keys[2], f.keys[0], f.keys[1]], active: f.keys[0])])
    #expect(f.store.memory.chromeTabs.inflight[7]?.cmd == 1, "a change Chrome made itself leaves the command in flight")
  }

  @Test func aTransactionDuringStartUpLandsAfterTheSnapshot() throws {
    let f = try fixture()
    f.engine.duringSnapshot = { [engine = f.engine, keys = f.keys] in
      engine.emit(cmd: nil, strips: [self.strip(keys, active: keys[0])])
    }
    f.transport.start()
    #expect(f.store.memory.chromeTabs.lastRev == 2, "the transaction sent while the snapshot was taken follows it")
    f.later.flush()
    #expect(f.engine.sent.isEmpty, "Chrome already shows the plan")
  }

  @Test func aRejectedCommandIsNotRetriedUntilTheStripChanges() throws {
    let f = try fixture()
    f.engine.reply = { [engine = f.engine, keys = f.keys] id, _ in
      engine.emit(cmd: id, strips: [self.strip([keys[2], keys[0], keys[1]], active: keys[0])], rejected: true)
    }
    f.transport.start()
    f.later.flush()
    #expect(f.store.memory.chromeTabs.inflight[7] == nil)
    try f.store.dispatch(Command("projectStrips"))
    f.later.flush()
    #expect(f.engine.sent.count == 1, "the same order isn't asked for again")
  }

  @Test func aStripThatAlreadyMatchesSendsNothing() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    #expect(f.engine.sent.isEmpty)
  }

  @Test func transactionsAndMovesCoalesceIntoOneProjection() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    for _ in 0..<3 { f.engine.emit(cmd: nil, strips: [strip(f.keys, active: f.keys[0])]) }
    try f.store.dispatch(Command("moveTab", [.string(f.keys[2]), 0]))
    #expect(f.later.work.count == 1)
    f.later.flush()
    #expect(arranges(f.engine).count == 1)
  }

  @Test func stopLeavesTheEngineAndStore() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    f.transport.stop()
    #expect(f.engine.observers.isEmpty)
    f.engine.emit(cmd: nil, strips: [strip(f.keys.reversed(), active: f.keys[0])])
    #expect(f.later.work.isEmpty)
  }

  @Test func aChromeChangeDuringAUserTransactionIsAppliedOnceInOrder() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    try f.store.dispatch(Command("beginTransaction"), origin: .native)
    f.engine.emit(cmd: nil, strips: [strip([f.keys[1], f.keys[0], f.keys[2]], active: f.keys[0])])
    f.engine.emit(cmd: nil, strips: [strip([f.keys[2], f.keys[1], f.keys[0]], active: f.keys[0])])
    try f.store.dispatch(Command("endTransaction"), origin: .native)
    #expect(f.trouble.all.isEmpty, "an engine transaction is never refused as busy")
    #expect(f.store.memory.chromeTabs.lastRev == 3)
    #expect(f.store.memory.chromeTabs.mirror[7]?.tabs.map(\.key) == [f.keys[2], f.keys[1], f.keys[0]].map(Optional.some), "the later transaction wins")
  }

  @Test func aRefusedStripTransactionIsReportedUntilStop() {
    let store = makeStore(BrowserState(settings: Settings.hydrated(from: nil), downloads: [download("d"), download("d")]))
    let engine = FakeStripEngine()
    let trouble = Troubles()
    let transport = StripTransport(store: store, engine: engine, later: { _ in }, trouble: { trouble.add($0) })
    transport.start()
    engine.emit(cmd: nil, strips: [])
    let refused = trouble.all.filter { $0.hasPrefix("the store refused stripTransaction") }
    #expect(refused.count == 1)
    transport.stop()
    store.enqueueSequenced(Command("stripTransaction", [["rev": 99, "cmd": .null, "strips": []]]), origin: .engine)
    store.sequence {}
    #expect(trouble.all.filter { $0.hasPrefix("the store refused stripTransaction") }.count == 1)
  }

  @Test func aRefusalDeliveredAfterAnOuterSequenceEndsIsDroppedOnceStopped() {
    let store = makeStore(BrowserState(settings: Settings.hydrated(from: nil), downloads: [download("d"), download("d")]))
    let engine = FakeStripEngine()
    let trouble = Troubles()
    let transport = StripTransport(store: store, engine: engine, later: { _ in }, trouble: { trouble.add($0) })
    transport.start()
    store.sequence {
      engine.emit(cmd: nil, strips: [])
      transport.stop()
    }
    #expect(trouble.all.allSatisfy { !$0.hasPrefix("the store refused stripTransaction") })
    transport.start()
    #expect(trouble.all.allSatisfy { !$0.hasPrefix("the store refused stripTransaction") }, "a restart does not hear the old subscription's refusal")
    transport.stop()
  }

  @Test func aRefusalHeardOffMainIsDroppedOnceStopped() throws {
    let store = makeStore(BrowserState(settings: Settings.hydrated(from: nil), downloads: [download("d"), download("d")]))
    let engine = FakeStripEngine()
    let trouble = Troubles()
    let transport = StripTransport(store: store, engine: engine, later: { _ in }, trouble: { trouble.add($0) })
    transport.start()
    let receive = try #require(engine.observers.values.first)
    let first: JSONValue = ["rev": 2, "cmd": .null, "strips": []]
    let second: JSONValue = ["rev": 3, "cmd": .null, "strips": []]
    let refused = { trouble.all.filter { $0.hasPrefix("the store refused stripTransaction") }.count }
    #expect(BackgroundStripReceipt(receive).deliver([first, second]))
    #expect(refused() == 0, "the refusal heard on another thread waits for main")
    transport.stop()
    #expect(refused() == 1, "stop drains the second transaction and reports it while the transport still runs")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    #expect(refused() == 1, "the first refusal, queued for main, is dropped after stop")
  }

  @Test func aRefusalHeardOffMainIsDroppedAfterARestart() throws {
    let store = makeStore(BrowserState(settings: Settings.hydrated(from: nil), downloads: [download("d"), download("d")]))
    let engine = FakeStripEngine()
    let trouble = Troubles()
    let transport = StripTransport(store: store, engine: engine, later: { _ in }, trouble: { trouble.add($0) })
    transport.start()
    let receive = try #require(engine.observers.values.first)
    let refused = { trouble.all.filter { $0.hasPrefix("the store refused stripTransaction") }.count }
    #expect(BackgroundStripReceipt(receive).deliver([["rev": 2, "cmd": .null, "strips": []], ["rev": 3, "cmd": .null, "strips": []]]))
    transport.stop()
    transport.start()
    let afterRestart = refused()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    #expect(refused() == afterRestart, "a refusal from the earlier start is not reported by the new one")
    transport.stop()
  }

  @Test func aHeldSequencerCannotDelayTheStartupSnapshot() throws {
    let f0 = try fixture(actual: [0, 1, 2])
    let held = HeldSequence()
    held.holding = true
    let transport = StripTransport(
      store: f0.store, engine: f0.engine, sequence: { work in held.holding ? held.work.append(work) : work() },
      later: { f0.later.work.append($0) })
    transport.start()
    #expect(held.work.isEmpty, "the snapshot is taken and applied inside start")
    f0.engine.emit(cmd: nil, strips: [strip([f0.keys[1], f0.keys[0], f0.keys[2]], active: f0.keys[0])])
    held.holding = false
    for work in held.work { work() }
    #expect(f0.store.memory.chromeTabs.lastRev == 2)
    #expect(f0.store.memory.chromeTabs.mirror[7]?.tabs.map(\.key) == [f0.keys[1], f0.keys[0], f0.keys[2]].map(Optional.some))
    transport.stop()
  }

  @Test func aProjectionBodyHeldPastARestartReservesNothing() throws {
    let f0 = try fixture()
    let held = HeldSequence()
    let transport = StripTransport(
      store: f0.store, engine: f0.engine, sequence: { work in held.holding ? held.work.append(work) : work() },
      later: { f0.later.work.append($0) })
    transport.start()
    held.holding = true
    f0.later.flush()
    held.holding = false
    #expect(held.work.count == 1)
    transport.stop()
    transport.start()
    for work in held.work { work() }
    held.work = []
    #expect(f0.store.memory.chromeTabs.inflight[7] == nil, "the old body dispatched nothing")
    f0.later.flush()
    #expect(f0.engine.sent.count == 1, "the restarted transport arranges the strip")
    #expect(f0.store.memory.chromeTabs.inflight[7]?.cmd == f0.engine.sent.last?.id)
    transport.stop()
  }

  @Test func aCommandPlannedWhileTheStoreIsBusySendsOnceWhenItFrees() throws {
    let f0 = try fixture()
    let held = HeldSequence()
    let transport = StripTransport(
      store: f0.store, engine: f0.engine, sequence: { work in held.holding ? held.work.append(work) : work() },
      later: { f0.later.work.append($0) })
    transport.start()
    held.holding = true
    f0.later.flush()
    #expect(f0.engine.sent.isEmpty, "nothing reaches the engine while the store is busy")
    #expect(held.work.count == 1, "the projection waits its turn instead of being dropped")
    held.holding = false
    for work in held.work { work() }
    held.work = []
    #expect(arranges(f0.engine).count == 1, "the command goes out once the store is free")
    #expect(f0.store.memory.chromeTabs.inflight[7]?.cmd == f0.engine.sent.last?.id)
    f0.later.flush()
    for work in held.work { work() }
    #expect(arranges(f0.engine).count == 1, "the command in flight isn't sent again")
    transport.stop()
  }

  @Test func aStripClosedWhileStoppedIsForgottenOnRestart() throws {
    let f = try fixture()
    f.transport.start()
    f.later.flush()
    #expect(f.engine.sent.count == 1)
    f.transport.stop()
    f.engine.strips = []
    f.transport.start()
    #expect(f.store.memory.chromeTabs.mirror[7] == nil)
    #expect(f.store.memory.chromeTabs.changedAt[7] == nil)
    f.later.flush()
    #expect(f.engine.sent.count == 1, "nothing is sent to a strip that no longer exists")
    f.transport.stop()
  }

  @Test func aRestartReleasesACommandWhoseAnswerCameWhileStopped() throws {
    let f = try fixture()
    f.transport.start()
    f.later.flush()
    #expect(f.store.memory.chromeTabs.inflight[7]?.cmd == 1)
    f.transport.stop()
    f.engine.emit(cmd: 1, strips: [strip([f.keys[1], f.keys[0], f.keys[2]], active: f.keys[0])])
    f.engine.strips = [strip([f.keys[1], f.keys[0], f.keys[2]], active: f.keys[0])]
    f.transport.start()
    #expect(f.store.memory.chromeTabs.inflight[7] == nil)
    f.later.flush()
    #expect(arranges(f.engine).count == 2, "the strip is arranged again from the new snapshot")
    #expect(f.engine.sent.last?.id == 2, "command ids keep counting up")
    f.transport.stop()
  }

  @Test func aStopInsideASendCancelsTheRestOfTheProjection() throws {
    let store = makeStore()
    var strips: [JSONValue] = []
    for number in [7, 8] {
      try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
      let w = store.state.windowOrder.last!
      for u in ["b", "c"] { try store.dispatch(Command("newTab", [.string(w), ["url": .string("https://\(u).example/"), "background": true]])) }
      let window = store.state.windows[w]!
      let keys = window.tabIds
      strips.append(strip([keys[2], keys[0], keys[1]], active: window.activeTabIds[window.profileId], number: number))
    }
    let engine = FakeStripEngine()
    engine.strips = strips
    let later = LaterQueue()
    let transport = StripTransport(store: store, engine: engine, later: { later.work.append($0) })
    engine.reply = { _, _ in MainActor.assumeIsolated { transport.stop() } }
    transport.start()
    later.flush()
    #expect(engine.sent.count == 1, "the second strip's command is not sent after stop")
    engine.reply = nil
    transport.start()
    later.flush()
    #expect(arranges(engine).count == 3, "a restart arranges both strips again")
    transport.stop()
  }

  @Test func aStripCommandPlannedOutsideTheTransportIsReportedNotSent() throws {
    let f = try fixture()
    f.transport.start()
    try f.store.dispatch(Command("projectStrips"), origin: .bridge)
    #expect(f.engine.sent.isEmpty)
    #expect(f.trouble.all.contains { $0.contains("only the strip transport may send") })
  }

  @Test func observerRegistrationCanWaitForABackgroundStartupCallback() throws {
    let f = try fixture(actual: [0, 1, 2])
    let startup: JSONValue = ["rev": 2, "cmd": .null,
      "strips": [strip([f.keys[1], f.keys[0], f.keys[2]], active: f.keys[0])]]
    var returned = false
    f.engine.duringObserve = { receive in
      returned = BackgroundStripReceipt(receive).deliver([startup])
    }
    f.transport.start()
    #expect(returned)
    #expect(f.store.memory.chromeTabs.lastRev == 2)
    #expect(f.store.memory.chromeTabs.mirror[7]?.tabs.map(\.key) == [f.keys[1], f.keys[0], f.keys[2]].map(Optional.some))
    f.transport.stop()
  }

  @Test func offMainReceiptsAreReservedBeforeTheMainQueueRuns() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    let receive = try #require(f.engine.observers.values.first)
    let background = BackgroundStripReceipt(receive)
    let first: JSONValue = ["rev": 2, "cmd": .null,
      "strips": [strip([f.keys[1], f.keys[0], f.keys[2]], active: f.keys[0])]]
    let second: JSONValue = ["rev": 3, "cmd": .null,
      "strips": [strip([f.keys[2], f.keys[1], f.keys[0]], active: f.keys[0])]]
    #expect(background.deliver([first, second]))
    #expect(f.engine.sent.isEmpty)
    try f.store.dispatch(Command("activate", [.string(f.keys[1])]))
    #expect(f.store.memory.chromeTabs.lastRev == 3)
    #expect(f.store.memory.chromeTabs.mirror[7]?.tabs.map(\.key) == [f.keys[2], f.keys[1], f.keys[0]].map(Optional.some))
    let window = try #require(f.store.state.tabs[f.keys[1]]?.windowId)
    let profile = try #require(f.store.state.tabs[f.keys[1]]?.profileId)
    #expect(f.store.state.windows[window]?.activeTabIds[profile] == f.keys[1])
    f.transport.stop()
  }

  @Test func anOffMainCallbackFromAnEarlierSubscriptionIsIgnored() throws {
    let f = try fixture(actual: [0, 1, 2])
    f.transport.start()
    f.later.flush()
    let receive = try #require(f.engine.observers.values.first)
    let background = BackgroundStripReceipt(receive)
    f.transport.stop()
    f.transport.start()
    let stale: JSONValue = ["rev": 99, "cmd": .null,
      "strips": [strip(f.keys.reversed(), active: f.keys[2])]]
    #expect(background.deliver([stale]))
    #expect(f.store.memory.chromeTabs.lastRev == 1)
    f.transport.stop()
  }

  @Test func aProjectionScheduledBeforeStopSendsNothing() throws {
    let f = try fixture()
    f.transport.start()
    #expect(f.later.work.count == 1)
    f.transport.stop()
    f.later.flush()
    #expect(f.engine.sent.isEmpty)
    f.transport.start()
    f.later.flush()
    #expect(f.engine.sent.count == 1, "a restarted transport projects again")
    f.transport.stop()
  }
}
