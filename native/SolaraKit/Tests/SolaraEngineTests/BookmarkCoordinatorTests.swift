import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkCoordinatorTests {
  let page = "https://example.test/é"

  func document(_ urls: [String]) -> JSONValue {
    var nodes: JSONObject = ["bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": .array(urls.indices.map { .string("b\($0)") }), "addedAt": 0], "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0]]
    for (i, url) in urls.enumerated() { nodes["b\(i)"] = ["id": .string("b\(i)"), "kind": "url", "parentId": "bar@default", "title": "Page", "url": .string(url), "favicon": nil, "addedAt": 10] }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": "bar@default", "other": "other@default"]]]
  }

  private func coordinator(_ urls: [String], ready: Bool = true) -> BookmarkCoordinator {
    let owner = BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", makeID: { "new" }, now: { 99 })
    owner.seed(engine: "", document: document(urls), ready: ready)
    return owner
  }

  @Test func pendingRemovalHidesCommittedURL() throws {
    let owner = coordinator([page])
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    #expect(!owner.membership(profile: "p", url: page))
    #expect(owner.desiredView(engine: "").document["nodes"]?["b0"] == nil)
  }

  @Test func cachedURLIsMemberBeforeReady() {
    let owner = coordinator([page], ready: false)
    #expect(owner.membership(profile: "p", url: page))
    #expect(!owner.desiredView(engine: "").readyForSync)
    #expect(owner.desiredView(engine: "").hasView)
  }

  @Test func toggleRemovesAllExactDuplicates() throws {
    let owner = coordinator([page, page, "https://example.test/e\u{301}"])
    try owner.submit(profile: "p", mutations: [.init(method: "toggleBookmark", args: ["p", ["url": .string(page), "title": "Page", "favicon": nil]])])
    #expect(!owner.membership(profile: "p", url: page))
    #expect(owner.membership(profile: "p", url: "https://example.test/e\u{301}"))
    #expect(owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == ["b2"])
  }

  @Test func readCompletionKeepsNewerEdit() throws {
    let owner = coordinator([page])
    let oldRevision = owner.desiredView(engine: "").revision
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Newer"]])])
    owner.completeRead(engine: "", document: document([page]), capturedRevision: oldRevision)
    #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Newer")
  }

  @Test func sharedAliasesUseOneRevision() throws {
    let owner = coordinator([page])
    try owner.submit(profile: "alias", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    #expect(owner.desiredView(profile: "p").revision == owner.desiredView(profile: "alias").revision)
    #expect(!owner.membership(profile: "p", url: page))
  }

  @Test func privateWindowUsesOriginalEngine() {
    let owner = coordinator([page])
    #expect(owner.membership(profile: "private", originalProfile: "p", url: page))
    #expect(owner.membership(profile: "missing", url: page))
  }

  @Test func structuralReplayMatchesJSBreak() throws {
    let before = BookmarkFlat(document: document([page]), engine: "")
    let ops: [JSONValue] = [["op": "move", "id": "b0", "parent": "missing", "index": 0], ["op": "remove", "id": "b0"]]
    let result = BookmarkReconcile.replay(before, operations: ops, engine: "")
    #expect(result.tree == before)
    #expect(result.structuralBreak == 0)
  }

  @Test func negativeIndexMatchesJS() throws {
    let owner = coordinator([page, "b", "c"])
    try owner.submit(profile: "p", mutations: [.init(method: "moveBookmark", args: ["b0", "bar@default", -1])])
    #expect(owner.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == ["b1", "b0", "b2"])
  }

  @Test func staleReplacementIsRejectedBeforeChange() throws {
    let owner = coordinator([page])
    let revision = owner.desiredView(engine: "").revision
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    let before = owner.desiredView(engine: "")
    #expect(throws: BookmarkCoordinatorError.staleRevision) { try owner.replaceDocument(engine: "", document: document([page]), expectedRevision: revision) }
    #expect(owner.desiredView(engine: "") == before)
  }

  @Test func expectChildrenRefusesTheWholeSubmissionWhenTheFolderChanged() throws {
    let owner = coordinator([page])
    let before = owner.desiredView(engine: "")
    let tree: JSONValue = [["title": "Imported", "url": "https://imported.test/"]]
    #expect(throws: BookmarkCoordinatorError.conditionFailed("bar@default")) {
      try owner.submit(profile: "p", mutations: [.init(method: "expectChildren", args: ["p", "bar@default", []]), .init(method: "addBookmarkTree", args: ["p", tree, "bar@default"])], requestID: "import-1")
    }
    #expect(owner.desiredView(engine: "") == before)
    let receipt = try owner.submit(profile: "p", mutations: [.init(method: "addBookmarkTree", args: ["p", [["title": "Imported from Test", "children": tree]], "bar@default"])], requestID: "import-1")
    #expect(receipt.view.document["nodes"]?["bar@default"]?["children"]?.array?.count == 2)
  }

  @Test func expectChildrenPassesWhenTheFolderIsAsSeen() throws {
    let owner = coordinator([])
    let tree: JSONValue = [["title": "Imported", "url": "https://imported.test/"]]
    let receipt = try owner.submit(profile: "p", mutations: [.init(method: "expectChildren", args: ["p", "bar@default", []]), .init(method: "addBookmarkTree", args: ["p", tree, "bar@default"])])
    #expect(receipt.results.first == true)
    #expect(receipt.view.document["nodes"]?["bar@default"]?["children"] == ["new"])
    #expect(throws: BookmarkCoordinatorError.conditionFailed("missing")) {
      try owner.submit(profile: "p", mutations: [.init(method: "expectChildren", args: ["p", "missing", []])])
    }
  }

  @Test func conditionFailedDescribesItselfAsTheJSWriterMatchesIt() {
    #expect(String(describing: BookmarkCoordinatorError.conditionFailed("bar@default")) == #"conditionFailed("bar@default")"#)
  }

  @Test func exactIdentityIncludesTitlesAndIDs() throws {
    let owner = coordinator([page])
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "é"]])])
    let first = owner.desiredView(engine: "").revision
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "e\u{301}"]])])
    #expect(owner.desiredView(engine: "").revision == first + 1)
    #expect(!owner.membership(profile: "p", url: ""))
  }
}

