import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkLegacyMigrationTests {
  private let id = "8d05c91f-ba6c-45d6-bc0c-623a10af00da"

  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bookmark-migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func source(title: String = "Legacy", profile: String = "p") -> JSONValue {
    ["bookmarks": ["roots": .object([profile: ["bar": "old-bar", "other": "old-other"]]), "nodes": [
      "old-bar": ["id": "old-bar", "kind": "folder", "parentId": nil, "title": "Bar", "addedAt": 0, "children": [.string(id)]],
      "old-other": ["id": "old-other", "kind": "folder", "parentId": nil, "title": "Other", "addedAt": 0, "children": []],
      id: ["id": .string(id), "kind": "url", "parentId": "old-bar", "title": .string(title), "url": "https://legacy.test/", "addedAt": 42, "syncKey": "original-key"]
    ]]]
  }

  private func writeSource(_ dir: URL, value: JSONValue? = nil) throws {
    try Data((value ?? source()).bookmarkText().utf8).write(to: dir.appendingPathComponent("bookmarks.json"))
  }

  private func owner(_ dir: URL, profiles: JSMap<String> = ["p": "", "alias": ""], readOnly: Bool = false) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: profiles, defaultProfile: "p", now: { 9999 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: dir, readOnly: readOnly), launchInput: BookmarkLaunchCache(directory: dir).load(profiles: profiles, defaultProfile: "p"))
  }

  private func empty(_ engine: String = "") -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    return BookmarkFlat(records: [
      ["id": .string(roots.bar), "kind": "folder", "parent": nil, "title": "Bookmarks Bar", "addedAt": 0, "children": []],
      ["id": .string(roots.other), "kind": "folder", "parent": nil, "title": "Other Bookmarks", "addedAt": 0, "children": []]
    ]).document(profiles: [])
  }

  private func read(_ c: BookmarkCoordinator, document: JSONValue? = nil, engine: String = "") {
    #expect(c.completeRead(engine: engine, document: document ?? empty(engine), capturedRevision: c.desiredView(engine: engine).revision))
  }

  private func push(_ c: BookmarkCoordinator, engine: String = "", succeeded: Bool = true) {
    let epoch = c.claimPump()
    let view = c.desiredView(engine: engine)
    #expect(c.beginPush(engine: engine, captured: view, epoch: epoch))
    #expect(c.completePush(engine: engine, captured: view, epoch: epoch, succeeded: succeeded, nowMs: 9999))
  }

  @Test func displaySeedCannotSatisfyLegacyImport() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    #expect(c.desiredView(engine: "").document["nodes"]?[id] != nil)
    read(c)
    #expect(c.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == "original-key")
    #expect(c.migrationNeedsPush(engine: ""))
    #expect(!c.desiredView(engine: "").readyForSync)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }

  @Test func legacyKeysAndSharedEnginesMigrateOnce() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var value = source()
    var nodes = try #require(value["bookmarks"]?["nodes"]?.object)
    var bar = try #require(nodes["old-bar"]?.object)
    bar["children"] = [.string(id), "old-id"]
    nodes["old-bar"] = .object(bar)
    nodes["old-id"] = ["id": "old-id", "kind": "url", "parentId": "old-bar", "title": "Old", "url": "https://old.test/", "addedAt": 7]
    value = ["bookmarks": ["nodes": .object(nodes), "roots": ["p": ["bar": "old-bar", "other": "old-other"], "alias": ["bar": "old-bar", "other": "old-other"]]]]
    try writeSource(dir, value: value)
    let c = owner(dir)
    read(c)
    let view = c.desiredView(engine: "")
    #expect(view.document["nodes"]?[id]?["addedAt"] == 42)
    #expect(view.document["nodes"]?[id]?["syncKey"] == "original-key")
    let oldID = BookmarkLaunchCache.legacyUUID("old-id")
    #expect(view.document["nodes"]?[oldID]?["syncKey"] == "old-id")
    #expect(view.document["nodes"]?["bar@default"]?["children"] == [.string(id), .string(oldID)])
    read(c)
    #expect(c.desiredView(engine: "").document["nodes"]?.object?.count == 4)
    #expect(c.bookmarkFacts(profileId: "p").isEmpty)
    #expect(c.desiredView(profile: "alias").document == c.desiredView(profile: "p").document)
  }

  @Test func migrationCompletionSurvivesRestartAndUnblocksSync() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    let accepted = c.desiredView(engine: "").document
    push(c)
    #expect(!c.desiredView(engine: "").readyForSync)
    read(c, document: accepted)
    #expect(c.desiredView(engine: "").readyForSync)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasPrefix("bookmarks-legacy-") })
    let reopened = owner(dir)
    read(reopened, document: accepted)
    #expect(reopened.desiredView(engine: "").readyForSync)
  }

  @Test func crashAfterAcceptBeforeCompletionDoesNotDuplicate() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == [.string(id)])
    #expect(reopened.migrationNeedsPush(engine: ""))
  }

  @Test func interveningDeleteIsNotReimported() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    try c.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: [.string(id)])])
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] == nil)
    #expect(reopened.bookmarkFacts(profileId: "p")["bm:original-key"] != nil)
    push(reopened)
    read(reopened)
    #expect(reopened.desiredView(engine: "").readyForSync)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] == nil)
  }

  @Test func invalidOrFailedMigrationKeepsSource() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    push(c, succeeded: false)
    read(c)
    #expect(!c.desiredView(engine: "").readyForSync)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    #expect(!c.recoveryConflicts.isEmpty)
  }

  @Test func malformedAndUnmappedLegacyHoldSourceVisibly() throws {
    for value in [source(profile: "missing"), ["bookmarks": ["roots": ["p": ["bar": "missing", "other": "missing"]], "nodes": [:]]]] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      try writeSource(dir, value: value)
      let c = owner(dir)
      read(c)
      #expect(!c.desiredView(engine: "").readyForSync)
      #expect(c.recoveryNotice != nil)
      #expect(!c.recoveryConflicts.isEmpty)
      #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    }
  }

  @Test func migrationNeverRestampsBaselineOverNewerRemote() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    #expect(c.bookmarkFacts(profileId: "p").isEmpty)
    let baseline = c.desiredView(engine: "").document
    push(c)
    read(c, document: baseline)
    let rev = c.desiredView(engine: "").revision
    try c.replaceDocument(engine: "", document: empty(), expectedRevision: rev)
    let reopened = owner(dir)
    read(reopened, document: baseline)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] == nil)
    #expect(reopened.bookmarkFacts(profileId: "p").isEmpty)
  }

  @Test func nativeJournalOutranksStaleCache() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    try c.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: [.string(id), ["title": "Journal"]])])
    let stale = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    try BookmarkLaunchCache(directory: dir).save(documents: stale.documents)
    let reopened = owner(dir)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id]?["title"] == "Journal")
    read(reopened)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id]?["title"] == "Journal")
  }

  @Test func safeModeDoesNotRenameOrWriteJournal() throws {
    for bytes in [Data("{".utf8), Data("{\"version\":999}".utf8)] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let journal = dir.appendingPathComponent(BookmarkPendingStore.journalName)
      try bytes.write(to: journal)
      try writeSource(dir)
      let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
      let c = owner(dir, readOnly: true)
      read(c)
      #expect(!c.desiredView(engine: "").readyForSync)
      #expect(c.bookmarkWritesPaused)
      #expect(throws: BookmarkPendingStoreError.unavailable) { try c.submit(profile: "p", mutations: []) }
      #expect(throws: BookmarkPendingStoreError.unavailable) { try c.retire(engine: "") }
      #expect(!c.setBookmarkSyncLinks(["p": "chain"]))
      #expect(try Data(contentsOf: journal) == bytes)
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
    }
  }

  @Test func savedUnconfirmedShowsAmbiguousRecovery() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var ops = BookmarkPendingFileOperations.live
    ops.syncDirectory = { _ in throw BookmarkPendingStoreError.io("directory sync", 5) }
    let c = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir, fileOperations: ops))
    #expect(!c.completeRead(engine: "", document: empty(), capturedRevision: 0))
    #expect(c.recoveryNotice?.message.contains("may have been saved") == true)
    #expect(c.bookmarkWritesPaused)
    #expect(!c.desiredView(engine: "").readyForSync)
  }

  @Test func secondEngineMustConfirmBeforeSourceRetirement() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let profiles: JSMap<String> = ["p": "", "q": "q"]
    let c = owner(dir, profiles: profiles)
    read(c)
    push(c)
    read(c, document: c.desiredView(engine: "").document)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    read(c, engine: "q")
    push(c, engine: "q")
    read(c, document: c.desiredView(engine: "q").document, engine: "q")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }

  @Test func deletionBeforeFirstReadIsNotImported() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    try c.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: [.string(id)])])
    read(c)
    #expect(c.desiredView(engine: "").document["nodes"]?[id] == nil)
  }

  @Test func retirementDiscardsMigrationIntentAcrossReactivation() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    try c.retire(engine: "")
    try c.reactivate(engine: "")
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] == nil)
    #expect(!reopened.migrationNeedsPush(engine: ""))
  }
}

