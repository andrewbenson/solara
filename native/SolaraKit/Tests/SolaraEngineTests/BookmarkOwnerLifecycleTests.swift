import Foundation
import Testing
import Synchronization
import SolaraModel
import SolaraStore
@testable import SolaraEngine

@Suite(.serialized) @MainActor struct BookmarkOwnerLifecycleTests {
  @Test func safeModeRestorableTerminalRefreshesDisplayWithoutJournalWrites() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let coordinator = f.owner.coordinator
    coordinator.seed(engine: "", document: document(engine: "", profile: "default"), ready: true)
    let snapshot = try f.owner.snapshot(profile: "default")
    _ = try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Pending before disappearance"]])], binding: snapshot.binding, requestID: "terminal-seed")
    #expect(coordinator.remap(profiles: ["default": "away"], defaultProfile: "default"))
    #expect(coordinator.terminalizeGoneEngine(engine: "", epoch: coordinator.claimPump()))
    let journal = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    var state = f.state
    state.orphanedProfileData = ["orphaned-engine"]
    let owner = await NativeBookmarkOwner.prepare(directory: f.directory, state: state, readOnly: true)
    NativeBookmarkOwner.current = owner
    defer { owner.stop() }
    let catalog = LibraryCatalog(client: f.client)
    try await owner.start(catalog: catalog, client: BookmarkEngineClient(
      readTree: { engine in await f.client.read(engine) },
      apply: { engine, ops in await f.client.apply(engine, ops) }),
      clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
    let store = Store(state: state)
    owner.bindStore(store)
    await owner.settleLifecycleForTesting()
    #expect(owner.installationIsUsable(catalog: catalog))
    let claim = try #require(catalog.bookmarkClaim)
    await claim.pump.settle(engine: "")
    #expect(owner.coordinator.desiredView(engine: "").document["nodes"]?["b0"] != nil)
    #expect(!owner.coordinator.desiredView(engine: "").readyForSync)
    #expect(owner.coordinator.bookmarkWritesPaused)
    #expect(f.client.appliedEngines.isEmpty)
    #expect(try Data(contentsOf: journal) == bytes)
  }