extension BookmarkCoordinatorTests {
  private func oracle() throws -> JSONValue {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bookmark-desired.json")
    return try JSONValue.parse(Data(contentsOf: path))
  }

  private func sameJSON(_ actual: JSONValue, _ expected: JSONValue) -> Bool { JSKey(actual.canonical) == JSKey(expected.canonical) }

  @Test func pureDiffAndReplayMatchEveryOracleRecord() throws {
    for record in try oracle()["pure"]?.array ?? [] {
      if record["name"] == "unpaired-surrogate-exact-update" { continue }
      let engine = record["engine"]?.string ?? ""
      let before = BookmarkFlat(records: record["before"]?.array ?? [])
      let after = BookmarkFlat(records: record["after"]?.array ?? [])
      let ops = BookmarkReconcile.operations(from: before, to: after, engine: engine)
      #expect(sameJSON(.array(ops), record["ops"] ?? []), "\(record["name"]?.string ?? "")")
      let fetched = BookmarkFlat(records: record["fetched"]?.array ?? [])
      let result = BookmarkReconcile.replay(fetched, operations: ops, engine: engine)
      #expect(sameJSON(.array(result.tree.records), record["replayed"] ?? []), "\(record["name"]?.string ?? "")")
    }
    for record in try oracle()["replay"]?.array ?? [] {
      let result = BookmarkReconcile.replay(BookmarkFlat(records: record["before"]?.array ?? []), operations: record["ops"]?.array ?? [], engine: record["engine"]?.string ?? "")
      #expect(sameJSON(.array(result.tree.records), record["replayed"] ?? []), "\(record["name"]?.string ?? "")")
    }
  }

