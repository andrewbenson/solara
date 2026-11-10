import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkCanonicalURLTests {
  private let raw = "https://DELTA.example.net:443"
  private let canonical = "https://delta.example.net/"

  private func normalize(_ value: String) throws -> String {
    switch value {
    case "https://DELTA.example.net:443", "https://delta.example.net": "https://delta.example.net/"
    case "https://NEXT.example.net:443": "https://next.example.net/"
    case "invalid draft": throw BookmarkCoordinatorError.invalidOperation("Invalid bookmark URL")
    default: value
    }
  }

  private func document(_ urls: [String]) -> JSONValue { BookmarkCoordinatorTests().document(urls) }

  private func owner(_ directory: URL? = nil) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", makeID: { "new" }, now: { 100 }, stampsEnabled: true, pendingStore: directory.map { BookmarkPendingStore(directory: $0) }, canonicalURL: normalize)
  }

  private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-bookmark-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }

  @Test func successfulPushUsesChromeSpellingWithoutWatcher() throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document([]), ready: true)
    let accepted = try coordinator.submit(profile: "p", mutations: [.init(method: "addBookmark", args: [["profileId": "p", "url": .string(raw), "title": "Draft"]])])
    #expect(accepted.view.document["nodes"]?["new"]?["url"] == .string(canonical))
    #expect(accepted.view.wireDocument["nodes"]?["new"]?["url"] == .string(canonical))
    let epoch = coordinator.claimPump()
    #expect(coordinator.beginPush(engine: "", captured: accepted.view, epoch: epoch))
    #expect(coordinator.completePush(engine: "", captured: accepted.view, epoch: epoch, succeeded: true, nowMs: 100))
    let confirmed = coordinator.desiredView(engine: "")
    #expect(confirmed.document["nodes"]?["new"]?["url"] == .string(canonical))
    #expect(confirmed.facts == accepted.view.facts)
    #expect(coordinator.pumpInput(engine: "", epoch: epoch)?.1.isEmpty == true)
  }

  @Test func canonicalAcceptanceKeepsInterveningTitleAndURL() throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document([canonical]), ready: true)
    let accepted = try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["url": .string(raw), "title": "First"]])])
    let epoch = coordinator.claimPump()
    #expect(coordinator.beginPush(engine: "", captured: accepted.view, epoch: epoch))
    let latest = try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["url": "https://NEXT.example.net:443", "title": "Later"]])])
    #expect(coordinator.completePush(engine: "", captured: accepted.view, epoch: epoch, succeeded: true, nowMs: 100))
    let confirmed = coordinator.desiredView(engine: "")
    #expect(confirmed.document["nodes"]?["b0"]?["title"] == "Later")
    #expect(confirmed.document["nodes"]?["b0"]?["url"] == "https://next.example.net/")
    #expect(confirmed.facts == latest.view.facts)
    #expect(coordinator.pumpInput(engine: "", epoch: epoch)?.1.first?["u"] == "https://next.example.net/")
  }

  @Test func canonicalMembershipAndDedupeAgree() throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document([raw, canonical, "https://other.example/"]), ready: true)
    #expect(coordinator.membership(profile: "alias", url: raw))
    #expect(coordinator.membership(profile: "p", url: "https://delta.example.net"))
    #expect(coordinator.membershipSnapshot(engine: "").nodeIDsByURL[canonical] == ["b0", "b1"])
    let receipt = try coordinator.submit(profile: "p", mutations: [.init(method: "toggleBookmark", args: ["p", ["url": .string(raw), "title": "Page"]])])
    #expect(receipt.results == [false])
    #expect(receipt.view.document["nodes"]?["bar@default"]?["children"] == ["b2"])
    #expect(!coordinator.membership(profile: "p", url: canonical))
  }

  @Test func wireProvenanceSurvivesRestartWithoutRepublish() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let coordinator = owner(path)
    coordinator.seed(engine: "", document: document([]), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    let replacement = try coordinator.replaceDocument(engine: "", profile: "p", document: document([raw]), expectedRevision: coordinator.desiredView(engine: "").revision, records: [("bm:b0", "remote:200")], expectedLink: "chain")
    #expect(replacement.view.document["nodes"]?["b0"]?["url"] == .string(canonical))
    #expect(replacement.view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(replacement.view.facts.isEmpty)
    let restored = owner(path)
    #expect(restored.desiredView(engine: "").wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(restored.completeRead(engine: "", document: document([canonical]), capturedRevision: 0))
    #expect(restored.desiredView(engine: "").facts.isEmpty)
    let renamed = try restored.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Local title", "url": .string(canonical)]])])
    #expect(renamed.view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(renamed.view.facts["bm:b0"]?.at == 100)
    #expect(renamed.view.facts["bm:b0"]?.after == "remote:200")
    let movedURL = try restored.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["url": "https://NEXT.example.net:443"]])])
    #expect(movedURL.view.wireDocument["nodes"]?["b0"]?["url"] == "https://next.example.net/")
  }

  @Test func existingJournalNormalizesWithoutChangingFactsOrPendingTarget() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let old = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 90 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: path))
    old.seed(engine: "", document: document([raw]), ready: true)
    let accepted = try old.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending"]])])
    let epoch = old.claimPump()
    #expect(old.beginPush(engine: "", captured: accepted.view, epoch: epoch))
    let restored = owner(path)
    let view = restored.desiredView(engine: "")
    #expect(view.document["nodes"]?["b0"]?["url"] == .string(canonical))
    #expect(view.inFlightTarget?["nodes"]?["b0"]?["url"] == .string(canonical))
    #expect(view.facts == accepted.view.facts)
    #expect(view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(restored.completeRead(engine: "", document: document([canonical]), capturedRevision: 0))
    #expect(restored.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Pending")
    #expect(restored.desiredView(engine: "").facts == accepted.view.facts)
  }

  @Test func invalidInputRefusesTheWholeBatchBeforePersistence() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let coordinator = owner(path)
    coordinator.seed(engine: "", document: document([canonical]), ready: true)
    try coordinator.submit(profile: "p", mutations: [])
    let before = coordinator.desiredView(engine: "")
    let bytes = try Data(contentsOf: path.appendingPathComponent(BookmarkPendingStore.journalName))
    do {
      try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Must not save"]]), .init(method: "addBookmark", args: [["profileId": "p", "url": "invalid draft", "title": "Draft"]])])
      Issue.record("invalid input was accepted")
    } catch {}
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(try Data(contentsOf: path.appendingPathComponent(BookmarkPendingStore.journalName)) == bytes)
  }

  @Test func invalidRecoveredURLPreservesJournalAndHoldsEdits() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let old = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: path))
    old.seed(engine: "", document: document(["invalid draft"]), ready: true)
    try old.submit(profile: "p", mutations: [])
    let file = path.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: file)
    let restored = owner(path)
    #expect(restored.recoveryNotice != nil)
    #expect(!restored.desiredView(engine: "").readyForSync)
    #expect(restored.desiredView(engine: "").document["nodes"]?["b0"]?["url"] == "invalid draft")
    #expect(!restored.completeRead(engine: "", document: document([]), capturedRevision: 0))
    do {
      try restored.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])
      Issue.record("recovered invalid input allowed a write")
    } catch {}
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func equivalentURLChangeKeepsRemoteSpellingAndCreatesNoFact() throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document([raw]), ready: true)
    let before = coordinator.desiredView(engine: "")
    let receipt = try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["url": "https://delta.example.net"]])])
    #expect(receipt.view.revision == before.revision)
    #expect(receipt.view.facts.isEmpty)
    #expect(receipt.view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
  }

  @Test func legacyLaunchDocumentUsesCanonicalViewAndOriginalWire() {
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true,
      launchInput: BookmarkLaunchInput(documents: ["": document([raw])], legacyPendingEngines: [JSKey("")]), canonicalURL: normalize)
    let view = coordinator.desiredView(engine: "")
    #expect(view.document["nodes"]?["b0"]?["url"] == .string(canonical))
    #expect(view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(view.facts.isEmpty)
    #expect(!view.readyForSync)
  }

  @Test func wireURLKeepsLoneSurrogatesAcrossCanonicalizationAndRestart() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let wire = try JSONValue.parseBookmark(#""https://x.test/\ud800""#).string!
    func canonicalize(_ input: String) -> String { JSKey(input) == JSKey(wire) ? "https://x.test/%EF%BF%BD" : input }
    func open() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: path), canonicalURL: canonicalize)
    }
    let coordinator = open()
    coordinator.seed(engine: "", document: document([wire]), ready: true)
    let receipt = try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Renamed"]])])
    #expect(receipt.view.document["nodes"]?["b0"]?["url"] == "https://x.test/%EF%BF%BD")
    #expect(receipt.view.wireDocument["nodes"]?["b0"]?["url"]?.bookmarkText() == #""https://x.test/\ud800""#)
    #expect(open().desiredView(engine: "").wireDocument["nodes"]?["b0"]?["url"]?.bookmarkText() == #""https://x.test/\ud800""#)
  }

  @Test func chromeURLChangeDropsOldWireProvenance() throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document([raw]), ready: true)
    #expect(coordinator.completeRead(engine: "", document: document(["https://next.example.net/"]), capturedRevision: 0))
    let view = coordinator.desiredView(engine: "")
    #expect(view.document["nodes"]?["b0"]?["url"] == "https://next.example.net/")
    #expect(view.wireDocument["nodes"]?["b0"]?["url"] == "https://next.example.net/")
    #expect(view.wireURLs.isEmpty)
    #expect(view.facts.isEmpty)
  }


  @Test(arguments: ["title", "delete", "url", "order"])
  func realChromeEditsEndConversionOnlyStatusDurably(_ change: String) throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let coordinator = owner(path)
    coordinator.seed(engine: "", document: document([raw, raw]), ready: true)
    try coordinator.submit(profile: "p", mutations: [])
    #expect(coordinator.desiredView(engine: "").wireBaselineKeys == ["bm:b0", "bm:b1"])
    var fetched = document([canonical, canonical]).object ?? [:]
    var nodes = fetched["nodes"]?.object ?? [:]
    var first = nodes["b0"]?.object ?? [:]
    switch change {
    case "title": first["title"] = "Extension rename"; nodes["b0"] = .object(first)
    case "url": first["url"] = "https://next.example.net/"; nodes["b0"] = .object(first)
    case "delete":
      nodes.removeValue(forKey: "b0")
      var bar = nodes["bar@default"]?.object ?? [:]
      bar["children"] = ["b1"]
      nodes["bar@default"] = .object(bar)
    default:
      var bar = nodes["bar@default"]?.object ?? [:]
      bar["children"] = ["b1", "b0"]
      nodes["bar@default"] = .object(bar)
    }
    fetched["nodes"] = .object(nodes)
    #expect(coordinator.completeRead(engine: "", document: .object(fetched), capturedRevision: 0))
    let changed = coordinator.desiredView(engine: "")
    #expect(!changed.wireBaselineKeys.contains("bm:b0"))
    if change == "title" { #expect(changed.wireDocument["nodes"]?["b0"]?["url"] == .string(raw)) }
    let restored = owner(path).desiredView(engine: "")
    #expect(!restored.wireBaselineKeys.contains("bm:b0"))
    #expect(restored.wireURLs == changed.wireURLs)
  }

  @Test func factAcknowledgementCannotHideAnInterveningChromeEdit() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let coordinator = owner(path)
    coordinator.seed(engine: "", document: document([raw]), ready: true)
    #expect(coordinator.setBookmarkSyncLinks(["p": "chain"]))
    let accepted = try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Local title"]])])
    let fact = try #require(accepted.view.facts["bm:b0"])
    #expect(accepted.view.wireBaselineKeys == ["bm:b0"])
    let epoch = coordinator.claimPump()
    #expect(coordinator.beginPush(engine: "", captured: accepted.view, epoch: epoch))
    #expect(coordinator.completePush(engine: "", captured: accepted.view, epoch: epoch, succeeded: true, nowMs: 100))
    var fetched = document([canonical]).object ?? [:]
    var nodes = fetched["nodes"]?.object ?? [:]
    var node = nodes["b0"]?.object ?? [:]
    node["title"] = "Extension title"
    nodes["b0"] = .object(node)
    fetched["nodes"] = .object(nodes)
    #expect(coordinator.completeRead(engine: "", document: .object(fetched), capturedRevision: accepted.view.revision))
    #expect(coordinator.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Extension title")
    #expect(coordinator.desiredView(engine: "").wireBaselineKeys.isEmpty)
    #expect(try coordinator.ackBookmarkFacts(profileId: "p", expectedEngine: "", records: [("bm:b0", fact.seq, "remote:101")], expectedLink: "chain"))
    #expect(coordinator.desiredView(engine: "").wireBaselineKeys.isEmpty)
    #expect(owner(path).desiredView(engine: "").wireBaselineKeys.isEmpty)
  }

  @Test(arguments: ["add", "remove"])
  func unrelatedSiblingChangesKeepConvertedBookmarksAtBaseline(_ change: String) throws {
    let coordinator = owner()
    coordinator.seed(engine: "", document: document(["https://other.example/", raw]), ready: true)
    var fetched = document(["https://other.example/", canonical]).object ?? [:]
    var nodes = fetched["nodes"]?.object ?? [:]
    var bar = nodes["bar@default"]?.object ?? [:]
    if change == "add" {
      nodes["new"] = ["id": "new", "kind": "url", "parentId": "bar@default", "title": "New sibling", "url": "https://new.example/", "addedAt": 1, "favicon": nil]
      bar["children"] = ["new", "b0", "b1"]
    } else {
      nodes.removeValue(forKey: "b0")
      bar["children"] = ["b1"]
    }
    nodes["bar@default"] = .object(bar)
    fetched["nodes"] = .object(nodes)
    #expect(coordinator.completeRead(engine: "", document: .object(fetched), capturedRevision: 0))
    #expect(coordinator.desiredView(engine: "").wireBaselineKeys == ["bm:b1"])
    #expect(coordinator.desiredView(engine: "").wireDocument["nodes"]?["b1"]?["url"] == .string(raw))
  }

  @Test(arguments: ["checkpoint", "revision", "link"])
  func refusedReplacementNeverInstallsWireProvenanceOrObservations(_ refusal: String) throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let initial = owner(path)
    initial.seed(engine: "", document: document([raw]), ready: true)
    #expect(initial.setBookmarkSyncLinks(["p": "chain"]))
    var operations = BookmarkPendingFileOperations.live
    if refusal == "checkpoint" { operations.syncFile = { _ in throw BookmarkCoordinatorError.invalidOperation("injected") } }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: path, fileOperations: operations), canonicalURL: normalize)
    let before = coordinator.desiredView(engine: "")
    let file = path.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: file)
    do {
      try coordinator.replaceDocument(engine: "", profile: "p", document: document(["https://delta.example.net"]), expectedRevision: before.revision + (refusal == "revision" ? 1 : 0), records: [("bm:b0", "remote:999")], expectedLink: refusal == "link" ? "other-chain" : "chain")
      Issue.record("refused remote replacement was accepted")
    } catch {}
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(owner(path).desiredView(engine: "").wireURLs == before.wireURLs)
  }


  @Test func canonicalizerRuleChangeCannotHideAnUnstampedChromeEdit() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    let coordinator = owner(path)
    coordinator.seed(engine: "", document: document([raw]), ready: true)
    var fetched = document([canonical]).object ?? [:]
    var nodes = fetched["nodes"]?.object ?? [:]
    var node = nodes["b0"]?.object ?? [:]
    node["title"] = "Unsynced extension title"
    nodes["b0"] = .object(node)
    fetched["nodes"] = .object(nodes)
    #expect(coordinator.completeRead(engine: "", document: .object(fetched), capturedRevision: 0))
    #expect(coordinator.desiredView(engine: "").wireBaselineKeys.isEmpty)
    let originalWire = raw
    let previousCanonical = canonical
    let newCanonical = "https://delta.example.net/new-rule"
    let restored = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true,
      pendingStore: BookmarkPendingStore(directory: path), canonicalURL: { input in
        input == originalWire || input == previousCanonical ? newCanonical : input
      })
    let view = restored.desiredView(engine: "")
    #expect(view.document["nodes"]?["b0"]?["url"] == .string(newCanonical))
    #expect(view.document["nodes"]?["b0"]?["title"] == "Unsynced extension title")
    #expect(view.wireDocument["nodes"]?["b0"]?["url"] == .string(raw))
    #expect(view.wireURLs["b0"]?.conversionOnly == false)
    #expect(view.wireBaselineKeys.isEmpty)
    #expect(view.facts.isEmpty)
  }


  @Test func canonicalLegacyImportKeepsWireBaselineAcrossConfirmationAndRestart() throws {
    let path = try directory()
    defer { try? FileManager.default.removeItem(at: path) }
    try Data(JSONValue.object(["bookmarks": document([raw])]).bookmarkText().utf8).write(to: path.appendingPathComponent("bookmarks.json"))
    func open() -> BookmarkCoordinator {
      BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: path), launchInput: BookmarkLaunchCache(directory: path).load(profiles: ["p": ""], defaultProfile: "p"), canonicalURL: normalize)
    }
    let coordinator = open()
    #expect(coordinator.completeRead(engine: "", document: document([]), capturedRevision: 0))
    let id = BookmarkLaunchCache.legacyUUID("b0")
    let accepted = coordinator.desiredView(engine: "")
    #expect(accepted.document["nodes"]?[id]?["url"] == .string(canonical))
    #expect(accepted.wireDocument["nodes"]?[id]?["url"] == .string(raw))
    #expect(accepted.wireBaselineKeys == ["bm:b0"])
    #expect(accepted.facts.isEmpty)
    let epoch = coordinator.claimPump()
    let pending = try #require(coordinator.pumpInput(engine: "", epoch: epoch)?.1)
    #expect(coordinator.chromeOperations(pending, engine: "", document: accepted.document).first?["ifAbsent"] == true)
    #expect(coordinator.beginPush(engine: "", captured: accepted, epoch: epoch))
    #expect(coordinator.completePush(engine: "", captured: accepted, epoch: epoch, succeeded: true, nowMs: 100))
    let reopened = open()
    #expect(reopened.completeRead(engine: "", document: accepted.document, capturedRevision: 0))
    let confirmed = reopened.desiredView(engine: "")
    #expect(confirmed.readyForSync)
    #expect(confirmed.wireDocument["nodes"]?[id]?["url"] == .string(raw))
    #expect(confirmed.wireBaselineKeys == ["bm:b0"])
    #expect(confirmed.facts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("bookmarks.json").path))
    #expect(open().desiredView(engine: "").wireDocument["nodes"]?[id]?["url"] == .string(raw))
  }

}