extension BookmarkLegacyMigrationTests {
  @Test func partialBackupCanResumeWithoutAcceptingAnyImportEarly() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let bytes = try Data(contentsOf: dir.appendingPathComponent("bookmarks.json"))
    var operations = BookmarkPendingFileOperations.live
    operations.writeNew = { url, data in
      try Data(data.prefix(8)).write(to: url)
      throw BookmarkPendingStoreError.io("partial backup", 5)
    }
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    let failed = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir), launchInput: BookmarkLaunchInput(documents: launch.documents, legacyPendingEngines: launch.legacyPendingEngines, legacyMigration: BookmarkLegacyMigration(directory: dir, bytes: bytes, fileOperations: operations)))
    read(failed)
    #expect(!failed.migrationNeedsPush(engine: ""))
    #expect(!failed.recoveryConflicts.isEmpty)
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.migrationNeedsPush(engine: ""))
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] != nil)
  }

  @Test func changedSourceCannotInheritAnOldCompletion() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    let accepted = c.desiredView(engine: "").document
    push(c)
    read(c, document: accepted)
    try writeSource(dir, value: source(title: "Different source"))
    let reopened = owner(dir)
    read(reopened, document: accepted)
    #expect(!reopened.desiredView(engine: "").readyForSync)
    #expect(reopened.recoveryNotice != nil)
    #expect(!reopened.recoveryConflicts.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }

  @Test func ownerHandoffBeforeFirstReadKeepsMigrationGate() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir))
    #expect(old.remap(profiles: ["p": ""], defaultProfile: "p"))
    try writeSource(dir)
    let replacement = owner(dir)
    replacement.reloadJournalForOwnerReplacement(previous: old)
    read(replacement)
    #expect(replacement.migrationNeedsPush(engine: ""))
    #expect(!replacement.desiredView(engine: "").readyForSync)
    #expect(replacement.desiredView(engine: "").document["nodes"]?[id]?["syncKey"] == "original-key")
  }

  @Test func acceptedImportResumesFromBackupWhenSourceDisappears() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("bookmarks.json"))
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.migrationNeedsPush(engine: ""))
    let accepted = reopened.desiredView(engine: "").document
    push(reopened)
    read(reopened, document: accepted)
    #expect(reopened.desiredView(engine: "").readyForSync)
  }

  @Test func crashAfterPushStillRequiresAConfirmingRead() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    let accepted = c.desiredView(engine: "").document
    push(c)
    let reopened = owner(dir)
    #expect(!reopened.desiredView(engine: "").readyForSync)
    #expect(reopened.migrationNeedsConfirmation(engine: ""))
    read(reopened, document: accepted)
    #expect(reopened.desiredView(engine: "").readyForSync)
  }

  @Test func safeModeSemanticCorruptionLeavesEnvelopeUntouched() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BookmarkPendingStore(directory: dir)
    try store.write(["kind": "bookmarkCoordinator", "wrongSchema": true])
    let bytes = try Data(contentsOf: store.journalURL)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let c = owner(dir, readOnly: true)
    read(c)
    #expect(c.bookmarkWritesPaused)
    #expect(c.recoveryNotice?.kind == .unreadableJournal)
    #expect(try Data(contentsOf: store.journalURL) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == names)
  }

  @Test func orphanedLegacyRecordsAreNeverSilentlyRetired() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var nodes = try #require(source()["bookmarks"]?["nodes"]?.object)
    nodes["orphan"] = ["id": "orphan", "kind": "url", "parentId": "missing", "title": "Orphan", "url": "https://orphan.test/", "addedAt": 3]
    try writeSource(dir, value: ["bookmarks": ["nodes": .object(nodes), "roots": source()["bookmarks"]?["roots"] ?? [:]]])
    let c = owner(dir)
    read(c)
    #expect(!c.migrationNeedsPush(engine: ""))
    #expect(!c.recoveryConflicts.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }

  @Test func bookmarkMigrationPreservesLoneUTF16Units() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let title = BookmarkString.encode(units: [0xD800, 0x61, 0xDC00])
    try writeSource(dir, value: source(title: title))
    let c = owner(dir)
    read(c)
    let actual = try #require(c.desiredView(engine: "").document["nodes"]?[id]?["title"]?.string)
    #expect(BookmarkString.units(actual) == [0xD800, 0x61, 0xDC00])
    let reopened = owner(dir)
    let recovered = try #require(reopened.desiredView(engine: "").document["nodes"]?[id]?["title"]?.string)
    #expect(BookmarkString.units(recovered) == [0xD800, 0x61, 0xDC00])
  }
}

