import Foundation
import Testing

@testable import SolaraModel
@testable import SolaraOmnibox
@testable import SolaraUI

@MainActor
struct SuggestionWorkerTests {
  func row(_ url: String, _ title: String) -> HistoryRow {
    HistoryRow(url: url, title: title, favicon: nil, visits: 5, lastVisit: Date().timeIntervalSince1970 * 1000)
  }

  func pages(_ result: SuggestionResult) -> [String] {
    result.items.compactMap { if case .page(let url, _, _, _, _, _) = $0 { return url }; return nil }
  }

  func ask(_ sources: NewTabSources, _ profileId: String, _ text: String) -> SuggestionResult {
    sources.suggestNow(SuggestRequest(profileId: profileId, typed: text, tabs: [], options: SuggestOptions()))
  }

  @Test func aRebuildKeepsServingTheOldIndexUntilTheNewOneIsReady() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    #expect(sources.preparedIndex("p"))
    let before = sources.worker.serving["p"]
    sources.setHistory([row("https://alpha.example/", "Alpha"), row("https://beta.example/", "Beta")] + OmniboxScaleRows.history(20000), profileId: "p")
    let answer = ask(sources, "p", "beta")
    #expect(sources.worker.serving["p"] == before || pages(answer).contains("https://beta.example/"))
    for _ in 0..<2000 where sources.worker.serving["p"] == before {
      sources.worker.drain()
      try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(sources.worker.serving["p"] != before)
    #expect(pages(ask(sources, "p", "beta")).contains("https://beta.example/"))
  }

  @Test func synchronousSourcesSwapAtOnce() {
    let sources = NewTabSources()
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    sources.setHistory([row("https://beta.example/", "Beta")], profileId: "p")
    #expect(pages(ask(sources, "p", "beta")).contains("https://beta.example/"))
  }

