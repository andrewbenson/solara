import Foundation
import Testing
import Synchronization
import SolaraModel
import SolaraStore
@testable import SolaraEngine

@Suite(.serialized) @MainActor struct BookmarkOwnerLifecycleTests {
  @Test func nativeOwnerClaimsCatalogBeforeFirstStart() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://page.test"]), ready: true)
    f.client.title = "Fresh"
    #expect(f.catalog.bookmarkClaim == nil)
    #expect(try f.owner.snapshot(profile: "default").ready)
    try await f.start()
    #expect(f.catalog.bookmarkClaim?.coordinator === f.owner.coordinator)
    await f.catalog.start(engineProfiles: [""])
    await f.settle()
    #expect(try f.owner.snapshot(profile: "default").ready)
    #expect(f.client.rawReads == 0)
    #expect(f.client.rawApplies == 0)
    #expect(f.client.reads == [""])
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "Fresh")
  }

  @Test(arguments: [false, true]) func readOnlyRecoveryStartsOwnerAndRefreshesCachedBookmarks(preservationFails: Bool) async throws {
    let bytes = Data((preservationFails ? "unreadable journal" : "{\"version\":999,\"future\":\"intent\"}").utf8)
    var operations: BookmarkPendingFileOperations?
    if preservationFails {
      var failing = BookmarkPendingFileOperations.live
      failing.rename = { _, _ in throw BookmarkPendingStoreError.unavailable }
      operations = failing
    }
    var cachedNodes = try #require(BookmarkCoordinatorTests().document(["https://cached.test"])["nodes"]?.object)
    var cachedPage = try #require(cachedNodes["b0"]?.object)
    cachedPage["title"] = "A"
    cachedNodes["b0"] = .object(cachedPage)
    let cache: JSONValue = ["version": 1, "trees": ["": .array(cachedNodes.values)]]
    let f = try await OwnerLifecycleFixture.make(journalBytes: bytes, cache: cache, fileOperations: operations)
    defer { f.stop() }
    let journal = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let expectedKind: BookmarkRecoveryNotice.Kind = preservationFails ? .unreadableJournal : .newerJournalVersion
    #expect(f.owner.coordinator.recoveryNotice?.kind == expectedKind)
    #expect(f.owner.coordinator.recoveryNotice?.preservedPath == journal.path)
    let before = try f.owner.snapshot(profile: "default")
    #expect(!before.ready)
    #expect(before.document["nodes"]?["b0"]?["title"] == "A")
    #expect(before.document["nodes"]?["b0"]?["url"] == "https://cached.test")
    f.client.pageID = "b1"
    f.client.title = "B"
    let scheduler = OwnerLifecycleScheduler()
    try await f.start(scheduler: scheduler.scheduler)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      let snapshot = try f.owner.snapshot(profile: "default")
      let catalog = f.catalog.bookmarks(engineProfile: "")
      if !f.client.reads.isEmpty && snapshot.ready && catalog.readyForSync && catalog.nodes["b1"]?.title == "B" { break }
      await Task.yield()
    }
    #expect(f.owner.runtimeIsActiveForTesting)
    #expect(f.catalog.bookmarkClaim?.coordinator === f.owner.coordinator)
    #expect(f.client.reads == [""])
    #expect(scheduler.delays.isEmpty)
    let snapshot = try f.owner.snapshot(profile: "default")
    #expect(snapshot.ready)
    #expect(snapshot.document["nodes"]?["b0"] == nil)
    #expect(snapshot.document["nodes"]?["b1"]?["title"] == "B")
    #expect(snapshot.document["nodes"]?["b1"]?["url"] == "https://page.test")
    let catalog = f.catalog.bookmarks(engineProfile: "")
    #expect(catalog.hasView)
    #expect(catalog.readyForSync)
    #expect(catalog.nodes["b0"] == nil)
    #expect(catalog.nodes["b1"]?.title == "B")
    #expect(catalog.nodes["b1"]?.url == "https://page.test")
    #expect(catalog.revision == Int(clamping: snapshot.revision))
    let refusal = BookmarkWriterError.refused(String(describing: BookmarkPendingStoreError.unavailable))
    #expect(throws: refusal) {
      try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b1", ["title": "Refused"]])], binding: snapshot.binding)
    }
    var replacementNodes = try #require(snapshot.document["nodes"]?.object)
    var replacementPage = try #require(replacementNodes["b1"]?.object)
    replacementPage["title"] = "Refused"
    replacementNodes["b1"] = .object(replacementPage)
    let replacement: JSONValue = ["nodes": .object(replacementNodes), "roots": snapshot.document["roots"]!]
    #expect(throws: refusal) {
      try f.owner.replace(profile: "default", document: replacement, expectedRevision: snapshot.revision, binding: snapshot.binding)
    }
    let unchanged = try f.owner.snapshot(profile: "default")
    #expect(unchanged.document == snapshot.document)
    #expect(unchanged.revision == snapshot.revision)
    #expect(try Data(contentsOf: journal) == bytes)
    #expect(try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == Date(timeIntervalSince1970: 12))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted() == ["bookmarks-cache.json", BookmarkPendingStore.journalName].sorted())
    f.state.profiles["default"]?.dataId = "recovery-engine"
    try await f.owner.remap(state: f.state)
    let remapDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < remapDeadline {
      let remapped = try f.owner.snapshot(profile: "default")
      let catalog = f.catalog.bookmarks(engineProfile: "recovery-engine")
      if remapped.binding.engine == "recovery-engine" && remapped.ready && catalog.readyForSync && catalog.nodes["b1"]?.title == "B" { break }
      await Task.yield()
    }
    let remapped = try f.owner.snapshot(profile: "default")
    #expect(remapped.binding.engine == "recovery-engine")
    #expect(remapped.ready)
    #expect(f.owner.coordinator.engine(profile: "default") == "recovery-engine")
    #expect(remapped.document["nodes"]?["b1"]?["title"] == "B")
    let remappedCatalog = f.catalog.bookmarks(engineProfile: "recovery-engine")
    #expect(remappedCatalog.hasView)
    #expect(remappedCatalog.readyForSync)
    #expect(remappedCatalog.nodes["b1"]?.title == "B")
    #expect(f.client.reads == ["", "recovery-engine"])
    #expect(f.owner.runtimeIsActiveForTesting)
    #expect(scheduler.delays.isEmpty)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: snapshot.binding)
    }
    #expect(throws: refusal) {
      try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b1", ["title": "Refused"]])], binding: remapped.binding)
    }
    #expect(f.client.appliedEngines.isEmpty)
    #expect(f.client.rawReads == 0)
    #expect(f.client.rawApplies == 0)
    #expect(try Data(contentsOf: journal) == bytes)
    #expect(try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == Date(timeIntervalSince1970: 12))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted() == ["bookmarks-cache.json", BookmarkPendingStore.journalName].sorted())
  }

  @Test func remapReclaimsSameCatalogAndReadsEveryOwnedEngine() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    await f.settle()
    let first = try #require(f.catalog.bookmarkClaim)
    let binding = try f.owner.snapshot(profile: "default").binding
    f.state.profiles["work"] = profile("work", data: "shared")
    f.state.profiles["alias"] = profile("alias", data: "shared")
    try await f.owner.remap(state: f.state)
    await f.settle()
    let second = try #require(f.catalog.bookmarkClaim)
    #expect(second !== first)
    #expect(second.coordinator === first.coordinator)
    #expect(second.epoch > first.epoch)
    #expect(f.client.reads.filter { $0.isEmpty }.count == 2)
    #expect(f.client.reads.filter { $0 == "shared" }.count == 1)
    #expect(f.catalog.bookmarks(engineProfile: "shared").hasView)
    _ = try f.owner.submit(profile: "default", mutations: [], binding: binding)
    await #expect(throws: BookmarkCoordinatorError.staleRevision) {
      try await first.pump.submit(profile: "default", mutations: [])
    }
    #expect(f.client.rawReads == 0)
    #expect(f.client.rawApplies == 0)
  }

  @Test func replacementPumpReadsEditJournaledWhileStopped() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    await f.settle()
    f.catalog.bookmarkClaim?.pump.stop()
    let before = try f.owner.snapshot(profile: "default")
    let owner = f.owner
    _ = try await Task.detached {
      try owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "While stopped"]])], binding: before.binding)
    }.value
    let reopened = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    #expect(try reopened.snapshot(profile: "default").document["nodes"]?["b0"]?["title"] == "While stopped")
    try await f.owner.remap(state: f.state)
    await f.settle()
    #expect(f.client.reads == ["", ""])
    #expect(f.client.title == "While stopped")
    #expect(f.catalog.bookmarks(engineProfile: "").nodes["b0"]?.title == "While stopped")
    #expect(f.client.rawApplies == 0)
  }

  @Test func defaultProfileAndSharedDataChangesRemap() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.state.profiles["work"] = profile("work", data: "default")
    let store = Store(state: f.state, checksInvariants: false)
    try await f.start()
    f.owner.bindStore(store)
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    let before = try f.owner.snapshot(profile: "work").binding
    try store.transact { session in
      session.update { state in
        state.settings.values["defaultProfileId"] = "work"
        state.profiles["work"]?.dataId = "work-data"
      }
    }
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    #expect(try f.owner.snapshot(profile: "work").binding.engine == "work-data")
    #expect(throws: BookmarkWriterError.unknownProfile) { try f.owner.snapshot(profile: "missing") }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.replace(profile: "work", document: ["nodes": [:], "roots": [:]], expectedRevision: 0, binding: before)
    }
    try store.transact { session in
      session.update { $0.profiles["work"]?.dataId = "default" }
    }
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    #expect(throws: BookmarkWriterError.unknownProfile) { try f.owner.snapshot(profile: "missing") }
    #expect(f.owner.coordinator.catalogEngines == [""])
    #expect(f.client.reads.contains("work-data"))
  }

  @Test func catalogClaimUnderTheFenceNeverEntersStoreIngress() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    let store = Store(state: f.state, checksInvariants: false)
    let previousResolver = NativeStoreHandle.resolve
    NativeStoreHandle.resolve = { store }
    defer { f.owner.stop(); NativeStoreHandle.resolve = previousResolver }
    f.owner.subscribeToStoreCommits()
    await f.owner.settleLifecycleForTesting()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let held = Thread {
      store.sequence {
        entered.signal()
        _ = release.wait(timeout: .now() + 3)
      }
    }
    held.start()
    #expect(blockingWait(entered, seconds: 5))
    defer { release.signal() }
    let before = f.catalog.bookmarkClaim.map { ObjectIdentifier($0.pump) }
    var changed = f.state
    changed.profiles["work"] = profile("work", data: "work-data")
    let started = ContinuousClock.now
    try await f.owner.remap(state: changed)
    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(f.catalog.bookmarkClaim.map { ObjectIdentifier($0.pump) } != before)
    #expect(elapsed < .seconds(1), "the replacement claim waited on the store's ingress: \(elapsed)")
    release.signal()
  }

  @Test func storeReplacementFencesOldOwner() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    let old = Store(state: f.state, checksInvariants: false)
    let previousResolver = NativeStoreHandle.resolve
    NativeStoreHandle.resolve = { old }
    defer { f.owner.stop(); NativeStoreHandle.resolve = previousResolver }
    f.owner.subscribeToStoreCommits()
    await f.owner.settleLifecycleForTesting()
    let before = try f.owner.snapshot(profile: "default")
    let oldStore = old
    try await Task.detached {
      try oldStore.transact { session in
        session.update { $0.profiles["default"]?.dataId = "obsolete" }
      }
    }.value
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: before.binding)
    }
    var replacement = f.state
    replacement.profiles["default"]?.dataId = "replacement"
    let current = Store(state: replacement, checksInvariants: false)
    NativeStoreHandle.resolve = { current }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: before.binding)
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.replace(profile: "default", document: before.document, expectedRevision: before.revision, binding: before.binding)
    }
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    try old.transact { session in
      session.update { $0.profiles["default"]?.dataId = "must-not-return" }
    }
    await f.owner.settleLifecycleForTesting()
    #expect(try f.owner.snapshot(profile: "default").binding.engine == "replacement")
    #expect(f.owner.coordinator.catalogEngines == ["replacement"])
    #expect(!f.client.reads.contains("must-not-return"))
    let live = try f.owner.snapshot(profile: "default")
    NativeStoreHandle.resolve = nil
    _ = try f.owner.submit(profile: "default", mutations: [], binding: live.binding)
    await #expect(throws: BookmarkCoordinatorError.staleRevision) {
      try await f.catalog.applyBookmarks(ops: [], engineProfile: "replacement")
    }
    #expect(f.client.rawApplies == 0)
  }

  @Test func privateWindowNeverCreatesBookmarkLane() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.state.profiles["work"] = profile("work", data: "work-data")
    f.state.profiles["incognito:w@work"] = profile("incognito:w@work")
    try await f.start()
    try await f.owner.remap(state: f.state)
    await f.settle()
    #expect(try f.owner.snapshot(profile: "incognito:w@work").binding.engine == "work-data")
    #expect(f.owner.coordinator.engine(profile: "incognito:w", originalProfile: "work") == "work-data")
    #expect(Set(f.owner.coordinator.catalogEngines) == Set(["", "work-data"]))
    #expect(f.client.reads.allSatisfy { !$0.hasPrefix("incognito:") })
  }

  @Test func coordinatorRemapFencesOwnerAdmissions() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    await f.settle()
    let before = try f.owner.snapshot(profile: "default")
    f.owner.coordinator.remap(profiles: ["default": "", "alias": ""], defaultProfile: "default", owningProfiles: ["": "alias"])
    _ = try f.owner.submit(profile: "default", mutations: [], binding: before.binding)
    _ = try f.owner.replace(profile: "default", document: before.document, expectedRevision: before.revision, binding: before.binding)
    f.owner.coordinator.remap(profiles: ["default": "changed"], defaultProfile: "default")
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: before.binding)
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.replace(profile: "default", document: before.document, expectedRevision: before.revision, binding: before.binding)
    }
  }

  @Test(arguments: [false, true]) func editDuringRemapIsJournaledAndPushed(beforeInstall: Bool) async throws {
    var state = BrowserState()
    state.profiles["work"] = profile("work", data: "old-work")
    let f = try await OwnerLifecycleFixture.make(state: state)
    defer { f.stop() }
    try await f.start()
    await f.settle()
    let binding = try f.owner.snapshot(profile: "default").binding
    let gate = OwnerClaimGate()
    if beforeInstall { f.owner.beforeInstallForTesting = { await gate.hold() } } else { f.owner.beforeClaimForTesting = { await gate.hold() } }
    defer { gate.open() }
    f.state.profiles["work"]?.dataId = "new-work"
    let remap = Task { try await f.owner.remap(state: f.state) }
    try await gate.waitUntilHeld()
    let owner = f.owner
    _ = try await Task.detached {
      try owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "During remap"]])], binding: binding, requestID: "during-remap")
    }.value
    let recovered = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    #expect(try recovered.snapshot(profile: "default").document["nodes"]?["b0"]?["title"] == "During remap")
    gate.open()
    try await remap.value
    await f.settle()
    #expect(f.client.appliedTitles[""] == "During remap")
  }

  @Test func editForARemappedProfileIsRefusedThenAccepted() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    await f.settle()
    let old = try f.owner.snapshot(profile: "default")
    let gate = OwnerClaimGate()
    f.owner.beforeClaimForTesting = { await gate.hold() }
    defer { gate.open() }
    f.state.profiles["default"]?.dataId = "replacement"
    let remap = Task { try await f.owner.remap(state: f.state) }
    try await gate.waitUntilHeld()
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: old.binding)
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.replace(profile: "default", document: old.document, expectedRevision: old.revision, binding: old.binding)
    }
    let fresh = try f.owner.snapshot(profile: "default")
    #expect(fresh.binding.engine == "replacement")
    let owner = f.owner
    _ = try await Task.detached {
      try owner.submit(profile: "default", mutations: [.init(method: "addBookmark", args: [["profileId": "default", "url": "https://during.test", "title": "Accepted"]])], binding: fresh.binding)
    }.value
    gate.open()
    try await remap.value
    await f.settle()
    #expect(f.client.appliedEngines.contains("replacement"))
  }

  @Test func stagedSnapshotUsesNewEngineAndWaitsForInstallation() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://old.test"]), ready: true)
    f.owner.coordinator.seed(engine: "next", document: ["nodes": [:], "roots": [:]], ready: true)
    f.state.profiles["default"]?.dataId = "next"
    let ticket = try #require(f.owner.stageForTesting(state: f.state))
    let staged = try f.owner.snapshot(profile: "default")
    #expect(staged.binding.engine == "next")
    #expect(!staged.ready)
    #expect(staged.document == ["nodes": [:], "roots": [:]])
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: staged.binding)
    }
    #expect(await f.owner.installMappingForTesting(ticket))
    #expect(try f.owner.snapshot(profile: "default").ready)
    _ = try f.owner.submit(profile: "default", mutations: [], binding: staged.binding)
  }

  @Test(arguments: [false, true]) func claimFailuresRetryWithBackoffAndKeepJournaling(afterStart: Bool) async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let time = OwnerLifecycleScheduler()
    if afterStart {
      try await f.start(scheduler: time.scheduler)
      await f.settle()
    } else {
      f.owner.coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://page.test"]), ready: true)
    }
    var attempts = 0
    f.owner.claimForTesting = {
      attempts += 1
      if attempts <= 7 { throw BookmarkCoordinatorError.ownershipUnavailable }
    }
    if afterStart { try await f.owner.remap(state: f.state) }
    else { try await f.start(scheduler: time.scheduler) }
    #expect(attempts == 1)
    #expect(f.owner.runtimeIsActiveForTesting == afterStart)
    let binding = try f.owner.snapshot(profile: "default").binding
    _ = try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "While retrying"]])], binding: binding)
    let recovered = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    #expect(try recovered.snapshot(profile: "default").document["nodes"]?["b0"]?["title"] == "While retrying")
    let delays: [Double] = [1000, 2000, 4000, 8000, 16000, 32000, 60000]
    for (index, delay) in delays.enumerated() {
      #expect(time.delays == Array(delays.prefix(index + 1)))
      #expect(time.delays.last == delay)
      try time.fireNext()
      await f.owner.settleLifecycleForTesting()
      #expect(attempts == index + 2)
    }
    #expect(f.owner.runtimeIsActiveForTesting)
    await f.settle()
    #expect(f.client.appliedTitles[""] == "While retrying")
    #expect(time.jobs.allSatisfy { $0 == nil })
  }

  @Test func unchangedFirstStoreBindKeepsTheStartPump() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let store = Store(state: f.state, checksInvariants: false)
    let previous = NativeStoreHandle.resolve
    NativeStoreHandle.resolve = { store }
    defer { f.owner.stop(); NativeStoreHandle.resolve = previous }
    try await f.start()
    await f.settle()
    let first = try #require(f.catalog.bookmarkClaim)
    f.owner.subscribeToStoreCommits()
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    #expect(f.catalog.bookmarkClaim === first)
    #expect(f.client.reads == [""])
  }

  @Test func sameMapStoreReattachPushesEditsJournaledWhileDetached() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let store = Store(state: f.state, checksInvariants: false)
    let previous = NativeStoreHandle.resolve
    NativeStoreHandle.resolve = { store }
    defer { f.owner.stop(); NativeStoreHandle.resolve = previous }
    try await f.start()
    f.owner.subscribeToStoreCommits()
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    NativeStoreHandle.resolve = nil
    let binding = try f.owner.snapshot(profile: "default").binding
    _ = try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Detached"]])], binding: binding)
    NativeStoreHandle.resolve = { store }
    await f.owner.settleLifecycleForTesting()
    await f.settle()
    #expect(f.client.appliedTitles[""] == "Detached")
  }

  @Test func supersededClaimRetryCannotReplaceTheCurrentPump() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let time = OwnerLifecycleScheduler()
    var attempts = 0
    f.owner.claimForTesting = {
      attempts += 1
      if attempts == 1 { throw BookmarkCoordinatorError.ownershipUnavailable }
    }
    try await f.start(scheduler: time.scheduler)
    let obsolete = try #require(time.jobs.first ?? nil)
    f.state.profiles["default"]?.dataId = "current"
    try await f.owner.remap(state: f.state)
    await f.settle()
    let current = try #require(f.catalog.bookmarkClaim)
    obsolete()
    await f.owner.settleLifecycleForTesting()
    #expect(f.catalog.bookmarkClaim === current)
    #expect(attempts == 2)
    #expect(try f.owner.snapshot(profile: "default").binding.engine == "current")
  }

  @Test func snapshotsAndStagingDoNotWaitForJournalIO() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-io-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let armed = JournalGateFlag()
    let operations = gatedJournalOperations(armed: armed, entered: entered, release: release)
    let owner = NativeBookmarkOwner(store: BookmarkPendingStore(directory: directory, fileOperations: operations), profiles: ["default": ""], defaultProfile: "default", wake: { _ in })
    let binding = try owner.snapshot(profile: "default").binding
    armed.set()
    let writerDone = JournalGateFlag()
    let writer = Task.detached { _ = try owner.submit(profile: "default", mutations: [], binding: binding, requestID: "slow"); writerDone.set() }
    let didEnter = await Task.detached { blockingWait(entered, seconds: 5) }.value
    guard didEnter else { release.signal(); _ = try await writer.value; Issue.record("Journal gate was not reached"); return }
    let completed = Mutex(false)
    let reader = Task.detached {
      _ = try owner.snapshot(profile: "default")
      _ = owner.stageForTesting(state: BrowserState())
      completed.withLock { $0 = true }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !completed.withLock({ $0 }) && ContinuousClock.now < deadline { await Task.yield() }
    let proceeded = completed.withLock { $0 }
    let writeWasInProgress = !writerDone.isSet
    release.signal()
    _ = try await writer.value
    try await reader.value
    #expect(writeWasInProgress, "the gate held the submit's own journal write")
    #expect(proceeded)
  }

  @Test func unknownProfilesCannotReadOrWriteTheDefaultEngine() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let snapshot = try f.owner.snapshot(profile: "default")
    for profile in ["missing", "incognito:w@missing"] {
      #expect(throws: BookmarkWriterError.unknownProfile) { try f.owner.snapshot(profile: profile) }
      #expect(throws: BookmarkWriterError.unknownProfile) {
        try f.owner.submit(profile: profile, mutations: [], binding: snapshot.binding)
      }
      #expect(throws: BookmarkWriterError.unknownProfile) {
        try f.owner.replace(profile: profile, document: snapshot.document, expectedRevision: snapshot.revision, binding: snapshot.binding)
      }
    }
    #expect(f.owner.coordinator.desiredView(engine: "").revision == snapshot.revision)
  }

  @Test func coordinatorRefusesRemovedProfilesEvenWhenTheDefaultSharesTheirEngine() throws {
    let coordinator = BookmarkCoordinator(profiles: ["p": "E", "default": "E"], defaultProfile: "default")
    coordinator.seed(engine: "E", document: document(engine: "E", profile: "p"), ready: true)
    let before = coordinator.desiredView(engine: "E")
    coordinator.remap(profiles: ["default": "E"], defaultProfile: "default")
    for profile in ["p", "incognito:w@p"] {
      #expect(throws: BookmarkWriterError.staleBinding) {
        try coordinator.submit(profile: profile, mutations: [], expectedEngine: "E")
      }
      #expect(throws: BookmarkWriterError.staleBinding) {
        try coordinator.replaceDocument(engine: "E", profile: profile, document: before.document, expectedRevision: before.revision, expectedEngine: "E")
      }
    }
    #expect(coordinator.desiredView(engine: "E") == before)
  }

  @Test func coldPrepareUsesRecoveredOwnerOnlyWhileItIsStillAnAlias() async throws {
    var state = BrowserState()
    state.profiles["z"] = profile("z", data: "E")
    let f = try await OwnerLifecycleFixture.make(state: state)
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "E", document: document(engine: "E", profile: "z"), ready: true)
    let before = try f.owner.snapshot(profile: "z")
    _ = try f.owner.submit(profile: "z", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending"]])], binding: before.binding)
    state.profiles["a"] = profile("a", data: "E")
    let retained = await NativeBookmarkOwner.prepare(directory: f.directory, state: state)
    #expect(retained.coordinator.ownerProfileForTesting(engine: "E") == "z")
    state.profiles["z"] = nil
    let surviving = await NativeBookmarkOwner.prepare(directory: f.directory, state: state)
    #expect(surviving.coordinator.ownerProfileForTesting(engine: "E") == "a")
    let selected = try surviving.snapshot(profile: "a")
    _ = try surviving.submit(profile: "a", mutations: [], binding: selected.binding)
    let loaded = BookmarkPendingStore(directory: f.directory).load().payload
    let entry = loaded?["engines"]?.array?.first { $0["view"]?["engine"] == "E" }
    #expect(entry?["ownerProfile"] == "a")
  }

  @Test func replacementPumpDrainsAnEngineAfterItsLastAliasLeaves() async throws {
    var state = BrowserState()
    state.profiles["p"] = profile("p", data: "E1")
    let f = try await OwnerLifecycleFixture.make(state: state)
    defer { f.stop() }
    try await f.start()
    await f.settle()
    f.catalog.bookmarkClaim?.pump.stop()
    let before = try f.owner.snapshot(profile: "p")
    let owner = f.owner
    _ = try await Task.detached {
      try owner.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Stranded"]])], binding: before.binding)
    }.value
    f.state.profiles["p"]?.dataId = "E2"
    let gate = OwnerClaimGate()
    f.owner.beforeClaimForTesting = { await gate.hold() }
    defer { gate.open() }
    let remap = Task { try await f.owner.remap(state: f.state) }
    try await gate.waitUntilHeld()
    #expect(f.owner.coordinator.catalogEngines.contains("E1"))
    gate.open()
    try await remap.value
    let claim = try #require(f.catalog.bookmarkClaim)
    await claim.pump.settle(engine: "E1")
    await f.settle()
    #expect(f.client.appliedTitles["E1"] == "Stranded")
    #expect(!f.owner.coordinator.catalogEngines.contains("E1"))
    #expect(f.owner.coordinator.pumpInput(engine: "E1", epoch: claim.epoch) == nil)
  }

  @Test func writerErrorCodesPreserveDescriptions() {
    let cases: [(BookmarkWriterError, String, String)] = [
      (.notOwned, "notOwned", "native bookmarks are not owned by this launch"),
      (.staleBinding, "staleBinding", "the bookmark owner changed since this binding was taken"),
      (.unknownProfile, "unknownProfile", "the bookmark profile is unknown"),
      (.invalidDocument("bad"), "invalidDocument", "invalid bookmark document: bad"),
      (.refused("conditionFailed(\"held\")"), "refused", "bookmark replacement refused: conditionFailed(\"held\")"),
      (.conditionFailed("conditionFailed(\"held\")"), "conditionFailed", "bookmark replacement refused: conditionFailed(\"held\")"),
    ]
    for (error, code, description) in cases {
      #expect(error.code == code)
      #expect(error.description == description)
    }
  }

  @Test func conditionFailureReachesTheWriterAsItsOwnCode() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    await f.settle()
    let snapshot = try f.owner.snapshot(profile: "default")
    #expect(throws: BookmarkWriterError.conditionFailed(String(describing: BookmarkCoordinatorError.conditionFailed("missing-folder")))) {
      try f.owner.submit(profile: "default", mutations: [.init(method: "expectChildren", args: ["default", "missing-folder", []])], binding: snapshot.binding)
    }
  }

  @Test func owningProfileIsStableAcrossAliasChanges() {
    var state = BrowserState()
    state.profiles["z"] = profile("z", data: "shared")
    let first = BookmarkProfileMap(state: state)
    state.profiles["a"] = profile("a", data: "shared")
    let second = BookmarkProfileMap(state: state, previousOwners: first.owningProfiles)
    #expect(second.owningProfiles["shared"] == "z")
    state.profiles["z"] = nil
    #expect(BookmarkProfileMap(state: state, previousOwners: second.owningProfiles).owningProfiles["shared"] == "a")
  }

  private func document(engine: String, profile: String) -> JSONValue {
    let roots = BookmarkFlat.roots(engine)
    return ["nodes": [
      roots.bar: ["id": .string(roots.bar), "kind": "folder", "parentId": nil, "title": "Bar", "children": ["b0"], "addedAt": 0],
      roots.other: ["id": .string(roots.other), "kind": "folder", "parentId": nil, "title": "Other", "children": [], "addedAt": 0],
      "b0": ["id": "b0", "kind": "url", "parentId": .string(roots.bar), "title": "Page", "url": "https://page.test", "addedAt": 1],
    ], "roots": .object([profile: ["bar": .string(roots.bar), "other": .string(roots.other)]])]
  }

  private func profile(_ id: String, data: String? = nil) -> Profile {
    Profile(id: id, name: id, color: "blue", icon: nil, createdAt: 1, dataId: data)
  }
}

