import Foundation
import Testing
import Synchronization
import SolaraModel
import SolaraStore
@testable import SolaraEngine

@MainActor
final class FakeEngineClient: EngineClient {
  var calls: [String] = []
  var rows: [String: [EngineHistoryRow]] = [:]
  var onQuery: (() -> Void)?
  var handler: ((HistoryChange) -> Void)?
  var reads = 0
  var holdQuery = false
  var queryGate: CheckedContinuation<Void, Never>?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {
    calls.append("observe")
    self.handler = handler
  }

  func watchHistory(engineProfile: String) async throws {
    calls.append("watch:\(engineProfile)")
  }

  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] {
    calls.append("query:\(engineProfile):\(maxUrls):\(maxVisits)")
    reads += 1
    let result = rows[engineProfile] ?? []
    onQuery?()
    if holdQuery {
      holdQuery = false
      await withCheckedContinuation { queryGate = $0 }
    }
    return result
  }

  func emit(_ change: HistoryChange) { handler?(change) }
}

struct HistoryRetirementTimeout: Error {}

@Suite @MainActor struct HistoryTests {
  @Test func dormantHistoryWaitsForEngineAdmission() async {
    let client = FakeEngineClient()
    var loaded: Set<String> = [""]
    let catalog = LibraryCatalog(client: client, engineAdmission: { loaded.contains($0) })
    await catalog.start(engineProfiles: ["", "work"])
    #expect(catalog.history(engineProfile: "").ready)
    #expect(!catalog.history(engineProfile: "work").ready)
    #expect(!client.calls.contains("watch:work"))
    loaded.insert("work")
    await catalog.start(engineProfiles: ["work"])
    #expect(catalog.history(engineProfile: "work").ready)
    #expect(client.calls.contains("watch:work"))
  }