extension BookmarkLegacyMigrationTests {
  @MainActor @Test func safeModePumpReadsButNeverAppliesPendingIntent() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let writable = owner(dir)
    read(writable)
    let journal = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    let c = owner(dir, readOnly: true)
    let tree = EngineBookmarkTree(bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: []), other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
    let calls = BookmarkMigrationCalls()
    let client = BookmarkEngineClient(readTree: { _ in
      await calls.read()
      return tree
    }, apply: { _, operations in
      await calls.apply()
      return BookmarkApplyResult(applied: operations.count, skipped: 0, invalid: [])
    })
    let pump = BookmarkPump(coordinator: c, client: client, clock: BookmarkPumpClock(wallTimeMs: { 1000 }, monotonicTimeMs: { 1000 }), scheduler: BookmarkPumpScheduler(schedule: { _, _ in {} }))
    defer { pump.stop() }
    pump.requestRead(engine: "")
    pump.requestPush(engine: "")
    await pump.settle(engine: "")
    #expect(await calls.reads == 1)
    #expect(await calls.applies == 0)
    #expect(!c.desiredView(engine: "").readyForSync)
    #expect(try Data(contentsOf: journal) == bytes)
  }

  @MainActor @Test(arguments: [false, true]) func skippedOrInvalidApplyNeverCompletesMigration(invalid: Bool) async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    let tree = EngineBookmarkTree(bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: []), other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
    let calls = BookmarkMigrationCalls()
    let client = BookmarkEngineClient(readTree: { _ in
      await calls.read()
      return tree
    }, apply: { _, _ in
      await calls.apply()
      return BookmarkApplyResult(applied: 0, skipped: invalid ? 0 : 1, invalid: invalid ? ["8d05c91f-ba6c-45d6-bc0c-623a10af00da"] : [])
    })
    let pump = BookmarkPump(coordinator: c, client: client, clock: BookmarkPumpClock(wallTimeMs: { 1000 }, monotonicTimeMs: { 1000 }), scheduler: BookmarkPumpScheduler(schedule: { _, _ in {} }))
    defer { pump.stop() }
    pump.requestRead(engine: "")
    await pump.settle(engine: "")
    #expect(await calls.applies > 0)
    #expect(!c.desiredView(engine: "").readyForSync)
    #expect(!c.recoveryConflicts.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }
}