@MainActor private final class OwnerLifecycleFixture {
  let directory: URL
  let owner: NativeBookmarkOwner
  let client = OwnerLifecycleClient()
  let catalog: LibraryCatalog
  var state: BrowserState

  private init(directory: URL, owner: NativeBookmarkOwner, state: BrowserState) {
    self.directory = directory
    self.owner = owner
    self.state = state
    catalog = LibraryCatalog(client: client)
  }

  static func make(state: BrowserState = BrowserState(), journalBytes: Data? = nil, cache: JSONValue? = nil, fileOperations: BookmarkPendingFileOperations? = nil) async throws -> OwnerLifecycleFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let journalBytes {
      let journal = directory.appendingPathComponent(BookmarkPendingStore.journalName)
      try journalBytes.write(to: journal)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 12)], ofItemAtPath: journal.path)
    }
    if let cache { try Data(cache.text().utf8).write(to: directory.appendingPathComponent("bookmarks-cache.json")) }
    let owner: NativeBookmarkOwner
    if let fileOperations {
      let mapping = BookmarkProfileMap(state: state)
      let launch = BookmarkLaunchCache(directory: directory).load(profiles: mapping.profiles, defaultProfile: mapping.defaultProfile)
      owner = NativeBookmarkOwner(store: BookmarkPendingStore(directory: directory, fileOperations: fileOperations), profiles: mapping.profiles, defaultProfile: mapping.defaultProfile, launchInput: launch, wake: { _ in })
    } else {
      owner = await NativeBookmarkOwner.prepare(directory: directory, state: state, cacheDirectory: cache == nil ? nil : directory)
    }
    return OwnerLifecycleFixture(directory: directory, owner: owner, state: state)
  }

  func start(scheduler: BookmarkPumpScheduler? = nil) async throws {
    try await owner.start(catalog: catalog, client: BookmarkEngineClient(readTree: { engine in await self.client.read(engine) }, apply: { engine, ops in await self.client.apply(engine, ops) }), clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: scheduler ?? .init(schedule: { _, _ in {} }))
  }

  func settle() async {
    guard let claim = catalog.bookmarkClaim else { return }
    for engine in owner.coordinator.catalogEngines {
      await claim.pump.settle(engine: engine)
      let revision = Int(clamping: owner.coordinator.desiredView(engine: engine).revision)
      for _ in 0..<1000 where catalog.bookmarks(engineProfile: engine).revision != revision { await Task.yield() }
      #expect(catalog.bookmarks(engineProfile: engine).revision == revision)
    }
  }

  func stop() {
    owner.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor private final class OwnerLifecycleClient: EngineClient {
  var pageID = "b0"
  var title = "Page"
  var reads: [String] = []
  var rawReads = 0
  var rawApplies = 0
  var appliedEngines: [String] = []
  var appliedTitles: [String: String] = [:]

  func read(_ engine: String) -> EngineBookmarkTree {
    reads.append(engine)
    return EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: [.init(id: pageID, kind: "u", title: title, url: "https://page.test", addedAt: 1)]), other: .init(id: "other", kind: "f", title: "Other", children: []))
  }

  func apply(_ engine: String, _ ops: [BookmarkOperation]) -> BookmarkApplyResult {
    appliedEngines.append(engine)
    for op in ops { if let value = op.title { title = value; appliedTitles[engine] = value } }
    return .init(applied: ops.count, skipped: 0, invalid: [])
  }

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree { rawReads += 1; return read(engineProfile) }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult { rawApplies += 1; return apply(engineProfile, ops) }
}

