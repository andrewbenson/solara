import Foundation
import Testing
@testable import SolaraEngine

@MainActor
private final class ForgettingFaviconClient: EngineClient {
  var fetched: CheckedContinuation<Data?, Never>?
  var reads = 0
  var writes = 0

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func storedFavicon(page: String, engineProfile: String) async throws -> Data? { reads += 1; return nil }
  func fetchFavicon(source: String, engineProfile: String) async -> Data? {
    await withCheckedContinuation { fetched = $0 }
  }
  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws { writes += 1 }
}

@MainActor
private func forgettingUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !condition() {
    if ContinuousClock.now >= deadline { throw ForgettingTimeout() }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private struct ForgettingTimeout: Error {}

@Suite @MainActor struct FaviconForgettingTests {
  @Test func allWaitersForgetAnInvalidatedPrivateFetch() async throws {
    let client = ForgettingFaviconClient()
    let library = FaviconLibrary(client: client)
    let profile = "incognito:w@p"
    let first = Task { await library.favicon(page: "https://private.test/", source: "https://private.test/icon", engineProfile: profile, appearance: false) }
    try await forgettingUntil { client.fetched != nil }
    var joined = false
    let second = Task {
      joined = true
      return await library.favicon(page: "https://private.test/", source: "https://private.test/icon", engineProfile: profile, appearance: false)
    }
    try await forgettingUntil { joined }
    library.invalidate(engineProfile: profile)
    client.fetched?.resume(returning: Data([9]))
    client.fetched = nil
    #expect(await first.value == nil)
    #expect(await second.value == nil)
    #expect(library.cachedCount == 0)
    #expect(client.reads == 0)
    #expect(client.writes == 0)
    let fresh = Task { await library.favicon(page: "https://private.test/", source: "https://private.test/icon", engineProfile: profile, appearance: false) }
    try await forgettingUntil { client.fetched != nil }
    client.fetched?.resume(returning: Data([8]))
    client.fetched = nil
    #expect(await fresh.value?.data == Data([8]))
    #expect(library.cachedCount == 1)
    #expect(client.writes == 0)
  }

  @Test func allWaitersForgetADeletedPublicPage() async throws {
    let client = ForgettingFaviconClient()
    let library = FaviconLibrary(client: client)
    let first = Task { await library.favicon(page: "https://public.test/", source: "https://public.test/icon", engineProfile: "p", appearance: false) }
    try await forgettingUntil { client.fetched != nil }
    var joined = false
    let second = Task {
      joined = true
      return await library.favicon(page: "https://public.test/", source: "https://public.test/icon", engineProfile: "p", appearance: false)
    }
    try await forgettingUntil { joined }
    library.invalidate(engineProfile: "p", pages: ["https://public.test/#part"])
    client.fetched?.resume(returning: Data([9]))
    #expect(await first.value == nil)
    #expect(await second.value == nil)
    #expect(client.writes == 0)
    #expect(library.cachedCount == 0)
  }
}
