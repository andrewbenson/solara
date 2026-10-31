import Foundation
import SolaraModel
import SolaraStore
import Testing

func liveObservationStore(_ ids: [String] = ["tab"]) -> Store {
  var state = BrowserState(settings: Settings.hydrated(from: nil))
  var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
  window.tabIds = ids
  window.activeTabIds["default"] = ids.first
  state.windows["w"] = window
  state.windowOrder = ["w"]
  for id in ids { state.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://observed.example/", now: 0) }
  var config = StoreConfig()
  config.listeners = []
  return Store(state: state, config: config, checksInvariants: true, clock: { 1_000 })
}

func insertObservationTab(_ id: String, into state: inout BrowserState) {
  state.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://observed.example/", now: 0)
  state.windows["w"]!.tabIds.append(id)
  state.windows["w"]!.activeTabIds["default"] = id
}

func removeObservationTab(_ id: String, from state: inout BrowserState) {
  state.tabs[id] = nil
  state.windows["w"]!.tabIds.removeAll { $0 == id }
  if state.windows["w"]!.activeTabIds["default"] == id {
    state.windows["w"]!.activeTabIds["default"] = state.windows["w"]!.tabIds.first
  }
}

@Suite struct LiveObservationTests {
  @Test func baselineAndRegistrationShareTheBarrierWithReentrantDelivery() throws {
    let store = liveObservationStore()
    let changes = SequencerValues<LiveChange>()
    let registrations = SequencerValues<PageLiveFacts?>()
    let tokens = SequencerValues<Int>()
    store.subscribe { commit in
      if commit.rev == 1 {
        try? store.transact { $0.update { $0.live["tab"] = PageLiveFacts(isLoading: true) } }
        let registration = store.observeLive(tabId: "tab") { changes.append($0) }
        registrations.append(registration.baseline)
        tokens.append(registration.token)
      }
    }
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    store.sequence {}
    #expect(registrations.all == [PageLiveFacts(isLoading: true)])
    #expect(changes.all.isEmpty)
    try store.transact { $0.update { $0.live["tab"] = PageLiveFacts(isLoading: false) } }
    #expect(changes.all.count == 1)
    #expect(changes.all.first?.previous == PageLiveFacts(isLoading: true))
    #expect(changes.all.first?.current == PageLiveFacts(isLoading: false))
    store.unsubscribe(tokens.all[0])
  }

  @Test func concurrentRegistrationCapturesAContiguousBaselineAndSubsequentEdges() throws {
    let store = liveObservationStore()
    try store.transact { $0.update { $0.live["tab"] = PageLiveFacts(themeColor: "0") } }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let registering = DispatchSemaphore(value: 0)
    let registered = DispatchSemaphore(value: 0)
    let continueCommits = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let observed = SequencerValues<LiveChange>()
    let allObserved = SequencerValues<LiveChange>()
    let baselines = SequencerValues<PageLiveFacts?>()
    let tokens = SequencerValues<Int>()
    let failures = SequencerValues<String>()
    defer { release.signal(); continueCommits.signal() }
    Thread.detachNewThread {
      do {
        try store.transact { session in
          session.update { $0.live["tab"] = PageLiveFacts(themeColor: "1") }
          entered.signal()
          #expect(release.wait(timeout: .now() + 5) == .success)
        }
        #expect(continueCommits.wait(timeout: .now() + 5) == .success)
        for i in 2...100 {
          try store.transact { $0.update { $0.live["tab"] = PageLiveFacts(themeColor: String(i)) } }
        }
      } catch { failures.append(String(describing: error)) }
      finished.signal()
    }
    #expect(entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
      registering.signal()
      let tab = store.observeLive(tabId: "tab") { observed.append($0) }
      let all = store.observeLive { allObserved.append($0) }
      baselines.append(tab.baseline)
      baselines.append(all.baseline["tab"])
      tokens.append(tab.token)
      tokens.append(all.token)
      registered.signal()
    }
    #expect(registering.wait(timeout: .now() + 5) == .success)
    #expect(registered.wait(timeout: .now() + 0.05) == .timedOut)
    release.signal()
    #expect(registered.wait(timeout: .now() + 5) == .success)
    continueCommits.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(failures.all.isEmpty)
    #expect(baselines.all == [PageLiveFacts(themeColor: "1"), PageLiveFacts(themeColor: "1")])
    for changes in [observed.all, allObserved.all] {
      #expect(changes.count == 99)
      #expect(changes.map { Int($0.current!.themeColor!)! } == Array(2...100))
      #expect(changes.map { Int($0.previous!.themeColor!)! } == Array(1...99))
      #expect(changes.map(\.rev) == Array(3...101))
    }
    for token in tokens.all { store.unsubscribe(token) }
    #expect(store.state.live["tab"]?.themeColor == "100")
  }

  @Test func allTabsBaselineDiffsAndUnsubscribe() throws {
    let store = liveObservationStore(["a"])
    try store.transact { $0.update { $0.live["a"] = PageLiveFacts(isLoading: true) } }
    let changes = SequencerValues<LiveChange>()
    let registration = store.observeLive { changes.append($0) }
    #expect(registration.baseline == ["a": PageLiveFacts(isLoading: true)])
    #expect(changes.all.isEmpty)
    try store.transact { session in session.update {
      removeObservationTab("a", from: &$0)
      insertObservationTab("b", into: &$0)
      $0.live["b"] = PageLiveFacts(playingAudio: true)
    } }
    #expect(changes.all.map(\.tabId) == ["a", "b"])
    #expect(changes.all.map(\.rev) == [2, 2])
    #expect(changes.all[0].previous == PageLiveFacts(isLoading: true))
    #expect(changes.all[0].current == nil)
    #expect(changes.all[1].previous == nil)
    #expect(changes.all[1].current == PageLiveFacts(playingAudio: true))
    store.unsubscribe(registration.token)
    try store.transact { $0.update { removeObservationTab("b", from: &$0) } }
    #expect(changes.all.count == 2)
  }

  @Test func factsAndMetadataComeFromTheSameCommitAndCallbacksUseItsThread() throws {
    let store = makeStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://old.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    let changes = SequencerValues<LiveChange>()
    let threads = SequencerValues<Bool>()
    let registration = store.observeLive(tabId: id) {
      changes.append($0)
      threads.append(Thread.current.threadDictionary["liveObservationCommit"] as? Bool == true)
    }
    #expect(registration.baseline == PageLiveFacts())
    Thread.current.threadDictionary["liveObservationCommit"] = true
    defer { Thread.current.threadDictionary.removeObject(forKey: "liveObservationCommit") }
    let commit = try store.transact { session in session.update {
      $0.tabs[id]!.url = "https://new.example/"
      $0.live[id] = PageLiveFacts(isLoading: true)
    } }
    #expect(changes.all.count == 1)
    #expect(changes.all[0].rev == commit.rev)
    #expect(changes.all[0].url == "https://new.example/")
    #expect(changes.all[0].profileId == "default")
    #expect(threads.all == [true])
    try store.dispatch(settingsCommand(["sidebarWidth": 210]))
    #expect(changes.all.count == 1)
  }

  @Test func aTabIdCanDisappearAndReturnWithoutLosingTheNewValue() throws {
    let store = liveObservationStore([])
    let changes = SequencerValues<LiveChange>()
    let registration = store.observeLive(tabId: "reused") { changes.append($0) }
    #expect(registration.baseline == nil)
    try store.transact { $0.update {
      insertObservationTab("reused", into: &$0)
      $0.live["reused"] = PageLiveFacts(isLoading: true)
    } }
    try store.transact { $0.update { removeObservationTab("reused", from: &$0) } }
    try store.transact { $0.update {
      insertObservationTab("reused", into: &$0)
      $0.live["reused"] = PageLiveFacts(playingAudio: true)
    } }
    #expect(changes.all.map(\.rev) == [1, 2, 3])
    #expect(changes.all[1].current == nil)
    #expect(changes.all[2].previous == nil)
    #expect(changes.all[2].current == PageLiveFacts(playingAudio: true))
  }
}
