import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkFactLinkInteractionTests {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkFactLinks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func document() -> JSONValue {
    let roots = BookmarkFlat.roots("")
    var nodes: JSONObject = [
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": ["A", "B", "C"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0]
    ]
    for id in ["A", "B", "C"] {
      nodes[id] = ["id": .string(id), "kind": "url", "parentId": .string(roots.bar), "title": .string(id), "url": .string("https://\(id.lowercased()).test"), "addedAt": 1]
    }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": .string(roots.bar), "other": .string(roots.other)], "alias": ["bar": .string(roots.bar), "other": .string(roots.other)]]]
  }

  private func owner(_ directory: URL) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", now: { 100 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
  }

  private func rename(_ title: String) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["A", ["title": .string(title)]])
  }

  @Test func siblingReorderUsesCurrentLinkPredecessorsAcrossRelaunchAndAliases() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = owner(directory)
    first.seed(engine: "", document: document(), ready: true)
    #expect(first.setBookmarkSyncLinks(["p": "old", "alias": "old"]))
    let keys = ["bm:A", "bm:B", "bm:C"]
    #expect(try first.observeRemoteRecords(profileId: "alias", expectedEngine: "", records: keys.map { (key: $0, hlc: "0000003uw.0009.old") }))
    #expect(first.setBookmarkSyncLinks(["p": "new", "alias": "old"]))
    #expect(try first.observeRemoteRecords(profileId: "p", expectedEngine: "", records: keys.map { (key: $0, hlc: "00000005k.0001.new") }))
    let recovered = owner(directory)
    let bar = BookmarkFlat.roots("").bar
    try recovered.submit(profile: "p", mutations: [.init(method: "moveBookmark", args: ["A", .string(bar), 2])])
    let reordered = recovered.bookmarkFacts(profileId: "p")
    #expect(Set(reordered.keys) == Set(keys))
    for key in keys {
      let fact = try #require(reordered[key])
      #expect(fact.at == 100 && fact.after == "00000005k.0001.new" && fact.link == "new")
    }
    #expect(owner(directory).bookmarkFacts(profileId: "p") == reordered)
    try recovered.submit(profile: "alias", mutations: [.init(method: "moveBookmark", args: ["A", .string(bar), 0])])
    let aliasFacts = recovered.bookmarkFacts(profileId: "alias")
    for key in keys {
      let fact = try #require(aliasFacts[key])
      #expect(fact.seq > (reordered[key]?.seq ?? 0))
      #expect(fact.after == "0000003uw.0009.old" && fact.link == "old")
    }
    #expect(owner(directory).bookmarkFacts(profileId: "alias") == aliasFacts)
  }

  @Test func republishedOldLinkAckDoesNotPromoteAnOldAliasEdit() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = owner(directory)
    coordinator.seed(engine: "", document: document(), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "old", "alias": "old"]))
    try coordinator.submit(profile: "p", mutations: [rename("Publishing old intent in new link")])
    let publishing = try #require(coordinator.bookmarkFacts(profileId: "p")["bm:A"])
    #expect(coordinator.setBookmarkSyncLinks(["p": "new", "alias": "old"]))
    try coordinator.submit(profile: "alias", mutations: [rename("Later old alias intent")])
    let surviving = try #require(coordinator.bookmarkFacts(profileId: "alias")["bm:A"])
    #expect(surviving.seq > publishing.seq && surviving.after == nil)
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [(key: "bm:A", seq: publishing.seq, mintedHLC: "0000003uw.0000.device")]))
    #expect(coordinator.bookmarkFacts(profileId: "alias")["bm:A"] == surviving)
    #expect(owner(directory).bookmarkFacts(profileId: "alias")["bm:A"] == surviving)
    let recovered = owner(directory)
    try recovered.submit(profile: "p", mutations: [rename("New chain edit")])
    #expect(recovered.bookmarkFacts(profileId: "p")["bm:A"]?.after == "0000003uw.0000.device")
    try recovered.submit(profile: "alias", mutations: [rename("Old alias edit")])
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:A"]?.after == nil)
    #expect(recovered.bookmarkFacts(profileId: "alias")["bm:A"]?.link == "old")
  }
}