private actor BookmarkMigrationCalls {
  var reads = 0
  var applies = 0
  @discardableResult func read() -> Int { reads += 1; return reads }
  func apply() { applies += 1 }
}

extension BookmarkLegacyMigrationTests {
  @Test func acceptedBaselineUsesIfAbsentAgainstInterveningChromeEdits() throws {
    for localEdit in [false, true] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      try writeSource(dir)
      let c = owner(dir)
      read(c)
      if localEdit { try c.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: [.string(id), ["title": "Local edit"]])]) }
      let view = c.desiredView(engine: "")
      let raw = BookmarkReconcile.operations(from: BookmarkFlat(document: empty(), engine: ""), to: BookmarkFlat(document: view.document, engine: ""), engine: "")
      let operations = c.chromeOperations(raw, engine: "", document: view.document)
      #expect(operations.first?["ifAbsent"] == (localEdit ? nil : true))
      var nodes = try #require(view.document["nodes"]?.object)
      var page = try #require(nodes[id]?.object)
      page["title"] = "Chrome edit"
      nodes[id] = .object(page)
      let chrome: JSONValue = ["nodes": .object(nodes), "roots": view.document["roots"] ?? [:]]
      let reopened = owner(dir)
      read(reopened, document: chrome)
      #expect(reopened.desiredView(engine: "").document["nodes"]?[id]?["title"] == (localEdit ? "Local edit" : "Chrome edit"))
    }
  }
}

