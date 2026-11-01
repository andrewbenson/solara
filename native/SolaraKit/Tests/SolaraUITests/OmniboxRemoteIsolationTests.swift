import Foundation
import SolaraModel
import SolaraOmnibox
import Synchronization
import Testing
@testable import SolaraUI

private final class HeldSuggestions: Sendable {
  private struct State {
    var pending: [String: CheckedContinuation<FetchResponse, Never>] = [:]
    var started: [String] = []
    var cancelled: Set<String> = []
  }

  private let state = Mutex(State())

  func fetch(_ url: String) async throws -> FetchResponse {
    let query = URLComponents(string: url)?.queryItems?.first { $0.name == "q" }?.value ?? ""
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        state.withLock {
          $0.started.append(query)
          $0.pending[query] = continuation
        }
      }
    } onCancel: {
      self.state.withLock { _ = $0.cancelled.insert(query) }
    }
  }

  var started: [String] { state.withLock { $0.started } }
  func cancelled(_ query: String) -> Bool { state.withLock { $0.cancelled.contains(query) } }

  func release(_ query: String) {
    let continuation = state.withLock { $0.pending.removeValue(forKey: query) }
    let data = try! JSONSerialization.data(withJSONObject: [query, ["\(query) remote"]])
    continuation?.resume(returning: FetchResponse(ok: true, body: data))
  }

  func releaseAll() {
    let pending = state.withLock {
      let pending = $0.pending
      $0.pending = [:]
      return pending
    }
    for continuation in pending.values { continuation.resume(returning: FetchResponse(ok: false, body: Data())) }
  }
}

private final class ManualDebounceClock: Sendable {
  private struct Sleeper {
    var deadline: Duration
    var continuation: CheckedContinuation<Void, Error>
  }

  private struct State {
    var now: Duration = .zero
    var nextID = 0
    var sleeps: [Duration] = []
    var cancelled: Set<Int> = []
    var pending: [Int: Sleeper] = [:]
    var closed = false
  }

  private let state = Mutex(State())

  var sleeps: [Duration] { state.withLock { $0.sleeps } }
  var cancelled: Set<Int> { state.withLock { $0.cancelled } }

  func sleep(_ duration: Duration) async throws {
    let id = state.withLock {
      let id = $0.nextID
      $0.nextID += 1
      return id
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let cancelled = state.withLock {
          $0.sleeps.append(duration)
          if $0.closed || Task.isCancelled { return true }
          $0.pending[id] = Sleeper(deadline: $0.now + duration, continuation: continuation)
          return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let sleeper = self.state.withLock {
        $0.cancelled.insert(id)
        return $0.pending.removeValue(forKey: id)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let ready = state.withLock { s in
      s.now += duration
      let ready = s.pending.filter { $0.value.deadline <= s.now }
      for id in ready.keys { s.pending.removeValue(forKey: id) }
      return Array(ready.values)
    }
    for sleeper in ready { sleeper.continuation.resume() }
  }

  func cancelAll() {
    let pending = state.withLock {
      $0.closed = true
      let pending = Array($0.pending.values)
      $0.pending = [:]
      return pending
    }
    for sleeper in pending { sleeper.continuation.resume(throwing: CancellationError()) }
  }
}

@MainActor
struct OmniboxRemoteIsolationTests {
  private func make(_ fetcher: SuggestFetcher?, window: String, variant: BarVariant = .hero) -> HeroBarModel {
    HeroBarModel(
      windowId: window, tabId: UUID().uuidString, profileId: "p", incognito: false,
      settings: { Settings.defaults }, sources: NewTabSources(), fetcher: fetcher, variant: variant)
  }

  private func remoteRows(_ model: HeroBarModel) -> [String] {
    model.items.compactMap {
      if case .search(let query, _, _, true, _) = $0 { query } else { nil }
    }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    return condition()
  }

  @Test(arguments: [BarVariant.hero, .panel, .sidebar])
  func twoWindowsKeepBothRemoteResults(_ variant: BarVariant) async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let shared = SuggestFetcher(fetch: transport.fetch, delay: .zero)
    let a = make(shared, window: "a")
    let b = make(shared, window: "b", variant: variant)
    a.driverType("alpha")
    try #require(try await waitUntil { transport.started == ["alpha"] })
    b.driverType("beta")
    try #require(try await waitUntil { transport.started == ["alpha", "beta"] })
    transport.release("alpha")
    transport.release("beta")
    #expect(try await waitUntil { remoteRows(a) == ["alpha remote"] && remoteRows(b) == ["beta remote"] })
    #expect(!transport.cancelled("alpha"))
  }

  @Test func resettingAHeroDoesNotCancelThePanelInItsWindow() async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let shared = SuggestFetcher(fetch: transport.fetch, delay: .zero)
    let hero = make(shared, window: "a")
    let panel = make(shared, window: "a", variant: .panel)
    hero.driverType("alpha")
    try #require(try await waitUntil { transport.started == ["alpha"] })
    panel.driverType("beta")
    try #require(try await waitUntil { transport.started == ["alpha", "beta"] })
    hero.reset()
    transport.release("alpha")
    transport.release("beta")
    #expect(try await waitUntil { remoteRows(panel) == ["beta remote"] })
    #expect(remoteRows(hero).isEmpty)
    #expect(!transport.cancelled("beta"))
  }

  @Test func tearingDownOneWindowCancelsOnlyItsOwnRequest() async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let shared = SuggestFetcher(fetch: transport.fetch, delay: .zero)
    let b = make(shared, window: "b", variant: .panel)
    b.driverType("beta")
    try #require(try await waitUntil { transport.started == ["beta"] })
    var a: HeroBarModel? = make(shared, window: "a")
    weak var released = a
    a?.driverType("alpha")
    try #require(try await waitUntil { transport.started == ["beta", "alpha"] })
    a = nil
    #expect(released == nil)
    #expect(transport.cancelled("alpha"))
    #expect(!transport.cancelled("beta"))
    transport.release("alpha")
    transport.release("beta")
    #expect(try await waitUntil { remoteRows(b) == ["beta remote"] })
  }