  @Test func reducerMatchesEveryOracleRecord() throws {
    for record in try oracle()["reducer"]?.array ?? [] {
      var allocated = record["allocatedIds"]?.array?.compactMap(\.string) ?? []
      let owner = BookmarkCoordinator(profiles: ["default": ""], defaultProfile: "default", makeID: { allocated.removeFirst() }, now: { record["now"]?.number ?? 0 })
      owner.seed(engine: "", document: record["before"] ?? [:], ready: true)
      let commands = (record["commands"]?.array ?? []).map { BookmarkMutation(method: $0["method"]?.string ?? "", args: $0["args"]?.array ?? []) }
      var results: [JSONValue] = []
      let steps = record["steps"]?.array ?? []
      try #require(steps.count == commands.count)
      for (index, command) in commands.enumerated() {
        let receipt = try owner.submit(profile: "default", mutations: [command])
        results.append(contentsOf: receipt.results)
        #expect(sameJSON(receipt.view.document, steps[index]["after"] ?? [:]), "\(record["name"]?.string ?? "") step \(index)")
        #expect(sameJSON(receipt.results.first ?? .null, steps[index]["result"] ?? .null), "\(record["name"]?.string ?? "") step \(index)")
      }
      #expect(sameJSON(owner.desiredView(engine: "").document, record["after"] ?? [:]), "\(record["name"]?.string ?? "")")
      #expect(sameJSON(.array(results), record["results"] ?? []), "\(record["name"]?.string ?? "")")
      #expect(allocated.isEmpty)
    }
  }

  @Test func exactMembershipMatchesAllRepresentableOracleStrings() throws {
    let fixture = try oracle()
    let owner = BookmarkCoordinator(profiles: ["default": ""], defaultProfile: "default")
    owner.seed(engine: "", document: fixture["membershipDocument"] ?? [:], ready: false)
    for record in fixture["membership"]?.array ?? [] {
      let url = record["url"]?.string ?? ""
      if url.contains("\u{FFFD}") { continue }
      #expect(owner.membership(profile: "default", url: url) == record["member"]?.bool)
      #expect(JSONValue(owner.membershipSnapshot.nodeIDsByURL[url] ?? []) == record["ids"])
    }
  }

  @Test func sharedAliasesPrivateFallbackAndRemapStayOnOwningEngine() throws {
    let owner = coordinator([page])
    owner.seed(engine: "q-engine", document: ["nodes": [:], "roots": [:]], ready: true)
    let original = owner.desiredView(profile: "p").revision
    owner.remap(profiles: ["p": "", "alias": "q-engine"], defaultProfile: "p")
    #expect(!owner.membership(profile: "alias", url: page))
    #expect(owner.membership(profile: "private", originalProfile: "p", url: page))
    #expect(owner.membership(profile: "missing", url: page))
    #expect(owner.desiredView(profile: "p").revision == original)
  }

  @Test func membershipObserversReceiveDesiredRevisionAndReadiness() async throws {
    let owner = coordinator([page], ready: false)
    var first = owner.membershipSnapshots(engine: "").makeAsyncIterator()
    var second = owner.membershipSnapshots(engine: "").makeAsyncIterator()
    let initial = await first.next()
    #expect(initial?.contains(page) == true)
    #expect(initial?.readyForSync == false)
    #expect(await second.next() == initial)
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Renamed"]])])
    let updated = await first.next()
    #expect(updated?.revision == (initial?.revision ?? 0) + 1)
    #expect(updated?.urls == initial?.urls)
    #expect(await second.next() == updated)
  }

