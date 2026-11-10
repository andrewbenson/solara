import Foundation
import Testing
@testable import SolaraEngine

@MainActor
final class CommandClient: EngineClient {
  var calls: [String] = []
  var tree = EngineBookmarkTree(
    bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: []),
    other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
  var result = BookmarkApplyResult(applied: 0, skipped: 0, invalid: [])
  var holdRead = false
  var readGate: CheckedContinuation<Void, Never>?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    if holdRead {
      holdRead = false
      await withCheckedContinuation { readGate = $0 }
    }
    return tree
  }
  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws {
    calls.append("favicon:\(engineProfile):\(page):\(source):\(data.count)")
  }
  func deleteHistory(urls: [String], engineProfile: String) async throws { calls.append("delete:\(engineProfile):\(urls.joined(separator: ","))") }
  func importHistory(rows: [HistoryImportRow], engineProfile: String) async throws { calls.append("import:\(engineProfile):\(rows.count):\(rows.first?.visits ?? 0)") }
  func addHistoryVisits(pages: [HistoryVisitPage], toleranceMs: Double, engineProfile: String) async throws -> Int {
    calls.append("add:\(engineProfile):\(pages.first?.visitTimes.first ?? 0):\(toleranceMs)")
    return 1
  }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    calls.append("bookmark:\(engineProfile):\(ops.first?.id ?? "")")
    tree.bar.children = [EngineBookmarkNode(id: "new", kind: "u", title: "New", url: "https://new", addedAt: 1)]
    return result
  }
}

@Suite @MainActor struct LibraryCommandTests {
  @Test func routesHistoryCommandsWithTheirArguments() async throws {
    let client = CommandClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    try await catalog.deleteHistory(urls: ["https://a", "https://b"], engineProfile: "p")
    try await catalog.importHistory(rows: [.init(url: "https://a", title: "A", visits: 4, lastVisit: 12)], engineProfile: "p")
    let count = try await catalog.addHistoryVisits(pages: [.init(url: "https://b", title: "B", visitTimes: [15])], toleranceMs: 60_000, engineProfile: "p")
    #expect(count == 1)
    #expect(client.calls == ["delete:p:https://a,https://b", "import:p:1:4", "add:p:15.0:60000.0"])
  }

  @Test func retiredRawBookmarkApplyRefusesWithoutCallingClient() async throws {
    let client = CommandClient()
    client.result = BookmarkApplyResult(applied: 1, skipped: 1, invalid: ["bad"])
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["p"])
    let before = catalog.bookmarks(engineProfile: "p").revision
    do {
      _ = try await catalog.applyBookmarks(ops: [.init(op: "add", id: "new", kind: "u", title: "New", url: "https://new", addedAt: 1, parent: "bar")], engineProfile: "p")
      Issue.record("retired raw bookmark command was accepted")
    } catch BookmarkCoordinatorError.ownershipUnavailable {}
    #expect(client.calls.isEmpty)
    #expect(catalog.bookmarks(engineProfile: "p").revision == before)
    #expect(catalog.bookmarks(engineProfile: "p").nodes["new"] == nil)
  }

  @Test func retiredApplyNeverWaitsForOrMutatesAnOngoingReload() async throws {
    let client = CommandClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["p"])
    client.holdRead = true
    let reload = Task { await catalog.reloadBookmarks(engineProfile: "p") }
    for _ in 0..<100 where client.readGate == nil { await Task.yield() }
    #expect(client.readGate != nil)
    do {
      _ = try await catalog.applyBookmarks(ops: [.init(op: "add", id: "new")], engineProfile: "p")
      Issue.record("retired raw bookmark command was accepted during reload")
    } catch BookmarkCoordinatorError.ownershipUnavailable {}
    #expect(client.calls.isEmpty)
    client.readGate?.resume()
    await reload.value
    #expect(catalog.bookmarks(engineProfile: "p").nodes["new"] == nil)
  }

  @Test func storesFaviconThroughClient() async throws {
    let client = CommandClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    try await catalog.storeFavicon(page: "https://a", source: "https://a/icon.png", data: Data([1, 2]), engineProfile: "p")
    #expect(client.calls == ["favicon:p:https://a:https://a/icon.png:2"])
  }

  @Test func refusesPrivateProfilesWithoutCallingClient() async {
    let client = CommandClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    var refused = 0
    do { try await catalog.deleteHistory(urls: ["https://a"], engineProfile: "incognito:p") } catch LibraryCommandError.privateProfile { refused += 1 } catch {}
    do { try await catalog.importHistory(rows: [], engineProfile: "incognito:p") } catch LibraryCommandError.privateProfile { refused += 1 } catch {}
    do { _ = try await catalog.addHistoryVisits(pages: [], toleranceMs: 1000, engineProfile: "incognito:p") } catch LibraryCommandError.privateProfile { refused += 1 } catch {}
    do { _ = try await catalog.applyBookmarks(ops: [], engineProfile: "incognito:p") } catch LibraryCommandError.privateProfile { refused += 1 } catch {}
    do { try await catalog.storeFavicon(page: "a", source: "b", data: Data([1]), engineProfile: "incognito:p") } catch LibraryCommandError.privateProfile { refused += 1 } catch {}
    #expect(refused == 5)
    #expect(client.calls.isEmpty)
  }
}