@MainActor private final class OwnerClaimGate {
  private var held: CheckedContinuation<Void, Never>?

  func hold() async { await withCheckedContinuation { held = $0 } }

  func waitUntilHeld() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while held == nil && ContinuousClock.now < deadline { await Task.yield() }
    try #require(held != nil)
  }

  func open() { held?.resume(); held = nil }
}

@MainActor private final class OwnerLifecycleScheduler {
  var delays: [Double] = []
  var jobs: [(@MainActor @Sendable () -> Void)?] = []

  var scheduler: BookmarkPumpScheduler {
    .init(schedule: { delay, callback in
      self.delays.append(delay)
      let index = self.jobs.count
      self.jobs.append(callback)
      return { self.jobs[index] = nil }
    })
  }

  func fireNext() throws {
    let index = try #require(jobs.firstIndex { $0 != nil })
    let callback = jobs[index]
    jobs[index] = nil
    callback?()
  }
}

private func blockingWait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
  semaphore.wait(timeout: .now() + seconds) == .success
}

private final class JournalGateFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  func set() { lock.withLock { on = true } }
  var isSet: Bool { lock.withLock { on } }
}

private func gatedJournalOperations(armed: JournalGateFlag, entered: DispatchSemaphore, release: DispatchSemaphore) -> BookmarkPendingFileOperations {
  var operations = BookmarkPendingFileOperations.live
  let liveSync = operations.syncFile
  operations.syncFile = { url in
    if armed.isSet {
      entered.signal()
      _ = release.wait(timeout: .now() + 10)
    }
    try liveSync(url)
  }
  return operations
}