  @Test func stampAckAndSupersedeUseExactOpaqueStrings() throws {
    var serial = 0
    var mintedProfiles: [String] = []
    let owner = BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { profile in mintedProfiles.append(profile); serial += 1; return BookmarkEditStamp(hlc: "00\(serial)-é", origin: "opaque origin") }), stampsEnabled: true)
    owner.seed(engine: "", document: document([page]), ready: true)
    try owner.submit(profile: "alias", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Local"]])])
    let first = try #require(owner.pendingEditStamp(profileId: "p", nodeId: "b0"))
    #expect(mintedProfiles == ["p"])
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "001-e\u{301}")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == first)
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: first.hlc)
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == first)
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "000-z")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == first)
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    let removed = try #require(owner.pendingEditStamp(profileId: "p", nodeId: "b0"))
    #expect(removed != first)
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: first.hlc)
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == removed)
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "999")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
  }

  @Test func replayObservesBeforeReadinessAndSyncNeverMints() throws {
    var observations: [String] = []
    var mints = 0
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { _ in mints += 1; return .init(hlc: "new", origin: "local") }, observeEditStamp: { profile, hlc in observations.append("\(profile):\(hlc)") }), stampsEnabled: true)
    owner.seed(engine: "", document: document([page]), ready: false)
    owner.replayPendingStamps(profileId: "p", stamps: ["deleted": .init(hlc: "old", origin: "verbatim")])
    owner.replayPendingStamps(profileId: "p", stamps: ["other": .init(hlc: "second", origin: "verbatim")])
    #expect(observations == ["p:old", "p:second"])
    #expect(!owner.desiredView(engine: "").readyForSync)
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Remote"]])], fromSync: true)
    #expect(mints == 0)
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "deleted") == .init(hlc: "old", origin: "verbatim"))
    owner.ackPendingEditStamp(profileId: "p", nodeId: "deleted", hlc: "old")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "deleted") == nil)
  }

  @Test func inactiveStampContractIsEntirelyNoOp() throws {
    var calls = 0
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { _ in calls += 1; return .init(hlc: "x", origin: "x") }, observeEditStamp: { _, _ in calls += 1 }))
    owner.seed(engine: "", document: document([page]), ready: true)
    try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
    owner.replayPendingStamps(profileId: "p", stamps: ["b0": .init(hlc: "x", origin: "x")])
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "x")
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "z")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(calls == 0)
  }
}

extension BookmarkCoordinatorTests {
  @Test func reorderStampsMovedNodeAndNeverSyntheticRoots() throws {
    var mintedProfiles: [String] = []
    let owner = BookmarkCoordinator(profiles: ["alias": "engine-owner", "engine-owner": "engine-owner"], defaultProfile: "alias", stampProviders: .init(mintEditStamp: { profile in mintedProfiles.append(profile); return .init(hlc: "001", origin: "x") }), stampsEnabled: true)
    let renamed = document(["a", "b"]).text().replacingOccurrences(of: "bar@default", with: "bar@engine-owner").replacingOccurrences(of: "other@default", with: "other@engine-owner")
    owner.seed(engine: "engine-owner", document: try JSONValue.parse(renamed), ready: true)
    try owner.submit(profile: "alias", mutations: [.init(method: "moveBookmark", args: ["b1", "bar@engine-owner", 0])])
    #expect(mintedProfiles == ["engine-owner"])
    #expect(owner.pendingEditStamp(profileId: "alias", nodeId: "b1") != nil)
    #expect(owner.pendingEditStamp(profileId: "alias", nodeId: "bar@engine-owner") == nil)
  }

  @Test func exactNodeIDsRemainDistinctInFlatChildren() {
    let nodes: [JSONValue] = [["id": "bar@default", "kind": "folder", "parent": nil, "title": "Bar", "addedAt": 0, "children": ["é", "e\u{301}"]], ["id": "é", "kind": "url", "parent": "bar@default", "title": "A", "url": "x:a", "addedAt": 0], ["id": "e\u{301}", "kind": "url", "parent": "bar@default", "title": "B", "url": "x:b", "addedAt": 0]]
    let first = BookmarkFlat(records: nodes)
    var second = first
    second.children["bar@default"] = ["e\u{301}", "é"]
    #expect(first != second)
    #expect(BookmarkReconcile.operations(from: first, to: second, engine: "").first?["id"] == "e\u{301}")
  }

