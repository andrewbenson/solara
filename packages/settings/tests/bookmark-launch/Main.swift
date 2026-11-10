import Foundation
import SolaraEngine
import SolaraModel
import SolaraStore

enum TestFailure: Error { case timedOut, claimUnavailable }

@MainActor private var failures: [String] = []

@MainActor private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
  if !condition() { throw TestFailure.timedOut }
}

@MainActor private final class Gate {
  var continuation: CheckedContinuation<Void, Never>?
  func hold() async { await withCheckedContinuation { continuation = $0 } }
  func open() { continuation?.resume(); continuation = nil }
}

@MainActor private final class Client: EngineClient {
  var historyObservers = 0
  var bookmarkObservers = 0
  var rawReads = 0
  var rawApplies = 0
  var pumpReads = 0
  var pumpApplies = 0

  func tree() -> EngineBookmarkTree {
    EngineBookmarkTree(
      bar: .init(id: "bar", kind: "f", title: "Bar", children: [.init(id: "b0", kind: "u", title: "Original", url: "https://page.test", addedAt: 1)]),
      other: .init(id: "other", kind: "f", title: "Other", children: []))
  }

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) { historyObservers += 1 }
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) { bookmarkObservers += 1 }
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree { rawReads += 1; return tree() }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    rawApplies += 1
    return .init(applied: ops.count, skipped: 0, invalid: [])
  }
}

@MainActor private final class Fixture {
  let directory: URL
  let client = Client()
  let gate = Gate()
  var selected = true
  var safeMode = false
  var held = false
  var preparations = 0
  var attachments = 0
  var state = BrowserState()
  var owner: NativeBookmarkOwner?
  var alternateCatalog: LibraryCatalog?
  var usesStoreSubscription = false

  lazy var installation: NativeBookmarkInstallation = makeInstallation()

  func makeInstallation() -> NativeBookmarkInstallation {
    NativeBookmarkInstallation(
      selected: selected, safeMode: safeMode,
      prepare: { [unowned self] in
        preparations += 1
        let initial = state
        if held { await gate.hold() }
        let next = await NativeBookmarkOwner.prepare(directory: directory, state: initial, stampsEnabled: true)
        owner = next
        return next
      },
      attach: { [unowned self] next in
        attachments += 1
        let destination = alternateCatalog ?? catalog
        try await next.start(
          catalog: destination,
          client: BookmarkEngineClient(
            readTree: { [client] _ in await MainActor.run { client.pumpReads += 1; return client.tree() } },
            apply: { [client] _, ops in await MainActor.run { client.pumpApplies += 1; return .init(applied: ops.count, skipped: 0, invalid: []) } }),
          clock: .init(wallTimeMs: { Date().timeIntervalSince1970 * 1000 }, monotonicTimeMs: { ProcessInfo.processInfo.systemUptime * 1000 }),
          scheduler: .init(schedule: { _, _ in {} }))
        if usesStoreSubscription {
          next.subscribeToStoreCommits()
          await next.settleStoreSubscription()
        }
        guard next.installationIsUsable(catalog: destination) else { throw TestFailure.claimUnavailable }
      })
  }

  lazy var catalog: LibraryCatalog = LibraryCatalog(client: client, bookmarkAdmission: { [unowned self] in try await installation.ensureReady() })

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func stop() {
    installation.stop()
    NativeStoreHandle.resolve = nil
    try? FileManager.default.removeItem(at: directory)
  }
}

