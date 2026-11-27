import SolaraEngine
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite struct BookmarkHolderRestorationTests {

  @Test @MainActor func filingFailureKeepsTheSourceAndAllowsRetry() async throws {
    let filing = BookmarkGroupFiling()
    var closed = 0
    var attempts = 0
    enum Refusal: Error { case refused }
    do {
      try await filing.run("group", save: { () throws -> Bool in
        attempts += 1
        throw Refusal.refused
      }, didSave: { _ in closed += 1 })
      Issue.record("The writer refusal should reach the caller")
    } catch Refusal.refused {}
    #expect(closed == 0)
    try await filing.run("group", save: { attempts += 1; return true }, didSave: { _ in closed += 1 })
    #expect(attempts == 2)
    #expect(closed == 1)
  }

  private let document: JSONValue = ["nodes": [
    "bar@default": ["kind": "folder", "children": ["holder"]],
    "holder": ["kind": "folder", "parentId": "bar@default", "title": "Imported (Arc)", "children": ["folder"]],
    "folder": ["kind": "folder", "parentId": "holder", "title": "Work", "children": ["a", "b"]],
    "a": ["kind": "url", "parentId": "folder", "url": "https://a.test/"],
    "b": ["kind": "url", "parentId": "folder", "url": "https://a.test/"],
  ]]

  private func catalog(_ profile: String, hasView: Bool = true) -> BookmarkHolderCatalog {
    BookmarkHolderCatalog(profile: profile, snapshot: BookmarkWriterSnapshot(
      binding: BookmarkWriterBinding(engine: "", generation: 1), revision: 1,
      ready: false, hasView: hasView, document: document, facts: [:]))
  }

  @Test func sharedRootsCountOnceAndUnreadableCatalogsAreIgnored() {
    #expect(BookmarkHolderRestoration.holders(in: [catalog("default", hasView: false)]).isEmpty)
    let holders = BookmarkHolderRestoration.holders(in: [catalog("default"), catalog("work")])
    #expect(holders.map(\.id) == ["holder"])
    #expect(holders.map(\.profile) == ["default"])
  }

  @Test func duplicateLinksStayAndOnlyAcknowledgedLinksAreRemoved() throws {
    let holder = try #require(BookmarkHolderRestoration.holders(in: [catalog("default")]).first)
    #expect(holder.removals(carried: []).isEmpty)
    #expect(holder.removals(carried: ["a"]) == ["a"])
    #expect(holder.removals(carried: ["a", "b"]) == ["holder"])
  }

  @Test func workspaceReceiptCarriesOnlyNewLinksAndRepeatAddsNothing() throws {
    let holder = try #require(BookmarkHolderRestoration.holders(in: [catalog("default")]).first)
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let command = Command("importWorkspace", [["profileId": "default", "windows": [
      ["tabs": [], "drafts": .array(holder.drafts)],
    ]]])
    let placed = try store.dispatch(command)
    #expect(placed.result?["carried"] == ["a"])
    #expect(store.state.groups.values.map(\.name) == ["Work"])
    #expect(try store.dispatch(command).result?["carried"] == [])
    #expect(store.state.groups.count == 1)
  }

  @Test func drainWaitsForAcceptedWorkAndOverlappingCallsShareIt() async throws {
    let holder = try #require(BookmarkHolderRestoration.holders(in: [catalog("default")]).first)
    let restoration = BookmarkHolderRestoration()
    var placements = 0
    let (started, start) = AsyncStream<Void>.makeStream()
    let (released, release) = AsyncStream<Void>.makeStream()
    func begin() -> Task<Void, Never>? {
      restoration.start(holder, safeMode: false, refuse: {}, place: { _ in
        placements += 1
        return ["a"]
      }, remove: { _, mutations in
        #expect(mutations.last?.args == [["a"]])
        start.yield(())
        for await _ in released { break }
      })
    }
    let first = try #require(begin())
    let overlap = try #require(begin())
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    let drain = restoration.beginDrain()
    #expect(begin() == nil)
    #expect(placements == 1)
    release.yield(())
    await drain()
    await first.value
    await overlap.value
    #expect(!restoration.draining)
  }

  @Test func failedRemovalRetriesWithoutPlacingAnotherGroup() async throws {
    let holder = try #require(BookmarkHolderRestoration.holders(in: [catalog("default")]).first)
    let restoration = BookmarkHolderRestoration()
    var placements = 0
    var removals = 0
    func attempt() async {
      await restoration.restore(holder, safeMode: false, refuse: { Issue.record("Unexpected Safe Mode") }, place: { _ in
        placements += 1
        return ["a", "b"]
      }, remove: { _, _ in
        removals += 1
        if removals == 1 { throw BookmarkWriterError.notOwned }
      })
    }
    await attempt()
    await attempt()
    #expect(placements == 1)
    #expect(removals == 2)
  }

  @Test func safeModeAndDrainHoldRefuseNewWork() async throws {
    let holder = try #require(BookmarkHolderRestoration.holders(in: [catalog("default")]).first)
    let restoration = BookmarkHolderRestoration()
    var alerts = 0
    func attempt(safeMode: Bool) async {
      await restoration.restore(holder, safeMode: safeMode, refuse: { alerts += 1 }, place: { _ in
        Issue.record("Unexpected placement")
        return ["a"]
      }, remove: { _, _ in Issue.record("Unexpected removal") })
    }
    await attempt(safeMode: true)
    let drain = restoration.beginDrain()
    await attempt(safeMode: false)
    await drain()
    #expect(alerts == 1)
  }
}
