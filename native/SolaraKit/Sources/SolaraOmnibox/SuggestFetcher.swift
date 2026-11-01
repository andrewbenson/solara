import Foundation
import Synchronization

public struct FetchResponse: Sendable {
  public var ok: Bool
  public var body: Data

  public init(ok: Bool, body: Data) {
    self.ok = ok
    self.body = body
  }
}

public final class SuggestFetcher: Sendable {
  public typealias Fetch = @Sendable (String) async throws -> FetchResponse
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  private struct State {
    var generation = 0
    var pending: Task<Void, Never>?
    var cache: [String: [String]] = [:]
    var order: [String] = []
  }

  private let fetch: Fetch
  private let delay: Duration
  private let sleep: Sleep
  private let cacheSize: Int
  private let state = Mutex(State())

  public init(
    fetch: @escaping Fetch, delay: Duration = .milliseconds(120), cacheSize: Int = 64,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.fetch = fetch
    self.delay = delay
    self.sleep = sleep
    self.cacheSize = cacheSize
  }

  public func makeContext() -> SuggestFetcher {
    SuggestFetcher(fetch: fetch, delay: delay, cacheSize: cacheSize, sleep: sleep)
  }

  public static func urlSession(_ session: URLSession = .shared) -> Fetch {
    { url in
      guard let target = URL(string: url) else { return FetchResponse(ok: false, body: Data()) }
      let (data, response) = try await session.data(from: target)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 200
      return FetchResponse(ok: (200...299).contains(status), body: data)
    }
  }

  public func cancel() {
    state.withLock { s in
      s.generation += 1
      s.pending?.cancel()
      s.pending = nil
    }
  }

  private func remember(_ url: String, _ suggestions: [String]) {
    state.withLock { s in
      if s.cache[url] != nil { s.order.removeAll { $0 == url } }
      s.cache[url] = suggestions
      s.order.append(url)
      if s.order.count > cacheSize { s.cache[s.order.removeFirst()] = nil }
    }
  }

  private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation == generation } }

  public func request(_ engine: SearchEngine, _ query: String, onResult: @escaping @Sendable ([String]) -> Void) {
    cancel()
    guard let url = suggestRequestUrl(engine, query) else { return }
    let (current, cached) = state.withLock { ($0.generation, $0.cache[url]) }
    if let cached {
      let task = Task { [weak self] in
        if self?.isCurrent(current) == true { onResult(cached) }
      }
      state.withLock { if $0.generation == current { $0.pending = task } }
      return
    }
    let fetch = self.fetch
    let delay = self.delay
    let sleep = self.sleep
    let task = Task { [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      if Task.isCancelled { return }
      let suggestions: [String]
      do {
        let response = try await fetch(url)
        suggestions = response.ok ? ((try? ParsedJSON(parsing: response.body)).map(parseSuggestions) ?? []) : []
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      self.remember(url, suggestions)
      let deliver = self.state.withLock { s -> Bool in
        guard s.generation == current else { return false }
        s.pending = nil
        return true
      }
      if deliver { onResult(suggestions) }
    }
    state.withLock { s in
      if s.generation == current { s.pending = task } else { task.cancel() }
    }
  }
}