  @Test(.disabled("SolaraModel JSONValue stores Swift String and replaces unpaired UTF-16 surrogates; the oracle record remains an activation gate"))
  func unpairedSurrogateOracleCannotYetMatch() throws {
    let record = try #require(oracle()["pure"]?.array?.first { $0["name"] == "unpaired-surrogate-exact-update" })
    let ops = BookmarkReconcile.operations(from: BookmarkFlat(records: record["before"]?.array ?? []), to: BookmarkFlat(records: record["after"]?.array ?? []), engine: "")
    #expect(sameJSON(.array(ops), record["ops"] ?? []))
  }
}

extension BookmarkCoordinatorTests {
  @Test func firstReadAdoptsCommittedTreeWithoutDeletingIt() {
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p")
    owner.completeRead(engine: "", document: document([page]), capturedRevision: 0)
    #expect(owner.membership(profile: "p", url: page))
    #expect(owner.desiredView(engine: "").readyForSync)
    #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["addedAt"] == 10)
  }
}

extension BookmarkCoordinatorTests {
  @Test func defaultCreationClockMatchesIntegerDateNow() throws {
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", makeID: { "new" })
    let receipt = try owner.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "title": "Now", "url": "x:a"]])])
    let addedAt = try #require(receipt.view.document["nodes"]?["new"]?["addedAt"]?.number)
    #expect(addedAt == addedAt.rounded(.down))
  }

  @Test func crossEngineCommandIsRejectedBeforeAnyChange() throws {
    let owner = BookmarkCoordinator(profiles: ["p": "", "q": "q"], defaultProfile: "p")
    owner.seed(engine: "", document: document([page]), ready: true)
    let before = owner.desiredView(engine: "")
    #expect(throws: BookmarkCoordinatorError.invalidProfileScope) {
      try owner.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "q", "title": "Wrong engine", "url": "x:a"]])])
    }
    #expect(owner.desiredView(engine: "") == before)
  }

  @Test func privateProfileSyntaxUsesNonDefaultOriginalEngine() {
    let owner = BookmarkCoordinator(profiles: ["p": "", "alias": "q", "q": "q"], defaultProfile: "p")
    #expect(owner.engine(profile: "incognito:window@alias") == "q")
    #expect(owner.engine(profile: "incognito:window@q") == "q")
    #expect(owner.engine(profile: "missing") == "")
  }
}

extension BookmarkCoordinatorTests {
  @Test func concurrentObserversNeverRegressRevisions() async throws {
    let owner = coordinator([page])
    var observer = owner.membershipSnapshots(engine: "").makeAsyncIterator()
    let initial = try #require(await observer.next())
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": .string("Change \(index)")]])])
        }
      }
      try await group.waitForAll()
    }
    let final = try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Final"]])])
    var last = initial.revision
    while last < final.view.revision {
      let next = try #require(await observer.next())
      #expect(next.revision > last)
      last = next.revision
    }
    #expect(last == owner.membershipSnapshot.revision)
  }

  @Test func orderedMutationBatchPublishesOneAtomicRevision() async throws {
    let owner = coordinator([page])
    var observer = owner.membershipSnapshots(engine: "").makeAsyncIterator()
    let initial = try #require(await observer.next())
    let result = try owner.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"]), .init(method: "addBookmark", args: [["profileId": "p", "title": "Replacement", "url": "x:replacement"]])])
    #expect(result.view.revision == initial.revision + 1)
    let published = try #require(await observer.next())
    #expect(published.revision == result.view.revision)
    #expect(!published.contains(page))
    #expect(published.contains("x:replacement"))
    #expect(result.results == [.null, "new"])
  }
}