  @Test(arguments: [false, true]) func rejectedRetainedURLKeepsRecoveryDisplayWithOrphanRetirement(acquiredAfterPreparation: Bool) async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "", document: document(engine: "", profile: "default"), ready: true)
    let rejected = "https://rejected-retained.test/"
    func persistRejectedURL() throws {
      let snapshot = try f.owner.snapshot(profile: "default")
      _ = try f.owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["url": .string(rejected)]])], binding: snapshot.binding)
    }
    if !acquiredAfterPreparation { try persistRejectedURL() }
    var state = f.state
    state.orphanedProfileData = ["orphaned-engine"]
    let owner = await NativeBookmarkOwner.prepare(directory: f.directory, state: state, canonicalURL: { value in
      guard value != "https://rejected-retained.test/" else { throw BookmarkCoordinatorError.invalidOperation("Rejected retained URL") }
      return value
    })
    defer { owner.stop() }
    if acquiredAfterPreparation { try persistRejectedURL() }
    let journal = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted()
    let modified = try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    NativeBookmarkOwner.current = owner
    let catalog = LibraryCatalog(client: f.client)
    try await owner.start(catalog: catalog, client: BookmarkEngineClient(
      readTree: { engine in await f.client.read(engine) },
      apply: { engine, ops in await f.client.apply(engine, ops) }),
      clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
    let store = Store(state: state)
    owner.bindStore(store)
    await owner.settleLifecycleForTesting()
    #expect(owner.installationIsUsable(catalog: catalog))
    let claim = try #require(catalog.bookmarkClaim)
    await claim.pump.settle(engine: "")
    let snapshot = try owner.snapshot(profile: "default")
    #expect(snapshot.document["nodes"]?["b0"]?["url"] == .string(rejected))
    #expect(catalog.bookmarks(engineProfile: "").hasView)
    #expect(catalog.bookmarks(engineProfile: "").nodes["b0"]?.url == rejected)
    #expect(!snapshot.ready)
    #expect(!owner.coordinator.desiredView(engine: "").readyForSync)
    #expect(owner.coordinator.bookmarkWritesPaused)
    #expect(throws: BookmarkWriterError.self) {
      try owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Refused"]])], binding: snapshot.binding)
    }
    #expect(throws: BookmarkWriterError.self) {
      try owner.replace(profile: "default", document: snapshot.document, expectedRevision: snapshot.revision, binding: snapshot.binding)
    }
    #expect(f.client.appliedEngines.isEmpty)
    #expect(try Data(contentsOf: journal) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted() == names)
    #expect(try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
  }

  @Test(arguments: [false, true]) func reacquiredRecoveryPolicyKeepsDisplayWithOrphanRetirement(newerJournal: Bool) async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "", document: document(engine: "", profile: "default"), ready: true)
    _ = try f.owner.submit(profile: "default", mutations: [], binding: f.owner.snapshot(profile: "default").binding)
    var state = f.state
    state.orphanedProfileData = ["orphaned-engine"]
    let owner = await NativeBookmarkOwner.prepare(directory: f.directory, state: state)
    defer { owner.stop() }
    let bytes = Data((newerJournal ? "{\"version\":999,\"future\":\"intent\"}" : "unreadable journal").utf8)
    try bytes.write(to: f.directory.appendingPathComponent(BookmarkPendingStore.journalName))
    NativeBookmarkOwner.current = owner
    let notice = try #require(owner.coordinator.recoveryNotice)
    #expect(notice.kind == (newerJournal ? .newerJournalVersion : .unreadableJournal))
    let preserved = URL(fileURLWithPath: try #require(notice.preservedPath))
    #expect(try Data(contentsOf: preserved) == bytes)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted()
    let modified = try preserved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let catalog = LibraryCatalog(client: f.client)
    try await owner.start(catalog: catalog, client: BookmarkEngineClient(
      readTree: { engine in await f.client.read(engine) },
      apply: { engine, ops in await f.client.apply(engine, ops) }),
      clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
    let store = Store(state: state)
    owner.bindStore(store)
    await owner.settleLifecycleForTesting()
    #expect(owner.installationIsUsable(catalog: catalog))
    let claim = try #require(catalog.bookmarkClaim)
    await claim.pump.settle(engine: "")
    #expect(catalog.bookmarks(engineProfile: "").hasView)
    #expect(catalog.bookmarks(engineProfile: "").nodes["b0"] != nil)
    #expect(!catalog.bookmarks(engineProfile: "").readyForSync)
    #expect(owner.coordinator.bookmarkWritesPaused)
    #expect(f.client.appliedEngines.isEmpty)
    #expect(try Data(contentsOf: preserved) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted() == names)
    #expect(try preserved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
  }

  @Test(arguments: [false, true]) func preparedOwnerKeepsLegacyMigrationUnreadyAfterJournalAcquisition(existingJournal: Bool) async throws {
    let nodes = try #require(document(engine: "", profile: "default")["nodes"]?.object)
    let cache: JSONValue = ["version": 1, "trees": ["": .array(nodes.values)]]
    let f = try await OwnerLifecycleFixture.make(cache: cache)
    defer { f.stop() }
    if existingJournal {
      _ = try f.owner.submit(profile: "default", mutations: [], binding: f.owner.snapshot(profile: "default").binding)
      #expect(BookmarkPendingStore(directory: f.directory).load().payload?["legacyPendingEngines"] == [])
    }
    try Data("{\"kept\":true}".utf8).write(to: f.directory.appendingPathComponent("bookmarks.json"))
    let replacement = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state, cacheDirectory: f.directory)
    defer { replacement.stop() }
    #expect(try replacement.snapshot(profile: "default").document["nodes"]?["b0"]?["url"] == "https://page.test")
    NativeBookmarkOwner.current = replacement
    f.client.empty = true
    try await replacement.start(catalog: f.catalog, client: BookmarkEngineClient(readTree: { engine in await f.client.read(engine) }, apply: { engine, ops in await f.client.apply(engine, ops) }), clock: .init(wallTimeMs: { 0 }, monotonicTimeMs: { 0 }), scheduler: .init(schedule: { _, _ in {} }))
    let claim = try #require(f.catalog.bookmarkClaim)
    await claim.pump.settle(engine: "")
    #expect(f.client.reads == [""])
    let snapshot = try replacement.snapshot(profile: "default")
    #expect(snapshot.document["nodes"]?["b0"] == nil)
    #expect(!snapshot.ready)
    let pending = try #require(BookmarkPendingStore(directory: f.directory).load().payload?["legacyPendingEngines"]?.array)
    #expect(pending.contains(""))
    #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("bookmarks.json").path))
  }

  @Test(arguments: ["gone", "emptyAliasless", "retired"]) func acquisitionLaunchMarkerDoesNotReviveNewTerminal(reason: String) async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let prepared = BookmarkCoordinator(profiles: ["default": ""], defaultProfile: "default", pendingStore: BookmarkPendingStore(directory: f.directory), launchInput: .init(documents: ["": document(engine: "", profile: "default")], legacyPendingEngines: [JSKey("")]))
    f.owner.coordinator.seed(engine: "", document: ["nodes": [:], "roots": [:]], ready: true)
    #expect(f.owner.coordinator.remap(profiles: ["default": "away"], defaultProfile: "default"))
    if reason == "retired" { try f.owner.coordinator.retire(engine: "") }
    else if reason == "gone" { #expect(f.owner.coordinator.terminalizeGoneEngine(engine: "", epoch: f.owner.coordinator.claimPump())) }
    else { #expect(f.owner.coordinator.terminalizeEmptyAliaslessEngine(engine: "", epoch: f.owner.coordinator.claimPump())) }
    let terminalLaunch = BookmarkCoordinator(profiles: ["default": "away"], defaultProfile: "default", pendingStore: BookmarkPendingStore(directory: f.directory), launchInput: .init(legacyPendingEngines: [JSKey("")]))
    #expect(terminalLaunch.remap(profiles: ["default": "away"], defaultProfile: "default"))
    #expect(BookmarkPendingStore(directory: f.directory).load().payload?["legacyPendingEngines"] == [])
    prepared.reloadJournalForOwnerReplacement()
    #expect(!prepared.catalogEngines.contains(""))
    #expect(!prepared.desiredView(engine: "").hasView)
    #expect(prepared.remap(profiles: ["default": "away"], defaultProfile: "default"))
    let payload = try #require(BookmarkPendingStore(directory: f.directory).load().payload)
    #expect(payload["terminalEngines"]?[""] == .string(reason))
    #expect(payload["legacyPendingEngines"] == [])
  }

  @Test func acquisitionDoesNotKeepStaleDiskMigrationMarker() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let initial = BookmarkCoordinator(profiles: ["default": ""], defaultProfile: "default", pendingStore: BookmarkPendingStore(directory: f.directory), launchInput: .init(legacyPendingEngines: [JSKey("")]))
    #expect(initial.remap(profiles: ["default": ""], defaultProfile: "default"))
    let prepared = BookmarkCoordinator(profiles: ["default": ""], defaultProfile: "default", pendingStore: BookmarkPendingStore(directory: f.directory))
    try BookmarkPendingStore(directory: f.directory).write(["kind": "bookmarkCoordinator", "formatVersion": 2, "factSequence": "0", "syncLinks": [:], "engines": [], "requests": [], "conflicts": [], "legacyPendingEngines": []])
    prepared.reloadJournalForOwnerReplacement()
    prepared.completeRead(engine: "", document: document(engine: "", profile: "default"), capturedRevision: 0)
    #expect(prepared.desiredView(engine: "").readyForSync)
    #expect(BookmarkPendingStore(directory: f.directory).load().payload?["legacyPendingEngines"] == [])
  }

  @Test func replacementOrphanRetirementKeepsLateAcceptedSurvivorEdit() async throws {
    var state = BrowserState()
    state.profiles["survivor"] = profile("survivor", data: "E1")
    state.profiles["orphan"] = profile("orphan", data: "E0")
    let f = try await OwnerLifecycleFixture.make(state: state)
    defer { f.stop() }
    f.owner.coordinator.seed(engine: "E1", document: document(engine: "E1", profile: "survivor"), ready: true)
    f.owner.coordinator.seed(engine: "E0", document: document(engine: "E0", profile: "orphan"), ready: true)
    let initial = try f.owner.snapshot(profile: "survivor")
    _ = try f.owner.submit(profile: "survivor", mutations: [], binding: initial.binding, requestID: "seed")
    state.profiles["orphan"] = nil
    state.orphanedProfileData = ["E0"]
    let before = try Data(contentsOf: f.directory.appendingPathComponent(BookmarkPendingStore.journalName))
    let gate = OwnerClaimGate()
    let replacementTask = Task {
      await NativeBookmarkOwner.prepareForTesting(directory: f.directory, state: state, afterLoad: { await gate.hold() })
    }
    try await gate.waitUntilHeld()
    let mutations: [BookmarkMutation] = [.init(method: "updateBookmark", args: ["b0", ["title": "Accepted late"]])]
    #expect(try Data(contentsOf: f.directory.appendingPathComponent(BookmarkPendingStore.journalName)) == before)
    let receipt = try f.owner.submit(profile: "survivor", mutations: mutations, binding: initial.binding, requestID: "late")
    let acceptedBytes = try Data(contentsOf: f.directory.appendingPathComponent(BookmarkPendingStore.journalName))
    gate.open()
    let replacement = await replacementTask.value
    #expect(try Data(contentsOf: f.directory.appendingPathComponent(BookmarkPendingStore.journalName)) == acceptedBytes)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try replacement.submit(profile: "survivor", mutations: [], binding: replacement.snapshot(profile: "survivor").binding)
    }
    NativeBookmarkOwner.current = replacement
    let reopened = await NativeBookmarkOwner.prepare(directory: f.directory, state: state)
    #expect(reopened.coordinator.desiredView(engine: "E1").document["nodes"]?["b0"]?["title"] == "Accepted late")
    #expect(!reopened.coordinator.catalogEngines.contains("E0"))
    NativeBookmarkOwner.current = reopened
    let binding = try reopened.snapshot(profile: "survivor").binding
    let replay = try reopened.submit(profile: "survivor", mutations: mutations, binding: binding, requestID: "late")
    #expect(replay.view.revision == receipt.view.revision)
    #expect(replay.results == receipt.results)
    #expect(BookmarkPendingStore(directory: f.directory).load().payload?["terminalEngines"]?["E0"] == "retired")
  }

  @Test func restoredTerminalRouteSurvivesCrashBeforeReactivation() async throws {
    for reason in ["gone", "emptyAliasless", "retired"] {
      let f = try await OwnerLifecycleFixture.make()
      defer { f.stop() }
      let coordinator = f.owner.coordinator
      if reason != "emptyAliasless" { coordinator.seed(engine: "", document: document(engine: "", profile: "default"), ready: true) }
      let initial = try f.owner.snapshot(profile: "default")
      let oldMutations: [BookmarkMutation] = reason == "gone" ? [.init(method: "updateBookmark", args: ["b0", ["title": "Retired pending intent"]])] : []
      _ = try f.owner.submit(profile: "default", mutations: oldMutations, binding: initial.binding, requestID: "old")
      #expect(coordinator.remap(profiles: ["default": "away"], defaultProfile: "default"))
      if reason == "retired" { try coordinator.retire(engine: "") }
      else if reason == "gone" { #expect(coordinator.terminalizeGoneEngine(engine: "", epoch: coordinator.claimPump())) }
      else { #expect(coordinator.terminalizeEmptyAliaslessEngine(engine: "", epoch: coordinator.claimPump())) }
      let restored = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
      NativeBookmarkOwner.current = restored
      let snapshot = try restored.snapshot(profile: "default")
      #expect(snapshot.document["nodes"]?["b0"] == nil)
      if reason == "retired" {
        restored.remap(profiles: ["default": "away"], defaultProfile: "default")
        restored.remap(profiles: ["default": ""], defaultProfile: "default")
        #expect(!restored.coordinator.catalogEngines.contains(""))
        #expect(throws: BookmarkWriterError.staleBinding) {
          try restored.submit(profile: "default", mutations: [], binding: restored.snapshot(profile: "default").binding)
        }
      } else {
        #expect(restored.coordinator.catalogEngines.contains(""))
        _ = try restored.submit(profile: "default", mutations: [.init(method: "addBookmark", args: [["profileId": "default", "url": "https://fresh.test", "title": "Fresh"]])], binding: snapshot.binding, requestID: "old")
        #expect(restored.coordinator.membership(profile: "default", url: "https://fresh.test"))
      }
      restored.stop()
    }
  }

  @Test func oldOwnerBindingAndRouteABAAreRefused() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let original = try f.owner.snapshot(profile: "default")
    f.owner.remap(profiles: ["default": "other"], defaultProfile: "default")
    f.owner.remap(profiles: ["default": ""], defaultProfile: "default")
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: original.binding, requestID: "old-route")
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.replace(profile: "default", document: original.document, expectedRevision: original.revision, binding: original.binding)
    }
    let replacement = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try replacement.submit(profile: "default", mutations: [], binding: original.binding)
    }
  }

  @Test func sameEngineStoreReplacementRevokesOldBindings() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    try await f.start()
    let old = Store(state: f.state, checksInvariants: false)
    f.owner.bindStore(old)
    await f.owner.settleLifecycleForTesting()
    let original = try f.owner.snapshot(profile: "default")
    f.owner.bindStore(Store(state: f.state, checksInvariants: false))
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: original.binding)
    }
    await f.owner.settleLifecycleForTesting()
    let current = try f.owner.snapshot(profile: "default")
    _ = try f.owner.submit(profile: "default", mutations: [], binding: current.binding)
    f.owner.stop()
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: current.binding)
    }
  }

  @Test func profileRemovalRevokesSameEngineRoute() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    f.owner.remap(profiles: ["default": "", "alias": ""], defaultProfile: "default")
    let old = try f.owner.snapshot(profile: "alias")
    f.owner.remap(profiles: ["default": ""], defaultProfile: "default")
    f.owner.remap(profiles: ["default": "", "alias": ""], defaultProfile: "default")
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "alias", mutations: [], binding: old.binding)
    }
    let current = try f.owner.snapshot(profile: "default")
    f.owner.remap(profiles: ["default": "", "alias": "", "work": "work"], defaultProfile: "default")
    _ = try f.owner.submit(profile: "default", mutations: [], binding: current.binding)
  }

  @Test func retiredRouteRefusesLateFactCallbacks() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let old = try f.owner.snapshot(profile: "default")
    f.owner.remap(profiles: ["default": "away"], defaultProfile: "default")
    f.owner.remap(profiles: ["default": ""], defaultProfile: "default")
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.ackBookmarkFacts(profileId: "default", expectedEngine: "", records: [], generation: old.binding.generation)
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.observeRemoteRecords(profileId: "default", expectedEngine: "", records: [("bm:old", "late")], generation: old.binding.generation)
    }
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.clearBookmarkFacts(profileId: "default", expectedEngine: "", records: [], generation: old.binding.generation)
    }
  }

  @Test func replacingProcessOwnerRevokesOldOwnerReferences() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    let old = try f.owner.snapshot(profile: "default")
    NativeBookmarkOwner.current = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: old.binding)
    }
  }

  @Test func supersededMappingCannotReactivateRetiredEngine() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    var next = f.state
    next.profiles["default"]?.dataId = "next"
    let ticket = try #require(f.owner.stageForTesting(state: next))
    let captured = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let once = Mutex(false)
    f.owner.beforeMappingAdmissionForTesting = {
      let hold = once.withLock { value in if value { return false }; value = true; return true }
      if hold { captured.signal(); _ = release.wait(timeout: .now() + 5) }
    }
    let owner = f.owner
    let install = Task.detached { await owner.installMappingForTesting(ticket) }
    let held = await Task.detached { blockingWait(captured, seconds: 5) }.value
    guard held else { release.signal(); _ = await install.value; Issue.record("mapping admission gate was not reached"); return }
    try f.owner.retireBookmarks(engine: "next")
    release.signal()
    #expect(!(await install.value))
    #expect(!f.owner.coordinator.catalogEngines.contains("next"))
    let current = try f.owner.snapshot(profile: "default")
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: current.binding)
    }
  }

  @Test func retiringOneEngineKeepsSurvivingEngineReady() async throws {
    var state = BrowserState()
    state.profiles["work"] = profile("work", data: "work")
    let f = try await OwnerLifecycleFixture.make(state: state)
    defer { f.stop() }
    try await f.start()
    await f.settle()
    f.state.profiles.remove(["default"])
    f.state.settings.values["defaultProfileId"] = "work"
    try await f.owner.remap(state: f.state)
    await f.settle()
    let previousEpoch = try #require(f.catalog.bookmarkClaim).epoch
    try f.owner.retireBookmarks(engine: "")
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if let claim = f.catalog.bookmarkClaim, claim.epoch > previousEpoch, try f.owner.snapshot(profile: "work").ready { break }
      await Task.yield()
    }
    #expect(try f.owner.snapshot(profile: "work").ready)
    #expect(f.catalog.bookmarkClaim.map { $0.epoch > previousEpoch } == true)
    #expect(f.owner.coordinator.catalogEngines == ["work"])
  }

  @Test func retirementWaitsForHeldApplyFromPreviousOwner() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    let gate = OwnerClaimGate()
    defer { gate.open() }
    let operation = Task { try await f.owner.coordinator.engineQueue.perform(engine: "") { await gate.hold(); return true } }
    try await gate.waitUntilHeld()
    let replacement = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    NativeBookmarkOwner.current = replacement
    try replacement.retireBookmarks(engine: "")
    let drained = Mutex(false)
    let drain = Task { try await replacement.settleRetiredBookmarks(engine: ""); drained.withLock { $0 = true } }
    for _ in 0..<1000 { await Task.yield() }
    #expect(!drained.withLock { $0 })
    gate.open()
    _ = try await operation.value
    try await drain.value
    #expect(drained.withLock { $0 })
  }

  @Test func replacedOwnerCannotResumeHeldCatalogClaim() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    let gate = OwnerClaimGate()
    defer { gate.open() }
    f.owner.beforeClaimForTesting = { await gate.hold() }
    let start = Task { try await f.start() }
    try await gate.waitUntilHeld()
    NativeBookmarkOwner.current = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    gate.open()
    try await start.value
    #expect(f.catalog.bookmarkClaim == nil)
    #expect(!f.owner.runtimeIsActiveForTesting)
    #expect(f.client.reads.isEmpty)
  }

  @Test func replacedOwnerCannotPersistSyncLinks() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    NativeBookmarkOwner.current = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    let journal = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try? Data(contentsOf: journal)
    #expect(!f.owner.setBookmarkSyncLinks(["default": "obsolete-link"]))
    #expect((try? Data(contentsOf: journal)) == before)
  }

  @Test func removedNativeOwnerCannotFallBackDuringCleanup() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    NativeBookmarkOwner.current = nil
    #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) {
      try NativeBookmarkOwner.retireBookmarksForCleanup(engine: "")
    }
  }

  @Test func revokedOwnerCannotRetireReplacementJournal() async throws {
    let f = try await OwnerLifecycleFixture.make()
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    NativeBookmarkOwner.current = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    let journal = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try? Data(contentsOf: journal)
    #expect(throws: BookmarkWriterError.staleBinding) { try f.owner.retireBookmarks(engine: "") }
    #expect((try? Data(contentsOf: journal)) == before)
  }

  @Test(arguments: [false, true]) func ownerReplacementReloadsLastAcceptedJournal(nilGap: Bool) async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let armed = JournalGateFlag()
    let f = try await OwnerLifecycleFixture.make(fileOperations: gatedJournalOperations(armed: armed, entered: entered, release: release))
    defer { f.stop() }
    let previous = NativeBookmarkOwner.current
    defer { NativeBookmarkOwner.current = previous }
    NativeBookmarkOwner.current = f.owner
    f.owner.coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document(["https://page.test"]), ready: true)
    let binding = try f.owner.snapshot(profile: "default").binding
    armed.set()
    let owner = f.owner
    let writer = Task.detached { try owner.submit(profile: "default", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "Accepted before replacement"]])], binding: binding) }
    let held = await Task.detached { blockingWait(entered, seconds: 5) }.value
    guard held else { release.signal(); _ = try await writer.value; Issue.record("journal gate was not reached"); return }
    let replacement = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state)
    let setter = Task.detached {
      if nilGap { NativeBookmarkOwner.current = nil }
      NativeBookmarkOwner.current = replacement
    }
    release.signal()
    _ = try await writer.value
    await setter.value
    #expect(try replacement.snapshot(profile: "default").document["nodes"]?["b0"]?["title"] == "Accepted before replacement")
  }

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
      if !f.client.reads.isEmpty && !snapshot.ready && !catalog.readyForSync && catalog.nodes["b1"]?.title == "B" { break }
      await Task.yield()
    }
    #expect(f.owner.runtimeIsActiveForTesting)
    #expect(f.catalog.bookmarkClaim?.coordinator === f.owner.coordinator)
    #expect(f.client.reads == [""])
    #expect(scheduler.delays.isEmpty)
    let snapshot = try f.owner.snapshot(profile: "default")
    #expect(!snapshot.ready)
    #expect(snapshot.document["nodes"]?["b0"] == nil)
    #expect(snapshot.document["nodes"]?["b1"]?["title"] == "B")
    #expect(snapshot.document["nodes"]?["b1"]?["url"] == "https://page.test")
    let catalog = f.catalog.bookmarks(engineProfile: "")
    #expect(catalog.hasView)
    #expect(!catalog.readyForSync)
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
      if remapped.binding.engine == "recovery-engine" && !remapped.ready && !catalog.readyForSync && catalog.nodes["b1"]?.title == "B" { break }
      await Task.yield()
    }
    let remapped = try f.owner.snapshot(profile: "default")
    #expect(remapped.binding.engine == "recovery-engine")
    #expect(!remapped.ready)
    #expect(f.owner.coordinator.engine(profile: "default") == "recovery-engine")
    #expect(remapped.document["nodes"]?["b1"]?["title"] == "B")
    let remappedCatalog = f.catalog.bookmarks(engineProfile: "recovery-engine")
    #expect(remappedCatalog.hasView)
    #expect(!remappedCatalog.readyForSync)
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
    #expect(throws: BookmarkWriterError.staleBinding) {
      try f.owner.submit(profile: "default", mutations: [], binding: live.binding)
    }
    let disconnected = try f.owner.snapshot(profile: "default")
    #expect(disconnected.binding != live.binding)
    #expect(!disconnected.ready)
    _ = try f.owner.submit(profile: "default", mutations: [], binding: disconnected.binding)
    await #expect(throws: BookmarkCoordinatorError.ownershipUnavailable) {
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
    NativeBookmarkOwner.current = surviving
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
    catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
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
    NativeBookmarkOwner.current = owner
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
  var empty = false
  var pageID = "b0"
  var title = "Page"
  var reads: [String] = []
  var rawReads = 0
  var rawApplies = 0
  var appliedEngines: [String] = []
  var appliedTitles: [String: String] = [:]

  func read(_ engine: String) -> EngineBookmarkTree {
    reads.append(engine)
    return EngineBookmarkTree(bar: .init(id: "bar", kind: "f", title: "Bar", children: empty ? [] : [.init(id: pageID, kind: "u", title: title, url: "https://page.test", addedAt: 1)]), other: .init(id: "other", kind: "f", title: "Other", children: []))
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