  @Test func confirmedDeletionRetiresOnlyTheFinalReference() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["first"] = Profile(id: "first", name: "First", color: "blue", icon: nil, createdAt: 1, dataId: "shared")
    state.profiles["last"] = Profile(id: "last", name: "Last", color: "blue", icon: nil, createdAt: 2, dataId: "shared")
    state.profileOrder += ["first", "last"]
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["shared"])
    try store.transact { try $0.deleteProfile("first") }
    #expect(catalog.history(engineProfile: "shared").ready)
    try store.transact { try $0.deleteProfile("last") }
    #expect(catalog.histories["shared"] == nil)
  }

  @Test func batchedIdentityChangeRetiresTheEngineRecordedAtDeletion() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["p-target-1"] = Profile(id: "p-target-1", name: "Target", color: "blue", icon: nil, createdAt: 1, dataId: "p-old-1")
    state.profileOrder.append("p-target-1")
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["p-old-1", "p-new-1"])
    try store.transact { session in
      try session.updateProfile("p-target-1", TabUpdate(set: ["dataId": .string("p-new-1")]))
      try session.deleteProfile("p-target-1")
    }
    #expect(store.state.orphanedProfileData == ["p-new-1"])
    #expect(catalog.histories["p-new-1"] == nil)
    #expect(catalog.history(engineProfile: "p-old-1").ready)
  }

  @Test func confirmedDeletionDoesNotRetireAnUnconfirmedEngineQueuedByTheSameBatch() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["p-unconfirmed-1"] = Profile(id: "p-unconfirmed-1", name: "Unconfirmed", color: "blue", icon: nil, createdAt: 1)
    state.profiles["p-confirmed-1"] = Profile(id: "p-confirmed-1", name: "Confirmed", color: "blue", icon: nil, createdAt: 2)
    state.profileOrder += ["p-unconfirmed-1", "p-confirmed-1"]
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["p-unconfirmed-1", "p-confirmed-1"])
    var profiles = state.profiles.map.mapValues(\.jsonValue)
    profiles.removeValue(forKey: "p-unconfirmed-1")
    let commit = try store.dispatch([
      Command("applyState", [[
        "profiles": .object(profiles), "profileOrder": JSONValue([Settings.defaultProfileID, "p-confirmed-1"]),
        "orphanedProfileData": ["p-unconfirmed-1"],
      ]]),
      Command("deleteProfile", ["p-confirmed-1"]),
    ])
    #expect(commit.state.orphanedProfileData == ["p-unconfirmed-1", "p-confirmed-1"])
    #expect(catalog.histories["p-confirmed-1"] == nil)
    #expect(catalog.history(engineProfile: "p-unconfirmed-1").ready)
    client.emit(.visit(profile: "p-unconfirmed-1", url: "https://unconfirmed", title: "Unconfirmed", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p-unconfirmed-1").entries.map(\.url) == ["https://unconfirmed"])
  }

  @Test func confirmedDeletionFromBackgroundStoreDeliveryRetiresOnlyItsEngine() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["p-background-1"] = Profile(id: "p-background-1", name: "Background", color: "blue", icon: nil, createdAt: 1)
    state.profileOrder.append("p-background-1")
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["", "p-background-1"])
    let completed = Mutex(false)
    let deletion = Task.detached {
      defer { completed.withLock { $0 = true } }
      try store.dispatch(Command("deleteProfile", ["p-background-1"]))
    }
    let deadline = ContinuousClock.now + .seconds(60)
    while !completed.withLock({ $0 }) {
      guard ContinuousClock.now < deadline else { throw HistoryRetirementTimeout() }
      try await Task.sleep(for: .milliseconds(1))
    }
    try await deletion.value
    while catalog.histories["p-background-1"] != nil {
      guard ContinuousClock.now < deadline else { throw HistoryRetirementTimeout() }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(catalog.history(engineProfile: "").ready)
    #expect(!catalog.history(engineProfile: "p-background-1").ready)
  }

  @Test func confirmedFinalDefaultEngineSharerRemovalRetiresOnlyDefaultHistory() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["p-default-sharer-1"] = Profile(id: "p-default-sharer-1", name: "Shared", color: "blue", icon: nil, createdAt: 1, dataId: Settings.defaultProfileID)
    state.profiles["p-survivor-1"] = Profile(id: "p-survivor-1", name: "Survivor", color: "blue", icon: nil, createdAt: 2)
    state.profileOrder += ["p-default-sharer-1", "p-survivor-1"]
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["", "p-survivor-1"])
    try store.dispatch(Command("deleteProfile", [.string(Settings.defaultProfileID)]))
    #expect(catalog.history(engineProfile: "").ready)
    #expect(store.state.orphanedProfileData.isEmpty)
    try store.dispatch(Command("deleteProfile", ["p-default-sharer-1"]))
    #expect(store.state.orphanedProfileData == [""])
    #expect(catalog.histories[""] == nil)
    #expect(catalog.history(engineProfile: "p-survivor-1").ready)
    client.emit(.visit(profile: "", url: "https://late", title: "Late", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.histories[""] == nil)
  }

  @Test func profileAbsenceWithoutConfirmationDoesNotRetireHistory() async throws {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var state = BrowserState()
    state.profiles["p"] = Profile(id: "p", name: "P", color: "blue", icon: nil, createdAt: 1)
    state.profileOrder.append("p")
    let store = Store(state: state, checksInvariants: false)
    let lifetimes = HistoryProfileLifetimes(catalog: catalog, store: store)
    defer { lifetimes.stop() }
    await catalog.start(engineProfiles: ["p"])
    try store.transact { session in
      session.update { state in
        state.profiles["p"] = nil
        state.profileOrder.removeAll { $0 == "p" }
        state.orphanedProfileData = ["p"]
      }
    }
    #expect(catalog.history(engineProfile: "p").ready)
  }

  @Test func retirementUsesExactUnicodeEngineIdentities() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    await catalog.start(engineProfiles: [composed, decomposed])
    catalog.retireHistory(engineProfile: composed, remainingEngineProfiles: [decomposed])
    client.emit(.visit(profile: decomposed, url: "https://survivor", title: "Survivor", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.histories[composed] == nil)
    #expect(catalog.history(engineProfile: decomposed).entries.map(\.url) == ["https://survivor"])
    #expect(catalog.history(engineProfile: decomposed).ready)
  }

  @Test func retirementDropsQueuedEventsAndRejectsStaleStarts() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://old", title: "Old", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p", "P"])
    client.emit(.visit(profile: "p", url: "https://queued", title: "Queued", visits: 1, at: 20))
    catalog.retireHistory(engineProfile: "p", remainingEngineProfiles: ["P"])
    await catalog.flushPending()
    await catalog.start(engineProfiles: ["p"])
    client.emit(.visit(profile: "p", url: "https://late", title: "Late", visits: 1, at: 30))
    await catalog.flushPending()
    #expect(catalog.histories["p"] == nil)
    #expect(!catalog.history(engineProfile: "p").ready)
    #expect(catalog.history(engineProfile: "P").ready)
    #expect(client.calls.filter { $0.hasPrefix("query:p:") }.count == 1)
  }

  @Test func retirementReplacesPendingObserverPublicationsAndFinishesTheStream() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    let stream = catalog.observe(engineProfile: "p")
    await catalog.start(engineProfiles: ["p"])
    catalog.retireHistory(engineProfile: "p", remainingEngineProfiles: [])
    for stream in [stream, catalog.observe(engineProfile: "p")] {
      let updates = Task {
        var values: [HistorySnapshot] = []
        for await snapshot in stream { values.append(snapshot) }
        return values
      }
      let timedOut = Mutex(false)
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        timedOut.withLock { $0 = true }
        updates.cancel()
      }
      #expect(await updates.value == [HistorySnapshot()])
      timeout.cancel()
      #expect(!timedOut.withLock { $0 })
    }
  }

  @Test func retirementKeepsAnEngineWithASurvivingSharer() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: [""])
    catalog.retireHistory(engineProfile: "", remainingEngineProfiles: [""])
    client.emit(.visit(profile: "", url: "https://shared", title: "Shared", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "").entries.map(\.url) == ["https://shared"])
    #expect(catalog.history(engineProfile: "").ready)
  }

  @Test func retirementDuringQueryDropsItsPublicationAndBufferedEvents() async throws {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://stale", title: "Stale", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    client.holdQuery = true
    let loading = Task { await catalog.start(engineProfiles: ["p"]) }
    defer { client.queryGate?.resume(); client.queryGate = nil }
    let deadline = ContinuousClock.now + .seconds(60)
    while client.queryGate == nil {
      guard ContinuousClock.now < deadline else { throw HistoryRetirementTimeout() }
      try await Task.sleep(for: .milliseconds(1))
    }
    client.emit(.visit(profile: "p", url: "https://buffered", title: "Buffered", visits: 1, at: 20))
    catalog.retireHistory(engineProfile: "p", remainingEngineProfiles: [])
    client.queryGate?.resume()
    client.queryGate = nil
    await loading.value
    #expect(catalog.histories["p"] == nil)
    #expect(!catalog.history(engineProfile: "p").ready)
  }

  @Test func watchesBeforeQueryAndReplaysEventsDuringLoad() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://old", title: "Old", visits: 1, visitTimes: [10])]
    client.onQuery = { client.emit(.visit(profile: "p", url: "https://new", title: "New", visits: 1, at: 20)) }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    #expect(client.calls == ["observe", "watch:p", "query:p:5000:50"])
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://new", "https://old"])
    #expect(catalog.history(engineProfile: "p").ready)
  }

  @Test func filtersOrdersLimitsAndSetsFloorBeforeFiltering() async {
    let client = FakeEngineClient()
    client.rows["p"] = (0..<5000).map { index in
      EngineHistoryRow(url: index == 0 ? "chrome://newtab" : "https://\(index)", title: "\(index)", visits: 60, visitTimes: Array(0..<60).map { Double(index * 100 + $0) })
    }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    let snapshot = catalog.history(engineProfile: "p")
    #expect(snapshot.entries.count == 4999)
    #expect(snapshot.entries.first?.url == "https://4999")
    #expect(snapshot.entries.first?.visitTimes.count == 50)
    #expect(snapshot.floor == 59)
  }

  @Test func batchesChangesAndIncrementsRevisionOnlyForChangedViews() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    let initial = catalog.history(engineProfile: "p").revision
    client.emit(.visit(profile: "p", url: "https://a", title: "A", visits: 1, at: 10))
    client.emit(.visit(profile: "p", url: "https://b", title: "B", visits: 1, at: 20))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").revision == initial + 1)
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://b", "https://a"])
    client.emit(.visit(profile: "p", url: "https://a", title: "A", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").revision == initial + 1)
  }

  @Test func fullDeletionRequeriesAndLeavesCatalogReady() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = []
    client.emit(.deleted(profile: "p", all: true, urls: []))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.isEmpty)
    #expect(catalog.history(engineProfile: "p").revision == 2)
  }

  @Test func fullDeletionDuringQueryTriggersAnotherQuery() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://stale", title: "Stale", visits: 1, visitTimes: [10])]
    client.onQuery = {
      guard client.reads == 1 else { return }
      client.rows["p"] = []
      client.emit(.deleted(profile: "p", all: true, urls: []))
    }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.isEmpty)
  }

  @Test func importedRowsForUnknownURLsRequery() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = [.init(url: "https://b", title: "B", visits: 2, visitTimes: [20]), .init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    client.emit(.modified(profile: "p", rows: [.init(url: "https://b", title: "B", visits: 2)]))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://b", "https://a"])
    client.emit(.modified(profile: "p", rows: [.init(url: "https://a", title: "A2", visits: 3)]))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.last?.title == "A2")
  }

  @Test func timeRangeDeletionRequeriesWithoutURLList() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "file:///a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = [.init(url: "file:///a", title: "A", visits: 1, visitTimes: [5])]
    client.emit(.deleted(profile: "p", all: true, urls: []))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").entries.first?.lastVisit == 5)
    #expect(client.reads == 2)
  }

  @Test func observerReceivesInitialAndUpdatedSnapshots() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var updates = catalog.observe(engineProfile: "p").makeAsyncIterator()
    #expect(await updates.next()?.ready == false)
    await catalog.start(engineProfiles: ["p"])
    #expect(await updates.next()?.revision == 1)
  }

  @Test func profileIsolationAndUnknownProfileStayUnready() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p", "incognito:w@p", "q", "p"])
    #expect(client.calls.filter { $0.hasPrefix("query:") }.count == 2)
    #expect(!catalog.history(engineProfile: "incognito:w@p").ready)
    #expect(!catalog.history(engineProfile: "missing").ready)
  }
}
