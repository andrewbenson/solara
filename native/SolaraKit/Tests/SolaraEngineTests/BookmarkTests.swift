import Foundation
import Testing
@testable import SolaraEngine

@MainActor
final class FakeBookmarkClient: EngineClient {
  var trees: [String: EngineBookmarkTree] = [:]
  var reads: [String] = []
  var watches: [String] = []
  var onRead: (() -> Void)?
  var handler: (@MainActor @Sendable (String) -> Void)?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) { self.handler = handler }
  func watchBookmarks(engineProfile: String) async throws { watches.append(engineProfile) }
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    reads.append(engineProfile)
    onRead?()
    guard let tree = trees[engineProfile] else { throw BookmarkReadUnavailable.unsupported }
    return tree
  }
  func emit(_ profile: String) { handler?(profile) }
}

@Suite @MainActor struct BookmarkTests {
  func tree(_ title: String, id: String = "a") -> EngineBookmarkTree {
    let link = EngineBookmarkNode(id: id, kind: "u", title: title, url: "https://\(id).example/", addedAt: 10)
    return EngineBookmarkTree(
      bar: EngineBookmarkNode(id: "chrome-bar", kind: "f", title: "Chrome bar", children: [link]),
      other: EngineBookmarkNode(id: "chrome-other", kind: "f", title: "Chrome other", children: []))
  }

  @Test func staysUnreadyUntilChromeTreeIsRead() async {
    let client = FakeBookmarkClient()
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    client.onRead = { #expect(!catalog.bookmarks(engineProfile: "p").ready) }
    await catalog.start(engineProfiles: ["p"])
    #expect(!catalog.bookmarks(engineProfile: "p").ready)
    client.trees["p"] = tree("A")
    await catalog.reloadBookmarks(engineProfile: "p")
    let snapshot = catalog.bookmarks(engineProfile: "p")
    #expect(snapshot.ready)
    #expect(snapshot.revision == 1)
    #expect(snapshot.roots == BookmarkRoots(bar: "bar@p", other: "other@p"))
    #expect(snapshot.nodes["a"]?.parentId == "bar@p")
    #expect(snapshot.nodes["bar@p"]?.title == "Bookmarks Bar")
    #expect(client.watches.count == 2)
  }

  @Test func changeEventRereadsAndRevisionsOnlyWhenTreeChanges() async throws {
    let client = FakeBookmarkClient()
    client.trees["p"] = tree("A")
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["p"])
    var updates = catalog.observeBookmarks(engineProfile: "p").makeAsyncIterator()
    #expect(await updates.next()?.revision == 1)
    client.trees["p"] = tree("B")
    client.emit("p")
    for _ in 0..<100 where catalog.bookmarks(engineProfile: "p").revision < 2 { try await Task.sleep(for: .milliseconds(1)) }
    #expect(client.reads == ["p", "p"])
    #expect(catalog.bookmarks(engineProfile: "p").nodes["a"]?.title == "B")
    #expect(await updates.next()?.revision == 2)
    client.emit("p")
    for _ in 0..<100 where client.reads.count < 3 { try await Task.sleep(for: .milliseconds(1)) }
    #expect(catalog.bookmarks(engineProfile: "p").revision == 2)
  }

  @Test func profilesAreIsolatedAndPrivateProfilesAreSkipped() async {
    let client = FakeBookmarkClient()
    client.trees["p"] = tree("P")
    client.trees["q"] = tree("Q", id: "q")
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["p", "q", "incognito:w@p"])
    #expect(catalog.bookmarks(engineProfile: "p").nodes["a"]?.title == "P")
    #expect(catalog.bookmarks(engineProfile: "q").nodes["q"]?.title == "Q")
    #expect(!catalog.bookmarks(engineProfile: "incognito:w@p").ready)
    client.trees["p"] = tree("P2")
    await catalog.reloadBookmarks(engineProfile: "p")
    #expect(catalog.bookmarks(engineProfile: "q").revision == 1)
    #expect(catalog.bookmarks(engineProfile: "p").revision == 2)
  }

  @Test func explicitWriteSignalRereadsPartialApplyResult() async {
    let client = FakeBookmarkClient()
    client.trees["p"] = tree("First")
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["p"])
    client.trees["p"] = tree("Applied")
    await catalog.reloadBookmarks(engineProfile: "p")
    #expect(catalog.bookmarks(engineProfile: "p").nodes["a"]?.title == "Applied")
    #expect(catalog.bookmarks(engineProfile: "p").revision == 2)
  }
}
