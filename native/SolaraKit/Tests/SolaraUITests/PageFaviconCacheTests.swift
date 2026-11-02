import AppKit
import SolaraEngine
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct PageFaviconCacheTests {
  @Test func heldPrivateLoadCannotRestoreAMissAfterSessionEnd() async throws {
    try await heldPrivateLoadCannotRestoreAHitOrMissAfterSessionEnd(returnsImage: false)
  }

  @Test func heldPrivateLoadCannotRestoreAHitAfterSessionEnd() async throws {
    try await heldPrivateLoadCannotRestoreAHitOrMissAfterSessionEnd(returnsImage: true)
  }

  private func heldPrivateLoadCannotRestoreAHitOrMissAfterSessionEnd(returnsImage: Bool) async throws {
    let client = HeldUIFaviconClient()
    let library = FaviconLibrary(client: client)
    let profile = "incognito:held-page-\(UUID().uuidString)@profile-a"
    let url = "https://private.test/"
    let favicon = "https://private.test/icon.png"
    let sentinelURL = "https://private.test/sentinel"
    let stale = NSImage(size: NSSize(width: 16, height: 16))
    let fresh = NSImage(size: NSSize(width: 32, height: 32))
    var loads = 0
    let favicons = PageFavicons(load: { page, source, profile, _ in
      if page == sentinelURL { return fresh }
      loads += 1
      if loads > 1 { return fresh }
      let result = await client.fetchFavicon(source: source ?? "", engineProfile: profile)
      return result.map { _ in stale }
    })
    let request = Task { @MainActor in
      let result = await favicons.fetch(url, favicon, profile, dark: false)
      #expect(result == nil)
      #expect(favicons.cached(url, favicon, profile, dark: false) == nil)
      #expect(loads == 1)
      let retried = await favicons.fetch(url, favicon, profile, dark: false)
      #expect(retried === fresh)
      #expect(loads == 2)
    }
    defer { client.finish(nil) }
    try await client.waitForFetch()
    #expect(loads == 1)
    #expect(await favicons.fetch(sentinelURL, nil, profile, dark: false) === fresh)
    #expect(favicons.cached(sentinelURL, nil, profile, dark: false) === fresh)

    withExtendedLifetime(library) {
      NotificationCenter.default.post(name: FaviconLibrary.didEndPrivateSession, object: nil, userInfo: ["aliases": [profile]])
    }
    #expect(favicons.cached(sentinelURL, nil, profile, dark: false) == nil)
    client.finish(returnsImage ? Data([9]) : nil)
    await request.value
  }
}

@MainActor
final class HeldUIFaviconClient: EngineClient {
  private var held: CheckedContinuation<Data?, Never>?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }

  func fetchFavicon(source: String, engineProfile: String) async -> Data? {
    await withCheckedContinuation { continuation in
      held = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.finish(nil) }
    }
  }

  func waitForFetch() async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while held == nil {
      if ContinuousClock.now >= deadline { throw HeldUIFaviconTimeout() }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func finish(_ data: Data?) {
    let continuation = held
    held = nil
    continuation?.resume(returning: data)
  }
}

private struct HeldUIFaviconTimeout: Error {}
