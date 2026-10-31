import Foundation
import SolaraModel
@testable import SolaraStore
import Synchronization
import Testing

@Suite struct StoreScopeTests {
  @Test func inScopeIssueAdmitsNothingBetweenRecheckAndInvoke() throws {
    let store = makeStore()
    let seen = SequencerValues<Int>()
    store.subscribe { seen.append($0.rev) }
    try store.sequence {
      try store.dispatch(settingsCommand(["sidebarWidth": 210]))
      let cursor = store.deliveryCursor()
      #expect(cursor.committed == 1)
      #expect(cursor.delivered == 0)
      store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
      try store.withinSequence {
        let atInvoke = store.deliveryCursor()
        #expect(atInvoke.committed == 1)
        #expect(atInvoke.delivered == 0)
        #expect(seen.all.isEmpty)
      }
    }
    #expect(seen.all == [1])
    let cursor = store.deliveryCursor()
    #expect(cursor.committed == 2)
    #expect(cursor.delivered == 1)
    #expect(seen.all == [1, 2])
    #expect(store.deliveryCursor().delivered == 2)
  }

  @Test func competingReservationWaitsUntilInScopeInvocationCompletes() throws {
    let store = makeStore()
    let attempting = DispatchSemaphore(value: 0)
    let reserved = DispatchSemaphore(value: 0)
    let order = SequencerValues<String>()
    store.subscribe { _ in order.append("commit") }
    try store.sequence {
      Thread.detachNewThread {
        attempting.signal()
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
        order.append("reserved")
        reserved.signal()
      }
      #expect(attempting.wait(timeout: .now() + 3) == .success)
      try store.withinSequence {
        #expect(reserved.wait(timeout: .now()) == .timedOut)
        order.append("invoke")
        #expect(store.deliveryCursor().committed == 0)
      }
    }
    #expect(reserved.wait(timeout: .now() + 3) == .success)
    #expect(order.all == ["invoke", "reserved"])
    #expect(store.deliveryCursor().committed == 1)
    #expect(order.all == ["invoke", "reserved", "commit"])
  }

  @Test func deliveryCursorLagsUntilOuterExit() throws {
    let store = makeStore()
    let cursors = SequencerValues<[Int]>()
    store.subscribe { _ in
      let cursor = store.deliveryCursor()
      cursors.append([cursor.committed, cursor.delivered])
    }
    try store.sequence {
      try store.dispatch(settingsCommand(["sidebarWidth": 210]))
      try store.dispatch(settingsCommand(["sidebarWidth": 220]))
      let cursor = store.deliveryCursor()
      #expect(cursor.committed == 2)
      #expect(cursor.delivered == 0)
      #expect(cursors.all.isEmpty)
    }
    #expect(cursors.all == [[2, 0], [2, 1]])
    #expect(store.deliveryCursor().committed == 2)
    #expect(store.deliveryCursor().delivered == 2)
  }

  @Test func deliveryCursorRemainsBehindAListenerOnAnotherThread() throws {
    let store = makeStore()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let errors = SequencerValues<String>()
    store.subscribe { commit in
      if commit.rev == 1 {
        entered.signal()
        #expect(release.wait(timeout: .now() + 3) == .success)
      }
    }
    Thread.detachNewThread {
      do { try store.dispatch(settingsCommand(["sidebarWidth": 210])) }
      catch { errors.append(String(describing: error)) }
      done.signal()
    }
    defer { release.signal() }
    #expect(entered.wait(timeout: .now() + 3) == .success)
    try store.dispatch(settingsCommand(["sidebarWidth": 220]))
    let cursor = store.deliveryCursor()
    #expect(cursor.committed == 2)
    #expect(cursor.delivered == 0)
    release.signal()
    #expect(done.wait(timeout: .now() + 3) == .success)
    #expect(errors.all.isEmpty)
    #expect(store.deliveryCursor().delivered == 2)
  }

  @Test func withinSequencePropagatesBodyErrorWithoutExitDrain() throws {
    let store = makeStore()
    let seen = SequencerValues<Int>()
    store.subscribe { seen.append($0.rev) }
    #expect(throws: CommandError.self) {
      try store.sequence {
        try store.withinSequence {
          store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
          throw CommandError("body")
        }
      }
    }
    #expect(seen.all.isEmpty)
    #expect(store.deliveryCursor().committed == 1)
    #expect(seen.all == [1])
  }

  #if !DEBUG
    @Test func withinSequenceRefusesWithoutCallingBodyOutsideScope() {
      let store = makeStore()
      let calls = SequencerValues<Bool>()
      #expect(throws: StoreSequenceRequired.self) { try store.withinSequence { calls.append(true) } }
      #expect(calls.all.isEmpty)
    }

    @Test func withinSequenceRefusesAnotherThreadsScope() throws {
      let store = makeStore()
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        store.sequence {
          entered.signal()
          #expect(release.wait(timeout: .now() + 3) == .success)
        }
        done.signal()
      }
      defer { release.signal() }
      #expect(entered.wait(timeout: .now() + 3) == .success)
      #expect(throws: StoreSequenceRequired.self) { try store.withinSequence {} }
      release.signal()
      #expect(done.wait(timeout: .now() + 3) == .success)
    }
  #endif

  @Test func liveChangeCarriesSessionGenerationAcrossDiscardGoneReady() throws {
    var config = StoreConfig()
    config.listeners = []
    let store = Store(config: config)
    let window = try #require(store.dispatch(Command("createWindow", [["url": "https://scope.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    let sequence = try #require(store.state.tabs[id]?.navigation?.seq)
    func report(_ value: JSONValue) throws { try store.dispatch(Command("pageReport", [.string(id), value])) }
    func created(_ generation: String) -> JSONValue {
      ["type": "created", "generation": .string(generation), "engine": "chromium", "navigationSeq": .number(sequence),
        "contextRevision": 0, "wasNewTab": false, "newTabShownUrl": .null]
    }
    try report(created("G"))
    let seen = SequencerValues<LiveChange>()
    let token = store.observeLive(tabId: id) { seen.append($0) }.token
    defer { store.unsubscribe(token) }
    try store.sequence {
      try report(["type": "discarded", "generation": "G", "url": "https://scope.example/"])
      try report(["type": "ready", "generation": "G", "browserId": 7])
      try report(["type": "discarded", "generation": "G", "url": "https://scope.example/"])
      try report(["type": "gone", "generation": "G"])
      try report(created("H"))
      try report(["type": "discarded", "generation": "H", "url": "https://scope.example/"])
    }
    #expect(seen.all.map(\.previousGeneration) == ["G", "G", "G", "G", "H"])
    #expect(seen.all.map(\.currentGeneration) == ["G", "G", "G", nil, "H"])
    #expect(seen.all.map { $0.current?.discarded } == [true, false, true, false, true])
    let legacy = LiveChange(tabId: id, rev: 0, previous: nil, current: nil, url: nil, profileId: nil)
    #expect(legacy.previousGeneration == nil)
    #expect(legacy.currentGeneration == nil)
  }
}