  @Test func aRemovedProfilesQueriesDontBringItsIndexBack() {
    let sources = NewTabSources()
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "gone")
    #expect(sources.worker.known.contains("gone"))
    sources.resetWorkspace()
    _ = ask(sources, "gone", "alpha")
    sources.worker.submit(SuggestRequest(profileId: "gone", typed: "al", tabs: [], options: SuggestOptions()), for: UUID(), generation: 1) { _ in }
    sources.worker.drain()
    #expect(!sources.worker.known.contains("gone"))
    #expect(!sources.preparedIndex("gone"))
  }

  func scope(_ sources: NewTabSources, _ profileId: String, _ text: String, engines: [SearchEngine] = builtInEngines) -> SearchScope? {
    findScope(text, sources.scopeSources(profileId, engines: engines))
  }

  @Test func theScopeCacheFollowsHistoryHosts() {
    let sources = NewTabSources()
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    #expect(scope(sources, "p", "alpha.example")?.kind == .history)
    #expect(scope(sources, "p", "beta.example") == nil)
    sources.setHistory([row("https://beta.example/", "Beta")], profileId: "p")
    #expect(scope(sources, "p", "beta.example")?.kind == .history)
    #expect(scope(sources, "p", "alpha.example") == nil)
  }

  @Test func theScopeCacheFollowsAsyncHistoryHosts() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    for _ in 0..<500 where scope(sources, "p", "alpha.example") == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(scope(sources, "p", "alpha.example")?.kind == .history)
    sources.setHistory([row("https://beta.example/", "Beta")], profileId: "p")
    for _ in 0..<500 where scope(sources, "p", "beta.example") == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(scope(sources, "p", "beta.example")?.kind == .history)
    #expect(scope(sources, "p", "alpha.example") == nil)
  }

  @Test func theScopeCacheFollowsOpenTabHosts() {
    let sources = NewTabSources()
    sources.setHistory([], profileId: "p")
    #expect(scope(sources, "p", "tab.example") == nil)
    sources.setTabs([TabRow(id: "t", url: "https://tab.example/", title: "Tab", favicon: nil)], profileId: "p")
    #expect(scope(sources, "p", "tab.example")?.kind == .history)
    sources.setTabs([], profileId: "p")
    #expect(scope(sources, "p", "tab.example") == nil)
  }

  @Test func theScopeCacheFollowsEngineEdits() {
    let sources = NewTabSources()
    sources.setHistory([], profileId: "p")
    var custom = builtInEngines[0]
    custom.id = "custom-wiki"
    custom.name = "Wiki"
    custom.keyword = "wk"
    custom.url = "https://wiki.example/?q=%s"
    custom.custom = true
    #expect(scope(sources, "p", "wk") == nil)
    #expect(scope(sources, "p", "wk", engines: builtInEngines + [custom])?.name == "Wiki")
    custom.keyword = "wq"
    #expect(scope(sources, "p", "wk", engines: builtInEngines + [custom]) == nil)
    #expect(scope(sources, "p", "wq", engines: builtInEngines + [custom])?.name == "Wiki")
    #expect(scope(sources, "p", "wq") == nil)
  }

  @Test func theScopeCacheIsPerProfileAndDroppedWithIt() {
    let sources = NewTabSources()
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "a")
    sources.setHistory([row("https://beta.example/", "Beta")], profileId: "b")
    #expect(scope(sources, "a", "alpha.example")?.kind == .history)
    #expect(scope(sources, "b", "alpha.example") == nil)
    #expect(scope(sources, "b", "beta.example")?.kind == .history)
    sources.resetWorkspace()
    #expect(scope(sources, "a", "alpha.example") == nil)
  }

  func waitFor(_ condition: () -> Bool, _ sources: NewTabSources) async {
    for _ in 0..<1000 where !condition() {
      sources.worker.drain()
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  @Test func anEmptyIndexIsNeverServedOverTheFirstRealHistory() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([], profileId: "p")
    sources.setHistory([row("https://beta.example/", "Beta")] + OmniboxScaleRows.history(20000), profileId: "p")
    #expect(pages(ask(sources, "p", "beta")).contains("https://beta.example/"))
  }

  @Test func emptyBookmarksNeverStandInForTheRealOnes() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory(OmniboxScaleRows.history(20000), profileId: "p")
    #expect(sources.preparedIndex("p"))
    sources.setBookmarks([BookmarkRow(url: "https://marked.example/", title: "Marked", favicon: nil)], profileId: "p")
    #expect(pages(ask(sources, "p", "marked")).contains("https://marked.example/"))
  }

  @Test func anEngineProfileSwitchNeverServesTheOtherProfilesRows() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")] + OmniboxScaleRows.history(20000), profileId: "p")
    #expect(sources.preparedIndex("p"))
    sources.setHistory([row("https://beta.example/", "Beta")] + OmniboxScaleRows.history(20000), profileId: "p", sameSource: false)
    #expect(!pages(ask(sources, "p", "alpha")).contains("https://alpha.example/"))
    #expect(pages(ask(sources, "p", "beta")).contains("https://beta.example/"))
  }

  @Test func clearedHistoryStopsServingAtOnceEvenMidBuild() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")] + OmniboxScaleRows.history(20000), profileId: "p")
    #expect(sources.preparedIndex("p"))
    sources.setHistory([row("https://alpha.example/", "Alpha"), row("https://beta.example/", "Beta")] + OmniboxScaleRows.history(20000), profileId: "p")
    sources.setHistory([], profileId: "p")
    #expect(!pages(ask(sources, "p", "alpha")).contains("https://alpha.example/"))
    #expect(!pages(ask(sources, "p", "beta")).contains("https://beta.example/"))
  }

  @Test func aSwapBumpsOnlyItsProfilesRevisionSoOpenBarsRefresh() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    #expect(sources.preparedIndex("p"))
    await waitFor({ scope(sources, "p", "alpha.example") != nil }, sources)
    sources.setHistory([row("https://alpha.example/", "Alpha"), row("https://alpha.example/beta", "Beta")], profileId: "p")
    let globalRevision = sources.revision
    let afterSet = sources.revision(for: "p")
    await waitFor({ sources.revision(for: "p") != afterSet }, sources)
    #expect(sources.revision(for: "p") != afterSet)
    #expect(sources.revision == globalRevision)
    #expect(pages(ask(sources, "p", "beta")).contains("https://alpha.example/beta"))
  }

  @Test func continuousChangesStillSwapTheBuildInProgress() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    #expect(sources.preparedIndex("p"))
    let before = sources.worker.swaps
    let big = OmniboxScaleRows.history(20000)
    sources.setHistory([row("https://alpha.example/", "Alpha")] + big, profileId: "p")
    sources.setHistory([row("https://alpha.example/", "Alpha"), row("https://beta.example/", "Beta")] + big, profileId: "p")
    sources.setHistory([row("https://alpha.example/", "Alpha"), row("https://beta.example/", "Beta"), row("https://gamma.example/", "Gamma")] + big, profileId: "p")
    #expect(sources.preparedIndex("p"))
    #expect(sources.worker.swaps - before == 2)
    #expect(pages(ask(sources, "p", "gamma")).contains("https://gamma.example/"))
  }

  @Test func warmSlicesRunAtUtility() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory(OmniboxScaleRows.history(20000), profileId: "p")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(sources.worker.lastWarmQoS == QOS_CLASS_UTILITY)
  }

  @Test func aResetDropsAHostPassStillInFlight() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory([row("https://alpha.example/", "Alpha")], profileId: "p")
    sources.resetWorkspace()
    for _ in 0..<50 where scope(sources, "p", "alpha.example") == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(scope(sources, "p", "alpha.example") == nil)
  }

  @Test func keystrokeQueriesRunAtUserInitiated() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory(OmniboxScaleRows.history(2000), profileId: "p")
    let worker = sources.worker
    DispatchQueue.global(qos: .background).async {
      worker.submit(SuggestRequest(profileId: "p", typed: "a", tabs: [], options: SuggestOptions()), for: UUID(), generation: 1) { _ in }
    }
    for _ in 0..<1000 where worker.lastComputeQoS == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(sources.worker.lastComputeQoS == QOS_CLASS_USER_INITIATED)
  }

  @Test func aDeletedRowIsNeverSuggestedByTheNextQuery() {
    let sources = NewTabSources()
    sources.asynchronous = true
    let big = OmniboxScaleRows.history(20000)
    sources.setHistory([row("https://secret.example/", "Secret")] + big, profileId: "p")
    #expect(sources.preparedIndex("p"))
    #expect(pages(ask(sources, "p", "secret")).contains("https://secret.example/"))
    sources.setHistory(big, profileId: "p")
    #expect(!pages(ask(sources, "p", "secret")).contains("https://secret.example/"))
  }

  @Test func aReplacedRowIsNeverSuggestedByTheNextQuery() {
    let sources = NewTabSources()
    sources.asynchronous = true
    let big = OmniboxScaleRows.history(20000)
    sources.setHistory([row("https://secret.example/", "Secret")] + big, profileId: "p")
    #expect(sources.preparedIndex("p"))
    sources.setHistory([row("https://other.example/", "Other")] + big, profileId: "p")
    #expect(!pages(ask(sources, "p", "secret")).contains("https://secret.example/"))
  }

  @Test func deletedBookmarksAreNeverSuggestedByTheNextQuery() {
    let sources = NewTabSources()
    sources.asynchronous = true
    sources.setHistory(OmniboxScaleRows.history(20000), profileId: "p")
    let keep = BookmarkRow(url: "https://kept.example/", title: "Kept", favicon: nil)
    sources.setBookmarks([keep, BookmarkRow(url: "https://marked.example/", title: "Marked", favicon: nil)], profileId: "p")
    #expect(sources.preparedIndex("p"))
    sources.setBookmarks([keep], profileId: "p")
    #expect(!pages(ask(sources, "p", "marked")).contains("https://marked.example/"))
  }

  @Test(arguments: ["first", "clear", "switch"])
  func aBlockedColdInstallSettlesWithoutWaitingForTheWorker(_ change: String) {
    let worker = SuggestionWorker()
    if change != "first" {
      worker.replace(profileId: "p", history: [row("https://alpha.example/", "Alpha")], bookmarks: [], serveOldUntilReady: false)
      #expect(worker.prepared("p"))
      #expect(worker.hasPreparedIndex("p"))
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    worker.submit(SuggestRequest(profileId: "gate", typed: "gate", tabs: [], options: SuggestOptions()), for: UUID(), generation: 1) { _ in
      entered.signal()
      _ = release.wait(timeout: .now() + .seconds(2))
    }
    #expect(entered.wait(timeout: .now() + .seconds(1)) == .success)
    defer { release.signal() }
    let history = change == "clear" ? [] : [row("https://beta.example/", "Beta")]
    worker.replace(profileId: "p", history: history, bookmarks: [], serveOldUntilReady: false)
    let request = SuggestRequest(profileId: "p", typed: "beta", tabs: [], options: SuggestOptions())
    let start = ContinuousClock.now
    for _ in 0..<32 { #expect(worker.suggestIfPrepared(request) == nil) }
    #expect(ContinuousClock.now - start < .milliseconds(50))
    #expect(!worker.hasPreparedIndex("p"))
    release.signal()
    #expect(worker.prepared("p"))
    #expect(worker.hasPreparedIndex("p"))
    let answer = worker.suggestNow(request)
    #expect(pages(answer) == (change == "clear" ? [] : ["https://beta.example/"]))
    #expect(!pages(worker.suggestNow(SuggestRequest(profileId: "p", typed: "alpha", tabs: [], options: SuggestOptions()))).contains("https://alpha.example/"))
  }

  @Test(arguments: ["warm", "compute"], [false, true])
  func oldWorkCannotRepublishReadinessAfterInvalidation(_ work: String, _ removing: Bool) {
    let worker = SuggestionWorker()
    if work == "compute" {
      worker.replace(profileId: "p", history: [row("https://alpha.example/", "Alpha")], bookmarks: [], serveOldUntilReady: false)
      #expect(worker.prepared("p"))
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let gate = SuggestRequest(profileId: "gate", typed: "gate", tabs: [], options: SuggestOptions())
    worker.submit(gate, for: UUID(), generation: 1) { _ in
      entered.signal()
      _ = release.wait(timeout: .now() + .seconds(2))
    }
    #expect(entered.wait(timeout: .now() + .seconds(1)) == .success)
    defer { release.signal() }
    let request = SuggestRequest(profileId: "p", typed: "alpha", tabs: [], options: SuggestOptions())
    if work == "warm" {
      worker.replace(profileId: "p", history: [row("https://alpha.example/", "Alpha")], bookmarks: [], serveOldUntilReady: false)
    } else {
      worker.submit(request, for: UUID(), generation: 1) { _ in }
    }
    let completed = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    worker.submit(gate, for: UUID(), generation: 1) { _ in
      completed.signal()
      _ = finish.wait(timeout: .now() + .seconds(2))
    }
    defer { finish.signal() }
    if removing {
      worker.remove("p")
    } else {
      worker.replace(profileId: "p", history: [], bookmarks: [], serveOldUntilReady: false)
    }
    release.signal()
    #expect(completed.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(!worker.hasPreparedIndex("p"))
    #expect(worker.suggestIfPrepared(request) == nil)
  }

  @Test func removingAProfileInvalidatesItsPreparedSnapshotBeforeTheWorkerRuns() {
    let worker = SuggestionWorker()
    worker.replace(profileId: "p", history: [row("https://alpha.example/", "Alpha")], bookmarks: [], serveOldUntilReady: false)
    let request = SuggestRequest(profileId: "p", typed: "alpha", tabs: [], options: SuggestOptions())
    #expect(pages(worker.suggestNow(request)) == ["https://alpha.example/"])
    #expect(worker.hasPreparedIndex("p"))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    worker.submit(request, for: UUID(), generation: 1) { _ in
      entered.signal()
      _ = release.wait(timeout: .now() + .seconds(2))
    }
    #expect(entered.wait(timeout: .now() + .seconds(1)) == .success)
    defer { release.signal() }
    worker.remove("p")
    #expect(!worker.hasPreparedIndex("p"))
    #expect(worker.suggestIfPrepared(request) == nil)
    release.signal()
    worker.drain()
    #expect(!worker.hasPreparedIndex("p"))
  }

  @Test func aQueuedSwapCannotRefreshARemovedProfile() async {
    let sources = NewTabSources()
    sources.asynchronous = true
    let old = row("https://alpha.example/", "Alpha")
    sources.setHistory([old], profileId: "gone")
    #expect(sources.preparedIndex("gone"))
    await waitFor({ scope(sources, "gone", "alpha.example") != nil }, sources)
    sources.setHistory([old, row("https://alpha.example/beta", "Beta")], profileId: "gone")
    #expect(sources.preparedIndex("gone"))
    sources.applyWorkspace(OmniboxWorkspaceSources(BrowserState()))
    let removedRevision = sources.revision(for: "gone")
    for _ in 0..<20 { await Task.yield() }
    #expect(sources.revision(for: "gone") == removedRevision)
    #expect(!sources.worker.known.contains("gone"))
    #expect(sources.omniboxBenchSnapshot(profileId: "gone")["sourceMode"] as? String == "unpublished")
  }

}