extension BookmarkLegacyMigrationTests {
  @Test func normalUnreadableRecoveryHoldSurvivesRestart() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{".utf8).write(to: dir.appendingPathComponent(BookmarkPendingStore.journalName))
    let first = owner(dir)
    #expect(first.bookmarkWritesPaused)
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.bookmarkWritesPaused)
    #expect(!reopened.desiredView(engine: "").readyForSync)
    #expect(reopened.recoveryNotice?.kind == .unreadableJournal)
  }

  @Test(arguments: [false, true]) func migrationCheckpointFaultResumesIdempotently(afterRename: Bool) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    var operations = BookmarkPendingFileOperations.live
    if afterRename { operations.syncDirectory = { _ in throw BookmarkPendingStoreError.io("directory sync", 5) } }
    else { operations.rename = { _, _ in throw BookmarkPendingStoreError.io("journal rename", 5) } }
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    let c = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir, fileOperations: operations), launchInput: launch)
    #expect(!c.completeRead(engine: "", document: empty(), capturedRevision: 0))
    #expect(!c.migrationNeedsPush(engine: ""))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    let reopened = owner(dir)
    read(reopened)
    #expect(reopened.migrationNeedsPush(engine: ""))
    #expect(reopened.desiredView(engine: "").document["nodes"]?["bar@default"]?["children"] == [.string(id)])
  }

  @Test func sourceRetirementFailureIsVisibleAndRetriesAfterRestart() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let bytes = try Data(contentsOf: dir.appendingPathComponent("bookmarks.json"))
    let launch = BookmarkLaunchCache(directory: dir).load(profiles: ["p": ""], defaultProfile: "p")
    var operations = BookmarkPendingFileOperations.live
    operations.remove = { _ in throw BookmarkPendingStoreError.io("source removal", 5) }
    let c = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: dir), launchInput: BookmarkLaunchInput(documents: launch.documents, legacyPendingEngines: launch.legacyPendingEngines, legacyMigration: BookmarkLegacyMigration(directory: dir, bytes: bytes, fileOperations: operations)))
    read(c)
    let accepted = c.desiredView(engine: "").document
    push(c)
    read(c, document: accepted)
    #expect(c.desiredView(engine: "").readyForSync)
    #expect(c.recoveryNotice?.message.contains("could not be retired") == true)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    let reopened = owner(dir)
    read(reopened, document: accepted)
    #expect(reopened.desiredView(engine: "").readyForSync)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
  }
}

extension BookmarkLegacyMigrationTests {
  @Test func remapBeforeFirstMigrationReadDrainsTheOriginalEngine() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    #expect(c.remap(profiles: ["p": "b"], defaultProfile: "p"))
    #expect(c.catalogEngines.contains(""))
    read(c)
    #expect(c.migrationNeedsPush(engine: ""))
    #expect(c.desiredView(engine: "").document["nodes"]?[id] != nil)
    let reopened = owner(dir, profiles: ["p": "b"])
    #expect(reopened.catalogEngines.contains(""))
    read(reopened)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id] != nil)
    push(reopened)
    read(reopened, document: reopened.desiredView(engine: "").document)
    read(reopened, engine: "b")
    #expect(reopened.desiredView(engine: "b").document["nodes"]?[id] == nil)
  }
}