extension BookmarkCoordinatorTests {
  @Test func replayNeverReplacesANewerLocalStamp() throws {
    var observations: [String] = []
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { _ in .init(hlc: "H2", origin: "local") }, observeEditStamp: { _, hlc in observations.append(hlc) }), stampsEnabled: true)
    owner.seed(engine: "", document: document([page, page]), ready: false)
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Local"]])])
    owner.replayPendingStamps(profileId: "p", stamps: ["b0": .init(hlc: "H1", origin: "replayed"), "b1": .init(hlc: "H1", origin: "replayed")])
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == .init(hlc: "H2", origin: "local"))
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b1") == .init(hlc: "H1", origin: "replayed"))
    owner.replayPendingStamps(profileId: "p", stamps: ["b1": .init(hlc: "H3", origin: "newer")])
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b1") == .init(hlc: "H3", origin: "newer"))
    #expect(observations == ["H1", "H1", "H3"])
  }

  @Test func replayAfterReadinessIsRefusedAndLogged() throws {
    var observations: [String] = []
    var logged: [String] = []
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(observeEditStamp: { _, hlc in observations.append(hlc) }), stampsEnabled: true, log: { logged.append($0) })
    owner.seed(engine: "", document: document([page]), ready: true)
    owner.replayPendingStamps(profileId: "p", stamps: ["b0": .init(hlc: "H1", origin: "late")])
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(observations.isEmpty)
    #expect(logged.count == 1)
  }

  @Test func failedMintLeavesAnUnconfirmedEditNoOldAckCanClear() throws {
    var next: BookmarkEditStamp? = .init(hlc: "H1", origin: "local")
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { _ in next }), stampsEnabled: true)
    owner.seed(engine: "", document: document([page]), ready: true)
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "One"]])])
    #expect(!owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    next = nil
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Two"]])])
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "H1")
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "H9")
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    next = .init(hlc: "H3", origin: "local")
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Three"]])])
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    owner.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "H4")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    next = .init(hlc: "H5", origin: "local")
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Four"]])])
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "H3")
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == .init(hlc: "H5", origin: "local"))
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "H5")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(!owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
  }
}

extension BookmarkCoordinatorTests {
  @Test func restampOnLinkMintsEachUnconfirmedNodeSoItsAckClearsIt() throws {
    var linked = false
    var serial = 0
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampProviders: .init(mintEditStamp: { _ in
      guard linked else { return nil }
      serial += 1
      return .init(hlc: "H\(serial)", origin: "local")
    }), stampsEnabled: true)
    owner.seed(engine: "", document: document([page, page, page]), ready: true)
    try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "A"]]), .init(method: "removeBookmark", args: ["b2"])])
    #expect(owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0") && owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b2"))
    owner.restampUnconfirmed(profileId: "p")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    linked = true
    owner.restampUnconfirmed(profileId: "p")
    let b0 = try #require(owner.pendingEditStamp(profileId: "p", nodeId: "b0"))
    let b2 = try #require(owner.pendingEditStamp(profileId: "p", nodeId: "b2"))
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b1") == nil)
    #expect(Set([b0.hlc, b2.hlc]) == ["H1", "H2"])
    owner.restampUnconfirmed(profileId: "p")
    #expect(owner.pendingEditStamp(profileId: "p", nodeId: "b0") == b0)
    #expect(serial == 2)
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: b0.hlc)
    owner.ackPendingEditStamp(profileId: "p", nodeId: "b2", hlc: b2.hlc)
    #expect(!owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b0") && !owner.hasUnconfirmedEdit(profileId: "p", nodeId: "b2"))
  }
}

extension BookmarkCoordinatorTests {
  @Test func legacyJSOnlyPartialDeleteResurrectsTheSuffixWhichTheNativePumpKeepsDeleted() throws {
    let record = try #require(try oracle()["pure"]?.array?.first { $0["name"] == "partial-delete-valid-suffix-resurrected" })
    let engine = record["engine"]?.string ?? ""
    let ops = BookmarkReconcile.operations(from: BookmarkFlat(records: record["before"]?.array ?? []), to: BookmarkFlat(records: record["after"]?.array ?? []), engine: engine)
    let legacy = BookmarkReconcile.replay(BookmarkFlat(records: record["fetched"]?.array ?? []), operations: ops, engine: engine)
    #expect(legacy.structuralBreak != nil)
    #expect(legacy.tree.records.filter { $0["kind"] == "url" }.count == 1)
  }
}