  @Test func newerInputStillCancelsTheSameBarsOlderRequest() async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let model = make(SuggestFetcher(fetch: transport.fetch, delay: .zero), window: "a")
    model.driverType("alpha")
    try #require(try await waitUntil { transport.started == ["alpha"] })
    model.driverType("alphabet")
    try #require(try await waitUntil { transport.started == ["alpha", "alphabet"] })
    #expect(transport.cancelled("alpha"))
    transport.release("alphabet")
    try #require(try await waitUntil { remoteRows(model) == ["alphabet remote"] })
    transport.release("alpha")
    try await Task.sleep(for: .milliseconds(30))
    #expect(remoteRows(model) == ["alphabet remote"])
  }

  @Test func newerInputStillDebouncesTheSameBar() async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let clock = ManualDebounceClock()
    defer { clock.cancelAll() }
    let model = make(SuggestFetcher(fetch: transport.fetch, delay: .milliseconds(30), sleep: clock.sleep), window: "a")
    model.driverType("alpha")
    try #require(try await waitUntil { clock.sleeps == [.milliseconds(30)] })
    #expect(transport.started.isEmpty)
    model.driverType("alphabet")
    try #require(try await waitUntil { clock.sleeps == [.milliseconds(30), .milliseconds(30)] })
    #expect(clock.cancelled == [0])
    #expect(transport.started.isEmpty)
    clock.advance(by: .milliseconds(30))
    try #require(try await waitUntil { transport.started == ["alphabet"] })
    transport.release("alphabet")
    #expect(try await waitUntil { remoteRows(model) == ["alphabet remote"] })
  }

  @Test(arguments: [false, true], [false, true])
  func offlinePropStopsConfiguredBarsAndCanResume(_ hero: Bool, _ startsOffline: Bool) async throws {
    let transport = HeldSuggestions()
    defer { transport.releaseAll() }
    let shared = SuggestFetcher(fetch: transport.fetch, delay: .zero)
    let setFetcher: (SuggestFetcher?) -> Void
    let model: HeroBarModel
    if hero {
      let view = NewTabHeroView(frame: .zero)
      view.settings = { Settings.defaults }
      view.fetcher = startsOffline ? nil : shared
      view.configure(NewTabIdentity(windowId: "a", tabId: UUID().uuidString, profileId: "p"))
      model = try #require(view.model)
      setFetcher = { view.fetcher = $0 }
    } else {
      let view = OmniboxBarView(frame: .zero)
      view.settings = { Settings.defaults }
      view.fetcher = startsOffline ? nil : shared
      view.configure(OmniboxBarIdentity(windowId: "a", tabId: UUID().uuidString, profileId: "p", variant: .panel, opensTab: false, initialText: ""))
      model = try #require(view.model)
      setFetcher = { view.fetcher = $0 }
    }
    model.driverType("alpha")
    if startsOffline {
      try await Task.sleep(for: .milliseconds(30))
      #expect(transport.started.isEmpty)
      #expect(remoteRows(model).isEmpty)
      setFetcher(shared)
    }
    try #require(try await waitUntil { transport.started == ["alpha"] })
    setFetcher(nil)
    #expect(transport.cancelled("alpha"))
    transport.release("alpha")
    model.driverType("beta")
    try await Task.sleep(for: .milliseconds(30))
    #expect(transport.started == ["alpha"])
    #expect(remoteRows(model).isEmpty)
    setFetcher(shared)
    try #require(try await waitUntil { transport.started == ["alpha", "beta"] })
    transport.release("beta")
    #expect(try await waitUntil { remoteRows(model) == ["beta remote"] })
    setFetcher(nil)
    #expect(remoteRows(model).isEmpty)
    setFetcher(shared)
    #expect(try await waitUntil { transport.started == ["alpha", "beta", "beta"] })
  }
}