extension BookmarkLegacyMigrationTests {
  @MainActor @Test func aliaslessMigrationWithNoDisplaySeedReadsBeforeTerminalRule() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    try BookmarkLaunchCache(directory: dir).save(documents: ["retired": empty("retired")])
    let c = owner(dir)
    #expect(!c.desiredView(engine: "").hasView)
    #expect(c.remap(profiles: ["p": "b"], defaultProfile: "p"))
    let calls = BookmarkMigrationCalls()
    let emptyTree = EngineBookmarkTree(bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: []), other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
    let page = EngineBookmarkNode(id: id, kind: "u", title: "Legacy", url: "https://legacy.test/", addedAt: 42, syncKey: "original-key")
    let importedTree = EngineBookmarkTree(bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: [page]), other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
    let client = BookmarkEngineClient(readTree: { _ in
      let count = await calls.read()
      return count == 1 ? emptyTree : importedTree
    }, apply: { _, operations in
      await calls.apply()
      return BookmarkApplyResult(applied: operations.count, skipped: 0, invalid: [])
    })
    let pump = BookmarkPump(coordinator: c, client: client, clock: BookmarkPumpClock(wallTimeMs: { 1000 }, monotonicTimeMs: { 1000 }), scheduler: BookmarkPumpScheduler(schedule: { _, _ in {} }))
    defer { pump.stop() }
    pump.requestRead(engine: "")
    await pump.settle(engine: "")
    #expect(await calls.reads == 2)
    #expect(await calls.applies == 1)
    #expect(c.desiredView(engine: "").document["nodes"]?[id] != nil)
    #expect(!c.legacyImportPending(engine: ""))
    #expect(c.recoveryConflicts.isEmpty)
  }
}

extension BookmarkLegacyMigrationTests {
  @Test func confirmingReadMismatchCannotConfirmAnEmptySubstitute() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeSource(dir)
    let c = owner(dir)
    read(c)
    let intended = c.desiredView(engine: "").document
    push(c)
    read(c)
    let reopened = owner(dir)
    read(reopened)
    #expect(!reopened.desiredView(engine: "").readyForSync)
    #expect(reopened.bookmarkEditsPaused(engine: ""))
    #expect(!reopened.migrationNeedsPush(engine: ""))
    #expect(throws: BookmarkPendingStoreError.unavailable) { try reopened.submit(profile: "p", mutations: []) }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bookmarks.json").path))
    read(reopened, document: intended)
    #expect(reopened.desiredView(engine: "").readyForSync)
    #expect(!reopened.bookmarkEditsPaused(engine: ""))
  }
}

extension BookmarkLegacyMigrationTests {
  @Test func legacyURLSpellingAdoptsChromeWithoutNewFact() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var nodes = try #require(source()["bookmarks"]?["nodes"]?.object)
    var page = try #require(nodes[id]?.object)
    page["url"] = "https://legacy.test"
    nodes[id] = .object(page)
    try writeSource(dir, value: ["bookmarks": ["nodes": .object(nodes), "roots": source()["bookmarks"]?["roots"] ?? [:]]])
    let c = owner(dir)
    read(c)
    push(c)
    let target = c.desiredView(engine: "").document
    var confirmed = try #require(target["nodes"]?.object)
    var saved = try #require(confirmed[id]?.object)
    saved["url"] = "https://legacy.test/"
    confirmed[id] = .object(saved)
    read(c, document: ["nodes": .object(confirmed), "roots": target["roots"] ?? [:]])
    #expect(c.desiredView(engine: "").readyForSync)
    #expect(!c.bookmarkEditsPaused(engine: ""))
    #expect(c.desiredView(engine: "").document["nodes"]?[id]?["url"] == "https://legacy.test/")
    #expect(c.bookmarkFacts(profileId: "p").isEmpty)
    let reopened = owner(dir)
    #expect(reopened.desiredView(engine: "").document["nodes"]?[id]?["url"] == "https://legacy.test/")
  }
}