@main private struct BookmarkLaunchTests {
  @MainActor static func historyStartupCannotPreemptClaim() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.held = true
    let startup = Task { await f.catalog.start(engineProfiles: [""]) }
    try await waitUntil { f.gate.continuation != nil }
    expect(NativeBookmarkOwner.ownershipState.phase.rawValue == "starting", "native selection is visible while recovery is held")
    expect(f.client.historyObservers == 0 && f.client.bookmarkObservers == 0 && f.client.rawReads == 0, "history and raw bookmarks cannot begin before claim")
    f.gate.open()
    await startup.value
    expect(NativeBookmarkOwner.ownershipState.phase.rawValue == "owned", "a successful initial claim publishes ownership")
    expect(f.client.historyObservers == 1 && f.client.rawReads == 0, "history starts after claim and raw tree reads never start")
    expect(f.owner?.installationIsUsable(catalog: f.catalog) == true, "the claimed catalog belongs to the installed owner")
  }

  @MainActor static func concurrentEarlyCommandsShareOneBootstrap() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.held = true
    let first = Task { try await f.installation.ensureReady() }
    try await waitUntil { f.gate.continuation != nil }
    let history = Task { await f.catalog.start(engineProfiles: [""]) }
    let command = Task { _ = try? await f.catalog.applyBookmarks(ops: [], engineProfile: "") }
    let callers = (0..<12).map { _ in Task { try await f.installation.ensureReady() } }
    for _ in 0..<30 { await Task.yield() }
    expect(f.preparations == 1 && f.attachments == 0, "all early callers share one held recovery")
    expect(f.client.historyObservers == 0 && f.client.rawApplies == 0, "early calls do not preempt native claim")
    f.gate.open()
    try await first.value
    for caller in callers { try await caller.value }
    await history.value
    await command.value
    expect(f.preparations == 1 && f.attachments == 1, "one process owner is prepared and attached exactly once")
  }

  @MainActor static func realOwnerRecordsFacts() async throws {
    let f = try Fixture()
    defer { f.stop() }
    try await f.installation.ensureReady()
    try await waitUntil { f.owner?.coordinator.desiredView(engine: "").hasView == true }
    guard let owner = f.owner else { throw TestFailure.claimUnavailable }
    let before = try owner.snapshot(profile: "default")
    _ = try NativeBookmarkWriter.submit(profile: "default", mutationsJSON: "[{\"method\":\"updateBookmark\",\"args\":[\"b0\",{\"title\":\"Accepted\"}]}]", engine: before.binding.engine, generation: String(before.binding.generation), requestID: "fact")
    let after = try owner.snapshot(profile: "default")
    expect(after.document["nodes"]?["b0"]?["title"] == "Accepted", "the real bridge durably accepts the edit")
    expect(after.facts.count == 1 && (after.facts.values.first?.at ?? 0) > 0, "the production-prepared owner records a fact with a real timestamp")
    let reopened = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state, stampsEnabled: true)
    let recovered = try reopened.snapshot(profile: "default")
    expect(recovered.document["nodes"]?["b0"]?["title"] == "Accepted" && recovered.facts.count == 1, "document and fact survive the pending-store restart")
    expect(f.client.rawReads == 0 && f.client.rawApplies == 0, "all Chrome work uses the pump client")
  }

  @MainActor static func claimFailureNeverSelectsLegacy() async throws {
    let f = try Fixture()
    defer { f.stop() }
    let preempted = LibraryCatalog(client: f.client)
    await preempted.start(engineProfiles: [""])
    f.alternateCatalog = preempted
    var refused = false
    do { try await f.installation.ensureReady() } catch { refused = true }
    expect(refused, "a real late initial catalog claim is rejected")
    expect(NativeBookmarkOwner.ownershipState.phase.rawValue == "read-only-unavailable", "a failed claim never restores legacy authority")
    NativeBookmarkOwner.current = nil
    expect(NativeBookmarkWriter.state()["state"] as? String == "read-only-unavailable", "a nil owner after native selection remains unavailable")
    let count = f.client.rawApplies
    do { _ = try await f.catalog.applyBookmarks(ops: [.init(op: "remove", id: "b0")], engineProfile: ""); failures.append("failed ownership admitted raw writes") } catch {}
    expect(f.client.rawApplies == count, "failed installation blocks independently called native catalog writes")
  }

  @MainActor static func safeModeRefusesAllBookmarkWritesAndSync() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.safeMode = true
    let sentinel = f.directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = Data("unreadable evidence".utf8)
    try bytes.write(to: sentinel)
    do { try await f.installation.ensureReady(); failures.append("safe mode installed a writer") } catch {}
    await f.catalog.start(engineProfiles: [""])
    do { _ = try await f.catalog.applyBookmarks(ops: [.init(op: "remove", id: "b0")], engineProfile: ""); failures.append("safe mode admitted catalog writes") } catch {}
    let commands: [() throws -> Void] = [
      { _ = try NativeBookmarkWriter.submit(profile: "default", mutationsJSON: "[]", engine: "", generation: "1", requestID: nil) },
      { _ = try NativeBookmarkWriter.replace(profile: "default", documentJSON: "{}", expectedRevision: "0", engine: "", generation: "1", requestID: nil) },
      { _ = try NativeBookmarkWriter.ackBookmarkFacts(profile: "default", engine: "", recordsJSON: "[]", generation: "1") },
      { _ = try NativeBookmarkWriter.observeBookmarkRecords(profile: "default", engine: "", recordsJSON: "[]", generation: "1") },
      { _ = try NativeBookmarkWriter.clearBookmarkFacts(profile: "default", engine: "", recordsJSON: "[]", generation: "1") },
      { _ = try NativeBookmarkWriter.setBookmarkSyncLinks(linksJSON: "{}") },
    ]
    for command in commands { do { try command(); failures.append("safe mode admitted a bridge write or sync mutation") } catch {} }
    expect(f.preparations == 0 && f.attachments == 0, "safe mode never runs the mutating recovery/attach path")
    expect(f.client.rawReads == 0 && f.client.rawApplies == 0 && f.client.pumpApplies == 0, "safe mode cannot touch Chrome bookmarks through either client")
    expect(try! Data(contentsOf: sentinel) == bytes, "safe mode preserves journal evidence byte for byte")
    expect(try! FileManager.default.contentsOfDirectory(atPath: f.directory.path) == [BookmarkPendingStore.journalName], "safe mode does not rename evidence or create journals")
    expect(NativeBookmarkWriter.state()["state"] as? String == "read-only-unavailable", "sync sees native unavailable authority in safe mode")
  }

  @MainActor static func reloadKeepsOneNativeOwner() async throws {
    let f = try Fixture()
    defer { f.stop() }
    try await f.installation.ensureReady()
    let first = NativeBookmarkOwner.current
    let generation = NativeBookmarkWriter.state()["generation"] as? String
    for _ in 0..<5 {
      try await f.installation.ensureReady()
      await f.catalog.start(engineProfiles: [""])
      _ = NativeBookmarkWriter.state()
    }
    expect(NativeBookmarkOwner.current === first, "reattaching bridge callers preserve the native owner")
    expect(NativeBookmarkWriter.state()["generation"] as? String == generation, "reload does not replace the process owner")
    expect(f.preparations == 1 && f.attachments == 1, "reload performs no second recovery or installation")
    expect(f.client.rawReads == 0, "reattached history startup still uses the native claim")
  }

  @MainActor static func stoppedOwnerCannotAdvertiseOwned() async throws {
    let f = try Fixture()
    defer { f.stop() }
    try await f.installation.ensureReady()
    f.owner?.stop()
    expect(NativeBookmarkWriter.state()["state"] as? String == "stopped", "a stopped owner cannot advertise owned")
    do { try await f.installation.ensureReady(); failures.append("stopped process owner restarted") } catch {}
    let count = f.client.rawApplies
    do { _ = try await f.catalog.applyBookmarks(ops: [.init(op: "remove", id: "b0")], engineProfile: ""); failures.append("stopped owner admitted catalog writes") } catch {}
    expect(f.client.rawApplies == count, "stopping never reopens raw bookmark writing")
    expect(f.preparations == 1, "a stopped process does not select a second owner")
  }

  @MainActor static func stopDuringPreparationCannotResurrect() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.held = true
    let pending = Task { try await f.installation.ensureReady() }
    try await waitUntil { f.gate.continuation != nil }
    f.installation.stop()
    f.gate.open()
    do { try await pending.value; failures.append("a stopped held bootstrap returned ready") } catch {}
    expect(NativeBookmarkWriter.state()["state"] as? String == "stopped", "late recovery cannot resurrect stopped authority")
    expect(f.attachments == 0 && NativeBookmarkOwner.current == nil, "late preparation cannot attach or publish an owner")
    expect(f.client.pumpReads == 0 && f.client.pumpApplies == 0, "a stopped held bootstrap never reaches Chrome")
  }

  @MainActor static func latestStoreMappingBeforeOwned() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.held = true
    f.usesStoreSubscription = true
    let firstStore = Store(state: f.state)
    NativeStoreHandle.resolve = { firstStore }
    let pending = Task { try await f.installation.ensureReady() }
    try await waitUntil { f.gate.continuation != nil }
    var latest = f.state
    latest.profiles["default"]?.dataId = "fresh-engine"
    let replacement = Store(state: latest)
    NativeStoreHandle.resolve = { replacement }
    f.gate.open()
    try await pending.value
    let snapshot = try f.owner!.snapshot(profile: "default")
    expect(snapshot.binding.engine == "fresh-engine", "initial store subscription reconciles the latest mapping before owned")
    expect(f.owner?.installationIsUsable(catalog: f.catalog) == true, "owned state describes the latest claimed map")
    expect(NativeBookmarkWriter.state()["state"] as? String == "owned", "latest mapped claim is usable")
  }

  @MainActor static func managedReplacementCannotInheritOwned() async throws {
    let f = try Fixture()
    defer { f.stop() }
    try await f.installation.ensureReady()
    let original = NativeBookmarkOwner.current
    let replacement = await NativeBookmarkOwner.prepare(directory: f.directory, state: f.state, stampsEnabled: true)
    NativeBookmarkOwner.current = replacement
    expect(original !== replacement, "the fixture installs a distinct unstarted replacement")
    expect(NativeBookmarkWriter.state()["state"] as? String == "read-only-unavailable", "an unclaimed replacement cannot inherit managed ownership")
    do { _ = try NativeBookmarkWriter.snapshot(profile: "default"); failures.append("an unstarted replacement advertised a writable snapshot") } catch {}
    do { _ = try NativeBookmarkWriter.submit(profile: "default", mutationsJSON: "[]", engine: "", generation: "1", requestID: nil); failures.append("an unstarted replacement admitted a bridge write") } catch {}
    do { try await f.installation.ensureReady(); failures.append("a replacement reused the completed bootstrap task") } catch {}
    let raw = f.client.rawApplies
    do { _ = try await f.catalog.applyBookmarks(ops: [], engineProfile: ""); failures.append("an unclaimed replacement admitted a raw catalog command") } catch {}
    expect(f.client.rawApplies == raw && f.preparations == 1, "replacement neither reopens raw writes nor starts another owner")
  }

  @MainActor static func ownershipStateFeedSurvivesReattachment() async throws {
    let f = try Fixture()
    defer { f.stop() }
    f.held = true
    let stream = NativeBookmarkOwner.ownershipStates()
    var phases: [String] = []
    let consumer = Task { @MainActor in
      for await state in stream {
        phases.append(state.phase.rawValue)
      }
    }
    let pending = Task { try await f.installation.ensureReady() }
    try await waitUntil { f.gate.continuation != nil }
    try await waitUntil { phases.last == "starting" }
    expect(phases.last == "starting", "the initial consumer observes selected starting authority")
    consumer.cancel()
    await consumer.value
    f.gate.open()
    try await pending.value
    let owner = NativeBookmarkOwner.current
    let reattached = NativeBookmarkOwner.ownershipStates()
    var iterator = reattached.makeAsyncIterator()
    let owned = await iterator.next()
    expect(owned?.phase.rawValue == "owned", "a replacement consumer immediately receives the current authority")
    expect(NativeBookmarkOwner.current === owner && f.preparations == 1, "ending the first consumer preserves the native owner")
    f.owner?.stop()
    let stopped = await iterator.next()
    expect(stopped?.phase.rawValue == "stopped", "the replacement consumer observes native teardown")
    expect(NativeBookmarkWriter.state()["state"] as? String == "stopped", "teardown query agrees with the feed")
  }

  @MainActor static func main() async {
    let name = CommandLine.arguments.dropFirst().first ?? ""
    do {
      switch name {
      case "historyStartupCannotPreemptClaim": try await historyStartupCannotPreemptClaim()
      case "concurrentEarlyCommandsShareOneBootstrap": try await concurrentEarlyCommandsShareOneBootstrap()
      case "realOwnerRecordsFacts": try await realOwnerRecordsFacts()
      case "claimFailureNeverSelectsLegacy": try await claimFailureNeverSelectsLegacy()
      case "safeModeRefusesAllBookmarkWritesAndSync": try await safeModeRefusesAllBookmarkWritesAndSync()
      case "reloadKeepsOneNativeOwner": try await reloadKeepsOneNativeOwner()
      case "stoppedOwnerCannotAdvertiseOwned": try await stoppedOwnerCannotAdvertiseOwned()
      case "stopDuringPreparationCannotResurrect": try await stopDuringPreparationCannotResurrect()
      case "latestStoreMappingBeforeOwned": try await latestStoreMappingBeforeOwned()
      case "managedReplacementCannotInheritOwned": try await managedReplacementCannotInheritOwned()
      case "ownershipStateFeedSurvivesReattachment": try await ownershipStateFeedSurvivesReattachment()
      default: failures.append("unknown case: \(name)")
      }
    } catch { failures.append("unexpected error: \(error)") }
    for failure in failures { print("FAIL \(name): \(failure)") }
    if failures.isEmpty { print("PASS \(name)") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
